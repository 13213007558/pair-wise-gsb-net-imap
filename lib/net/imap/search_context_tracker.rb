# frozen_string_literal: true

module Net
  class IMAP

    # SearchContextTracker tracks the SearchContext objects of an IMAP
    # connection, routing untagged +ESEARCH+ updates
    # {[RFC5267]}[https://www.rfc-editor.org/rfc/rfc5267.html] to the
    # context whose correlator tag matches, and observing +NOUPDATE+,
    # +CANCELUPDATE+, and mailbox (or connection) close events.
    #
    # A tracker is created with the IMAP client and receives every server
    # response (before #add_response_handler handlers are called):
    #
    #   result  = imap.uid_search(["FLAGGED"], return: [:PARTIAL, 1..100])
    #   context = imap.search_contexts.track(result)
    #
    #   imap.search_contexts["RUBY0001"]  # => context
    #   imap.search_contexts.active       # => [context]
    #
    #   imap.search_contexts.cancel(context) # sends CANCELUPDATE
    #
    # When the selected mailbox is closed or deselected---or the connection
    # is logged out---every tracked context is marked as closed (see
    # SearchContext#closed?), because the server implicitly destroys all of
    # its search contexts.
    #
    # *NOTE:* The tracker API is experimental and may change without
    # deprecation or warning.
    class SearchContextTracker
      include Enumerable

      def initialize(client) # :nodoc:
        @client    = client
        @contexts  = {}
        @pending   = Hash.new {|hash, key| hash[key] = [] }
        @noupdates = Set.new
        @mutex     = Thread::Mutex.new
      end

      # Registers a SearchContext (or the ESearchResult that creates one)
      # so that subsequent server updates are routed to it.  Returns the
      # tracked SearchContext.
      #
      # Updates and +NOUPDATE+ response codes that arrived before #track
      # was called are replayed onto the context, so a context can be
      # tracked after its command has completed.
      def track(esearch, command: nil)
        context = SearchContext === esearch ? esearch
                : SearchContext.new(esearch, command: command)
        @mutex.synchronize do
          @contexts[context.tag] = context
          @pending.delete(context.tag)&.each { context.update(_1) }
          context.noupdates! if @noupdates.delete?(context.tag)
        end
        context
      end

      # Returns the tracked context for the correlator +tag+, or +nil+.
      def [](tag)
        @mutex.synchronize { @contexts[tag] }
      end

      # Yields every tracked context, including closed and cancelled ones.
      def each(&block)
        return to_enum(__callee__) unless block_given?
        @mutex.synchronize { @contexts.values.dup }.each(&block)
        self
      end

      # The number of tracked contexts.
      def size;  @mutex.synchronize { @contexts.size } end

      # Whether no contexts are tracked.
      def empty?; size.zero? end

      # Every tracked context that is still SearchContext#active?.
      def active; select(&:active?) end

      # Sends a +CANCELUPDATE+ command
      # {[RFC5267]}[https://www.rfc-editor.org/rfc/rfc5267.html#section-4.5]
      # to cancel updates for the given contexts (or correlator tags), and
      # marks each tracked context as SearchContext#cancelled?.
      #
      # Raises NoResponseError or BadResponseError when the server refuses
      # the command; contexts are left unchanged in that case.
      def cancel(*contexts)
        tags = contexts.flatten.map {|context|
          context.respond_to?(:tag) ? context.tag : String(context)
        }
        @client.cancelupdate(*tags)
        @mutex.synchronize { tags.each { @contexts[_1]&.cancel! } }
        tags
      end

      # Stops tracking every context.  Active contexts are first marked as
      # SearchContext#closed?.
      def clear
        close_all!
        @mutex.synchronize { @contexts.clear }
        self
      end

      # Marks every tracked context as SearchContext#closed?.  Called by the
      # client when the selected mailbox is closed or deselected, or when
      # the connection is logged out.
      def close_all! # :nodoc:
        @mutex.synchronize do
          @contexts.each_value(&:close!)
          @pending.clear
        end
        self
      end

      # Response handler callback: routes ESEARCH updates and NOUPDATE
      # response codes to their contexts.  Updates for tags that are not
      # (yet) tracked are buffered and replayed by #track.
      def call(response) # :nodoc:
        case response
        in UntaggedResponse[name: "ESEARCH",
                            data: ESearchResult[tag: String] => esearch]
          route_update(esearch)
        in {data: ResponseText[code: ResponseCode[name: "NOUPDATE",
                                                  data: tag]]}
          route_noupdate(tag)
        else
        end
      end

      private

      def route_update(esearch)
        @mutex.synchronize do
          if (context = @contexts[esearch.tag])
            context.update(esearch)
          else
            @pending[esearch.tag] << esearch
          end
        end
      end

      def route_noupdate(tag)
        tag = String(tag)
        @mutex.synchronize do
          if (context = @contexts[tag])
            context.noupdates!
          else
            @noupdates << tag
          end
        end
      end

    end

  end
end
