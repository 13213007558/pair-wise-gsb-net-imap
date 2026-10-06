# frozen_string_literal: true

require_relative "../../lib/helper"
require_relative "fake_server"

class IMAPMetadataTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  test "getmetadata and setmetadata round trip" do
    with_fake_server(with_extensions: %i[METADATA]) do |server, imap|
      server.on "GETMETADATA" do |resp|
        resp.untagged "METADATA \"\" (/shared/comment {9}\r\n(hi mom!))"
        resp.untagged "METADATA OtherX (/shared/comment {12}\r\nnot for you!)"
        resp.tagged :OK, code: ["METADATA", "LONGENTRIES 2"],
                   text: "metadata returned with limits"
      end

      result = imap.getmetadata("", "/shared/comment", depth: 1, maxsize: 10)
      command = server.commands.pop
      assert_equal "GETMETADATA", command.name
      assert_equal '"" (DEPTH 1 MAXSIZE 10) /shared/comment', command.args
      assert_equal({"/shared/comment" => "(hi mom!)"}, result)
      assert_equal Encoding::BINARY, result["/shared/comment"].encoding

      interleaved = imap.responses("METADATA")
      assert_equal [
        Net::IMAP::MetadataData.new(
          "OtherX", {"/shared/comment" => "not for you!"}
        )
      ], interleaved

      warning = nil
      server.on "SETMETADATA" do |resp|
        warning = resp.done_ok
      end
      tagged = imap.setmetadata(
        "INBOX",
        "/shared/comment"  => "",
        "/shared/empty"    => Net::IMAP::Literal.new(""),
        "/private/comment" => nil,
        "/private/binary"  => "\xff(h)\x00"
      )
      assert_same warning, tagged
      command = server.commands.pop
      assert_equal "SETMETADATA", command.name
      assert_include command.raw, "/shared/comment \"\" /private/comment NIL"
      assert_include command.raw, "/shared/empty {0}\r\n"
      assert_match(/~\{5\}\r\n\xFF\(h\)\x00/xn, command.raw)

      server.on "GETMETADATA" do |resp|
        resp.untagged "METADATA INBOX (/shared/comment {5}\r\n(too))"
        resp.fail_no "entry too big", code: ["METADATA", "TOOBIG"]
      end
      error = assert_raise(Net::IMAP::NoResponseError) do
        imap.getmetadata("INBOX", "/shared/comment", maxsize: 5)
      end
      command = server.commands.pop
      assert_equal "INBOX (MAXSIZE 5) /shared/comment", command.args
      assert_equal "entry too big", error.message
      assert_equal "METADATA", error.response.data.code.name
      assert_equal Net::IMAP::ResponseCode.new("TOOBIG", nil),
                   error.response.data.code.data

      server.on "NOOP", &:done_ok
      assert_kind_of Net::IMAP::TaggedResponse, imap.noop
      assert server.commands.pop.name == "NOOP"
    end
  end

  test "parses metadata response codes" do
    parser = Net::IMAP::ResponseParser.new

    response = parser.parse "A1 NO [METADATA (LONGENTRIES 12)] limit\r\n"
    assert_equal Net::IMAP::ResponseCode.new("LONGENTRIES", 12),
                 response.data.code.data

    response = parser.parse "A2 NO [METADATA (MAXSIZE 1024)] limit\r\n"
    assert_equal Net::IMAP::ResponseCode.new("MAXSIZE", 1024),
                 response.data.code.data

    response = parser.parse "A3 NO [METADATA (TOOMANY)] limit\r\n"
    assert_equal Net::IMAP::ResponseCode.new("TOOMANY", nil),
                 response.data.code.data
  end

  test "parses metadata entries with binary literals, NIL, and empty values" do
    parser = Net::IMAP::ResponseParser.new
    response = parser.parse(
      "* METADATA \"\" (/binary {3}\r\n(\xff) /octets ~{3}\r\n\xff\x00a " \
      "/missing NIL /empty \"\")\r\n".b
    )
    assert_equal Net::IMAP::MetadataData.new(
      "",
      "/binary"  => "(\xff)".b,
      "/octets"  => "\xff\x00a".b,
      "/missing" => nil,
      "/empty"   => ""
    ), response.data
  end
end
