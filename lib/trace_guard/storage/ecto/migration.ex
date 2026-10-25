if Code.ensure_loaded?(Ecto.Migration) do
  defmodule TraceGuard.Storage.Ecto.Migration do
    @moduledoc """
    **Experimental in 0.1.0-rc.2.** Creates and drops the table used by
    `TraceGuard.Storage.Ecto`, from **your application's own migration**.
    TraceGuard never runs migrations itself.

    Generate a migration with `mix trace_guard.gen.ecto_migration`, or write one:

        defmodule MyApp.Repo.Migrations.AddTraceGuardReports do
          use Ecto.Migration

          def up, do: TraceGuard.Storage.Ecto.Migration.up(version: 1)
          def down, do: TraceGuard.Storage.Ecto.Migration.down(version: 1)
        end

    then run `mix ecto.migrate` as usual.

    ## Options

      * `:version`: the schema version to migrate to (`up`) or from (`down`).
        Only `1` exists. Pin it in your migration so that a later TraceGuard
        release can't change what an already-run migration does.
      * `:prefix`: a PostgreSQL schema to create the table in (default: the
        Repo's default, usually `public`). Use the same `:prefix` in the
        adapter's configuration.

    ## Schema version 1

    Table `trace_guard_reports`:

    | Column | Type | Purpose |
    | --- | --- | --- |
    | `id` | `bigserial` (primary key) | insertion order (newest = highest) |
    | `trace_id` | `varchar(32)`, unique | lookup |
    | `outcome`, `method`, `kind` | `varchar` | filters |
    | `route`, `exception` | `text` | filters |
    | `status` | `integer` | filters |
    | `request_id` | `varchar`, indexed | filter (from `Plug.RequestId`) |
    | `incoming_id` | `varchar(128)`, indexed | filter (client correlation ID) |
    | `summary` | `jsonb` | `TraceGuard.Storage.summary/1` |
    | `report` | `jsonb` | the **redacted** report |
    | `inserted_at` | `timestamp`, indexed | age-based retention |

    Indexes: unique `trace_id`, `inserted_at`, `incoming_id`, `request_id`,
    and `(route, status)`.

    The filter columns duplicate fields of the redacted summary; nothing in
    the table comes from anywhere other than the redacted report.

    ## Rollback

    `down(version: 1)` drops the table and all stored reports. Before rolling
    back, switch TraceGuard to another storage adapter or deploy without the
    Ecto adapter. While the table is missing, writes are dropped with
    `{:ecto_error, :undefined_table}` and reads return `{:error, :unavailable}`.
    """

    use Ecto.Migration

    @table :trace_guard_reports
    @latest 1

    @doc "Creates TraceGuard's table (schema `:version`, default and latest: 1)."
    def up(opts \\ []) do
      version = Keyword.get(opts, :version, @latest)
      prefix = Keyword.get(opts, :prefix)
      if version >= 1, do: up_v1(prefix)
      :ok
    end

    @doc "Drops TraceGuard's table (and every stored report)."
    def down(opts \\ []) do
      version = Keyword.get(opts, :version, @latest)
      prefix = Keyword.get(opts, :prefix)
      if version >= 1, do: drop_if_exists(table(@table, prefix: prefix))
      :ok
    end

    defp up_v1(prefix) do
      create table(@table,
               prefix: prefix,
               comment: "TraceGuard diagnostic reports (redacted), schema v1"
             ) do
        add :trace_id, :string, size: 32, null: false
        add :outcome, :string
        add :method, :string
        add :route, :text
        add :status, :integer
        add :kind, :string
        add :exception, :text
        add :request_id, :string
        add :incoming_id, :string, size: 128
        add :summary, :map, null: false
        add :report, :map, null: false
        add :inserted_at, :naive_datetime_usec, null: false, default: fragment("now()")
      end

      create unique_index(@table, [:trace_id], prefix: prefix)
      create index(@table, [:inserted_at], prefix: prefix)
      create index(@table, [:incoming_id], prefix: prefix)
      create index(@table, [:request_id], prefix: prefix)
      create index(@table, [:route, :status], prefix: prefix)
    end
  end
end
