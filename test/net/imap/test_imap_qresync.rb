# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPQResyncTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  QResyncResult          = Net::IMAP::QResyncResult
  QResyncRebuildRequired = Net::IMAP::QResyncRebuildRequired
  SequenceSet            = Net::IMAP::SequenceSet
  NoResponseError        = Net::IMAP::NoResponseError

  CHECKPOINT = {
    uidvalidity:   3857529045,
    highestmodseq: 1000,
    known_uids:    "1:10",
  }.freeze

  # RFC7162: ( QRESYNC ( uid-validity mod-sequence known-uids ) )
  EXPECTED_PARAMS = "(QRESYNC (3857529045 1000 1:10))".freeze

  # Scripts a SELECT/EXAMINE handler that speaks the QRESYNC resync dialect.
  # It asserts the client sent a (QRESYNC uidvalidity modseq known-uids)
  # parameter, emits the supplied untagged FETCH/VANISHED/EXISTS lines all
  # within the one command, then tags the command.
  def scripted_qresync_select(server, command:, lines:, status: :ok,
                             uidvalidity: CHECKPOINT[:uidvalidity],
                             highestmodseq: 5000, nomodseq: false,
                             expected_params: EXPECTED_PARAMS)
    server.on(command) do |resp|
      _name, *params = resp.args
      unless params.join(" ") == expected_params
        next resp.fail_bad("unexpected params: #{params.inspect}")
      end
      lines.each { |line| resp.untagged line }
      resp.untagged "OK [UIDVALIDITY #{uidvalidity}] UIDs valid"
      if nomodseq
        resp.untagged "OK [NOMODSEQ] no mod sequences"
      else
        resp.untagged "OK [HIGHESTMODSEQ #{highestmodseq}] highest"
      end
      case status
      when :ok then resp.done_ok(code: "READ-WRITE")
      when :no then resp.fail_no("resync rejected")
      else raise ArgumentError, status.inspect
      end
    end
  end

  def with_qresync_server
    with_fake_server(
      with_extensions: %i[ENABLE QRESYNC CONDSTORE],
      capabilities_enablable: %w[QRESYNC CONDSTORE]
    ) { |server, imap| yield server, imap }
  end

  test "#resync enables QRESYNC and sends the qresync select parameter" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "SELECT", lines: [])
      result = imap.resync("INBOX", **CHECKPOINT)
      assert_kind_of QResyncResult, result
      cmds = server.commands
      assert_equal "RUBY0001 ENABLE QRESYNC", cmds.pop.raw.strip
      assert_equal "RUBY0002 SELECT INBOX (QRESYNC (3857529045 1000 1:10))",
                   cmds.pop.raw.strip
    end
  end

  test "#resync returns deleted, updated, and missing buckets" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(
        server, command: "SELECT",
        lines: [
          "10 EXISTS",
          "* VANISHED (EARLIER) 2:3",
          '* 4 FETCH (UID 4 MODSEQ (12345) FLAGS (\\Seen))',
          '* 5 FETCH (UID 5 MODSEQ (12346) FLAGS (\\Flagged))',
          "* 9 FETCH (UID 11 MODSEQ (12347) FLAGS ())",
        ])

      result = imap.resync("INBOX", **CHECKPOINT)

      assert_kind_of QResyncResult, result
      assert_equal SequenceSet["2:3"], result.deleted_uids
      assert_equal [4, 5], result.updated.map(&:uid)
      assert_equal SequenceSet["11"], result.missing_uids
      assert_equal 5000, result.highestmodseq
      assert_equal 3857529045, result.uidvalidity
      assert_equal 10, result.exists
      assert_equal({uidvalidity: 3857529045, highestmodseq: 5000},
                   result.checkpoint)
      assert result.resyncable?
    end
  end

  test "large known-uid range is compressed and never expanded" do
    with_qresync_server do |server, imap|
      big = "1:4294967295"
      server.on("SELECT") do |resp|
        _name, *params = resp.args
        unless params.join(" ") == "(QRESYNC (3857529045 1000 #{big}))"
          next resp.fail_bad("unexpected params: #{params.inspect}")
        end
        resp.untagged "1 EXISTS"
        resp.untagged "OK [UIDVALIDITY 3857529045] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 1001] highest"
        resp.done_ok(code: "READ-WRITE")
      end
      result = imap.resync("INBOX", **CHECKPOINT, known_uids: big)
      assert_empty result.deleted_uids
      assert_empty result.updated
      assert_empty result.missing_uids
      assert_equal 1001, result.highestmodseq
    end
  end

  test "out-of-order flag changes are grouped by uid regardless of order" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(
        server, command: "SELECT",
        lines: [
          '* 3 FETCH (UID 9 MODSEQ (2003) FLAGS (\\Deleted))',
          '* 1 FETCH (UID 4 MODSEQ (2001) FLAGS (\\Seen))',
          "* VANISHED (EARLIER) 6",
          '* 2 FETCH (UID 7 MODSEQ (2002) FLAGS (\\Flagged))',
          "* VANISHED (EARLIER) 2",
          "* 4 FETCH (UID 12 MODSEQ (2004) FLAGS ())",
        ])
      result = imap.resync("INBOX", **CHECKPOINT)
      assert_equal SequenceSet["2,6"], result.deleted_uids
      assert_equal [9, 4, 7], result.updated.map(&:uid)
      assert_equal [2003, 2001, 2002], result.updated.map(&:modseq)
      assert_equal SequenceSet["12"], result.missing_uids
    end
  end

  test "current-session VANISHED (not EARLIER) is also merged by UID" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(
        server, command: "SELECT",
        lines: [
          "* VANISHED (EARLIER) 2",
          "* VANISHED 3",
          '* 4 FETCH (UID 4 MODSEQ (3000) FLAGS (\\Seen))',
        ])
      result = imap.resync("INBOX", **CHECKPOINT)
      assert_equal SequenceSet["2:3"], result.deleted_uids
      assert_equal [4], result.updated.map(&:uid)
      assert_empty result.missing_uids
    end
  end

  test "UIDVALIDITY change requires a rebuild and does not merge old UIDs" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "SELECT", lines: [],
                              uidvalidity: 999)
      error = assert_raise(QResyncRebuildRequired) do
        imap.resync("INBOX", **CHECKPOINT)
      end
      assert_equal 999, error.uidvalidity
      assert_match(/UIDVALIDITY changed/, error.message)
    end
  end

  test "NOMODSEQ requires a rebuild" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "SELECT", lines: [],
                              nomodseq: true)
      error = assert_raise(QResyncRebuildRequired) do
        imap.resync("INBOX", **CHECKPOINT)
      end
      assert_equal CHECKPOINT[:uidvalidity], error.uidvalidity
      assert_match(/NOMODSEQ/, error.message)
    end
  end

  test "SELECT failure leaves the prior checkpoint usable and no new one" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "SELECT", lines: [],
                              status: :no)
      assert_raise(NoResponseError) { imap.resync("INBOX", **CHECKPOINT) }

      # The connection is still usable and the old checkpoint still retries.
      scripted_qresync_select(
        server, command: "SELECT",
        lines: ["* VANISHED (EARLIER) 8"])
      result = imap.resync("INBOX", **CHECKPOINT)
      assert_equal SequenceSet["8"], result.deleted_uids
      assert_equal 5000, result.highestmodseq
    end
  end

  test "#examine is used when read_only is true" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "EXAMINE", lines: [])
      imap.resync("INBOX", **CHECKPOINT, read_only: true)
      cmds = server.commands
      assert_equal "RUBY0001 ENABLE QRESYNC", cmds.pop.raw.strip
      assert_equal "RUBY0002 EXAMINE INBOX (QRESYNC (3857529045 1000 1:10))",
                   cmds.pop.raw.strip
    end
  end

  test "#select with a qresync checkpoint returns a QResyncResult" do
    with_qresync_server do |server, imap|
      scripted_qresync_select(server, command: "SELECT",
                              lines: ["* VANISHED (EARLIER) 1"])
      result = imap.select("INBOX", qresync: CHECKPOINT)
      assert_kind_of QResyncResult, result
      assert_equal SequenceSet["1"], result.deleted_uids
    end
  end

  test "plain #select is unchanged and returns the tagged response" do
    with_qresync_server do |server, imap|
      tagged = imap.select("INBOX")
      assert_equal "OK", tagged.name
      assert_equal "RUBY0001 SELECT INBOX", server.commands.pop.raw.strip
    end
  end

end
