# frozen_string_literal: true

require "net/imap"
require "socket"
require "stringio"
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

  test "#multiappend sends each message and returns APPENDUIDs in order" do
    first  = "Subject: first\r\n\r\nhello\r\n".b
    second = "Subject: second\r\n\r\nlonger second body\r\n".b
    third  = "Subject: third\r\n\r\n3\r\n".b
    date   = Time.new(2026, 2, 20, 10, 0, 0, in: "-0500")
    wire, uids = nil, nil

    imap, = imap_on_socket_pair(
      %w[MULTIAPPEND UIDPLUS],
      config: {max_non_synchronizing_literal: -1},
    ) do |server|
      wire = +"".b
      read_multiappend(server, wire) do |_index, size|
        server.print("+ Continue\r\n")
        server.read(size)
      end
      server.print("RUBY0001 OK [APPENDUID 42 101:103] done\r\n")
    end

    begin
      uids = imap.multiappend(
        "INBOX",
        [
          {message: StringIO.new(first.dup)},
          Net::IMAP::AppendMessage.new(
            StringIO.new(second.dup), flags: [:Seen], date_time: date,
          ),
          {message: explicit_length_io(third.dup, third.bytesize),
           flags: [:Draft, :Flagged], length: third.bytesize},
        ],
      )
    ensure
      imap.disconnect
    end

    expected = +"RUBY0001 MULTIAPPEND INBOX ".b
    expected << "{#{first.bytesize}}\r\n#{first}".b
    expected << " (\\Seen) \"20-Feb-2026 10:00:00 -0500\" ".b
    expected << "{#{second.bytesize}}\r\n#{second}".b
    expected << " (\\Draft \\Flagged) ".b
    expected << "{#{third.bytesize}}\r\n#{third}\r\n".b
    assert_equal expected, wire
    assert_equal [101, 102, 103], uids
  end

  test "#multiappend waits after a rejected message and does not consume later IO" do
    first  = "first body\r\n".b
    second = "second body\r\n".b
    third  = "third body\r\n".b
    reads = 0
    third_io = Object.new
    third_io.define_singleton_method(:read) do |*|
      raise "third message must not be read"
    end
    third_io.define_singleton_method(:size) { third.bytesize }
    rejection = Queue.new

    imap, = imap_on_socket_pair(
      %w[MULTIAPPEND],
      config: {max_non_synchronizing_literal: -1},
    ) do |server|
      prefix = read_literal_prefix(server)
      server.print("+ Continue first\r\n")
      server.read(prefix.fetch(:size))
      prefix = read_literal_prefix(server)
      server.print("+ Continue second\r\n")
      server.read(prefix.fetch(:size))
      server.print("RUBY0001 NO second message rejected\r\n")
      rejection << :sent
      server.read
    end

    begin
      assert_raise(Net::IMAP::NoResponseError) do
        imap.multiappend(
          "INBOX",
          [
            counting_io(StringIO.new(first.dup)) { reads += 1 },
            counting_io(StringIO.new(second.dup)) { reads += 1 },
            third_io,
          ],
        )
      end
      assert_equal :sent, rejection.pop
      assert_equal 2, reads
    ensure
      imap.disconnect
    end
  end

  test "#multiappend uses binary non-synchronizing literals for NUL content" do
    message = "Subject: binary\r\n\r\nab\0c\r\n".b
    wire = nil

    imap, = imap_on_socket_pair(%w[MULTIAPPEND UIDPLUS BINARY LITERAL+]) do |server|
      expected = "RUBY0001 MULTIAPPEND INBOX ~{#{message.bytesize}+}\r\n#{message}\r\n".b
      wire = read_exactly(server, expected.bytesize)
      server.print("RUBY0001 OK [APPENDUID 7 20] done\r\n")
    end

    begin
      uids = imap.multiappend(
        "INBOX",
        {message: StringIO.new(message.dup), binary: true},
      )
    ensure
      imap.disconnect
    end

    assert_equal "RUBY0001 MULTIAPPEND INBOX ~{#{message.bytesize}+}\r\n#{message}\r\n".b,
                 wire
    assert_equal [20], uids
  end

  test "#multiappend does not report success when message IO is interrupted" do
    first = "first body\r\n".b
    interrupted_io = Object.new
    read_count = 0
    interrupted_io.define_singleton_method(:size) { 100 }
    interrupted_io.define_singleton_method(:read) do |length|
      read_count += 1
      raise IOError, "interrupted" if read_count == 1
      "x" * length
    end

    command_prefix = nil
    imap, = imap_on_socket_pair(
      %w[MULTIAPPEND UIDPLUS],
      config: {max_non_synchronizing_literal: -1},
    ) do |server|
      prefix = read_literal_prefix(server)
      server.print("+ Continue first\r\n")
      server.read(prefix.fetch(:size))
      command_prefix = read_literal_prefix(server)
    end

    begin
      error = nil
      begin
        imap.multiappend(
          "INBOX",
          [StringIO.new(first.dup), interrupted_io],
        )
      rescue StandardError => error
      end
      assert_kind_of(IOError, error)
      assert_equal 100, command_prefix.fetch(:size)
    ensure
      imap.disconnect
    end
  end

  test "#multiappend rejects an APPENDUID range with the wrong message count" do
    message = "one body\r\n".b

    imap, = imap_on_socket_pair(
      %w[MULTIAPPEND UIDPLUS],
      config: {max_non_synchronizing_literal: -1},
    ) do |server|
      prefix = read_literal_prefix(server)
      server.print("+ Continue\r\n")
      server.read(prefix.fetch(:size))
      server.readline
      server.print("RUBY0001 OK [APPENDUID 42 101:102] wrong count\r\n")
    end

    begin
      assert_raise(Net::IMAP::InvalidResponseError) do
        imap.multiappend("INBOX", StringIO.new(message.dup))
      end
    ensure
      imap.disconnect
    end
  end

  private

  def imap_on_socket_pair(capabilities, config: nil)
    client_socket, server_socket = Socket.pair(:UNIX, :STREAM)
    greeting = "* OK [CAPABILITY IMAP4rev1 #{capabilities.join(' ')}] test\r\n"
    thread = Thread.new do
      begin
        server_socket.print(greeting)
        yield server_socket
      rescue IOError, Errno::ECONNRESET
      ensure
        server_socket.close unless server_socket.closed?
      end
    end
    imap = Net::IMAP.allocate
    imap.singleton_class.send(:define_method, :tcp_socket) {|*, **| client_socket }
    imap.send(:initialize, "localhost", config: config || Net::IMAP::Config.global)
    thread.abort_on_exception = true
    @threads << thread
    [imap, thread]
  rescue
    client_socket&.close
    server_socket&.close
    raise
  end

  def read_literal_prefix(server)
    line = "".b
    until (match = line.match(/~?\{(?<size>\d+)(?<non_sync>\+)?\}\r\n\z/n))
      line << server.readline.b
    end
    /~?\{(?<size>\d+)(?<non_sync>\+)?\}\r\n\z/n =~ line or
      flunk("expected literal prefix, got: #{line.inspect}")
    {size: Integer(size), non_sync: !!non_sync}
  end

  def read_multiappend(server, wire)
    3.times do |index|
      chunk = server.readline.b
      wire << chunk
      until (match = chunk.match(/~?\{(\d+)(\+)?\}\r\n\z/n))
        chunk = server.readline.b
        wire << chunk
      end
      body = yield(index, Integer(match[1]))
      wire << body
    end
    wire << server.readline.b
  end

  def counting_io(io, size: true)
    wrapper = Object.new
    wrapper.define_singleton_method(:read) {|*args| io.read(*args).tap { yield } }
    wrapper.define_singleton_method(:size) { io.size } if size
    wrapper
  end

  def explicit_length_io(body, length)
    source = StringIO.new(body)
    wrapper = Object.new
    wrapper.define_singleton_method(:read) {|*args| source.read(*args) }
    wrapper.define_singleton_method(:length) { length }
    wrapper
  end

  def read_exactly(io, length)
    buffer = "".b
    buffer << io.read(length - buffer.bytesize) until buffer.bytesize == length
    buffer
  end

end
