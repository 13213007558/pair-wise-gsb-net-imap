# frozen_string_literal: true

require "net/imap"
require "test/unit"

class SearchContextTest < Net::IMAP::TestCase
  SearchContext = Net::IMAP::SearchContext
  ESearchResult = Net::IMAP::ESearchResult
  UNKNOWN       = SearchContext::UNKNOWN

  def esearch(string)
    Net::IMAP::ResponseParser.new.parse("#{string}\r\n").data
  end

  test "requires a correlator tag" do
    assert_raise(ArgumentError) { SearchContext.new }
    assert_raise(ArgumentError) {
      SearchContext.new(ESearchResult.new(nil, true, []))
    }
    assert_raise(TypeError) { SearchContext.new("not an esearch", tag: "A1") }
  end

  test "keeps the correlator tag and command reference" do
    initial = esearch('* ESEARCH (TAG "A283") UID PARTIAL (1:3 24,42,88)')
    context = SearchContext.new(initial, command: "UID SEARCH")
    assert_equal "A283", context.tag
    assert_equal "UID SEARCH", context.command
    assert_equal true, context.uid?
  end

  test "applies ADDTO and REMOVEFROM step by step" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A1") UID PARTIAL (1:5 10,20,30,40,50) COUNT 5')
    )
    assert_equal [10, 20, 30, 40, 50], context.to_a

    context.update(esearch('* ESEARCH (TAG "A1") UID ADDTO 3:25'))
    assert_equal [10, 20, 25, 30, 40, 50], context.to_a

    context.update(esearch('* ESEARCH (TAG "A1") UID REMOVEFROM 1'))
    assert_equal [20, 25, 30, 40, 50], context.to_a

    context.update(esearch('* ESEARCH (TAG "A1") UID ADDTO 1:5,6:45'))
    assert_equal [5, 20, 25, 30, 40, 45, 50], context.to_a

    context.update(esearch('* ESEARCH (TAG "A1") UID REMOVEFROM 7'))
    assert_equal [5, 20, 25, 30, 40, 45], context.to_a
    assert_equal 6, context.count
    assert context.fully_known?
  end

  test "applies multiple updates in a single response, in order" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A2") UID PARTIAL (1:5 10,20,30,40,50) COUNT 5')
    )
    assert_equal [10, 20, 30, 40, 50], context.to_a

    # ADDTO shifts positions before REMOVEFROM is applied, and a later
    # ADDTO sees the result of the removal.
    context.update(
      esearch('* ESEARCH (TAG "A2") UID ADDTO 2:15 REMOVEFROM 5 ADDTO 5:55')
    )
    assert_equal [10, 15, 20, 30, 55, 50], context.to_a
    assert_equal 6, context.count
  end

  test "positions in one REMOVEFROM all refer to the same current result" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A3") UID ALL 1,2,3,4,5')
    )
    assert_equal [1, 2, 3, 4, 5], context.to_a

    # positions 2 and 4 of [1,2,3,4,5], removed as a set
    context.update(esearch('* ESEARCH (TAG "A3") UID REMOVEFROM 2,4'))
    assert_equal [1, 3, 5], context.to_a

    # successive REMOVEFROM data applies to the updated result:
    # [1,3,5] -[pos 1]-> [3,5] -[pos 2]-> [3]
    context.update(esearch('* ESEARCH (TAG "A3") UID REMOVEFROM 1 REMOVEFROM 2'))
    assert_equal [3], context.to_a
  end

  test "CONTEXT=SORT order is preserved, not treated as a sorted UID set" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A4") UID PARTIAL (1:4 30,10,40,20) COUNT 4')
    )
    assert_equal [30, 10, 40, 20], context.to_a

    context.update(esearch('* ESEARCH (TAG "A4") UID ADDTO 2:25'))
    assert_equal [30, 25, 10, 40, 20], context.to_a

    context.update(esearch('* ESEARCH (TAG "A4") UID REMOVEFROM 4'))
    assert_equal [30, 25, 10, 20], context.to_a
  end

  test "unknown positions are UNKNOWN, never empty" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A5") UID PARTIAL (1:3 10,20,30) COUNT 6')
    )
    assert_equal 6, context.count
    assert_equal 3, context.known_count
    refute context.fully_known?
    assert context.partial?
    assert_equal [10, 20, 30, UNKNOWN, UNKNOWN, UNKNOWN], context.to_a
    assert_equal UNKNOWN, context[5]
    assert_nil context[7]

    # an addition inside the known window shifts the unknown positions
    context.update(esearch('* ESEARCH (TAG "A5") UID ADDTO 2:15'))
    assert_equal [10, 15, 20, 30, UNKNOWN, UNKNOWN, UNKNOWN], context.to_a
    assert_equal 7, context.count

    # a removal from an unknown position shrinks the unknown tail
    context.update(esearch('* ESEARCH (TAG "A5") UID REMOVEFROM 7'))
    assert_equal [10, 15, 20, 30, UNKNOWN, UNKNOWN], context.to_a
    assert_equal 6, context.count
    assert_equal 4, context.known_count
  end

  test "unknown tail without COUNT is observable and not empty" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A6") UID PARTIAL (1:3 10,20,30)')
    )
    assert_nil context.count
    refute context.fully_known?
    assert_equal [10, 20, 30], context.to_a
    assert_equal [10, 20, 30], context.each_known.to_a

    # updates inside the known prefix still apply precisely
    context.update(esearch('* ESEARCH (TAG "A6") UID ADDTO 2:15'))
    assert_equal [10, 15, 20, 30], context.to_a
    assert_nil context.count

    context.update(esearch('* ESEARCH (TAG "A6") UID REMOVEFROM 1'))
    assert_equal [15, 20, 30], context.to_a

    # a later COUNT makes the total (and its unknown positions) observable
    context.update(esearch('* ESEARCH (TAG "A6") UID COUNT 5'))
    assert_equal 5, context.count
    assert_equal [15, 20, 30, UNKNOWN, UNKNOWN], context.to_a
  end

  test "PARTIAL (1:n NIL) seeds an empty, fully known result" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A7") UID PARTIAL (1:100 NIL) COUNT 0')
    )
    assert_equal 0, context.count
    assert context.fully_known?
    assert_equal [], context.to_a

    context.update(esearch('* ESEARCH (TAG "A7") UID ADDTO 1:42'))
    assert_equal [42], context.to_a
  end

  test "update with mismatched correlator tag raises ArgumentError" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A8") UID PARTIAL (1:2 10,20)')
    )
    assert_raise(ArgumentError) {
      context.update(esearch('* ESEARCH (TAG "OTHER") UID ADDTO 1:99'))
    }
    assert_raise(TypeError) { context.update("not an esearch") }
  end

  test "updates are ignored once the context is no longer active" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "A9") UID PARTIAL (1:2 10,20) COUNT 2')
    )
    assert context.active?
    context.noupdates!
    assert context.noupdates?
    context.update(esearch('* ESEARCH (TAG "A9") UID ADDTO 1:99'))
    assert_equal [10, 20], context.to_a
  end

  test "state transitions are observable and terminal" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "B1") UID PARTIAL (1:2 10,20)')
    )
    assert_equal :active, context.state
    context.noupdates!
    assert_equal :noupdates, context.state
    context.cancel! # already terminal: noupdates wins
    assert_equal :noupdates, context.state

    context = SearchContext.new(
      esearch('* ESEARCH (TAG "B2") UID PARTIAL (1:2 10,20)')
    )
    context.cancel!
    assert context.cancelled?

    context = SearchContext.new(
      esearch('* ESEARCH (TAG "B3") UID PARTIAL (1:2 10,20)')
    )
    context.close!
    assert context.closed?
    refute context.active?
  end

  test "#each, #each_known, #to_sequence_set" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "C1") UID PARTIAL (1:3 10,20,30) COUNT 4')
    )
    assert_kind_of Enumerator, context.each
    assert_equal [10, 20, 30, UNKNOWN], context.each.to_a
    assert_kind_of Enumerator, context.each_known
    assert_equal [10, 20, 30], context.each_known.to_a
    assert_equal Net::IMAP::SequenceSet[10, 20, 30], context.to_sequence_set
  end

  test "negative PARTIAL range is placed with COUNT, unknown without it" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "D2") UID PARTIAL (-2:-1 40,50) COUNT 5')
    )
    assert_equal [UNKNOWN, UNKNOWN, UNKNOWN, 40, 50], context.to_a
    assert_equal 5, context.count
    assert_equal 2, context.known_count

    # without COUNT, absolute positions are unknowable: not empty, unknown
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "D3") UID PARTIAL (-2:-1 40,50)')
    )
    assert_nil context.count
    refute context.fully_known?
    assert_equal [], context.to_a
    assert_equal [], context.each_known.to_a
  end

  test "seeded from ALL return data" do
    context = SearchContext.new(
      esearch('* ESEARCH (TAG "C2") UID ALL 3,1,2')
    )
    # the written order is preserved (significant for CONTEXT=SORT)
    assert_equal [3, 1, 2], context.to_a
    assert_equal 3, context.count
    assert context.fully_known?
  end

end
