# frozen_string_literal: true

require "net/imap"
require "zlib"

class Net::IMAP::FakeServer

  # Wraps the connection socket after COMPRESS [RFC4978], transparently
  # compressing everything written to it and decompressing everything read
  # from it.  Each direction uses a single continuous DEFLATE stream
  # [RFC1951], flushed after each write but never reset or finished.
  class DeflateSocket
    def initialize(socket)
      @socket   = socket
      @inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION,
                                    -Zlib::MAX_WBITS)
      @read_buffer = +"".b
    end

    # Compresses +string+ and writes it to the socket.
    def print(string)
      write(deflate(string))
    end

    # Writes +bytes+ to the socket verbatim, without any compression.
    def write(bytes)
      @socket.print(bytes)
    end

    # Returns +string+ compressed with the connection's continuous DEFLATE
    # stream, without writing anything.  Useful for crafting raw writes that
    # mix uncompressed and compressed bytes.
    def deflate(string)
      @deflater.deflate(string, Zlib::SYNC_FLUSH)
    end

    def gets(separator = $/)
      until (index = @read_buffer.index(separator))
        fill_read_buffer or break
      end
      line = index ? @read_buffer.slice!(0, index + separator.bytesize)
                   : @read_buffer.slice!(0, @read_buffer.bytesize)
      line unless line.empty?
    end

    # Reads up to +length+ _decompressed_ bytes.
    def read(length)
      until @read_buffer.bytesize >= length
        fill_read_buffer or break
      end
      @read_buffer.slice!(0, length)
    end

    def eof?;   @socket.eof?   end
    def close;  @socket.close  end
    def closed?; @socket.closed? end

    private

    def fill_read_buffer
      @read_buffer << @inflater.inflate(@socket.readpartial(16_384))
      true
    rescue EOFError
      false
    end
  end
end
