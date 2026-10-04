defmodule SymphonyElixir.ChangedCoverage do
  @moduledoc """
  Checks the line coverage of the `lib/` modules a branch changes, before a push, so a branch
  that misses one line fails here instead of in CI's 100% `coverage report`.

  Finds the files changed since the merge-base with the base branch (committed, uncommitted and
  untracked), the modules compiled from the changed `lib/` files, and the test files for them: the
  changed test files, `test/<path>_test.exs` for `lib/<path>.ex`, and every test file that names
  the module. It runs those tests once with `--cover` and fails when a changed module, outside
  `mix.exs`'s `test_coverage` `ignore_modules`, has a line they don't run.

  `mix cover.changed` runs it. The git, test and `:cover` calls go through `deps`, so tests can
  fake them; `SymphonyElixir.ChangedCoverage.Runner` holds the real ones.
  """

  alias SymphonyElixir.ChangedCoverage.Runner

  @type git_runner :: ([String.t()] -> {:ok, String.t()} | {:error, String.t()})
  @type line_results :: [{{module(), non_neg_integer()}, {non_neg_integer(), non_neg_integer()}}]
  @type deps :: %{
          git: git_runner(),
          modules: (-> [{module(), Path.t()}]),
          test_files: (-> [Path.t()]),
          read_file: (Path.t() -> String.t()),
          run_tests: ([Path.t()] -> :ok | {:error, String.t()}),
          coverage: ([module()] -> %{module() => {:ok, line_results()} | {:error, term()}}),
          info: (String.t() -> any())
        }

  @doc """
  Runs the check. `opts`: `:base` (default `origin/main`), `:ignore_modules` (modules or regexes)
  and `:extra_tests` (test files to run as well). Returns `:ok`, or `{:error, message}` naming
  what failed.
  """
  @spec run(keyword(), deps()) :: :ok | {:error, String.t()}
  def run(opts, deps) do
    base = Keyword.get(opts, :base, "origin/main")
    ignores = Keyword.get(opts, :ignore_modules, [])

    with {:ok, files} <- changed_files(base, deps.git) do
      {ignored, checked} = files |> changed_modules(deps.modules.()) |> Enum.split_with(&ignored?(elem(&1, 0), ignores))
      Enum.each(ignored, fn {module, _file} -> deps.info.("skipped #{inspect(module)}: in mix.exs test_coverage ignore_modules") end)
      check(checked, files, Keyword.get(opts, :extra_tests, []), deps)
    end
  end

  defp check([], _files, _extra_tests, deps) do
    deps.info.("no changed lib/ module to check")
    :ok
  end

  defp check(modules, files, extra_tests, deps) do
    case test_files(modules, files, extra_tests, deps) do
      [] ->
        {:error,
         "no test file found for #{Enum.map_join(modules, ", ", &inspect(elem(&1, 0)))}. " <>
           "Pass the test files that cover them: mix cover.changed <test files>"}

      tests ->
        deps.info.("running #{length(tests)} test file(s) with --cover:\n" <> Enum.map_join(tests, "\n", &"  #{&1}"))

        with :ok <- deps.run_tests.(tests) do
          modules |> results(deps.coverage.(Enum.map(modules, &elem(&1, 0)))) |> report(deps)
        end
    end
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

  defp test_files(modules, files, extra_tests, deps) do
    all_tests = deps.test_files.()
    changed_tests = Enum.filter(files, &(&1 in all_tests))
    by_path = modules |> Enum.map(fn {_module, "lib/" <> rest} -> "test/" <> Path.rootname(rest) <> "_test.exs" end) |> Enum.filter(&(&1 in all_tests))
    by_name = Enum.filter(all_tests, &names_any?(deps.read_file.(&1), modules))

    Enum.uniq(extra_tests ++ changed_tests ++ by_path ++ by_name)
  end

  defp names_any?(source, modules) do
    Enum.any?(modules, fn {module, _file} -> names?(source, inspect(module)) end)
  end

  @doc """
  Whether test `source` names `module` (`"Mix.Tasks.Foo"`): in full, not as the prefix of a longer
  module name, or as a member of a multi-alias such as `alias Mix.Tasks.{Bar, Foo}`.
  """
  @spec names?(String.t(), String.t()) :: boolean()
  def names?(source, module) do
    {parent, last} =
      case String.split(module, ".") do
        [single] -> {nil, single}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
      end

    full = ~r/(?<![\w.])#{Regex.escape(module)}(?![\w]|\.[A-Z])/
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

  @doc false
  @spec default_deps() :: deps()
  def default_deps do
    %{
      git: &Runner.git/1,
      modules: &app_modules/0,
      test_files: &all_test_files/0,
      read_file: &File.read!/1,
      run_tests: &Runner.run_tests/1,
      coverage: &Runner.coverage/1,
      info: &Mix.shell().info("cover.changed: " <> &1)
    }
  end
end
