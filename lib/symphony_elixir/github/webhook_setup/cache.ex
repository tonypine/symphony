defmodule SymphonyElixir.GitHub.WebhookSetup.Cache do
  @moduledoc """
  The last `github_updates` section (`SymphonyElixir.GitHub.WebhookSetup`), so `GET /api/v1/state`
  reads it rather than build it. Building it asks git for each repository's GitHub name, the run
  store for the setup record, each repository's health and GitHub's rate limit, and each relay for
  its status; the app polls the state every 5 seconds, and a dev server's health check may give
  each poll 250 ms. `GET /api/v1/setup`, which the app reads while a test delivery is on its way
  and which answers 503 while the configuration can't be read, still builds it on each request.

  It builds the section in a task, so reading never waits on it: at start, after a config reload
  (once per save), on `refresh/1` (after each verified delivery, which may complete a test), and
  every `interval_ms` (5 s by default) for what changes with time or without saying so (a relay's
  restarts, a repository's health, the rate limit, a test's 30 s wait). A setup action hands it
  the section it answered with (`put/2`), so the next poll shows what the action did, and a build
  that started before it is dropped. The repositories, which run git, are read at start and after
  each config reload only.

  Every call names the server in `opts[:cache]` (this module by default). Without a running server
  (a test, a one-off command), or before its first build ends, a read builds the section here and
  now with `opts`, and `put/2` and `refresh/1` do nothing.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config.Cache, as: ConfigCache
  alias SymphonyElixir.GitHub.WebhookSetup

  @interval_ms 5_000
  @reload_debounce_ms 1_000

  @doc """
  Options: `:name`, `:interval_ms`, `:reload_debounce_ms` and `:section_opts` (the options
  `SymphonyElixir.GitHub.WebhookSetup.section/1` builds the section with).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The section for `/api/v1/state`'s `setup`: the last one built, nil when it couldn't be read."
  @spec state_section(keyword()) :: map() | nil
  def state_section(opts) do
    case read(server(opts)) do
      {:ok, section} -> section
      :none -> WebhookSetup.state_section(opts)
    end
  end

  @doc "Keeps `section`, which a setup action just built, in place of the last one."
  @spec put(map(), keyword()) :: :ok
  def put(%{} = section, opts), do: GenServer.cast(server(opts), {:put, section})

  @doc "Builds the section again, after a change it has no other way to hear of."
  @spec refresh(keyword()) :: :ok
  def refresh(opts), do: GenServer.cast(server(opts), :refresh)

  @doc false
  @spec handle_config_reloaded([atom()], map(), map(), pid()) :: :ok
  def handle_config_reloaded(_event, _measurements, _metadata, server) do
    send(server, :config_reloaded)
    :ok
  end

  defp server(opts), do: Keyword.get(opts, :cache, __MODULE__)

  defp read(server) do
    if GenServer.whereis(server), do: GenServer.call(server, :read), else: :none
  catch
    :exit, _reason -> :none
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = {__MODULE__, self()}
    :ok = :telemetry.attach(handler, ConfigCache.reloaded_event(), &__MODULE__.handle_config_reloaded/4, self())

    state = %{
      section_opts: Keyword.get(opts, :section_opts, []),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      reload_debounce_ms: Keyword.get(opts, :reload_debounce_ms, @reload_debounce_ms),
      handler: handler,
      section: :none,
      repos: nil,
      # Bumped by a put and a config reload: a build that started before either is dropped.
      version: 0,
      task: nil,
      task_version: nil,
      rerun?: false,
      reload_timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    schedule_tick(state)
    {:noreply, request_build(state)}
  end

  @impl true
  def handle_call(:read, _from, %{section: :none} = state), do: {:reply, :none, state}
  def handle_call(:read, _from, state), do: {:reply, {:ok, state.section}, state}

  @impl true
  def handle_cast({:put, section}, state), do: {:noreply, %{state | section: section, version: state.version + 1}}
  def handle_cast(:refresh, state), do: {:noreply, request_build(state)}

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state)
    {:noreply, request_build(state)}
  end

  # A save often touches the file more than once; one build reads them all.
  def handle_info(:config_reloaded, %{reload_timer: nil} = state) do
    {:noreply, %{state | reload_timer: Process.send_after(self(), :reload, state.reload_debounce_ms)}}
  end

  def handle_info(:config_reloaded, state), do: {:noreply, state}

  def handle_info(:reload, state) do
    {:noreply, request_build(%{state | reload_timer: nil, repos: nil, version: state.version + 1})}
  end

  def handle_info({ref, {repos, section}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      if state.task_version == state.version,
        do: %{state | section: section, repos: repos},
        else: state

    {:noreply, finish_build(state)}
  end

  # A build that crashed keeps the last section, and the next one starts as usual.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("Instant GitHub updates section build crashed: #{Exception.format_exit(reason)}")
    {:noreply, finish_build(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.interval_ms)

  defp request_build(%{task: nil} = state), do: start_build(state)
  defp request_build(state), do: %{state | rerun?: true}

  defp finish_build(state) do
    state = %{state | task: nil, task_version: nil}
    if state.rerun?, do: start_build(%{state | rerun?: false}), else: state
  end

  defp start_build(state) do
    %{section_opts: opts, repos: repos} = state
    %{state | task: Task.async(fn -> build(opts, repos) end), task_version: state.version}
  end

  defp build(opts, repos) do
    repos = repos || WebhookSetup.repositories(opts)
    {repos, WebhookSetup.state_section(Keyword.put(opts, :repos, fn -> repos end))}
  end
end
