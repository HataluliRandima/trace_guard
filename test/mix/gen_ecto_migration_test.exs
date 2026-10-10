defmodule Mix.Tasks.TraceGuard.Gen.EctoMigrationTest do
  use ExUnit.Case, async: false

  @dir Path.join(System.tmp_dir!(), "trace_guard_gen_migration_test")

  setup do
    File.rm_rf!(@dir)
    on_exit(fn -> File.rm_rf!(@dir) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "writes a pinned migration into the application's migrations path, once" do
    Mix.Tasks.TraceGuard.Gen.EctoMigration.run(["--repo", "MyApp.Repo", "--migrations-path", @dir])

    [file] = Path.wildcard(Path.join(@dir, "*_add_trace_guard_reports.exs"))
    assert Path.basename(file) =~ ~r/^\d{14}_add_trace_guard_reports\.exs$/
    content = File.read!(file)
    assert content =~ "defmodule MyApp.Repo.Migrations.AddTraceGuardReports"
    assert content =~ "TraceGuard.Storage.Ecto.Migration.up(version: 1)"
    assert content =~ "TraceGuard.Storage.Ecto.Migration.down(version: 1)"
    # It compiles as an ordinary Ecto migration.
    assert [{MyApp.Repo.Migrations.AddTraceGuardReports, _}] = Code.compile_string(content)

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Tasks.TraceGuard.Gen.EctoMigration.run([
        "--repo",
        "MyApp.Repo",
        "--migrations-path",
        @dir
      ])
    end
  end

  test "passes a schema prefix through" do
    Mix.Tasks.TraceGuard.Gen.EctoMigration.run([
      "--repo",
      "Other.Repo",
      "--prefix",
      "diag",
      "--migrations-path",
      @dir
    ])

    [file] = Path.wildcard(Path.join(@dir, "*.exs"))
    assert File.read!(file) =~ ~s{up(version: 1, prefix: "diag")}
  end
end
