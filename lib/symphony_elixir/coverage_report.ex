defmodule SymphonyElixir.CoverageReport do
  @moduledoc """
  CI's `coverage report`: the merge of the test partitions' coverage, with the uncovered lines of
  every module below 100% and the change each one is blamed on.

  It reads the merged coverage of every module (outside `mix.exs`'s `test_coverage`
  `ignore_modules`), prints each module below 100% with its file and uncovered line numbers, and
  fails when one of them is the change's fault:

  - Without `:base` (a push to main), every module below 100% fails.
  - With `:base` (a pull request: the merge commit's first parent), a module below 100% fails when
    the pull request touches it: it changes the module's file, or changes or deletes a test file
    that names it (`SymphonyElixir.ChangedCoverage.names?/2`). One it doesn't touch fails when main's
    baseline (`:baseline`, written by main's last green report with `:write_baseline`) doesn't have
    it at 100%: it was short on main already, new, or there is no baseline. A module the pull
    request doesn't touch and main had at 100% is a warning, not the pull request's failure: the
    merge step or a flaky test lost its lines, and it gets its own ticket.

  With `:annotate` each module below 100% is also printed as a GitHub Actions `::error` or
  `::warning` annotation on its file, naming the lines, so the check's annotations carry them.

  `mix coverage.report` runs it. The `:cover`, git and file calls go through `deps`, so tests can
  fake them; `SymphonyElixir.ChangedCoverage.Runner` holds the real `:cover` one.
  """

  alias SymphonyElixir.ChangedCoverage

  @type result :: %{
          module: module(),
          file: String.t() | nil,
          covered: non_neg_integer(),
          lines: non_neg_integer(),
          uncovered: [pos_integer()]
        }
  @type deps :: %{
          coverage: (-> %{module() => ChangedCoverage.line_results()}),
          modules: (-> [{module(), Path.t()}]),
          git: ChangedCoverage.git_runner(),
          read_file: (Path.t() -> {:ok, String.t()} | {:error, term()}),
          write_file: (Path.t(), String.t() -> :ok | {:error, term()}),
          info: (String.t() -> any()),
          print: (String.t() -> any())
        }

  @doc """
  Runs the report. `opts`: `:base` (the ref the pull request is diffed against; nil for main),
  `:baseline` (main's baseline file to read), `:write_baseline` (where to write this run's),
  `:annotate` (print GitHub annotations) and `:ignore_modules`. Returns `:ok`, or
  `{:error, message}` naming the modules that fail.
  """
  @spec run(keyword(), deps()) :: :ok | {:error, String.t()}
  def run(opts, deps) do
    results = results(deps.coverage.(), deps.modules.(), Keyword.get(opts, :ignore_modules, []))
    short = Enum.reject(results, &(&1.uncovered == []))

    Enum.each(short, &deps.info.(describe(&1)))
    deps.info.("#{length(results) - length(short)} of #{length(results)} modules at 100.00%")

    with {:ok, blame} <- blame(short, opts, deps),
         :ok <- write_baseline(Keyword.get(opts, :write_baseline), results, deps) do
      {failing, excused} = Enum.split_with(short, &(Map.fetch!(blame, &1.module) != :excused))

      Enum.each(excused, &deps.info.("warning: #{inspect(&1.module)} is below 100% but this change doesn't touch it and main had it at 100%: not this change's failure"))
      Enum.each(failing, &deps.info.("#{inspect(&1.module)} fails the gate: #{reason(Map.fetch!(blame, &1.module))}"))

      if Keyword.get(opts, :annotate, false) do
        Enum.each(excused, &deps.print.(annotation("warning", &1, "not this change's: main had it at 100% and this change doesn't touch it")))
        Enum.each(failing, &deps.print.(annotation("error", &1, reason(Map.fetch!(blame, &1.module)))))
      end

      verdict(failing)
    end
  end

  defp verdict([]), do: :ok

  defp verdict(failing) do
    {:error, "#{length(failing)} module(s) below 100% coverage, their uncovered lines above: " <> Enum.map_join(failing, ", ", &inspect(&1.module))}
  end

  @doc """
  Each covered module outside `ignores`, sorted by name, with its file (relative to the project
  root; nil when `modules` doesn't know it) and its covered, total and uncovered lines.
  """
  @spec results(%{module() => ChangedCoverage.line_results()}, [{module(), Path.t()}], [module() | Regex.t()]) ::
          [result()]
  def results(coverage, modules, ignores) do
    files = Map.new(modules, fn {module, source} -> {module, Path.relative_to_cwd(source)} end)

    coverage
    |> Enum.reject(fn {module, _lines} -> ChangedCoverage.ignored?(module, ignores) end)
    |> Enum.map(fn {module, lines} -> Map.merge(%{module: module, file: Map.get(files, module)}, ChangedCoverage.summarize(lines)) end)
    |> Enum.sort_by(&inspect(&1.module))
  end

  # Baseline

  defp write_baseline(nil, _results, _deps), do: :ok

  defp write_baseline(path, results, deps) do
    modules = Map.new(results, &{inspect(&1.module), %{"file" => &1.file, "uncovered" => &1.uncovered}})

    case deps.write_file.(path, Jason.encode!(%{"modules" => modules}, pretty: true)) do
      :ok ->
        deps.info.("wrote the coverage baseline to #{path}")
        :ok

      {:error, reason} ->
        {:error, "could not write the coverage baseline to #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Main's baseline read from `path`: the names of the modules it had at 100%. `:none` when there is
  no readable baseline, so no module is excused.
  """
  @spec read_baseline(Path.t() | nil, deps()) :: MapSet.t(String.t()) | :none
  def read_baseline(nil, _deps), do: :none

  def read_baseline(path, deps) do
    with {:ok, json} <- deps.read_file.(path),
         {:ok, %{"modules" => %{} = modules}} <- Jason.decode(json) do
      for {name, %{"uncovered" => []}} <- modules, into: MapSet.new(), do: name
    else
      _missing_or_invalid ->
        deps.info.("no coverage baseline from main at #{path}: every module below 100% fails")
        :none
    end
  end

  # Blame

  defp blame([], _opts, _deps), do: {:ok, %{}}

  defp blame(short, opts, deps) do
    case Keyword.get(opts, :base) do
      nil ->
        {:ok, Map.new(short, &{&1.module, :main})}

      base ->
        with {:ok, files} <- ChangedCoverage.changed_files(base, deps.git),
             {:ok, deleted} <- ChangedCoverage.deleted_tests(base, deps.git) do
          tests = changed_tests(files, deps) ++ Enum.map(deleted, &elem(&1, 1))
          baseline = read_baseline(Keyword.get(opts, :baseline), deps)
          {:ok, Map.new(short, &{&1.module, blame_one(&1, files, tests, baseline)})}
        end
    end
  end

  defp changed_tests(files, deps) do
    for file <- files,
        String.starts_with?(file, "test/"),
        String.ends_with?(file, ".exs"),
        {:ok, source} <- [deps.read_file.(file)],
        do: source
  end

  defp blame_one(result, files, tests, baseline) do
    name = inspect(result.module)

    cond do
      result.file != nil and result.file in files -> :touched
      Enum.any?(tests, &ChangedCoverage.names?(&1, name)) -> :test_touched
      baseline == :none -> :no_baseline
      MapSet.member?(baseline, name) -> :excused
      true -> :short_on_main
    end
  end

  defp reason(:main), do: "every module must be at 100% on main"
  defp reason(:touched), do: "this change edits its file"
  defp reason(:test_touched), do: "this change edits or deletes a test file that names it"
  defp reason(:no_baseline), do: "there is no coverage baseline from main to tell whether it was at 100% there"
  defp reason(:short_on_main), do: "main's last green report did not have it at 100% either"

  # Output

  @doc """
  One module below 100%: its name, percentage, file and uncovered lines.
  """
  @spec describe(result()) :: String.t()
  def describe(result) do
    "#{inspect(result.module)} #{percent(result)} (#{result.file || "file unknown"}), uncovered lines: #{Enum.join(result.uncovered, ", ")}"
  end

  @doc """
  A GitHub Actions annotation (`level` is `error` or `warning`) on the module's first uncovered line,
  naming every uncovered line and `why`.
  """
  @spec annotation(String.t(), result(), String.t()) :: String.t()
  def annotation(level, result, why) do
    location = if result.file, do: ["file=#{escape(result.file, ~w(: ,))}", "line=#{hd(result.uncovered)}"], else: []
    title = escape("Coverage #{inspect(result.module)} #{percent(result)}", ~w(: ,))
    message = escape("uncovered lines #{Enum.join(result.uncovered, ", ")} of #{result.file || inspect(result.module)}: #{why}", [])

    "::#{level} #{Enum.join(location ++ ["title=#{title}"], ",")}::#{message}"
  end

  # Workflow commands read `%` as an escape, and `:` and `,` end a property.
  defp escape(text, property_chars) do
    text = String.replace(text, "%", "%25")
    Enum.reduce(property_chars, text, &String.replace(&2, &1, %{":" => "%3A", "," => "%2C"}[&1]))
  end

  defp percent(%{covered: covered, lines: lines}), do: :erlang.float_to_binary(covered / lines * 100, decimals: 2) <> "%"

  @doc false
  @spec default_deps() :: deps()
  def default_deps do
    %{
      coverage: &ChangedCoverage.Runner.imported_coverage/0,
      modules: &ChangedCoverage.app_modules/0,
      git: &ChangedCoverage.Runner.git/1,
      read_file: &File.read/1,
      write_file: &File.write/2,
      info: &Mix.shell().info("coverage.report: " <> &1),
      print: &Mix.shell().info(&1)
    }
  end
end
