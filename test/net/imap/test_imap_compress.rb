# frozen_string_literal: true

require "zlib"
require_relative "../../lib/helper"

# Tests for RFC4978 COMPRESS=DEFLATE (Net::IMAP#compress).
#
# Uses a minimal scripted server (not FakeServer) so the tests have exact
# control over the bytes on the wire: the tagged OK to COMPRESS is merged
# into a single write with the first compressed response, and compressed
# response data can be fed to the client one byte at a time.
class IMAPCompressTest < Net::IMAP::TestCase
  CA_FILE     = File.expand_path("../fixtures/cacert.pem", __dir__)
  SERVER_KEY  = File.expand_path("../fixtures/server.key", __dir__)
  SERVER_CERT = File.expand_path("../fixtures/server.crt", __dir__)

  CRLF = "\r\n"

  # A minimal scripted IMAP server that speaks COMPRESS=DEFLATE.
  class CompressServer
    Command = Struct.new(:tag, :name, :args, :raw)

    attr_reader :commands, :literals

    def initialize(tls: false, advertise_compress: true,
                   refuse_compress: false, corrupt: false,
                   close_on_command: nil)
      @tls                = tls
      @advertise_compress = advertise_compress
      @refuse_compress    = refuse_compress
      @corrupt            = corrupt
      @close_on_command   = close_on_command
      @tcp_server = TCPServer.new("localhost", 0)
      @commands   = []
      @literals   = []
      @inbuf      = +"".b
      @compressing = false
    end

    def port = @tcp_server.addr[1]

    def run
      @sock = accept
      @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      capabilities = %w[IMAP4rev1 LITERAL+]
      capabilities << "COMPRESS=DEFLATE" if @advertise_compress
      send_line "* OK [CAPABILITY %s] fake server ready" % [capabilities.join(" ")]
      while (command = read_command)
        commands << command
        close_after = command.name == @close_on_command
        handle_command(command) unless close_after
        if close_after
          @sock.close
          return
        end
        break if command.name == "LOGOUT"
      end
    rescue IOError, SystemCallError
      # The client went away abruptly (e.g. after a decompression error).
    ensure
      @sock&.close if @sock && !@sock.closed?
      @tcp_server.close
    end

    private

    def accept
      tcp_socket = @tcp_server.accept
      return tcp_socket unless @tls
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.key  = OpenSSL::PKey::RSA.new(File.read(SERVER_KEY))
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(SERVER_CERT))
      OpenSSL::SSL::SSLSocket.new(tcp_socket, ctx).tap do |ssl|
        ssl.sync_close = true
        ssl.accept
      end
    end

    def handle_command(command)
      case command.name
      when "COMPRESS" then handle_compress(command)
      when "NOOP"     then send_line "#{command.tag} OK NOOP completed"
      when "SELECT"
        send_line "* 2 EXISTS"
        send_line "#{command.tag} OK SELECT completed"
      when "FETCH"
        blob = binary_blob
        send_data "* 1 FETCH (BODY[] {#{blob.bytesize}}#{CRLF}".b +
                  blob +
                  ")#{CRLF}#{command.tag} OK FETCH completed#{CRLF}".b
      when "APPEND"
        literals << command.args
        send_line "#{command.tag} OK APPEND completed"
      when "LOGOUT"
        send_line "* BYE logging out"
        send_line "#{command.tag} OK LOGOUT completed"
      else
        send_line "#{command.tag} BAD unknown command"
      end
    end

    def handle_compress(command)
      if @refuse_compress
        send_line "#{command.tag} NO COMPRESS is not allowed here"
        return
      end
      @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      @inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      ok    = "#{command.tag} OK COMPRESS active#{CRLF}"
      # The first compressed response, merged into the same write as the OK.
      first = deflate("* 1 EXISTS#{CRLF}")
      @sock.write(ok + first)
      @compressing = true
    end

    # Reads one command, inflating when compression is active.  Returns a
    # Command with any literal bytes placed into +args+.
    def read_command
      line = read_line or return nil
      args = nil
      if line =~ /\{(\d+)(\+)?\}\r\n\z/
        send_line "+ Ready for literal" unless $2
        args = read_bytes($1.to_i)
        read_line # trailing CRLF after the literal
      end
      tag, name = line.split(" ", 3)
      Command.new(tag, name&.upcase, args, line)
    end

    def read_line
      until (index = @inbuf.index(CRLF))
        fill or return nil
      end
      @inbuf.slice!(0, index + 2)
    end

    def read_bytes(count)
      fill while @inbuf.bytesize < count
      @inbuf.slice!(0, count)
    end

    def fill
      chunk = @sock.readpartial(1024)
      @inbuf << (@compressing ? @inflater.inflate(chunk) : chunk)
      true
    rescue EOFError, IOError, SystemCallError
      false
    end

    # Sends a response line, compressed when compression is active.
    # Compressed data is fed to the client one byte at a time.
    def send_line(line) = send_data(line + CRLF)

    def send_data(data)
      if @corrupt && @compressing
        data = "\xFF\xFF\xFF\xFF invalid deflate stream".b
      elsif @compressing
        data = deflate(data)
      end
      if @compressing
        data.each_byte { @sock.write(_1.chr) } # feed single bytes
      else
        @sock.write(data)
      end
    end

    def deflate(data)
      @deflater.deflate(data) + @deflater.flush(Zlib::SYNC_FLUSH)
    end

    def binary_blob
      "binary: \x00\x01\x02\r\n\xFE\xFF end".b
    end
  end

  def with_compress_server(**server_opts)
    server = CompressServer.new(**server_opts)
    @threads << Thread.new { server.run }
    ssl = server_opts[:tls] ? { ca_file: CA_FILE } : nil
    client = Net::IMAP.new("localhost", port: server.port, ssl: ssl)
    yield server, client
  ensure
    client&.disconnect unless client.nil? || client.disconnected?
  end

  test "compress enables COMPRESS=DEFLATE for commands and responses" do
    with_compress_server do |server, imap|
      refute imap.compressing?
      response = imap.compress
      assert_equal "OK", response.name
      assert imap.compressing?
      assert_equal "RUBY0001 COMPRESS DEFLATE",
                   server.commands.first.raw.strip

      # the first compressed response was merged into the same write as the OK
      assert_equal :count, wait_for_response_count(imap, type: "EXISTS", count: 1)
      assert_equal 1, imap.responses("EXISTS").last

      # multiple commands continue to work over the compressed connection
      assert_equal "OK", imap.noop.name
      assert_equal "OK", imap.select("INBOX").name
      assert_equal 2, imap.responses("EXISTS").last

      # binary literals in responses are decompressed correctly
      fetched = imap.fetch(1, "BODY[]")
      assert_equal "binary: \x00\x01\x02\r\n\xFE\xFF end".b,
                   fetched.first.attr["BODY[]"]

      # binary literals in commands are compressed correctly
      message = "Subject: hi\r\n\r\n\x00\x01\xFE\xFF\r\n".b
      assert_equal "OK", imap.append("INBOX", message).name
      assert_equal message, server.literals.last

      assert_equal "OK", imap.logout.name
    end
  end

  test "compress raises DataFormatError when capability is not advertised" do
    with_compress_server(advertise_compress: false) do |server, imap|
      assert_raise(Net::IMAP::DataFormatError) { imap.compress }
      refute imap.compressing?
      assert_empty server.commands
      assert_equal "OK", imap.noop.name # connection is still usable
    end
  end

  test "compress refusal preserves the NO response error" do
    with_compress_server(refuse_compress: true) do |server, imap|
      error = assert_raise(Net::IMAP::NoResponseError) { imap.compress }
      assert_match "COMPRESS is not allowed here", error.message
      refute imap.compressing?
      assert_equal "OK", imap.noop.name # connection is still usable
    end
  end

  test "corrupted compressed data raises the original zlib error" do
    with_compress_server(corrupt: true) do |server, imap|
      imap.compress
      assert imap.compressing?
      assert_raise(Zlib::DataError) { imap.noop }
    end
  end

  test "premature connection close raises EOFError" do
    with_compress_server(close_on_command: "NOOP") do |server, imap|
      imap.compress
      assert imap.compressing?
      assert_raise(EOFError) { imap.noop }
    end
  end

  test "compress works over a TLS connection" do
    with_compress_server(tls: true) do |server, imap|
      assert imap.tls_verified?
      assert imap.tls_socket?
      refute imap.compressing?
      assert_equal "OK", imap.compress.name
      assert imap.compressing?
      assert imap.tls_socket?, "TLS socket should be detected under the codec"
      assert_equal :count, wait_for_response_count(imap, type: "EXISTS", count: 1)
      assert_equal "OK", imap.noop.name
      assert_equal "OK", imap.logout.name
    end
  end

end
