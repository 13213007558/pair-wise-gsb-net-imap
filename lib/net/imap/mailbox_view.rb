# frozen_string_literal: true

module Net
  class IMAP < Protocol

    # Net::IMAP::MailboxView maintains a local, UID-keyed view of a selected
    # mailbox, built entirely from server responses.  It is an optional
    # companion to Net::IMAP: register it with IMAP#add_response_handler and
    # it will consume untagged +SELECT+/+QRESYNC+ status responses, +FETCH+,
    # +EXPUNGE+, and +VANISHED+ responses as they arrive.
    #
    #   view = Net::IMAP::MailboxView.new
    #   imap.add_response_handler(view)
    #   imap.select("INBOX", condstore: true)
    #   view.full_sync(1..) { imap.uid_fetch(1.., %w[FLAGS MODSEQ]) }
    #   view[123]         # => #<data Net::IMAP::MailboxView::Message ...>
    #   view.exists?(456) # => true, false, or nil (not synchronized yet)
    #   view.sync_state   # => confirmed boundary for a QRESYNC reconnect
    #
    # == Confirmed state vs. live state
    #
    # The view deliberately separates two kinds of state:
    #
    # * _Live_ message data (Message#flags and Message#modseq, keyed by UID)
    #   is updated immediately by every +FETCH+, +EXPUNGE+, and +VANISHED+
    #   response.  Updates carrying a +MODSEQ+ lower than the known value are
    #   stale (or duplicate) notifications and are ignored; see
    #   #ignored_stale_updates.
    # * The _confirmed synchronization boundary_ (#uidvalidity,
    #   #highestmodseq, #uidnext, and #nomodseq?) is only updated when the
    #   command that carried the new values completes with a tagged +OK+
    #   response.  A failed +SELECT+ or an interrupted synchronization never
    #   modifies the confirmed boundary, so #sync_state can safely be used to
    #   resume a +QRESYNC+ session after reconnecting.
    #
    # == Known-gone vs. not-yet-synchronized
    #
    # The view never assumes that a UID which was not returned by a partial
    # response is gone.  #exists? returns +nil+ for UIDs that have not been
    # covered by a completed synchronization.  Only +EXPUNGE+, +VANISHED+, or
    # a successfully completed #full_sync can prove that a UID does not
    # exist.
    #
    # == UIDVALIDITY
    #
    # When a +UIDVALIDITY+ response code carries a new value, all message
    # data derived from the previous identity is discarded immediately.  The
    # new identity replaces the confirmed boundary only after the command
    # completes successfully.
    class MailboxView
      include Enumerable

      # A single message known to the MailboxView.
      #
      # +flags+ is a frozen array of flag name Symbols, and +modseq+ is the
      # highest message mod-sequence the server has reported (or +nil+ when
      # the server does not support mod-sequences).
      Message = Data.define(:uid, :flags, :modseq) do
        # Returns a new Message.  +flags+ is converted to a frozen array of
        # Symbols, and +modseq+ may be +nil+.
        def initialize(uid:, flags:, modseq: nil)
          super(
            uid:    Integer(uid),
            flags:  (flags || []).map(&:to_sym).freeze,
            modseq: modseq && Integer(modseq)
          )
        end
      end

      # A snapshot of the confirmed synchronization boundary, suitable for
      # resuming the mailbox with a +QRESYNC+ +SELECT+ after reconnecting.
      # All values are +nil+ when they have never been confirmed.
      SyncState = Data.define(:uidvalidity, :highestmodseq, :uidnext)

      # The number of +FETCH+ updates that were ignored because they carried
      # a +MODSEQ+ lower than the known value.
      attr_reader :ignored_stale_updates

      def initialize
        @mutex      = Thread::Mutex.new
        @messages   = {} # uid    => Message
        @seq_to_uid = {} # seqno  => uid
        @uid_to_seq = {} # uid    => seqno
        @coverage   = SequenceSet.new # UIDs with proven existence knowledge
        @uidvalidity   = nil # confirmed identity
        @highestmodseq = nil # confirmed boundary
        @uidnext       = nil # confirmed boundary
        @nomodseq      = false
        @ignored_stale_updates = 0
        @staged = {}
      end

      # Registers the view as a response handler on +imap+ and returns +self+.
      def attach(imap); imap.add_response_handler(self)    and self end

      # Removes the view from +imap+'s response handlers and returns +self+.
      def detach(imap); imap.remove_response_handler(self) and self end

      # :call-seq: call(response) -> self
      #
      # Response handler interface: consumes untagged +FETCH+, +VANISHED+,
      # +EXPUNGE+, and status +OK+ responses, and commits or discards staged
      # synchronization state when a tagged response arrives.  Register with
      # IMAP#add_response_handler or #attach.
      def call(resp)
        @mutex.synchronize do
          case resp
          when UntaggedResponse then handle_untagged(resp)
          when TaggedResponse   then handle_tagged(resp)
          end
        end
        self
      end

      # The confirmed +UIDVALIDITY+ of the mailbox, or +nil+ when no
      # synchronization has completed successfully.
      def uidvalidity;   @mutex.synchronize { @uidvalidity   } end

      # The confirmed highest mod-sequence of the mailbox, or +nil+ when it
      # is unknown or the server does not support mod-sequences.
      def highestmodseq; @mutex.synchronize { @highestmodseq } end

      # The confirmed +UIDNEXT+ of the mailbox, or +nil+ when unknown.
      def uidnext;       @mutex.synchronize { @uidnext       } end

      # Whether the server reported +NOMODSEQ+ for the confirmed identity.
      def nomodseq?;     @mutex.synchronize { @nomodseq      } end

      # Returns a SyncState snapshot of the confirmed synchronization
      # boundary, or +nil+ when no boundary has ever been confirmed.  Only
      # values from successfully completed commands are included, so the
      # result is always safe to use as +QRESYNC+ parameters after a
      # reconnect.
      def sync_state
        @mutex.synchronize do
          @uidvalidity and SyncState[
            uidvalidity:   @uidvalidity,
            highestmodseq: @nomodseq ? nil : @highestmodseq,
            uidnext:       @uidnext,
          ]
        end
      end

      # Returns the Message for +uid+, or +nil+ when the UID is not known to
      # exist.  See also #exists?.
      def [](uid);       @mutex.synchronize { @messages[uid] } end

      # Returns +true+ when a Message is known for +uid+.
      def known?(uid);   @mutex.synchronize { @messages.key?(uid) } end

      # :call-seq: exists?(uid) -> true, false, or nil
      #
      # Returns +true+ when the UID is known to exist, +false+ when it is
      # known to be gone (expunged, vanished, or absent from a completed
      # #full_sync), and +nil+ when the UID has not been synchronized yet.
      def exists?(uid)
        @mutex.synchronize do
          next true  if @messages.key?(uid)
          next false if @coverage.include?(uid)
          nil
        end
      end

      # Returns the number of known messages.
      def size;   @mutex.synchronize { @messages.size   } end

      # Returns +true+ when no messages are known.
      def empty?; @mutex.synchronize { @messages.empty? } end

      # Returns a sorted Array of the UIDs of all known messages.
      def uids;   @mutex.synchronize { @messages.keys.sort } end

      # Returns a SequenceSet of the UIDs of all known messages, suitable
      # for the _known-uids_ parameter of a +QRESYNC+ +SELECT+.
      def known_uid_set
        @mutex.synchronize { SequenceSet[@messages.keys] }
      end

      # Yields each known Message, ordered by UID.  Returns an Enumerator
      # when no block is given.
      def each(&block)
        return to_enum(__method__) unless block_given?
        @mutex.synchronize { @messages.sort.map(&:last) }.each(&block)
        self
      end

      # Returns an Array of all known messages, ordered by UID.
      def to_a; each.to_a end

      # :call-seq:
      #   full_sync(uid_range = 1..) { ... } -> block result
      #
      # Runs the block---typically a +UID FETCH+ of the given range---and,
      # only when the block completes without raising, records that every
      # UID in +uid_range+ has been accounted for.  After a successful
      # #full_sync, #exists? returns +false+ for any UID in the range that
      # was not returned by the server.  When the block raises (for example
      # a connection error halfway through the +FETCH+), the range is
      # _not_ recorded: UIDs that were not returned remain "not yet
      # synchronized" rather than being treated as deleted.
      #
      # An endless range (the default) is resolved against the confirmed
      # #uidnext and the highest UID seen so far.
      def full_sync(uid_range = 1..)
        raise ArgumentError, "full_sync requires a block" unless block_given?
        result = yield
        @mutex.synchronize do
          first = uid_range.begin || 1
          last  = uid_range.end   || sync_high_water
          last or raise ArgumentError,
                "cannot resolve endless range: no confirmed UIDNEXT or UIDs"
          last -= 1 if uid_range.exclude_end?
          @coverage.add(first..last) if first <= last
        end
        result
      end

      private

      def handle_untagged(resp)
        case resp.name
        when "FETCH"    then apply_fetch(resp.data)
        when "VANISHED" then apply_vanished(resp.data)
        when "EXPUNGE"  then apply_expunge(resp.data)
        when "OK"       then apply_response_code(resp.data&.code)
        end
      end

      def handle_tagged(resp)
        apply_response_code(resp.data&.code)
        case resp.name
        when "OK" then commit_staged
        else           discard_staged
        end
      end

      def apply_response_code(code)
        case code&.name
        when "UIDVALIDITY"   then stage_uidvalidity(code.data)
        when "HIGHESTMODSEQ" then @staged[:highestmodseq] = Integer(code.data)
        when "NOMODSEQ"      then @staged[:nomodseq]      = true
        when "UIDNEXT"       then @staged[:uidnext]       = Integer(code.data)
        when "CLOSED"        then drop_session_state
        end
      end

      # A new UIDVALIDITY invalidates every message and every coverage claim
      # derived from the previous identity.  Live data is dropped
      # immediately; the confirmed boundary is only replaced on commit.
      def stage_uidvalidity(value)
        value = Integer(value)
        return if value == (@staged[:uidvalidity] || @uidvalidity)
        drop_session_state
        @staged.replace(uidvalidity: value)
      end

      def commit_staged
        identity_changed =
          @staged[:uidvalidity] && @staged[:uidvalidity] != @uidvalidity
        @uidvalidity = @staged[:uidvalidity] if @staged[:uidvalidity]
        if @staged[:nomodseq]
          @nomodseq      = true
          @highestmodseq = nil
        elsif @staged[:highestmodseq]
          @nomodseq      = false
          @highestmodseq = @staged[:highestmodseq]
        elsif identity_changed
          # The new identity did not report a highest mod-sequence.
          @nomodseq      = false
          @highestmodseq = nil
        end
        if @staged[:uidnext]
          @uidnext = @staged[:uidnext]
        elsif identity_changed
          @uidnext = nil
        end
        discard_staged
      end

      def discard_staged
        @staged.clear
      end

      # Drops everything learned from the current session's message
      # responses, while keeping the confirmed boundary for reconnecting.
      def drop_session_state
        @messages.clear
        @seq_to_uid.clear
        @uid_to_seq.clear
        @coverage = SequenceSet.new
      end

      def apply_fetch(data)
        uid = data.attr["UID"] or return # cannot track without a UID
        uid = Integer(uid)
        record_seq(data.seqno, uid) if data.respond_to?(:seqno) && data.seqno
        existing = @messages[uid]
        modseq   = data.attr["MODSEQ"]
        flags    = data.attr["FLAGS"]
        if modseq && existing&.modseq && modseq < existing.modseq
          @ignored_stale_updates += 1 # stale or duplicate notification
          return
        end
        @messages[uid] = Message[
          uid:    uid,
          flags:  flags ? flags : (existing&.flags || []),
          modseq: modseq || existing&.modseq,
        ]
        @coverage.add(uid)
        advance_highestmodseq(modseq)
      end

      def apply_vanished(data)
        # VANISHED (EARLIER) and VANISHED are equivalent for the view: the
        # UIDs are gone.  Both are idempotent, so duplicate notifications
        # are harmless.
        data.each { |uid| remove_uid(uid) }
      end

      def apply_expunge(seqno)
        seqno = Integer(seqno)
        if @seq_to_uid.key?(seqno)
          remove_uid(@seq_to_uid[seqno]) # also shifts higher seqs down
        else
          # The expunged message was never seen, but higher known sequence
          # numbers still shift down.
          shift_seqs_down(seqno)
        end
      end

      def remove_uid(uid)
        uid or return
        uid = Integer(uid)
        @messages.delete(uid)
        if (seq = @uid_to_seq.delete(uid))
          @seq_to_uid.delete(seq)
          shift_seqs_down(seq)
        end
        @coverage.add(uid) # the UID is now *known* to be gone
      end

      def shift_seqs_down(seqno)
        @seq_to_uid.keys.select { _1 > seqno }.sort.each do |seq|
          uid = @seq_to_uid.delete(seq)
          @seq_to_uid[seq - 1] = uid
          @uid_to_seq[uid]     = seq - 1
        end
      end

      def record_seq(seqno, uid)
        seqno = Integer(seqno)
        if (previous = @uid_to_seq[uid]) && previous != seqno
          @seq_to_uid.delete(previous)
        end
        @seq_to_uid[seqno] = uid
        @uid_to_seq[uid]   = seqno
      end

      def advance_highestmodseq(modseq)
        return if modseq.nil? || @nomodseq
        if @highestmodseq.nil? || modseq > @highestmodseq
          @highestmodseq = modseq
        end
      end

      def sync_high_water
        [@uidnext&.-(1), @messages.keys.max].compact.max
      end

    end
  end
end
