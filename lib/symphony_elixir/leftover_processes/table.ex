defmodule SymphonyElixir.LeftoverProcesses.Table do
  @moduledoc """
  Reads the process table for `SymphonyElixir.LeftoverProcesses`: each process's
  pid, start time and command line from `ps`, and its working folder from
  `/proc/<pid>/cwd` on Linux or `lsof` elsewhere.
  """

  alias SymphonyElixir.LeftoverProcesses

  @type cmd_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  # `lstart` is five words, for example `Sat Oct  3 08:00:00 2026`.
  @ps_line ~r/^\s*(\d+)\s+(\S+\s+\S+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.*)$/

  @doc "Every process visible to this user, or an error when `ps` can't list them."
  @spec read(cmd_fun()) :: {:ok, [LeftoverProcesses.entry()]} | {:error, term()}
  def read(cmd \\ &System.cmd/3) do
    ps = System.find_executable("ps") || "/bin/ps"

    case cmd.(ps, ["-A", "-ww", "-o", "pid=,lstart=,args="], stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
      {output, 0} ->
        processes = parse_ps(output)
        cwds = cwds(Enum.map(processes, & &1.pid), cmd)
        {:ok, Enum.map(processes, &Map.put(&1, :cwd, Map.get(cwds, &1.pid)))}

      {output, status} ->
        {:error, {:ps_failed, status, String.trim(output)}}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc "Parses `ps -o pid=,lstart=,args=` output."
  @spec parse_ps(String.t()) :: [%{pid: pos_integer(), start_time: String.t(), command: String.t()}]
  def parse_ps(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(@ps_line, line) do
        [_line, pid, start_time, command] ->
          [%{pid: String.to_integer(pid), start_time: String.replace(start_time, ~r/\s+/, " "), command: String.trim(command)}]

        nil ->
          []
      end
    end)
  end

  @doc "Parses `lsof -Fpn -d cwd` output into a map of pid to working folder."
  @spec parse_lsof(String.t()) :: %{pos_integer() => String.t()}
  def parse_lsof(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, %{}}, fn
      "p" <> pid, {_pid, cwds} -> {parse_pid(pid), cwds}
      "n" <> path, {pid, cwds} when is_integer(pid) -> {pid, Map.put(cwds, pid, path)}
      _line, acc -> acc
    end)
    |> elem(1)
  end

  defp parse_pid(pid) do
    case Integer.parse(pid) do
      {pid, ""} -> pid
      _other -> nil
    end
  end

  defp cwds(pids, cmd) do
    if File.dir?("/proc/self"), do: proc_cwds(pids), else: lsof_cwds(cmd)
  end

  defp proc_cwds(pids) do
    Enum.reduce(pids, %{}, fn pid, cwds ->
      case File.read_link("/proc/#{pid}/cwd") do
        {:ok, cwd} -> Map.put(cwds, pid, cwd)
        {:error, _reason} -> cwds
      end
    end)
  end

  # lsof exits 1 when it can't read some processes; what it did read still counts.
  defp lsof_cwds(cmd) do
    case System.find_executable("lsof") do
      nil ->
        %{}

      lsof ->
        {output, _status} = cmd.(lsof, ["-nP", "-w", "-d", "cwd", "-Fpn"], stderr_to_stdout: false)
        parse_lsof(output)
    end
  end
end
