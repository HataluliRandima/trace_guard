defmodule TraceGuard.ConfigTest do
  use ExUnit.Case, async: true

  alias TraceGuard.Config

  test "defaults are conservative" do
    config = Config.validate!([])

    assert config.capture_path == false
    assert config.capture_path_params == false
    assert config.capture_sql == false
    assert config.capture_request_headers == ["accept", "content-type"]
    assert config.incoming_header == nil
    assert config.failure_status == 500
    assert config.max_events == 100
    assert config.max_reports == 50
    assert config.redact_keys == Config.default_redact_keys()
  end

  test "custom redact keys extend, and never replace, the defaults" do
    config = Config.validate!(redact_keys: [:ssn, "Card-Number"])
    assert "password" in config.redact_keys
    assert "ssn" in config.redact_keys
    assert "card_number" in config.redact_keys
  end

  test "rejects invalid and unknown options" do
    for opts <- [
          [max_events: 0],
          [failure_status: 700],
          [redact_keys: "password"],
          [response_header: "bad header"],
          [ecto_telemetry_prefixes: [:my_app]],
          [capture_sql: "yes"],
          [max_event: 10]
        ] do
      assert_raise ArgumentError, fn -> Config.validate!(opts) end
    end
  end
end
