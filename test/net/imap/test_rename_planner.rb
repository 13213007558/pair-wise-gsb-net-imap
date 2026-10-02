# frozen_string_literal: true

require "net/imap"
require_relative "../../lib/helper"

class RenamePlannerTest < Net::IMAP::TestCase
  InvalidRenames = Net::IMAP::RenamePlanner::InvalidRenames
  MailboxList = Net::IMAP::MailboxList

  class InMemoryServer
    def initialize(mailboxes, namespaces: [["", "/"]])
      @mailboxes = mailboxes.to_set
      @namespaces = namespaces
    end

    attr_reader :mailboxes

    def can_rename?(source, target)
      return false unless @mailboxes.include?(source)
      return false if @mailboxes.include?(target)
      return false if same_namespace?(source, target) == false

      namespace = namespace_for(target)
      parent = parent_path(target, namespace)
      return false if parent && !@mailboxes.include?(parent)

      delimiter = namespace.fetch(1)
      !target.start_with?(source + delimiter)
    end

    def rename(source, target)
      unless can_rename?(source, target)
        raise ArgumentError, "cannot rename #{source.inspect} to #{target.inspect}"
      end

      moved = @mailboxes.select { _1 == source || _1.start_with?(source + namespace_for(source).fetch(1)) }
      @mailboxes.subtract(moved)
      @mailboxes.merge(moved.map { target + _1.delete_prefix(source) })
    end

    private

    def same_namespace?(source, target)
      source_namespace = namespace_for(source)
      target_namespace = namespace_for(target)
      source_namespace && target_namespace &&
        source_namespace.fetch(0) == target_namespace.fetch(0)
    end

    def namespace_for(path)
      @namespaces
        .select { |prefix, _| path.start_with?(prefix) }
        .max_by { _1.fetch(0).length }
    end

    def parent_path(path, namespace)
      prefix, delimiter = namespace
      relative = path.delete_prefix(prefix).sub(/\A#{Regexp.escape(delimiter)}/, "")
      index = relative.rindex(delimiter)
      index ? prefix + relative[0...index] : nil
    end
  end

  test "orders parent and child renames and tracks implicitly moved identities" do
    list = %w[INBOX a a/child a/child/leaf other]
    renames = {
      "a"       => "new",
      "a/child" => "new/kid",
    }
    server = InMemoryServer.new(list)
    plan = Net::IMAP::RenamePlanner.plan(renames, list:, delimiter: "/")
    execution = plan.start

    assert_equal [
      ["a",          "new"],
      ["new/child",  "new/kid"],
    ], plan.commands.map { [_1.from, _1.to] }

    plan.commands.each do |command|
      assert server.can_rename?(command.from, command.to)
      server.rename(command.from, command.to)
      execution.advance
      assert execution.moved?("a")
      assert execution.moved?("a/child")
    end

    assert_equal %w[INBOX other new new/kid new/kid/leaf].sort, server.mailboxes.to_a.sort
    assert_equal Set["a", "a/child", "a/child/leaf"], execution.moved_identities
    assert_predicate execution, :done?
  end

  test "parks one subtree before swapping two subtrees" do
    list = %w[alpha alpha/child beta beta/child keep]
    renames = {
      "alpha" => "beta",
      "beta"  => "alpha",
    }
    final_targets = list.to_set.merge(%w[alpha/child beta/child])
    server = InMemoryServer.new(list)
    plan = Net::IMAP::RenamePlanner.plan(renames, list:, delimiter: "/")
    execution = plan.start

    assert_equal 3, plan.size
    temporary = plan.commands.first
    assert_predicate temporary, :temporary?
    refute_includes list, temporary.to
    final_targets.each do |occupied|
      refute_equal occupied, temporary.to
      refute temporary.to.start_with?(occupied + "/")
      refute occupied.start_with?(temporary.to + "/")
    end

    plan.commands.each do |command|
      assert server.can_rename?(command.from, command.to)
      server.rename(command.from, command.to)
      execution.advance
    end

    assert_equal %w[alpha alpha/child beta beta/child keep].sort, server.mailboxes.to_a.sort
    assert_equal Set["alpha", "alpha/child", "beta", "beta/child"],
                 execution.moved_identities
  end

  test "resolves a three-name cycle without assuming a two-way swap" do
    list = %w[a a/child b b/child c c/child]
    renames = {"a" => "b", "b" => "c", "c" => "a"}
    plan = Net::IMAP::RenamePlanner.plan(renames, list:, delimiter: "/")
    server = InMemoryServer.new(list)

    plan.each do |command|
      assert server.can_rename?(command.from, command.to)
      server.rename(command.from, command.to)
    end

    assert_equal list.sort, server.mailboxes.to_a.sort
  end

  test "keeps execution at the failed command until the caller advances" do
    list = %w[parent parent/child]
    plan = Net::IMAP::RenamePlanner.plan({"parent" => "moved"}, list:, delimiter: "/")
    execution = plan.start
    command = execution.current_command

    assert_empty execution.moved_identities
    assert_raise(ArgumentError) do
      # Simulate a server rejection. The caller must not call #advance.
      InMemoryServer.new(list).rename(command.from, command.from)
    end
    assert_equal 0, execution.index
    assert_empty execution.moved_identities
  end

  test "reports invalid, duplicate, INBOX, namespace, and parent errors before planning" do
    list = [
      "INBOX",
      MailboxList.new([:Noinferiors], "/", "leaf"),
      "users/notice",
      "shared/notice",
    ]
    namespaces = [["", "/"], ["users/", "/"], ["shared/", "/"]]
    renames = [
      ["missing",       "whatever"],
      ["INBOX",         "inbox-archive"],
      ["inbox",         "also-invalid"],
      ["leaf",          "INBOX"],
      ["leaf",          "leaf//bad"],
      ["shared/notice", "shared/missing/child"],
      ["leaf",          "leaf-moved"],
      ["leaf",          "leaf-moved-again"],
      ["INBOX",         "duplicate-target"],
      ["shared/notice", "duplicate-target"],
      ["users/notice",  "shared/notice"],
    ]

    error = assert_raise(InvalidRenames) do
      Net::IMAP::RenamePlanner.plan(renames, list:, namespaces:)
    end

    assert_match(/unknown mailbox/, error.message)
    assert_match(/INBOX cannot be renamed/, error.message)
    assert_match(/invalid target name/, error.message)
    assert_match(/duplicate target/, error.message)
    assert_match(/cannot rename across namespaces/, error.message)
    assert_match(/target parent does not exist/, error.message)
    assert_match(/duplicate rename request for "leaf"/, error.message)
  end

  test "rejects targets beneath NoInferiors mailboxes" do
    list = [MailboxList.new([:Noinferiors], "/", "locked"), "plain"]
    error = assert_raise(InvalidRenames) do
      Net::IMAP::RenamePlanner.plan({"plain" => "locked/child"}, list:, delimiter: "/")
    end
    assert_match(/does not allow inferiors/, error.message)
  end

  test "rejects a target occupied by a mailbox that is not renamed" do
    error = assert_raise(InvalidRenames) do
      Net::IMAP::RenamePlanner.plan(
        {"a" => "b", "b" => "b"},
        list: %w[a b],
        delimiter: "/",
      )
    end
    assert_match(/duplicate final target "b"/, error.message)
  end

  test "accepts the listed name with a trailing hierarchy delimiter" do
    list = [MailboxList.new([], "/", "parent/")]
    plan = Net::IMAP::RenamePlanner.plan(
      {"parent/" => "moved/"},
      list: list,
      delimiter: "/",
    )
    assert_equal [["parent", "moved"]], plan.commands.map { [_1.from, _1.to] }
  end

  test "allows ordinary folders under an INBOX namespace prefix" do
    list = %w[INBOX INBOX.sent INBOX.sent.draft]
    plan = Net::IMAP::RenamePlanner.plan(
      {"INBOX.sent" => "INBOX.sent-items"},
      list: list,
      namespaces: [["", "."]],
    )

    assert_equal [["INBOX.sent", "INBOX.sent-items"]],
                 plan.commands.map { [_1.from, _1.to] }
  end

  test "moves an explicitly renamed descendant out from a renamed parent" do
    list = %w[a a/child a/child/leaf b]
    renames = {
      "a"       => "new",
      "a/child" => "b/moved-child",
    }
    plan = Net::IMAP::RenamePlanner.plan(renames, list:, delimiter: "/")
    server = InMemoryServer.new(list)
    execution = plan.start

    plan.commands.each do |command|
      assert server.can_rename?(command.from, command.to)
      server.rename(command.from, command.to)
      execution.advance
    end

    assert_includes server.mailboxes, "new"
    assert_includes server.mailboxes, "b/moved-child"
    assert_includes server.mailboxes, "b/moved-child/leaf"
    assert_not_includes server.mailboxes, "new/child"
  end

  test "resolves a renamed parent inside an explicit namespace prefix" do
    list = ["shared/a", "shared/a/child"]
    renames = {
      "shared/a"       => "shared/new",
      "shared/a/child" => "shared/new/child",
    }
    plan = Net::IMAP::RenamePlanner.plan(
      renames,
      list: list,
      namespaces: [["shared/", "/"]],
    )
    assert_equal [["shared/a", "shared/new"]],
                 plan.commands.map { [_1.from, _1.to] }
  end
end
