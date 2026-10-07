# frozen_string_literal: true

require "zlib"

module Net
  class IMAP
    class DeflateSocket # :nodoc:
      READ_SIZE = 4096

      attr_reader :io

      def initialize(io)
        @io = io
        @input = String.new.b
        @compressed_input = nil
        @inflate = nil
        @deflate = nil
      end

      def compressed?
        !!@inflate
      end

      def tls_socket?
        io.kind_of?(OpenSSL::SSL::SSLSocket)
      end

      def start_deflate!
        raise Error, "compression is already enabled" if compressed?
        @inflate = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        @deflate = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        @compressed_input = @input.dup
        @input.clear
        self
      end

      def replace_io!(io)
        @io = io
        @input = String.new.b
        @compressed_input = nil
        @inflate = nil
        @deflate = nil
        self
      end

      def print(*args)
        if @deflate
          args.each do |arg|
            compressed = @deflate.deflate(String(arg).b, Zlib::SYNC_FLUSH)
            begin
              io.write(compressed)
            rescue IOError, SystemCallError => error
              raise compression_error(error)
            end
          end
        else
          io.print(*args)
        end
        io.flush
        nil
      end

      def gets(separator, limit = nil)
        loop do
          result = buffered_line(separator, limit)
          return result unless result == :need_more
          fill_input
        end
      rescue EOFError
        nil
      end

      def read(length, outbuf = nil)
        outbuf&.replace(String.new.b)
        result = outbuf || String.new(capacity: length)
        while result.bytesize < length
          unless @input.empty?
            size = length - result.bytesize
            result << @input.byteslice(0, size)
            @input = remaining_bytes(@input, size)
            next
          end
          filled = fill_decoded do |chunk|
            available = length - result.bytesize
            result << chunk.byteslice(0, available)
            [available, chunk.bytesize].min
          end
          break unless filled
        end
        return nil if result.empty? || result.bytesize < length
        result
      end

      def to_io
        io.respond_to?(:to_io) ? io.to_io : io
      end

      def shutdown(*args)
        to_io.shutdown(*args)
      end

      def close(*args)
        io.close(*args)
      end

      def closed?
        io.closed?
      end

      private

      def buffered_line(separator, limit)
        return :need_more if @input.empty?
        separator_size = separator.bytesize
        index = @input.index(separator)
        if index && (limit.nil? || index + separator_size <= limit)
          size = index + separator_size
          result = @input.byteslice(0, size)
          @input = remaining_bytes(@input, size)
          return result
        end
        if limit && @input.bytesize >= limit
          result = @input.byteslice(0, limit)
          @input = remaining_bytes(@input, limit)
          return result
        end
        :need_more
      end

      def fill_input
        fill_decoded do |chunk|
          @input << chunk
          chunk.bytesize
        end
      end

      def fill_decoded
        chunk = next_decoded_chunk or raise EOFError, "end of file reached"
        consumed = yield(chunk)
        @input.prepend(chunk.byteslice(consumed..)) if consumed < chunk.bytesize
        !chunk.empty? || consumed.positive?
      end

      def next_decoded_chunk
        loop do
          chunk = next_input_chunk or return nil
          if @inflate
            chunk = begin
              @inflate.inflate(chunk)
            rescue Zlib::Error => error
              raise compression_error(error)
            end
            next if chunk.empty?
          end
          return chunk.b
        end
      end

      def next_input_chunk
        if @inflate && @compressed_input && !@compressed_input.empty?
          chunk = @compressed_input.byteslice(0, READ_SIZE)
          @compressed_input = @compressed_input.byteslice(chunk.bytesize..)
          return chunk
        end
        @compressed_input = nil
        begin
          io.readpartial(READ_SIZE)
        rescue EOFError, IOError
          raise unless @inflate
          raise CompressionError, "compressed IMAP stream ended before completion"
        end
      end

      def compression_error(error)
        CompressionError.new("compressed IMAP stream error: #{error.message}")
      end

      def remaining_bytes(string, offset)
        string.byteslice(offset..) || String.new.b
      end

    end
  end
end
