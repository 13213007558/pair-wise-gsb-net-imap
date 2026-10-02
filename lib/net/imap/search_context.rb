# frozen_string_literal: true

module Net
  class IMAP

    # SearchContext is an ordered, updatable view of a <tt>CONTEXT=SEARCH</tt>
    # or <tt>CONTEXT=SORT</tt> "search context"
    # {[RFC5267]}[https://www.rfc-editor.org/rfc/rfc5267.html].
    #
    # When a SEARCH, UID SEARCH, SORT, or UID SORT command uses the +PARTIAL+
    # return option on a server that supports <tt>CONTEXT=SEARCH</tt> or
    # <tt>CONTEXT=SORT</tt>, the server creates a search context and sends
    # untagged +ESEARCH+ updates (with +ADDTO+ and +REMOVEFROM+ return data)
    # as messages are added to or removed from the result.  This avoids
    # polling the server with repeated SEARCH commands.
    #
    # A SearchContext is seeded from the ESearchResult of the command that
    # created the context, and updated with each subsequent ESearchResult
    # that carries the same correlator #tag.  Use IMAP#search_contexts to
    # route server updates to their contexts automatically:
    #
    #   result = imap.uid_search(["FLAGGED"], return: [:PARTIAL, 1..100])
    #   context = imap.search_contexts.track(result)
    #   # ... later, after the server sent updates:
    #   context.to_a # => current ordered result
    #
    # ==== Ordered results, not a sorted set
    #
    # The result is an ordered list of message sequence numbers or UIDs, in
    # the order reported by the server (mailbox order for
    # <tt>CONTEXT=SEARCH</tt>, sort order for <tt>CONTEXT=SORT</tt>).  It is
    # *not* merely a sorted set of UIDs: positions are significant, and
    # +ADDTO+/+REMOVEFROM+ updates refer to positions in the *current*
    # result, as required by the protocol.
    #
    # ==== Partially known results
    #
    # When the initial result (or the known window) only covers part of the
    # result---for example, <tt>PARTIAL (1:100 ...)</tt> with a larger
    # +COUNT+---the unknown positions are represented by the UNKNOWN
    # sentinel, never by "empty" values.  Use #fully_known?, #count,
    # #known_count, and #to_a to observe exactly which parts are known.
    class SearchContext
      include Enumerable

      # A sentinel value marking result positions whose message sequence
      # number or UID is not (currently) known to the client.  Unknown
      # positions are never silently dropped or treated as empty.
      UNKNOWN = Object.new
      class << UNKNOWN
        def inspect; "Net::IMAP::SearchContext::UNKNOWN" end
        alias to_s inspect
      end
      UNKNOWN.freeze

      # The correlator tag of the command that created this search context.
      # Untagged +ESEARCH+ updates are matched to their context by this tag.
      attr_reader :tag

      # A description of the command that created this search context, when
      # it was provided to #initialize or SearchContextTracker#track.
      attr_reader :command

      # Creates a search context, optionally seeded from the ESearchResult
      # +esearch+ of the command that created the server-side context.
      #
      # [+esearch+]
      #   An ESearchResult with a correlator tag.  The context is seeded
      #   from its +ALL+, +PARTIAL+, and +COUNT+ return data.
      # [+tag+]
      #   The correlator tag.  Defaults to <tt>esearch.tag</tt>.  Required.
      # [+uid+]
      #   Whether results are UIDs (+true+) or message sequence numbers
      #   (+false+).  Defaults to <tt>esearch.uid?</tt>.
      # [+command+]
      #   An optional description of the command that created the context,
      #   kept so the correlator #tag can be traced back to its command.
      def initialize(esearch = nil, tag: nil, uid: false, command: nil)
        @entries = []
        @total   = nil
        if esearch
          ESearchResult === esearch or
            raise TypeError, "expected ESearchResult, got %s" % esearch.class
          tag ||= esearch.tag
          uid   = esearch.uid?
          seed_from_esearch(esearch)
        end
        tag => String | nil
        tag or raise ArgumentError, "missing search context correlator tag"
        @tag     = -tag
        @uid     = !!uid
        @command = command
        @state   = :active
      end

      # Whether the results are UIDs (+true+) or message sequence numbers
      # (+false+).
      def uid?; @uid end

      ##
      # :method: state
      # :call-seq: state -> :active, :noupdates, :cancelled, or :closed
      #
      # The state of this search context:
      # [:active]
      #   The server is expected to send updates for this context.
      # [:noupdates]
      #   The server sent a +NOUPDATE+ response code for this context: no
      #   further updates will be sent.
      # [:cancelled]
      #   The client cancelled updates with a +CANCELUPDATE+ command.
      # [:closed]
      #   The mailbox was closed or deselected (or the connection was
      #   lost), which implicitly destroys every server-side context.
      attr_reader :state

      # Whether this context is expected to receive server updates.
      def active?;    @state == :active    end

      # Whether the server sent +NOUPDATE+ for this context.
      def noupdates?; @state == :noupdates end

      # Whether updates for this context were cancelled by +CANCELUPDATE+.
      def cancelled?; @state == :cancelled end

      # Whether the mailbox (or connection) for this context was closed.
      def closed?;    @state == :closed    end

      # Marks the context as no longer updated by the server (+NOUPDATE+).
      def noupdates!; transition_to(:noupdates) end

      # Marks the context as cancelled by the client (+CANCELUPDATE+).
      def cancel!;    transition_to(:cancelled) end

      # Marks the context as destroyed by a mailbox close or deselect.
      def close!;     transition_to(:closed)    end

      # :call-seq: count -> integer or nil
      #
      # The total number of messages in the result, or +nil+ when the total
      # is unknown (the server did not return +COUNT+ and the known window
      # does not cover the entire result).  A +nil+ count means the result
      # may continue beyond the last known position---it does *not* mean
      # the result is empty.
      def count; @total end
      alias size count

      # The number of result positions whose value is known.
      def known_count; @entries.count { !_1.equal?(UNKNOWN) } end

      # Whether every position in the result is known.
      def fully_known?; !@total.nil? && known_count == @total end

      # Whether any part of the result is unknown.  Unknown parts are
      # represented by UNKNOWN in #to_a and #each---never by empty values.
      def partial?; !fully_known? end

      # :call-seq: [](position) -> integer, UNKNOWN, or nil
      #
      # Returns the result at 1-based +position+, UNKNOWN when the position
      # exists but its value is unknown, or +nil+ when +position+ is beyond
      # every known position.
      def [](position)
        return nil unless Integer === position && position >= 1
        @entries[position - 1]
      end

      # Returns the ordered result as an array of message sequence numbers
      # or UIDs.  Positions whose value is unknown contain UNKNOWN.  When
      # the total #count is unknown, only the known prefix is returned and
      # #fully_known? returns +false+.
      def to_a; @entries.dup end

      # Yields each result in order, including UNKNOWN sentinels for unknown
      # positions.  Use #each_known to skip unknown positions.
      def each(&block)
        return to_enum(__callee__) unless block_given?
        @entries.each(&block)
        self
      end

      # Yields each known result in order, skipping UNKNOWN positions.
      def each_known(&block)
        return to_enum(__callee__) unless block_given?
        @entries.each { |value| yield value unless value.equal?(UNKNOWN) }
        self
      end

      # Returns a SequenceSet of every known result.  Note that a sequence
      # set is unordered: for <tt>CONTEXT=SORT</tt> results, use #to_a to
      # preserve the sort order.
      def to_sequence_set
        known = each_known.to_a
        known.empty? ? SequenceSet.empty : SequenceSet[*known]
      end

      # Applies an ESearchResult update (+ADDTO+, +REMOVEFROM+, +PARTIAL+,
      # +ALL+, and +COUNT+ return data) to this context, in the order the
      # return data appears in the response.  Positions always refer to the
      # current result, as updated by any preceding return data in the same
      # response.
      #
      # The correlator tag of +esearch+ must match #tag.  Updates are
      # ignored when the context is no longer #active?.
      #
      # Returns self.
      def update(esearch)
        ESearchResult === esearch or
          raise TypeError, "expected ESearchResult, got %s" % esearch.class
        unless esearch.tag == tag
          raise ArgumentError,
                "ESEARCH correlator tag %p does not match context tag %p" % [
                  esearch.tag, tag
                ]
        end
        return self unless active?
        esearch.data.each do |name, value|
          case name
          when "ADDTO"      then apply_addto(value)
          when "REMOVEFROM" then apply_removefrom(value)
          when "PARTIAL"    then apply_partial(value)
          when "ALL"        then apply_all(value)
          when "COUNT"      then apply_count(value)
          end
        end
        self
      end

      def inspect # :nodoc:
        entries = @entries.map { _1.equal?(UNKNOWN) ? "UNKNOWN" : _1.inspect }
        "#<Net::IMAP::SearchContext tag=%p uid=%p state=%p count=%p entries=[%s]>" % [
          tag, uid?, state, count, entries.join(", ")
        ]
      end

      private

      def transition_to(state)
        @state = state if @state == :active
        self
      end

      def seed_from_esearch(esearch)
        if (all = esearch.all)
          @entries = ordered_numbers(all)
          @total   = @entries.size
        elsif (partial = esearch.partial)
          results = partial.results
          values  = results ? ordered_numbers(results) : []
          range   = partial.range
          if range.begin >= 1
            @entries = Array.new(range.begin - 1, UNKNOWN).concat(values)
            # PARTIAL (1:n NIL) means the result is empty.
            @total   = 0 if results.nil? && range.begin == 1
          elsif (count = esearch.count)
            # A negative partial-range is relative to the end of the
            # result, so a known COUNT is needed to place its values.
            start    = [count + range.begin, 0].max
            @entries = Array.new(start, UNKNOWN).concat(values).first(count)
          end
          # Without a known COUNT, positions in a negative partial-range
          # cannot be placed in the absolute result: every position stays
          # unknown (which is not the same as empty).
        end
        apply_count(esearch.count) if esearch.count
      end

      # Expands a sequence set into an array of numbers, preserving the
      # order in which entries were written.  The order is significant for
      # CONTEXT=SORT results: they are not simply a sorted set of UIDs.
      def ordered_numbers(seqset)
        seqset.each_entry.flat_map {|entry|
          case entry
          when Range
            lo, hi = entry.minmax
            (lo..hi).to_a
          when Integer
            [entry]
          else
            []
          end
        }
      end

      def apply_addto(addto)
        addto.pairs.each { |position, message| insert_at(position, message) }
      end

      def apply_removefrom(removefrom)
        # All positions in a single REMOVEFROM refer to the result as it was
        # before this REMOVEFROM is applied, so they are removed as a set.
        removefrom.positions.each_number.reverse_each do |position|
          next if position < 1 || position > @entries.size
          @entries.delete_at(position - 1)
          @total -= 1 if @total
        end
      end

      def apply_partial(partial)
        results = partial.results or return
        ordered_numbers(results).each_with_index do |value, offset|
          position = partial.range.begin + offset
          next if position < 1
          if position <= @entries.size
            @entries[position - 1] = value
          elsif @total.nil?
            @entries.fill(UNKNOWN, @entries.size...position - 1)
            @entries << value
          end
        end
      end

      def apply_all(all)
        @entries = ordered_numbers(all)
        @total   = @entries.size
      end

      def apply_count(count)
        @total = [Integer(count), @entries.size].max
        @entries.fill(UNKNOWN, @entries.size...@total)
      end

      def insert_at(position, message)
        if @total
          position = position.clamp(1, @total + 1)
          @entries.insert(position - 1, message)
          @total += 1
        elsif position >= 1 && position <= @entries.size + 1
          @entries.insert(position - 1, message)
        end
        # When the total is unknown and the position lies beyond the known
        # prefix, the addition happens somewhere in the unknown tail: the
        # tail grows, but it stays unknown.
      end

    end

  end
end
