# frozen_string_literal: true

module Net
  class IMAP < Protocol

    # Experimental local view of one IMAP mailbox, keyed by UID.
    class MailboxView
      Message = Data.define(:uid, :flags, :modseq) do
        def initialize(uid:, flags:, modseq: nil)
          super(uid: Integer(uid),
                flags: flags&.dup&.freeze,
                modseq: modseq && Integer(modseq))
        end
      end

      Error = Class.new(Net::IMAP::Error)

      class Transaction
        attr_accessor :tag

        def initialize(view, state, qresync: false)
          @view = view
          @state = state
          @qresync = qresync
          @handled = false
        end

        def qresync? = @qresync
        def handled? = @handled
        def state = @state

        def finish(resp)
          @handled = true
          resp.name.upcase == "OK" ? commit : :aborted
        end

        def commit = state

        def handle_untagged(resp, qresync: qresync?)
          case resp
          in {name: "OK" | "NO", data: {code:}}
            handle_status_code(code)
          in {name: "EXISTS", data: Integer => count}
            set_exists(count)
          in {name: "FETCH" | "UIDFETCH", data:}
            apply_fetch(data)
          in {name: "EXPUNGE", data: Integer => seqno}
            apply_expunge(seqno)
          in {name: "VANISHED", data:}
            apply_vanished(data, qresync:)
          else
          end
        end

      private

        attr_reader :view

        def handle_status_code(code)
          case code.name.upcase
          when "UIDNEXT"
            state.uidnext = Integer(code.data)
          when "HIGHESTMODSEQ"
            value = Integer(code.data)
            state.server_highest_modseq = value
            state.modseq_supported = true
          when "NOMODSEQ"
            state.modseq_supported = false
            state.server_highest_modseq = nil
          end
        end

        def set_exists(count)
          state.exists = Integer(count)
          slots = state.slots
          slots.pop(slots.length - count) if slots.length > count
          if slots.length < count
            slots.concat(Array.new(count - slots.length)) if qresync?
            state.complete = false
          end
        end

        def apply_fetch(fetch)
          uid = uid_of(fetch)
          return unless uid
          uid = Integer(uid)
          modseq = normalized_modseq(fetch)
          state.modseq_supported = true unless modseq.nil?
          return unless update_message?(uid, fetch, modseq)
          state.messages[uid] = Message.new(
            uid: uid,
            flags: fetch.attr.key?("FLAGS") ? fetch.flags : current_flags(uid),
            modseq: modseq,
          )
          place_in_sequence(fetch, uid)
          advance_confirmed_modseq(modseq)
        end

        def uid_of(fetch)
          fetch.uid
        rescue NoMethodError
          nil
        end

        def update_message?(uid, fetch, modseq = normalized_modseq(fetch))
          current = state.messages[uid]
          modseq = normalized_modseq(fetch)
          if current.nil? && state.known_absent.include?(uid)
            raise Error, "FETCH reported known-absent UID #{uid}"
          end
          return true unless current
          if state.modseq_supported == false ||
             (state.modseq_supported.nil? && modseq.nil?)
            if fetch.attr.key?("FLAGS") && current.flags == fetch.flags
              view.note(uid, :duplicate)
              return false
            end
            true
          elsif modseq.nil?
            view.note(uid, :unversioned)
            false
          elsif modseq < current.modseq.to_i
            view.note(uid, :stale)
            false
          elsif current.modseq == modseq &&
                (!fetch.attr.key?("FLAGS") || current.flags == fetch.flags)
            view.note(uid, :duplicate)
            false
          elsif current.modseq == modseq
            view.note(uid, :conflict)
            false
          else
            true
          end
        end

        def normalized_modseq(fetch)
          state.modseq_supported == false ? nil : fetch.modseq
        end

        def current_flags(uid)
          state.messages[uid]&.flags&.dup || []
        end

        def place_in_sequence(fetch, uid)
          return unless fetch.is_a?(FetchData)
          seqno = fetch.seqno
          return unless seqno&.positive?
          if state.slots.length >= seqno
            state.slots[seqno - 1] = uid
          elsif seqno == state.slots.length + 1
            state.slots << uid
          end
          state.complete = complete_sequence?
        end

        def complete_sequence?
          length = [state.slots.length, state.exists.to_i].max
          length.zero? ||
            (state.slots.length >= length && state.slots.none?(&:nil?))
        end

        def advance_confirmed_modseq(modseq)
          return unless modseq && complete_sequence?
          state.confirmed_modseq = modseq if
            state.confirmed_modseq.nil? || modseq > state.confirmed_modseq
        end

        def apply_expunge(seqno)
          seqno = Integer(seqno)
          uid = state.slots.delete_at(seqno - 1)
          return view.note(seqno, :unknown) unless uid
          was_complete = state.complete
          state.exists -= 1
          remove_message(uid, absent: was_complete || state.slots.none?(&:nil?))
          state.complete = was_complete && complete_sequence?
          :expunged
        end

        def apply_vanished(vanished, qresync: qresync?)
          if vanished.earlier? && !qresync
            vanished.each { view.note(_1, :ignored_earlier) }
            return
          end
          vanished.each do |uid|
            state.slots.delete(uid)
            remove_message(uid, absent: true)
          end
        end

        def remove_message(uid, absent: false)
          if state.messages.delete(uid)
            state.known_absent.merge(uid) if absent
            :vanished
          elsif state.known_absent.include?(uid)
            view.note(uid, :duplicate)
          elsif absent
            state.known_absent.merge(uid)
            :absent
          else
            view.note(uid, :unknown)
          end
        end
      end

      class Selection < Transaction
        def initialize(...)
          super
          @expected_uidvalidity = nil
          @queued = []
          @resolved = false
        end

        def begin(qresync: nil)
          @expected_uidvalidity = qresync&.first
          @qresync = !!qresync
          state.uidvalidity = nil
          @resolved = false
        end

        def handle_untagged(resp)
          code = status_code(resp)
          if code&.name&.upcase == "UIDVALIDITY"
            resolve_identity(Integer(code.data))
            @queued.each { handle_queued(_1) }
            @queued.clear
          elsif state.uidvalidity.nil?
            @queued << resp
          else
            super
          end
        end

        def commit
          raise Error, "SELECT response is missing UIDVALIDITY" unless state.uidvalidity
          resize_slots
          strip_modseqs if state.modseq_supported == false
          if qresync?
            if state.server_highest_modseq &&
               state.server_highest_modseq < state.confirmed_modseq.to_i
              raise Error, "HIGHESTMODSEQ is below the confirmed boundary"
            end
            state.confirmed_modseq = [state.confirmed_modseq, state.server_highest_modseq].compact.max
            state.complete = sequence_complete?
          elsif state.modseq_supported == false
            state.confirmed_modseq = nil
            state.complete = false
          else
            state.complete = false
            state.confirmed_modseq = nil
          end
          state
        end

        private

        def handle_queued(resp)
          case resp
          in {name: "VANISHED", data:}
            apply_vanished(data, qresync: !@expected_uidvalidity.nil?)
          else
            Transaction.instance_method(:handle_untagged).bind_call(self, resp)
          end
        end

        def disable_modseq
          super
          @qresync = false
        end

        def status_code(resp)
          if resp in {name: "OK" | "NO", data: {code: _}}
            resp.data.code
          end
        end

        def resolve_identity(uidvalidity)
          return if @resolved
          @resolved = true
          same_identity = !@expected_uidvalidity.nil? &&
            @expected_uidvalidity == uidvalidity
          @qresync = @expected_uidvalidity == uidvalidity
          state.uidvalidity = uidvalidity
          state.reset(uidvalidity, modseq_supported: nil) unless same_identity
          state.uidvalidity = uidvalidity
          @queued.each { handle_queued(_1) }
          @queued.clear
        end

        def resize_slots
          count = state.exists.to_i
          state.slots.pop(state.slots.length - count) if state.slots.length > count
          state.slots.concat(Array.new(count - state.slots.length)) if
            state.slots.length < count
        end

        def strip_modseqs
          state.messages.each do |uid, message|
            next if message.modseq.nil?
            state.messages[uid] = Message.new(
              uid: uid, flags: message.flags, modseq: nil
            )
          end
        end

        def sequence_complete?
          state.slots.length == state.exists.to_i && state.slots.none?(&:nil?)
        end
      end

      class Snapshot < Transaction
        def initialize(...)
          super
          @fetches = []
        end

        def handle_untagged(resp)
          @fetches << resp.data if resp.name == "FETCH" || resp.name == "UIDFETCH"
          super
        end

        def fetches
          @fetches.dup
        end

        def commit
          @expected_exists = state.exists
          commit_fetches(@fetches)
        end

        private

        def commit_fetches(fetches)
          messages = {}
          fetches.each do |fetch|
            uid = fetch.uid or raise Error, "full FETCH snapshot is missing UID"
            flags = fetch.flags
            modseq = state.modseq_supported == false ? nil : fetch.modseq
            if state.modseq_supported && modseq.nil?
              raise Error, "full FETCH snapshot is missing MODSEQ"
            end
            state.modseq_supported = false if modseq.nil?
            messages[Integer(uid)] = Message.new(uid:, flags: flags || [], modseq:)
          end
          raise Error, "snapshot is not attached to a mailbox" unless state.uidvalidity
          state.messages = messages
          state.slots = messages.keys.sort
          state.exists = @expected_exists
          state.slots.concat(Array.new(@expected_exists - state.slots.length)) if
            state.slots.length < @expected_exists
          state.complete = @expected_exists == messages.length
          state.confirmed_modseq = state.modseq_supported == false ? nil :
            [state.server_highest_modseq, *messages.values.map(&:modseq)].compact.max
          state
        end
      end

      State = Struct.new(:uidvalidity, :uidnext, :exists, :modseq_supported,
                         :server_highest_modseq, :confirmed_modseq, :complete,
                         :messages, :known_absent, :slots, keyword_init: true) do
        def dup
          result = super
          result.messages = messages.dup
          result.known_absent = SequenceSet.new(known_absent)
          result.slots = slots.dup
          result
        end

        def reset(uidvalidity, modseq_supported:)
          self.uidvalidity = uidvalidity
          self.uidnext = nil
          self.exists = nil
          self.modseq_supported = modseq_supported
          self.server_highest_modseq = nil
          self.confirmed_modseq = nil
          self.complete = false
          self.messages = {}
          self.known_absent = SequenceSet.new
          self.slots = []
        end
      end

      def self.open(imap, mailbox, examine: false, enable: true)
        view = new
        view.open(imap, mailbox, examine: examine, enable: enable)
        view
      end

      def initialize
        @mutex = Mutex.new
        @state = initial_state
        @transaction = nil
        @transaction_handler = nil
        @imap = nil
        @handler = method(:handle_response).to_proc
        @notes = []
        @transaction_condition = ConditionVariable.new
      end

      def complete? = synchronize { @state.complete }
      def resynchronizable?
        synchronize { @state.uidvalidity && !@state.confirmed_modseq.nil? }
      end

      def modseq_supported?
        synchronize { @state.modseq_supported == true }
      end

      def highest_modseq
        synchronize { @state.confirmed_modseq }
      end

      def uidvalidity
        synchronize { @state.uidvalidity }
      end

      def uidnext
        synchronize { @state.uidnext }
      end

      def exists
        synchronize { @state.exists }
      end

      def [](uid)
        synchronize { @state.messages[Integer(uid)]&.dup }
      end

      def each_message(&block)
        return to_enum(__method__) unless block
        synchronize { @state.messages.each_value { block.call(_1.dup) } }
      end

      def known_uids
        synchronize { SequenceSet.new(@state.messages.keys) }
      end

      def known_absent?(uid)
        synchronize { @state.known_absent.include?(Integer(uid)) }
      end

      def known?(uid)
        synchronize do
          uid = Integer(uid)
          @state.messages.key?(uid) || @state.known_absent.include?(uid)
        end
      end

      def status(uid)
        synchronize do
          uid = Integer(uid)
          if @state.messages.key?(uid) then :present
          elsif @state.known_absent.include?(uid) then :absent
          else :unknown
          end
        end
      end

      def attach(imap)
        synchronize do
          detach_locked if @imap && @imap != imap
          @imap = imap
          @attached_handlers ||= []
          unless @attached_handlers.include?(@handler)
            add_response_handler(imap, @handler)
          end
          self
        end
      end

      def detach
        synchronize { detach_locked }
      end

      def open(imap, mailbox, examine: false, enable: true)
        attach(imap)
        imap.enable("QRESYNC") if enable && imap.capable?("QRESYNC")
        known_uids = self.known_uids
        if enable && @state.uidvalidity && !@state.confirmed_modseq.nil? &&
           !known_uids.empty?
          select(imap, mailbox, examine: examine,
                 qresync: [@state.uidvalidity, @state.confirmed_modseq, known_uids])
        elsif @state.modseq_supported == false
          select(imap, mailbox, examine: examine)
        else
          select(imap, mailbox, examine: examine, condstore: true)
        end
        full_snapshot!(imap) unless complete?
        self
      end

      def select(imap, mailbox, examine: false, condstore: false, qresync: nil)
        transaction = synchronize do
          selection = Selection.new(self, @state.dup)
          selection.begin(qresync: qresync)
          @transaction = selection
          selection
        end
        run_transaction(transaction) do
          if examine
            imap.examine(mailbox, condstore: condstore, qresync: qresync)
          else
            imap.select(mailbox, condstore: condstore, qresync: qresync)
          end
        end
      end

      def full_snapshot!(imap)
        attrs = %w[UID FLAGS]
        attrs << "MODSEQ" unless synchronize { @state.modseq_supported == false }
        transaction = Snapshot.new(self, @state.dup)
        synchronize { @transaction = transaction }
        run_transaction(transaction) do
          imap.uid_fetch(1.., attrs)
        end
        synchronize { transaction.fetches }
      end

      def handle_response(resp)
        synchronize do
          return unless resp.is_a?(UntaggedResponse) || resp.is_a?(TaggedResponse)
          return if @transaction_handler
          transaction = @transaction
          if transaction
            if resp.is_a?(TaggedResponse)
              finish_transaction(transaction, resp) if transaction.tag.nil? ||
                transaction.tag == resp.tag
            elsif !transaction.handled?
              transaction.handle_untagged(resp)
            end
          elsif resp.is_a?(UntaggedResponse)
            Transaction.new(self, @state).handle_untagged(resp)
          end
        rescue Exception
          @transaction = nil
          raise
        end
      end

      def notes
        synchronize { @notes.dup }
      end

      def note(key, reason)
        @notes << [key, reason]
        reason
      end

      private

      def wait_for_transaction(transaction)
        synchronize do
          @transaction_condition.wait(@mutex) while @transaction.equal?(transaction)
        end
      end

      def run_transaction(transaction)
        handler = nil
        handler = proc do |resp|
          synchronize do
            next unless @transaction.equal?(transaction)
            if resp.is_a?(TaggedResponse)
              transaction.tag = resp.tag
              finish_transaction(transaction, resp)
            else
              transaction.handle_untagged(resp)
            end
          end
        end
        synchronize { @transaction_handler = handler }
        add_priority_response_handler(handler)
        result = yield
        wait_for_transaction(transaction)
        result
      ensure
        @imap&.remove_response_handler(handler)
        synchronize { @transaction_handler = nil if @transaction_handler.equal?(handler) }
      end

      def finish_transaction(transaction, resp)
        return if transaction.handled?
        result = transaction.finish(resp)
        return discard_transaction if result == :aborted
        @state = result
        @transaction = nil
        @transaction_condition.broadcast
      rescue Exception
        @transaction = nil
        @transaction_condition.broadcast
        raise
      end

      def discard_transaction
        @transaction = nil
        @transaction_condition.broadcast
      end

      def initial_state
        State.new(
          uidvalidity: nil, uidnext: nil, exists: nil,
          modseq_supported: nil, server_highest_modseq: nil,
          confirmed_modseq: nil, complete: false,
          messages: {}, known_absent: SequenceSet.new, slots: []
        )
      end

      def synchronize(&block) = @mutex.synchronize(&block)

      def detach_locked
        @attached_handlers&.each do |handler|
          @imap&.remove_response_handler(handler)
        end
        @imap = nil
      end

      def add_response_handler(imap, handler)
        @attached_handlers << handler
        imap.add_response_handler(handler)
      end

      def add_priority_response_handler(handler)
        @attached_handlers.unshift(handler)
        @imap.add_response_handler(handler, priority: true)
      end
    end

  end
end
