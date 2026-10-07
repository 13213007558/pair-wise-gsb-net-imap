# frozen_string_literal: true

require_relative "../../lib/helper"
require "zlib"

class IMAPCompressTest < Net::IMAP::TestCase
  RAW_WBITS = -Zlib::MAX_WBITS

  class ScriptedIO
    def initialize(chunks = [], eof_when_empty: false)
      @chunks = chunks.map(&:b)
      @eof_when_empty = eof_when_empty
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @written = +""
      @written_chunks = Queue.new
      @eof = false
      @read_eof = false
    end

    attr_reader :written, :written_chunks

    def write(data)
      data = data.b
      @mutex.synchronize do
        @written << data
        @written_chunks << data
      end
      data.bytesize
    end

    def flush
    end

    def read(maxlen, outbuf = nil)
      @mutex.synchronize do
        if @read_eof
          outbuf&.replace(+"")
          return nil
        end
        @condition.wait(@mutex) while @chunks.empty? && !@eof && !@eof_when_empty
        chunk = @chunks.shift
        if chunk.nil?
          @read_eof = true
          outbuf&.replace(+"")
          return nil
        end
        if chunk.bytesize > maxlen
          remaining = chunk.byteslice(maxlen, chunk.bytesize - maxlen)
          @chunks.unshift(remaining) if remaining
          chunk = chunk.byteslice(0, maxlen)
        end
        outbuf ? outbuf.replace(chunk) : chunk.dup
      end
    end

    def enqueue(chunk)
      @mutex.synchronize do
        @chunks << chunk.b
        @condition.broadcast
      end
    end

    def shutdown(*)
    end

    def close
      @mutex.synchronize do
        @eof = true
        @written_chunks.close
        @condition.broadcast
      end
    end

    def closed?
      @mutex.synchronize { @eof }
    end

    def to_io
      self
    end

  end

  class CompressedTestIO < ScriptedIO
    MESSAGE = "line\r\n{binary}\x00\xff\x01".b
    CRLF = "\r\n".b

    def initialize(first_split)
      super(["* PREAUTH ready\r\n"])
      @first_split = first_split
      @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, RAW_WBITS)
      @inflater = Zlib::Inflate.new(RAW_WBITS)
      @plain_buffer = +"".b
      @compressed_buffer = +"".b
      @error = nil
      @thread = Thread.start { serve }
    end

    def join(raise_error: true)
      @thread.join
      raise @error if raise_error && @error
    end

    private

    def serve
      command = read_cleartext_line
      raise "unexpected command: #{command.inspect}" unless command == "RUBY0001 COMPRESS DEFLATE\r\n"

      enqueue("RUBY0001 OK COMPRESS done\r\n")

      loop do
        command = read_compressed_line
        case command
        when "RUBY0002 NOOP\r\n"
          send_compressed("RUBY0002 OK NOOP done\r\n")
        when /\A(RUBY\d+) APPEND INBOX ~?\{(\d+)\}\r\n\z/
          tag = $1
          size = Integer($2)
          send_compressed("+ Ready for literal data\r\n")
          received = read_compressed_bytes(size + CRLF.bytesize)
          raise "unexpected literal: #{received.inspect}" unless received == MESSAGE + CRLF
          send_compressed("#{tag} OK APPEND done\r\n")
        when /\A(RUBY\d+) IDLE\r\n\z/
          tag = $1
          send_compressed("+ idling\r\n* 1 EXISTS\r\n")
          raise "bad DONE" unless read_compressed_bytes(6) == "DONE\r\n"
          send_compressed("#{tag} OK IDLE done\r\n")
        when /\A(RUBY\d+) LOGOUT\r\n\z/
          send_compressed("* BYE done\r\n#{$1} OK LOGOUT done\r\n")
          return
        else
          raise "unexpected compressed command: #{command.inspect}"
        end
      end
    rescue => @error
    ensure
      close
    end

    def read_cleartext_line
      @plain_buffer << written_chunks.pop until @plain_buffer.include?(CRLF)
      @plain_buffer.slice!(0, @plain_buffer.index(CRLF) + 2)
    end

    def read_compressed_line
      fill_compressed until @compressed_buffer.include?(CRLF)
      @compressed_buffer.slice!(0, @compressed_buffer.index(CRLF) + 2)
    end

    def read_compressed_bytes(length)
      fill_compressed while @compressed_buffer.bytesize < length
      @compressed_buffer.slice!(0, length)
    end

    def fill_compressed
      chunk = written_chunks.pop
      decoded = @inflater.inflate(chunk)
      @compressed_buffer << decoded
    rescue Zlib::BufError
      @compressed_buffer << @inflater.inflate(+"")
    end

    def send_compressed(response)
      compressed = compress(response)
      compressed.bytes.each { |byte| enqueue(byte.chr.b) }
    end

    def compress(data)
      @deflater.deflate(data.b, Zlib::SYNC_FLUSH)
    end

  end

  test "commands, literals, and IDLE share one fragmented compressed stream" do
    first_response = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, RAW_WBITS)
      .deflate("RUBY0002 OK NOOP done\r\n", Zlib::SYNC_FLUSH)

    splits = ENV["COMPRESS_SPLITS"]&.split(",")&.map(&:to_i)
    split_values = splits || (0..first_response.bytesize).to_a
    split_values.each do |split|
      io = CompressedTestIO.new(split)
      imap = new_client(io)

      assert imap.compress
      assert imap.compressed?
      assert_raise(Net::IMAP::Error) { imap.compress }
      assert imap.noop
      assert imap.append("INBOX", CompressedTestIO::MESSAGE.dup)

      responses = []
      imap.idle do |response|
        responses << response
        imap.idle_done if response.name == "EXISTS"
      end
      assert_equal "EXISTS", responses.last.name
      imap.logout
      io.join
    ensure
      imap&.disconnect
      io&.join(raise_error: false)
    end
  end

  class RejectingTestIO < ScriptedIO
    def initialize
      super(["* PREAUTH ready\r\n"])
      @thread = Thread.start { serve }
    end

    def join(raise_error: true)
      @thread.join
    end

    private

    def serve
      request = +"".b
      request << written_chunks.pop until request.include?("\r\n")
      enqueue("RUBY0001 NO compression disabled\r\n")
      request = +"".b
      request << written_chunks.pop until request.include?("\r\n")
      enqueue("RUBY0002 OK NOOP done\r\n")
    ensure
      close
    end
  end

  test "rejected compression leaves the connection usable" do
    io = RejectingTestIO.new
    imap = new_client(io)
    assert_raise(Net::IMAP::NoResponseError) { imap.compress }
    refute imap.compressed?
    assert imap.noop
  ensure
    imap&.disconnect
  end

  test "invalid algorithm or connection state is rejected before writing" do
    io = ScriptedIO.new(["* OK ready\r\n"])
    imap = new_client(io)
    assert_raise(ArgumentError) { imap.compress("GZIP") }
    assert_raise(Net::IMAP::Error) { imap.compress }
    assert_empty io.written
  ensure
    imap&.disconnect
  end

  test "truncated compressed stream raises a transport error" do
    truncated = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, RAW_WBITS)
      .deflate("* OK never completed", Zlib::SYNC_FLUSH)
      .byteslice(0, 2)
    io = Object.new
    bytes = truncated.dup
    io.define_singleton_method(:read) do |length, buffer = nil|
      chunk = bytes.empty? ? nil : bytes.slice!(0, length)
      buffer&.replace(chunk)
      chunk
    end
    io.define_singleton_method(:write) { |data| data.bytesize }
    io.define_singleton_method(:flush) {}
    io.define_singleton_method(:closed?) { false }
    connection = Net::IMAP::ConnectionIO.new(io)
    connection.start_compression
    assert_raise(Net::IMAP::CompressionError) { connection.gets("\r\n") }
  end

  private

  def new_client(io)
    Class.new(Net::IMAP) do
      define_method(:tcp_socket) { |_, _| io }
    end.new("localhost", port: 0, ssl: false)
  end
end
