defmodule TraceGuard.RedactorTest do
  use ExUnit.Case, async: true

  alias TraceGuard.{Config, Redactor}

  doctest TraceGuard.Redactor

  @keys Config.default_redact_keys()
  @r "[REDACTED]"

  describe "normalize_key/1" do
    test "handles atoms, strings, header names, camelCase and upper case consistently" do
      for {input, expected} <- [
            {:api_key, "api_key"},
            {"API_KEY", "api_key"},
            {"Api-Key", "api_key"},
            {"apiKey", "api_key"},
            {"x-api-key", "x_api_key"},
            {:accessToken, "access_token"},
            {"Authorization", "authorization"},
            {"  password  ", "password"}
          ] do
        assert Redactor.normalize_key(input) == expected
      end
    end
  end

  describe "sensitive?/2" do
    test "matches whole token sequences, not substrings" do
      assert Redactor.sensitive?("x-api-key", @keys)
      assert Redactor.sensitive?(:user_password, @keys)
      assert Redactor.sensitive?("password_confirmation", @keys)
      assert Redactor.sensitive?("csrfToken", @keys)
      assert Redactor.sensitive?("REFRESH_TOKEN", @keys)
      assert Redactor.sensitive?("client_secret", @keys)

      refute Redactor.sensitive?("tokenizer", @keys)
      refute Redactor.sensitive?("passwords_page", @keys)
      refute Redactor.sensitive?("email", @keys)
      refute Redactor.sensitive?(42, @keys)
      refute Redactor.sensitive?({:a, :b}, @keys)
    end

    test "never creates atoms from string keys" do
      key = "brand_new_key_#{System.unique_integer([:positive])}"
      Redactor.sensitive?(key, @keys)
      Redactor.redact(%{key => "v"}, @keys)
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  describe "redact/2" do
    test "redacts nested maps and lists with atom and string keys" do
      input = %{
        "user" => %{
          :email => "a@example.com",
          "Password" => "hunter2",
          :profile => %{api_key: "k1", nested: [%{"refresh_token" => "rt"}, %{"ok" => 1}]}
        },
        :items => [[%{secret: "s"}], "plain"]
      }

      {output, count} = Redactor.redact(input, @keys)

      assert output == %{
               "user" => %{
                 :email => "a@example.com",
                 "Password" => @r,
                 :profile => %{api_key: @r, nested: [%{"refresh_token" => @r}, %{"ok" => 1}]}
               },
               :items => [[%{secret: @r}], "plain"]
             }

      assert count == 4
    end

    test "redacts header lists and keyword lists" do
      headers = [
        {"authorization", "Bearer abc"},
        {"X-Api-Key", "k"},
        {"content-type", "application/json"},
        {"cookie", "_session=1"}
      ]

      {output, 4} = Redactor.redact(%{"headers" => headers, opts: [token: "t", limit: 5]}, @keys)
      {_, 1} = Redactor.redact([token: "t", limit: 5], @keys)

      assert output["headers"] == [
               {"authorization", @r},
               {"X-Api-Key", @r},
               {"content-type", "application/json"},
               {"cookie", @r}
             ]

      assert output.opts == [token: @r, limit: 5]
    end

    test "redacts representative error metadata" do
      error = %{
        kind: :error,
        reason: %{"message" => "boom", "details" => %{"access_token" => "at", "attempt" => 2}},
        request: %{"params" => %{"card" => %{"number" => "4242", "password" => "x"}}}
      }

      {output, 2} = Redactor.redact(error, @keys)
      assert output.reason["details"]["access_token"] == @r
      assert output.request["params"]["card"]["password"] == @r
      assert output.request["params"]["card"]["number"] == "4242"
    end

    test "structs are traversed as plain maps so their fields cannot leak" do
      {output, 1} =
        Redactor.redact(%URI{userinfo: "u", host: "h", path: "/", query: nil}, ["userinfo"])

      assert output.userinfo == @r
      refute Map.has_key?(output, :__struct__)
    end

    test "custom keys are normalized" do
      keys = Config.validate!(redact_keys: ["Card-Number"]).redact_keys
      {%{"cardNumber" => @r}, 1} = Redactor.redact(%{"cardNumber" => "4242"}, keys)
    end

    test "leaves non-container values untouched" do
      assert Redactor.redact("password", @keys) == {"password", 0}
      assert Redactor.redact(nil, @keys) == {nil, 0}
      assert Redactor.redact({1, 2, 3}, @keys) == {{1, 2, 3}, 0}
    end
  end

  describe "scrub_string/2" do
    test "scrubs labelled values and bearer credentials" do
      message =
        ~s(request failed: api_key=fake_key_1 token: abc "password": "p w" ) <>
          ~s(Authorization: Bearer eyJhbGciOi.x-y_z api-key => 'q' user=bob)

      {scrubbed, count} = Redactor.scrub_string(message, @keys)

      for secret <- ["fake_key_1", "abc", "p w", "eyJhbGciOi", "'q'"] do
        refute scrubbed =~ secret, "#{secret} leaked in #{scrubbed}"
      end

      assert scrubbed =~ "user=bob"
      assert count >= 5
    end
  end
end
