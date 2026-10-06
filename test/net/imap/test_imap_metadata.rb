# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPMetadataTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  test "getmetadata, setmetadata nil, and interleaved mailbox responses" do
    with_fake_server(with_extensions: %i[METADATA]) do |server, imap|
      server.on "GETMETADATA" do |resp|
        resp.untagged 'METADATA Other (/shared/comment "interleaved")'
        resp.untagged %(METADATA "" (/shared/comment {8}\r\n(a) b(c)))
        resp.done_ok
      end

      result = imap.getmetadata("", "/shared/comment")
      command = server.commands.pop
      assert_equal "GETMETADATA", command.name
      assert_equal '"" /shared/comment', command.args
      assert_equal "", result.mailbox
      assert_equal({"/shared/comment" => "(a) b(c)"}, result.entries)
      assert_empty result.omitted
      assert_nil result.longentries

      other = imap.responses("METADATA", &:to_a)
      assert_equal ["Other"], other.map(&:mailbox)
      assert_equal "interleaved", other.first.entries["/shared/comment"]

      server.on "SETMETADATA", &:done_ok
      imap.setmetadata("", "/private/comment", nil)
      command = server.commands.pop
      assert_equal "SETMETADATA", command.name
      assert_equal '"" (/private/comment NIL)', command.args

      imap.noop
      assert_equal "NOOP", server.commands.pop.name
    end
  end

  test "getmetadata options, omitted entries, and LONGENTRIES" do
    with_fake_server(with_extensions: %i[METADATA]) do |server, imap|
      server.on "GETMETADATA" do |resp|
        resp.untagged 'METADATA INBOX (/private/comment "kept" /too-large)'
        resp.done_ok code: "LONGENTRIES 1"
      end

      result = imap.getmetadata("INBOX",
                                "/private/comment", "/too-large",
                                depth: 0, maxsize: 4)
      command = server.commands.pop
      assert_equal "INBOX (DEPTH 0 MAXSIZE 4) /private/comment /too-large",
                   command.args
      assert_equal "INBOX", result.mailbox
      assert_equal 0, result.depth
      assert_equal 4, result.maxsize
      assert_equal 1, result.longentries
      assert_equal ["/too-large"], result.omitted
      assert_equal "kept", result["/private/comment"]
      assert_nil result["/too-large"]
      assert result.key?("/too-large")
    end
  end

  test "setmetadata preserves empty strings, nil, and literals" do
    with_fake_server(with_extensions: %i[METADATA]) do |server, imap|
      server.on "SETMETADATA", &:done_ok

      values = {
        "/shared/empty"         => "",
        "/shared/empty-literal" => Net::IMAP::Literal.new(""),
        "/private/delete"       => nil,
        "/private/binary"       => "\x00()".b,
        "/private/forced"       => Net::IMAP::Literal.new("()"),
      }
      imap.setmetadata("INBOX", values)

      command = server.commands.pop
      expected_args = "INBOX (" \
        "/shared/empty \"\" " \
        "/shared/empty-literal {0}\r\n " \
        "/private/delete NIL " \
        "/private/binary ~{3}\r\n\x00() " \
        "/private/forced {2}\r\n())"
      assert_equal expected_args, command.args
    end
  end

  test "SETMETADATA MAXSIZE errors retain the limit" do
    with_fake_server(with_extensions: %i[METADATA]) do |server, imap|
      server.on "SETMETADATA" do |resp|
        resp.fail_no "metadata value too large", code: "MAXSIZE 10240"
      end

      error = assert_raise(Net::IMAP::NoResponseError) do
        imap.setmetadata("INBOX", "/private/comment", "x" * 20_000)
      end
      assert_equal "MAXSIZE", error.response.data.code.name
      assert_equal 10_240, error.response.data.code.data
      assert_equal "SETMETADATA", server.commands.pop.name
    end
  end

end
