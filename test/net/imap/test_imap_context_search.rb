# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPContextSearchTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  SearchContext = Net::IMAP::SearchContext
  UNKNOWN       = SearchContext::UNKNOWN

  # issues a NOOP so that every previously sent unsolicited response has
  # been processed by the client receiver thread
  def sync(imap) = imap.noop

  test "CONTEXT=SEARCH: server updates an ordered result, step by step" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:5 10,20,30,40,50) COUNT 5)
        cmd.done_ok
      end

      result  = imap.uid_search(["FLAGGED"], return: [:PARTIAL, 1..5])
      command = server.commands.pop
      assert_equal "RETURN (PARTIAL 1:5) FLAGGED", command.args

      context = imap.search_contexts.track(result, command: "UID SEARCH")
      assert_equal result.tag, context.tag
      assert_equal "UID SEARCH", context.command
      assert_equal [10, 20, 30, 40, 50], context.to_a

      server.unsolicited %(ESEARCH (TAG "#{result.tag}") UID ADDTO 3:25)
      sync imap
      assert_equal [10, 20, 25, 30, 40, 50], context.to_a

      server.unsolicited %(ESEARCH (TAG "#{result.tag}") UID REMOVEFROM 1)
      sync imap
      assert_equal [20, 25, 30, 40, 50], context.to_a

      server.unsolicited %(ESEARCH (TAG "#{result.tag}") UID ADDTO 1:5,5:45)
      sync imap
      assert_equal [5, 20, 25, 30, 45, 40, 50], context.to_a
      assert_equal 7, context.count
      assert context.active?
    end
  end

  test "multiple updates in one input block, two contexts interleaved" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        case cmd.args
        when /FLAGGED/
          cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:3 10,20,30) COUNT 3)
        when /UNSEEN/
          cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:3 7,8,9) COUNT 3)
        end
        cmd.done_ok
      end

      flagged = imap.search_contexts.track(
        imap.uid_search(["FLAGGED"], return: [:PARTIAL, 1..3])
      )
      unseen  = imap.search_contexts.track(
        imap.uid_search(["UNSEEN"], return: [:PARTIAL, 1..3])
      )
      server.commands.pop
      server.commands.pop
      refute_equal flagged.tag, unseen.tag
      assert_equal [10, 20, 30], flagged.to_a
      assert_equal [7, 8, 9],     unseen.to_a

      # a single input block with updates for both contexts, interleaved,
      # including one response that carries multiple updates
      server.unsolicited %(ESEARCH (TAG "#{flagged.tag}") UID ADDTO 2:15)
      server.unsolicited %(ESEARCH (TAG "#{unseen.tag}") UID REMOVEFROM 2)
      server.unsolicited %(ESEARCH (TAG "#{flagged.tag}") UID REMOVEFROM 3 ADDTO 1:5)
      server.unsolicited %(ESEARCH (TAG "#{unseen.tag}") UID ADDTO 3:6)
      sync imap

      assert_equal [5, 10, 15, 30], flagged.to_a
      assert_equal [7, 9, 6],       unseen.to_a
      assert_equal 4, flagged.count
      assert_equal 3, unseen.count
      assert_equal [flagged, unseen].sort_by(&:tag),
                   imap.search_contexts.active.sort_by(&:tag)
    end
  end

  test "untracked correlator tags are ignored, then replayed on track" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok
      end

      result = imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      server.commands.pop

      # updates arrive before the context is tracked
      server.unsolicited %(ESEARCH (TAG "#{result.tag}") UID ADDTO 3:30)
      server.unsolicited %(ESEARCH (TAG "RUBY9999") UID ADDTO 1:1)
      sync imap

      context = imap.search_contexts.track(result)
      assert_equal [10, 20, 30], context.to_a
      assert_nil imap.search_contexts["RUBY9999"]
    end
  end

  test "NOUPDATE in the tagged search response is observed on track" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok "SEARCH done", code: "NOUPDATE #{cmd.tag}"
      end

      result  = imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      context = imap.search_contexts.track(result)
      server.commands.pop

      assert context.noupdates?
      refute context.active?
      assert_empty imap.search_contexts.active
    end
  end

  test "untagged NOUPDATE stops updates for a tracked context" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok
      end

      context = imap.search_contexts.track(
        imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      )
      server.commands.pop
      assert context.active?

      server.unsolicited %(OK [NOUPDATE #{context.tag}] too many contexts)
      sync imap
      assert context.noupdates?

      # further updates are ignored
      server.unsolicited %(ESEARCH (TAG "#{context.tag}") UID ADDTO 1:99)
      sync imap
      assert_equal [10, 20], context.to_a
    end
  end

  test "CANCELUPDATE cancels updates for tracked contexts" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok
      end
      server.on "CANCELUPDATE", &:done_ok

      context = imap.search_contexts.track(
        imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      )
      server.commands.pop

      imap.search_contexts.cancel(context)
      command = server.commands.pop
      assert_equal "CANCELUPDATE", command.name
      assert_equal context.tag,    command.args
      assert context.cancelled?

      server.unsolicited %(ESEARCH (TAG "#{context.tag}") UID ADDTO 1:99)
      sync imap
      assert_equal [10, 20], context.to_a
    end
  end

  test "selecting another mailbox closes every tracked context" do
    mailboxes = { "INBOX" => { name: "INBOX" }, "ARCHIVE" => { name: "ARCHIVE" } }
    with_fake_server(select: "INBOX", mailboxes:) do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok
      end

      context = imap.search_contexts.track(
        imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      )
      server.commands.pop
      assert context.active?

      imap.select("ARCHIVE")
      server.commands.pop
      assert context.closed?
      assert_empty imap.search_contexts.active
      # closed contexts stay observable until explicitly cleared
      assert_equal [context], imap.search_contexts.to_a
    end
  end

  test "CLOSE closes every tracked context" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:2 10,20) COUNT 2)
        cmd.done_ok
      end

      context = imap.search_contexts.track(
        imap.uid_search(["ALL"], return: [:PARTIAL, 1..2])
      )
      server.commands.pop

      imap.close
      server.commands.pop
      assert context.closed?
    end
  end

  test "CONTEXT=SORT: uid_sort with return options keeps sort order" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SORT" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:3 30,10,20) COUNT 3)
        cmd.done_ok
      end

      result = imap.uid_sort(%w[FROM], %w[ALL], "UTF-8",
                             return: [:PARTIAL, 1..100])
      command = server.commands.pop
      assert_equal "RETURN (PARTIAL 1:100) (FROM) UTF-8 ALL", command.args
      assert_kind_of Net::IMAP::ESearchResult, result

      context = imap.search_contexts.track(result, command: "UID SORT")
      # sorted order is preserved: not simply a sorted set of UIDs
      assert_equal [30, 10, 20], context.to_a

      server.unsolicited %(ESEARCH (TAG "#{result.tag}") UID ADDTO 2:25)
      sync imap
      assert_equal [30, 25, 10, 20], context.to_a
    end
  end

  test "sort without return options still returns a plain SORT result" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "SORT" do |cmd|
        cmd.puts "* SORT 2 1 3"
        cmd.done_ok
      end

      assert_equal [2, 1, 3], imap.sort(%w[FROM], %w[ALL], "UTF-8")
      command = server.commands.pop
      assert_equal "(FROM) UTF-8 ALL", command.args
    end
  end

  test "partially known results expose UNKNOWN positions, never empty" do
    with_fake_server(select: "INBOX") do |server, imap|
      server.on "UID SEARCH" do |cmd|
        cmd.puts %(\* ESEARCH (TAG "#{cmd.tag}") UID PARTIAL (1:3 10,20,30) COUNT 6)
        cmd.done_ok
      end

      context = imap.search_contexts.track(
        imap.uid_search(["ALL"], return: [:PARTIAL, 1..3])
      )
      server.commands.pop

      assert_equal 6, context.count
      assert_equal 3, context.known_count
      refute context.fully_known?
      assert_equal [10, 20, 30, UNKNOWN, UNKNOWN, UNKNOWN], context.to_a

      server.unsolicited %(ESEARCH (TAG "#{context.tag}") UID REMOVEFROM 5)
      sync imap
      assert_equal [10, 20, 30, UNKNOWN, UNKNOWN], context.to_a
      assert_equal 5, context.count
    end
  end

end
