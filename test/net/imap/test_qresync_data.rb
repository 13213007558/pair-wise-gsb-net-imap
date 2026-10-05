# frozen_string_literal: true

require "net/imap"
require "test/unit"

class QResyncDataTest < Net::IMAP::TestCase
  QResyncResult           = Net::IMAP::QResyncResult
  QResyncRebuildRequired  = Net::IMAP::QResyncRebuildRequired
  SequenceSet             = Net::IMAP::SequenceSet

  def build_result(responses, checkpoint_uids: "1:10",
                   uidvalidity: 3857529045, highestmodseq: 1000)
    imap = Net::IMAP.allocate
    imap.send(:mon_initialize)
    bucket = Hash.new { |h, k| h[k] = [] }
    imap.instance_variable_set(:@responses, bucket)
    parser = Net::IMAP::ResponseParser.new
    responses.each do |line|
      resp = parser.parse(line.b)
      bucket[resp.name] << resp.data
      if resp.data.is_a?(Net::IMAP::ResponseText) && resp.data.code
        bucket[resp.data.code.name] << resp.data.code.data
      end
    end
    checkpoint = imap.send(
      :normalize_qresync_checkpoint,
      uidvalidity: uidvalidity,
      highestmodseq: highestmodseq,
      known_uids: checkpoint_uids,
    )
    imap.send(:build_qresync_result, checkpoint)
  end

  test "partitions FETCH into updated and missing and merges VANISHED" do
    result = build_result([
      "* 10 EXISTS\r\n",
      "* VANISHED (EARLIER) 2:3\r\n",
      '* 4 FETCH (UID 4 MODSEQ (12345) FLAGS (\\Seen))' + "\r\n",
      "* VANISHED 10\r\n",
      "* 9 FETCH (UID 11 MODSEQ (12347) FLAGS ())\r\n",
      "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n",
      "* OK [HIGHESTMODSEQ 5000] h\r\n",
    ])
    assert_equal SequenceSet["2:3,10"], result.deleted_uids
    assert_equal [4], result.updated.map(&:uid)
    assert_equal SequenceSet["11"], result.missing_uids
    assert_equal 5000, result.highestmodseq
    assert_equal 10, result.exists
    assert_equal({uidvalidity: 3857529045, highestmodseq: 5000},
                 result.checkpoint)
  end

  test "out-of-order FETCH responses are grouped independent of order" do
    result = build_result([
      "* 3 FETCH (UID 9 MODSEQ (2003) FLAGS (\\Deleted))\r\n",
      "* 1 FETCH (UID 4 MODSEQ (2001) FLAGS (\\Seen))\r\n",
      "* VANISHED (EARLIER) 6\r\n",
      "* 2 FETCH (UID 7 MODSEQ (2002) FLAGS (\\Flagged))\r\n",
      "* VANISHED (EARLIER) 2\r\n",
      "* 4 FETCH (UID 12 MODSEQ (2004) FLAGS ())\r\n",
      "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n",
      "* OK [HIGHESTMODSEQ 5000] h\r\n",
    ])
    assert_equal SequenceSet["2,6"], result.deleted_uids
    assert_equal [9, 4, 7], result.updated.map(&:uid)
    assert_equal [2003, 2001, 2002], result.updated.map(&:modseq)
    assert_equal SequenceSet["12"], result.missing_uids
  end

  test "a huge known-uid range never expands and covers new members" do
    big = "1:4294967295"
    result = build_result([
      "* 5 FETCH (UID 4294967290 MODSEQ (1) FLAGS ())\r\n",
      "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n",
      "* OK [HIGHESTMODSEQ 1001] h\r\n",
    ], checkpoint_uids: big)
    assert_equal [4294967290], result.updated.map(&:uid)
    assert_empty result.missing_uids
    assert_empty result.deleted_uids
  end

  test "UIDVALIDITY change raises rebuild and ignores the old UIDs" do
    error = assert_raise(QResyncRebuildRequired) do
      build_result([
        "* VANISHED (EARLIER) 1\r\n",
        "* 2 FETCH (UID 4 MODSEQ (1) FLAGS ())\r\n",
        "* OK [UIDVALIDITY 999] UIDs valid\r\n",
        "* OK [HIGHESTMODSEQ 5000] h\r\n",
      ])
    end
    assert_equal 999, error.uidvalidity
    assert_match(/UIDVALIDITY changed/, error.message)
  end

  test "NOMODSEQ raises rebuild" do
    error = assert_raise(QResyncRebuildRequired) do
      build_result([
        "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n",
        "* OK [NOMODSEQ] no modseq\r\n",
      ])
    end
    assert_equal 3857529045, error.uidvalidity
    assert_match(/NOMODSEQ/, error.message)
  end

  test "missing HIGHESTMODSEQ (without NOMODSEQ) raises rebuild" do
    assert_raise(QResyncRebuildRequired) do
      build_result([
        "* OK [UIDVALIDITY 3857529045] UIDs valid\r\n",
      ])
    end
  end

  test "QResyncResult coerces and freezes its fields" do
    result = QResyncResult.new(
      uidvalidity: "7", highestmodseq: "9",
      deleted_uids: "1:3", updated: [], missing_uids: "5")
    assert_equal 7, result.uidvalidity
    assert_equal 9, result.highestmodseq
    assert_equal SequenceSet["1:3"], result.deleted_uids
    assert_equal SequenceSet["5"], result.missing_uids
    assert result.deleted_uids.frozen?
    assert result.updated.frozen?
    assert result.resyncable?
  end

  test "checkpoint is nil without a highestmodseq" do
    result = QResyncResult.new(
      uidvalidity: 7, highestmodseq: nil,
      deleted_uids: SequenceSet.new, updated: [], missing_uids: SequenceSet.new)
    refute result.resyncable?
    assert_nil result.checkpoint
  end

  test "normalizing a checkpoint compresses known UIDs into ranges" do
    imap = Net::IMAP.allocate
    cp = imap.send(:normalize_qresync_checkpoint,
                   uidvalidity: 1, highestmodseq: 2,
                   known_uids: [1, 2, 3, 4, 5])
    assert_equal SequenceSet["1:5"], cp[:known_uids]
  end

end
