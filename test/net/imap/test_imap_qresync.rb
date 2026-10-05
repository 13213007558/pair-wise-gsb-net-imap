# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPQResyncTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  UID_MAX = 2**32 - 1

  def with_qresync_server(&block)
    with_fake_server(
      with_extensions: %i[ENABLE CONDSTORE QRESYNC],
      capabilities_enablable: %w[QRESYNC],
      &block
    )
  end

  test "resynchronize keeps large UID ranges compressed" do
    with_qresync_server do |server, imap|
      known_uids = Net::IMAP::SequenceSet["1:#{UID_MAX - 2}"]

      server.on "SELECT" do |resp|
        resp.untagged "4 EXISTS"
        resp.untagged "3 FETCH (UID 5 FLAGS (\\Seen) MODSEQ (101))"
        resp.untagged "VANISHED (EARLIER) 2:3"
        resp.untagged "4 FETCH (UID #{UID_MAX - 1} FLAGS (\\Answered) MODSEQ (102))"
        resp.untagged "5 FETCH (UID #{UID_MAX} FLAGS (\\Draft) MODSEQ (103))"
        resp.untagged "OK [UIDVALIDITY 42] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 103] Highest"
        resp.done_ok
      end

      result = imap.resynchronize(
        "inbox",
        uidvalidity: 42,
        modseq:      100,
        known_uids:  known_uids,
      )

      assert result.ok?
      assert_equal [2..3], result.deleted.ranges
      assert_equal [5, UID_MAX - 1], result.updated.map(&:uid)
      assert_equal [UID_MAX..UID_MAX], result.missing.ranges
      assert_equal "1:#{UID_MAX - 1}", known_uids.to_s
      assert_equal [1..1, 4..UID_MAX], result.checkpoint.known_uids.ranges
      assert_equal 103, result.checkpoint.modseq
      assert_equal 4, result.exists

      assert_equal "RUBY0001 ENABLE QRESYNC",
                   server.commands.pop.raw.strip
      assert_equal "RUBY0002 SELECT inbox (QRESYNC 42 100 1:#{UID_MAX - 2})",
                   server.commands.pop.raw.strip
    end
  end

  test "out-of-order flag updates and current-session deletions are merged" do
    with_qresync_server do |server, imap|
      server.on "SELECT" do |resp|
        resp.untagged "9 EXISTS"
        resp.untagged "2 FETCH (UID 5 FLAGS (\\Answered) MODSEQ (102))"
        resp.untagged "1 FETCH (UID 9 FLAGS () MODSEQ (103))"
        resp.untagged "VANISHED 6"
        resp.untagged "3 FETCH (UID 5 FLAGS (\\Seen) MODSEQ (104))"
        resp.untagged "4 FETCH (UID 9 FLAGS (\\Draft) MODSEQ (105))"
        resp.untagged "OK [UIDVALIDITY 42] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 106] Highest"
        resp.done_ok
      end

      result = imap.resynchronize(
        "inbox",
        uidvalidity: 42,
        modseq:      100,
        known_uids:  Net::IMAP::SequenceSet["1:10"],
      )

      assert result.ok?
      assert_empty result.deleted
      assert_equal [6..6], result.vanished.ranges
      assert_equal [5, 9], result.updated.map(&:uid)
      assert_equal [:Seen], result.updated.first.flags
      assert_equal [:Draft], result.updated.last.flags
      assert_equal 106, result.checkpoint.modseq
      assert_empty result.missing
      assert_equal [1..5, 7..10], result.checkpoint.known_uids.ranges
    end
  end

  test "NOMODSEQ requires rebuilding" do
    with_qresync_server do |server, imap|
      server.on "SELECT" do |resp|
        resp.untagged "OK [UIDVALIDITY 42] UIDs valid"
        resp.untagged "OK [NOMODSEQ] No modsequences"
        resp.done_ok
      end

      result = imap.resynchronize(
        "inbox",
        uidvalidity: 42,
        modseq:      100,
        known_uids:  Net::IMAP::SequenceSet["1:10"],
      )

      assert result.rebuild_required?
      assert_equal :nomodseq, result.reason
      assert_nil result.checkpoint
      assert_empty result.deleted
      assert_empty result.updated
    end
  end

  test "UIDVALIDITY changes require rebuilding" do
    with_qresync_server do |server, imap|
      server.on "SELECT" do |resp|
        resp.untagged "OK [UIDVALIDITY 43] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 100] Highest"
        resp.done_ok
      end

      result = imap.resynchronize(
        "inbox",
        uidvalidity: 42,
        modseq:      100,
        known_uids:  Net::IMAP::SequenceSet["1:10"],
      )

      assert result.rebuild_required?
      assert_equal :uidvalidity_changed, result.reason
      assert_nil result.checkpoint
      assert_empty result.deleted
      assert_empty result.updated
    end
  end

  test "failed SELECT does not publish a checkpoint and old checkpoint is reusable" do
    with_qresync_server do |server, imap|
      checkpoint = Net::IMAP::QResyncCheckpoint.new(
        uidvalidity: 42,
        modseq:      100,
        known_uids:  Net::IMAP::SequenceSet["1:10"],
      )

      server.on "SELECT" do |resp|
        resp.fail_no "mailbox temporarily unavailable"
      end

      assert_raise(Net::IMAP::NoResponseError) do
        imap.resynchronize("inbox", checkpoint)
      end
      assert server.state.authenticated?

      server.on "SELECT" do |resp|
        resp.untagged "10 EXISTS"
        resp.untagged "OK [UIDVALIDITY 42] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 101] Highest"
        resp.done_ok
      end

      result = imap.resynchronize("inbox", checkpoint, enable: false)

      assert result.ok?
      assert_equal 101, result.checkpoint.modseq
      assert_equal checkpoint.known_uids, result.checkpoint.known_uids
      assert_equal [1..10], result.checkpoint.known_uids.ranges

      assert_equal "RUBY0001 ENABLE QRESYNC",
                   server.commands.pop.raw.strip
      assert_match(/RUBY0002 SELECT inbox .*QRESYNC 42 100 1:10/,
                   server.commands.pop.raw)
      assert_match(/RUBY0003 SELECT inbox .*QRESYNC 42 100 1:10/,
                   server.commands.pop.raw)
    end
  end

  test "EXAMINE accepts QRESYNC parameters" do
    with_qresync_server do |server, imap|
      imap.enable("QRESYNC")
      server.commands.pop

      checkpoint = Net::IMAP::QResyncCheckpoint.new(
        uidvalidity: 42,
        modseq:      100,
        known_uids:  Net::IMAP::SequenceSet["1:10"],
      )

      server.on "EXAMINE" do |resp|
        resp.untagged "10 EXISTS"
        resp.untagged "OK [UIDVALIDITY 42] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 101] Highest"
        resp.done_ok code: "READ-ONLY"
      end

      result = imap.examine("inbox", qresync: checkpoint)

      assert result.ok?
      assert_equal "RUBY0002 EXAMINE inbox (QRESYNC 42 100 1:10)",
                   server.commands.pop.raw.strip
    end
  end

end
