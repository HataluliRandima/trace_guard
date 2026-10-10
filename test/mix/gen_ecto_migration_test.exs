defmodule TraceGuard.GenMigrationTest.NotPostgresRepo do
  # Looks like an Ecto.Repo to Mix.Ecto, but isn't PostgreSQL.
  def __adapter__, do: Ecto.Adapters.SQLite3
end

defmodule Mix.Tasks.TraceGuard.Gen.EctoMigrationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.TraceGuard.Gen.EctoMigration
  alias TraceGuard.TestRepo

  @dir Path.join(System.tmp_dir!(), "trace_guard_gen_migration_test")

  setup do
    File.rm_rf!(@dir)
    File.mkdir_p!(@dir)
    repo_env = Application.get_env(:trace_guard, TestRepo)
    ecto_repos = Application.get_env(:trace_guard, :ecto_repos)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      restore(TestRepo, repo_env)
      restore(:ecto_repos, ecto_repos)
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(@dir)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:trace_guard, key)
  defp restore(key, value), do: Application.put_env(:trace_guard, key, value)

  # Runs the task with the project's working directory set to @dir, as if
  # @dir were the application's root.
  defp gen(args), do: File.cd!(@dir, fn -> EctoMigration.run(["--no-compile" | args]) end)

  defp generated(dir \\ @dir),
    do: Path.wildcard(Path.join(dir, "**/*_add_trace_guard_reports.exs"))

  test "writes a pinned migration for the given Repo into its migrations directory, once" do
    gen(["--repo", "TraceGuard.TestRepo"])

    # The Repo's default priv directory, as `mix ecto.gen.migration` uses.
    [file] = generated()

    assert Path.relative_to(file, @dir) =~
             ~r"^priv/test_repo/migrations/\d{14}_add_trace_guard_reports\.exs$"

    content = File.read!(file)
    assert content =~ "defmodule TraceGuard.TestRepo.Migrations.AddTraceGuardReports"
    assert content =~ "TraceGuard.Storage.Ecto.Migration.up(version: 1)"
    assert content =~ "TraceGuard.Storage.Ecto.Migration.down(version: 1)"

    # An ordinary, already formatted Ecto migration.
    assert IO.iodata_to_binary(Code.format_string!(content)) <> "\n" == content

    assert [{TraceGuard.TestRepo.Migrations.AddTraceGuardReports, _}] =
             Code.compile_string(content)

    assert_raise Mix.Error, ~r/already exists/, fn -> gen(["--repo", "TraceGuard.TestRepo"]) end
  end

  test "the output is deterministic apart from the timestamp" do
    gen(["-r", "TraceGuard.TestRepo"])
    [first] = generated()
    content = File.read!(first)
    File.rm!(first)
    gen(["-r", "TraceGuard.TestRepo"])
    [second] = generated()

    assert File.read!(second) == content
    assert content == EctoMigration.migration(TestRepo, nil)
  end

  test "uses the Repo from :ecto_repos and honours the Repo's :priv setting" do
    Application.put_env(:trace_guard, :ecto_repos, [TestRepo])

    Application.put_env(
      :trace_guard,
      TestRepo,
      Keyword.put(Application.get_env(:trace_guard, TestRepo, []), :priv, "priv/diagnostics")
    )

    gen([])
    assert [file] = generated()
    assert Path.relative_to(file, @dir) =~ ~r{^priv/diagnostics/migrations/}
  end

  test "an explicit --migrations-path wins" do
    out = Path.join(@dir, "elsewhere")
    gen(["--repo", "TraceGuard.TestRepo", "--migrations-path", out])
    assert [_] = generated(out)
  end

  test "refuses to guess: no Repo, several Repos, a non-Repo, a non-PostgreSQL Repo" do
    assert_raise Mix.Error, ~r/No Ecto Repo found/, fn -> gen([]) end

    Application.put_env(:trace_guard, :ecto_repos, [TestRepo, TraceGuard.TestRepoNeverStarted])
    assert_raise Mix.Error, ~r/Several Ecto repos.*pass --repo/, fn -> gen([]) end

    assert_raise Mix.Error, ~r/not an Ecto.Repo/, fn -> gen(["--repo", "TraceGuard.Config"]) end

    assert_raise Mix.Error, ~r/PostgreSQL repos only/, fn ->
      gen(["--repo", "TraceGuard.GenMigrationTest.NotPostgresRepo"])
    end

    assert generated() == []
  end

  test "passes a schema prefix through" do
    gen(["--repo", "TraceGuard.TestRepo", "--prefix", "diag"])

    [file] = generated()
    assert File.read!(file) =~ ~s{up(version: 1, prefix: "diag")}
    assert File.read!(file) =~ ~s{down(version: 1, prefix: "diag")}
  end
end
