defmodule SymphonyElixir.GitHub.Relay do
  @moduledoc """
  One `gh webhook forward` for one repository: GitHub's deliveries for it reach Symphony's
  `POST /api/v1/github/webhook` on `127.0.0.1` through the GitHub CLI's webhook extension.

  The extension creates the repository's forwarding hook when it starts, so GitHub pings it, and
  holds a websocket to GitHub. GitHub lets one person forward a repository at a time; a second
  forwarder fails with `Hook already exists`. When the connection drops the extension retries
  three times, 5 seconds apart, then exits ("unable to connect to webhooks server, forwarding
  stopped"); a normal close exits 0. So any exit counts as a drop: the relay starts it again after
  1 s, doubling the wait up to 5 minutes while it keeps failing, and counts each restart and its
  last error for health (`status/1`). A run that lasted a minute starts the wait over at 1 s.

  The secret reaches `gh` as `--secret`: the extension reads it from no environment variable and
  no standard input, so while the relay runs its command line (`ps`) shows it to any local process.
  It is scrubbed from everything the relay keeps or logs.
  """

  use GenServer, restart: :transient

  require Logger

  alias SymphonyElixir.{ProcessTree, Secret}

  @min_backoff_ms 1_000
  @max_backoff_ms 300_000
  @stable_ms 60_000
  @output_bytes 4_000
  @error_chars 300

  @type spec :: %{
          repo_key: String.t(),
          repo: String.t(),
          events: [String.t()],
          url: String.t(),
          secret: Secret.t()
        }

  @type status :: %{
          state: :running | :restarting,
          restarts: non_neg_integer(),
          failures: non_neg_integer(),
          last_error: String.t() | nil,
          started_at: DateTime.t() | nil
        }

  @doc """
  Starts the relay for `opts[:spec]`. `opts`: `:name`, `:executable` (else `gh` on `PATH`),
  `:timer` (`fn ms, message -> ref end`, else `Process.send_after/3` to itself), `:clock`
  (monotonic milliseconds) and `:utc_now` (when it started, for its status).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The arguments `gh` runs the relay with."
  @spec args(spec()) :: [String.t()]
  def args(spec) do
    ["webhook", "forward", "--repo", spec.repo, "--events", Enum.join(spec.events, ","), "--url", spec.url, "--secret", Secret.unwrap(spec.secret)]
  end

  @doc "How long the relay waits before its `failures`th restart in a row: 1 s, doubling, at most 5 minutes."
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(failures) when is_integer(failures) and failures > 0 do
    min(@min_backoff_ms * Integer.pow(2, min(failures - 1, 20)), @max_backoff_ms)
  end

  @doc "Whether it runs, how many times it restarted and why it last stopped."
  @spec status(GenServer.server(), timeout()) :: status()
  def status(server, timeout \\ 5_000), do: GenServer.call(server, :status, timeout)

  @doc "Stops the running `gh` and starts it again at once (a test delivery: the new hook is pinged)."
  @spec restart(GenServer.server()) :: :ok
  def restart(server), do: GenServer.call(server, :restart)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    me = self()

    state = %{
      spec: Keyword.fetch!(opts, :spec),
      executable: Keyword.get_lazy(opts, :executable, fn -> System.find_executable("gh") end),
      timer: Keyword.get(opts, :timer, fn ms, message -> Process.send_after(me, message, ms) end),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      utc_now: Keyword.get(opts, :utc_now, &DateTime.utc_now/0),
      port: nil,
      os_pid: nil,
      began: nil,
      started_at: nil,
      output: "",
      restarts: 0,
      failures: 0,
      last_error: nil,
      timer_ref: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{state: if(state.port, do: :running, else: :restarting), restarts: state.restarts, failures: state.failures, last_error: state.last_error, started_at: state.started_at}, state}
  end

  def handle_call(:restart, _from, state) do
    state = state |> stop_port() |> cancel_timer()
    {:reply, :ok, start(%{state | restarts: state.restarts + 1})}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = scrub(state.output <> data, state.spec)
    kept = min(byte_size(output), @output_bytes)
    {:noreply, %{state | output: binary_part(output, byte_size(output) - kept, kept)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    error = last_line(state.output) || "gh webhook forward stopped (exit status #{status})"
    {:noreply, dropped(%{state | port: nil, os_pid: nil}, error)}
  end

  def handle_info(:start, state), do: {:noreply, start(%{state | timer_ref: nil, restarts: state.restarts + 1})}

  # A port this relay already closed, or its link.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = stop_port(state)
    :ok
  end

  defp start(%{executable: nil} = state), do: dropped(state, "The GitHub CLI (gh) isn't installed.")

  defp start(state) do
    port = Port.open({:spawn_executable, state.executable}, [:binary, :exit_status, :stderr_to_stdout, :hide, args: args(state.spec)])
    os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid
    %{state | port: port, os_pid: os_pid, began: state.clock.(), started_at: state.utc_now.(), output: ""}
  rescue
    error in ErlangError -> dropped(state, "gh webhook forward didn't start: #{Exception.message(error)}")
  end

  defp dropped(state, error) do
    ran_ms = if state.began, do: state.clock.() - state.began, else: 0
    failures = if ran_ms >= @stable_ms, do: 1, else: state.failures + 1
    wait_ms = backoff_ms(failures)
    error = error |> scrub(state.spec) |> String.slice(0, @error_chars)

    Logger.warning("GitHub relay for repo=#{state.spec.repo_key} github=#{state.spec.repo} stopped: #{error}; starting it again in #{wait_ms} ms")

    %{state | began: nil, failures: failures, last_error: error, timer_ref: state.timer.(wait_ms, :start)}
  end

  defp stop_port(%{port: nil} = state), do: state

  defp stop_port(%{port: port, os_pid: os_pid} = state) do
    ProcessTree.terminate_port_descendants(port)
    if is_integer(os_pid), do: System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    %{state | port: nil, os_pid: nil, began: nil}
  end

  defp cancel_timer(%{timer_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp cancel_timer(state), do: %{state | timer_ref: nil}

  defp last_line(output) do
    output
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end

  @doc "`text` with the relay's secret replaced, so no log or status carries it."
  @spec scrub(String.t(), spec()) :: String.t()
  def scrub(text, %{secret: secret}) do
    case Secret.unwrap(secret) do
      value when is_binary(value) and value != "" -> String.replace(text, value, "[secret]")
      _none -> text
    end
  end
end
