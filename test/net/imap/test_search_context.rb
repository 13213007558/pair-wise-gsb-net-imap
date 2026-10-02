# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "../../lib/helper"

class SearchContextTest < Net::IMAP::TestCase
  OrderedResult = Net::IMAP::OrderedSearchResult
  Update        = Net::IMAP::SearchContextUpdate
  Context       = Net::IMAP::SearchContext
  ESearchResult = Net::IMAP::ESearchResult
  Partial       = ESearchResult::PartialResult

  test "ADDTO positions are applied to the current ordered result" do
    assert_equal [9, 3, 1, 4], OrderedResult.known([3, 1, 4]).tap { _1.apply add(1, 9) }.to_a
    assert_equal [3, 1, 4, 9], OrderedResult.known([3, 1, 4]).tap { _1.apply add(4, 9) }.to_a
    assert_equal [3, 1, 9, 4], OrderedResult.known([3, 1, 4]).tap { _1.apply add(3, 9) }.to_a
    result = OrderedResult.known([3, 1, 4])
    assert_equal :unknown, result.apply(add(5, 9))
    assert_equal [3, 1, 4], result.to_a
  end

  test "REMOVEFROM positions are applied after preceding updates" do
    result = OrderedResult.known([3, 1, 4, 1, 5])
    result.apply add(3, 9)
    assert_equal [3, 1, 9, 4, 1, 5], result.to_a
    result.apply remove(4, 4)
    assert_equal [3, 1, 9, 1, 5], result.to_a
    result.apply remove(2, 1)
    assert_equal [3, 9, 1, 5], result.to_a
  end

  test "updates are not treated as a sorted UID set" do
    result = OrderedResult.known([90, 10, 50])
    result.apply add(2, 30)
    assert_equal [90, 30, 10, 50], result.to_a
    result.apply remove(4, 50)
    assert_equal [90, 30, 10], result.to_a
    assert_equal "10,30,90", result.to_sequence_set.to_s
  end

  test "positive PARTIAL keeps the suffix unknown" do
    result = OrderedResult.from_partial(Partial[1..2, "10,30"])
    assert_equal [10, 30], result.known_results
    assert_predicate result, :unknown_suffix?
    assert_nil result.unknown_suffix_size
    assert_nil result.total_count
    assert_equal :applied, result.apply(add(1, 5))
    assert_equal [5, 10, 30], result.known_results
    assert_equal :unknown, result.apply(add(5, 99))
  end

  test "PARTIAL with COUNT records finite unknown portions" do
    result = OrderedResult.from_partial(Partial[2..3, "10,30"], count: 5)
    assert_equal 1, result.unknown_prefix_size
    assert_equal 2, result.unknown_suffix_size
    assert_equal 5, result.total_count
    result.apply add(2, 99)
    assert_equal [99, 10, 30], result.known_results
    assert_equal 2, result.unknown_suffix_size
    assert_equal 6, result.total_count
    result.apply add(1, 7)
    assert_equal [7, 99, 10, 30], result.known_results
    assert_equal 0, result.unknown_prefix_size
    assert_equal 2, result.unknown_suffix_size
    assert_equal 7, result.total_count
  end

  test "negative PARTIAL has an unknown prefix and known suffix order" do
    result = OrderedResult.from_partial(Partial[-2..-1, "10,30"])
    assert_predicate result, :unknown_prefix?
    assert_nil result.unknown_prefix_size
    assert_equal [10, 30], result.known_results
    assert_equal :unknown, result.apply(add(1, 99))
  end

  test "empty PARTIAL NIL is not an empty full result" do
    result = OrderedResult.from_partial(Partial[1..3, nil])
    assert_empty result.known_results
    assert_predicate result, :partial?
    assert_equal 3, result.unknown_suffix_size
  end

  test "multiple updates in one response are applied in order" do
    context = context_with(OrderedResult.known([10, 20, 30]))
    response = ESearchResult.new("tag", true, [
      ["ADDTO", add(2, 40)],
      ["REMOVEFROM", remove(3, 20)],
      ["ADDTO", add(1, 50)],
    ])
    assert context.apply_esearch(response)
    assert_equal [50, 10, 40, 30], context.to_a
    assert_equal [40, 20, 50], context.updates.map { _1.uids.first }
  end

  test "two contexts advance independently when updates interleave" do
    alpha = context_with(OrderedResult.known([1, 2, 3]), tag: "A")
    beta  = context_with(OrderedResult.known([9, 8, 7]), tag: "B")
    apply alpha, add(2, 10)
    apply beta,  remove(1, 9)
    apply alpha, remove(4, 3)
    apply beta,  add(3, 6)
    assert_equal [1, 10, 2], alpha.to_a
    assert_equal [8, 7, 6], beta.to_a
  end

  test "NOUPDATE, CANCELUPDATE, and invalid states are observable" do
    context = context_with(OrderedResult.known([1]))
    context.noupdate!
    assert_predicate context, :noupdate?
    refute context.apply_esearch(update_response(add(2, 2)))
    assert_equal [1], context.to_a
    context = context_with(OrderedResult.known([1]))
    context.cancel!
    assert_predicate context, :cancelled?
    refute context.apply_esearch(update_response(add(2, 2)))
    context.invalidate!
    assert_predicate context, :invalid?
  end

  private

  def add(position, uid)
    Update.new(name: "ADDTO", position: position, uids: [uid])
  end

  def remove(position, uid)
    Update.new(name: "REMOVEFROM", position: position, uids: [uid])
  end

  def context_with(result, tag: "tag")
    Context.new(tag: tag, uid: true, command: "UID SEARCH", result: result)
  end

  def update_response(update)
    ESearchResult.new(@context_tag || "tag", true, [[update.name, update]])
  end

  def apply(context, update)
    @context_tag = context.tag
    context.apply_esearch(update_response(update))
  ensure
    @context_tag = nil
  end
end
