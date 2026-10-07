# frozen_string_literal: true

require "zlib"
require_relative "../../lib/helper"

class IMAPCompressTest < Net::IMAP::TestCase
  include Net::IMAP::TestCase::SimpleTCPServerHelper

  CompressionClient = Struct.new(:max_response_size)

  class FragmentedIO
    def initialize(data, first_read_size: nil, read_size: 1)
      @data = data.b
      @offset = 0
      @first_read = true
      @first_read_size = first_read_size
      @read_size = read_size
    end

    def readpartial(max)
      raise EOFError if @offset >= @data.bytesize
      size = if @first_read && @first_read_size
               @first_read_size
             else
               @read_size
             end
      size = [size, max].min
      chunk = @data.byteslice(@offset, size)
      @offset += chunk.bytesize
      @first_read = false
      chunk
    end
  end

  def deflate_raw(data)
    deflate = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    deflate.deflate(data.b, Zlib::FINISH)
  ensure
    deflate&.close
  end

  def test_response_reader_preserves_compressed_bytes_buffered_with_tagged_ok
    body = "line CRLF: \r\n braces: { } {4} binary: \0\xff\r\n".b
    response = "* FETCH (BODY[]) {#{body.bytesize}}\r\n#{body}\r\n".b
    tagged_ok = "RUBY0001 OK COMPRESS completed\r\n".b
    compressed = deflate_raw(response)

    (0..compressed.bytesize).each do |boundary|
      io = FragmentedIO.new(
        tagged_ok + compressed,
        first_read_size: tagged_ok.bytesize + boundary
      )
      socket = Net::IMAP::DeflateSocket.new(io)
      assert_equal tagged_ok, socket.gets("\r\n")
      socket.start_deflate!
      reader = Net::IMAP::ResponseReader.new(
        CompressionClient.new(1024 * 1024), socket
      )
      assert_equal response, reader.read_response_buffer
    end
  end

  def test_truncated_compressed_stream_raises_transport_error
    body = "enough data to make truncation detectable\r\n" * 8
    response = "* FETCH (BODY[]) {#{body.bytesize}}\r\n#{body}\r\n".b
    tagged_ok = "RUBY0001 OK COMPRESS completed\r\n".b
    compressed = deflate_raw(response)
    io = FragmentedIO.new(
      tagged_ok + compressed.byteslice(0, 1),
      first_read_size: tagged_ok.bytesize + 1
    )
    socket = Net::IMAP::DeflateSocket.new(io)
    socket.gets("\r\n")
    socket.start_deflate!
    reader = Net::IMAP::ResponseReader.new(
      CompressionClient.new(1024 * 1024), socket
    )
    error = assert_raise(Net::IMAP::CompressionError) do
      reader.read_response_buffer
    end
    assert_match(/compressed IMAP stream/, error.message)
  end

  def test_commands_idle_and_literals_share_one_compressed_stream
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    received = []
    start_server do
      sock = server_socket
      begin
        sock.print("* PREAUTH [CAPABILITY IMAP4rev1 COMPRESS=DEFLATE IDLE] ready\r\n")
        assert_compress_request(sock, received)

        inflate = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        deflate = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        buffer = String.new.b

        received << read_compressed_command(sock, inflate, buffer)
        write_compressed(sock, deflate, "* 1 EXISTS\r\n")
        write_compressed(sock, deflate, "RUBY0002 OK NOOP completed\r\n")

        command = read_compressed_command(sock, inflate, buffer)
        received << command
        write_compressed(sock, deflate, "+ idling\r\n* 2 RECENT\r\n")
        received << read_compressed_command(sock, inflate, buffer)
        write_compressed(sock, deflate, "RUBY0003 OK IDLE terminated\r\n")

        command = read_compressed_append(sock, inflate, buffer) do
          write_compressed(sock, deflate, "+ Ready\r\n")
        end
        received << command
        write_compressed(sock, deflate, "RUBY0004 OK APPEND completed\r\n")

        received << read_compressed_command(sock, inflate, buffer)
        write_compressed(sock, deflate,
                         "* BYE closing\r\nRUBY0005 OK LOGOUT completed\r\n")
      ensure
        sock.close
      end
    end

    imap = new_memory_client(client_socket)
    begin
      assert imap.capable?("COMPRESS=DEFLATE")
      imap.compress
      assert imap.compressed?
      wait_for_response_count(imap, type: "EXISTS", count: 1)
      imap.noop

      idle_responses = []
      imap.idle do |response|
        idle_responses << response
        imap.idle_done if response.respond_to?(:name) && response.name == "RECENT"
      end
      names = idle_responses.map { _1.respond_to?(:name) ? _1.name : "CONTINUATION" }
      assert_equal ["CONTINUATION", "RECENT"], names

      body = "subject {CRLF} \r\n braces {} binary \0\xff\r\n".b
      imap.append("INBOX", body)
      assert_include received.join, body
      assert_raise(Net::IMAP::Error) { imap.compress }
      imap.logout
    ensure
      imap.disconnect if imap && !imap.disconnected?
    end
  end

  def test_rejected_compression_leaves_cleartext_connection_usable
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    noop_done = Queue.new
    start_server do
      sock = server_socket
      begin
        sock.print("* PREAUTH [CAPABILITY IMAP4rev1 COMPRESS=DEFLATE] ready\r\n")
        compress_command = sock.gets("\r\n")
        sock.print("RUBY0001 NO compression disabled\r\n")
        command = sock.gets("\r\n")
        raise compress_command unless command.start_with?("RUBY0002")
        tag = command.split(/[[:space:]]/, 2).first
        sock.print("#{tag} OK NOOP completed\r\n")
        noop_done.pop
      ensure
        sock.close
      end
    end

    imap = new_memory_client(client_socket)
    begin
      assert_raise(Net::IMAP::NoResponseError) { imap.compress }
      refute imap.compressed?
      imap.noop
      assert_raise(ArgumentError) { imap.compress("ZLIB") }
      noop_done << true
    ensure
      imap.disconnect
    end
  end

  def test_illegal_state_and_unsupported_capability_are_rejected_before_writing
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    start_server do
      sock = server_socket
      begin
        sock.print("* OK [CAPABILITY IMAP4rev1 COMPRESS=DEFLATE] ready\r\n")
      ensure
        sock.close
      end
    end

    imap = new_memory_client(client_socket)
    begin
      assert_equal :not_authenticated, imap.connection_state.to_sym
      assert_raise(Net::IMAP::Error) { imap.compress }
    ensure
      imap.disconnect
    end
  end

  def test_unsupported_compression_capability_and_algorithm_are_rejected_before_writing
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    start_server do
      sock = server_socket
      begin
        sock.print("* PREAUTH [CAPABILITY IMAP4rev1 IDLE] ready\r\n")
        sleep 0.05
      ensure
        sock.close
      end
    end

    imap = new_memory_client(client_socket)
    begin
      assert_raise(Net::IMAP::Error) { imap.compress }
      assert_raise(ArgumentError) { imap.compress("ZLIB") }
      refute imap.compressed?
    ensure
      imap.disconnect
    end
  end

  def test_caller_receives_compression_error_after_server_truncates_stream
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    start_server do
      sock = server_socket
      begin
        sock.print("* PREAUTH [CAPABILITY IMAP4rev1 COMPRESS=DEFLATE] ready\r\n")
        sock.gets("\r\n")
        sock.print("RUBY0001 OK COMPRESS completed\r\n")
        sock.write("\x00\x00\xff\xff".b)
        sock.flush
        sock.close_write
        sleep 0.05
      ensure
        sock.close
      end
    end

    imap = new_memory_client(client_socket)
    begin
      assert_raise(Net::IMAP::CompressionError) do
        imap.compress
        imap.noop
      end
    ensure
      imap.disconnect
    end
  end

  private

  def new_memory_client(socket)
    client = Net::IMAP.allocate
    client.define_singleton_method(:tcp_socket) { |_host, _port| socket }
    client.send(:initialize, "memory")
    client
  end

  def assert_compress_request(sock, received)
    command = sock.gets("\r\n")
    received << command
    tagged_ok = "RUBY0001 OK COMPRESS completed\r\n".b
    first_response = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      .deflate("* 1 EXISTS\r\n", Zlib::SYNC_FLUSH)
    sock.write(tagged_ok + first_response)
    sock.flush
  end

  def write_compressed(sock, deflate, response)
    sock.write(deflate.deflate(response.b, Zlib::SYNC_FLUSH))
    sock.flush
  end

  def read_compressed_chunk(sock, inflate)
    inflate.inflate(sock.readpartial(4096))
  rescue EOFError
    nil
  end

  def read_compressed_line(sock, inflate, buffer)
    until (index = buffer.index("\r\n"))
      chunk = read_compressed_chunk(sock, inflate)
      return nil if chunk.nil?
      buffer << chunk
    end
    line = buffer.byteslice(0, index + 2)
    buffer.replace(buffer.byteslice(index + 2..) || String.new.b)
    line
  end

  def read_compressed_command(sock, inflate, buffer)
    command = String.new.b
    while (line = read_compressed_line(sock, inflate, buffer))
      command << line
      return command unless line =~ /~?\{(\d+)(\+)?\}\r\n\z/n
      size = Integer($1)
      command << read_compressed_bytes(sock, inflate, buffer, size)
    end
  end

  def read_compressed_append(sock, inflate, buffer)
    command = String.new.b
    while (line = read_compressed_line(sock, inflate, buffer))
      command << line
      if line =~ /~?\{(\d+)(\+)?\}\r\n\z/n
        size = Integer($1)
        yield
        command << read_compressed_bytes(sock, inflate, buffer, size)
      else
        return command
      end
    end
  end

  def read_compressed_bytes(sock, inflate, buffer, size)
    result = String.new.b
    while result.bytesize < size
      missing = size - result.bytesize
      if !buffer.empty?
        result << buffer.byteslice(0, missing)
        buffer.replace(buffer.byteslice(missing..) || String.new.b)
      else
        chunk = read_compressed_chunk(sock, inflate)
        raise EOFError if chunk.nil?
        buffer << chunk
      end
    end
    result
  end

end
