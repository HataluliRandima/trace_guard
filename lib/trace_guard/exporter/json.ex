defmodule TraceGuard.Exporter.JSON do
  @moduledoc """
  Encodes diagnostic reports as JSON using `Jason`.

  Reports produced by `TraceGuard.TraceBuilder` contain only strings,
  numbers, booleans, nil, lists and string-keyed maps, and are redacted
  before they reach the exporter. Encoding therefore never needs custom
  `Jason.Encoder` implementations.
  """

  @doc """
  Encodes a report.

  ## Options

    * `:pretty` - pretty-print the output (default `false`)
  """
  @spec encode(map(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(report, opts \\ []) when is_map(report) do
    Jason.encode(report, pretty: Keyword.get(opts, :pretty, false))
  end

  @doc "Encodes a report and writes it to `path`."
  @spec write(map(), Path.t(), keyword()) :: :ok | {:error, term()}
  def write(report, path, opts \\ []) do
    with {:ok, json} <- encode(report, Keyword.put_new(opts, :pretty, true)) do
      File.write(path, json <> "\n")
    end
  end
end
