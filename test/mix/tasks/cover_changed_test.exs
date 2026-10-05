defmodule Mix.Tasks.Cover.ChangedTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Cover.Changed

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("cover.changed")

    on_exit(fn ->
      Mix.shell(previous_shell)
      Application.delete_env(:symphony_elixir, :cover_changed_deps)
    end)

    :ok
  end

  defp fake_deps(overrides) do
    test_pid = self()

    deps = %{
      git: fn
        ["merge-base", "HEAD", base] ->
          send(test_pid, {:base, base})
          {:ok, "abc123\n"}

        ["diff" | _] ->
          {:ok, "lib/symphony_elixir/changed_coverage.ex\n"}

        ["ls-files" | _] ->
          {:ok, ""}
      end,
      run_tests: fn files ->
        send(test_pid, {:run_tests, files})
        :ok
      end,
      coverage: fn modules -> Map.new(modules, &{&1, {:ok, [{{&1, 1}, {1, 0}}]}}) end
    }

    Application.put_env(:symphony_elixir, :cover_changed_deps, Map.merge(deps, overrides))
  end

  test "checks the changed modules with the extra test files and the given base" do
    fake_deps(%{})

    assert :ok = Changed.run(["--base", "origin/dev", "test/extra_test.exs"])

    assert_received {:base, "origin/dev"}
    assert_received {:run_tests, ["test/extra_test.exs", "test/symphony_elixir/changed_coverage_test.exs" | _rest]}
    assert_received {:mix_shell, :info, ["cover.changed: running " <> _files]}
    assert_received {:mix_shell, :info, ["cover.changed: SymphonyElixir.ChangedCoverage 100.00% (lib/symphony_elixir/changed_coverage.ex)"]}
    assert_received {:mix_shell, :info, ["cover.changed: every changed module is at 100.00%"]}
  end

  test "skips the modules mix.exs ignores" do
    fake_deps(%{
      git: fn
        ["merge-base" | _] -> {:ok, "abc123\n"}
        ["diff" | _] -> {:ok, "lib/symphony_elixir/changed_coverage/runner.ex\n"}
        ["ls-files" | _] -> {:ok, ""}
      end
    })

    assert :ok = Changed.run([])

    assert_received {:mix_shell, :info, ["cover.changed: skipped SymphonyElixir.ChangedCoverage.Runner: in mix.exs test_coverage ignore_modules"]}
    assert_received {:mix_shell, :info, ["cover.changed: no changed lib/ module to check"]}
  end

  test "raises when a changed module is below 100%" do
    fake_deps(%{coverage: fn modules -> Map.new(modules, &{&1, {:ok, [{{&1, 4}, {0, 1}}]}}) end})

    assert_raise Mix.Error, ~r/cover.changed: 1 changed module\(s\) below 100% coverage: SymphonyElixir.ChangedCoverage/, fn ->
      Changed.run([])
    end
  end
end
