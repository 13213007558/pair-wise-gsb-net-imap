# frozen_string_literal: true

require "net/imap"
require "test/unit"

class RenamePlannerTest < Net::IMAP::TestCase
  RenamePlanner = Net::IMAP::RenamePlanner
  MailboxList = Net::IMAP::MailboxList
  InvalidPlanError = Net::IMAP::RenamePlanner::InvalidPlanError

  class InMemoryServer
    def initialize(mailboxes, delimiter)
      @mailboxes = mailboxes.to_set
      @delimiter = delimiter
    end

    def rename(from, to)
      unless @mailboxes.include?(from)
        raise "source mailbox #{from.inspect} does not exist"
      end
      if @mailboxes.include?(to)
        raise "target mailbox #{to.inspect} already exists"
      end
      if inside?(to, from)
        raise "cannot rename #{from.inspect} into its own subtree #{to.inspect}"
      end
      if @mailboxes.any? { _1 != from && inside?(_1, to) }
        raise "target mailbox #{to.inspect} already has children"
      end

      moved = @mailboxes.select { _1 == from || inside?(_1, from) }
      @mailboxes.subtract(moved)
      moved.each do |mailbox|
        suffix = mailbox == from ? "" : mailbox[from.length..]
        @mailboxes.add(to + suffix)
      end
    end

    def list = @mailboxes.to_a.sort

    private

    def inside?(mailbox, ancestor)
      mailbox != ancestor && mailbox.start_with?(ancestor + @delimiter)
    end
  end

  test "plans parent and child renames with parent cascade" do
    list = %w[Projects Projects/A Projects/A/Deeps Archive]
    renames = {
      "Projects" => "Work",
      "Projects/A" => "Work/Alpha",
    }

    plan = RenamePlanner.plan(list, renames, delimiter: "/")
    assert_equal [%w[Projects Work], %w[Work/A Work/Alpha]], plan.map(&:to_a)
    assert_equal [["Projects", "Projects/A", "Projects/A/Deeps"],
                  ["Projects/A", "Projects/A/Deeps"]], plan.map(&:affected)

    server = InMemoryServer.new(list, "/")
    execute_all(plan, server)

    assert_equal %w[Archive Work Work/Alpha Work/Alpha/Deeps], server.list
    assert_equal %w[Projects Projects/A Projects/A/Deeps], plan.moved_identities
    assert_empty plan.pending_identities
  end

  test "restores an explicitly unchanged child moved by a parent cascade" do
    list = %w[Parent Parent/Child Parent/Child/Deeps]
    plan = RenamePlanner.plan(list, {
      "Parent" => "Moved",
      "Parent/Child" => "Parent/Child",
    }, delimiter: "/")

    server = InMemoryServer.new(list, "/")
    execute_all(plan, server)
    assert_equal %w[Moved Parent/Child Parent/Child/Deeps], server.list
    assert_empty plan.pending_identities
  end

  test "exchanges two subtrees using temporary names" do
    list = %w[Alpha Alpha/One Alpha/One/Child Beta Beta/Two]
    renames = {"Alpha" => "Beta", "Beta" => "Alpha"}
    plan = RenamePlanner.plan(list, renames, delimiter: "/")

    temporary = plan.find(&:temporary?)
    assert temporary
    assert_equal "Alpha", temporary.identity
    assert_not_include list, temporary.to
    assert_not_include renames.values, temporary.to
    assert_not_include(plan.map(&:to) - [temporary.to], temporary.to)
    assert_include temporary.to, "net-imap-rename-"

    server = InMemoryServer.new(list, "/")
    commands = execute_all(plan, server)

    assert_equal [
      ["Alpha", temporary.to],
      ["Beta", "Alpha"],
      [temporary.to, "Beta"],
    ], commands.map(&:to_a)
    assert_equal %w[Alpha Alpha/Two Beta Beta/One Beta/One/Child], server.list
    assert_empty plan.pending_identities
  end

  test "keeps temporary names inside the moving namespace" do
    list = %w[Shared/A Shared/B]
    namespaces = [
      {prefix: "", delim: "/"},
      {prefix: "Shared/", delim: "/"},
    ]
    plan = RenamePlanner.plan(
      list, {"Shared/A" => "Shared/B", "Shared/B" => "Shared/A"},
      delimiter: "/", namespaces:
    )
    temporary = plan.find(&:temporary?)
    assert temporary
    assert temporary.to.start_with?("Shared/")
    assert_not_include list, temporary.to
    assert_not_include %w[Shared/A Shared/B], temporary.to
  end

  test "accepts a single NAMESPACE response object" do
    namespace = Net::IMAP::Namespace.new("", "/", nil)
    plan = RenamePlanner.plan(
      %w[Mail], {"Mail" => "Archive"}, delimiter: "/", namespace:
    )
    assert_equal [%w[Mail Archive]], plan.map(&:to_a)
  end

  test "reports identities moved after a later command fails" do
    list = %w[Parent Parent/Child Other Other/Child Swap Swap/Child]
    renames = {
      "Parent" => "Moved",
      "Other" => "Swap",
      "Swap" => "Other",
    }
    plan = RenamePlanner.plan(list, renames, delimiter: "/")
    server = InMemoryServer.new(list, "/")

    plan.execute(server)
    plan.execute(server)
    failing_server = Object.new
    def failing_server.rename(*) = raise("connection lost")
    error = assert_raise(RuntimeError) { plan.execute(failing_server) }
    assert_equal "connection lost", error.message

    assert_equal %w[Other Other/Child Parent Parent/Child], plan.moved_identities.sort
    assert_equal ["Other"], plan.pending_identities
    assert_include plan.current_location("Other"), "net-imap-rename-"
    assert_equal "Other", plan.current_location("Swap")
    refute_nil plan.next_command
  end

  test "can resume the remaining command after a failed execution" do
    list = %w[Alpha Beta]
    plan = RenamePlanner.plan(
      list, {"Alpha" => "Beta", "Beta" => "Alpha"}, delimiter: "/"
    )
    server = InMemoryServer.new(list, "/")

    plan.execute(server)
    assert_raise(RuntimeError) do
      failing_server = Object.new
      def failing_server.rename(*) = raise("temporary failure")
      plan.execute(failing_server)
    end

    next_command = plan.next_command
    refute next_command.temporary?
    assert_equal ["Beta", "Alpha"], next_command.to_a
    plan.execute(server)
    plan.execute(server)
    assert_equal %w[Alpha Beta], server.list
    assert_empty plan.pending_identities
  end

  test "rejects invalid, inbox, and cross-namespace targets before commands" do
    list = [
      "INBOX",
      "Mail/Foo",
      "Shared/Root",
      MailboxList.new([:Noinferiors], "/", "Mail/NoKids"),
      MailboxList.new([:Noinferiors], "/", "Locked"),
    ].uniq
    namespaces = [
      {prefix: "", delim: "/"},
      {prefix: "Shared/", delim: "/"},
    ]
    renames = {
      "Missing" => "New",
      "Mail/Foo" => "Shared/Foo",
      "INBOX" => "Inbox Backup",
      "Mail/NoKids" => "Locked/Child",
      "Shared/Root" => "Shared/Root//Bad",
    }

    error = assert_raise(InvalidPlanError) do
      RenamePlanner.plan(list, renames, delimiter: "/", namespaces:)
    end

    reasons = error.problems.map(&:reason)
    assert_include reasons, :unknown_mailbox
    assert_include reasons, :cross_namespace
    assert_include reasons, :inbox
    assert_include reasons, :no_inferiors
    assert_include reasons, :invalid_name
  end

  test "rejects even an explicit INBOX no-op mapping" do
    error = assert_raise(InvalidPlanError) do
      RenamePlanner.plan(%w[INBOX], {"INBOX" => "INBOX"}, delimiter: "/")
    end
    assert_include error.problems.map(&:reason), :inbox
  end

  test "rejects targets inside the mailbox's own current subtree" do
    list = %w[Parent Parent/Child]
    error = assert_raise(InvalidPlanError) do
      RenamePlanner.plan(list, {"Parent" => "Parent/Child/Renamed"}, delimiter: "/")
    end
    assert_include error.problems.map(&:reason), :own_descendant
  end

  test "orders an unrelated child before moving a mailbox above it" do
    list = %w[Source Other Other/Child Merged]
    plan = RenamePlanner.plan(list, {
      "Source" => "Merged/Root",
      "Other/Child" => "Merged/Root/Child",
    }, delimiter: "/")

    server = InMemoryServer.new(list, "/")
    execute_all(plan, server)
    assert_equal %w[Merged Merged/Root Merged/Root/Child Other], server.list
  end

  test "rejects targets with a missing parent mailbox" do
    list = %w[Source]
    error = assert_raise(InvalidPlanError) do
      RenamePlanner.plan(list, {"Source" => "Missing/Parent/Target"}, delimiter: "/")
    end
    assert_include error.problems.map(&:reason), :missing_parent
  end

  test "requires a single character hierarchy delimiter" do
    assert_raise_with_message(ArgumentError, /single-character/) do
      RenamePlanner.new(%w[Mail], delimiter: "//")
    end
  end

  test "moves an occupying child before renaming into its parent" do
    list = %w[Parent Parent/Child NewParent]
    plan = RenamePlanner.plan(list, {
      "Parent" => "NewParent/Renamed",
      "Parent/Child" => "Elsewhere",
    }, delimiter: "/")

    server = InMemoryServer.new(list, "/")
    execute_all(plan, server)
    assert_equal %w[Elsewhere NewParent NewParent/Renamed], server.list
  end

  test "rejects duplicate explicit and final targets" do
    list = %w[A A/Child B C C/Child]
    renames = {
      "A" => "D",
      "B" => "D",
      "C" => "A",
    }

    error = assert_raise(InvalidPlanError) do
      RenamePlanner.plan(list, renames, delimiter: "/")
    end
    reasons = error.problems.map(&:reason)
    assert_include reasons, :duplicate_target
    assert_include reasons, :duplicate_final_target
  end

  private

  def execute_all(plan, server)
    plan.map do
      before = server.list
      command = plan.next_command
      assert_include before, command.from
      assert_not_include before, command.to
      plan.execute(server)
      command
    end
  end
end
