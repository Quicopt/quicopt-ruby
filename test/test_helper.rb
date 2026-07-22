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
class StubServer
  Request = Struct.new(:method, :path, :query, :headers, :body)

  # @return [Array<Request>] every request received, in order
  attr_reader :requests

  def initialize(&handler)
    @handler = handler
    @requests = []
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
  def self.run(handler)
    server = new(&handler)
    yield server
  ensure
    server&.stop
  end

  private

  def serve
    loop do
      handle(@socket.accept)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(connection)
    request = read_request(connection)
    return if request.nil?

    @requests << request
    status, headers, body = @handler.call(request)
    write_response(connection, status, headers || {}, body.to_s)
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
    connection.write("Connection: close\r\n\r\n")
    connection.write(body)
  end
end
