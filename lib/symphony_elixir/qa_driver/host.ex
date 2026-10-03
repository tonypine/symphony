defmodule SymphonyElixir.QaDriver.Host do
  @moduledoc """
  The OS boundary of `SymphonyElixir.QaDriver`: timed commands, app launches,
  process kills and the compiled Swift helper.

  The helper source ships as `priv/qa_driver/symphony-qa-driver.swift` and is
  embedded at compile time (escript and Burrito builds drop `priv/`). On first use
  it is compiled with `swiftc` into `<state root>/qa-driver/<source hash>/`, so a
  new Symphony version builds a new helper and the old one is never reused.
  """

  alias SymphonyElixir.{AgentEnv, Paths, ProcessTree}

  @source_path Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "qa_driver", "symphony-qa-driver.swift"]))
  @external_resource @source_path
  @source File.read!(@source_path)
  @source_hash :sha256 |> :crypto.hash(@source) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  @compile_timeout_ms 300_000
  @quit_grace_ms 3_000

  @doc "The host functions `QaDriver` uses unless a test overrides them."
  @spec default() :: SymphonyElixir.QaDriver.host()
  def default do
    %{cmd: &cmd/3, launch: &launch/2, kill: &kill/1, helper: &helper/0}
  end

  @doc """
  Runs `executable` with `args` and collects its output. Options: `:cd`, `:env`,
  `:timeout_ms` (the process tree is killed when it runs out) and `:output_limit`
  (bytes kept from the end of the output).
  """
  @spec cmd(String.t(), [String.t()], keyword()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def cmd(executable, args, opts) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
      |> put_opt(:cd, Keyword.get(opts, :cd))
      |> put_opt(:env, Keyword.get(opts, :env))

    port = Port.open({:spawn_executable, executable}, port_opts)
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout_ms)
    collect(port, "", Keyword.get(opts, :output_limit, 8_000), deadline)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp collect(port, output, limit, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        output = output <> data
        output = if byte_size(output) > limit, do: binary_part(output, byte_size(output) - limit, limit), else: output
        collect(port, output, limit, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, {output, status}}
    after
      remaining ->
        os_pid = Port.info(port, :os_pid)
        ProcessTree.terminate_port_descendants(port)
        close(port)

        with {:os_pid, pid} <- os_pid, do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        {:error, :timeout}
    end
  end

  # The port may already be closed when its process exited during the timeout.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> true
  end

  @doc "Starts `executable` as a port owned by the caller. Options: `:cd`, `:env`."
  @spec launch(String.t(), keyword()) :: {:ok, port(), pos_integer()} | {:error, term()}
  def launch(executable, opts) do
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, cd: opts[:cd], env: opts[:env]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    {:ok, port, pid}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Asks the process to quit (SIGTERM), then kills it and its children after a grace period."
  @spec kill(pos_integer()) :: :ok
  def kill(pid) do
    pid_arg = Integer.to_string(pid)
    System.cmd("kill", ["-TERM", pid_arg], stderr_to_stdout: true)

    unless wait_for_exit(pid_arg, @quit_grace_ms) do
      ProcessTree.terminate_descendants(pid)
      System.cmd("kill", ["-KILL", pid_arg], stderr_to_stdout: true)
    end

    :ok
  end

  defp wait_for_exit(_pid_arg, remaining) when remaining <= 0, do: false

  defp wait_for_exit(pid_arg, remaining) do
    case System.cmd("kill", ["-0", pid_arg], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(100)
        wait_for_exit(pid_arg, remaining - 100)

      _gone ->
        true
    end
  end

  @doc "Path to the compiled Swift helper, compiling it on first use."
  @spec helper() :: {:ok, Path.t()} | {:error, term()}
  def helper do
    dir = Path.join([Paths.state_root(), "qa-driver", @source_hash])
    binary = Path.join(dir, "symphony-qa-driver")

    if File.regular?(binary), do: {:ok, binary}, else: compile(dir, binary)
  end

  defp compile(dir, binary) do
    source = Path.join(dir, "symphony-qa-driver.swift")
    staging = binary <> ".#{System.unique_integer([:positive])}"

    with swiftc when is_binary(swiftc) <- System.find_executable("swiftc") || {:error, :swiftc_not_found},
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(source, @source),
         {:ok, {_output, 0}} <- cmd(swiftc, ["-O", "-o", staging, source], env: AgentEnv.build(), timeout_ms: @compile_timeout_ms),
         :ok <- File.rename(staging, binary) do
      {:ok, binary}
    else
      {:ok, {output, status}} -> {:error, {:swiftc_failed, status, String.slice(output, -2_000, 2_000)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]
end
