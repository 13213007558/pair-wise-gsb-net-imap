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

  # An IO-like message source that can only be read once.
  class ReadOnceSource
    attr_reader :read_count

    def initialize(content)
      @content    = content
      @read_count = 0
    end

    def read
      @read_count += 1
      raise IOError, "read-once source was read again" if @read_count > 1
      @content
    end
  end

  test "#append with CATENATE URLs around a read-once text source" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE UIDPLUS]) do |server, imap|
      server.on("APPEND") do |resp|
        resp.done_ok "APPEND completed", code: "APPENDUID 38505 3955"
      end

      content = "X-Comment: forwarded\r\n"
      text = ReadOnceSource.new(content)
      response = imap.append("INBOX", [
        Net::IMAP::CatenateURL["imap://imap.example.com/INBOX/;uid=24356"],
        text,
        Net::IMAP::CatenateURL["imap://imap.example.com/INBOX/;uid=24357"],
      ])

      assert_equal 1, text.read_count
      assert_equal "INBOX " \
        "URL imap://imap.example.com/INBOX/;uid=24356 " \
        "{#{content.bytesize}}\r\n#{content} " \
        "URL imap://imap.example.com/INBOX/;uid=24357",
        server.commands.pop.args
      code = response.data.code
      assert_equal "APPENDUID", code.name
      assert_equal 38505, code.data.uidvalidity
      assert_equal [3955], code.data.assigned_uids.numbers
    end
  end

  test "#append with CATENATE empty text part" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      server.on("APPEND", &:done_ok)

      imap.append("INBOX", [
        Net::IMAP::CatenateURL["imap://imap.example.com/INBOX/;uid=24356"],
        "",
        Net::IMAP::CatenateURL["imap://imap.example.com/INBOX/;uid=24357"],
      ])

      assert_equal "INBOX " \
        "URL imap://imap.example.com/INBOX/;uid=24356 {0}\r\n " \
        "URL imap://imap.example.com/INBOX/;uid=24357",
        server.commands.pop.args
    end
  end

  test "#append CATENATE rejection skips unread sources and keeps connection" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      server.literal_acceptor = ->(_buf, _size) { false }
      server.on("APPEND", &:done_ok)

      unread = ReadOnceSource.new("must never be read")
      error = assert_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", [
          Net::IMAP::CatenateURL["imap://imap.example.com/INBOX/;uid=24356"],
          "rejected text",
          unread,
        ])
      end
      assert_match(/literal rejected/, error.message)

      assert_equal 0, unread.read_count
      assert_equal "OK", imap.noop.name
      assert_equal "NOOP", server.commands.pop.name
    end
  end

  test "#append CATENATE BADURL and TOOBIG errors are distinct" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      server.on("APPEND") { |resp| resp.fail_no "bad url", code: "BADURL" }
      error = assert_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", [Net::IMAP::CatenateURL["imap://x/y"]])
      end
      assert_equal "BADURL", error.response.data.code.name
    end

    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      server.on("APPEND") { |resp| resp.fail_no "too big", code: "TOOBIG" }
      error = assert_raise(Net::IMAP::NoResponseError) do
        imap.append("INBOX", [Net::IMAP::CatenateURL["imap://x/y"], "text"])
      end
      assert_equal "TOOBIG", error.response.data.code.name
    end
  end

  test "#append CATENATE connection interruption is distinct from NO" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      server.on("APPEND") { |_resp| throw :eof }
      assert_raise(Net::IMAP::ByeResponseError) do
        imap.append("INBOX", [Net::IMAP::CatenateURL["imap://x/y"]])
      end
    end
  end

  test "#append CATENATE validates parts without reading sources" do
    with_in_memory_fake_server(with_extensions: %i[CATENATE]) do |server, imap|
      unread = ReadOnceSource.new("must never be read")
      assert_raise(Net::IMAP::DataFormatError) do
        imap.append("INBOX", [])
      end
      assert_raise(TypeError) do
        imap.append("INBOX", [unread, 42])
      end
      assert_raise(Net::IMAP::DataFormatError) do
        imap.append("INBOX", [Net::IMAP::CatenateURL["imap://x/\r\ny"]])
      end
      assert_equal 0, unread.read_count
      assert_empty server.commands
    end
  end

end
