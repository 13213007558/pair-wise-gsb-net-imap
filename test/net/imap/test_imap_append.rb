# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPAppendTest < Net::IMAP::TestCase
  TEST_FIXTURE_PATH = File.join(__dir__, "fixtures/response_parser")

  # TODO: convert all tests to use Net::IMAP::FakeServer::TestHelper
  include Net::IMAP::TestCase::SimpleTCPServerHelper
  include Net::IMAP::FakeServer::TestHelper

  test "#append" do
    server = create_tcp_server
    port = server.addr[1]
    mail = <<~EOF.gsub(/\n/, "\r\n")
      From: shugo@example.com
      To: matz@example.com
      Subject: hello

      hello world
    EOF
    requests = []
    received_mail = nil
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        line = sock.gets
        requests.push(line)
        size = line.slice(/{(\d+)}\r\n/, 1).to_i
        sock.print("+ Ready for literal data\r\n")
        received_mail = sock.read(size)
        sock.gets
        sock.print("RUBY0001 OK APPEND completed\r\n")
        requests.push(sock.gets)
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      imap.append("INBOX", mail)
      assert_equal(1, requests.length)
      assert_equal("RUBY0001 APPEND INBOX {#{mail.size}}\r\n", requests[0])
      assert_equal(mail, received_mail)
      imap.logout
      assert_equal(2, requests.length)
      assert_equal("RUBY0002 LOGOUT\r\n", requests[1])
    ensure
      imap.disconnect if imap
    end
  end

  test "#append failed with 'NO'" do
    server = create_tcp_server
    port = server.addr[1]
    mail = <<~EOF.gsub(/\n/, "\r\n")
      From: shugo@example.com
      To: matz@example.com
      Subject: hello

      hello world
    EOF
    requests = []
    start_server do
      sock = server.accept
      begin
        sock.print("* OK test server\r\n")
        requests.push(sock.gets)
        sock.print("RUBY0001 NO Mailbox doesn't exist\r\n")
        requests.push(sock.gets)
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0002 OK LOGOUT completed\r\n")
      ensure
        sock.close
        server.close
      end
    end

    begin
      imap = Net::IMAP.new(server_addr, :port => port)
      assert_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", mail)
      end
      assert_equal(1, requests.length)
      assert_equal("RUBY0001 APPEND INBOX {#{mail.size}}\r\n", requests[0])
      imap.logout
      assert_equal(2, requests.length)
      assert_equal("RUBY0002 LOGOUT\r\n", requests[1])
    ensure
      imap.disconnect if imap
    end
  end

  test "#append with binary data" do
    png = File.binread(File.join(TEST_FIXTURE_PATH, "ruby.png"))
    mail = <<~EOF.b.gsub(/\n/, "\r\n")
      From: nick@example.com
      To: shugo@example.com
      Subject: Binary append support
      MIME-Version: 1.0
      Content-Transfer-Encoding: binary
      Content-Type: image/png

    EOF
    mail << png
    mail.freeze
    with_fake_server do |server, imap|
      server.on "APPEND", &:done_ok

      time = Time.new(2026, 2, 20, 10, 00, in: "-0500")
      imap.append "Drafts", mail, %i[Draft Seen], time
      assert_equal 'Drafts (\\Draft \\Seen) "20-Feb-2026 10:00:00 -0500" ' \
                   "~{#{mail.bytesize}}\r\n#{mail}",
                   server.commands.pop.args
    end
  end

  test "#append with CATENATE streams a whole command and keeps command results distinct" do
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    transcript = []
    url1 = "imap://example.com/INBOX/;uid=1/;section=1.1;urlauth=submit+user"
    url2 = "imap://example.com/INBOX/;uid=2/;section=1.2;urlauth=submit+user"
    text = OneShotTextSource.new("hello")
    empty_text = OneShotTextSource.new("")
    too_large = OneShotTextSource.new("", bytesize: 999_999)
    before_reject = ChunkedTextSource.new("abc", 2)
    rejected_text = OneShotTextSource.new("defg")
    after_rejected_text = OneShotTextSource.new("hijkl")

    @threads << Thread.start(server_sock) do |sock|
      begin
        sock.print("* OK test server\r\n")

        transcript << sock.gets
        sock.print("+ Ready for literal data\r\n")
        transcript << sock.read(text.bytesize)
        transcript << sock.gets
        sock.print("RUBY0001 OK [APPENDUID 42 100] CATENATE complete\r\n")

        transcript << sock.gets
        sock.print("+ Ready for empty literal\r\n")
        transcript << sock.read(empty_text.bytesize)
        transcript << sock.gets
        sock.print("RUBY0002 OK CATENATE complete\r\n")

        transcript << sock.gets
        sock.print("RUBY0003 NO [BADURL] unsupported URL\r\n")

        transcript << sock.gets
        sock.print("RUBY0004 NO [TOOBIG] message too large\r\n")

        transcript << sock.gets
        sock.print("+ Ready for literal data\r\n")
        transcript << sock.read(before_reject.bytesize)
        transcript << sock.gets
        sock.print("RUBY0005 NO literal rejected\r\n")

        transcript << sock.gets
        sock.print("RUBY0006 OK NOOP complete\r\n")

        transcript << sock.gets
        sock.print("* BYE terminating connection\r\n")
        sock.print("RUBY0007 OK LOGOUT completed\r\n")
      ensure
        sock.close
      end
    end

    imap = imap_on_socket(client_sock)
    begin
      response = imap.append("INBOX", catenate: [
        {url: url1}, {text: text}, {url: url2}
      ])
      assert_equal "APPENDUID", response.data.code.name
      assert_equal [100], response.data.code.data.assigned_uids.numbers

      imap.append("INBOX", [
        {url: url1}, {text: empty_text}, {url: url2}
      ])

      badurl = assert_local_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", catenate: [{url: "imap://invalid"}])
      end
      assert_equal "BADURL", badurl.response.data.code.name

      toobig = assert_local_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", catenate: [{text: too_large}])
      end
      assert_equal "TOOBIG", toobig.response.data.code.name

      assert_local_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", catenate: [
          {url: url1},
          {text: before_reject},
          {text: rejected_text},
          {text: after_rejected_text},
        ])
      end
      noop = imap.noop
      assert_equal "OK", noop.name

      assert_equal 1, text.read_count
      assert_equal 0, empty_text.read_count
      assert_equal 0, too_large.read_count
      assert_equal 2, before_reject.read_count
      assert_equal 0, rejected_text.read_count
      assert_equal 0, after_rejected_text.read_count
      protocol = transcript.join
      assert_include protocol, %Q!RUBY0001 APPEND INBOX CATENATE (URL [#{url1}] TEXT {5}\r\n!
      assert_include protocol, "hello"
      assert_include protocol, %Q! URL [#{url2}])\r\n!
      assert_include protocol, "RUBY0002 APPEND INBOX CATENATE"
      assert_include protocol, "TEXT {0}\r\n"
      assert_include protocol, "RUBY0006 NOOP\r\n"
    ensure
      imap.logout
    end
  end

  test "#append with CATENATE preserves connection interruption failures" do
    client_sock, server_sock = Socket.pair(:UNIX, :STREAM)
    text = OneShotTextSource.new("hello")

    server_sock.print("* OK test server\r\n")
    imap = imap_on_socket(client_sock)
    @threads << Thread.start do
      server_sock.gets
      server_sock.close
    end
    begin
      assert_local_raise(EOFError) do
        imap.append("INBOX", catenate: [{text: text}])
      end
      assert imap.disconnected?
      assert_equal 0, text.read_count
    ensure
      imap.disconnect
    end
  end

  class OneShotTextSource
    attr_reader :bytesize, :read_count

    def initialize(data, bytesize: data.bytesize)
      @data = data.b
      @bytesize = bytesize
      @read_count = 0
    end

    def read(length)
      raise IOError, "source can only be read once" unless @read_count.zero?
      raise ArgumentError, "requested wrong length" unless length == @data.bytesize
      @read_count += 1
      @data
    end
  end

  class ChunkedTextSource < OneShotTextSource
    def initialize(data, chunk_size)
      super(data)
      @chunk_size = chunk_size
    end

    def read(length)
      @read_count += 1
      @data.slice!(0, [length, @chunk_size].min)
    end
  end

  def imap_on_socket(socket)
    Net::IMAP.allocate.tap do |imap|
      imap.send(:mon_initialize)
      imap.instance_variable_set(:@config, Net::IMAP.config)
      imap.instance_variable_set(:@debug_output_bol, true)
      imap.instance_variable_set(:@exception, nil)
      imap.instance_variable_set(:@greeting, nil)
      imap.instance_variable_set(:@capabilities, [])
      imap.instance_variable_set(:@enabled, Set.new)
      imap.instance_variable_set(:@tls_connected, false)
      imap.instance_variable_set(:@tls_verified, false)
      imap.instance_variable_set(:@connection_state,
                                 Net::IMAP::ConnectionState::Authenticated.new)
      imap.instance_variable_set(:@parser,
                                 Net::IMAP::ResponseParser.new(config: imap.config))
      imap.instance_variable_set(:@responses, Hash.new {|hash, key| hash[key] = [] })
      imap.instance_variable_set(:@response_handlers, [])
      imap.instance_variable_set(:@receiver_thread, nil)
      imap.instance_variable_set(:@receiver_thread_exception, nil)
      imap.instance_variable_set(:@receiver_thread_terminating, false)
      imap.instance_variable_set(:@tag_prefix, "RUBY")
      imap.instance_variable_set(:@tagno, 0)
      imap.instance_variable_set(:@tagged_responses, {})
      imap.instance_variable_set(:@tagged_response_arrival, imap.new_cond)
      imap.instance_variable_set(:@continued_command_tag, nil)
      imap.instance_variable_set(:@continuation_request_arrival, imap.new_cond)
      imap.instance_variable_set(:@continuation_request_exception, nil)
      imap.instance_variable_set(:@idle_done_cond, nil)
      imap.instance_variable_set(:@logout_command_tag, nil)
      imap.instance_variable_set(:@sock, socket)
      imap.instance_variable_set(:@reader,
                                 Net::IMAP::ResponseReader.new(imap, socket))
      imap.send(:start_imap_connection)
    end
  end

end
