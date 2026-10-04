defmodule SymphonyElixir.QaAndroid.Emulator do
  @moduledoc """
  Runs the one headless Android emulator that Android QA passes share.

  The QA agent's sandbox cannot run an emulator (it needs the hypervisor, Mach
  ports, adb sockets and a lot of memory), so Symphony runs it on the host. The
  host is shared with agent runs, so at most one emulator runs, and only while a
  QA pass needs it.

  - A QA pass takes the emulator with `checkout/2` and gets its serial back; it
    gives it back with `checkin/2`, or by exiting. One pass holds it at a time;
    the others wait in turn, each until its own `:wait_ms` runs out
    (`{:lease_timeout, ms}`). A holder that checks out again gets the same lease.
  - The first checkout boots `auto_review.android.avd` with
    `<sdk_root>/emulator/emulator -no-window -no-audio -no-boot-anim -read-only
    -no-snapshot-save`, so QA never changes the AVD, and waits up to
    `boot_timeout_ms` for `sys.boot_completed`. A missing setting, SDK tool or AVD
    and a boot timeout each return their own error (see `t:error/0` and
    `error_message/1`).
  - Symphony's own adb server listens on a private port (`ANDROID_ADB_SERVER_PORT`,
    default #{15_037}) and the emulator on a fixed console port (default 5600).
    Every adb call goes to that server and `-s emulator-<port>` (see
    `adb_command/2`), so the operator's adb server and devices are never touched.
  - The emulator stops `idle_timeout_ms` after the last checkin, and when
    Symphony stops: `adb emu kill`, `adb kill-server`, then SIGTERM and SIGKILL to
    the processes it recorded (the emulator and its children, such as qemu, and
    the adb server). An emulator that exits on its own is marked down; the next
    checkout boots a new one.
  - Those processes, with their start times, are recorded in
    `<state root>/qa-android/emulator-processes.json`. On start the manager stops
    any of them still running as the same process (same pid and start time),
    left by a Symphony that crashed.

  The command runner, launcher, clock, timers and process table are injectable,
  so tests never start an emulator.
  """

  use GenServer, shutdown: 30_000

  require Logger

  alias SymphonyElixir.{Config, LeftoverProcesses, Paths}
  alias SymphonyElixir.QaDriver.Host

  # Outside 5554-5585, the range every adb server scans for emulators, so the
  # operator's adb server never picks this one up.
  @console_port 5600
  @adb_server_port 15_037
  @default_wait_ms 30 * 60_000
  @command_timeout_ms 30_000
  @adb_timeout_ms 10_000
  @poll_interval_ms 2_000
  @grace_ms 3_000
  @output_limit 4_000
  @emulator_flags ~w(-no-window -no-audio -no-boot-anim -read-only -no-snapshot-save)
  @log_context "qa_android_emulator"

  @type android :: %{
          avd: String.t() | nil,
          sdk_root: Path.t(),
          boot_timeout_ms: pos_integer(),
          idle_timeout_ms: pos_integer()
        }
  @type lease :: %{lease: reference(), serial: String.t(), adb: Path.t(), adb_server_port: pos_integer()}
  @type error ::
          :avd_not_configured
          | {:sdk_missing, Path.t()}
          | {:avd_missing, String.t()}
          | {:boot_timeout, pos_integer()}
          | {:start_failed, String.t()}
          | {:emulator_exited, integer()}
          | {:lease_timeout, non_neg_integer()}
          | :emulator_unavailable
  @type env :: [{charlist(), charlist()}]

  @doc """
  Starts the manager. Options: `:name`, `:android` (returns the
  `t:android/0` settings, default `Config.auto_review_android/2`), `:cmd` (runs a
  command, as `SymphonyElixir.QaDriver.Host.cmd/3`), `:launch` (starts the
  emulator, as `launch/3`), `:table` and `:signal` (as in
  `SymphonyElixir.LeftoverProcesses`), `:clock` (milliseconds), `:sleep`,
  `:send_after` (as `Process.send_after/3`), `:grace_ms`, `:pid_file`,
  `:console_port` and `:adb_server_port`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Takes the emulator for the calling process, booting it when it is down, and
  returns its lease. Waits while another process holds it, at most `:wait_ms`
  (default 30 minutes).
  """
  @spec checkout(GenServer.server(), keyword()) :: {:ok, lease()} | {:error, error()}
  def checkout(server \\ __MODULE__, opts \\ []) do
    case GenServer.whereis(server) do
      nil -> {:error, :emulator_unavailable}
      pid -> GenServer.call(pid, {:checkout, Keyword.get(opts, :wait_ms, @default_wait_ms)}, :infinity)
    end
  end

  @doc "Gives the emulator back. A lease that is no longer held is ignored."
  @spec checkin(GenServer.server(), lease()) :: :ok
  def checkin(server \\ __MODULE__, %{lease: lease}) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.call(pid, {:checkin, lease}, :infinity)
    end
  end

  @doc "The executable, arguments and environment of an adb call to the leased emulator."
  @spec adb_command(lease() | map(), [String.t()]) :: {Path.t(), [String.t()], env()}
  def adb_command(%{adb: adb, serial: serial, adb_server_port: port}, args) do
    {adb, ["-P", Integer.to_string(port), "-s", serial | args], [{~c"ANDROID_ADB_SERVER_PORT", ~c"#{port}"}]}
  end

  @doc "Explains an error to a QA agent, which reports the Android steps `blocked`."
  @spec error_message(error()) :: String.t()
  def error_message(:avd_not_configured), do: "auto_review.android.avd is not set in symphony.yml, so there is no emulator to boot."

  def error_message({:sdk_missing, path}),
    do: "The Android SDK tool #{path} is missing; install the SDK or fix auto_review.android.sdk_root."

  def error_message({:avd_missing, avd}),
    do: "The AVD #{avd} does not exist; create it in Android Studio's Device Manager or fix auto_review.android.avd."

  def error_message({:boot_timeout, ms}),
    do: "The emulator did not finish booting within #{ms} ms (auto_review.android.boot_timeout_ms)."

  def error_message({:start_failed, detail}), do: "The emulator could not start: #{detail}"
  def error_message({:emulator_exited, status}), do: "The emulator exited with status #{status} while booting."

  def error_message({:lease_timeout, ms}),
    do: "Another QA pass held the emulator for more than #{ms} ms; only one emulator runs at a time."

  def error_message(:emulator_unavailable), do: "The Android emulator manager is not running."

  @doc "Starts `executable` with `args` and `env` as a port owned by the caller."
  @spec launch(Path.t(), [String.t()], env()) :: {:ok, port(), pos_integer()} | {:error, String.t()}
  def launch(executable, args, env) do
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, args: args, env: env])
    {:os_pid, pid} = Port.info(port, :os_pid)
    {:ok, port, pid}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    console_port = Keyword.get(opts, :console_port, @console_port)

    config = %{
      android: Keyword.get(opts, :android, &default_android/0),
      cmd: Keyword.get(opts, :cmd, &Host.cmd/3),
      launch: Keyword.get(opts, :launch, &launch/3),
      table: Keyword.get_lazy(opts, :table, &LeftoverProcesses.default_table/0),
      signal: Keyword.get(opts, :signal, &LeftoverProcesses.signal/2),
      clock: Keyword.get(opts, :clock, &now_ms/0),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      send_after: Keyword.get(opts, :send_after, &Process.send_after/3),
      grace_ms: Keyword.get(opts, :grace_ms, @grace_ms),
      pid_file: Keyword.get_lazy(opts, :pid_file, &default_pid_file/0),
      serial: "emulator-#{console_port}",
      console_port: console_port,
      adb_server_port: Keyword.get(opts, :adb_server_port, @adb_server_port)
    }

    state = %{
      config: config,
      status: :down,
      sdk: nil,
      emulator: nil,
      processes: [],
      booter: nil,
      holder: nil,
      waiters: [],
      idle: nil,
      idle_ms: nil
    }

    {:ok, state, {:continue, :reap}}
  end

  @impl true
  def handle_continue(:reap, state) do
    with [_ | _] = recorded <- read_pid_file(state.config.pid_file) do
      Logger.warning("Stopping Android emulator processes a previous Symphony left running #{@log_context} pids=#{Enum.map_join(recorded, ",", & &1.pid)}")
      stop_processes(recorded, state.config)
    end

    File.rm(state.config.pid_file)
    {:noreply, state}
  end

  @impl true
  def handle_call({:checkout, wait_ms}, {pid, _tag} = from, state) do
    cond do
      match?(%{pid: ^pid}, state.holder) ->
        {:noreply, serve(put_in(state.holder.from, from))}

      state.holder == nil ->
        holder = %{pid: pid, from: from, monitor: Process.monitor(pid), lease: make_ref()}
        {:noreply, serve(%{state | holder: holder, idle: nil})}

      true ->
        token = make_ref()
        state.config.send_after.(self(), {:wait_timeout, token}, wait_ms)
        waiter = %{pid: pid, from: from, monitor: Process.monitor(pid), token: token, wait_ms: wait_ms}
        {:noreply, %{state | waiters: state.waiters ++ [waiter]}}
    end
  end

  def handle_call({:checkin, lease}, from, state) do
    case state.holder do
      %{lease: ^lease, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        # Handing the emulator to a waiter can boot it; the holder does not wait for that.
        GenServer.reply(from, :ok)
        {:noreply, next(%{state | holder: nil})}

      _other ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      match?(%{monitor: ^monitor}, state.holder) ->
        Logger.info("Android emulator lease holder exited; releasing the lease #{@log_context} holder=#{inspect(pid)}")
        {:noreply, next(%{state | holder: nil})}

      match?(%{monitor: ^monitor}, state.booter) ->
        {:noreply, fail(shutdown(%{state | booter: nil}), {:start_failed, "the boot check crashed: #{inspect(reason)}"})}

      true ->
        {:noreply, %{state | waiters: Enum.reject(state.waiters, &(&1.monitor == monitor))}}
    end
  end

  def handle_info({:wait_timeout, token}, state) do
    case Enum.split_with(state.waiters, &(&1.token == token)) do
      {[waiter], waiters} ->
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, {:error, {:lease_timeout, waiter.wait_ms}})
        {:noreply, %{state | waiters: waiters}}

      {[], _waiters} ->
        {:noreply, state}
    end
  end

  def handle_info({:idle_timeout, token}, %{idle: token} = state) do
    Logger.info("Stopping the idle Android emulator #{@log_context} serial=#{state.config.serial}")
    {:noreply, shutdown(state)}
  end

  def handle_info({:boot_processes, token, entries}, %{booter: %{token: token}} = state) do
    {:noreply, record(state, entries)}
  end

  def handle_info({:boot_result, token, {result, entries}}, %{booter: %{token: token, monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    state = record(%{state | booter: nil}, entries)

    case result do
      :ok ->
        Logger.info("Android emulator booted #{@log_context} serial=#{state.config.serial}")
        {:noreply, serve(%{state | status: :up})}

      {:error, reason} ->
        {:noreply, fail(shutdown(state), reason)}
    end
  end

  def handle_info({port, {:data, data}}, %{emulator: %{port: port} = emulator} = state) do
    {:noreply, %{state | emulator: %{emulator | output: tail(emulator.output <> data)}}}
  end

  def handle_info({port, {:exit_status, status}}, %{emulator: %{port: port} = emulator} = state) do
    Logger.warning("Android emulator exited #{@log_context} status=#{status} output=#{inspect(tail(emulator.output))}")
    was = state.status
    state = shutdown(%{state | emulator: nil})

    if was == :booting, do: {:noreply, fail(state, {:emulator_exited, status})}, else: {:noreply, state}
  end

  # Stale timers, port exits after a close, and port messages of an emulator that is gone.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    shutdown(state)
    :ok
  end

  # The holder gets the lease once the emulator is up.
  defp serve(%{holder: nil} = state), do: state

  defp serve(%{status: :up} = state) do
    %{holder: holder, config: config} = state
    GenServer.reply(holder.from, {:ok, %{lease: holder.lease, serial: config.serial, adb: state.sdk.adb, adb_server_port: config.adb_server_port}})
    %{state | holder: %{holder | from: nil}}
  end

  defp serve(%{status: :booting} = state), do: state
  defp serve(%{status: :down} = state), do: start(state)

  defp next(%{waiters: [waiter | waiters]} = state) do
    holder = %{pid: waiter.pid, from: waiter.from, monitor: waiter.monitor, lease: make_ref()}
    serve(%{state | holder: holder, waiters: waiters})
  end

  defp next(%{waiters: []} = state) do
    token = make_ref()
    if state.idle_ms, do: state.config.send_after.(self(), {:idle_timeout, token}, state.idle_ms)
    %{state | holder: nil, idle: token}
  end

  # A failed start is the holder's answer; the next waiter tries again.
  defp fail(state, reason) do
    Logger.warning("Android emulator unavailable #{@log_context} reason=#{inspect(reason)}")

    with %{from: from, monitor: monitor} <- state.holder do
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, {:error, reason})
    end

    next(%{state | holder: nil})
  end

  defp start(state) do
    android = state.config.android.()

    case preflight(android, state.config) do
      {:ok, sdk} -> launch_emulator(%{state | sdk: sdk, idle_ms: android.idle_timeout_ms}, android)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp preflight(%{avd: nil}, _config), do: {:error, :avd_not_configured}

  defp preflight(android, config) do
    sdk = %{
      root: android.sdk_root,
      emulator: Path.join([android.sdk_root, "emulator", "emulator"]),
      adb: Path.join([android.sdk_root, "platform-tools", "adb"])
    }

    with :ok <- sdk_tool(sdk.emulator),
         :ok <- sdk_tool(sdk.adb),
         :ok <- avd_listed(android.avd, sdk, config),
         :ok <- start_adb_server(sdk, config) do
      {:ok, sdk}
    end
  end

  defp sdk_tool(path), do: if(File.regular?(path), do: :ok, else: {:error, {:sdk_missing, path}})

  defp avd_listed(avd, sdk, config) do
    case config.cmd.(sdk.emulator, ["-list-avds"], timeout_ms: @command_timeout_ms, env: emulator_env(sdk, config)) do
      {:ok, {output, 0}} ->
        if avd in String.split(output, ~r/\s+/, trim: true), do: :ok, else: {:error, {:avd_missing, avd}}

      other ->
        {:error, {:start_failed, "emulator -list-avds failed: #{describe(other)}"}}
    end
  end

  defp start_adb_server(sdk, config) do
    case adb(config, sdk.adb, ["start-server"], @command_timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      other -> {:error, {:start_failed, "adb start-server failed: #{describe(other)}"}}
    end
  end

  defp launch_emulator(state, android) do
    %{config: config, sdk: sdk} = state
    args = ["-avd", android.avd, "-port", Integer.to_string(config.console_port) | @emulator_flags]

    case config.launch.(sdk.emulator, args, emulator_env(sdk, config)) do
      {:ok, port, os_pid} ->
        Logger.info("Starting the Android emulator #{@log_context} avd=#{android.avd} serial=#{config.serial} os_pid=#{os_pid}")
        state = %{state | status: :booting, emulator: %{port: port, os_pid: os_pid, output: ""}}
        %{state | booter: start_booter(state, os_pid, android.boot_timeout_ms)}

      {:error, reason} ->
        fail(shutdown(state), {:start_failed, "the emulator could not be launched: #{inspect(reason)}"})
    end
  end

  # Boot can take minutes, so it is awaited in another process and the manager
  # keeps answering checkouts, checkins and exits.
  defp start_booter(state, os_pid, timeout_ms) do
    %{config: config, sdk: %{adb: adb}} = state
    server = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(server, {:boot_processes, token, processes(config, os_pid)})
        result = await_boot(config, adb, config.clock.() + timeout_ms, timeout_ms)
        send(server, {:boot_result, token, {result, processes(config, os_pid)}})
      end)

    %{pid: pid, monitor: monitor, token: token}
  end

  defp await_boot(config, adb, deadline, timeout_ms) do
    cond do
      booted?(adb(config, adb, ["shell", "getprop", "sys.boot_completed"], @adb_timeout_ms)) ->
        :ok

      config.clock.() >= deadline ->
        {:error, {:boot_timeout, timeout_ms}}

      true ->
        config.sleep.(@poll_interval_ms)
        await_boot(config, adb, deadline, timeout_ms)
    end
  end

  defp booted?({:ok, {output, 0}}), do: String.trim(output) == "1"
  defp booted?(_result), do: false

  # The emulator, its children (qemu, crashpad) and this manager's adb server.
  defp processes(config, emulator_pid) do
    case config.table.() do
      {:ok, entries} ->
        tree = LeftoverProcesses.symphony_pids(entries, emulator_pid)
        adb_server = "tcp:#{config.adb_server_port}"

        Enum.filter(entries, fn entry ->
          MapSet.member?(tree, entry.pid) or (entry.command =~ "fork-server" and entry.command =~ adb_server)
        end)

      {:error, reason} ->
        Logger.warning("Could not read the process table to record the Android emulator #{@log_context}: #{inspect(reason)}")
        []
    end
  end

  defp record(state, []), do: state

  defp record(state, entries) do
    processes = Enum.uniq_by(state.processes ++ entries, & &1.pid)
    write_pid_file(state.config.pid_file, processes)
    %{state | processes: processes}
  end

  defp shutdown(%{sdk: nil} = state), do: state

  defp shutdown(state) do
    %{config: config, sdk: sdk, emulator: emulator} = state

    with %{pid: pid, monitor: monitor} <- state.booter do
      Process.demonitor(monitor, [:flush])
      Process.exit(pid, :kill)
    end

    if emulator, do: adb(config, sdk.adb, ["emu", "kill"], @adb_timeout_ms)
    adb(config, sdk.adb, ["kill-server"], @adb_timeout_ms)
    stop_processes(state.processes, config)

    with %{port: port, os_pid: os_pid} <- emulator do
      # Without a process table the emulator was never recorded.
      unless Enum.any?(state.processes, &(&1.pid == os_pid)), do: config.signal.(os_pid, "KILL")
      close(port)
    end

    File.rm(config.pid_file)
    Logger.info("Stopped the Android emulator #{@log_context} serial=#{config.serial}")
    %{state | status: :down, sdk: nil, emulator: nil, processes: [], booter: nil, idle: nil}
  end

  defp stop_processes([], _config), do: []

  defp stop_processes(entries, config) do
    LeftoverProcesses.stop_running(entries,
      table: config.table,
      signal: config.signal,
      grace_ms: config.grace_ms,
      log_context: @log_context
    )
  end

  # The port is already closed when the emulator exited.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> true
  end

  defp adb(config, adb, args, timeout_ms) do
    {executable, args, env} = adb_command(%{adb: adb, serial: config.serial, adb_server_port: config.adb_server_port}, args)
    config.cmd.(executable, args, timeout_ms: timeout_ms, env: env)
  end

  defp emulator_env(sdk, config) do
    root = String.to_charlist(sdk.root)
    [{~c"ANDROID_ADB_SERVER_PORT", ~c"#{config.adb_server_port}"}, {~c"ANDROID_HOME", root}, {~c"ANDROID_SDK_ROOT", root}]
  end

  defp describe({:ok, {output, status}}), do: "exit status #{status}: #{tail(String.trim(output))}"
  defp describe({:error, reason}), do: inspect(reason)

  defp tail(output) when byte_size(output) > @output_limit, do: binary_part(output, byte_size(output) - @output_limit, @output_limit)
  defp tail(output), do: output

  defp read_pid_file(path) do
    with {:ok, json} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(json) do
      for %{"pid" => pid, "start_time" => start_time} = entry <- entries, is_integer(pid) and pid > 0 and is_binary(start_time) do
        %{pid: pid, start_time: start_time, command: Map.get(entry, "command", "")}
      end
    else
      _missing_or_invalid -> []
    end
  end

  defp write_pid_file(path, processes) do
    json = Jason.encode!(Enum.map(processes, &Map.take(&1, [:pid, :start_time, :command])))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json) do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not record the Android emulator processes #{@log_context} path=#{path}: #{inspect(reason)}")
    end
  end

  defp default_android, do: Config.auto_review_android(Config.settings!())
  defp default_pid_file, do: Path.join([Paths.state_root(), "qa-android", "emulator-processes.json"])
  defp now_ms, do: System.monotonic_time(:millisecond)
end
