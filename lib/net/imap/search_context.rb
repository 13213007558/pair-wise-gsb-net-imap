# frozen_string_literal: true

module Net
  class IMAP

    # An ordered +SEARCH+ or +SORT+ result that can be updated by the
    # +CONTEXT=SEARCH+ or +CONTEXT=SORT+ extension (RFC5267).
    #
    # Unlike SequenceSet, this class preserves server order.  It also keeps
    # unknown portions of a +PARTIAL+ result distinct from the known portions,
    # so an unknown result is never confused with an empty result.
    class OrderedSearchResult
      def self.from_esearch(result)
        if (partial = result.partial)
          from_partial(partial, count: result.count)
        elsif (all = result.all)
          new(ordered_numbers(all), total_count: result.count || all.count)
        elsif !result.count.nil?
          new([], total_count: result.count, known_count: 0)
        else
          unknown
        end
      end

      def self.from_partial(partial, count: nil)
        values = partial.results&.numbers || []
        range  = partial.range
        chunks = []

        if range.begin.positive?
          before = range.begin - 1
          chunks << [:unknown, before] if before.positive?
          if values.empty?
            chunks << [:unknown, range.size]
            after = count ? count - before - range.size : nil
            chunks << [:unknown, after] if count && after.positive?
          else
            chunks << [:known, values]
            if count
              after = count - before - values.size
              chunks << [:unknown, after] if after.positive?
            else
              chunks << [:unknown, nil]
            end
          end
        else
          after = -range.end
          if count
            before = count - values.size - after
            chunks << [:unknown, before] if before.positive?
          else
            chunks << [:unknown, nil]
          end
          unless values.empty?
            chunks << [:known, values]
          end
          if count
            chunks << [:unknown, after] if after.positive?
          else
            chunks << [:unknown, after] if after.positive?
          end
        end

        new(chunks, total_count: count)
      end

      def self.known(values, total_count: nil)
        new(Array(values), total_count: total_count || Array(values).size)
      end

      def self.unknown(count = nil)
        new([[:unknown, count]])
      end

      def self.ordered_numbers(sequence_set)
        sequence_set.to_s.split(",").flat_map do |entry|
          first, last = entry.split(":", 2).map do |number|
            number == "*" ? SequenceSet::UINT32_MAX : Integer(number)
          end
          if last
            first <= last ? first.upto(last).to_a : first.downto(last).to_a
          else
            first
          end
        end
      rescue ArgumentError
        sequence_set.numbers
      end

      def initialize(values_or_chunks, total_count: nil, known_count: nil)
        @chunks = coerce_chunks(values_or_chunks)
        @total_count = total_count
        @total_count ||= count_known_chunks if known_count.nil? && fully_known?
      end

      attr_reader :chunks, :total_count

      def apply(update)
        return :unknown unless position_resolvable?(update)

        position = update.position
        offset   = 0
        index    = 0

        while index < chunks.size
          type, size = chunks[index]

          if type == :unknown
            if size.nil?
              before = position - offset - 1
              return :unknown if before.negative?

              if update.add?
                insert_unknown_open(index, before, update.uids)
                @total_count &&= @total_count + update.uids.size
                return :applied
              else
                return :unknown
              end
            elsif position <= offset + size
              if update.add?
                insert_within_unknown(index, position - offset - 1, size, update.uids)
              else
                remove_within_unknown(index, position - offset - 1, size)
              end
              @total_count &&= @total_count +
                (update.add? ? update.uids.size : -1)
              return :applied
            end

            offset += size
          else
            values = size
            local  = update.position - offset - 1

            if update.add? && local <= values.size
              values.insert(local, *update.uids)
              @total_count &&= @total_count + update.uids.size
              return :applied
            elsif update.remove? && local < values.size
              return :unknown unless values[local] == update.uids.first
              values.delete_at(local)
              following = chunks[index + 1]
              following[1] += 1 if
                following&.first == :unknown && following[1]
              @total_count &&= @total_count - 1
              return :applied
            elsif values.size + offset == 0 && local == 0
              return :unknown
            end

            offset += values.size
          end

          index += 1
        end

        :unknown
      end

      def to_a = known_results.dup
      alias numbers to_a

      def each(&block)
        return enum_for(__method__) unless block_given?
        known_results.each(&block)
        self
      end

      def to_sequence_set
        SequenceSet[*known_results]
      end

      def known_results
        chunks.filter_map {|type, values| values if type == :known }.flatten
      end

      def size = known_results.size
      alias length size
      alias known_count size

      def fully_known? = chunks.none? {|type,| type == :unknown }
      def partial? = !fully_known?
      alias unknown? partial?

      def unknown_prefix?
        chunks.first&.first == :unknown
      end

      def unknown_prefix_size
        chunks.first&.first == :unknown ? chunks.first[1] : 0
      end

      def unknown_suffix?
        chunks.last&.first == :unknown
      end

      def unknown_suffix_size
        chunks.last&.first == :unknown ? chunks.last[1] : 0
      end

      def unknown_count
        chunks.sum {|type, size| type == :unknown && size ? size : 0 }
      end

      def ==(other)
        other.is_a?(OrderedSearchResult) &&
          total_count == other.total_count &&
          chunks == other.chunks
      end

      alias eql? ==

      def hash = [self.class, total_count, chunks].hash

      def inspect
        "#<#{self.class} #{known_results.inspect} " \
          "total_count=#{total_count.inspect} chunks=#{chunks.inspect}>"
      end

      private

      def coerce_chunks(values_or_chunks)
        values = Array.try_convert(values_or_chunks)
        if values && values.all? { Integer === _1 }
          return [[:known, values.map(&:to_int)]]
        end

        Array(values_or_chunks).map do |chunk|
          type, size_or_values = chunk
          case type
          when :known
            values = Array(size_or_values).map(&:to_int)
            [:known, values]
          when :unknown
            size = size_or_values
            size = size.to_int unless size.nil?
            raise ArgumentError, "unknown size cannot be negative" if size&.negative?
            [:unknown, size]
          else
            raise ArgumentError, "invalid result chunk: #{type.inspect}"
          end
        end
      end

      def count_known_chunks
        chunks.sum {|type, values| type == :known ? values.size : 0 }
      end

      def position_resolvable?(update)
        return false unless update.position.positive?
        offset = 0
        chunks.each do |chunk|
          type, size = chunk
          if type == :known
            position = update.position - offset
            length   = size.size
            return true if update.add? ? position >= 1 && position <= length + 1
                                   : position >= 1 && position <= length
            offset += length
          elsif size
            return true if update.position <= offset + size
            offset += size
          else
            return false
          end
        end
        false
      end

      def insert_within_unknown(index, before, size, uids)
        after = size - before
        replacement = []
        replacement << [:unknown, before] if before.positive?
        replacement << [:known, uids.dup]
        replacement << [:unknown, after] if after.positive?
        chunks[index, 1] = replacement
      end

      def remove_within_unknown(index, before, size)
        after = size - before - 1
        replacement = []
        replacement << [:unknown, before] if before.positive?
        replacement << [:unknown, after] if after.positive?
        chunks[index, 1] = replacement
        chunks.delete_if {|type, size| type == :unknown && size == 0 }
      end

      def insert_unknown_open(index, before, uids)
        replacement = []
        replacement << [:unknown, before] if before.positive?
        replacement << [:known, uids.dup]
        replacement << [:unknown, nil]
        chunks[index, 1] = replacement
      end

      def remove_unknown_open(index, before)
        replacement = []
        replacement << [:unknown, before] if before.positive?
        replacement << [:unknown, nil]
        chunks[index, 1] = replacement
      end
    end

    # RFC5267 +ADDTO+ or +REMOVEFROM+ search context update.
    class SearchContextUpdate < Data.define(:name, :position, :uids, :before, :after)
      def initialize(name:, position:, uids:, before: nil, after: nil)
        name = -String(name)
        raise ArgumentError, "invalid update: #{name}" unless
          %w[ADDTO REMOVEFROM].include?(name)
        position = Integer(position)
        uids = Array(uids).map { Integer(_1) }
        super(name:, position:, uids:, before:, after:)
      end

      def add? = name == "ADDTO"
      def remove? = name == "REMOVEFROM"
      def to_a = uids.dup
      def to_sequence_set = SequenceSet[*uids]
    end

    # A server-correlated, updatable +SEARCH+ or +SORT+ context.
    class SearchContext
      def initialize(tag:, uid:, command:, result: nil, state: :active)
        @tag      = -tag
        @uid      = !!uid
        @command  = command
        @result   = result
        @state    = state.to_sym
        @updates  = []
        @ignored_updates = []
      end

      attr_reader :tag, :uid, :command, :result, :updates
      attr_reader :ignored_updates
      attr_accessor :state

      def set_initial_result(values)
        @result ||= OrderedSearchResult.known(values)
      end

      def set_initial_esearch(response)
        @result = OrderedSearchResult.from_esearch(response)
      end

      def replace_result(result)
        @result = result
      end

      def apply_esearch(response)
        return false unless response.is_a?(ESearchResult) && response.tag == tag
        return false unless mutable?
        if result.nil? && (response.all || response.partial || response.count)
          @result = OrderedSearchResult.from_esearch(response)
        end

        updates = response.data.filter_map do |_name, update|
          update if update.is_a?(SearchContextUpdate)
        end
        return true if updates.empty?

        if result.nil?
          @state = :unknown
          ignored_updates.concat(updates)
          return false
        end

        updates.each do |update|
          before = result.to_a
          applied = result.apply(update) == :applied
          after = result.to_a if applied
          @updates << update.with(before: before, after: after)
          unless applied
            @ignored_updates << update
            @state = :unknown
            return false
          end
        end

        true
      end

      def ignore_esearch(response)
        return false unless response.is_a?(ESearchResult) && response.tag == tag
        response.data.each do |_name, update|
          ignored_updates << update if update.is_a?(SearchContextUpdate)
        end
      end

      def apply_or_ignore_esearch(response)
        apply_esearch(response) || ignore_esearch(response)
      end

      def noupdate! = @state = :noupdate
      def cancel!
        @state = :cancelled unless terminal?
      end
      def invalidate! = @state = :invalid
      def close! = @state = :closed

      def active?     = state == :active
      def noupdate?   = state == :noupdate
      def cancelled?  = state == :cancelled
      def unknown?    = state == :unknown
      def invalid?    = state == :invalid
      def closed?     = state == :closed
      def terminal?   = cancelled? || invalid? || closed?
      def mutable?    = active? || unknown?

      def to_a = result&.to_a || []
      def each(&block)
        result&.each(&block)
        self
      end
      def to_sequence_set = result&.to_sequence_set || SequenceSet.empty
      def known_results = result&.known_results || []
      def fully_known? = result ? result.fully_known? : false
      def partial? = result ? result.partial? : true
      alias unknown_partial? partial?
      def result_unknown? = result.nil? || result.partial?
      def update_unknown? = state == :unknown

    end

  end
end
