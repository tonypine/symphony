defmodule Mix.Tasks.PrWatch.Sweep do
  use Mix.Task

  @shortdoc "Map Symphony's skipped dispatches and silent waits to the PR and CI decision table"

  @moduledoc """
  Lists every `Skipping dispatch` / `Not dispatching` line and silent wait in Symphony's log, maps
  each to the decision table rule that holds the ticket, a dispatch gate that is no PR case, or
  `no rule` (`SymphonyElixir.PrWatch.Sweep`), and prints the count per rule, then `no rule: N` and
  each line no rule covers: a case for a new table row.

  Usage:

      mix pr_watch.sweep [--since 7d] [--log PATH]...

  Without `--log` it sweeps this host's Symphony: the log file and the rotated ones next to it, in
  the logs folder and its `release` folder (`SymphonyElixir.Paths.logs_root/0`), and the silent
  waits the running Symphony lists now, from its run store (`GET /api/v1/state`). `--log` sweeps
  only the files it names, such as a saved log. `--since` counts only the lines of the last days,
  hours or minutes (`7d`, `12h`, `30m`); without it every line counts.
  """

  @requirements ["compile"]

  alias SymphonyElixir.Paths
  alias SymphonyElixir.PrWatch.Sweep

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [since: :string, log: :keep, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      true -> sweep(opts)
    end
  end

  defp sweep(opts) do
    since = since(opts[:since])
    named = Keyword.get_values(opts, :log)
    files = if named == [], do: host_logs(), else: Enum.map(named, &existing!/1)
    {silent_now, store} = if named == [], do: silent_now(), else: {[], nil}

    lines = Stream.flat_map(files, fn path -> path |> File.stream!() |> Stream.map(&String.replace_invalid/1) end)
    report = Sweep.sweep(lines, since: since, silent_now: silent_now)
    shell = Mix.shell()
    Enum.each(Sweep.format(report, sources(files, since, store)), &shell.info/1)
  end

  defp since(nil), do: nil

  defp since(value) do
    case Regex.run(~r/\A(\d+)([dhm])\z/, value) do
      [_match, amount, unit] -> DateTime.add(DateTime.utc_now(), -String.to_integer(amount) * seconds(unit), :second)
      nil -> Mix.raise("Invalid --since #{inspect(value)}: use days, hours or minutes, such as 7d, 12h or 30m")
    end
  end

  defp seconds("d"), do: 86_400
  defp seconds("h"), do: 3_600
  defp seconds("m"), do: 60

  defp existing!(path) do
    if File.regular?(path), do: path, else: Mix.raise("No log file at #{path}")
  end

  # The log file and its rotated files (`symphony.log.1` and on), where a checkout and a release
  # of Symphony write them.
  defp host_logs do
    root = Paths.logs_root()

    files =
      for dir <- [root, Path.join(root, "release")],
          path <- [Path.join(dir, "symphony.log") | Path.wildcard(Path.join(dir, "symphony.log.[0-9]*"))],
          File.regular?(path),
          do: path

    if files == [], do: Mix.shell().info("No Symphony log under #{root}")
    files
  end

  # The silent waits the running Symphony lists now, from its run store.
  defp silent_now do
    case control_client().state([]) do
      {:ok, state} ->
        {Map.get(state, "silent_waits") || [], "the running Symphony's run store"}

      other ->
        Mix.shell().info("The running Symphony's run store couldn't be read (#{inspect(other)}): silent waits come from the log only")
        {[], nil}
    end
  end

  defp sources(files, since, store) do
    logs = if files == [], do: "no log", else: Enum.map_join(files, ", ", &Path.basename/1)
    window = if since, do: " since #{DateTime.to_iso8601(DateTime.truncate(since, :second))}", else: ""
    Enum.join(Enum.reject([logs <> window, store], &is_nil/1), " and ")
  end

  defp control_client, do: Application.get_env(:symphony_elixir, :control_client, SymphonyElixir.ControlClient)
end
