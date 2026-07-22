# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require "json"
require "net/http"
require "stringio"
require "uri"
require "zlib"

# quicopt/client — talk to the Quicopt service over HTTP.
#
# Encode a model to wire bytes (+Quicopt::Wire+), POST it, read the result back.
# Transport is stdlib +net/http+, so the gem's only runtime dependency stays
# +google-protobuf+. The request body is the versioned wire bytes; the response is
# the service's result JSON (+status+ / +objective+ / +solution+ / a
# ready-to-print +display+ / …). The first keyless call mints an API key, returned
# in the +X-Quicopt-Api-Key+ response header and remembered on the +Client+ so
# later calls replay it as +Authorization: Bearer+.
#
# Two entry points mirror the two service endpoints:
#
# - +Client#solve+ — POST +/v1/solve+, block for the result (synchronous).
# - +Client#submit+ — POST +/v1/jobs+, return a +Job+ to poll.
#
# A non-2xx response raises +QuicoptError+, carrying the service's stable +reason+
# code and the framed +display+ text.
module Quicopt
  # The public Quicopt free-tier endpoint a +Client+ targets when no +base_url+
  # is given. Mirrors the Python and Julia clients' default, so every client
  # reaches the same server out of the box.
  DEFAULT_BASE_URL = "https://try.quicoptapi.pgi.fz-juelich.de"

  # The modelling front-end this client authors with, sent as the
  # +source_language+ call tag. It names the *front-end*, not the language — the
  # Ruby DSL is one front-end among the clients' several (+jump+, +pyomo+,
  # +pulp+, +mathopt+), so it carries its own name here.
  SOURCE_LANGUAGE = "quicopt-ruby"

  # A finished solve, parsed from the service's result JSON.
  #
  # +objective+ and +feasible+ are +nil+ when the class or outcome leaves them
  # undefined (an unconstrained heuristic, or no incumbent). +display+ is the
  # framed, ready-to-print summary the service renders for every backend alike —
  # print it rather than formatting your own.
  Result = Data.define(:job_id, :status, :objective, :feasible, :solution,
                       :solve_time_seconds, :solver_data, :display) do
    # Build a +Result+ from the service's decoded result JSON.
    #
    # Missing optional keys default rather than raise, so a partial result (e.g.
    # a heuristic backend that reports no objective) still parses.
    #
    # @param body [Hash] the decoded result JSON object
    # @return [Result]
    def self.from_json(body)
      new(job_id: body["job_id"].to_s,
          status: body["status"].to_s,
          objective: body["objective"],
          feasible: body["feasible"],
          solution: body["solution"] || {},
          solve_time_seconds: body["solve_time_seconds"] || 0.0,
          solver_data: body["solver_data"] || {},
          display: body["display"].to_s)
    end

    # The class the service routed the model to (+LP+/+MILP+/+QUBO+/…), or +nil+
    # if it did not report one.
    #
    # @return [String, nil]
    def model_class
      solver_data["model_class"]
    end
  end

  # A non-2xx service response.
  #
  # +reason+ is the service's stable snake_case code (+size_exceeded+,
  # +unsupported_model+, +quota_exhausted+, +not_done+, +too_many_inflight+,
  # +queue_full+, +parse_error+, …) — match on it, not on the message. +display+
  # is the framed text to print; +status_code+ the HTTP status.
  class QuicoptError < Error
    # @return [Integer] the HTTP status code
    attr_reader :status_code
    # @return [Hash] the decoded error body
    attr_reader :body
    # @return [String, nil] the stable machine-readable reason code
    attr_reader :reason
    # @return [String, nil] the server-rendered, ready-to-print message
    attr_reader :display

    def initialize(status_code, body)
      @status_code = status_code
      @body = body.is_a?(Hash) ? body : { "error" => body.to_s }
      @reason = @body["reason"]
      @display = @body["display"]
      super(@body["error"] || "HTTP #{status_code}")
    end
  end

  # A connection to a Quicopt service at +base_url+ — the public free tier
  # (+DEFAULT_BASE_URL+) unless another URL is given.
  #
  # The client holds the API key: pass a known one, or let the first keyless call
  # mint one and read it back from +api_key+ to persist it yourself.
  #
  #   client = Quicopt::Client.new
  #   result = client.solve(model)
  #   puts result.display
  #   client.api_key   # => the key the first call minted
  class Client
    # The HTTP methods this client issues, and the request class for each.
    REQUESTS = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "DELETE" => Net::HTTP::Delete
    }.freeze

    OCTET_STREAM = "application/octet-stream"

    # @return [String] the service base URL, without a trailing slash
    attr_reader :base_url
    # @return [String, nil] the API key in use; set on the first mint
    attr_accessor :api_key
    # @return [Float] the per-request socket timeout, in seconds
    attr_accessor :timeout

    # Bind a client to a service endpoint.
    #
    # @param base_url [String] the service base URL; a trailing slash is stripped
    # @param api_key [String, nil] a known API key, or +nil+ to let the first
    #   keyless call mint one
    # @param timeout [Numeric] the per-request socket timeout, in seconds
    def initialize(base_url = DEFAULT_BASE_URL, api_key = nil, timeout: 60.0)
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @api_key = api_key
      @timeout = timeout
    end

    # Solve +model+ synchronously, blocking until the result returns.
    #
    # @param model [Quicopt::Model, Quicopt::Wire::PB::Program, String] a model —
    #   lowered and encoded here — or a +Program+ / pre-encoded wire bytes if you
    #   built them yourself
    # @param project [String, nil] an optional project tag, so calls on one key
    #   can be invoiced per project. Sent as a query param, never baked into the
    #   model.
    # @param config [Hash, nil] optional service parameters, sent as the query
    #   string
    # @param gzip [Boolean] gzip-compress the request body
    # @return [Result]
    # @raise [QuicoptError] on a non-2xx response
    def solve(model, project: nil, config: nil, gzip: false)
      Result.from_json(request("POST", "/v1/solve", to_wire(model),
                               config: meta_config(model, project, config), gzip: gzip))
    end

    # Submit +model+ for asynchronous solving and return a handle to poll.
    #
    # Use this for the first call against a freshly-booted server: the worker
    # warms up before claiming, which can time out a cold synchronous call.
    #
    # @return [Job] a handle to the queued job; call +Job#result+ to await it
    # @raise [QuicoptError] on a non-2xx response
    def submit(model, project: nil, config: nil, gzip: false)
      body = request("POST", "/v1/jobs", to_wire(model),
                     config: meta_config(model, project, config), gzip: gzip)
      Job.new(self, body["job_id"])
    end

    # Perform one HTTP request and return the raw response body.
    #
    # Sets the octet-stream content type (and gzip encoding, if requested) for a
    # body, attaches the bearer key when known, and captures a freshly minted key
    # off the response — including from an error response, since a 502/504 on a
    # first call may still have minted one.
    #
    # @return [String] the raw response body
    # @raise [QuicoptError] on a non-2xx response
    # @api private
    def request_raw(method, path, data = nil, config: nil, gzip: false)
      uri = URI.parse(@base_url + path + Client.query(config))
      request_class = REQUESTS.fetch(method) { raise ArgumentError, "unsupported method #{method}" }
      req = request_class.new(uri)
      if data
        req["Content-Type"] = OCTET_STREAM
        if gzip
          data = Client.gzip(data)
          req["Content-Encoding"] = "gzip"
        end
        req.body = data
      end
      req["Authorization"] = "Bearer #{@api_key}" if @api_key

      resp = http(uri).start { |conn| conn.request(req) }
      capture_key(resp) # a 502/504 on a first call still minted a key
      raise QuicoptError.new(resp.code.to_i, Client.decode(resp.body)) unless resp.is_a?(Net::HTTPSuccess)

      resp.body.to_s
    end

    # Perform a request via +request_raw+ and parse its JSON body.
    #
    # @return [Hash] the parsed JSON object, or +{}+ for an empty body
    # @raise [QuicoptError] on a non-2xx response
    # @api private
    def request(method, path, data = nil, **options)
      raw = request_raw(method, path, data, **options)
      raw.empty? ? {} : JSON.parse(raw)
    end

    # Render a config mapping as a URL query-string suffix.
    #
    # Escapes per RFC 3986, so a space becomes +%20+ and never +'+'+ — the form
    # the service's query parser round-trips unambiguously, and the form the
    # other clients send. Ruby's stock helpers (+URI.encode_www_form+,
    # +CGI.escape+, +URI.encode_www_form_component+) all emit +'+'+ here, so none
    # of them can be used.
    #
    # @param config [Hash, nil]
    # @return [String] +"?k=v&…"+ if +config+ is non-empty, else +""+
    # @api private
    def self.query(config)
      return "" if config.nil? || config.empty?

      "?" + config.map { |k, v| "#{escape(k)}=#{escape(v)}" }.join("&")
    end

    # Percent-encode one query component per RFC 3986 (unreserved characters
    # pass through; everything else is escaped byte-wise, UTF-8 included).
    #
    # @api private
    def self.escape(value)
      value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |c| format("%%%02X", c.ord) }
    end

    # Gzip-compress a request body.
    #
    # @api private
    def self.gzip(data)
      io = StringIO.new(+"".b)
      writer = Zlib::GzipWriter.new(io)
      begin
        writer.write(data)
      ensure
        writer.close
      end
      io.string
    end

    # Best-effort decode of a response body into a Hash.
    #
    # @return [Hash] the parsed JSON if it parses (or +{}+ when empty), else the
    #   body wrapped as +{"error" => text}+ so a non-JSON error still surfaces
    # @api private
    def self.decode(raw)
      text = raw.to_s
      return {} if text.empty?

      parsed = JSON.parse(text)
      parsed.is_a?(Hash) ? parsed : { "error" => text }
    rescue JSON::ParserError
      { "error" => text }
    end

    private

    def http(uri)
      conn = Net::HTTP.new(uri.host, uri.port)
      conn.use_ssl = uri.scheme == "https"
      conn.open_timeout = @timeout
      conn.read_timeout = @timeout
      conn.write_timeout = @timeout
      conn
    end

    # Coerce to wire bytes: pre-encoded bytes pass through, a +Program+ is
    # encoded, and a +Model+ is lowered then encoded — so a caller solves the
    # *model*, never a hand-built +Program+.
    def to_wire(model)
      case model
      when Model, Wire::PB::Program then Wire.encode(model)
      when String then model
      else
        raise TypeError, "cannot solve a #{model.class}: pass a Quicopt::Model, a Program, or wire bytes"
      end
    end

    # The modelling front-end that authored +model+, or +nil+ for a hand-built
    # +Program+ / pre-encoded bytes, which have no front-end to attribute.
    def source_language(model)
      SOURCE_LANGUAGE if model.is_a?(Model)
    end

    # Merge the per-call metadata tags into the request config (sent as query
    # params): the front-end tag, unless the caller already set one, and the
    # optional project id. The model is unchanged — these ride the query string,
    # not the wire bytes.
    def meta_config(model, project, config)
      meta = {}
      (config || {}).each { |k, v| meta[k.to_s] = v }
      src = source_language(model)
      meta["source_language"] = src if src && !meta.key?("source_language")
      meta["project_id"] = project if project
      meta
    end

    # Remember a freshly minted API key from a response, if we have none yet. A
    # key we already hold is never overwritten.
    def capture_key(resp)
      minted = resp["X-Quicopt-Api-Key"]
      @api_key = minted if minted && !minted.empty? && (@api_key.nil? || @api_key.empty?)
    end
  end

  # A handle to an asynchronous job. +result+ polls until it finishes.
  class Job
    # @return [Client] the client that submitted the job
    attr_reader :client
    # @return [String] the server-assigned job id
    attr_reader :job_id

    def initialize(client, job_id)
      @client = client
      @job_id = job_id
    end

    # Fetch the job's metadata and framed log tail.
    #
    # @return [Hash] the job state (+queued+/+running+/+done+/+failed+) and its
    #   log tail, as returned by the service
    def status
      @client.request("GET", "/v1/jobs/#{@job_id}")
    end

    # Fetch the job's result, optionally polling until it is ready.
    #
    # @param wait [Boolean] poll past the service's +not_done+ reason until the
    #   worker finishes; when +false+, fetch once
    # @param timeout [Numeric] maximum time to poll, in seconds
    # @param poll [Numeric] delay between polls, in seconds
    # @return [Result]
    # @raise [QuicoptError] if +wait+ is false and the job is not yet done, on any
    #   non-+not_done+ error, or once +timeout+ elapses
    def result(wait: true, timeout: 120.0, poll: 0.5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return Result.from_json(@client.request("GET", "/v1/jobs/#{@job_id}/result"))
      rescue QuicoptError => e
        raise if !wait || e.reason != "not_done"
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep(poll)
      end
    end

    # Fetch the job's log — the same framed view as +display+, not a raw solver
    # log.
    #
    # @return [String]
    def log
      @client.request_raw("GET", "/v1/jobs/#{@job_id}/log")
    end

    # Delete the job and its stored blob, result and log on the server.
    #
    # @return [nil]
    def delete
      @client.request_raw("DELETE", "/v1/jobs/#{@job_id}")
      nil
    end

    def inspect
      "#<Quicopt::Job #{@job_id}>"
    end
  end
end
