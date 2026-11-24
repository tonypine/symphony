defmodule SymphonyElixir.ChangedCoverage.Runner do
  @moduledoc """
  The git, `mix test` and `:cover` calls behind `mix cover.changed` (`SymphonyElixir.ChangedCoverage`)
  and `mix coverage.report` (`SymphonyElixir.CoverageReport`).

  It is also the coverage tool of the `mix test --cover` processes `mix cover.changed` starts
  (`start/2`, chosen in `mix.exs` when `SYMPHONY_COVER_MODULES` is set): it cover-compiles
  only the modules under check, where Mix's own tool cover-compiles the whole app in every process.

  Listed in `mix.exs`'s `test_coverage` `ignore_modules`: `coverage/2` restarts the `:cover`
  server, which inside a `mix test --cover` run would throw away the suite's own coverage.
  """

  # `:cover` comes from OTP's `:tools`, which Mix loads when a task needs it, not the app.
  @compile {:no_warn_undefined, :cover}

  @export_prefix "cover_changed_"
  @modules_env "SYMPHONY_COVER_MODULES"
  @out_dir "_build/test/cover_changed"
  @max_failures "10"
  # ExUnit runs 2 x cores of the tests that may run together, in every process. With several
  # parts that keeps every core so busy that the tests that measure time fail (`scripts/test-parts.sh`).
  @max_cases "2"
  @logs ["part-*.log", "retry.log"]

  @doc """
  Runs git in the current directory: `{:ok, stdout}`, or `{:error, message}` on a non-zero exit.
  Git's stderr goes to the terminal, so warnings never mix into the file lists. A repo's diff
  drivers stay off (`SymphonyElixir.GitConfigCommands.subcommand_args/1`).
  """
  @spec git([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(args) do
    case System.cmd("git", SymphonyElixir.GitConfigCommands.subcommand_args(args)) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, "exit status #{status}"}
    end
  end

  @doc """
  Runs each `{name, tests}` part as its own `mix test` in the test environment, all at once, and
  returns each one's exit status and output, in order. The output also stays in
  `#{@out_dir}/<name>.log`. With `modules`, a part runs with `--cover`, cover-compiles only them
  (`start/2`) and exports their coverage to `cover/#{@export_prefix}<name>.coverdata`. A part stops after
  #{@max_failures} failures, and with several parts each runs #{@max_cases} tests at a time
  (`TEST_MAX_CASES`, as in `scripts/test-parts.sh`).
  """
  @spec run_parts([{String.t(), [String.t()]}], [module()]) :: [SymphonyElixir.ChangedCoverage.part_result()]
  def run_parts(parts, modules) do
    File.mkdir_p!(@out_dir)
    # The logs of an earlier run's parts don't stay beside this run's.
    if match?([{"part-1", _tests} | _rest], parts), do: Enum.each(@logs, fn log -> @out_dir |> Path.join(log) |> Path.wildcard() |> Enum.each(&File.rm/1) end)
    max_cases = if length(parts) > 1, do: ["--max-cases", System.get_env("TEST_MAX_CASES", @max_cases)], else: []

    parts
    |> Task.async_stream(&run_part(&1, modules, max_cases), max_concurrency: length(parts), timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp run_part({name, tests}, modules, max_cases) do
    log = Path.join(@out_dir, name <> ".log")
    File.rm(coverdata(name))

    {cover, env} =
      case modules do
        [] -> {[], []}
        modules -> {["--cover", "--export-coverage", @export_prefix <> name], [{@modules_env, Enum.map_join(modules, ",", &Atom.to_string/1)}]}
      end

    args = ["test", "--max-failures", @max_failures] ++ max_cases ++ cover ++ tests
    {_log, status} = System.cmd("mix", args, env: [{"MIX_ENV", "test"} | env], into: File.stream!(log), stderr_to_stdout: true)

    %{name: name, status: status, output: File.read!(log)}
  end

  @doc """
  The coverage tool of a part (`mix.exs`'s `test_coverage` `tool`, see `mix help test`):
  cover-compiles the modules `#{@modules_env}` names, and returns the function Mix calls after the
  tests, which exports their coverage to `<output>/<export>.coverdata`.
  """
  @spec start(Path.t(), keyword()) :: (-> :ok)
  def start(_compile_path, opts) do
    Mix.ensure_application!(:tools)
    modules = @modules_env |> System.fetch_env!() |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
    _ = :cover.stop()
    {:ok, _pid} = :cover.start()
    :cover.local_only()

    case modules |> Enum.map(&:code.which/1) |> :cover.compile_beam() |> List.wrap() |> Enum.reject(&match?({:ok, _module}, &1)) do
      [] -> :ok
      failed -> Mix.raise("cover.changed: could not cover-compile #{inspect(failed)}")
    end

    output = Keyword.get(opts, :output, "cover")

    fn ->
      File.mkdir_p!(output)
      :ok = :cover.export(String.to_charlist(Path.join(output, "#{opts[:export]}.coverdata")))
    end
  end

  @doc """
  The tests that failed in the last run (`#{@out_dir}/failed.txt`), as `test/file_test.exs:line`,
  without those whose file is gone.
  """
  @spec failed_tests() :: [String.t()]
  def failed_tests do
    case File.read(failed_path()) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.filter(&File.exists?(String.replace(&1, ~r/:\d+$/, "")))
      {:error, _reason} -> []
    end
  end

  @doc """
  Records the tests that failed, for the next run to run first; none removes the record.
  """
  @spec save_failed([String.t()]) :: :ok
  def save_failed([]) do
    _ = File.rm(failed_path())
    :ok
  end

  def save_failed(specs) do
    File.mkdir_p!(@out_dir)
    File.write!(failed_path(), Enum.map_join(specs, "\n", & &1) <> "\n")
  end

  @doc """
  Reads the coverage the parts `names` exported (`run_parts/2`), merged, and returns
  `:cover.analyse(module, :coverage, :line)` for each module. Deletes every export of a
  `mix cover.changed` run afterwards, so a later `mix test.coverage` doesn't pick one up.
  """
  @spec coverage([module()], [String.t()]) :: %{module() => {:ok, list()} | {:error, term()}}
  def coverage(modules, names) do
    Mix.ensure_application!(:tools)
    _ = :cover.stop()
    {:ok, pid} = :cover.start()
    # `:cover` prints a notice for each analysis of imported data.
    {:ok, quiet} = StringIO.open("")
    Process.group_leader(pid, quiet)

    try do
      Enum.each(names, fn name -> :ok = :cover.import(String.to_charlist(coverdata(name))) end)
      Map.new(modules, &{&1, :cover.analyse(&1, :coverage, :line)})
    after
      :cover.stop()
      Enum.each(Path.wildcard(coverdata("*")), &File.rm/1)
    end
  end

  @doc """
  Imports every `.coverdata` file in `paths` (default `cover/*.coverdata`: CI's test partitions) into a fresh `:cover` server
  and returns `:cover.analyse(module, :coverage, :line)` of each module they cover, merged across
  the files.
  """
  @spec imported_coverage([Path.t()]) :: %{module() => list()}
  def imported_coverage(paths \\ Path.wildcard("cover/*.coverdata")) do
    Mix.ensure_application!(:tools)
    _ = :cover.stop()
    {:ok, pid} = :cover.start()
    {:ok, quiet} = StringIO.open("")
    Process.group_leader(pid, quiet)

    try do
      Enum.each(paths, fn path -> :ok = :cover.import(String.to_charlist(path)) end)

      for module <- :cover.imported_modules(),
          {:ok, lines} <- [:cover.analyse(module, :coverage, :line)],
          into: %{},
          do: {module, lines}
    after
      :cover.stop()
    end
  end

  defp failed_path, do: Path.join(@out_dir, "failed.txt")
  defp coverdata(name), do: Path.join("cover", @export_prefix <> name <> ".coverdata")
end
