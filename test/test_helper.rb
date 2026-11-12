# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "quicopt"

require "minitest/autorun"
require "socket"

# A minimal HTTP/1.1 server the client tests talk to over a real socket.
#
# The transport is a third of this gem — headers, the query string, gzip framing,
# key capture, the error path — so the tests exercise it end to end rather than
# stubbing +Net::HTTP+ and asserting against a mock of our own assumptions.
#
# The handler block receives a +Request+ and returns +[status, headers, body]+.
#
# +keep_alive+ sets what happens to a connection after a response: +false+ says
# +Connection: close+ and closes it, +true+ keeps it for the client's next
# request, and +:drop+ closes it without saying so, as a server does whose idle
# timeout ran out.
class StubServer
  Request = Struct.new(:method, :path, :query, :headers, :body)

  # @return [Array<Request>] every request received, in order
  attr_reader :requests
  # @return [Integer] the connections accepted so far
  attr_reader :connections

  def initialize(keep_alive: false, &handler)
    @handler = handler
    @keep_alive = keep_alive
    @requests = []
    @connections = 0
    @socket = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def base_url
    "http://127.0.0.1:#{@socket.addr[1]}"
  end

  def stop
    @socket.close
    @thread.join(2)
  end

  # Run a server with +handler+ for the duration of the block, then shut it down.
  def self.run(handler, keep_alive: false)
    server = new(keep_alive: keep_alive, &handler)
    yield server
  ensure
    server&.stop
  end

  private

  def serve
    loop do
      connection = @socket.accept
      @connections += 1
      # a kept connection waits for its next request, so each gets a thread
      @keep_alive == true ? Thread.new(connection) { |c| handle(c) } : handle(connection)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(connection)
    loop do
      request = read_request(connection)
      break if request.nil?

      @requests << request
      status, headers, body = @handler.call(request)
      write_response(connection, status, headers || {}, body.to_s)
      break unless @keep_alive == true
    end
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil # the client gave up on this connection
  ensure
    begin
      connection.close
    rescue IOError
      nil
    end
  end

  def read_request(connection)
    line = connection.gets
    return nil if line.nil?

    method, target, = line.split
    path, query = target.split("?", 2)
    headers = {}
    while (header = connection.gets) && header != "\r\n"
      key, value = header.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    Request.new(method, path, query, headers, length.positive? ? connection.read(length) : nil)
  end

  def write_response(connection, status, headers, body)
    connection.write("HTTP/1.1 #{status} Status\r\n")
    headers.each { |key, value| connection.write("#{key}: #{value}\r\n") }
    connection.write("Content-Length: #{body.bytesize}\r\n")
    connection.write("Connection: close\r\n") unless @keep_alive
    connection.write("\r\n")
    connection.write(body)
  end
end
