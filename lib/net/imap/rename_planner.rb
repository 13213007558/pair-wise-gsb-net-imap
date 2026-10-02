# frozen_string_literal: true

require "set"

module Net
  class IMAP < Protocol

    # Builds an offline sequence of RENAME commands from the complete mailbox
    # hierarchy returned by LIST, the hierarchy delimiter, and a mapping from
    # original mailbox identities to desired full mailbox names.
    #
    # The planner never sends commands and the resulting plan is not an atomic
    # batch rename.  Commands are intended to be executed one at a time.  After
    # each successful command, RenamePlan#execute records every original mailbox
    # identity that was moved by the server's parent-rename cascade.
    class RenamePlanner

      # One executable RENAME command.  +temporary+ commands are inserted only
      # when required to break a rename cycle.
      Command = Data.define(:identity, :from, :to, :temporary, :affected, :suffixes) do
        def to_a = [from, to]
        def temporary? = temporary
      end

      # An ordered, non-atomic rename plan.
      class Plan
        def initialize(commands, locations, final_locations, requested)
          @commands = commands
          @locations = locations.transform_values(&:itself)
          @final_locations = final_locations
          @requested = requested
          @position = 0
          @moved = Set.new
        end

        attr_reader :commands

        include Enumerable

        def each(&block)
          return enum_for(__method__) unless block
          @commands.each(&block)
        end

        def size = @commands.size
        def empty? = @commands.empty?
        def next_command = @commands[@position]
        def remaining = @commands[@position..] || []
        def current_location(identity) = @locations.fetch(identity)
        def moved_identities = @moved.to_a.freeze

        def completed_identities
          @moved.select { @locations.fetch(_1) == @final_locations.fetch(_1) }.to_a.freeze
        end

        def pending_identities
          @requested.select {
            @locations.fetch(_1) != @final_locations.fetch(_1)
          }.to_a.freeze
        end

        # Executes the next command by calling <tt>client.rename(from, to)</tt>,
        # then records the cascade performed by the server.  This sends one
        # ordinary command at a time and is not an atomic batch rename.
        def execute(client, command = next_command)
          command = fetch_command(command)
          client.rename(command.from, command.to)

          command.affected.each do |identity|
            @locations[identity] = command.to + command.suffixes.fetch(identity)
            @moved.add(identity)
          end

          @position += 1
          command
        end

        private

        def fetch_command(command)
          command = @commands[command] if command.is_a?(Integer)
          unless command.equal?(@commands[@position])
            raise ArgumentError, "command is not the next planned command"
          end
          command
        end

      end

      RenamePlan = Plan

      # A validation problem detected before any command is built.
      Problem = Data.define(:reason, :identity, :target, :message)

      # Raised when one or more requested renames are invalid.  #problems
      # reports every detected problem rather than failing on the first one.
      class InvalidPlanError < Error
        attr_reader :problems

        def initialize(problems)
          @problems = problems
          super(problems.map(&:message).join("; "))
        end
      end

      # Convenience method for building a one-off plan.
      def self.plan(list, renames, delimiter:, namespaces: nil, namespace: nil)
        new(list, delimiter:, namespaces: namespaces || namespace).plan(renames)
      end

      def initialize(list, delimiter:, namespaces: nil, namespace: nil)
        unless delimiter.is_a?(String) && delimiter.length == 1
          raise ArgumentError, "delimiter must be a single-character String"
        end
        @delimiter = delimiter
        @namespaces = build_namespaces(namespaces || namespace)
        @attributes = {}
        @mailboxes = build_mailboxes(list)
      end

      def plan(renames)
        requests = normalize_requests(renames)
        validate(requests)

        current = @mailboxes.to_h { [_1, _1] }
        final = final_locations(requests)
        pending = Set.new(requests.keys)
        temporary_identities = Set.new
        commands = []

        until pending.empty?
          identity = executable_identity(
            pending, current, final, temporary_identities
          )

          if identity
            target = final.fetch(identity)
            temporary = false
          else
            identity = (pending - temporary_identities).first || pending.first
            target = temporary_name(identity, current, final)
            temporary = true
          end

          source = current.fetch(identity)
          commands << Command.new(
            identity, source, target, temporary,
            current_subtree_identities(identity, current),
            subtree_suffixes(identity, current)
          )
          apply_rename!(current, identity, source, target)
          if temporary
            temporary_identities.add(identity)
          else
            pending.delete(identity)
            temporary_identities.delete(identity)
          end
        end

        Plan.new(commands, current, final, requests.keys)
      end

      private

      def build_namespaces(namespaces)
        entries = case namespaces
        when nil
          [{prefix: "", delim: @delimiter}]
        when Array
          namespaces
        else
          Array(namespaces)
        end

        entries.map {
          case _1
          when Namespace
            [_1.prefix, _1.delim]
          when Hash
            [_1.fetch(:prefix), _1[:delim] || @delimiter]
          else
            [_1, @delimiter]
          end
        }.map { [String(_1), _2] }.uniq.freeze
      end

      def build_mailboxes(list)
        names = Array(list).map do |entry|
          if entry.respond_to?(:name)
            @attributes[entry.name] = Array(entry.attr)
            String(entry.name)
          else
            String(entry)
          end
        end
        duplicates = names.tally.select { _2 > 1 }
        unless duplicates.empty?
          raise ArgumentError, "duplicate mailbox in LIST: #{duplicates.keys.join(", ")}"
        end
        names.freeze
      end

      def normalize_requests(renames)
        renames.to_h.transform_keys { String(_1) }.transform_values { String(_1) }
      rescue NoMethodError, TypeError, ArgumentError
        raise ArgumentError, "renames must be convertible to a Hash"
      end

      def validate(requests)
        known = @mailboxes.to_set
        final = final_locations(requests)
        problems = []

        requests.each do |identity, target|
          source_namespace = namespace_for(identity, allow_unknown: true)
          target_namespace = namespace_for(target, allow_unknown: true)

          add_problem(problems, :unknown_mailbox, identity, target,
                      "#{identity.inspect} is not in LIST") unless known.include?(identity)
          unless target_namespace
            add_problem(problems, :unknown_namespace, identity, target,
                        "#{target.inspect} is outside all known namespaces")
          end
          if source_namespace && target_namespace && source_namespace != target_namespace
            add_problem(problems, :cross_namespace, identity, target,
                        "cannot rename #{identity.inspect} across namespaces to #{target.inspect}")
          end
          if inbox?(identity) || inbox?(target)
            add_problem(problems, :inbox, identity, target,
                        "INBOX has special rename semantics and cannot be included in a rename plan")
          end
          validate_name(identity, source_namespace, problems)
          validate_name(target, target_namespace, problems)
          if path_inside?(target, identity, source_namespace)
            add_problem(problems, :own_descendant, identity, target,
                        "cannot rename #{identity.inspect} into its own subtree #{target.inspect}")
          end
          validate_no_inferiors_target(identity, target, final, problems)
          validate_target_parent(identity, target, final, requests, problems)
        end

        requests.group_by { _2 }.each do |target, group|
          next unless group.size > 1
          identities = group.map(&:first).map(&:inspect).join(", ")
          add_problem(problems, :duplicate_target, nil, target,
                      "duplicate target #{target.inspect} requested for #{identities}")
        end

        final.group_by(&:last).each do |target, group|
          next unless group.size > 1
          identities = group.map(&:first)
          add_problem(problems, :duplicate_final_target, nil, target,
                      "duplicate final target #{target.inspect} for #{identities.map(&:inspect).join(", ")}")
        end

        raise InvalidPlanError.new(problems) unless problems.empty?
      end

      def add_problem(problems, reason, identity, target, message)
        problems << Problem.new(reason, identity, target, message)
      end

      def validate_name(name, namespace, problems)
        return unless namespace
        relative = relative_name(name, namespace)
        _, delim = namespace
        invalid = relative.empty? || relative.include?("\0") ||
          relative.include?("\r") || relative.include?("\n")
        invalid ||= delim && (
          relative.start_with?(delim) || relative.end_with?(delim) ||
            relative.include?(delim * 2)
        )
        if invalid
          add_problem(problems, :invalid_name, nil, name,
                      "#{name.inspect} is not a valid mailbox name")
        end
      end

      def validate_no_inferiors_target(identity, target, final, problems)
        final.each do |ancestor_identity, ancestor_path|
          next if ancestor_identity == identity
          next unless path_inside?(target, ancestor_path, namespace_for(target, allow_unknown: true))
          next unless @attributes.fetch(ancestor_identity, []).include?(:Noinferiors)
          add_problem(problems, :no_inferiors, identity, target,
                      "cannot rename #{identity.inspect} under #{ancestor_path.inspect} because it has \\NoInferiors")
        end
      end

      def validate_target_parent(identity, target, final, requests, problems)
        namespace = namespace_for(target, allow_unknown: true)
        return unless namespace
        prefix, delim = namespace
        return unless delim

        relative = relative_name(target, namespace)
        return unless relative.include?(delim)

        parent_relative, = relative.rpartition(delim)
        parent = prefix + parent_relative
        return if final.value?(parent) || requests.key?(parent)

        add_problem(problems, :missing_parent, identity, target,
                    "target #{target.inspect} requires existing parent mailbox #{parent.inspect}")
      end

      def final_locations(requests)
        @mailboxes.to_h do |identity|
          if requests.key?(identity)
            [identity, requests.fetch(identity)]
          else
            ancestor = cascade_ancestor(identity, requests)
            if ancestor
              [identity, requests.fetch(ancestor) + identity[ancestor.length..]]
            else
              [identity, identity]
            end
          end
        end
      end

      def cascade_ancestor(identity, requests)
        requests.keys
          .select { path_inside?(identity, _1, namespace_for(identity, allow_unknown: true)) }
          .max_by(&:length)
      end

      def executable_identity(pending, current, final, temporary_identities)
        pending.find do |identity|
          source = current.fetch(identity)
          target = final.fetch(identity)
          next false if source == target
          next false if path_inside?(target, source, namespace_for(identity))
          next false if target_occupied?(identity, source, target, current)
          next false if waits_for_current_ancestor?(
            identity, target, pending, current, final, temporary_identities
          )
          next false if waits_for_ancestor?(identity, target, pending, final)
          true
        end
      end

      def target_occupied?(identity, source, target, current)
        current.any? do |other, location|
          next false if other == identity
          next false if location == source || path_inside?(location, source, namespace_for(identity))
          location == target || path_inside?(location, target, namespace_for(identity))
        end
      end

      def waits_for_ancestor?(identity, target, pending, final)
        pending.any? do |other|
          next false if other == identity
          ancestor = final.fetch(other)
          path_inside?(target, ancestor, namespace_for(identity))
        end
      end

      def waits_for_current_ancestor?(identity, target, pending, current,
                                     final, temporary_identities)
        pending.any? do |other|
          next false if other == identity
          ancestor = current.fetch(other)
          next false if ancestor == final.fetch(other)
          next false if temporary_identities.include?(other)
          target == ancestor || path_inside?(target, ancestor, namespace_for(identity))
        end
      end

      def temporary_name(identity, current, final)
        namespace = namespace_for(identity)
        1.step do |index|
          label = "net-imap-rename-#{$$}-#{object_id}-#{index}"
          candidate = join_namespace(namespace, label)
          occupied = (current.values + final.values).any? do |path|
            candidate == path ||
              path_inside?(path, candidate, namespace) ||
              path_inside?(candidate, path, namespace_for(path, allow_unknown: true))
          end
          return candidate unless occupied
        end
      end

      def apply_rename!(locations, identity, source, target)
        current_subtree_identities(identity, locations).each do |child|
          location = locations.fetch(child)
          suffix = child == identity ? "" : location[source.length..]
          locations[child] = target + suffix
        end
      end

      def current_subtree_identities(identity, current)
        source = current.fetch(identity)
        namespace = namespace_for(identity)
        current.keys.select do |other|
          other == identity || path_inside?(current.fetch(other), source, namespace)
        end
      end

      def subtree_suffixes(identity, current)
        source = current.fetch(identity)
        current_subtree_identities(identity, current).to_h do |other|
          location = current.fetch(other)
          [other, other == identity ? "" : location[source.length..]]
        end
      end

      def namespace_for(name, allow_unknown: false)
        match = @namespaces
          .select { |prefix, delim| name.start_with?(prefix) && valid_relative?(name, prefix, delim) }
          .max_by { _1.first.length }
        match || (allow_unknown ? nil : @namespaces.first)
      end

      def valid_relative?(name, prefix, delim)
        relative = name[prefix.length..]
        delim.nil? || !relative.include?(@delimiter) || delim == @delimiter
      end

      def relative_name(name, namespace)
        name[namespace.first.length..]
      end

      def join_namespace(namespace, label)
        prefix, delim = namespace
        return prefix + label if delim.nil? || prefix.empty? || prefix.end_with?(delim)
        prefix + delim + label
      end

      def path_inside?(path, ancestor, namespace = namespace_for(ancestor, allow_unknown: true))
        return false unless namespace
        _, delim = namespace
        !!delim && path != ancestor && path.start_with?(ancestor + delim)
      end

      def inbox?(name)
        namespace = namespace_for(name, allow_unknown: true) || @namespaces.first
        relative_name(name, namespace)&.casecmp?("INBOX")
      end
    end
  end
end
