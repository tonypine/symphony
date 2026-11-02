defmodule Mix.Tasks.Coverage.Missing do
  use Mix.Task

  alias SymphonyElixir.MissingCoverage

  @moduledoc """
  Prints the uncovered lines of every module below 100% in the exported coverage data.

      mix coverage.missing [COVER_DIR]

  Runs after `mix test.coverage` (see the `test.coverage` alias), which fails on a percentage table
  alone. `COVER_DIR` defaults to `cover`. Never fails by itself.
  """
  @shortdoc "Prints the uncovered lines of modules below 100% coverage"

  @impl Mix.Task
  def run(args) do
    dir = List.first(args) || "cover"
    Mix.Task.run("compile")
    ignores = Mix.Project.config()[:test_coverage][:ignore_modules] || []

    missing = MissingCoverage.describe(dir, ignores)
    Mix.shell().info("coverage.missing: #{length(missing)} module(s) with uncovered lines")
    Enum.each(missing, &Mix.shell().info("coverage.missing: " <> &1))
  end
end
