# frozen_string_literal: true

module Net
  class IMAP < Protocol

    # Net::IMAP::QResyncResult represents the result of a quick mailbox
    # resynchronization, as performed by Net::IMAP#resync (or by
    # Net::IMAP#select/Net::IMAP#examine with a <tt>qresync:</tt> parameter).
    #
    # It is described by the
    # {QRESYNC}[https://www.rfc-editor.org/rfc/rfc7162.html] extension,
    # [{RFC7162 §3.2.7}[https://www.rfc-editor.org/rfc/rfc7162.html#section-3.2.7]].
    #
    # The result categorizes every change the server reported into three,
    # mutually exclusive buckets:
    #
    # * #deleted_uids  — messages the caller should remove from its cache.
    # * #updated       — FetchData for messages whose flags/modseq changed.
    # * #missing_uids  — UIDs the caller must fetch with a separate
    #   Net::IMAP#uid_fetch request.
    #
    # The #checkpoint attributes (#uidvalidity and #highestmodseq) should be
    # persisted _only_ after the changes above have been applied and (when
    # applicable) the #missing_uids have been fetched.
    class QResyncResult < Data.define(
      :uidvalidity, :highestmodseq,
      :deleted_uids, :updated, :missing_uids,
      :exists,
    )

      # Returns a new QResyncResult.
      #
      # * +uidvalidity+ is the mailbox's UIDVALIDITY as returned by the server.
      # * +highestmodseq+ is the mailbox's HIGHESTMODSEQ as returned by the
      #   server (+nil+ only when the mailbox does not support mod-sequences).
      # * +deleted_uids+ is converted to a SequenceSet.
      # * +updated+ is an Array of FetchData.
      # * +missing_uids+ is converted to a SequenceSet.
      def initialize(uidvalidity:, highestmodseq:, deleted_uids:, updated:,
                     missing_uids:, exists: nil)
        deleted_uids = SequenceSet[deleted_uids] unless deleted_uids.is_a?(SequenceSet)
        missing_uids = SequenceSet[missing_uids] unless missing_uids.is_a?(SequenceSet)
        updated = Array(updated).freeze
        super(uidvalidity: Integer(uidvalidity),
              highestmodseq: highestmodseq && Integer(highestmodseq),
              deleted_uids: deleted_uids.freeze,
              updated: updated,
              missing_uids: missing_uids.freeze,
              exists: exists && Integer(exists))
      end

      ##
      # :attr_reader: uidvalidity
      #
      # The UIDVALIDITY of the selected mailbox.  Persist this with
      # #highestmodseq as the checkpoint for the next #resync.

      ##
      # :attr_reader: highestmodseq
      #
      # The HIGHESTMODSEQ of the selected mailbox, or +nil+ when the mailbox
      # does not support persistent mod-sequences.  Persist this with
      # #uidvalidity as the checkpoint for the next #resync.

      ##
      # :attr_reader: deleted_uids
      #
      # A SequenceSet of UIDs that have been permanently removed from the
      # mailbox since the checkpoint.  These UIDs should be deleted from the
      # caller's local cache.
      #
      # Both <tt>VANISHED (EARLIER)</tt> UIDs (messages removed before the
      # SELECT/EXAMINE) and any UIDs expunged during the resynchronization are
      # merged here.  _All values are UIDs_, never message sequence numbers.

      ##
      # :attr_reader: updated
      #
      # An Array of FetchData, one for every message the server reported with a
      # MODSEQ greater than the checkpoint (including out-of-order flag
      # updates).  Apply these flag/label updates to the local cache.

      ##
      # :attr_reader: missing_uids
      #
      # A SequenceSet of UIDs the server reported (via +FETCH+) that were not
      # part of the resync's +known-uids+ — i.e. messages that arrived after
      # the checkpoint and are not yet in the caller's cache.  Fetch these
      # in full with Net::IMAP#uid_fetch before persisting the #checkpoint.

      ##
      # :attr_reader: exists
      #
      # The mailbox's current message count from the last +EXISTS+ response
      # received during the resynchronization, or +nil+ if none was sent.

      # Returns +true+ when the mailbox can be used as the starting point for a
      # future #resync (i.e. it has a #highestmodseq).
      def resyncable? = !highestmodseq.nil?

      # Returns the values to persist for the next #resync, or +nil+ when the
      # mailbox cannot be resynchronized (see #resyncable?).
      def checkpoint
        return nil unless resyncable?
        {uidvalidity: uidvalidity, highestmodseq: highestmodseq}
      end

    end

  end
end
