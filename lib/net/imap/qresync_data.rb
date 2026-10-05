# frozen_string_literal: true

module Net
  class IMAP < Protocol

    # Parameters for a QRESYNC-enabled SELECT or EXAMINE command.
    # See Net::IMAP#resynchronize, Net::IMAP#select, Net::IMAP#examine, and
    # {RFC 7162}[https://www.rfc-editor.org/rfc/rfc7162.html].
    class QResyncParameters < Data.define(:uidvalidity, :modseq, :known_uids)
      def initialize(uidvalidity:, modseq:, known_uids: SequenceSet.empty)
        uidvalidity = Integer(uidvalidity)
        modseq      = Integer(modseq)
        known_uids  = SequenceSet.new(known_uids)
        if uidvalidity <= 0
          raise ArgumentError, "uidvalidity must be positive"
        end
        if modseq.negative?
          raise ArgumentError, "modseq must not be negative"
        end
        super(uidvalidity:, modseq:, known_uids:)
      end

      # Coerces +value+ into QResyncParameters.  A QResyncCheckpoint may also
      # be passed directly.
      def self.coerce(value)
        case value
        when QResyncParameters then value
        when QResyncCheckpoint
          new(uidvalidity: value.uidvalidity,
              modseq:      value.modseq,
              known_uids:  value.known_uids)
        else
          raise ArgumentError,
                "expected QResyncParameters or QResyncCheckpoint, got #{value.class}"
        end
      end

      # Returns the arguments sent in the QRESYNC parenthesized list.
      def to_command_args
        args = ["QRESYNC", uidvalidity, modseq]
        args << known_uids unless known_uids.empty?
        args
      end
    end

    # A successful QRESYNC checkpoint.  Persist an instance only after the
    # resynchronization command has completed successfully.
    class QResyncCheckpoint < Data.define(:uidvalidity, :modseq, :known_uids)
      def initialize(uidvalidity:, modseq:, known_uids:)
        known_uids = SequenceSet.new(known_uids).freeze
        super(uidvalidity: Integer(uidvalidity),
              modseq:      Integer(modseq),
              known_uids:)
      end
    end

    # Result returned by Net::IMAP#resynchronize and by Net::IMAP#select or
    # Net::IMAP#examine when their +qresync+ parameter is used.
    class QResyncResult < Data.define(
      :status, :deleted, :updated, :missing, :vanished,
      :expunged, :exists, :checkpoint, :reason
    )
      def initialize(status:, deleted: SequenceSet.empty, updated: [],
                     missing: SequenceSet.empty, vanished: SequenceSet.empty,
                     expunged: [], exists: nil,
                     checkpoint: nil, reason: nil)
        deleted  = SequenceSet.new(deleted).freeze
        missing  = SequenceSet.new(missing).freeze
        vanished = SequenceSet.new(vanished).freeze
        super(status: status.to_sym, deleted:, updated: updated.freeze,
              missing:, vanished:, expunged: expunged.freeze, exists:,
              checkpoint:, reason:)
      end

      # Creates a successful resynchronization result.
      def self.ok(deleted:, updated:, missing:, vanished:, expunged:, exists:, checkpoint:)
        new(status: :ok,
            deleted:, updated:, missing:, vanished:, expunged:, exists:,
            checkpoint:)
      end

      # Creates a result which requires a complete mailbox rebuild.  The old
      # UID set must not be merged with the new mailbox state.
      def self.rebuild(reason)
        new(status: :rebuild, reason: reason.to_sym)
      end

      # Returns true when the mailbox can be updated incrementally.
      def ok?; status == :ok end

      # Returns true when the local mailbox cache must be discarded.
      def rebuild?; status == :rebuild end
      alias rebuild_required? rebuild?
    end

  end
end
