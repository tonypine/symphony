defmodule SymphonyElixir.ChangedCoverage do
  @moduledoc """
  Checks the line coverage of the `lib/` modules a branch changes, before a push, so a branch
  that misses one line fails here instead of in CI's 100% `coverage report`.

  Finds the files changed since the merge-base with the base branch (committed, uncommitted and
  untracked), the modules compiled from the changed `lib/` files, and the test files for them: the
  changed test files, `test/<path>_test.exs` for `lib/<path>.ex`, and every test file that names
  the module. A test file the branch deletes may have been the only coverage of a module the branch
  doesn't touch, so every app module the deleted file named at the merge-base is checked too. It
  runs those tests once and fails when one of them fails, or when a changed module, outside
  `mix.exs`'s `test_coverage` `ignore_modules`, has a line they don't run.

  The one pass is both the test run and the coverage run:

  - The test files are spread over several `mix test` processes that run at once (`parts/3`: by
    how long each file took, `test/support/test_weights.tsv`, heaviest first onto the lightest
    part), since most test files run one test at a time and one process leaves most cores idle.
  - Each process cover-compiles only the modules under check, not the whole app, and exports their
    coverage; the report reads the exports of every part together.
  - The tests that failed in the last run go first, alone, and the run stops there while one still
    fails. A test that fails beside the others runs once more, alone: one that passes then is
    named as unsteady and doesn't fail the run.
  - A part that stopped at `--max-failures`, or in which a `setup_all` failed, left tests that
    never ran: the run fails and names the part, and no test is run again alone.
  - With no module to check (a change to test files only, or to ignored modules), the changed test
    files and the tests of the changed `lib/` files still run, without coverage.
  - With `:all`, the one pass runs every test file of the suite, not only the ones picked for the
    change, and reads the changed modules' coverage from it.

  `mix cover.changed` runs it. The git, test and `:cover` calls go through `deps`, so tests can
  fake them; `SymphonyElixir.ChangedCoverage.Runner` holds the real ones.
  """

  alias SymphonyElixir.ChangedCoverage.Runner

  # A part pays for its own `mix test` start (about 3 s), so a part is worth at least this much.
  @min_part_seconds 5.0
  # More parts than this are no faster on a 12-core machine (`scripts/test-parts.sh`).
  @max_parts 8
  # More failures than this are not load: they are printed, not run again alone.
  @max_failed_alone 30
  @failure_lines 400
  @tail_lines 60

  @type git_runner :: ([String.t()] -> {:ok, String.t()} | {:error, String.t()})
  @type line_results :: [{{module(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}]
  @typedoc "One `mix test` process: its name, exit status and whole output."
  @type part_result :: %{name: String.t(), status: non_neg_integer(), output: String.t()}
  @type deps :: %{
          git: git_runner(),
          modules: (-> [{module(), Path.t()}]),
          test_files: (-> [Path.t()]),
          read_file: (Path.t() -> String.t()),
          weights: (-> %{Path.t() => number()}),
          failed_tests: (-> [String.t()]),
          save_failed: ([String.t()] -> any()),
          run_parts: ([{String.t(), [String.t()]}], [module()] -> [part_result()]),
          coverage: ([module()], [String.t()] -> %{module() => {:ok, line_results()} | {:error, term()}}),
          info: (String.t() -> any())
        }

  @doc """
  Runs the check. `opts`: `:base` (default `origin/main`), `:files` (the `lib/` files to check in
  place of the changed ones: a CI Fix run's failed-check step names the modules CI found below 100%), `:ignore_modules` (modules or regexes),
  `:extra_tests` (test files to run as well), `:covering_tests` (a map from a `lib/` file to
  the test files that cover it without naming its modules, run whenever that file changes),
  `:parts` (the number of `mix test` processes, in place of the one `part_count/2` picks),
  `:max_parts` (its ceiling) and `:all` (run every test file `deps.test_files` lists, in `:max_parts`
  parts unless `:parts` says). Returns `:ok`, or `{:error, message}` naming what failed.
  """
  @spec run(keyword(), deps()) :: :ok | {:error, String.t()}
  def run(opts, deps) do
    base = Keyword.get(opts, :base, "origin/main")
    ignores = Keyword.get(opts, :ignore_modules, [])

    with {:ok, files} <- files(Keyword.get(opts, :files, []), base, deps.git),
         {:ok, deleted} <- deleted_tests(base, deps.git) do
      app_modules = deps.modules.()
      changed = changed_modules(files, app_modules)
      named = named_modules(deleted, app_modules, changed)

      Enum.each(named, fn {{module, _file}, test} -> deps.info.("checking #{inspect(module)}: named by deleted #{test}") end)

      {ignored, checked} =
        (changed ++ Enum.map(named, &elem(&1, 0))) |> Enum.sort_by(fn {module, file} -> {file, inspect(module)} end) |> Enum.split_with(&ignored?(elem(&1, 0), ignores))

      Enum.each(ignored, fn {module, _file} -> deps.info.("skipped #{inspect(module)}: in mix.exs test_coverage ignore_modules") end)
      covering = Keyword.get(opts, :covering_tests, %{})
      extra_tests = Keyword.get(opts, :extra_tests, []) ++ Enum.flat_map(files, &Map.get(covering, &1, []))
      check(checked, files, extra_tests, opts, deps)
    end
  end

  defp files([], base, git), do: changed_files(base, git)
  defp files(files, _base, _git), do: {:ok, files |> Enum.uniq() |> Enum.sort()}

  defp check(modules, files, extra_tests, opts, deps) do
    tests = if all?(opts), do: Enum.uniq(extra_tests ++ Enum.sort(deps.test_files.())), else: test_files(modules, files, extra_tests, deps)

    case {modules, tests} do
      {[], []} ->
        deps.info.("no changed lib/ module to check")
        :ok

      {_modules, []} ->
        {:error,
         "no test file found for #{Enum.map_join(modules, ", ", &inspect(elem(&1, 0)))}. " <>
           "Pass the test files that cover them: mix cover.changed <test files>"}

      {_modules, tests} ->
        names = Enum.map(modules, &elem(&1, 0))

        with {:ok, exports} <- run_tests(tests, names, opts, deps) do
          coverage_report(modules, names, exports, deps)
        end
    end
  end

  defp coverage_report([], _names, _exports, deps) do
    deps.info.("no changed lib/ module to check")
    :ok
  end

  defp coverage_report(modules, names, exports, deps), do: modules |> results(deps.coverage.(names, exports)) |> report(deps)

  # Runs `tests` in parts and returns the names of the runs whose coverage counts.
  defp run_tests(tests, modules, opts, deps) do
    with :ok <- failed_first(tests, deps) do
      parts = tests |> parts(deps.weights.(), part_opts(opts)) |> Enum.with_index(1) |> Enum.map(fn {files, index} -> {"part-#{index}", files} end)
      coverage = if modules == [], do: "no coverage", else: "coverage of #{length(modules)} module(s)"
      deps.info.(running(tests, length(parts), coverage, all?(opts)))
      parts |> deps.run_parts.(modules) |> ran(modules, deps)
    end
  end

  defp all?(opts), do: Keyword.get(opts, :all, false)

  # Every test of the suite is worth the ceiling, as in `scripts/test-parts.sh`.
  defp part_opts(opts) do
    if all?(opts), do: Keyword.put_new(opts, :parts, Keyword.get(opts, :max_parts, @max_parts)), else: opts
  end

  # The whole suite is not listed file by file.
  defp running(tests, parts, coverage, true), do: "running every test file (#{length(tests)}) in #{parts} part(s), #{coverage}"
  defp running(tests, parts, coverage, false), do: "running #{length(tests)} test file(s) in #{parts} part(s), #{coverage}:\n" <> Enum.map_join(Enum.sort(tests), "\n", &"  #{&1}")

  defp ran(results, modules, deps) do
    names = Enum.map(results, & &1.name)
    tests = results |> Enum.map(&test_count(&1.output)) |> Enum.sum()

    case Enum.reject(results, &(&1.status == 0)) do
      [] ->
        deps.info.("#{tests} tests passed in #{length(results)} part(s)")
        {:ok, names}

      failed ->
        with {:ok, retry} <- failed_alone(failed, modules, deps) do
          deps.info.("#{tests} tests ran in #{length(results)} part(s)")
          {:ok, names ++ [retry]}
        end
    end
  end

  # The tests of this run that failed last time go first, alone: a fix is checked in seconds.
  defp failed_first(tests, deps) do
    case Enum.filter(deps.failed_tests.(), &(String.replace(&1, ~r/:\d+$/, "") in tests)) do
      [] ->
        :ok

      specs ->
        deps.info.("running the #{length(specs)} test(s) that failed last time first")
        [result] = deps.run_parts.([{"failed-first", specs}], [])

        if result.status == 0 do
          deps.save_failed.([])
          :ok
        else
          still = failures_or(result.output, specs)
          deps.info.(failure_text(result.output))
          deps.save_failed.(still)
          {:error, "#{length(still)} of the #{length(specs)} test(s) that failed last time still fail: #{Enum.join(still, ", ")}. The other tests did not run"}
        end
    end
  end

  # A test that measures time can fail while every core is busy. The failed tests run once more,
  # alone, with coverage, when running them again is running everything that did not pass.
  defp failed_alone(failed, modules, deps) do
    specs = failed |> Enum.flat_map(&failures(&1.output)) |> Enum.uniq() |> Enum.sort()

    if Enum.all?(failed, &only_named_failures?(&1.output)) and length(specs) <= @max_failed_alone do
      [retry] = deps.run_parts.([{"retry", specs}], modules)

      if retry.status == 0 do
        deps.save_failed.([])
        deps.info.("#{length(specs)} test(s) failed beside the others and passed alone:\n" <> Enum.map_join(specs, "\n", &"  #{&1}"))
        {:ok, retry.name}
      else
        fail([%{retry | name: "failed again, alone"}], failures_or(retry.output, specs), deps)
      end
    else
      fail(failed, specs, deps)
    end
  end

  defp fail(failed, specs, deps) do
    Enum.each(failed, &deps.info.("#{&1.name}:\n" <> failure_text(&1.output)))
    deps.save_failed.(specs)
    unrun = Enum.flat_map(failed, &stopped_early/1)

    case {specs, unrun} do
      {[], []} -> {:error, "mix test ended without running its tests (#{Enum.map_join(failed, ", ", & &1.name)}); fix what it printed first"}
      {[], unrun} -> {:error, "tests did not run: " <> Enum.join(unrun, "; ")}
      {specs, []} -> {:error, failing(specs)}
      {specs, unrun} -> {:error, failing(specs) <> ". Tests did not run: " <> Enum.join(unrun, "; ")}
    end
  end

  defp failing(specs), do: "#{length(specs)} test(s) fail: #{Enum.join(specs, ", ")}. Fix the failing tests first; they run first next time"

  # What a part that left tests unrun says of itself: it stopped at `--max-failures`, or a
  # `setup_all` failed and ExUnit counted its tests as invalid.
  defp stopped_early(%{name: name, output: output}) do
    {tests, _failures, invalid} = counts(output) || {0, 0, 0}

    max_failures = if String.contains?(output, "--max-failures reached"), do: ["#{name} stopped at --max-failures after #{tests} tests, the rest of its tests did not run"], else: []
    setup_all = if invalid > 0, do: ["#{name} did not run #{invalid} tests, a setup_all failed" <> setup_all_failures(output)], else: []

    max_failures ++ setup_all
  end

  defp setup_all_failures(output) do
    case Regex.scan(~r/^ +\d+\) ([^\n]*): failure on setup_all callback/m, output, capture: :all_but_first) do
      [] -> ""
      modules -> " (" <> (modules |> List.flatten() |> Enum.uniq() |> Enum.join(", ")) <> ")"
    end
  end

  # Whether the numbered test failures are all that kept a part from passing. Not so for a part
  # that stopped at `--max-failures` (tests never ran), that did not run its tests at all (a
  # compile error), or that counts a failure with no test to run again (a `setup_all` that
  # failed and its invalid tests, a doctest).
  defp only_named_failures?(output) do
    named = length(failures(output))

    named > 0 and not String.contains?(output, "--max-failures reached") and match?({_tests, ^named, 0}, counts(output))
  end

  # `{tests, failures, invalid}` of the last summary line a `mix test` printed, or nil.
  defp counts(output) do
    case Regex.scan(~r/^(?:\d+ doctests?, )?(\d+) tests?, (\d+) failures?(?:, (\d+) invalid)?/m, output, capture: :all_but_first) do
      [] -> nil
      found -> found |> List.last() |> Enum.map(&String.to_integer/1) |> then(fn [tests, failures | invalid] -> {tests, failures, Enum.sum(invalid)} end)
    end
  end

  defp failures_or(output, specs) do
    case failures(output) do
      [] -> specs
      failures -> failures
    end
  end

  @doc """
  The failed tests of a `mix test` output, as `test/file_test.exs:line`, one per numbered failure.
  """
  @spec failures(String.t()) :: [String.t()]
  def failures(output) do
    ~r/^ +\d+\) test [^\n]*\n +(test\/[^\s:]+\.exs:\d+)/m |> Regex.scan(output, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  @doc """
  The failures of a `mix test` output as ExUnit printed them, without the lines before the first
  one or the progress dots (at most #{@failure_lines} lines); the last #{@tail_lines} lines of an
  output with no numbered failure (a compile error, a crash).
  """
  @spec failure_text(String.t()) :: String.t()
  def failure_text(output) do
    lines = String.split(output, "\n")

    numbered =
      lines
      |> Enum.drop_while(&(not Regex.match?(~r/^ +\d+\) test /, &1)))
      |> Enum.take_while(&(not String.starts_with?(&1, "Finished in ")))
      |> Enum.reject(&Regex.match?(~r/^[.*]+$/, &1))

    case numbered do
      [] -> lines |> Enum.take(-@tail_lines) |> Enum.join("\n") |> String.trim()
      numbered -> numbered |> Enum.take(@failure_lines) |> Enum.join("\n") |> String.trim_trailing()
    end
  end

  @doc """
  The number of tests a `mix test` output says ran (`12 tests, 0 failures`), 0 when it says none.
  """
  @spec test_count(String.t()) :: non_neg_integer()
  def test_count(output) do
    case counts(output) do
      nil -> 0
      {tests, _failures, _invalid} -> tests
    end
  end

  @doc """
  Spreads `tests` over parts that take about as long as each other: heaviest file first onto the
  lightest part, by the seconds `weights` records for each file. A file it doesn't list counts as
  an average one. `opts`: `:parts` sets the number of parts (never more than there are files) in
  place of `part_count/2`, whose ceiling is `:max_parts` (default #{@max_parts}).
  """
  @spec parts([Path.t()], %{Path.t() => number()}, keyword()) :: [[Path.t()]]
  def parts(tests, weights, opts \\ []) do
    average = if map_size(weights) == 0, do: 1.0, else: Enum.sum(Map.values(weights)) / map_size(weights)
    weighted = tests |> Enum.map(&{&1, Map.get(weights, &1, average)}) |> Enum.sort_by(fn {file, weight} -> {-weight, file} end)
    count = Keyword.get(opts, :parts) || part_count(Enum.map(weighted, &elem(&1, 1)), Keyword.get(opts, :max_parts, @max_parts))
    empty = for index <- 1..min(max(count, 1), length(tests))//1, do: {0, index, []}

    weighted
    |> Enum.reduce(empty, fn {file, weight}, loads ->
      [{load, index, files} | rest] = Enum.sort(loads)
      [{load + weight, index, [file | files]} | rest]
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {_load, _index, files} -> Enum.reverse(files) end)
  end

  @doc """
  How many parts a run whose test files take `weights` seconds is split into: the total over the
  length a part should have, rounded up, at most `max_parts`. A part runs its files one after the
  other, so the run never ends sooner than its heaviest file: the other parts aim at half of it,
  so that a file that takes longer than recorded doesn't make its part the last to end. And a
  part pays for its own `mix test` start, so none aims at less than #{@min_part_seconds} s of tests.
  """
  @spec part_count([number()], pos_integer()) :: pos_integer()
  def part_count([], _max_parts), do: 1

  def part_count(weights, max_parts) do
    (Enum.sum(weights) / max(Enum.max(weights) / 2, @min_part_seconds)) |> Float.ceil() |> trunc() |> max(1) |> min(max_parts)
  end

  @doc """
  The files changed since `base` forked: committed and uncommitted changes to tracked files
  (deletions excluded) and untracked files outside `.gitignore`, sorted.
  """
  @spec changed_files(String.t(), git_runner()) :: {:ok, [Path.t()]} | {:error, String.t()}
  def changed_files(base, git) do
    with {:ok, merge_base} <- git_step(git, ["merge-base", "HEAD", base], "find the merge-base with #{base}; fetch it first"),
         {:ok, tracked} <- git_step(git, ["diff", "--name-only", "--diff-filter=ACMR", String.trim(merge_base)], "diff"),
         {:ok, untracked} <- git_step(git, ["ls-files", "--others", "--exclude-standard"], "list untracked files") do
      {:ok, (lines(tracked) ++ lines(untracked)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc """
  The test files (`test/**/*_test.exs`) deleted since `base` forked, committed or not, each with its
  source at the merge-base, sorted by path.
  """
  @spec deleted_tests(String.t(), git_runner()) :: {:ok, [{Path.t(), String.t()}]} | {:error, String.t()}
  def deleted_tests(base, git) do
    with {:ok, merge_base} <- git_step(git, ["merge-base", "HEAD", base], "find the merge-base with #{base}; fetch it first"),
         merge_base = String.trim(merge_base),
         {:ok, deleted} <- git_step(git, ["diff", "--name-only", "--diff-filter=D", merge_base], "list deleted files") do
      deleted
      |> lines()
      |> Enum.filter(&(String.starts_with?(&1, "test/") and String.ends_with?(&1, "_test.exs")))
      |> Enum.sort()
      |> read_deleted(merge_base, git, [])
    end
  end

  defp read_deleted([], _merge_base, _git, acc), do: {:ok, Enum.reverse(acc)}

  defp read_deleted([path | rest], merge_base, git, acc) do
    with {:ok, source} <- git_step(git, ["show", "#{merge_base}:#{path}"], "read deleted #{path}") do
      read_deleted(rest, merge_base, git, [{path, source} | acc])
    end
  end

  # The app modules outside `changed` that a deleted test names, each with the first test naming it.
  defp named_modules(deleted, app_modules, changed) do
    changed_set = MapSet.new(changed, &elem(&1, 0))

    for {module, source} <- app_modules,
        not MapSet.member?(changed_set, module),
        {test, _test_source} <- [Enum.find(deleted, {nil, nil}, fn {_test, test_source} -> names?(test_source, inspect(module)) end)],
        test != nil,
        do: {{module, Path.relative_to_cwd(source)}, test}
  end

  defp git_step(git, args, action) do
    case git.(args) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> {:error, "git could not #{action} (git #{Enum.join(args, " ")}): #{String.trim(output)}"}
    end
  end

  defp lines(output), do: String.split(output, "\n", trim: true)

  @doc """
  The modules compiled from the changed `lib/*.ex` files, as `{module, file}` sorted by file then
  module. `modules` lists every module of the app with its source path.
  """
  @spec changed_modules([Path.t()], [{module(), Path.t()}]) :: [{module(), Path.t()}]
  def changed_modules(files, modules) do
    lib_files = files |> Enum.filter(&(String.starts_with?(&1, "lib/") and String.ends_with?(&1, ".ex"))) |> MapSet.new()

    modules
    |> Enum.map(fn {module, source} -> {module, Path.relative_to_cwd(source)} end)
    |> Enum.filter(fn {_module, file} -> MapSet.member?(lib_files, file) end)
    |> Enum.sort_by(fn {module, file} -> {file, inspect(module)} end)
  end

  @doc """
  Whether `ignore_modules` (modules or regexes matched against the inspected name) lists `module`.
  """
  @spec ignored?(module(), [module() | Regex.t()]) :: boolean()
  def ignored?(module, ignores) do
    Enum.any?(ignores, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      ignored -> ignored == module
    end)
  end

  # With no module to check, the tests are the ones a plain `mix test` of the change would run:
  # the changed test files and the tests of the changed `lib/` files.
  defp test_files(modules, files, extra_tests, deps) do
    all_tests = deps.test_files.()
    changed_tests = Enum.filter(files, &(&1 in all_tests))
    lib_files = Enum.uniq(Enum.map(modules, &elem(&1, 1)) ++ files)
    by_path = for "lib/" <> rest <- lib_files, Path.extname(rest) == ".ex", test = test_path(rest), test in all_tests, do: test
    by_name = if modules == [], do: [], else: Enum.filter(all_tests, &names_any?(deps.read_file.(&1), modules))

    Enum.uniq(extra_tests ++ changed_tests ++ by_path ++ by_name)
  end

  defp test_path(lib_path), do: "test/" <> Path.rootname(lib_path) <> "_test.exs"

  defp names_any?(source, modules) do
    Enum.any?(modules, fn {module, _file} -> names?(source, inspect(module)) end)
  end

  @doc """
  Whether test `source` names `module` (`"Mix.Tasks.Foo"`): in full, as a whole token, or as a
  member of a multi-alias such as `alias Mix.Tasks.{Bar, Foo}`. The prefix of a longer module name
  (`Mix.Tasks.Foo.Bar`) doesn't name it, nor does the head of a multi-alias (`alias Mix.Tasks.Foo.{A, B}`
  names `Mix.Tasks.Foo.A` and `Mix.Tasks.Foo.B`, not `Mix.Tasks.Foo`). The source is read as
  text, so a name in a string or a comment counts.
  """
  @spec names?(String.t(), String.t()) :: boolean()
  def names?(source, module) do
    {parent, last} =
      case String.split(module, ".") do
        [single] -> {nil, single}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
      end

    full = ~r/(?<![\w.])#{Regex.escape(module)}(?![\w]|\.[A-Z{])/
    multi = parent && ~r/(?<![\w.])#{Regex.escape(parent)}\.\{[^}]*(?<![\w.])#{Regex.escape(last)}(?![\w.])[^}]*\}/

    Regex.match?(full, source) or (multi != nil and Regex.match?(multi, source))
  end

  defp results(modules, coverage) do
    Enum.map(modules, fn {module, file} ->
      case Map.get(coverage, module, {:error, :no_coverage_data}) do
        {:ok, lines} -> Map.merge(%{module: module, file: file}, summarize(lines))
        {:error, reason} -> %{module: module, file: file, error: reason}
      end
    end)
  end

  @doc """
  Counts a module's lines from `:cover.analyse(module, :coverage, :line)` the way `mix test --cover`
  does: line 0 (generated code) doesn't count, and a line with several entries is covered when any
  of them ran. Returns the covered and total line counts and the uncovered line numbers.
  """
  @spec summarize(line_results()) :: %{covered: non_neg_integer(), lines: non_neg_integer(), uncovered: [pos_integer()]}
  def summarize(line_results) do
    by_line =
      Enum.reduce(line_results, %{}, fn
        {{_module, 0}, _counts}, acc -> acc
        {{_module, line}, {covered, _not_covered}}, acc -> Map.update(acc, line, covered > 0, &(&1 or covered > 0))
      end)

    uncovered = for {line, false} <- by_line, do: line

    %{covered: map_size(by_line) - length(uncovered), lines: map_size(by_line), uncovered: Enum.sort(uncovered)}
  end

  defp report(results, deps) do
    Enum.each(results, &deps.info.(describe(&1)))

    case Enum.reject(results, &full?/1) do
      [] ->
        deps.info.("every changed module is at 100.00%")
        :ok

      below ->
        {:error,
         "#{length(below)} changed module(s) below 100% coverage: " <>
           Enum.map_join(below, ", ", &inspect(&1.module)) <>
           ". Add tests that run the uncovered lines, or pass the test files that cover them: mix cover.changed <test files>"}
    end
  end

  defp full?(%{uncovered: []}), do: true
  defp full?(_result), do: false

  defp describe(%{error: reason} = result), do: "#{inspect(result.module)} (#{result.file}): no coverage data, #{inspect(reason)}"

  defp describe(%{uncovered: []} = result), do: "#{inspect(result.module)} #{percent(result)} (#{result.file})"

  defp describe(result) do
    "#{inspect(result.module)} #{percent(result)}, uncovered: " <> Enum.map_join(result.uncovered, ", ", &"#{result.file}:#{&1}")
  end

  defp percent(%{lines: 0}), do: "100.00%"
  defp percent(%{covered: covered, lines: lines}), do: :erlang.float_to_binary(covered / lines * 100, decimals: 2) <> "%"

  @doc """
  Every module of the app with the absolute path of the file it was compiled from.
  """
  @spec app_modules(atom()) :: [{module(), Path.t()}]
  def app_modules(app \\ :symphony_elixir) do
    _ = Application.load(app)
    {:ok, modules} = :application.get_key(app, :modules)

    Enum.map(modules, &{&1, List.to_string(&1.module_info(:compile)[:source])})
  end

  @doc """
  The repo's test files, `test/**/*_test.exs`, relative to the project root.
  """
  @spec all_test_files() :: [Path.t()]
  def all_test_files, do: Path.wildcard("test/**/*_test.exs")

  @doc """
  The seconds each test file took in the last recorded run of the suite
  (`test/support/test_weights.tsv`, written by `scripts/test-parts.sh --record`); empty without the file.
  """
  @spec test_weights(Path.t()) :: %{Path.t() => float()}
  def test_weights(path \\ "test/support/test_weights.tsv") do
    case File.read(path) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), [file, seconds] <- [String.split(line, "\t")], {weight, ""} <- [Float.parse(seconds)], into: %{}, do: {file, weight}

      {:error, _reason} ->
        %{}
    end
  end

  @doc false
  @spec default_deps() :: deps()
  def default_deps do
    %{
      git: &Runner.git/1,
      modules: &app_modules/0,
      test_files: &all_test_files/0,
      read_file: &File.read!/1,
      weights: &test_weights/0,
      failed_tests: &Runner.failed_tests/0,
      save_failed: &Runner.save_failed/1,
      run_parts: &Runner.run_parts/2,
      coverage: &Runner.coverage/2,
      info: &Mix.shell().info("cover.changed: " <> &1)
    }
  end
end
