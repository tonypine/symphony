defmodule SymphonyElixir.ChangedCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ChangedCoverage

  @tests %{
    "test/symphony_elixir/foo_test.exs" => "defmodule FooTest do\nend\n",
    "test/symphony_elixir/bar_test.exs" => "alias SymphonyElixir.Bar\n",
    "test/symphony_elixir/other_test.exs" => "alias SymphonyElixir.Other\n"
  }

  defp deps(overrides \\ %{}) do
    test_pid = self()

    %{
      git: fn
        ["merge-base", "HEAD", "origin/main"] -> {:ok, "abc123\n"}
        ["diff", "--name-only", "--diff-filter=ACMR", "abc123"] -> {:ok, "lib/symphony_elixir/foo.ex\nlib/symphony_elixir/bar.ex\nREADME.md\n"}
        ["ls-files", "--others", "--exclude-standard"] -> {:ok, ""}
      end,
      modules: fn ->
        [
          {SymphonyElixir.Foo, Path.expand("lib/symphony_elixir/foo.ex")},
          {SymphonyElixir.Foo.Helper, Path.expand("lib/symphony_elixir/foo.ex")},
          {SymphonyElixir.Bar, Path.expand("lib/symphony_elixir/bar.ex")},
          {SymphonyElixir.Other, Path.expand("lib/symphony_elixir/other.ex")}
        ]
      end,
      test_files: fn -> Map.keys(@tests) end,
      read_file: &Map.fetch!(@tests, &1),
      run_tests: fn files ->
        send(test_pid, {:run_tests, files})
        :ok
      end,
      coverage: fn modules ->
        send(test_pid, {:coverage, modules})
        Map.new(modules, &{&1, {:ok, [{{&1, 0}, {0, 1}}, {{&1, 3}, {1, 0}}]}})
      end,
      info: &send(test_pid, {:info, &1})
    }
    |> Map.merge(overrides)
  end

  defp infos do
    receive do
      {:info, line} -> [line | infos()]
    after
      0 -> []
    end
  end

  test "runs the tests for the changed modules and passes when each is fully covered" do
    assert :ok = ChangedCoverage.run([], deps())

    assert_received {:run_tests, ["test/symphony_elixir/bar_test.exs", "test/symphony_elixir/foo_test.exs"]}
    assert_received {:coverage, [SymphonyElixir.Bar, SymphonyElixir.Foo, SymphonyElixir.Foo.Helper]}

    assert [running | rest] = infos()
    assert running =~ "running 2 test file(s) with --cover:\n  test/symphony_elixir/bar_test.exs\n  test/symphony_elixir/foo_test.exs"

    assert rest == [
             "SymphonyElixir.Bar 100.00% (lib/symphony_elixir/bar.ex)",
             "SymphonyElixir.Foo 100.00% (lib/symphony_elixir/foo.ex)",
             "SymphonyElixir.Foo.Helper 100.00% (lib/symphony_elixir/foo.ex)",
             "every changed module is at 100.00%"
           ]
  end

  test "fails naming the uncovered lines of a module below 100%" do
    coverage = fn modules ->
      Map.new(modules, fn
        SymphonyElixir.Foo = module ->
          {module, {:ok, [{{module, 3}, {1, 0}}, {{module, 7}, {0, 1}}, {{module, 7}, {0, 1}}, {{module, 9}, {0, 1}}]}}

        SymphonyElixir.Foo.Helper = module ->
          {module, {:error, {:not_cover_compiled, module}}}

        module ->
          {module, {:ok, []}}
      end)
    end

    assert {:error, message} = ChangedCoverage.run([], deps(%{coverage: coverage}))
    assert message =~ "2 changed module(s) below 100% coverage: SymphonyElixir.Foo, SymphonyElixir.Foo.Helper."
    assert message =~ "mix cover.changed <test files>"

    lines = infos()
    assert "SymphonyElixir.Bar 100.00% (lib/symphony_elixir/bar.ex)" in lines
    assert "SymphonyElixir.Foo 33.33%, uncovered: lib/symphony_elixir/foo.ex:7, lib/symphony_elixir/foo.ex:9" in lines

    assert "SymphonyElixir.Foo.Helper (lib/symphony_elixir/foo.ex): no coverage data, {:not_cover_compiled, SymphonyElixir.Foo.Helper}" in lines
  end

  test "reports a module the coverage data misses" do
    assert {:error, message} = ChangedCoverage.run([], deps(%{coverage: fn _modules -> %{} end}))
    assert message =~ "3 changed module(s) below 100% coverage"
    assert "SymphonyElixir.Bar (lib/symphony_elixir/bar.ex): no coverage data, :no_coverage_data" in infos()
  end

  test "skips ignored modules, adds extra and changed test files, and uses the given base" do
    git = fn
      ["merge-base", "HEAD", "origin/dev"] -> {:ok, "def456\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", "def456"] -> {:ok, "lib/symphony_elixir/foo.ex\nlib/symphony_elixir/bar.ex\n"}
      ["ls-files", "--others", "--exclude-standard"] -> {:ok, "test/symphony_elixir/other_test.exs\nlib/symphony_elixir/foo.ex\n"}
    end

    opts = [base: "origin/dev", ignore_modules: [SymphonyElixir.Bar, ~r/Helper$/], extra_tests: ["test/extra_test.exs"]]
    assert :ok = ChangedCoverage.run(opts, deps(%{git: git}))

    assert_received {:run_tests, ["test/extra_test.exs", "test/symphony_elixir/other_test.exs", "test/symphony_elixir/foo_test.exs"]}
    assert_received {:coverage, [SymphonyElixir.Foo]}

    assert [
             "skipped SymphonyElixir.Bar: in mix.exs test_coverage ignore_modules",
             "skipped SymphonyElixir.Foo.Helper: in mix.exs test_coverage ignore_modules" | _rest
           ] = infos()
  end

  test "passes without running tests when no lib/ module changed" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff" | _] -> {:ok, "README.md\nlib/symphony_elixir/notes.txt\n"}
      ["ls-files" | _] -> {:ok, ""}
    end

    assert :ok = ChangedCoverage.run([], deps(%{git: git}))
    refute_received {:run_tests, _files}
    assert infos() == ["no changed lib/ module to check"]
  end

  test "fails when no test file covers the changed modules" do
    assert {:error, message} = ChangedCoverage.run([], deps(%{test_files: fn -> [] end}))
    assert message =~ "no test file found for SymphonyElixir.Bar, SymphonyElixir.Foo, SymphonyElixir.Foo.Helper."
    refute_received {:run_tests, _files}
  end

  test "fails when the tests fail" do
    run_tests = fn _files -> {:error, "mix test exited with status 2; fix the failing tests first"} end

    assert {:error, "mix test exited with status 2; fix the failing tests first"} =
             ChangedCoverage.run([], deps(%{run_tests: run_tests}))

    refute_received {:coverage, _modules}
  end

  test "fails naming the git step that failed" do
    git = fn
      ["merge-base" | _] -> {:error, "exit status 128"}
    end

    assert {:error, message} = ChangedCoverage.run([], deps(%{git: git}))

    assert message ==
             "git could not find the merge-base with origin/main; fetch it first (git merge-base HEAD origin/main): exit status 128"
  end

  describe "names?/2" do
    test "matches the full module name, not a longer one" do
      assert ChangedCoverage.names?("alias SymphonyElixir.Foo\n", "SymphonyElixir.Foo")
      assert ChangedCoverage.names?("SymphonyElixir.Foo.run()", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias SymphonyElixir.Foo.Helper\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias SymphonyElixir.FooBar\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias Other.SymphonyElixir.Foo\n", "SymphonyElixir.Foo")
    end

    test "matches a member of a multi-alias" do
      assert ChangedCoverage.names?("alias SymphonyElixir.{Bar, Foo}\n", "SymphonyElixir.Foo")
      assert ChangedCoverage.names?("alias SymphonyElixir.{\n  Foo,\n  Bar\n}\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias SymphonyElixir.{Bar, FooBar}\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias SymphonyElixir.{Bar, Foo.Helper}\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias Other.{Foo}\n", "SymphonyElixir.Foo")
    end

    test "matches a top-level module by its name only" do
      assert ChangedCoverage.names?("Foo.run()", "Foo")
      refute ChangedCoverage.names?("Bar.Foo.run()", "Foo")
    end
  end

  test "summarize/1 counts each line once and skips line 0" do
    module = SymphonyElixir.Foo

    assert ChangedCoverage.summarize([
             {{module, 0}, {0, 1}},
             {{module, 2}, {0, 1}},
             {{module, 2}, {1, 0}},
             {{module, 5}, {0, 1}}
           ]) == %{covered: 1, lines: 2, uncovered: [5]}

    assert ChangedCoverage.summarize([]) == %{covered: 0, lines: 0, uncovered: []}
  end

  test "app_modules/1 lists the app's modules with their source files" do
    modules = ChangedCoverage.app_modules()

    assert {ChangedCoverage, Path.expand("lib/symphony_elixir/changed_coverage.ex")} in modules
  end

  test "all_test_files/0 lists the repo's test files" do
    assert "test/symphony_elixir/changed_coverage_test.exs" in ChangedCoverage.all_test_files()
  end
end
