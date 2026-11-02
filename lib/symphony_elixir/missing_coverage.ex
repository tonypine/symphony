defmodule SymphonyElixir.MissingCoverage do
  @moduledoc """
  Names the uncovered lines of every module below 100% in exported coverage data.

  `mix test.coverage` fails with a table of percentages and no line numbers, so a partition-dependent
  gap in a module a change never touched can't be told from the log. This reads the same
  `cover/*.coverdata` files and returns one `Module path:line, path:line` description per module with
  uncovered lines.
  """

  alias SymphonyElixir.ChangedCoverage

  @compile {:no_warn_undefined, :cover}

  @type deps :: %{
          import: (charlist() -> term()),
          modules: (-> [module()]),
          analyse: (module() -> {:ok, list()} | {:error, term()}),
          source: (module() -> Path.t())
        }

  @doc """
  Imports every `*.coverdata` file in `dir` into `:cover` and describes each module with uncovered
  lines, skipping `ignore_modules` as `mix test.coverage` does. Returns `[]` when all are covered.
  """
  @spec describe(Path.t(), [module() | Regex.t()], deps()) :: [String.t()]
  def describe(dir, ignore_modules, deps \\ default_deps()) do
    dir
    |> Path.join("*.coverdata")
    |> Path.wildcard()
    |> Enum.each(&deps.import.(String.to_charlist(&1)))

    for module <- deps.modules.(),
        not ChangedCoverage.ignored?(module, ignore_modules),
        {:ok, lines} <- [deps.analyse.(module)],
        %{uncovered: uncovered} = ChangedCoverage.summarize(lines),
        uncovered != [] do
      "#{inspect(module)} uncovered: " <> Enum.map_join(uncovered, ", ", &"#{deps.source.(module)}:#{&1}")
    end
  end

  @doc false
  @spec default_deps() :: deps()
  def default_deps do
    # `:cover` comes from OTP's `:tools`, which Mix loads when a task needs it, not the app.
    Mix.ensure_application!(:tools)
    _ = :cover.start()

    %{
      import: &:cover.import/1,
      modules: &:cover.imported_modules/0,
      analyse: &:cover.analyse(&1, :coverage, :line),
      source: &(&1.module_info(:compile)[:source] |> List.to_string() |> Path.relative_to_cwd())
    }
  end
end
