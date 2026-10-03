# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class MailboxViewTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  Message = Net::IMAP::MailboxView::Message

  # Replaces the FakeServer SELECT handler with one that responds like a
  # CONDSTORE/QRESYNC server.
  def on_qresync_select(server, uidvalidity:, uidnext:, exists: 0,
                        highestmodseq: nil, vanished: [], fetches: [])
    server.on "SELECT" do |resp|
      resp.untagged "#{exists} EXISTS"
      resp.untagged "FLAGS (\\Seen \\Flagged \\Deleted)"
      resp.untagged "OK [UIDVALIDITY #{uidvalidity}] UIDs valid"
      resp.untagged "OK [UIDNEXT #{uidnext}] Predicted next UID"
      if highestmodseq
        resp.untagged "OK [HIGHESTMODSEQ #{highestmodseq}] Highest"
      else
        resp.untagged "OK [NOMODSEQ] No mod-sequences"
      end
      vanished.each { |uids| resp.untagged "VANISHED (EARLIER) #{uids}" }
      fetches.each  { |line| resp.untagged line }
      resp.done_ok code: "READ-WRITE"
    end
  end

  test "interleaved FETCH/VANISHED/EXPUNGE events converge with a full UID FETCH" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 100,
                                uidnext: 9, exists: 5)
      imap.select("INBOX", condstore: true)
      server.commands.pop
      assert_equal 777, view.uidvalidity
      assert_equal 100, view.highestmodseq
      assert_equal 9,   view.uidnext

      # Interleaved live events, arriving between commands.
      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (90))"
      server.unsolicited "2 FETCH (UID 2 FLAGS (\\Seen) MODSEQ (95))"
      server.unsolicited "3 FETCH (UID 3 FLAGS () MODSEQ (98))"
      server.unsolicited "4 FETCH (UID 5 FLAGS (\\Flagged) MODSEQ (99))"
      server.unsolicited "5 FETCH (UID 8 FLAGS () MODSEQ (100))"
      server.unsolicited "VANISHED 2" # uid 2 is gone; seqs 3.. shift down
      server.unsolicited "2 FETCH (UID 3 FLAGS (\\Seen \\Flagged) MODSEQ (105))"
      server.unsolicited "2 FETCH (UID 3 FLAGS (\\Deleted) MODSEQ (99))" # stale
      server.unsolicited "2 FETCH (UID 3 FLAGS (\\Seen \\Flagged) MODSEQ (105))"
      server.unsolicited "3 EXPUNGE" # seq 3 is uid 5; uid 8 shifts to seq 3
      imap.noop # round-trip: all of the above have been consumed

      assert_equal Message[uid: 1, flags: %i[Seen],           modseq: 90],
                   view[1]
      assert_equal Message[uid: 3, flags: %i[Seen Flagged],   modseq: 105],
                   view[3]
      assert_equal Message[uid: 8, flags: [],                 modseq: 100],
                   view[8]
      assert_equal [1, 3, 8], view.uids
      assert_equal 1, view.ignored_stale_updates
      assert_equal 105, view.highestmodseq

      # known-gone vs not-yet-synchronized
      assert_equal false, view.exists?(2) # VANISHED
      assert_equal false, view.exists?(5) # EXPUNGE
      assert_nil          view.exists?(4) # never mentioned
      assert_nil          view.exists?(7) # never mentioned

      # A full UID FETCH is the ground truth; the view must converge to it.
      server.on "UID FETCH" do |resp|
        resp.untagged "1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (90))"
        resp.untagged "2 FETCH (UID 3 FLAGS (\\Seen \\Flagged) MODSEQ (105))"
        resp.untagged "3 FETCH (UID 8 FLAGS () MODSEQ (100))"
        resp.done_ok
      end
      fetched = view.full_sync(1..) { imap.uid_fetch(1.., %w[FLAGS MODSEQ]) }
      server.commands.pop
      expected = fetched.map { |data|
        Message[uid: data.uid, flags: data.flags, modseq: data.modseq]
      }
      assert_equal expected, view.to_a
      assert_equal [1, 3, 8], view.uids

      # After the completed full sync, every UID below UIDNEXT is accounted
      # for: unreturned UIDs are now known to be gone.
      assert_equal false, view.exists?(4)
      assert_equal false, view.exists?(7)
      assert_equal true,  view.exists?(8)
    end
  end

  test "UIDVALIDITY change discards the old identity" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 100,
                                uidnext: 4, exists: 2)
      imap.select("INBOX", condstore: true)
      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (90))"
      server.unsolicited "2 FETCH (UID 2 FLAGS () MODSEQ (91))"
      imap.noop
      assert_equal [1, 2], view.uids

      on_qresync_select(server, uidvalidity: 888, highestmodseq: 500,
                                uidnext: 11, exists: 1,
                                fetches: ["1 FETCH (UID 10 FLAGS () MODSEQ (500))"])
      imap.select("INBOX", condstore: true)

      assert_equal 888, view.uidvalidity
      assert_equal 500, view.highestmodseq
      assert_equal 11,  view.uidnext
      assert_equal [10], view.uids
      # nothing from the old identity survives, not even as "known gone"
      assert_nil view.exists?(1)
      assert_nil view.exists?(2)

      # A new identity that reports neither HIGHESTMODSEQ nor NOMODSEQ
      # invalidates the previous boundary values.
      server.on "SELECT" do |resp|
        resp.untagged "1 EXISTS"
        resp.untagged "OK [UIDVALIDITY 999] UIDs valid"
        resp.done_ok code: "READ-WRITE"
      end
      imap.select("INBOX", condstore: true)
      assert_equal 999, view.uidvalidity
      assert_nil  view.highestmodseq
      assert_nil  view.uidnext
      assert_equal false, view.nomodseq?
    end
  end

  test "a failed SELECT does not confirm the staged boundary" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 100, uidnext: 4)
      imap.select("INBOX", condstore: true)
      confirmed = view.sync_state
      assert_equal 777, confirmed.uidvalidity
      assert_equal 100, confirmed.highestmodseq

      server.on "SELECT" do |resp|
        resp.untagged "OK [UIDVALIDITY 999] UIDs valid"
        resp.untagged "OK [HIGHESTMODSEQ 900] Highest"
        resp.fail_no "mailbox is gone"
      end
      assert_raise(Net::IMAP::NoResponseError) { imap.select("INBOX") }

      # the reconnect boundary is still the last *confirmed* one
      assert_equal confirmed, view.sync_state
      assert_equal 777, view.uidvalidity
      assert_equal 100, view.highestmodseq
    end
  end

  test "NOMODSEQ disables modseq tracking but still tracks flags" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: nil, uidnext: 3)
      imap.select("INBOX", condstore: true)

      assert view.nomodseq?
      assert_nil view.highestmodseq
      assert_nil view.sync_state.highestmodseq

      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Seen))"
      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Deleted \\Seen))"
      imap.noop
      assert_equal Message[uid: 1, flags: %i[Deleted Seen], modseq: nil],
                   view[1]
    end
  end

  test "VANISHED (EARLIER) and duplicate notifications during QRESYNC select" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 100, uidnext: 6)
      imap.select("INBOX", condstore: true)
      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (90))"
      server.unsolicited "2 FETCH (UID 2 FLAGS () MODSEQ (90))"
      server.unsolicited "3 FETCH (UID 3 FLAGS () MODSEQ (90))"
      server.unsolicited "4 FETCH (UID 4 FLAGS () MODSEQ (90))"
      server.unsolicited "5 FETCH (UID 5 FLAGS () MODSEQ (90))"
      imap.noop
      assert_equal [1, 2, 3, 4, 5], view.uids

      # Re-select with QRESYNC-style resynchronization: VANISHED (EARLIER)
      # reports removals, FETCH reports changed flags.  Duplicates included.
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 120,
                                uidnext: 6, exists: 3,
                                vanished: ["2", "2:3", "2"],
                                fetches: ["3 FETCH (UID 5 FLAGS (\\Seen) MODSEQ (115))"])
      imap.select("INBOX", condstore: true)

      assert_equal [1, 4, 5], view.uids
      assert_equal false, view.exists?(2)
      assert_equal false, view.exists?(3)
      assert_equal Message[uid: 5, flags: %i[Seen], modseq: 115], view[5]
      assert_equal 120, view.highestmodseq
    end
  end

  test "a failed full_sync does not claim unreturned UIDs are gone" do
    with_fake_server(with_extensions: %i[CONDSTORE QRESYNC]) do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      on_qresync_select(server, uidvalidity: 777, highestmodseq: 100, uidnext: 5)
      imap.select("INBOX", condstore: true)

      server.on "UID FETCH" do |resp|
        resp.untagged "1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (90))"
        resp.fail_no "server exploded halfway"
      end
      error = assert_raise(Net::IMAP::NoResponseError) do
        view.full_sync(1..) { imap.uid_fetch(1.., %w[FLAGS MODSEQ]) }
      end
      assert_match(/exploded/, error.message)

      # Data received before the failure is kept...
      assert_equal true, view.exists?(1)
      # ...but the interrupted sync proves nothing about the rest.
      assert_nil view.exists?(2)
      assert_nil view.exists?(3)
      assert_nil view.exists?(4)
    end
  end

  test "EXPUNGE maps sequence numbers to UIDs and shifts higher seqs" do
    with_fake_server do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      imap.select("INBOX")
      server.unsolicited "1 FETCH (UID 11 FLAGS ())"
      server.unsolicited "2 FETCH (UID 22 FLAGS ())"
      server.unsolicited "3 FETCH (UID 33 FLAGS ())"
      server.unsolicited "2 EXPUNGE" # uid 22
      server.unsolicited "2 FETCH (UID 33 FLAGS (\\Seen))" # shifted down
      imap.noop

      assert_equal false, view.exists?(22)
      assert_equal Message[uid: 33, flags: %i[Seen], modseq: nil], view[33]
      # expunge of a message the view never saw only shifts seq numbers
      server.unsolicited "1 EXPUNGE" # uid 11
      server.unsolicited "1 FETCH (UID 33 FLAGS (\\Seen \\Flagged))"
      imap.noop
      assert_equal false, view.exists?(11)
      assert_equal %i[Seen Flagged], view[33].flags
    end
  end

  test "detach stops consuming responses" do
    with_fake_server do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      imap.select("INBOX")
      server.unsolicited "1 FETCH (UID 1 FLAGS (\\Seen))"
      imap.noop
      assert_equal 1, view.size

      view.detach(imap)
      server.unsolicited "2 FETCH (UID 2 FLAGS (\\Seen))"
      imap.noop
      assert_equal 1, view.size
      assert_equal [1], view.uids
    end
  end

  test "known_uid_set reflects known messages" do
    with_fake_server do |server, imap|
      view = Net::IMAP::MailboxView.new.attach(imap)
      imap.select("INBOX")
      server.unsolicited "1 FETCH (UID 5 FLAGS ())"
      server.unsolicited "2 FETCH (UID 7 FLAGS ())"
      server.unsolicited "3 FETCH (UID 9 FLAGS ())"
      imap.noop
      assert_equal Net::IMAP::SequenceSet["5,7,9"], view.known_uid_set
    end
  end

end
