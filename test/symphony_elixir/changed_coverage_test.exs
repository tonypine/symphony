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
        ["diff", "--name-only", "--diff-filter=D", "abc123"] -> {:ok, "lib/symphony_elixir/gone.ex\n"}
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
      weights: fn -> %{} end,
      failed_tests: fn -> [] end,
      save_failed: &send(test_pid, {:save_failed, &1}),
      run_parts: fn parts, modules ->
        send(test_pid, {:run_parts, parts, modules})
        Enum.map(parts, fn {name, _tests} -> %{name: name, status: 0, output: "Running ExUnit\n...\nFinished in 0.1 seconds\n3 tests, 0 failures\n"} end)
      end,
      coverage: fn modules, exports ->
        send(test_pid, {:coverage, modules, exports})
        Map.new(modules, &{&1, {:ok, [{{&1, 0}, {0, 1}}, {{&1, 3}, {1, 0}}]}})
      end,
      info: &send(test_pid, {:info, &1})
    }
    |> Map.merge(overrides)
  end

  # `mix test` output with one numbered failure for each of `specs` (`test/file_test.exs:line`).
  defp failed_output(specs, last_line \\ "") do
    numbered =
      specs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {spec, number} -> "  #{number}) test fails (SymphonyElixir.FooTest)\n     #{spec}\n     Assertion with == failed\n" end)

    "Running ExUnit\n..\n\n" <> numbered <> "\n.*.\nFinished in 0.1 seconds\n5 tests, #{length(specs)} failures\n" <> last_line
  end

  # A `run_parts` whose runs answer by name: `outputs` maps a name to `{status, output}`.
  defp run_parts(outputs) do
    test_pid = self()

    fn parts, modules ->
      send(test_pid, {:run_parts, parts, modules})

      Enum.map(parts, fn {name, _tests} ->
        {status, output} = Map.get(outputs, name, {0, "2 tests, 0 failures\n"})
        %{name: name, status: status, output: output}
      end)
    end
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

    modules = [SymphonyElixir.Bar, SymphonyElixir.Foo, SymphonyElixir.Foo.Helper]
    assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs", "test/symphony_elixir/foo_test.exs"]}], ^modules}
    assert_received {:coverage, ^modules, ["part-1"]}
    refute_received {:run_parts, _parts, _modules}
    refute_received {:save_failed, _specs}

    assert [running | rest] = infos()
    assert running == "running 2 test file(s) in 1 part(s), coverage of 3 module(s):\n  test/symphony_elixir/bar_test.exs\n  test/symphony_elixir/foo_test.exs"

    assert rest == [
             "3 tests passed in 1 part(s)",
             "SymphonyElixir.Bar 100.00% (lib/symphony_elixir/bar.ex)",
             "SymphonyElixir.Foo 100.00% (lib/symphony_elixir/foo.ex)",
             "SymphonyElixir.Foo.Helper 100.00% (lib/symphony_elixir/foo.ex)",
             "every changed module is at 100.00%"
           ]
  end

  test "fails naming the uncovered lines of a module below 100%" do
    coverage = fn modules, _exports ->
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
    assert {:error, message} = ChangedCoverage.run([], deps(%{coverage: fn _modules, _exports -> %{} end}))
    assert message =~ "3 changed module(s) below 100% coverage"
    assert "SymphonyElixir.Bar (lib/symphony_elixir/bar.ex): no coverage data, :no_coverage_data" in infos()
  end

  test "skips ignored modules, adds extra and changed test files, and uses the given base" do
    git = fn
      ["merge-base", "HEAD", "origin/dev"] -> {:ok, "def456\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", "def456"] -> {:ok, "lib/symphony_elixir/foo.ex\nlib/symphony_elixir/bar.ex\n"}
      ["diff", "--name-only", "--diff-filter=D", "def456"] -> {:ok, ""}
      ["ls-files", "--others", "--exclude-standard"] -> {:ok, "test/symphony_elixir/other_test.exs\nlib/symphony_elixir/foo.ex\n"}
    end

    opts = [base: "origin/dev", ignore_modules: [SymphonyElixir.Bar, ~r/Helper$/], extra_tests: ["test/extra_test.exs"]]
    assert :ok = ChangedCoverage.run(opts, deps(%{git: git}))

    # `bar.ex` changed too: its test runs, as a plain `mix test` of the change would run it.
    tests = ["test/extra_test.exs", "test/symphony_elixir/bar_test.exs", "test/symphony_elixir/foo_test.exs", "test/symphony_elixir/other_test.exs"]
    assert_received {:run_parts, [{"part-1", ^tests}], [SymphonyElixir.Foo]}
    assert_received {:coverage, [SymphonyElixir.Foo], ["part-1"]}

    assert [
             "skipped SymphonyElixir.Bar: in mix.exs test_coverage ignore_modules",
             "skipped SymphonyElixir.Foo.Helper: in mix.exs test_coverage ignore_modules" | _rest
           ] = infos()
  end

  test "checks the files it is given in place of the changed ones" do
    assert :ok = ChangedCoverage.run([files: ["lib/symphony_elixir/other.ex", "lib/symphony_elixir/other.ex"]], deps())

    assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/other_test.exs"]}], [SymphonyElixir.Other]}
    assert_received {:coverage, [SymphonyElixir.Other], ["part-1"]}
  end

  test "runs the covering tests of a changed file, and not those of an unchanged one" do
    covering = %{
      "lib/symphony_elixir/foo.ex" => ["test/symphony_elixir/foo_reach_test.exs"],
      "lib/symphony_elixir/other.ex" => ["test/symphony_elixir/other_reach_test.exs"]
    }

    assert :ok = ChangedCoverage.run([covering_tests: covering], deps())

    assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs", "test/symphony_elixir/foo_reach_test.exs", "test/symphony_elixir/foo_test.exs"]}], _modules}
  end

  test "checks the unchanged modules a deleted test named, with the tests left that name them" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", "abc123"] -> {:ok, "test/symphony_elixir/foo_test.exs\n"}
      ["diff", "--name-only", "--diff-filter=D", "abc123"] -> {:ok, "test/symphony_elixir/gone_test.exs\ntest/support/gone.ex\n"}
      ["show", "abc123:test/symphony_elixir/gone_test.exs"] -> {:ok, "alias SymphonyElixir.{Bar, Other}\nSymphonyElixir.Foo.Helper.run()\n"}
      ["ls-files" | _] -> {:ok, ""}
    end

    coverage = fn modules, _exports ->
      Map.new(modules, fn
        SymphonyElixir.Other = module -> {module, {:ok, [{{module, 3}, {1, 0}}, {{module, 552}, {0, 1}}]}}
        module -> {module, {:ok, []}}
      end)
    end

    assert {:error, message} = ChangedCoverage.run([ignore_modules: [SymphonyElixir.Bar]], deps(%{git: git, coverage: coverage}))
    assert message =~ "1 changed module(s) below 100% coverage: SymphonyElixir.Other."

    assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/foo_test.exs", "test/symphony_elixir/other_test.exs"]}], [SymphonyElixir.Foo.Helper, SymphonyElixir.Other]}
    lines = infos()
    assert "SymphonyElixir.Foo.Helper 100.00% (lib/symphony_elixir/foo.ex)" in lines
    assert "checking SymphonyElixir.Bar: named by deleted test/symphony_elixir/gone_test.exs" in lines
    assert "checking SymphonyElixir.Other: named by deleted test/symphony_elixir/gone_test.exs" in lines
    assert "skipped SymphonyElixir.Bar: in mix.exs test_coverage ignore_modules" in lines
    assert "SymphonyElixir.Other 50.00%, uncovered: lib/symphony_elixir/other.ex:552" in lines
  end

  test "fails naming a deleted test git could not read" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", _base] -> {:ok, ""}
      ["diff", "--name-only", "--diff-filter=D", _base] -> {:ok, "test/a_test.exs\ntest/b_test.exs\n"}
      ["show", "abc123:test/a_test.exs"] -> {:ok, ""}
      ["show", "abc123:test/b_test.exs"] -> {:error, "fatal: bad object"}
      ["ls-files" | _] -> {:ok, ""}
    end

    assert {:error, "git could not read deleted test/b_test.exs (git show abc123:test/b_test.exs): fatal: bad object"} =
             ChangedCoverage.run([], deps(%{git: git}))
  end

  test "passes without running tests when no lib/ module changed" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff" | _] -> {:ok, "README.md\nlib/symphony_elixir/notes.txt\n"}
      ["ls-files" | _] -> {:ok, ""}
    end

    assert :ok = ChangedCoverage.run([], deps(%{git: git}))
    refute_received {:run_parts, _parts, _modules}
    assert infos() == ["no changed lib/ module to check"]
  end

  test "with no module to check, runs the changed tests and the tests of the changed lib/ files without coverage" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", _base] -> {:ok, "lib/symphony_elixir/bar.ex\ntest/symphony_elixir/other_test.exs\n"}
      ["diff" | _] -> {:ok, ""}
      ["ls-files" | _] -> {:ok, ""}
    end

    read_file = fn path -> flunk("read #{path} to find the tests that name no module") end

    assert :ok = ChangedCoverage.run([ignore_modules: [SymphonyElixir.Bar]], deps(%{git: git, read_file: read_file}))

    assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs", "test/symphony_elixir/other_test.exs"]}], []}
    refute_received {:coverage, _modules, _exports}

    assert infos() == [
             "skipped SymphonyElixir.Bar: in mix.exs test_coverage ignore_modules",
             "running 2 test file(s) in 1 part(s), no coverage:\n  test/symphony_elixir/bar_test.exs\n  test/symphony_elixir/other_test.exs",
             "3 tests passed in 1 part(s)",
             "no changed lib/ module to check"
           ]
  end

  test "fails when a changed test fails, with no module to check" do
    git = fn
      ["merge-base" | _] -> {:ok, "abc123\n"}
      ["diff", "--name-only", "--diff-filter=ACMR", _base] -> {:ok, "test/symphony_elixir/other_test.exs\n"}
      ["diff" | _] -> {:ok, ""}
      ["ls-files" | _] -> {:ok, ""}
    end

    spec = "test/symphony_elixir/other_test.exs:4"
    outputs = %{"part-1" => {2, failed_output([spec])}, "retry" => {2, failed_output([spec])}}

    assert {:error, "1 test(s) fail: " <> _rest} = ChangedCoverage.run([], deps(%{git: git, run_parts: run_parts(outputs)}))
    assert_received {:run_parts, [{"retry", [^spec]}], []}
    refute "no changed lib/ module to check" in infos()
  end

  test "fails when no test file covers the changed modules" do
    assert {:error, message} = ChangedCoverage.run([], deps(%{test_files: fn -> [] end}))
    assert message =~ "no test file found for SymphonyElixir.Bar, SymphonyElixir.Foo, SymphonyElixir.Foo.Helper."
    refute_received {:run_parts, _parts, _modules}
  end

  describe "the parts" do
    test "run at once, by the weights, and the report reads every part's coverage" do
      weights = fn -> %{"test/symphony_elixir/bar_test.exs" => 12.0, "test/symphony_elixir/foo_test.exs" => 9.5} end

      assert :ok = ChangedCoverage.run([], deps(%{weights: weights}))

      assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs"]}, {"part-2", ["test/symphony_elixir/foo_test.exs"]}], _modules}
      assert_received {:coverage, _modules, ["part-1", "part-2"]}
      assert "6 tests passed in 2 part(s)" in infos()
    end

    test "are as many as asked for" do
      assert :ok = ChangedCoverage.run([parts: 2], deps())
      assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs"]}, {"part-2", ["test/symphony_elixir/foo_test.exs"]}], _modules}

      weights = fn -> %{"test/symphony_elixir/bar_test.exs" => 12.0, "test/symphony_elixir/foo_test.exs" => 9.5} end
      assert :ok = ChangedCoverage.run([max_parts: 1], deps(%{weights: weights}))
      assert_received {:run_parts, [{"part-1", ["test/symphony_elixir/bar_test.exs", "test/symphony_elixir/foo_test.exs"]}], _modules}
    end
  end

  describe "a failing test" do
    @foo_12 "test/symphony_elixir/foo_test.exs:12"
    @bar_7 "test/symphony_elixir/bar_test.exs:7"

    test "runs once more, alone, and fails the run when it fails again" do
      outputs = %{"part-1" => {2, failed_output([@foo_12, @bar_7])}, "retry" => {2, failed_output([@foo_12])}}

      assert {:error, message} = ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))
      assert message == "1 test(s) fail: #{@foo_12}. Fix the failing tests first; they run first next time"

      assert_received {:run_parts, [{"part-1", _tests}], modules}
      assert_received {:run_parts, [{"retry", [@bar_7, @foo_12]}], ^modules}
      assert_received {:save_failed, [@foo_12]}
      refute_received {:coverage, _modules, _exports}

      assert [_running, failure] = infos()
      assert failure == "failed again, alone:\n  1) test fails (SymphonyElixir.FooTest)\n     #{@foo_12}\n     Assertion with == failed"
    end

    test "that passes alone is named and does not fail the run, and its coverage counts" do
      outputs = %{"part-1" => {2, failed_output([@foo_12])}}

      assert :ok = ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))

      assert_received {:run_parts, [{"retry", [@foo_12]}], [_ | _]}
      assert_received {:save_failed, []}
      assert_received {:coverage, _modules, ["part-1", "retry"]}

      lines = infos()
      assert "1 test(s) failed beside the others and passed alone:\n  #{@foo_12}" in lines
      assert "5 tests ran in 1 part(s)" in lines
      assert "every changed module is at 100.00%" in lines
    end

    test "fails the run with the tests it named when the run alone names none" do
      outputs = %{"part-1" => {2, failed_output([@foo_12])}, "retry" => {1, "** (CompileError) test/symphony_elixir/foo_test.exs:3\n"}}

      assert {:error, "1 test(s) fail: #{@foo_12}." <> _rest} = ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))
      assert_received {:save_failed, [@foo_12]}
      assert "failed again, alone:\n** (CompileError) test/symphony_elixir/foo_test.exs:3" in infos()
    end

    test "is not run again when its part stopped at --max-failures, which left tests that never ran" do
      outputs = %{"part-1" => {2, failed_output([@foo_12], "--max-failures reached, aborting test suite\n")}}

      assert {:error, "1 test(s) fail: #{@foo_12}." <> _rest} = ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))
      assert_received {:run_parts, [{"part-1", _tests}], _modules}
      refute_received {:run_parts, _parts, _modules}
      assert_received {:save_failed, [@foo_12]}
    end

    test "is not run again when its part counts a failure that names no test, or an invalid test" do
      setup_all = "  1) SymphonyElixir.BarTest: failure on setup_all callback, all tests have been invalidated\n     ** (RuntimeError) boom\n\n"
      invalid = String.replace(failed_output([@foo_12]), "5 tests, 1 failures\n", "5 tests, 1 failure, 3 invalid\n")
      doctest = String.replace(failed_output([@foo_12]), "5 tests, 1 failures\n", "1 doctest, 5 tests, 2 failures\n")

      for output <- [setup_all <> invalid, doctest] do
        assert {:error, "1 test(s) fail: #{@foo_12}." <> _rest} = ChangedCoverage.run([], deps(%{run_parts: run_parts(%{"part-1" => {2, output}})}))
        assert_received {:run_parts, [{"part-1", _tests}], _modules}
        refute_received {:run_parts, _parts, _modules}
      end
    end

    test "is not run again with more failures than load explains" do
      specs = for line <- 10..40, do: "test/symphony_elixir/foo_test.exs:#{line}"
      outputs = %{"part-1" => {2, failed_output(specs)}}

      assert {:error, "31 test(s) fail: " <> _rest} = ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))
      assert_received {:run_parts, [{"part-1", _tests}], _modules}
      refute_received {:run_parts, _parts, _modules}
    end

    test "is not run again beside a part that ended without running its tests" do
      weights = fn -> %{"test/symphony_elixir/bar_test.exs" => 12.0, "test/symphony_elixir/foo_test.exs" => 9.5} end
      outputs = %{"part-1" => {1, "== Compilation error in file test/symphony_elixir/bar_test.exs ==\n"}, "part-2" => {2, failed_output([@foo_12])}}

      assert {:error, message} = ChangedCoverage.run([], deps(%{weights: weights, run_parts: run_parts(outputs)}))
      assert message =~ "1 test(s) fail: #{@foo_12}."
      refute_received {:run_parts, [{"retry", _specs}], _modules}
      assert "part-1:\n== Compilation error in file test/symphony_elixir/bar_test.exs ==" in infos()
    end

    test "fails the run naming the parts when none ran its tests" do
      outputs = %{"part-1" => {1, "** (Mix) Could not compile\n"}}

      assert {:error, "mix test ended without running its tests (part-1); fix what it printed first"} =
               ChangedCoverage.run([], deps(%{run_parts: run_parts(outputs)}))

      assert_received {:save_failed, []}
      assert "part-1:\n** (Mix) Could not compile" in infos()
    end
  end

  describe "the tests that failed last time" do
    @foo_12 "test/symphony_elixir/foo_test.exs:12"
    @foo_30 "test/symphony_elixir/foo_test.exs:30"

    test "run first, alone and without coverage, then every test runs" do
      # A failure of a test file this run does not select is left alone.
      failed_tests = fn -> [@foo_12, "test/symphony_elixir/other_test.exs:3"] end

      assert :ok = ChangedCoverage.run([], deps(%{failed_tests: failed_tests}))

      assert_received {:run_parts, [{"failed-first", [@foo_12]}], []}
      assert_received {:save_failed, []}
      assert_received {:run_parts, [{"part-1", _tests}], [_ | _]}
      assert_received {:coverage, _modules, ["part-1"]}
      assert ["running the 1 test(s) that failed last time first" | _rest] = infos()
    end

    test "stop the run while one still fails" do
      failed_tests = fn -> [@foo_12, @foo_30] end
      outputs = %{"failed-first" => {2, failed_output([@foo_30])}}

      assert {:error, message} = ChangedCoverage.run([], deps(%{failed_tests: failed_tests, run_parts: run_parts(outputs)}))
      assert message == "1 of the 2 test(s) that failed last time still fail: #{@foo_30}. The other tests did not run"

      assert_received {:run_parts, [{"failed-first", [@foo_12, @foo_30]}], []}
      refute_received {:run_parts, _parts, _modules}
      assert_received {:save_failed, [@foo_30]}
      assert [_first, "  1) test fails (SymphonyElixir.FooTest)\n     #{@foo_30}\n     Assertion with == failed"] = infos()
    end

    test "stay recorded when their run names no failure" do
      failed_tests = fn -> [@foo_12] end
      outputs = %{"failed-first" => {1, "** (Mix) Could not compile\n"}}

      assert {:error, "1 of the 1 test(s) that failed last time still fail: " <> _rest} =
               ChangedCoverage.run([], deps(%{failed_tests: failed_tests, run_parts: run_parts(outputs)}))

      assert_received {:save_failed, [@foo_12]}
      assert "** (Mix) Could not compile" in infos()
    end
  end

  describe "parts/3" do
    test "puts the heaviest file first onto the lightest part" do
      weights = %{"a" => 10.0, "b" => 6.0, "c" => 5.0, "d" => 4.0, "e" => 1.0}

      assert ChangedCoverage.parts(~w(e d c b a), weights, parts: 2) == [~w(a d), ~w(b c e)]
      assert ChangedCoverage.parts(~w(a b c d e), weights, parts: 1) == [~w(a b c d e)]
      # 29 s of tests, the heaviest file 10 s: parts of about 5 s, half of it.
      more = Map.merge(weights, %{"f" => 1.0, "g" => 1.0, "h" => 1.0})
      assert ChangedCoverage.parts(~w(a b c d e f g h), more) == [~w(a), ~w(b), ~w(c), ~w(d), ~w(e g), ~w(f h)]
      assert ChangedCoverage.parts(~w(a b c d e), weights, max_parts: 2) == [~w(a d), ~w(b c e)]
    end

    test "counts a file the weights don't list as an average one, and as one second without weights" do
      assert ChangedCoverage.parts(~w(new a b), %{"a" => 9.0, "b" => 1.0, "other" => 5.0}, parts: 2) == [~w(a), ~w(new b)]
      assert ChangedCoverage.parts(~w(b a), %{}, parts: 2) == [~w(a), ~w(b)]
    end

    test "never makes more parts than there are files, and at least one" do
      assert ChangedCoverage.parts(~w(a b), %{}, parts: 8) == [~w(a), ~w(b)]
      assert ChangedCoverage.parts(~w(a b), %{}, parts: 0) == [~w(a b)]
      assert ChangedCoverage.parts([], %{}) == []
    end
  end

  test "part_count/2 aims the parts at half the heaviest file, and at 5 s or more, up to the ceiling" do
    assert ChangedCoverage.part_count([], 8) == 1
    # Light files: a `mix test` start is not worth less than 5 s of tests.
    assert ChangedCoverage.part_count([1.0, 1.0, 1.0], 8) == 1
    assert ChangedCoverage.part_count(List.duplicate(1.0, 11), 8) == 3
    assert ChangedCoverage.part_count([8.8, 2.0, 2.0, 1.3], 8) == 3
    # One heavy file: the run ends no sooner than it, so the others go into parts half as long.
    assert ChangedCoverage.part_count([47.4, 20.0, 20.0, 10.0], 8) == 5
    assert ChangedCoverage.part_count(List.duplicate(2.0, 200), 8) == 8
    assert ChangedCoverage.part_count(List.duplicate(2.0, 200), 4) == 4
  end

  test "failures/1 lists each numbered failure once, as file:line" do
    output = failed_output(["test/a_test.exs:3", "test/sub/b_test.exs:40", "test/a_test.exs:3"])

    assert ChangedCoverage.failures(output) == ["test/a_test.exs:3", "test/sub/b_test.exs:40"]
    assert ChangedCoverage.failures("3 tests, 0 failures\n") == []
  end

  describe "failure_text/1" do
    test "keeps the numbered failures, without the lines before, the progress dots and the summary" do
      assert ChangedCoverage.failure_text(failed_output(["test/a_test.exs:3"])) == "  1) test fails (SymphonyElixir.FooTest)\n     test/a_test.exs:3\n     Assertion with == failed"
    end

    test "keeps at most 400 lines" do
      specs = for line <- 1..150, do: "test/a_test.exs:#{line}"
      text = ChangedCoverage.failure_text(failed_output(specs))

      assert length(String.split(text, "\n")) == 399
      assert text =~ "test/a_test.exs:100\n"
      refute text =~ "test/a_test.exs:101\n"
    end

    test "is the end of an output with no numbered failure" do
      lines = for number <- 1..80, do: "line #{number}"
      text = ChangedCoverage.failure_text(Enum.join(lines, "\n") <> "\n")

      assert String.starts_with?(text, "line 22\n")
      assert String.ends_with?(text, "line 80")
    end
  end

  test "test_count/1 reads the number of tests a run printed" do
    assert ChangedCoverage.test_count("Finished in 0.1 seconds\n12 tests, 0 failures\n") == 12
    assert ChangedCoverage.test_count("3 doctests, 1 test, 1 failure, 2 excluded\n") == 1
    assert ChangedCoverage.test_count("** (Mix) Could not compile\n") == 0
  end

  @tag :tmp_dir
  test "test_weights/1 reads the seconds of each test file, and nothing without the file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "weights.tsv")
    File.write!(path, "test/a_test.exs\t12.5\ntest/b_test.exs\t0.0\nnot a line\ntest/c_test.exs\tslow\n")

    assert ChangedCoverage.test_weights(path) == %{"test/a_test.exs" => 12.5, "test/b_test.exs" => 0.0}
    assert ChangedCoverage.test_weights(Path.join(tmp_dir, "none.tsv")) == %{}
    assert %{"test/symphony_elixir/changed_coverage_test.exs" => _seconds} = ChangedCoverage.test_weights()
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

    test "does not match the head of a multi-alias, which names its members only" do
      refute ChangedCoverage.names?("alias SymphonyElixir.{Bar, Foo}\n", "SymphonyElixir")
      refute ChangedCoverage.names?("alias SymphonyElixir.Foo.{Helper, Other}\n", "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("alias SymphonyElixir.{\n  Bar,\n  Foo\n}\n", "SymphonyElixir")
      assert ChangedCoverage.names?("alias SymphonyElixir.Foo.{Helper, Other}\n", "SymphonyElixir.Foo.Helper")
      # The module itself among the members of its parent's group still names it.
      assert ChangedCoverage.names?("alias SymphonyElixir.{Foo, Foo.Helper}\n", "SymphonyElixir.Foo")
    end

    test "matches an alias of the module itself, and a mention in a string, an atom or a comment" do
      assert ChangedCoverage.names?("alias SymphonyElixir\n", "SymphonyElixir")
      assert ChangedCoverage.names?("alias SymphonyElixir.Foo, as: F\n", "SymphonyElixir.Foo")
      assert ChangedCoverage.names?("assert SymphonyElixir.start(:normal, []) == :ok\n", "SymphonyElixir")
      assert ChangedCoverage.names?("@moduletag capture_log: SymphonyElixir\n", "SymphonyElixir")
      # The source is read as text: a name in a string or a comment counts, as it always did.
      assert ChangedCoverage.names?(~s(assert message =~ "SymphonyElixir.Foo is down"\n), "SymphonyElixir.Foo")
      assert ChangedCoverage.names?("# covers SymphonyElixir.Foo through the web layer\n", "SymphonyElixir.Foo")
      assert ChangedCoverage.names?("# see SymphonyElixir.\n", "SymphonyElixir")
      refute ChangedCoverage.names?(~s("SymphonyElixir.Foo.Helper is down"), "SymphonyElixir.Foo")
      refute ChangedCoverage.names?("# covers SymphonyElixir.Foo\n", "SymphonyElixir")
    end

    test "selects for the top-level module only the test files that name it" do
      tests = %{
        "test/exact_test.exs" => "assert SymphonyElixir.version() =~ \".\"\n",
        "test/alias_test.exs" => "alias SymphonyElixir\n",
        "test/comment_test.exs" => "# SymphonyElixir starts the app\n",
        "test/longer_test.exs" => "alias SymphonyElixir.Foo\nSymphonyElixirWeb.Endpoint.url()\n",
        "test/group_test.exs" => "alias SymphonyElixir.{Bar, Foo}\n"
      }

      modules = fn -> [{SymphonyElixir, Path.expand("lib/symphony_elixir.ex")}, {SymphonyElixir.Foo, Path.expand("lib/symphony_elixir/foo.ex")}] end
      deps = deps(%{modules: modules, test_files: fn -> Map.keys(tests) end, read_file: &Map.fetch!(tests, &1)})

      assert :ok = ChangedCoverage.run([files: ["lib/symphony_elixir.ex"]], deps)
      assert_received {:run_parts, [{"part-1", ["test/alias_test.exs", "test/comment_test.exs", "test/exact_test.exs"]}], [SymphonyElixir]}

      assert :ok = ChangedCoverage.run([files: ["lib/symphony_elixir/foo.ex"]], deps)
      assert_received {:run_parts, [{"part-1", ["test/group_test.exs", "test/longer_test.exs"]}], [SymphonyElixir.Foo]}
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
