# frozen_string_literal: true

require "set"

require_relative "errors"
require_relative "response_data"

module Net
  class IMAP < Protocol
    # Offline planner for a sequence of RENAME commands.
    #
    # The planner works from a complete +LIST+ result and does not send any
    # commands itself.  It accounts for servers moving descendants when a parent
    # mailbox is renamed, and it inserts temporary mailbox names to resolve
    # cycles such as two subtrees exchanging names.
    class RenamePlanner
      # A single RENAME command in a RenamePlan.
      #
      # +from+ and +to+ are the exact paths to send at this point in the plan.
      # +identity+ is the original LIST name represented by the moved subtree's
      # root.  +identities+ includes every original identity that the server
      # moves because of a parent RENAME.
      class Command < Data.define(:from, :to, :identity, :identities, :temporary)
        def initialize(from:, to:, identity:, identities:, temporary: false)
          super
        end

        def temporary? = temporary
      end

      # An executable, non-atomic sequence of RENAME commands.
      #
      # Each command becomes executable only after the preceding commands have
      # succeeded.  A failure leaves the plan partially executed on the server;
      # the server does not provide an atomic batch RENAME.
      class RenamePlan < Data.define(:commands)
        include Enumerable

        def each(...) = commands.each(...)
        def size = commands.size
        alias length size

        # Start executing the plan.  The caller sends each current_command and
        # calls Execution#advance only after the server reports success.
        def start
          Execution.new(self)
        end
      end
      Plan = RenamePlan

      # Tracks which original mailbox identities have already moved after each
      # confirmed successful command.
      class Execution
        attr_reader :index, :moved_identities

        def initialize(plan)
          @plan = plan
          @index = 0
          @moved_identities = Set.new
        end

        def current_command = @plan.commands[@index]
        def done? = @index >= @plan.commands.size
        # Returns true after a successful command confirmed this identity moved.
        def moved?(identity) = @moved_identities.include?(identity)

        def advance
          return if done?
          command = current_command
          @moved_identities.merge(command.identities)
          @index += 1
        end

        def remaining_commands = @plan.commands[@index..] || []
      end

      class Error < Net::IMAP::Error; end

      # Aggregates every problem discovered before any RENAME is sent.
      class InvalidRenames < Error
        attr_reader :problems

        def initialize(problems)
          @problems = problems
          super(problems.map { _1.fetch(:message) }.join("; "))
        end
      end

      Mailbox = Data.define(:name, :attr, :namespace) do
        def noinferiors?
          attr.any? { Symbol === _1 ? _1 == :Noinferiors : _1.to_s.casecmp?("Noinferiors") }
        end
      end

      private_constant :Mailbox

      TEMPORARY_PREFIX = "__net_imap_rename_planner_"
      private_constant :TEMPORARY_PREFIX

      # Builds a planner from a complete LIST result.
      #
      # +delimiter+ is required when the LIST entries do not each provide one.
      # +namespaces+ may be a Net::IMAP::Namespaces object, an enumerable of
      # Net::IMAP::Namespace objects, or an enumerable of [prefix, delimiter]
      # pairs.  When omitted, the supplied +delimiter+ defines one namespace
      # with an empty prefix.
      def initialize(list, delimiter: nil, namespaces: nil)
        @delimiter = delimiter
        @namespaces = normalize_namespaces(namespaces)
        @paths = build_mailboxes(list)
      end

      # Creates a plan without retaining a planner instance.
      def self.plan(renames, list:, delimiter: nil, namespaces: nil)
        new(list, delimiter:, namespaces:).plan(renames)
      end

      # Validates all requested renames and returns commands in an executable
      # order.  Raises InvalidRenames, without sending a command, when the batch
      # cannot be planned safely.
      def plan(renames)
        requested = normalize_renames(renames)
        problems = []
        explicit = {}
        target_sources = Hash.new { |hash, key| hash[key] = [] }
        source_targets = Hash.new { |hash, key| hash[key] = [] }

        requested.each do |source, target|
          original_source = source
          source_targets[source] << target
          if source_targets[source].size > 1
            problems << {
              identity: source,
              message: "duplicate rename request for #{source.inspect}",
            }
          end
          source = normalize_source(source)
          source = "INBOX" if source.casecmp?("INBOX") && @paths.key?("INBOX")
          mailbox = @paths[source]
          unless mailbox
            problems << {identity: original_source, message: "unknown mailbox: #{original_source.inspect}"}
            next
          end

          if inbox_name?(source, mailbox.namespace)
            problems << {
              identity: source,
              message: "INBOX cannot be renamed because its special semantics " \
                       "do not preserve a mailbox identity",
            }
          end

          target_info = resolve_target(target)
          unless target_info
            problems << {identity: source, target: target,
                          message: "invalid target name: #{target.inspect}"}
            next
          end

          unless target_info[:namespace] == mailbox.namespace
            problems << {
              identity: source,
              target: target,
              message: "cannot rename across namespaces: #{source.inspect} to #{target.inspect}",
            }
          end

          explicit[source] = target_info[:path]
          target_sources[target_info[:path]] << source
        end

        target_sources.each do |target, sources|
          next if sources.size <= 1
          problems << {
            target: target,
            message: "duplicate target #{target.inspect} requested by: " \
                     "#{sources.map(&:inspect).join(", ")}",
          }
        end

        final_paths = compute_final_paths(explicit)
        occupied = Hash.new { |hash, key| hash[key] = [] }
        effective = {}

        final_paths.each do |identity, final_path|
          occupied[final_path] << identity
          effective[identity] = final_path unless final_path == identity
        end

        effective.each do |identity, target|
          mailbox = @paths.fetch(identity)
          parent = parent_path(target, mailbox.namespace)
          parent_identity = parent.nil? ? nil : final_paths.key(parent)
          parent_mailbox = parent_identity && @paths.fetch(parent_identity)
          next if parent.nil?
          unless parent_identity
            problems << {identity: identity, target: target,
                          message: "target parent does not exist: #{parent.inspect}"}
          end
          if parent_mailbox&.noinferiors?
            problems << {identity: identity, target: target,
                          message: "target parent does not allow inferiors: #{parent.inspect}"}
          end
          if target != identity && under?(target, identity, mailbox.namespace)
            problems << {identity: identity, target: target,
                          message: "cannot rename a mailbox into its own subtree: #{target.inspect}"}
          end
        end

        occupied.each do |target, identities|
          next if identities.size <= 1
          problems << {
            target: target,
            message: "duplicate final target #{target.inspect} for identities: " \
                     "#{identities.map(&:inspect).join(", ")}",
          }
        end

        raise InvalidRenames.new(problems) unless problems.empty?

        schedule(effective)
      end

      private

      def normalize_namespaces(namespaces)
        case namespaces
        when nil
          [["", default_delimiter]]
        when Net::IMAP::Namespaces
          [*namespaces.personal, *namespaces.other, *namespaces.shared]
            .map { [_1.prefix, _1.delim] }
        when Enumerable
          namespaces.map do |namespace|
            case namespace
            when Net::IMAP::Namespace then [namespace.prefix, namespace.delim]
            when Array then [String(namespace.fetch(0)), namespace.fetch(1)]
            else
              raise ArgumentError, "invalid namespace: #{namespace.inspect}"
            end
          end
        else
          raise ArgumentError, "invalid namespaces: #{namespaces.inspect}"
        end.map do |prefix, delimiter|
          raise ArgumentError, "namespace delimiter must be a non-empty string" unless nonempty_string?(delimiter)
          [prefix, delimiter]
        end.uniq.freeze
      end

      def default_delimiter
        unless nonempty_string?(@delimiter)
          raise ArgumentError, "delimiter must be a non-empty string"
        end
        @delimiter
      end

      def build_mailboxes(list)
        list.each_with_object({}) do |entry, result|
          case entry
          when String
            name = entry
            attr = []
          when Net::IMAP::MailboxList
            name = entry.name
            attr = Array(entry.attr)
          else
            raise ArgumentError, "invalid mailbox list entry: #{entry.inspect}"
          end
          next if name.nil? || name.empty?
          delimiter = expected_delim(entry)
          if delimiter && name.end_with?(delimiter)
            stripped = name.delete_suffix(delimiter)
            name = stripped unless stripped.empty?
          end
          namespace = resolve_namespace(name, delimiter)
          unless namespace
            namespace, delimiter, name = resolve_ambiguous_list_name(name)
          end
          namespace or
            raise ArgumentError, "mailbox is outside known namespaces: #{name.inspect}"
          delimiter ||= namespace[1]
          unless delimiter == namespace[1]
            raise ArgumentError, "mailbox delimiter does not match its namespace delimiter: #{name.inspect}"
          end
          if result.key?(name)
            raise ArgumentError, "duplicate mailbox in LIST: #{name.inspect}"
          end
          result[name] = Mailbox.new(name, attr.dup.freeze, namespace)
        end
      end

      def expected_delim(entry)
        case entry
        when Net::IMAP::MailboxList then entry.delim || @delimiter
        else
          @delimiter
        end
      end

      def resolve_ambiguous_list_name(name)
        @namespaces.each do |prefix, candidate_delim|
          next unless name.start_with?(prefix) && name.end_with?(candidate_delim)
          candidate_name = name.delete_suffix(candidate_delim)
          next if candidate_name.empty?
          namespace = resolve_namespace(candidate_name, candidate_delim)
          return [namespace, candidate_delim, candidate_name] if namespace
        end
        [nil, nil, name]
      end

      def normalize_source(source)
        return source if @paths.key?(source)
        @namespaces.each do |prefix, delimiter|
          next unless source.start_with?(prefix) && source.end_with?(delimiter)
          candidate = source.delete_suffix(delimiter)
          return candidate if @paths.key?(candidate)
        end
        source
      end

      def normalize_renames(renames)
        case renames
        when Hash
          renames.map { |source, target| [String(source), target] }
        when Enumerable
          renames.map { |source, target| [String(source), target] }
        else
          raise ArgumentError, "renames must be a Hash or Enumerable of pairs"
        end
      end

      def resolve_target(target)
        return nil unless String === target
        return nil unless nonempty_string?(target)
        return nil if target.include?("\0")
        namespace = resolve_namespace(target) or return nil
        delimiter = namespace[1]
        if target.end_with?(delimiter)
          stripped = target.delete_suffix(delimiter)
          target = stripped unless stripped.empty?
        end
        relative = target.delete_prefix(namespace[0])
        return nil if relative.empty? || relative.include?(delimiter * 2)
        return nil if relative.start_with?(delimiter) || relative.end_with?(delimiter)
        return nil if !relative.include?(delimiter) && relative.casecmp?("INBOX")
        {path: target, namespace: namespace}
      end

      def compute_final_paths(explicit)
        @paths.keys.to_h do |identity|
          final = explicit[identity]
          unless final
            ancestor = explicit.keys
              .select { identity != _1 && under?(identity, _1, @paths.fetch(_1).namespace) }
              .max_by(&:length)
            final = ancestor ? explicit[ancestor] + identity.delete_prefix(ancestor) : identity
          end
          [identity, final]
        end
      end

      def schedule(effective)
        current_paths = @paths.keys.to_h { [_1, _1] }
        commands = []
        pending = effective.dup

        until pending.empty?
          identity, target = pending.find do |candidate, candidate_target|
            rename_available?(current_paths, candidate, candidate_target)
          end

          unless identity
            identity, target = pending.find do |candidate, candidate_target|
              occupant = current_paths.find { |_, current_path| current_path == candidate_target }&.first
              occupant && occupant != candidate
            end
            unless identity
              raise InvalidRenames.new([{
                message: "unable to schedule rename of #{pending.first[0].inspect} to " \
                         "#{pending.first[1].inspect}",
              }])
            end

            mailbox = @paths.fetch(identity)
            source = current_paths.fetch(identity)
            temporary_path = temporary_path(current_paths, mailbox.namespace, effective.values)
            append_command!(commands, current_paths, identity, source, temporary_path, temporary: true)
            pending.delete_if { |candidate, target| current_paths[candidate] == target }
            next
          end

          source = current_paths.fetch(identity)
          append_command!(commands, current_paths, identity, source, target)
          pending.delete_if { |candidate, candidate_target| current_paths[candidate] == candidate_target }
          pending.delete(identity)
        end

        Plan.new(commands.freeze)
      end

      def rename_available?(current_paths, identity, target)
        source = current_paths.fetch(identity)
        return false if source == target
        return false if current_paths.value?(target)
        return false if under?(target, source, @paths.fetch(identity).namespace)

        mailbox = @paths.fetch(identity)
        parent = parent_path(target, mailbox.namespace)
        return false if parent && !current_paths.value?(parent)
        true
      end

      def apply_rename!(current_paths, moved_identity, source, target)
        current_paths.each do |identity, path|
          next unless identity == moved_identity || under?(path, source, @paths.fetch(moved_identity).namespace)
          current_paths[identity] = target + path.delete_prefix(source)
        end
      end

      def append_command!(commands, current_paths, identity, source, target, temporary: false)
        namespace = @paths.fetch(identity).namespace
        identities = affected_identities(current_paths, source, namespace)
        commands << Command.new(
          from: source,
          to: target,
          identity: identity,
          identities: identities,
          temporary: temporary,
        )
        apply_rename!(current_paths, identity, source, target)
      end

      def affected_identities(current_paths, source, namespace)
        current_paths.keys
          .select { current_paths[_1] == source || under?(current_paths[_1], source, namespace) }
          .to_set
      end

      def temporary_path(current_paths, namespace, targets)
        prefix, delimiter = namespace
        1.step do |number|
          suffix = "#{TEMPORARY_PREFIX}#{number}"
          candidate = prefix.empty? || prefix.end_with?(delimiter) ? prefix + suffix : prefix + delimiter + suffix
          current_path_values = current_paths.values
          next if current_path_values.include?(candidate) || targets.include?(candidate)
          next if current_path_values.any? { under?(_1, candidate, namespace) }
          next if targets.any? do |target|
            candidate == target ||
              under?(target, candidate, namespace) ||
              under?(candidate, target, namespace)
          end
          return candidate
        end
      end

      def namespace_for(path)
        resolve_namespace(path)
      end

      def resolve_namespace(path, expected_delim = nil)
        matches = @namespaces.select do |prefix, delimiter|
          next true if prefix.empty?
          effective_prefix = prefix.delete_suffix(delimiter)
          path == prefix || path == effective_prefix || path.start_with?(prefix)
        end
        filtered = expected_delim ? matches.select { _1[1] == expected_delim } : []
        (filtered.empty? ? matches : filtered).max_by { _1[0].length }
      end

      def inbox_name?(path, namespace)
        relative = path.delete_prefix(namespace[0])
        relative.casecmp?("INBOX")
      end

      def under?(path, ancestor, namespace = nil)
        delimiter = namespace&.dig(1) || namespace_for(ancestor)&.dig(1) || @delimiter
        return false unless delimiter && path && ancestor
        path.start_with?(ancestor + delimiter)
      end

      def parent_path(path, namespace)
        relative = path.delete_prefix(namespace[0]).sub(/\A#{Regexp.escape(namespace[1])}/, "")
        index = relative.rindex(namespace[1])
        index ? namespace[0] + relative[0...index] : nil
      end

      def nonempty_string?(value)
        String === value && !value.empty?
      end
    end
  end
end
