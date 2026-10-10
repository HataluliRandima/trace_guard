defmodule Mix.Tasks.TraceGuard.Gen.EctoMigration do
  @shortdoc "Generates the migration for TraceGuard.Storage.Ecto"

  @moduledoc """
  Generates an Ecto migration, in **your** application, that creates the
  table used by `TraceGuard.Storage.Ecto` (experimental).

      mix trace_guard.gen.ecto_migration
      mix trace_guard.gen.ecto_migration --repo MyApp.Repo --prefix diagnostics
      mix ecto.migrate

  The generated file pins the schema version, so later TraceGuard releases
  never change what an already-run migration does.

  ## Options

    * `--repo`: the Repo module whose migrations module is used (default:
      `<App>.Repo`, from your project's `:app`).
    * `--prefix`: a PostgreSQL schema for the table (it must already exist).
      Use the same `:prefix` in the adapter's configuration.
    * `--migrations-path`: where to write the file (default:
      `priv/repo/migrations`).

  TraceGuard never runs migrations itself.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [repo: :string, prefix: :string, migrations_path: :string]
      )

    repo = opts[:repo] || default_repo()
    path = opts[:migrations_path] || Path.join(["priv", "repo", "migrations"])

    if Path.wildcard(Path.join(path, "*_add_trace_guard_reports.exs")) != [] do
      Mix.raise("A TraceGuard migration already exists in #{path}")
    end

    file = Path.join(path, "#{timestamp()}_add_trace_guard_reports.exs")

    migration_opts =
      if opts[:prefix], do: "version: 1, prefix: #{inspect(opts[:prefix])}", else: "version: 1"

    Mix.Generator.create_file(file, """
    defmodule #{repo}.Migrations.AddTraceGuardReports do
      use Ecto.Migration

      # Creates the table used by TraceGuard.Storage.Ecto. The version is
      # pinned on purpose; see TraceGuard.Storage.Ecto.Migration.
      def up, do: TraceGuard.Storage.Ecto.Migration.up(#{migration_opts})
      def down, do: TraceGuard.Storage.Ecto.Migration.down(#{migration_opts})
    end
    """)
  end

  defp default_repo do
    case Mix.Project.config()[:app] do
      nil -> Mix.raise("Could not infer the Repo; pass --repo MyApp.Repo")
      app -> Macro.camelize(Atom.to_string(app)) <> ".Repo"
    end
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss])
    |> IO.iodata_to_binary()
  end
end
