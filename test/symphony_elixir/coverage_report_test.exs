defmodule SymphonyElixir.CoverageReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CoverageReport

  # Foo misses lines 4 and 9 of 4; Bar and Ignored are fully covered.
  @coverage %{
    SymphonyElixir.Foo => [
      {{SymphonyElixir.Foo, 0}, {0, 1}},
      {{SymphonyElixir.Foo, 2}, {1, 0}},
      {{SymphonyElixir.Foo, 3}, {2, 0}},
      {{SymphonyElixir.Foo, 4}, {0, 1}},
      {{SymphonyElixir.Foo, 9}, {0, 1}}
    ],
    SymphonyElixir.Bar => [{{SymphonyElixir.Bar, 1}, {1, 0}}],
    SymphonyElixir.Ignored => [{{SymphonyElixir.Ignored, 1}, {0, 1}}]
  }

  @baseline_path "cover/baseline.json"

  defp baseline(modules), do: Jason.encode!(%{"modules" => modules})

  defp deps(overrides \\ %{}) do
    test_pid = self()
    files = Map.get(overrides, :files, %{})

    %{
      coverage: fn -> @coverage end,
      modules: fn ->
        [
          {SymphonyElixir.Foo, Path.expand("lib/symphony_elixir/foo.ex")},
          {SymphonyElixir.Bar, Path.expand("lib/symphony_elixir/bar.ex")},
          {SymphonyElixir.Ignored, Path.expand("lib/symphony_elixir/ignored.ex")}
        ]
      end,
      git: fn
        ["merge-base", "HEAD", "HEAD^1"] -> {:ok, "base123\n"}
        ["diff", "--name-only", "--diff-filter=ACMR", "base123"] -> {:ok, Map.get(overrides, :changed, "lib/symphony_elixir/bar.ex\nREADME.md\n")}
        ["diff", "--name-only", "--diff-filter=D", "base123"] -> {:ok, Map.get(overrides, :deleted, "")}
        ["show", "base123:" <> path] -> {:ok, Map.fetch!(files, "base:" <> path)}
        ["ls-files", "--others", "--exclude-standard"] -> {:ok, ""}
      end,
      read_file: fn path -> Map.get(files, path, {:error, :enoent}) |> wrap() end,
      write_file: fn path, contents ->
        send(test_pid, {:write, path, contents})
        :ok
      end,
      info: &send(test_pid, {:info, &1}),
      print: &send(test_pid, {:print, &1})
    }
    |> Map.merge(Map.drop(overrides, [:files, :changed, :deleted]))
  end

  defp wrap({:error, _reason} = error), do: error
  defp wrap(contents), do: {:ok, contents}

  defp drain(tag) do
    receive do
      {^tag, line} -> [line | drain(tag)]
    after
      0 -> []
    end
  end

  defp opts(extra), do: Keyword.merge([ignore_modules: [SymphonyElixir.Ignored]], extra)
  defp pr_opts(extra \\ []), do: opts([base: "HEAD^1", baseline: @baseline_path, annotate: true] ++ extra)

  test "passes when every module outside ignore_modules is at 100%, and writes the baseline" do
    coverage = Map.delete(@coverage, SymphonyElixir.Foo)
    assert :ok = CoverageReport.run(opts(write_baseline: @baseline_path), deps(%{coverage: fn -> coverage end}))

    assert drain(:info) == ["1 of 1 modules at 100.00%", "wrote the coverage baseline to #{@baseline_path}"]
    assert_received {:write, @baseline_path, json}
    assert Jason.decode!(json) == %{"modules" => %{"SymphonyElixir.Bar" => %{"file" => "lib/symphony_elixir/bar.ex", "uncovered" => []}}}
  end

  test "on main every module below 100% fails, named with its file and uncovered lines" do
    assert {:error, message} = CoverageReport.run(opts(annotate: true), deps())
    assert message == "1 module(s) below 100% coverage, their uncovered lines above: SymphonyElixir.Foo"

    assert drain(:info) == [
             "SymphonyElixir.Foo 50.00% (lib/symphony_elixir/foo.ex), uncovered lines: 4, 9",
             "1 of 2 modules at 100.00%",
             "SymphonyElixir.Foo fails the gate: every module must be at 100% on main"
           ]

    assert drain(:print) == [
             "::error file=lib/symphony_elixir/foo.ex,line=4,title=Coverage SymphonyElixir.Foo 50.00%25::" <>
               "uncovered lines 4, 9 of lib/symphony_elixir/foo.ex: every module must be at 100%25 on main"
           ]
  end

  test "a pull request that doesn't touch a module main had at 100% gets a warning, not a failure" do
    files = %{@baseline_path => baseline(%{"SymphonyElixir.Foo" => %{"uncovered" => []}, "SymphonyElixir.Bar" => %{"uncovered" => []}})}

    assert :ok = CoverageReport.run(pr_opts(), deps(%{files: files}))

    assert "warning: SymphonyElixir.Foo is below 100% but this change doesn't touch it and main had it at 100%: not this change's failure" in drain(:info)

    assert drain(:print) == [
             "::warning file=lib/symphony_elixir/foo.ex,line=4,title=Coverage SymphonyElixir.Foo 50.00%25::" <>
               "uncovered lines 4, 9 of lib/symphony_elixir/foo.ex: not this change's: main had it at 100%25 and this change doesn't touch it"
           ]
  end

  test "a pull request that touches a short module fails on it: its file, a changed test or a deleted test naming it" do
    full = %{@baseline_path => baseline(%{"SymphonyElixir.Foo" => %{"uncovered" => []}})}

    assert {:error, _message} = CoverageReport.run(pr_opts(), deps(%{files: full, changed: "lib/symphony_elixir/foo.ex\n"}))
    assert "SymphonyElixir.Foo fails the gate: this change edits its file" in drain(:info)
    assert [annotation] = drain(:print)
    assert annotation =~ "::error file=lib/symphony_elixir/foo.ex,line=4,"

    changed_test = Map.put(full, "test/symphony_elixir/foo_test.exs", "alias SymphonyElixir.Foo\n")
    assert {:error, _message} = CoverageReport.run(pr_opts(), deps(%{files: changed_test, changed: "test/symphony_elixir/foo_test.exs\ntest/support/gone.exs\n"}))
    assert "SymphonyElixir.Foo fails the gate: this change edits or deletes a test file that names it" in drain(:info)

    deleted = Map.put(full, "base:test/symphony_elixir/foo_test.exs", "SymphonyElixir.Foo.run()\n")
    assert {:error, _message} = CoverageReport.run(pr_opts(), deps(%{files: deleted, changed: "", deleted: "test/symphony_elixir/foo_test.exs\n"}))
    assert "SymphonyElixir.Foo fails the gate: this change edits or deletes a test file that names it" in drain(:info)
  end

  test "an untouched module still fails when main was short on it, or there is no baseline to tell" do
    short_on_main = %{@baseline_path => baseline(%{"SymphonyElixir.Foo" => %{"uncovered" => [4]}})}
    assert {:error, _message} = CoverageReport.run(pr_opts(), deps(%{files: short_on_main}))
    assert "SymphonyElixir.Foo fails the gate: main's last green report did not have it at 100% either" in drain(:info)

    for files <- [%{}, %{@baseline_path => "not json"}, %{@baseline_path => ~s({"other": 1})}] do
      assert {:error, _message} = CoverageReport.run(pr_opts(), deps(%{files: files}))
      info = drain(:info)
      assert "no coverage baseline from main at #{@baseline_path}: every module below 100% fails" in info
      assert "SymphonyElixir.Foo fails the gate: there is no coverage baseline from main to tell whether it was at 100% there" in info
    end

    assert {:error, _message} = CoverageReport.run(opts(base: "HEAD^1"), deps())
    assert "SymphonyElixir.Foo fails the gate: there is no coverage baseline from main to tell whether it was at 100% there" in drain(:info)
  end

  test "a module whose file is unknown is still named, and annotated without a location" do
    modules = fn -> [] end
    assert {:error, _message} = CoverageReport.run(opts(annotate: true), deps(%{modules: modules}))

    assert "SymphonyElixir.Foo 50.00% (file unknown), uncovered lines: 4, 9" in drain(:info)
    assert ["::error title=Coverage SymphonyElixir.Foo 50.00%25::uncovered lines 4, 9 of SymphonyElixir.Foo: every module must be at 100%25 on main"] = drain(:print)
  end

  test "fails when the baseline can't be written or git can't diff the pull request" do
    write = fn _path, _contents -> {:error, :eacces} end
    assert {:error, "could not write the coverage baseline to out.json: :eacces"} = CoverageReport.run(opts(write_baseline: "out.json"), deps(%{write_file: write}))

    git = fn _args -> {:error, "fatal"} end
    assert {:error, "git could not find the merge-base with HEAD^1" <> _rest} = CoverageReport.run(pr_opts(), deps(%{git: git}))
  end

  test "the annotation escapes what GitHub's workflow commands read as syntax" do
    result = %{module: SymphonyElixir.Foo, file: "lib/a,b.ex", covered: 1, lines: 3, uncovered: [2]}

    assert CoverageReport.annotation("error", result, "why: 100%") ==
             "::error file=lib/a%2Cb.ex,line=2,title=Coverage SymphonyElixir.Foo 33.33%25::uncovered lines 2 of lib/a,b.ex: why: 100%25"
  end
end
