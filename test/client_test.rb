# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: (c) 2026 Tim Bode, PGI-12, Forschungszentrum Jülich
# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zlib"

# The transport: what goes on the wire, and what comes back off it.
class ClientTest < Minitest::Test
  RESULT = {
    "job_id" => "job-1", "status" => "optimal", "objective" => 17.0, "feasible" => true,
    "solution" => { "x" => 4.0, "y" => 1.0 }, "solve_time_seconds" => 0.25,
    "solver_data" => { "model_class" => "MILP" }, "display" => "framed banner"
  }.freeze

  def setup
    @m = Quicopt::Model.new
    @x = @m.int_var(0, 4, "x")
    @m.maximize(3 * @x)
    @m.add(@x <= 3)
  end

  def json_ok(body = RESULT, headers = {})
    [200, { "Content-Type" => "application/json" }.merge(headers), JSON.generate(body)]
  end

  # ── query encoding ────────────────────────────────────────────────────────

  def test_spaces_escape_as_percent_20_never_plus
    # The service's query parser and the sibling clients agree on RFC 3986. Every
    # stock Ruby helper (URI.encode_www_form, CGI.escape,
    # URI.encode_www_form_component) emits "+" here and cannot be used.
    assert_equal "proj%20A%2F1", Quicopt::Client.escape("proj A/1")
    assert_equal "?project_id=proj%20A%2F1",
                 Quicopt::Client.query({ "project_id" => "proj A/1" })
  end

  def test_query_escapes_non_ascii_byte_wise
    assert_equal "J%C3%BClich", Quicopt::Client.escape("Jülich")
  end

  def test_empty_config_yields_no_query_string
    assert_equal "", Quicopt::Client.query(nil)
    assert_equal "", Quicopt::Client.query({})
  end

  # ── call attribution ──────────────────────────────────────────────────────

  def test_a_dsl_model_tags_the_call_with_its_front_end
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m)
      assert_equal "source_language=quicopt-ruby", server.requests.first.query
    end
  end

  def test_project_rides_the_query_string
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m, project: "proj A/1")
      assert_includes server.requests.first.query, "project_id=proj%20A%2F1"
    end
  end

  def test_a_caller_supplied_source_language_wins
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m, config: { "source_language" => "custom" })
      assert_equal "source_language=custom", server.requests.first.query
    end
  end

  def test_pre_encoded_bytes_have_no_front_end_to_attribute
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m.encode)
      assert_nil server.requests.first.query
    end
  end

  def test_a_hand_built_program_has_no_front_end_to_attribute
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m.to_program)
      assert_nil server.requests.first.query
    end
  end

  # ── the request body ──────────────────────────────────────────────────────

  def test_the_body_is_the_wire_bytes
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m)
      request = server.requests.first
      assert_equal "POST", request.method
      assert_equal "/v1/solve", request.path
      assert_equal "application/octet-stream", request.headers["content-type"]
      assert_equal @m.to_program, Quicopt.decode(request.body)
    end
  end

  def test_gzip_compresses_the_body_and_flags_the_encoding
    StubServer.run(->(_req) { json_ok }) do |server|
      Quicopt::Client.new(server.base_url).solve(@m, gzip: true)
      request = server.requests.first
      assert_equal "gzip", request.headers["content-encoding"]
      inflated = Zlib::GzipReader.new(StringIO.new(request.body)).read
      assert_equal @m.to_program, Quicopt.decode(inflated)
    end
  end

  def test_solving_something_that_is_not_a_model_raises
    assert_raises(TypeError) { Quicopt::Client.new("http://127.0.0.1:1").solve(42) }
  end

  # ── key minting ───────────────────────────────────────────────────────────

  def test_the_first_keyless_call_captures_the_minted_key
    StubServer.run(->(_req) { json_ok(RESULT, "X-Quicopt-Api-Key" => "minted-key") }) do |server|
      client = Quicopt::Client.new(server.base_url)
      assert_nil client.api_key

      client.solve(@m)
      assert_equal "minted-key", client.api_key

      client.solve(@m)
      assert_equal "Bearer minted-key", server.requests.last.headers["authorization"]
    end
  end

  def test_a_key_already_held_is_never_overwritten
    StubServer.run(->(_req) { json_ok(RESULT, "X-Quicopt-Api-Key" => "minted-key") }) do |server|
      client = Quicopt::Client.new(server.base_url, "mine")
      client.solve(@m)
      assert_equal "mine", client.api_key
      assert_equal "Bearer mine", server.requests.first.headers["authorization"]
    end
  end

  def test_a_key_minted_on_a_failing_call_is_still_captured
    # A 502/504 on a first call may still have minted a key.
    handler = lambda do |_req|
      [504, { "X-Quicopt-Api-Key" => "minted-key" }, JSON.generate({ "error" => "gateway timeout" })]
    end
    StubServer.run(handler) do |server|
      client = Quicopt::Client.new(server.base_url)
      assert_raises(Quicopt::QuicoptError) { client.solve(@m) }
      assert_equal "minted-key", client.api_key
    end
  end

  # ── results and errors ────────────────────────────────────────────────────

  def test_a_result_parses_every_field
    StubServer.run(->(_req) { json_ok }) do |server|
      result = Quicopt::Client.new(server.base_url).solve(@m)
      assert_equal "job-1", result.job_id
      assert_equal "optimal", result.status
      assert_in_delta 17.0, result.objective
      assert result.feasible
      assert_equal({ "x" => 4.0, "y" => 1.0 }, result.solution)
      assert_in_delta 0.25, result.solve_time_seconds
      assert_equal "MILP", result.model_class
      assert_equal "framed banner", result.display
    end
  end

  def test_absent_optional_fields_default_rather_than_raise
    StubServer.run(->(_req) { json_ok({ "status" => "heuristic" }) }) do |server|
      result = Quicopt::Client.new(server.base_url).solve(@m)
      assert_equal "heuristic", result.status
      assert_nil result.objective
      assert_nil result.feasible
      assert_nil result.model_class
      assert_empty result.solution
      assert_equal 0.0, result.solve_time_seconds
      assert_equal "", result.display
    end
  end

  def test_an_error_carries_the_status_reason_and_display
    body = { "error" => "model too large", "reason" => "size_exceeded",
             "display" => "framed error", "contact" => "olaf@quicopt.com" }
    StubServer.run(->(_req) { [400, {}, JSON.generate(body)] }) do |server|
      error = assert_raises(Quicopt::QuicoptError) { Quicopt::Client.new(server.base_url).solve(@m) }
      assert_equal 400, error.status_code
      assert_equal "size_exceeded", error.reason
      assert_equal "framed error", error.display
      assert_equal "model too large", error.message
      assert_equal "olaf@quicopt.com", error.body["contact"]
    end
  end

  def test_a_non_json_error_body_still_surfaces
    StubServer.run(->(_req) { [502, {}, "<html>bad gateway</html>"] }) do |server|
      error = assert_raises(Quicopt::QuicoptError) { Quicopt::Client.new(server.base_url).solve(@m) }
      assert_equal 502, error.status_code
      assert_nil error.reason
      assert_includes error.message, "bad gateway"
    end
  end

  def test_errors_are_rescuable_as_the_gem_wide_error
    StubServer.run(->(_req) { [500, {}, ""] }) do |server|
      assert_raises(Quicopt::Error) { Quicopt::Client.new(server.base_url).solve(@m) }
    end
  end

  # ── jobs ──────────────────────────────────────────────────────────────────

  def test_submit_returns_a_job_handle
    StubServer.run(->(_req) { json_ok({ "job_id" => "job-7" }) }) do |server|
      job = Quicopt::Client.new(server.base_url).submit(@m)
      assert_equal "job-7", job.job_id
      assert_equal "/v1/jobs", server.requests.first.path
    end
  end

  def test_result_polls_past_not_done
    attempts = 0
    handler = lambda do |req|
      next json_ok({ "job_id" => "job-7" }) if req.method == "POST"

      attempts += 1
      next [409, {}, JSON.generate({ "error" => "not done", "reason" => "not_done" })] if attempts < 3

      json_ok
    end
    StubServer.run(handler) do |server|
      job = Quicopt::Client.new(server.base_url).submit(@m)
      result = job.result(poll: 0.01)
      assert_equal "optimal", result.status
      assert_equal 3, attempts
    end
  end

  def test_result_without_wait_raises_immediately
    handler = lambda do |req|
      next json_ok({ "job_id" => "job-7" }) if req.method == "POST"

      [409, {}, JSON.generate({ "error" => "not done", "reason" => "not_done" })]
    end
    StubServer.run(handler) do |server|
      job = Quicopt::Client.new(server.base_url).submit(@m)
      error = assert_raises(Quicopt::QuicoptError) { job.result(wait: false) }
      assert_equal "not_done", error.reason
    end
  end

  def test_polling_gives_up_at_the_timeout
    handler = lambda do |req|
      next json_ok({ "job_id" => "job-7" }) if req.method == "POST"

      [409, {}, JSON.generate({ "error" => "not done", "reason" => "not_done" })]
    end
    StubServer.run(handler) do |server|
      job = Quicopt::Client.new(server.base_url).submit(@m)
      error = assert_raises(Quicopt::QuicoptError) { job.result(timeout: 0.05, poll: 0.01) }
      assert_equal "not_done", error.reason
    end
  end

  def test_status_log_and_delete_hit_their_endpoints
    StubServer.run(lambda { |req|
      next json_ok({ "job_id" => "job-7" }) if req.path == "/v1/jobs" && req.method == "POST"
      next [200, {}, "framed log"] if req.path.end_with?("/log")

      json_ok({ "status" => "running" })
    }) do |server|
      client = Quicopt::Client.new(server.base_url)
      job = client.submit(@m)
      assert_equal "running", job.status["status"]
      assert_equal "framed log", job.log
      assert_nil job.delete
      assert_equal %w[/v1/jobs /v1/jobs/job-7 /v1/jobs/job-7/log /v1/jobs/job-7],
                   server.requests.map(&:path)
      assert_equal "DELETE", server.requests.last.method
    end
  end

  # ── construction ──────────────────────────────────────────────────────────

  def test_the_default_base_url_is_the_public_free_tier
    assert_equal "https://try.quicoptapi.pgi.fz-juelich.de", Quicopt::DEFAULT_BASE_URL
    assert_equal Quicopt::DEFAULT_BASE_URL, Quicopt::Client.new.base_url
  end

  def test_a_trailing_slash_is_stripped
    assert_equal "http://example.test", Quicopt::Client.new("http://example.test/").base_url
  end
end
