if Code.ensure_loaded?(Mix.Ecto) do
  defmodule Mix.Tasks.TraceGuard.Gen.EctoMigration do
    @shortdoc "Generates the migration for TraceGuard.Storage.Ecto"

    @moduledoc """
    Generates an Ecto migration, in **your** application, that creates the
    table used by `TraceGuard.Storage.Ecto` (experimental).

        mix trace_guard.gen.ecto_migration
        mix trace_guard.gen.ecto_migration --repo MyApp.Repo --prefix diagnostics
        mix ecto.migrate

    The generated file pins the schema version, so later TraceGuard releases
    never change what an already-run migration does. Apart from the
    timestamp in its file name, the output is the same on every run.

    The Repo and the directory are resolved as `mix ecto.gen.migration`
    resolves them: the Repo from `--repo` or your application's
    `:ecto_repos`, the directory from that Repo's `:priv` setting
    (default `priv/repo/migrations`), and the module is named
    `<Repo>.Migrations.AddTraceGuardReports`.

    ## Options

      * `--repo` / `-r`: the Repo whose database will hold the table. Needed
        when `:ecto_repos` lists more than one. It must use
        `Ecto.Adapters.Postgres`.
      * `--prefix`: a PostgreSQL schema for the table (it must already
        exist). Use the same `:prefix` in the adapter's configuration.
      * `--migrations-path`: write the file here instead of the Repo's
        migrations directory.
      * `--no-compile`: don't compile the project first.

    TraceGuard never runs migrations itself.
    """

    use Mix.Task

    @switches [repo: :keep, prefix: :string, migrations_path: :string, compile: :boolean]

    @impl Mix.Task
    def run(args) do
      {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])

      repo =
        case Mix.Ecto.parse_repo(args) do
          [repo] ->
            repo

          [] ->
            Mix.raise("No Ecto Repo found: pass --repo MyApp.Repo or set :ecto_repos")

          repos ->
            Mix.raise(
              "Several Ecto repos are configured (#{Enum.map_join(repos, ", ", &inspect/1)}); " <>
                "pass --repo with the one TraceGuard should store reports in"
            )
        end

      # Loads the configuration and compiles the project (unless
      # --no-compile), then checks that `repo` is an Ecto.Repo.
      Mix.Ecto.ensure_repo(repo, args)

      unless repo.__adapter__() == Ecto.Adapters.Postgres do
        Mix.raise(
          "TraceGuard.Storage.Ecto supports PostgreSQL repos only " <>
            "(#{inspect(repo)} uses #{inspect(repo.__adapter__())})"
        )
      end

      path = opts[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")

      if Path.wildcard(Path.join(path, "*_add_trace_guard_reports.exs")) != [] do
        Mix.raise("A TraceGuard migration already exists in #{Path.relative_to_cwd(path)}")
      end

      file = Path.join(path, "#{timestamp()}_add_trace_guard_reports.exs")
      Mix.Generator.create_file(file, migration(repo, opts[:prefix]))
      file
    end

    @doc false
    def migration(repo, prefix) do
      migration_opts =
        if prefix, do: "version: 1, prefix: #{inspect(prefix)}", else: "version: 1"

      """
      defmodule #{inspect(Module.concat([repo, Migrations, AddTraceGuardReports]))} do
        use Ecto.Migration

        # Creates the table used by TraceGuard.Storage.Ecto. The version is
        # pinned on purpose; see TraceGuard.Storage.Ecto.Migration.
        def up, do: TraceGuard.Storage.Ecto.Migration.up(#{migration_opts})
        def down, do: TraceGuard.Storage.Ecto.Migration.down(#{migration_opts})
      end
      """
    end

    # As `mix ecto.gen.migration` does: the Repo's :priv setting, relative to
    # the application that owns the Repo.
    defp source_repo_priv(repo) do
      config = repo.config()

      priv =
        config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"

      app = Keyword.fetch!(config, :otp_app)
      Path.join(Mix.Project.deps_paths()[app] || File.cwd!(), priv)
    end

    defp timestamp do
      {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

      :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [y, m, d, hh, mm, ss])
      |> IO.iodata_to_binary()
    end
  end
end
