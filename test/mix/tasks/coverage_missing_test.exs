defmodule Mix.Tasks.Coverage.MissingTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Coverage.Missing

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("coverage.missing")
    Mix.Task.reenable("compile")
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "counts no modules with uncovered lines in a directory without coverage data", %{tmp_dir: dir} do
    Missing.run([dir])
    assert_received {:mix_shell, :info, ["coverage.missing: 0 module(s) with uncovered lines"]}
  end
end
