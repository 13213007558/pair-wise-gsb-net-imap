# frozen_string_literal: true

require "zlib"

module Net
  class IMAP

    # Wraps the connection IO with the RFC4978 COMPRESS=DEFLATE codec.
    #
    # Each direction is a single continuous raw deflate stream (RFC1951, no
    # zlib wrapper), so the compressor and decompressor are created only once
    # and shared by all commands and responses after compression starts.
    # Outgoing data is flushed with Zlib::SYNC_FLUSH, so the receiver can
    # decompress each chunk as it arrives without waiting for the stream end.
    #
    # The wrapped IO object is kept and all reading goes through it, so any
    # compressed bytes that were already received into its internal buffer
    # (e.g. sent by the server in the same packet as the COMPRESS tagged OK)
    # are still decompressed correctly.
    class RawDeflateIO # :nodoc:
      CHUNK_SIZE = 16 * 1024

      # The wrapped IO, e.g. a TCPSocket or OpenSSL::SSL::SSLSocket.
      attr_reader :io

      def initialize(io)
        @io       = io
        @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION,
                                      -Zlib::MAX_WBITS)
        @inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        @inflated = String.new(capacity: CHUNK_SIZE, encoding: Encoding::BINARY)
      end

      def print(str)
        io.print(@deflater.deflate(str))
        io.print(@deflater.flush(Zlib::SYNC_FLUSH))
        nil
      end

      def gets(sep, limit = nil)
        loop do
          if (index = @inflated.index(sep))
            index += sep.bytesize
            index = limit if limit && limit < index
            return @inflated.slice!(0, index)
          end
          return @inflated.slice!(0, limit) if limit && limit <= @inflated.bytesize
          read_more or return (@inflated.empty? ? nil : @inflated.slice!(0..))
        end
      end

      def read(length, buffer = nil)
        read_more while @inflated.bytesize < length
        return nil if length.positive? && @inflated.empty?
        chunk = @inflated.slice!(0, length)
        buffer ? buffer.replace(chunk) : chunk
      end

      def to_io;   io.to_io   end
      def close;   io.close   end
      def closed?; io.closed? end

      private

      # Inflates one more chunk into @inflated.  Returns false at EOF.
      # Zlib errors (e.g. corrupted deflate data) are propagated as-is.
      def read_more
        chunk = io.readpartial(CHUNK_SIZE)
        @inflated << @inflater.inflate(chunk)
        true
      rescue EOFError
        false
      end

    end
  end
end
