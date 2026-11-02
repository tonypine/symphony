defmodule Mix.Tasks.Coverage.ReportTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Coverage.Report

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Task.reenable("coverage.report")

    on_exit(fn ->
      Mix.shell(previous_shell)
      Application.delete_env(:symphony_elixir, :coverage_report_deps)
    end)

    :ok
  end

  defp fake_deps(coverage) do
    test_pid = self()

    Application.put_env(:symphony_elixir, :coverage_report_deps, %{
      coverage: fn -> coverage end,
      write_file: fn path, _contents ->
        send(test_pid, {:write, path})
        :ok
      end
    })
  end

  test "reports the merged coverage, skipping mix.exs's ignore_modules, and writes the baseline" do
    # The runner is in mix.exs's ignore_modules: its missed line doesn't count.
    fake_deps(%{
      SymphonyElixir.CoverageReport => [{{SymphonyElixir.CoverageReport, 1}, {1, 0}}],
      SymphonyElixir.ChangedCoverage.Runner => [{{SymphonyElixir.ChangedCoverage.Runner, 1}, {0, 1}}]
    })

    assert :ok = Report.run(["--write-baseline", "cover/baseline.json", "--annotate"])

    assert_received {:write, "cover/baseline.json"}
    assert_received {:mix_shell, :info, ["coverage.report: 1 of 1 modules at 100.00%"]}
  end

  test "raises naming the modules below 100%, after printing their lines and annotations" do
    fake_deps(%{SymphonyElixir.CoverageReport => [{{SymphonyElixir.CoverageReport, 7}, {0, 1}}]})

    assert_raise Mix.Error, "coverage.report: 1 module(s) below 100% coverage, their uncovered lines above: SymphonyElixir.CoverageReport", fn ->
      Report.run(["--annotate"])
    end

    assert_received {:mix_shell, :info, ["coverage.report: SymphonyElixir.CoverageReport 0.00% (lib/symphony_elixir/coverage_report.ex), uncovered lines: 7"]}
    assert_received {:mix_shell, :info, ["::error file=lib/symphony_elixir/coverage_report.ex,line=7," <> _rest]}
  end
end
