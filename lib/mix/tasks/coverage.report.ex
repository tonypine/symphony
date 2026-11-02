defmodule Mix.Tasks.Coverage.Report do
  use Mix.Task

  alias SymphonyElixir.CoverageReport

  @moduledoc """
  CI's `coverage report`: merges the test partitions' `cover/*.coverdata`, names the uncovered lines
  of every module below 100% and fails when one of them is the change's fault.

      mix coverage.report [--base REF] [--baseline FILE] [--write-baseline FILE] [--annotate]

  Without `--base` every module below 100% fails (a push to main). With `--base` (a pull request's
  merge commit diffed against its first parent), a module the pull request doesn't touch, and that
  main's `--baseline` has at 100%, is a warning instead. `--write-baseline` writes this run's
  per-module uncovered lines for later pull requests; `--annotate` prints GitHub Actions
  annotations naming the lines. Modules in `mix.exs`'s `test_coverage` `ignore_modules` are skipped.
  See `SymphonyElixir.CoverageReport`.
  """
  @shortdoc "Names the uncovered lines of the merged coverage and fails on the change's own"

  @switches [base: :string, baseline: :string, write_baseline: :string, annotate: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")

    opts = Keyword.put(opts, :ignore_modules, Mix.Project.config()[:test_coverage][:ignore_modules] || [])

    # Tests swap in fakes for `:cover`, git and the files here.
    deps = Map.merge(CoverageReport.default_deps(), Application.get_env(:symphony_elixir, :coverage_report_deps, %{}))

    case CoverageReport.run(opts, deps) do
      :ok -> :ok
      {:error, message} -> Mix.raise("coverage.report: " <> message)
    end
  end
end
