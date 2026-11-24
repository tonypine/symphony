defmodule Mix.Tasks.Cover.Changed do
  use Mix.Task

  alias SymphonyElixir.ChangedCoverage

  @moduledoc """
  Runs the tests of what the branch changes and checks that every `lib/` module it changes is at
  100% line coverage, in one pass, before a push.

      mix cover.changed [--base origin/main] [--file lib/PATH.ex ...] [--parts N] [TEST_FILES...]

  Runs the changed test files, `test/<path>_test.exs` for each changed `lib/<path>.ex` and every
  test file that names a changed module, once (the test environment), then prints
  each changed module's coverage with its uncovered lines. Fails when a test fails or a module is below 100%. Modules in
  `mix.exs`'s `test_coverage` `ignore_modules` are skipped, as in CI. `--file` (repeatable) checks
  the modules of the `lib/` files it names in place of the changed ones, as a CI Fix run's
  failed-check step does for the modules CI's coverage report found below 100%.

  The test files run in several `mix test` processes at once, spread by how long each took
  (`test/support/test_weights.tsv`): as many as the tests are worth, at most 8 and the number of
  cores; `--parts N` sets the number. Each process cover-compiles only the modules under check and
  the report reads the coverage of all of them together. The tests that failed in the last run go
  first, alone, and the run stops there while one still fails; a test that fails beside the others
  runs once more, alone, and one that passes then is named and doesn't fail the run. The failures
  are printed as ExUnit prints them; each process's whole output is in
  `_build/test/cover_changed/<name>.log`.

  The changed files are those since the merge-base with `--base`, uncommitted and untracked ones
  included. Extra `TEST_FILES` run as well: pass them when the tests that cover a module don't name it.
  `mix.exs`'s `cover_changed` `covering_tests` maps a `lib/` file to the test files that always run
  when it changes, for a file such as the config schema whose modules the tests reach without naming.
  With no module to check (test files only, or ignored modules) the changed test files, the tests
  of the changed `lib/` files and the extra ones still run, without coverage.
  """
  @shortdoc "Runs the tests of the change; fails when a changed lib/ module is below 100% coverage"

  @switches [base: :string, file: :keep, parts: :integer]
  @max_parts 8

  @impl Mix.Task
  def run(args) do
    {opts, extra_tests} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile")

    config = Mix.Project.config()

    opts =
      Keyword.merge(opts,
        extra_tests: extra_tests,
        files: Keyword.get_values(opts, :file),
        max_parts: min(@max_parts, System.schedulers_online()),
        ignore_modules: config[:test_coverage][:ignore_modules] || [],
        covering_tests: config[:cover_changed][:covering_tests] || %{}
      )

    # Tests swap in fakes for git, `mix test` and `:cover` here.
    deps = Map.merge(ChangedCoverage.default_deps(), Application.get_env(:symphony_elixir, :cover_changed_deps, %{}))

    case ChangedCoverage.run(opts, deps) do
      :ok -> :ok
      {:error, message} -> Mix.raise("cover.changed: " <> message)
    end
  end
end
