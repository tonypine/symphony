defmodule SymphonyElixir.AgentPriority do
  @nice_increment 10

  @moduledoc """
  Starts agent subprocesses below Symphony's own CPU scheduling priority.

  The host is shared by every agent run, QA pass and workspace hook, and an
  agent can start CPU-bound children (a test flood, a busy loop). Each local
  agent is launched through `nice -n #{@nice_increment}`, so the agent and
  everything it starts, which inherit its niceness, yield the CPU to Symphony
  and to other runs instead of starving them.

  `nice` execs the agent in place, so the port's OS pid is still the agent's
  pid and its process group id. Where the OS refuses to lower the priority
  (sandboxes that deny `setpriority`), `nice` would still start the agent but
  print a warning into its output, so the agent is started unchanged instead
  and a warning is logged.
  """

  require Logger

  @type priority :: :lowered | :unchanged

  @doc "How much lower than Symphony's priority (higher niceness) agents run."
  @spec nice_increment() :: pos_integer()
  def nice_increment, do: @nice_increment

  @doc """
  The executable and arguments to pass to `Port.open/2` so that `executable`
  starts with `args` at a lower priority, and whether the priority is lowered.
  `lowerable?` is given the path of `nice` and says whether it can lower a
  process's priority here.
  """
  @spec command(String.t(), [charlist()], (String.t() -> boolean())) :: {charlist(), [charlist()], priority()}
  def command(executable, args, lowerable? \\ &lowerable?/1) when is_binary(executable) and is_list(args) do
    nice = System.find_executable("nice") || "/usr/bin/nice"

    if lowerable?.(nice) do
      nice_args = [~c"-n", Integer.to_charlist(@nice_increment), String.to_charlist(executable) | args]
      {String.to_charlist(nice), nice_args, :lowered}
    else
      {String.to_charlist(executable), args, :unchanged}
    end
  end

  @doc """
  Logs the pid, command and run id of an agent started through `command/3`.
  """
  @spec log_started(port(), String.t(), String.t() | nil, priority()) :: :ok
  def log_started(port, command, run_id, priority) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        context = "pid=#{os_pid} run_id=#{run_id || "none"} command=#{inspect(command)}"

        case priority do
          :lowered -> Logger.info("Started agent below Symphony's CPU priority nice_increment=#{@nice_increment} #{context}")
          :unchanged -> Logger.warning("Started agent at Symphony's CPU priority; the OS refused to lower it #{context}")
        end

      nil ->
        :ok
    end
  end

  defp lowerable?(nice) do
    true_executable = System.find_executable("true") || "/usr/bin/true"
    match?({"", 0}, System.cmd(nice, ["-n", Integer.to_string(@nice_increment), true_executable], stderr_to_stdout: true))
  end
end
