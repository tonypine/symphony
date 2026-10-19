defmodule SymphonyElixir.Setup do
  @moduledoc """
  The Setup health model: every `SymphonyElixir.Setup.Check` run against the running config, and
  the problems they find, for `GET /api/v1/setup` and the `setup` part of `GET /api/v1/state`.

  The checks run at startup, after each config reload, every 15 minutes, and on
  `POST /api/v1/setup/refresh` (`refresh/1`), in a task, so reading the result never waits on them.
  The payload is `problems`, `not_checked` (each check that could not run, with the reason),
  `checked_at` (null until the first run ends) and `linear_checked_at`.

  A check that can't run is not a failure. Without a Linear API key every Linear-side check is listed
  under `not_checked`, and the secrets check reports the missing key. When Linear can't be reached,
  the Linear-side problems of the last run that reached it are kept, and `linear_checked_at` says
  when that run was.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Setup.{Checks, Problem, TeamCache}

  @interval_ms 15 * 60 * 1000
  @reload_debounce_ms 1_000
  @refresh_timeout_ms 60_000

  @checks [
    Checks.DeprecatedKeys,
    Checks.FailedReload,
    Checks.WorkflowRef,
    Checks.WorkflowFetch,
    Checks.UnclonedRepos,
    Checks.Routing,
    Checks.Secrets,
    Checks.Teams
  ]

  @type not_checked :: %{id: String.t(), title: String.t(), reason: String.t()}
  @type payload :: %{
          problems: [Problem.t()],
          not_checked: [not_checked()],
          checked_at: String.t() | nil,
          linear_checked_at: String.t() | nil
        }

  @empty_payload %{problems: [], not_checked: [], checked_at: nil, linear_checked_at: nil}
  @no_linear %{problems: [], checked_at: nil}

  @doc """
  Options: `:name`, `:checks` (the check modules), `:interval_ms`, `:reload_debounce_ms`,
  `:tracker` (for the team cache), `:now` (a clock returning a `DateTime`) and `:linear_api_key?`
  (whether a Linear API key is set, read from the config by default).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The check modules a run uses by default."
  @spec checks() :: [module()]
  def checks, do: @checks

  @doc """
  The last run's result. Without a running server (a test, a one-off command) the checks run here
  and now.
  """
  @spec payload(GenServer.server()) :: payload()
  def payload(server) do
    if GenServer.whereis(server), do: GenServer.call(server, :payload), else: check()
  end

  @doc """
  Runs the checks again, with the team cache emptied, and returns their result. A run already going
  finishes first; this one starts after it.
  """
  @spec refresh(GenServer.server()) :: payload()
  def refresh(server) do
    if GenServer.whereis(server), do: GenServer.call(server, :refresh, @refresh_timeout_ms), else: check()
  end

  @doc "Empties the team cache, as a Setup fix that changed Linear does."
  @spec invalidate_team_cache(GenServer.server()) :: :ok
  def invalidate_team_cache(server \\ __MODULE__), do: GenServer.call(server, :invalidate_team_cache)

  @doc """
  The running server's team cache, for a read outside the checks that should share it
  (`SymphonyElixir.RepoTeams`'s projects lookup). `nil` without a running server.
  """
  @spec team_cache(GenServer.server()) :: TeamCache.t() | nil
  def team_cache(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.call(server, :team_cache)
  catch
    :exit, _reason -> nil
  end

  @doc "Runs `checks` once, with a cache of its own, and returns the payload."
  @spec check(keyword()) :: payload()
  def check(opts \\ []) do
    cache = TeamCache.new(Keyword.merge([ttl_ms: @interval_ms], Keyword.take(opts, [:tracker])))

    try do
      opts |> run(@no_linear, cache) |> elem(0)
    after
      TeamCache.delete(cache)
    end
  end

  @doc false
  @spec handle_config_reloaded([atom()], map(), map(), pid()) :: :ok
  def handle_config_reloaded(_event, _measurements, metadata, server) do
    send(server, {:config_reloaded, metadata[:path]})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = {__MODULE__, self()}
    :ok = :telemetry.attach(handler, Cache.reloaded_event(), &__MODULE__.handle_config_reloaded/4, self())
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)

    state = %{
      opts: opts,
      interval_ms: interval_ms,
      handler: handler,
      team_cache: TeamCache.new(ttl_ms: interval_ms, tracker: Keyword.get(opts, :tracker, SymphonyElixir.Tracker)),
      payload: @empty_payload,
      linear: @no_linear,
      task: nil,
      waiters: [],
      queued: [],
      rerun?: false,
      empty_cache?: false,
      reload_timer: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    schedule_tick(state)
    {:noreply, request_run(state, nil)}
  end

  @impl true
  def handle_call(:payload, _from, state), do: {:reply, state.payload, state}

  # The cache is emptied when the refresh's own run starts: a run already going may still fill it.
  def handle_call(:refresh, from, state), do: {:noreply, request_run(%{state | empty_cache?: true}, from)}

  def handle_call(:invalidate_team_cache, _from, state), do: {:reply, TeamCache.invalidate(state.team_cache), state}

  def handle_call(:team_cache, _from, state), do: {:reply, state.team_cache, state}

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state)
    {:noreply, request_run(state, nil)}
  end

  # A save often touches the file more than once; one run checks them all.
  def handle_info({:config_reloaded, _path}, %{reload_timer: nil} = state) do
    timer = Process.send_after(self(), :config_reloaded, Keyword.get(state.opts, :reload_debounce_ms, @reload_debounce_ms))
    {:noreply, %{state | reload_timer: timer}}
  end

  def handle_info({:config_reloaded, _path}, state), do: {:noreply, state}

  def handle_info(:config_reloaded, state), do: {:noreply, request_run(%{state | reload_timer: nil}, nil)}

  def handle_info({ref, {payload, linear}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state, payload, linear)}
  end

  # A run that crashed outside a check keeps the last result, and the next run starts as usual.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("Setup checks crashed: #{Exception.format_exit(reason)}")
    {:noreply, finish_run(state, state.payload, state.linear)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
  end

  defp finish_run(state, payload, linear) do
    Enum.each(state.waiters, &GenServer.reply(&1, payload))
    state = %{state | payload: payload, linear: linear, task: nil, waiters: []}
    if state.rerun?, do: start_run(%{state | rerun?: false, waiters: state.queued, queued: []}), else: state
  end

  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.interval_ms)

  defp request_run(%{task: nil} = state, from), do: start_run(%{state | waiters: List.wrap(from)})
  defp request_run(state, from), do: %{state | rerun?: true, queued: state.queued ++ List.wrap(from)}

  defp start_run(state) do
    %{opts: opts, linear: linear, team_cache: cache} = state
    if state.empty_cache?, do: TeamCache.invalidate(cache)
    %{state | task: Task.async(fn -> run(opts, linear, cache) end), empty_cache?: false}
  end

  # One run: the local checks, then the Linear-side ones, which keep the last run that reached Linear
  # when this one can't. Returns the payload and the Linear-side result to keep.
  defp run(opts, previous_linear, cache) do
    now = now(opts)
    context = %{system: system_config(), symphony_path: Workflow.symphony_file_path(), team_cache: cache, now: now}
    {linear_checks, local_checks} = opts |> Keyword.get(:checks, @checks) |> Enum.split_with(& &1.needs_linear?())
    local = Enum.map(local_checks, &{&1, run_check(&1, context)})
    {linear, linear_not_checked} = run_linear(linear_checks, context, previous_linear, linear_api_key?(opts))

    payload = %{
      problems: Enum.flat_map(local, &problems/1) ++ linear.problems,
      not_checked: Enum.flat_map(local, &not_checked/1) ++ linear_not_checked,
      checked_at: iso8601(now),
      linear_checked_at: linear.checked_at && iso8601(linear.checked_at)
    }

    {payload, linear}
  end

  defp run_linear(checks, _context, _previous, false) do
    {@no_linear, Enum.map(checks, &not_checked(&1, "No Linear API key is set, so Symphony can't read Linear. Add one in Settings."))}
  end

  defp run_linear(checks, context, previous, true) do
    results = Enum.map(checks, &{&1, run_check(&1, context)})

    case Enum.find(results, &match?({_check, {:unreachable, _reason}}, &1)) do
      nil ->
        not_checked = Enum.flat_map(results, &not_checked/1)
        {%{problems: Enum.flat_map(results, &problems/1), checked_at: context.now}, not_checked}

      {_check, {:unreachable, reason}} when is_nil(previous.checked_at) ->
        {previous, Enum.map(checks, &not_checked(&1, "Symphony couldn't reach Linear: #{describe(reason)}"))}

      {_check, {:unreachable, _reason}} ->
        {previous, []}
    end
  end

  defp run_check(check, context) do
    case check.run(context) do
      problems when is_list(problems) -> {:ok, problems}
      {:error, reason} -> if check.needs_linear?(), do: {:unreachable, reason}, else: {:failed, reason}
    end
  rescue
    error ->
      Logger.warning("Setup check #{check.id()} failed: #{Exception.message(error)}")
      {:failed, Exception.message(error)}
  end

  defp problems({_check, {:ok, problems}}), do: problems
  defp problems(_result), do: []

  defp not_checked({check, {:failed, reason}}), do: [not_checked(check, "This check failed: #{describe(reason)}")]
  defp not_checked(_result), do: []

  defp not_checked(check, reason), do: %{id: check.id(), title: check.title(), reason: reason}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: Config.format_error(reason)

  defp system_config do
    case Config.system() do
      {:ok, system_config} -> system_config
      {:error, _reason} -> nil
    end
  end

  defp linear_api_key?(opts), do: Keyword.get_lazy(opts, :linear_api_key?, &Checks.Secrets.linear_api_key?/0)

  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
