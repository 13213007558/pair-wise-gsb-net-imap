# frozen_string_literal: true

require_relative "../fake_server"

module Net::IMAP::FakeServer::TestHelper

  IO_ERRORS = [
    IOError,
    EOFError,
    Errno::ECONNABORTED,
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ETIMEDOUT,
  ].freeze

  # A Net::IMAP client that connects over an in-memory socketpair, rather
  # than a TCP socket.  Used by #with_in_memory_fake_server.
  class InMemoryClient < Net::IMAP
    def initialize(sock, **config)
      @in_memory_socket = sock
      super("in-memory", **config)
    end

    private

    def tcp_socket(*) = @in_memory_socket
  end

  # Yields a FakeServer::Connection and a Net::IMAP client, connected to
  # each other by an in-memory socketpair (no TCP listener is needed).
  #
  # The yielded server quacks like a FakeServer: it responds to #on,
  # #commands, #state, and #literal_acceptor=.
  def with_in_memory_fake_server(timeout: 10, **opts)
    timeout *= EnvUtil.timeout_scale || 1 if defined?(EnvUtil.timeout_scale)
    Timeout.timeout(timeout) do
      client_socket, server_socket = UNIXSocket.pair
      config     = Net::IMAP::FakeServer::Configuration.new(**opts)
      server     = Net::IMAP::FakeServer::Connection.new(
        Struct.new(:config).new(config), tcp_socket: server_socket
      )
      server_thread = Thread.new do
        Thread.current.report_on_exception = false
        server.run
      rescue *IO_ERRORS
        raise unless config.ignore_abrupt_eof?
      end
      client = InMemoryClient.new(client_socket)
      begin
        yield server, client
      ensure
        client.logout! unless client.disconnected?
        client_socket.close unless client_socket.closed?
        server_thread.join
      end
    end
  end

  def run_fake_server_in_thread(ignore_io_error: false,
                                report_on_exception: true,
                                timeout: 10, **opts)
    timeout *= EnvUtil.timeout_scale || 1 if defined?(EnvUtil.timeout_scale)
    Timeout.timeout(timeout) do
      server = Net::IMAP::FakeServer.new(timeout: timeout, **opts)
      @threads << Thread.new do
        Thread.current.abort_on_exception  = false
        Thread.current.report_on_exception = report_on_exception
        server.run
      rescue *IO_ERRORS
        raise unless ignore_io_error
      end
      yield server
    ensure
      begin
        server&.shutdown
      rescue *IO_ERRORS
        raise unless ignore_io_error
      end
    end
  end

  def with_client(*args, **kwargs)
    client = Net::IMAP.new(*args, **kwargs)
    yield client
  ensure
    if client && !client.disconnected?
      client.logout!
    end
  end

  def with_fake_server(select: nil, **opts)
    run_fake_server_in_thread(**opts) do |server|
      tls = opts[:implicit_tls]
      tls = {ca_file: server.config.tls[:ca_file]} if tls == true
      with_client("localhost", port: server.port, ssl: tls) do |client|
        if select
          client.select(select)
          server.commands.pop
          assert server.state.selected?
        end
        yield server, client
      end
    end
  end

end
