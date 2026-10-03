defmodule SymphonyElixir.QaDriver.Host do
  @moduledoc """
  The OS boundary of `SymphonyElixir.QaDriver`: timed commands, app launches,
  process kills and the Swift helper app, `SymphonyQADriver.app`.

  Screen Recording and Accessibility are granted to the helper app only. macOS
  gives every process an app spawns that app's grants, so a grant on Symphony.app
  (or the terminal running Symphony) would reach every coding agent too. The
  helper is therefore never spawned from here: it is opened through LaunchServices
  (`open -a`), which makes it its own responsible process, and it answers over a
  Unix socket, only to this Symphony process and only about processes this
  Symphony process started.

  The socket lives in a fixed `0700` run directory,
  `~/Library/Application Support/symphony/qa-driver/run`, that agent sandboxes
  cannot write, whatever the state root. Before opening the helper, Symphony
  leaves `qa-<pid>.owner` there. The helper serves only an owner whose file it
  finds, and removes the file, so an agent cannot open a helper that serves it,
  or plant a socket that answers this process.

  Symphony.app ships the helper signed at `Contents/Helpers/SymphonyQADriver.app`
  and passes its path in `SYMPHONY_QA_DRIVER_APP`, so a grant survives app
  updates. Without it (Symphony run from a terminal) the helper source, which
  ships as `priv/qa_driver/` and is embedded at compile time (escript and Burrito
  builds drop `priv/`), is compiled with `swiftc` on first use and signed ad hoc
  into `<state root>/qa-driver/<source hash>/`, so a new helper source builds a
  new helper that needs a new grant.
  """

  alias SymphonyElixir.{AgentEnv, Paths, ProcessTree}

  @source_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "qa_driver"]))
  @source_path Path.join(@source_dir, "symphony-qa-driver.swift")
  @plist_path Path.join(@source_dir, "Info.plist")
  @external_resource @source_path
  @external_resource @plist_path
  @source File.read!(@source_path)
  @plist File.read!(@plist_path)
  @source_hash :sha256 |> :crypto.hash(@source <> @plist) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  @app_name "SymphonyQADriver.app"
  @executable "symphony-qa-driver"
  @app_env "SYMPHONY_QA_DRIVER_APP"
  @compile_timeout_ms 300_000
  @quit_grace_ms 3_000
  @helper_start_ms 15_000
  @socket_path_limit 103
  @run_dir ["Library", "Application Support", "symphony", "qa-driver", "run"]

  @doc "The host functions `QaDriver` uses unless a test overrides them."
  @spec default() :: SymphonyElixir.QaDriver.host()
  def default do
    %{cmd: &cmd/3, launch: &launch/2, kill: &kill/1, helper: &helper/0, call_helper: &call_helper/3}
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

  @doc """
  Path to the helper app: Symphony.app's signed copy when `SYMPHONY_QA_DRIVER_APP`
  names one, else a copy compiled and signed ad hoc on first use.
  """
  @spec helper() :: {:ok, Path.t()} | {:error, term()}
  def helper do
    case System.get_env(@app_env) do
      app when is_binary(app) and app != "" -> if File.dir?(app), do: {:ok, app}, else: {:error, {:qa_driver_app_missing, app}}
      _unset -> compiled_helper()
    end
  end

  defp compiled_helper do
    dir = Path.join([Paths.state_root(), "qa-driver", @source_hash])
    app = Path.join(dir, @app_name)

    if File.dir?(app), do: {:ok, app}, else: compile(dir, app)
  end

  defp compile(dir, app) do
    staging = app <> ".#{System.unique_integer([:positive])}"
    contents = Path.join(staging, "Contents")
    source = Path.join(dir, "symphony-qa-driver.swift")

    with swiftc when is_binary(swiftc) <- System.find_executable("swiftc") || {:error, :swiftc_not_found},
         :ok <- File.mkdir_p(Path.join(contents, "MacOS")),
         :ok <- File.write(source, @source),
         :ok <- File.write(Path.join(contents, "Info.plist"), @plist),
         {:ok, {_output, 0}} <-
           cmd(swiftc, ["-O", "-o", Path.join([contents, "MacOS", @executable]), source], env: AgentEnv.build(), timeout_ms: @compile_timeout_ms),
         {:ok, {_output, 0}} <- cmd("/usr/bin/codesign", ["--force", "--sign", "-", staging], timeout_ms: @compile_timeout_ms) do
      publish(staging, app)
    else
      {:ok, {output, status}} ->
        File.rm_rf(staging)
        {:error, {:helper_build_failed, status, String.slice(output, -2_000, 2_000)}}

      {:error, reason} ->
        File.rm_rf(staging)
        {:error, reason}
    end
  end

  # Another QA pass may have published the same helper first.
  defp publish(staging, app) do
    case File.rename(staging, app) do
      :ok ->
        {:ok, app}

      {:error, reason} ->
        File.rm_rf(staging)
        if File.dir?(app), do: {:ok, app}, else: {:error, reason}
    end
  end

  @doc """
  Runs one helper command (`args`) in the helper app, opening the app first when
  it is not running yet. Returns the command's output and exit status like
  `cmd/3`. Options: `:timeout_ms` and `:output_limit`.
  """
  @spec call_helper(Path.t(), [String.t()], keyword()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def call_helper(app, args, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout_ms)

    with {:ok, socket_path} <- socket_path(),
         {:ok, socket} <- helper_socket(app, socket_path) do
      try do
        request(socket, args, Keyword.get(opts, :output_limit, 8_000), deadline)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  # One helper per Symphony process, in the run directory the helper accepts.
  # Never a temporary directory: agents can write there.
  defp socket_path do
    dir = Path.join([System.user_home!() | @run_dir])
    path = Path.join(dir, "qa-#{System.pid()}.sock")

    if byte_size(path) <= @socket_path_limit, do: private_dir(dir, path), else: {:error, {:socket_path_too_long, path}}
  end

  defp private_dir(dir, path) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(dir) do
      {:ok, path}
    else
      {:ok, _stat} -> {:error, {:unsafe_socket_dir, dir}}
      {:error, reason} -> {:error, {:socket_dir, dir, reason}}
    end
  end

  defp helper_socket(app, socket_path) do
    case connect(socket_path) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> :global.trans({__MODULE__, self()}, fn -> start_helper(app, socket_path) end, [node()])
    end
  end

  # Under the lock another caller may have opened the helper already. The helper
  # removes the owner file when it accepts it; one it never read goes here.
  defp start_helper(app, socket_path) do
    owner_file = Path.rootname(socket_path) <> ".owner"

    with {:error, _reason} <- connect(socket_path),
         :ok <- File.write(owner_file, ""),
         :ok <- File.chmod(owner_file, 0o600) do
      args = ["-g", "-j", "-n", "-a", app, "--args", "serve", socket_path, System.pid()]

      result =
        case System.cmd("/usr/bin/open", args, stderr_to_stdout: true) do
          {_output, 0} -> wait_for_helper(socket_path, System.monotonic_time(:millisecond) + @helper_start_ms)
          {output, status} -> {:error, {:open_failed, status, String.trim(output)}}
        end

      File.rm(owner_file)
      result
    end
  end

  defp wait_for_helper(socket_path, deadline) do
    case connect(socket_path) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:helper_not_started, reason}}
        else
          Process.sleep(100)
          wait_for_helper(socket_path, deadline)
        end
    end
  end

  defp connect(socket_path) do
    :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false, packet: :raw], 1_000)
  end

  defp request(socket, args, limit, deadline) do
    with :ok <- :gen_tcp.send(socket, [Jason.encode!(%{"args" => args}), "\n"]),
         {:ok, reply} <- receive_reply(socket, "", deadline),
         {:ok, %{"status" => status, "output" => output}} when is_integer(status) and is_binary(output) <- Jason.decode(reply) do
      output = if byte_size(output) > limit, do: binary_part(output, byte_size(output) - limit, limit), else: output
      {:ok, {output, status}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :helper_reply_unreadable}
    end
  end

  # The helper closes the connection after its one reply line. It closes it
  # without a reply when it does not answer this process.
  defp receive_reply(socket, reply, deadline) do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, data} -> receive_reply(socket, reply <> data, deadline)
      {:error, :closed} when reply != "" -> {:ok, reply}
      {:error, :closed} -> {:error, :helper_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: [{key, value} | opts]
end
