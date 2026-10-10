defmodule TraceGuard.Redactor do
  @moduledoc """
  **Internal module.** Not part of TraceGuard's public API: it may change in
  any release. Use the functions in `TraceGuard` instead.

  Recursive, key-based redaction of diagnostic data.

  ## Key matching

  Keys are compared in a *normalized* form so that atom keys, string keys,
  header names and common casing styles behave the same:

      :api_key, "API_KEY", "x-api-key", "apiKey", "X-Api-Key"
      #=> "api_key", "api_key", "x_api_key", "api_key", "x_api_key"

  A key is sensitive when the token sequence of a configured sensitive key
  appears contiguously in the token sequence of the normalized key. With
  `"api_key"` configured, `"x_api_key"` and `"api_key_id"` match, but
  `"apikeys"` does not. With `"token"` configured, `"csrf_token"` matches but
  `"tokenizer"` does not. This deliberately errs towards over-redaction.

  Keys are only ever converted from atoms to strings; external strings are
  never converted to atoms.

  ## Structures

  Maps, lists, and two-element `{key, value}` tuples (keyword lists, Plug
  header lists) are traversed. Structs are converted to plain maps before
  traversal so that a struct field such as `:password` cannot slip through.
  """

  @redacted "[REDACTED]"

  @doc "The placeholder that replaces sensitive values."
  @spec placeholder() :: String.t()
  def placeholder, do: @redacted

  @doc """
  Normalizes a key to lower snake case.

      iex> TraceGuard.Redactor.normalize_key("X-Api-Key")
      "x_api_key"
      iex> TraceGuard.Redactor.normalize_key(:refreshToken)
      "refresh_token"
      iex> TraceGuard.Redactor.normalize_key("AUTHORIZATION")
      "authorization"
  """
  @spec normalize_key(atom() | String.t()) :: String.t()
  def normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  def normalize_key(key) when is_binary(key) do
    key
    |> then(&Regex.replace(~r/([a-z0-9])([A-Z])/, &1, "\\1_\\2"))
    |> String.downcase()
    |> then(&Regex.replace(~r/[^a-z0-9]+/, &1, "_"))
    |> String.trim("_")
  end

  @doc """
  Returns true if `key` matches one of the normalized `sensitive_keys`.

  Keys that are neither atoms nor strings are never sensitive.
  """
  @spec sensitive?(term(), [String.t()]) :: boolean()
  def sensitive?(key, sensitive_keys), do: matches?(key, needles(sensitive_keys))

  # Each sensitive key is split into tokens once per call, not once per key
  # compared (profiling showed the repeated splitting dominating report builds).
  defp needles(sensitive_keys), do: Enum.map(sensitive_keys, &String.split(&1, "_", trim: true))

  defp matches?(key, needles) when is_atom(key) or is_binary(key) do
    tokens = key |> normalize_key() |> String.split("_", trim: true)
    Enum.any?(needles, &contains_tokens?(tokens, &1))
  end

  defp matches?(_key, _needles), do: false

  defp contains_tokens?(_tokens, []), do: false
  defp contains_tokens?(tokens, needle) when length(tokens) < length(needle), do: false

  defp contains_tokens?([_ | rest] = tokens, needle) do
    List.starts_with?(tokens, needle) or contains_tokens?(rest, needle)
  end

  @doc """
  Recursively replaces the values of sensitive keys with `"[REDACTED]"`.

  Returns `{redacted_term, number_of_redacted_values}`.
  """
  @spec redact(term(), [String.t()]) :: {term(), non_neg_integer()}
  def redact(term, sensitive_keys) do
    # The accumulator memoizes the verdict per distinct key: reports repeat
    # the same keys (event and stack-frame fields) many times.
    {term, {count, _memo}} = do_redact(term, needles(sensitive_keys), {0, %{}})
    {term, count}
  end

  defp do_redact(%_{} = struct, needles, acc),
    do: struct |> Map.from_struct() |> do_redact(needles, acc)

  defp do_redact(map, needles, acc) when is_map(map) do
    {pairs, acc} =
      Enum.map_reduce(map, acc, fn {key, value}, acc ->
        redact_pair(key, value, needles, acc)
      end)

    {Map.new(pairs), acc}
  end

  defp do_redact(list, needles, acc) when is_list(list) do
    redact_list(list, needles, acc, [])
  end

  defp do_redact({key, value}, needles, acc) when is_atom(key) or is_binary(key) do
    redact_pair(key, value, needles, acc)
  end

  defp do_redact(other, _needles, acc), do: {other, acc}

  # Handles proper and improper lists without assuming they are proper.
  defp redact_list([head | tail], needles, acc, out) do
    {head, acc} = do_redact(head, needles, acc)
    redact_list(tail, needles, acc, [head | out])
  end

  defp redact_list([], _needles, acc, out), do: {Enum.reverse(out), acc}

  defp redact_list(improper_tail, needles, acc, out) do
    {tail, acc} = do_redact(improper_tail, needles, acc)
    {Enum.reverse(out) ++ tail, acc}
  end

  defp redact_pair(key, value, needles, {count, memo}) do
    {sensitive?, memo} =
      case memo do
        %{^key => verdict} ->
          {verdict, memo}

        _ ->
          verdict = matches?(key, needles)

          {verdict,
           if(is_atom(key) or is_binary(key), do: Map.put(memo, key, verdict), else: memo)}
      end

    if sensitive? do
      {{key, @redacted}, {count + 1, memo}}
    else
      {value, acc} = do_redact(value, needles, {count, memo})
      {{key, value}, acc}
    end
  end

  @doc """
  Scrubs sensitive values embedded in free text, such as exception messages.

  Two patterns are handled:

    * `key=value`, `key: value`, `"key": "value"` and `key => value`, where the
      key contains a configured sensitive key (`_` in a configured key also
      matches `-` or nothing, so `api_key` covers `api-key` and `apikey`).
    * `Bearer <credential>` and `Basic <credential>`.

  This is a best-effort safety net. It cannot recognize secrets that are not
  labelled, so exception messages remain the riskiest captured field.

  Returns `{scrubbed_string, number_of_replacements}`.
  """
  @spec scrub_string(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def scrub_string(string, sensitive_keys) when is_binary(string) do
    patterns = [
      {~r/\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+\/]+=*/i, "\\1 #{@redacted}"},
      {key_value_regex(sensitive_keys), "\\1\\2#{@redacted}"}
    ]

    Enum.reduce(patterns, {string, 0}, fn
      {nil, _replacement}, acc ->
        acc

      {regex, replacement}, {acc_string, acc_count} ->
        matches = regex |> Regex.scan(acc_string) |> length()
        {Regex.replace(regex, acc_string, replacement), acc_count + matches}
    end)
  end

  defp key_value_regex([]), do: nil

  # Compiled once per distinct key list and cached; the key list only changes
  # with configuration, so the number of cached entries stays tiny.
  defp key_value_regex(sensitive_keys) do
    cache_key = {__MODULE__, :key_value_regex, sensitive_keys}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        regex = compile_key_value_regex(sensitive_keys)
        :persistent_term.put(cache_key, regex)
        regex

      regex ->
        regex
    end
  end

  defp compile_key_value_regex(sensitive_keys) do
    alternatives =
      sensitive_keys
      |> Enum.map(fn key ->
        key |> String.split("_", trim: true) |> Enum.map_join("[_\\-]?", &Regex.escape/1)
      end)
      |> Enum.join("|")

    Regex.compile!(
      "([A-Za-z0-9_\\-]*(?:#{alternatives})[A-Za-z0-9_\\-]*[\"']?)" <>
        "(\\s*(?:=>|:|=)\\s*)" <>
        "(\"[^\"]*\"|'[^']*'|[^\\s,;&)}\\]]+)",
      "i"
    )
  end
end
