defmodule Mix.Tasks.Cover.Changed do
  use Mix.Task

  alias SymphonyElixir.ChangedCoverage

  @moduledoc """
  Checks that every `lib/` module the branch changes is at 100% line coverage, before a push.

      mix cover.changed [--base origin/main] [TEST_FILES...]

  Runs the changed test files, `test/<path>_test.exs` for each changed `lib/<path>.ex` and every
  test file that names a changed module, once with `--cover` (the test environment), then prints
  each changed module's coverage with its uncovered lines. Fails when one is below 100%. Modules in
  `mix.exs`'s `test_coverage` `ignore_modules` are skipped, as in CI.

  The changed files are those since the merge-base with `--base`, uncommitted and untracked ones
  included. Extra `TEST_FILES` run as well: pass them when the tests that cover a module don't name it.
  """
  @shortdoc "Fails when a lib/ module the branch changes is below 100% coverage"

  @switches [base: :string]

  @impl Mix.Task
  def run(args) do
    {opts, extra_tests} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")

    opts = Keyword.merge(opts, extra_tests: extra_tests, ignore_modules: Mix.Project.config()[:test_coverage][:ignore_modules] || [])

    # Tests swap in fakes for git, `mix test` and `:cover` here.
    deps = Map.merge(ChangedCoverage.default_deps(), Application.get_env(:symphony_elixir, :cover_changed_deps, %{}))

    case ChangedCoverage.run(opts, deps) do
      :ok -> :ok
      {:error, message} -> Mix.raise("cover.changed: " <> message)
    end
  end
end
