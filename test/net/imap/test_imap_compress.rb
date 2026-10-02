# frozen_string_literal: true

require "net/imap"
require "test/unit"
require_relative "fake_server"

class IMAPCompressTest < Net::IMAP::TestCase
  include Net::IMAP::FakeServer::TestHelper

  test "#compress enables DEFLATE for subsequent commands and responses" do
    with_fake_server(select: "INBOX",
                     with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      assert imap.capable?("COMPRESS=DEFLATE")

      response = imap.compress
      assert_equal "OK", response.name
      assert_equal "RUBY0002 COMPRESS DEFLATE", server.commands.pop.raw.strip

      # multiple commands over the single continuous deflate stream
      imap.noop
      assert_equal "RUBY0003 NOOP", server.commands.pop.raw.strip
      imap.select("INBOX")
      assert_equal "RUBY0004 SELECT INBOX", server.commands.pop.raw.strip
      imap.noop
      assert_equal "RUBY0005 NOOP", server.commands.pop.raw.strip
    end
  end

  test "tagged OK merged with the first compressed response in a single write" do
    with_fake_server(with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      server.on "COMPRESS" do |resp|
        deflate = state.use_deflate
        deflate.write(
          "#{resp.tag} OK COMPRESS active\r\n" +
          deflate.deflate("* OK merged compressed response\r\n")
        )
      end
      imap.compress
      imap.noop # wait until the unsolicited response has been handled
      assert_equal "merged compressed response",
                   imap.responses("OK", &:last).text
    end
  end

  test "compressed response data arriving one byte at a time" do
    with_fake_server(with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      server.on "COMPRESS" do |resp|
        deflate = state.use_deflate
        deflate.write("#{resp.tag} OK COMPRESS active\r\n")
        deflate.deflate("* 42 EXISTS\r\n").each_byte do |byte|
          deflate.write(byte.chr)
        end
      end
      imap.compress
      imap.noop # wait until the unsolicited response has been handled
      assert_equal 42, imap.responses("EXISTS", &:last)
    end
  end

  test "binary literals in both directions, counted as uncompressed bytes" do
    binary = (0..255).map(&:chr).join.b
    with_fake_server(select: "INBOX",
                     with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      server.on("APPEND") {|resp| resp.done_ok }
      server.on "FETCH" do |resp|
        resp.print "* 1 FETCH (BODY[] {#{binary.bytesize}}\r\n"
        resp.print binary
        resp.print ")\r\n"
        resp.done_ok
      end
      imap.compress
      assert_equal "COMPRESS", server.commands.pop.name

      imap.append("INBOX", binary)
      append = server.commands.pop
      assert_equal "APPEND", append.name
      assert_include append.raw, binary

      message = imap.fetch(1, "BODY[]").first.message
      assert_equal binary, message
    end
  end

  test "compress over an implicit TLS connection" do
    with_fake_server(implicit_tls: true,
                     with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      assert imap.tls_connected?
      imap.compress
      assert_equal "RUBY0001 COMPRESS DEFLATE", server.commands.pop.raw.strip
      imap.noop
      assert_equal "RUBY0002 NOOP", server.commands.pop.raw.strip
      assert imap.tls_connected?
    end
  end

  test "server refuses COMPRESS with NO, connection stays uncompressed" do
    with_fake_server(with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      server.on("COMPRESS") {|resp| resp.fail_no "DEFLATE is not available" }
      error = assert_raise(Net::IMAP::NoResponseError) { imap.compress }
      assert_include error.message, "DEFLATE is not available"
      assert_equal "RUBY0001 COMPRESS DEFLATE", server.commands.pop.raw.strip
      # the connection is still usable, without compression
      imap.noop
      assert_equal "RUBY0002 NOOP", server.commands.pop.raw.strip
    end
  end

  test "server refuses COMPRESS with BAD" do
    with_fake_server(with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      server.on("COMPRESS") {|resp| resp.fail_bad "COMPRESS is not allowed" }
      assert_raise(Net::IMAP::BadResponseError) { imap.compress }
      assert_equal "RUBY0001 COMPRESS DEFLATE", server.commands.pop.raw.strip
      imap.noop
      assert_equal "RUBY0002 NOOP", server.commands.pop.raw.strip
    end
  end

  test "corrupted compressed data raises Zlib::DataError" do
    with_fake_server(ignore_io_error: true,
                     with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      deflate = nil
      server.on "COMPRESS" do |resp|
        resp.done_ok
        deflate = state.use_deflate
      end
      server.on "NOOP" do |_resp|
        deflate.write("\x07".b) # invalid DEFLATE block type
      end
      imap.compress
      assert_raise(Zlib::DataError) { imap.noop }
    end
  end

  test "server closes the compressed connection prematurely" do
    with_fake_server(ignore_io_error: true,
                     with_extensions: %w[COMPRESS=DEFLATE]) do |server, imap|
      deflate = nil
      server.on "COMPRESS" do |resp|
        resp.done_ok
        deflate = state.use_deflate
      end
      server.on "NOOP" do |_resp|
        deflate.print("* OK still compressed\r\n")
        deflate.close
      end
      imap.compress
      assert_raise(EOFError) { imap.noop }
      assert_equal "still compressed", imap.responses("OK", &:last).text
    end
  end

end
