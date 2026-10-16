defmodule Mix.Tasks.PrDecision.TableTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PrDecision.Table, as: TableTask
  alias SymphonyElixir.PrDecision.Table

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("pr_decision.table")
    root = Path.join(System.tmp_dir!(), "pr-decision-table-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{path: Path.join([root, "docs", "pr-ci-decisions.md"])}
  end

  test "prints help, and rejects invalid options" do
    assert capture_io(fn -> TableTask.run(["--help"]) end) =~ "mix pr_decision.table [--check] [--path PATH]"
    assert_raise Mix.Error, ~r/Invalid option/, fn -> TableTask.run(["--wat"]) end
  end

  test "writes the table, then rewriting it changes nothing", %{path: path} do
    assert capture_io(fn -> TableTask.run(["--path", path]) end) =~ "Wrote #{path}"
    assert File.read!(path) == Table.render()

    assert capture_io(fn -> TableTask.run(["--path", path]) end) =~ "Wrote"
    assert File.read!(path) == Table.render()
  end

  test "--check passes on an up-to-date file and fails on a stale or missing one", %{path: path} do
    assert_raise Mix.Error, ~r/out of date: run mix pr_decision.table/, fn -> TableTask.run(["--check", "--path", path]) end

    capture_io(fn -> TableTask.run(["--path", path]) end)
    assert capture_io(fn -> TableTask.run(["--check", "--path", path]) end) =~ "is up to date"

    File.write!(path, String.replace(File.read!(path), "| R29 |", "| R99 |"))
    assert_raise Mix.Error, ~r/out of date/, fn -> TableTask.run(["--check", "--path", path]) end
  end

  test "the repository's table is up to date" do
    assert capture_io(fn -> TableTask.run(["--check"]) end) =~ "docs/pr-ci-decisions.md is up to date"
  end
end
