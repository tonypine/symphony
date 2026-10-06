defmodule SymphonyElixir.Verification.DevServer do
  @moduledoc false

  use GenServer
  require Logger

  alias SymphonyElixir.{AgentCaches, AgentEnv, AgentTmpDir}
  alias SymphonyElixir.Config.Schema.Verification.DevServer, as: DevServerConfig
  alias SymphonyElixir.Verification
  alias SymphonyElixir.Verification.{DevServerSandbox, EgressProxy, PortPool}

  @port_line_bytes 1_048_576
  @launcher_argv_env "SYMPHONY_DEV_SERVER_ARGV"
  @launcher_marker "__SYMPHONY_DEV_SERVER_PGID__"
  @health_poll_interval_ms 250
  @tmp_dir_prefix "symphony-dev-server-"
  @no_proxy "localhost,127.0.0.1,::1"

  defstruct [
    :run_id,
    :port,
    :workspace,
    :config,
    :port_handle,
    :os_pid,
    :pgid,
    :process_group?,
    :owner_ref,
    :tmp_dir,
    :proxy,
    sandbox_dirs: [],
    stopping?: false
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          port: pos_integer(),
          workspace: Path.t(),
          config: DevServerConfig.t(),
          port_handle: port() | nil,
          os_pid: integer() | nil,
          pgid: integer() | nil,
          process_group?: boolean(),
          owner_ref: reference() | nil,
          tmp_dir: Path.t() | nil,
          proxy: pid() | nil,
          sandbox_dirs: [Path.t()],
          stopping?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run_id = Keyword.get(opts, :run_id, make_ref())

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: :infinity,
      type: :worker
    }
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.call(pid, :stop, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    run_id = Keyword.fetch!(opts, :run_id)
    port = Keyword.fetch!(opts, :port)
    workspace = Keyword.fetch!(opts, :workspace)
    config = Keyword.fetch!(opts, :config)
    env = Keyword.get(opts, :env, [])
    launcher = Keyword.get(opts, :launcher, &launcher_executable/0)
    owner = Keyword.get(opts, :owner)
    owner_ref = if is_pid(owner), do: Process.monitor(owner)
    sandbox = Keyword.get_lazy(opts, :sandbox, &sandbox_opts/0)
    tmp_bases = Keyword.get_lazy(opts, :tmp_bases, &tmp_bases/0)

    case AgentTmpDir.create(AgentTmpDir.paths(@tmp_dir_prefix, run_id, tmp_bases)) do
      {:ok, tmp_dir} ->
        state = %__MODULE__{
          run_id: run_id,
          port: port,
          workspace: workspace,
          config: config,
          owner_ref: owner_ref,
          tmp_dir: tmp_dir
        }

        proxy_opts = [allowed_domains: Keyword.get(opts, :allowed_domains, []), run_id: run_id] ++ Keyword.get(opts, :egress_proxy, [])

        with {:ok, state} <- start_egress_proxy(state, proxy_opts) do
          start_dev_server(state, env, launcher, sandbox)
        end

      :error ->
        {:stop, {:verification_failed, :dev_server_tmp_dir_unavailable}}
    end
  end

  defp start_egress_proxy(state, proxy_opts) do
    case EgressProxy.start_link(proxy_opts) do
      {:ok, proxy} ->
        {:ok, %{state | proxy: proxy}}

      {:error, reason} ->
        Logger.warning("Verification dev server egress proxy unavailable run_id=#{state.run_id} reason=#{inspect(reason)}")
        File.rm_rf(state.tmp_dir)
        {:stop, {:verification_failed, {:egress_proxy_unavailable, reason}}}
    end
  end

  defp start_dev_server(%__MODULE__{config: config} = state, env, launcher, sandbox) do
    case sandbox_command(config.start_cmd, state, sandbox) do
      {:ok, argv, sandbox_dirs} ->
        run_dev_server(%{state | sandbox_dirs: sandbox_dirs}, argv, env, launcher)

      {:error, reason} ->
        release_resources(state)
        {:stop, {:verification_failed, reason}}
    end
  end

  defp run_dev_server(%__MODULE__{run_id: run_id, port: port, config: config, workspace: workspace} = state, argv, env, launcher) do
    case start_process(argv, workspace, child_env(env, state), launcher) do
      {:ok, port_handle, metadata} ->
        state = %{state | port_handle: port_handle, os_pid: metadata.os_pid, pgid: metadata.pgid, process_group?: metadata.process_group?}

        :ok =
          PortPool.record_dev_server_started(run_id, %{
            dev_server_os_pid: metadata.os_pid,
            dev_server_pgid: metadata.pgid
          })

        health_url = Verification.interpolate_port(config.health_check_url, port)

        case wait_for_health(health_url, config.health_timeout_ms) do
          :ok ->
            Logger.info("Verification dev server healthy run_id=#{run_id} port=#{port} url=#{health_url}")
            {:ok, state}

          {:error, reason} ->
            Logger.warning("Verification dev server failed health check run_id=#{run_id} port=#{port} url=#{health_url} reason=#{inspect(reason)}")
            stop_process(state)
            release_resources(state)
            {:stop, {:verification_failed, reason}}
        end

      {:error, reason} ->
        release_resources(state)
        {:stop, {:verification_failed, reason}}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = %{state | stopping?: true}
    stop_process(state)
    # Stopped: `terminate/2` only releases the resources.
    {:stop, :normal, :ok, %{state | port_handle: nil}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{owner_ref: ref} = state) do
    Logger.warning("Verification dev server owner exited run_id=#{state.run_id} reason=#{inspect(reason)}")
    {:stop, {:owner_down, reason}, state}
  end

  def handle_info({port_handle, {:exit_status, _status}}, %{port_handle: port_handle, stopping?: true} = state) do
    {:noreply, %{state | port_handle: nil, os_pid: nil, pgid: nil}}
  end

  def handle_info({port_handle, {:exit_status, status}}, %{port_handle: port_handle} = state) do
    Logger.warning("Verification dev server exited run_id=#{state.run_id} status=#{status}")
    {:stop, {:dev_server_exit, status}, %{state | port_handle: nil, os_pid: nil, pgid: nil}}
  end

  # Without its proxy the dev server can't fetch a dependency, so it stops too.
  def handle_info({:EXIT, proxy, reason}, %{proxy: proxy} = state) do
    Logger.warning("Verification dev server egress proxy exited run_id=#{state.run_id} reason=#{inspect(reason)}")
    {:stop, {:egress_proxy_down, reason}, state}
  end

  def handle_info({_port_handle, {:data, _data}}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_process(state)
    release_resources(state)
    :ok
  end

  defp sandbox_opts, do: Application.get_env(:symphony_elixir, :verification_dev_server_sandbox, [])

  defp tmp_bases, do: Application.get_env(:symphony_elixir, :agent_run_tmp_bases) || AgentTmpDir.default_bases()

  # Called once the dev server's process group is gone, so no sandbox mounts over its folders.
  defp release_resources(%{tmp_dir: tmp_dir, proxy: proxy, sandbox_dirs: sandbox_dirs}) do
    EgressProxy.stop(proxy)
    File.rm_rf(tmp_dir)
    Enum.each(sandbox_dirs, &File.rmdir/1)
    :ok
  end

  # The launcher stays outside the sandbox only to start a process group; its child execs
  # `sandbox-exec`, which applies the profile before the start command runs, or on Linux a
  # shell that runs the socat bridges to the sandbox's loopback and `bwrap`.
  defp sandbox_command(command, %{workspace: workspace} = state, sandbox) do
    sandbox = [port: state.port, proxy_port: EgressProxy.port(state.proxy)] ++ sandbox
    DevServerSandbox.command(command, workspace, state.tmp_dir, sandbox)
  end

  # The agent's env: the host's tokens and agent sockets are left out, the tool caches point
  # at the agent cache folder, and HTTP(S) goes through the egress proxy.
  defp child_env(env, %{tmp_dir: tmp_dir, proxy: proxy}) do
    proxy_url = "http://127.0.0.1:#{EgressProxy.port(proxy)}"

    Map.merge(AgentCaches.env(), %{
      Verification.env_var() => verification_port(env),
      "TMPDIR" => tmp_dir,
      "HTTP_PROXY" => proxy_url,
      "HTTPS_PROXY" => proxy_url,
      "http_proxy" => proxy_url,
      "https_proxy" => proxy_url,
      "NO_PROXY" => @no_proxy,
      "no_proxy" => @no_proxy
    })
  end

  defp start_process(argv, workspace, env, launcher) when is_binary(workspace) and is_function(launcher, 0) do
    case launcher.() do
      {:ok, executable, args, launcher_env, process_group?} ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Enum.map(args, &String.to_charlist/1),
              cd: String.to_charlist(workspace),
              env:
                env
                |> Map.merge(Map.new(launcher_env))
                |> Map.put(@launcher_argv_env, Jason.encode!(argv))
                |> AgentEnv.build_with(),
              line: @port_line_bytes
            ]
          )

        metadata = launcher_metadata(port, process_group?)

        if metadata.process_group? do
          {:ok, port, metadata}
        else
          close_port(port)
          {:error, :process_group_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp launcher_executable do
    cond do
      python = System.find_executable("python3") ->
        {:ok, python, ["-c", python_launcher()], [], true}

      python = System.find_executable("python") ->
        {:ok, python, ["-c", python_launcher()], [], true}

      true ->
        {:error, :python_not_found}
    end
  end

  defp python_launcher do
    [
      "import json, os, sys",
      "argv = json.loads(os.environ.pop(#{inspect(@launcher_argv_env)}))",
      "pid = os.fork()",
      "if pid == 0:",
      "    process_group = 0",
      "    try:",
      "        os.setsid()",
      "        process_group = 1",
      "    except OSError:",
      "        pass",
      "    print(#{inspect(@launcher_marker)} + '=' + str(os.getpid()) + ':' + str(process_group), flush=True)",
      "    os.execv(argv[0], argv)",
      "pid, status = os.waitpid(pid, 0)",
      "if os.WIFEXITED(status):",
      "    sys.exit(os.WEXITSTATUS(status))",
      "if os.WIFSIGNALED(status):",
      "    sys.exit(128 + os.WTERMSIG(status))",
      "sys.exit(1)"
    ]
    |> Enum.join("\n")
  end

  defp verification_port(env) do
    env_var = Verification.env_var()

    env
    |> Enum.find_value(fn
      {^env_var, value} -> value
      _entry -> nil
    end)
    |> to_string()
  end

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp launcher_metadata(port, true) when is_port(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        parse_launcher_metadata(to_string(line), port)

      {^port, {:data, line}} ->
        parse_launcher_metadata(to_string(line), port)

      {^port, {:exit_status, _status}} ->
        %{os_pid: port_os_pid(port), pgid: port_os_pid(port), process_group?: false}
    after
      1_000 ->
        os_pid = port_os_pid(port)
        %{os_pid: os_pid, pgid: os_pid, process_group?: false}
    end
  end

  defp launcher_metadata(port, false) when is_port(port) do
    os_pid = port_os_pid(port)
    %{os_pid: os_pid, pgid: os_pid, process_group?: false}
  end

  defp parse_launcher_metadata(line, port) do
    marker = @launcher_marker <> "="

    if String.starts_with?(line, marker) do
      line
      |> String.replace_prefix(marker, "")
      |> String.split(":", parts: 2)
      |> case do
        [pid, "1"] -> %{os_pid: parse_pid(pid), pgid: parse_pid(pid), process_group?: true}
        [pid, _process_group] -> %{os_pid: parse_pid(pid), pgid: parse_pid(pid), process_group?: false}
        _ -> fallback_launcher_metadata(port)
      end
    else
      fallback_launcher_metadata(port)
    end
  end

  defp fallback_launcher_metadata(port) do
    os_pid = port_os_pid(port)
    %{os_pid: os_pid, pgid: os_pid, process_group?: false}
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {pid, ""} -> pid
      _ -> nil
    end
  end

  defp wait_for_health(url, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_health(url, deadline)
  end

  defp poll_health(url, deadline) do
    case health_ok?(url) do
      true ->
        :ok

      false ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :health_timeout}
        else
          Process.sleep(min(@health_poll_interval_ms, max(1, deadline - now)))
          poll_health(url, deadline)
        end
    end
  end

  defp health_ok?(url) do
    case Req.get(url, receive_timeout: @health_poll_interval_ms, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _exception -> false
  end

  defp stop_process(%{port_handle: nil}), do: :ok

  defp stop_process(%{config: config, port_handle: port_handle} = state) do
    case signal_target(state) do
      nil ->
        close_port(port_handle)

      target ->
        send_signal(target, config.stop_signal)

        if process_alive?(target, config.stop_timeout_ms) do
          send_signal(target, "KILL")
          wait_until_stopped(target, 1_000)
        end

        close_port(port_handle)
    end
  end

  defp signal_target(%{process_group?: true, pgid: pgid}) when is_integer(pgid), do: -pgid
  defp signal_target(%{os_pid: os_pid}) when is_integer(os_pid), do: os_pid
  defp signal_target(_state), do: nil

  defp process_alive?(target, timeout_ms) do
    case wait_until_stopped(target, timeout_ms) do
      :stopped -> false
      :alive -> true
    end
  end

  defp wait_until_stopped(_target, timeout_ms) when timeout_ms <= 0, do: :alive

  defp wait_until_stopped(target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_stopped(target, deadline)
  end

  defp do_wait_until_stopped(target, deadline) do
    if alive_target?(target) do
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        :alive
      else
        Process.sleep(min(100, max(1, deadline - now)))
        do_wait_until_stopped(target, deadline)
      end
    else
      :stopped
    end
  end

  # `--` keeps a group's `-<pgid>` an operand: procps-ng's `kill` reads it as an option and
  # signals `-<first digit>` instead, exiting 0.
  defp alive_target?(target) when is_integer(target) do
    case System.cmd("kill", ["-0", "--", to_string(target)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp send_signal(target, signal) when is_integer(target) and is_binary(signal) do
    System.cmd("kill", ["-#{signal}", "--", to_string(target)], stderr_to_stdout: true)
    :ok
  rescue
    _exception -> :ok
  end

  defp close_port(port_handle) when is_port(port_handle) do
    Port.close(port_handle)
  rescue
    _exception -> :ok
  end
end
