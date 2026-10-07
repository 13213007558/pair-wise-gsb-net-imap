# frozen_string_literal: true

require "zlib"

module Net
  class IMAP
    class ConnectionIO # :nodoc:
      DEFLATE_WINDOW_BITS = -Zlib::MAX_WBITS
      READ_SIZE = 1 << 16

      attr_reader :to_io, :read_buffer

      def initialize(io)
        @to_io = io
        @read_buffer = String.new(encoding: Encoding::BINARY)
        @compressed_buffer = nil
        @inflater = nil
        @deflater = nil
        @write_buffer = nil
      end

      def compressed?
        !!@inflater
      end

      def start_compression
        raise Error, "connection compression is already enabled" if compressed?
        pending = @read_buffer
        @read_buffer = String.new(encoding: Encoding::BINARY)
        @inflater = Zlib::Inflate.new(DEFLATE_WINDOW_BITS)
        @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, DEFLATE_WINDOW_BITS)
        @read_buffer << @inflater.inflate(pending) unless pending.empty?
      end

      def print(*args, flush: true)
        data = args.map(&:to_s).join.b
        if @deflater
          @write_buffer ||= String.new(encoding: Encoding::BINARY)
          if flush
            data = @deflater.deflate(@write_buffer + data, Zlib::SYNC_FLUSH)
            @write_buffer.clear
          else
            @write_buffer << data
            data = +"".b
          end
        end
        @to_io.write(data)
        @to_io.flush
        nil
      end

      def print_flush_buffer(*args)
        data = args.map(&:to_s).join.b
        return unless @deflater
        @write_buffer ||= String.new(encoding: Encoding::BINARY)
        data = @deflater.deflate(@write_buffer + data, Zlib::SYNC_FLUSH)
        @write_buffer.clear
        @to_io.write(data)
        @to_io.flush
        nil
      end

      def gets(separator, limit = nil, outbuf = nil)
        result = nil
        loop do
          position = @read_buffer.index(separator)
          if position
            length = position + separator.bytesize
            length = limit if limit && length > limit
            result = consume_read_buffer(length)
            break
          end
          if limit && @read_buffer.bytesize >= limit
            result = consume_read_buffer(limit)
            break
          end
          unless refill
            raise CompressionError, truncated_message if @inflater
            result = consume_read_buffer(@read_buffer.bytesize)
            break
          end
        end
        result = nil if result&.empty?
        outbuf ? outbuf.replace(result) : result
      end

      def read(length, outbuf = nil)
        result = String.new(encoding: Encoding::BINARY, capacity: length)
        loop do
          unless @read_buffer.empty?
            result << consume_read_buffer(length - result.bytesize)
          end
          break if result.bytesize == length
          unless refill
            raise CompressionError, truncated_message if @inflater
            result = nil if result.empty?
            break
          end
        end
        outbuf ? outbuf.replace(result) : result
      end

      def adopt_read_buffer(buffer)
        @read_buffer << buffer.b unless buffer.nil? || buffer.empty?
      end

      def shutdown(*args) = @to_io.shutdown(*args)
      def close = @to_io.close
      def closed? = @to_io.closed?

      def tls_socket?
        defined?(OpenSSL::SSL::SSLSocket) && @to_io.is_a?(OpenSSL::SSL::SSLSocket)
      end

      def respond_to_missing?(name, include_private = false)
        @to_io.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        if @to_io.respond_to?(name)
          @to_io.public_send(name, *args, **kwargs, &block)
        else
          super
        end
      end

      private

      def consume_read_buffer(length)
        @read_buffer.slice!(0, length) || +"".b
      end

      def refill
        @inflater ? refill_compressed : refill_plain
      end

      def refill_compressed
        loop do
          fill_compressed_buffer
          if @compressed_buffer.nil?
            raise CompressionError, truncated_message
          end
          begin
            @read_buffer << @inflater.inflate(@compressed_buffer)
          rescue Zlib::BufError
            @read_buffer << @inflater.inflate(+"".b)
          end
          @compressed_buffer = nil
          break if @read_buffer.include?(CRLF)
        end
        true
      rescue Zlib::Error => error
        raise CompressionError,
              "error while inflating compressed IMAP data: #{error.message}"
      end

      def fill_compressed_buffer
        @compressed_buffer = nil
        chunk = @to_io.read(READ_SIZE)
        @compressed_buffer = chunk
      end

      def refill_plain
        chunk = @to_io.read(READ_SIZE)
        return false unless chunk
        @read_buffer << chunk
        true
      end

      def truncated_message
        "unexpected end of file while reading compressed IMAP data"
      end
    end
  end
end
