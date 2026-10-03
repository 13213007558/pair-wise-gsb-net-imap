# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "../../lib/helper"
require_relative "fake_server"

class MailboxViewTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  def select_response(server, uidvalidity:, exists:, uidnext:, highest:)
    server.on("SELECT", "EXAMINE") do |resp|
      resp.untagged "#{exists} EXISTS"
      resp.untagged "OK [UIDVALIDITY #{uidvalidity}] UIDs valid"
      resp.untagged "OK [UIDNEXT #{uidnext}] next"
      if highest
        resp.untagged "OK [HIGHESTMODSEQ #{highest}] current"
      else
        resp.untagged "OK [NOMODSEQ] no modseq"
      end
      resp.untagged "FLAGS (\\Seen \\Deleted)"
      resp.untagged "OK [PERMANENTFLAGS (\\Seen \\Deleted *)]"
      resp.done_ok code: "READ-WRITE"
    end
  end

  def uid_fetch_response(server, messages)
    server.on("UID FETCH") do |resp|
      messages.each do |uid, flags, modseq|
        flags = flags.map { "\\#{_1.to_s.delete_prefix(?\\)}" }.join(" ")
        modseq = " MODSEQ (#{modseq})" if modseq
        resp.untagged "1 FETCH (UID #{uid} FLAGS (#{flags})#{modseq})"
      end
      resp.done_ok
    end
  end

  test "builds a complete UID snapshot and preserves unknown UIDs" do
    with_fake_server(with_extensions: %i[QRESYNC CONDSTORE],
                     capabilities_enablable: %w[QRESYNC]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 3, uidnext: 6, highest: 10)
      uid_fetch_response(server, [
        [1, %i[Seen], 3],
        [2, [], 4],
        [4, %i[Deleted], 5],
      ])
      view = Net::IMAP::MailboxView.open(imap, "INBOX")
      server.commands.clear
      assert_equal 10, view.highest_modseq
      parser = Net::IMAP::ResponseParser.new
      view.handle_response(
        parser.parse("* 1 FETCH (UID 1 FLAGS (\\Deleted) MODSEQ (9))\r\n")
      )
      view.handle_response(
        parser.parse("* 1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (3))\r\n")
      )
      assert_equal %i[Deleted], view[1].flags
      reasons = view.notes.map(&:last)
      assert_include reasons, :stale
      view.handle_response(
        parser.parse("* 1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (11))\r\n")
      )
      view.handle_response(
        parser.parse("* 1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (11))\r\n")
      )
      assert_include view.notes.map(&:last), :duplicate

      assert_equal [:present, :unknown, :unknown], [1, 3, 7].map { view.status(_1) }
      assert_equal %i[Seen], view[1].flags
      assert_equal :unknown, view.status(3)
      assert_equal :unknown, view.status(6)
    end
  end

  test "consumes interleaved FETCH, EXPUNGE, and VANISHED updates" do
    with_fake_server(with_extensions: %i[QRESYNC CONDSTORE],
                     capabilities_enablable: %w[QRESYNC]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 3, uidnext: 6, highest: 10)
      uid_fetch_response(server, [
        [1, [], 10], [2, %i[Seen], 10], [4, [], 10]
      ])
      view = Net::IMAP::MailboxView.open(imap, "INBOX")
      server.commands.clear

      server.on("NOOP") do |resp|
        resp.untagged "3 FETCH (UID 4 FLAGS (\\Seen \\Deleted) MODSEQ (13))"
        resp.untagged "VANISHED 4"
        resp.untagged "2 FETCH (UID 2 FLAGS (\\Seen \\Answered) MODSEQ (14))"
        resp.untagged "1 EXPUNGE"
        resp.untagged "2 EXISTS"
        resp.done_ok
      end
      imap.noop

      server.on("UID FETCH") do |resp|
        resp.untagged "1 FETCH (UID 2 FLAGS (\\Seen \\Answered) MODSEQ (14))"
        resp.untagged "2 FETCH (UID 5 FLAGS (\\Draft) MODSEQ (15))"
        resp.done_ok
      end
      complete = imap.uid_fetch(1.., %w[UID FLAGS MODSEQ])
      view.full_snapshot!(imap) unless view.complete?

      expected = complete.to_h { [_1.uid, _1.flags] }
      actual = view.each_message.to_h { [_1.uid, _1.flags] }
      assert_equal expected, actual
      assert_equal [:absent, :present, :absent, :present],
                   [1, 2, 4, 5].map { view.status(_1) }
    end
  end

  test "resynchronizes from the confirmed boundary and consumes EARLIER" do
    with_fake_server(with_extensions: %i[QRESYNC CONDSTORE],
                     capabilities_enablable: %w[QRESYNC]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 3, uidnext: 6, highest: 10)
      uid_fetch_response(server, [
        [1, [], 10], [2, %i[Seen], 10], [4, [], 10]
      ])
      view = Net::IMAP::MailboxView.open(imap, "INBOX")
      server.commands.clear

      server.on("SELECT", "EXAMINE") do |resp|
        resp.untagged "OK [UIDVALIDITY 42] same"
        resp.untagged "OK [HIGHESTMODSEQ 12] current"
        resp.untagged "VANISHED (EARLIER) 1,4"
        resp.untagged "1 FETCH (UID 2 FLAGS (\\Seen \\Answered) MODSEQ (11))"
        resp.untagged "2 FETCH (UID 5 FLAGS (\\Draft) MODSEQ (12))"
        resp.untagged "2 EXISTS"
        resp.done_ok
      end
      view.open(imap, "INBOX")

      assert_equal "RUBY0004 ENABLE QRESYNC",
                   server.commands.pop.raw.strip
      assert_equal "RUBY0005 SELECT INBOX (QRESYNC 42 10 1:2,4)",
                   server.commands.pop.raw.strip
      assert view.complete?
      assert_equal 12, view.highest_modseq
      assert_equal [:absent, :present, :absent, :present],
                   [1, 2, 4, 5].map { view.status(_1) }

      uid_fetch_response(server, [
        [2, %i[Seen Answered], 11],
        [5, %i[Draft], 12],
      ])
      complete = imap.uid_fetch(1.., %w[UID FLAGS MODSEQ])
      expected = complete.to_h { [_1.uid, _1.flags] }
      actual = view.each_message.to_h { [_1.uid, _1.flags] }
      assert_equal expected, actual
    end
  end

  test "uses only a confirmed boundary for QRESYNC and discards failed work" do
    with_fake_server(with_extensions: %i[QRESYNC CONDSTORE],
                     capabilities_enablable: %w[QRESYNC]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 2, uidnext: 3, highest: 10)
      uid_fetch_response(server, [[1, [], 10], [2, %i[Seen], 10]])
      view = Net::IMAP::MailboxView.open(imap, "INBOX")
      assert_equal 10, view.highest_modseq

      server.on("SELECT") do |resp|
        resp.untagged "1 FETCH (UID 2 FLAGS (\\Seen \\Deleted) MODSEQ (999))"
        resp.fail_no "temporarily unavailable"
      end
      assert_raise(Net::IMAP::NoResponseError) do
        view.select(imap, "INBOX", qresync: [42, 10, [1, 2]])
      end
      assert_equal 10, view.highest_modseq
      assert_equal %i[Seen], view[2].flags
      assert_equal "RUBY0001 ENABLE QRESYNC",
                   server.commands.pop.raw.strip
      assert_equal "RUBY0002 SELECT INBOX (CONDSTORE)",
                   server.commands.pop.raw.strip
      assert_equal "RUBY0003 UID FETCH 1:* (UID FLAGS MODSEQ)",
                   server.commands.pop.raw.strip
      assert_equal "RUBY0004 SELECT INBOX (QRESYNC 42 10 1:2)",
                   server.commands.pop.raw.strip
    end
  end

  test "discards old identity when UIDVALIDITY changes" do
    with_fake_server(with_extensions: %i[QRESYNC CONDSTORE],
                     capabilities_enablable: %w[QRESYNC]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 1, uidnext: 2, highest: 10)
      uid_fetch_response(server, [[1, [], 10]])
      view = Net::IMAP::MailboxView.open(imap, "INBOX")

      select_response(server, uidvalidity: 43, exists: 1, uidnext: 9, highest: 1)
      uid_fetch_response(server, [[8, %i[Draft], 1]])
      view.open(imap, "INBOX", enable: false)

      assert_equal 43, view.uidvalidity
      assert_equal :unknown, view.status(1)
      assert_equal :present, view.status(8)
      assert_equal 1, view.highest_modseq
    end
  end

  test "handles NOMODSEQ, stale updates, duplicate VANISHED, and VANISHED EARLIER" do
    with_fake_server(with_extensions: %i[CONDSTORE]) do |server, imap|
      select_response(server, uidvalidity: 42, exists: 2, uidnext: 3, highest: nil)
      uid_fetch_response(server, [[1, []], [2, %i[Seen]]])
      view = Net::IMAP::MailboxView.open(imap, "INBOX", enable: false)
      assert_nil view.highest_modseq
      server.commands.clear

      view.open(imap, "INBOX", enable: false)
      assert_equal "RUBY0003 SELECT INBOX", server.commands.pop.raw.strip
      assert_nil view.highest_modseq

      parser = Net::IMAP::ResponseParser.new
      view.handle_response(parser.parse("* 1 FETCH (UID 1 FLAGS (\\Seen))\r\n"))
      view.handle_response(parser.parse("* 1 FETCH (UID 1 FLAGS (\\Deleted))\r\n"))
      assert_equal %i[Deleted], view[1].flags
      view.handle_response(parser.parse("* 1 FETCH (UID 1 FLAGS (\\Deleted))\r\n"))
      assert_include view.notes.map(&:last), :duplicate

      view.handle_response(parser.parse("* VANISHED (EARLIER) 2\r\n"))
      assert_equal :present, view.status(2)
      assert_include view.notes.map(&:last), :ignored_earlier

      view.handle_response(parser.parse("* VANISHED 2\r\n"))
      assert_equal :absent, view.status(2)
      view.handle_response(parser.parse("* VANISHED 2\r\n"))
      assert_equal :absent, view.status(2)
      assert_include view.notes.map(&:last), :duplicate
    end
  end
end
