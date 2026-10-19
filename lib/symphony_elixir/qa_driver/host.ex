defmodule SymphonyElixir.QaDriver.Host do
  @moduledoc """
  Timed commands on this host, and the sources Symphony compiles on a QA host.

  `SymphonyElixir.QaDriver` never builds or runs a PR's app here: it drives a QA
  host through `SymphonyElixir.QaDriver.Remote`, which runs its SSH sessions with
  `cmd/3`, as the Android QA driver runs `adb`. Remote compiles the Swift helper
  (`priv/qa_driver/symphony-qa-driver.swift`) and builds the appearance library
  (`priv/qa_driver/symphony-qa-appearance.m` with `build-appearance.sh`) in each
  pass's run directory there, from the sources embedded here at compile time
  (escript builds drop `priv/`).
  """

  alias SymphonyElixir.ProcessTree

  @source_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "qa_driver"]))
  @source_path Path.join(@source_dir, "symphony-qa-driver.swift")
  @external_resource @source_path
  @source File.read!(@source_path)
  @appearance_source_path Path.join(@source_dir, "symphony-qa-appearance.m")
  @appearance_build_path Path.join(@source_dir, "build-appearance.sh")
  @external_resource @appearance_source_path
  @external_resource @appearance_build_path
  @appearance_source File.read!(@appearance_source_path)
  @appearance_build File.read!(@appearance_build_path)

  @doc "The Swift helper's source."
  @spec helper_source() :: String.t()
  def helper_source, do: @source

  @doc "The appearance library's Objective-C source and the shell script that builds it."
  @spec appearance_source() :: {String.t(), String.t()}
  def appearance_source, do: {@appearance_source, @appearance_build}

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

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]
end
