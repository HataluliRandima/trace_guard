defmodule TraceGuard.TestRepo do
  @moduledoc false
  # Stands in for the host application's Repo in the PostgreSQL suite.
  use Ecto.Repo, otp_app: :trace_guard, adapter: Ecto.Adapters.Postgres
end

defmodule TraceGuard.TestRepoNeverStarted do
  @moduledoc false
  # A Repo that is configured but never started: "database not ready".
  use Ecto.Repo, otp_app: :trace_guard, adapter: Ecto.Adapters.Postgres
end

defmodule TraceGuard.TestMigrations.AddTraceGuardReports do
  @moduledoc false
  # What `mix trace_guard.gen.ecto_migration` generates.
  use Ecto.Migration
  def up, do: TraceGuard.Storage.Ecto.Migration.up(version: 1)
  def down, do: TraceGuard.Storage.Ecto.Migration.down(version: 1)
end

defmodule TraceGuard.TestMigrations.AddUnrelatedAppTable do
  @moduledoc false
  # Application data that TraceGuard must never touch.
  use Ecto.Migration

  def change do
    create table(:app_orders) do
      add :reference, :string
    end
  end
end

defmodule TraceGuard.PostgresSupport do
  @moduledoc false

  @db "trace_guard_test"

  def url do
    case System.get_env("TRACE_GUARD_POSTGRES_URL") do
      "" -> nil
      url -> url
    end
  end

  def repo_config(database \\ @db) do
    uri = URI.parse(url())

    {user, pass} =
      case String.split(uri.userinfo || "postgres", ":", parts: 2) do
        [user, pass] -> {user, pass}
        [user] -> {user, nil}
      end

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: database,
      pool_size: 10,
      show_sensitive_data_on_connection_error: false
    ]
  end

  @doc "Fresh database, TraceGuard table and an unrelated table; started repo."
  def setup! do
    config = repo_config()
    Application.put_env(:trace_guard, TraceGuard.TestRepo, config)
    Application.put_env(:trace_guard, TraceGuard.TestRepoNeverStarted, config)

    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, _} = TraceGuard.TestRepo.start_link()

    Ecto.Migrator.up(TraceGuard.TestRepo, 1, TraceGuard.TestMigrations.AddTraceGuardReports,
      log: false
    )

    Ecto.Migrator.up(TraceGuard.TestRepo, 2, TraceGuard.TestMigrations.AddUnrelatedAppTable,
      log: false
    )

    :ok
  end

  def teardown! do
    if pid = Process.whereis(TraceGuard.TestRepo), do: Supervisor.stop(pid)
    Ecto.Adapters.Postgres.storage_down(repo_config())
  end

  @doc "A connection to the `postgres` maintenance database, for admin actions."
  def admin! do
    {:ok, pid} = Postgrex.start_link(repo_config("postgres") |> Keyword.delete(:pool_size))
    pid
  end

  def database, do: @db

  def server_version do
    %{rows: [[version]]} = TraceGuard.TestRepo.query!("SELECT version()", [], log: false)
    version
  end
end
