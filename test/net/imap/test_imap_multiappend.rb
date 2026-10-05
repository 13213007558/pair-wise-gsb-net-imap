# frozen_string_literal: true

require "net/imap"
require "stringio"
require "test/unit"
require_relative "fake_server"

class IMAPMultiAppendTest < Net::IMAP::TestCase
  include Net::IMAP::TestCase::SimpleTCPServerHelper
  include Net::IMAP::FakeServer::TestHelper

  # Three messages with different contents and different lengths.
  MESSAGES = [
    "Subject: first\r\n\r\nhello\r\n",
    "Subject: second\r\n\r\nthis body is a bit longer\r\n",
    "Subject: third\r\n\r\nbye\r\n",
  ].freeze

  test "#append_multi appends messages with their own flags and dates, " \
       "and returns UIDs in input order" do
    with_fake_server(select: "INBOX",
                     extensions: %i[MULTIAPPEND UIDPLUS]) do |server, imap|
      server.on "APPEND" do |cmd|
        cmd.done_ok code: "APPENDUID 38505 3955:3957"
      end
      time = Time.new(2026, 2, 20, 10, 00, in: "-0500")
      uids = imap.append_multi("Drafts", [
        {message: MESSAGES[0], flags: %i[Draft]},
        {message: MESSAGES[1], date_time: time},
        {message: MESSAGES[2], flags: %i[Seen Draft], date_time: time},
      ])
      assert_equal [3955, 3956, 3957], uids
      cmd = server.commands.pop
      assert_equal "APPEND", cmd.name
      expected_args =
        "Drafts (\\Draft) {#{MESSAGES[0].bytesize}}\r\n#{MESSAGES[0]}" \
        "\"20-Feb-2026 10:00:00 -0500\" " \
        "{#{MESSAGES[1].bytesize}}\r\n#{MESSAGES[1]}" \
        "(\\Seen \\Draft) \"20-Feb-2026 10:00:00 -0500\" " \
        "{#{MESSAGES[2].bytesize}}\r\n#{MESSAGES[2]}"
      assert_equal expected_args, cmd.args
    end
  end

  test "#append_multi streams IO bodies, using non-synchronizing literals " \
       "when the server allows them" do
    with_fake_server(select: "INBOX",
                     extensions: %i[MULTIAPPEND UIDPLUS LITERAL+]) do |server, imap|
      server.on "APPEND" do |cmd|
        cmd.done_ok code: "APPENDUID 38505 3960:3962"
      end
      bodies = MESSAGES.map { StringIO.new(_1) }
      uids = imap.append_multi("INBOX", [
        {message: bodies[0]},
        {message: bodies[1], bytesize: MESSAGES[1].bytesize},
        {message: bodies[2]},
      ])
      assert_equal [3960, 3961, 3962], uids
      assert bodies.all? { _1.pos == _1.size }
      expected_args =
        "INBOX {#{MESSAGES[0].bytesize}+}\r\n#{MESSAGES[0]}" \
        "{#{MESSAGES[1].bytesize}+}\r\n#{MESSAGES[1]}" \
        "{#{MESSAGES[2].bytesize}+}\r\n#{MESSAGES[2]}"
      assert_equal expected_args, server.commands.pop.args
    end
  end

  test "#append_multi negotiates literal8 for message bodies containing NUL" do
    nul_body = "Subject: nul\r\n\r\nbinary\x00body\r\n".b
    with_fake_server(select: "INBOX",
                     extensions: %i[MULTIAPPEND UIDPLUS BINARY]) do |server, imap|
      server.on "APPEND" do |cmd|
        cmd.done_ok code: "APPENDUID 38505 3955:3957"
      end
      uids = imap.append_multi("INBOX", [
        {message: MESSAGES[0]},
        {message: nul_body},
        {message: MESSAGES[2]},
      ])
      assert_equal [3955, 3956, 3957], uids
      expected_args =
        "INBOX {#{MESSAGES[0].bytesize}}\r\n#{MESSAGES[0]}" \
        "~{#{nul_body.bytesize}}\r\n#{nul_body}" \
        "{#{MESSAGES[2].bytesize}}\r\n#{MESSAGES[2]}"
      assert_equal expected_args.b, server.commands.pop.args.b
    end
  end

  test "#append_multi does not consume later IOs when the server rejects " \
       "the command before a continuation request" do
    server = create_tcp_server
    port = server.addr[1]
    bodies = MESSAGES.map { StringIO.new(_1) }
    trace = []
    start_server do
      sock = server.accept
      begin
        server_send trace, sock,
                    "* OK [CAPABILITY IMAP4rev1 MULTIAPPEND UIDPLUS] fake"
        trace << "C: #{sock.gets.chomp}"
        server_send trace, sock, "+ Ready for literal data"
        trace << "C: #{sock.read(MESSAGES[0].bytesize).chomp}"
        trace << "C: #{sock.gets.chomp}"
        server_send trace, sock, "RUBY0001 NO second message rejected"
        trace << "C: #{sock.gets.chomp}"
        server_send trace, sock, "* BYE terminating connection"
        server_send trace, sock, "RUBY0002 OK LOGOUT completed"
      ensure
        sock.close
        server.close
      end
    end

    imap = Net::IMAP.new(server_addr, port: port)
    assert_raise(Net::IMAP::NoResponseError) do
      imap.append_multi("INBOX", [
        {message: bodies[0]},
        {message: bodies[1]},
        {message: bodies[2]},
      ])
    end
    assert_equal MESSAGES[0].bytesize, bodies[0].pos
    assert_equal 0, bodies[1].pos, "rejected message IO must not be consumed"
    assert_equal 0, bodies[2].pos, "unsent message IO must not be consumed"
    imap.logout
    assert_equal [
      "S: * OK [CAPABILITY IMAP4rev1 MULTIAPPEND UIDPLUS] fake",
      "C: RUBY0001 APPEND INBOX {#{MESSAGES[0].bytesize}}",
      "S: + Ready for literal data",
      "C: #{MESSAGES[0].chomp}",
      "C:  {#{MESSAGES[1].bytesize}}",
      "S: RUBY0001 NO second message rejected",
      "C: RUBY0002 LOGOUT",
      "S: * BYE terminating connection",
      "S: RUBY0002 OK LOGOUT completed",
    ], trace
  ensure
    imap.disconnect if imap
  end

  test "#append_multi raises when APPENDUID cannot be paired with the batch" do
    with_fake_server(select: "INBOX",
                     extensions: %i[MULTIAPPEND UIDPLUS]) do |server, imap|
      server.on "APPEND" do |cmd|
        cmd.done_ok code: "APPENDUID 38505 3955:3956" # 2 UIDs for 3 messages
      end
      error = assert_raise(Net::IMAP::InvalidResponseError) do
        imap.append_multi("INBOX", MESSAGES.map { {message: _1} })
      end
      assert_match(/APPENDUID uid-set size \(2\).*messages \(3\)/,
                   error.message)
    end
  end

  test "#append_multi raises and reports no UIDs when the send is interrupted" do
    server = create_tcp_server
    port = server.addr[1]
    start_server do
      sock = server.accept
      begin
        sock.print "* OK [CAPABILITY IMAP4rev1 MULTIAPPEND UIDPLUS] fake\r\n"
        line = sock.gets
        size = line.slice(/\{(\d+)\}\r\n/, 1).to_i
        sock.print "+ Ready for literal data\r\n"
        sock.read(size)
        sock.gets # the second literal prefix
        sock.close # abrupt close: no continuation, no tagged response
      ensure
        server.close
      end
    end

    imap = Net::IMAP.new(server_addr, port: port)
    assert_raise(EOFError) do
      imap.append_multi("INBOX", MESSAGES)
    end
  ensure
    imap.disconnect if imap
  end

  test "#append_multi validates its arguments before sending" do
    with_fake_server(select: "INBOX",
                     extensions: %i[MULTIAPPEND]) do |server, imap|
      assert_raise(ArgumentError) { imap.append_multi("INBOX", []) }
      io_without_size = Class.new { def read(*args) = nil }.new
      assert_raise(ArgumentError) do
        imap.append_multi("INBOX", [{message: io_without_size}])
      end
      assert_raise(ArgumentError) do
        imap.append_multi("INBOX", [{message: "x", bogus: 1}])
      end
      assert_raise(ArgumentError) do
        imap.append_multi("INBOX", [{flags: %i[Seen]}])
      end
    end
  end

  private

  def server_send(trace, sock, line)
    trace << "S: #{line}"
    sock.print "#{line}\r\n"
  end

end
