defmodule SymphonyElixir.AcceptanceGate.Runner do
  @moduledoc """
  Runs acceptance gate passes in the background, like `SymphonyElixir.QaRunner` runs QA passes.

  Auto Review asks for a pass once QA is done on a PR head. The runner starts at most
  `auto_review.acceptance_gate.max_concurrent` passes, one per issue, each as a task under
  `SymphonyElixir.TaskSupervisor` that runs `SymphonyElixir.AutoReview.run_gate/2`. A request
  for an issue that already has a pass running is a no-op.

  A request turned away because the runner is full leaves the issue queued until a pass starts
  for it or no request has come for it in 10 minutes. A forced ticket's request (`job.forced`)
  goes first: while one is queued and still asking (a request within two CI poll intervals), a
  free slot is turned away from unforced requests, so the forced ticket takes it on its next
  request.

  A request waits without asking the runner while the gate agent's provider is held by a usage
  limit (`SymphonyElixir.AcceptanceGate.usage_profile/1`); the next green poll asks again.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AcceptanceGate, AutoReview, UsageLimit}

  @type request_result :: :started | :running | :busy | :usage_limited | {:error, term()}

  @queued_ttl_ms 10 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts a gate pass for `job` unless the gate agent's provider is usage-limited, a pass is
  running for the issue, or the runner is at `max_concurrent`. `opts` are passed to
  `AutoReview.run_gate/2`.
  """
  @spec request(map(), keyword()) :: request_result()
  def request(%{issue: %{id: issue_id}, settings: settings} = job, opts \\ []) when is_binary(issue_id) do
    server = Keyword.get(opts, :gate_runner_server, __MODULE__)

    cond do
      UsageLimit.persisted_holding(AcceptanceGate.usage_profile(settings)) -> :usage_limited
      pid = GenServer.whereis(server) -> GenServer.call(pid, {:request, job, Keyword.delete(opts, :gate_runner_server)})
      true -> {:error, :gate_runner_unavailable}
    end
  end

  @doc "The issue workspace, gate worktrees and temp folders of every pass in flight."
  @spec workspaces(GenServer.server()) :: [Path.t()]
  def workspaces(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :workspaces)
    end
  end

  @doc "The passes in flight and the queued requests, each with `issue_id`, `identifier` and `forced`."
  @spec snapshot(GenServer.server()) :: %{running: [map()], queued: [map()]}
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{running: [], queued: []}
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       running: %{},
       queued: %{},
       queued_ttl_ms: Keyword.get(opts, :queued_ttl_ms, @queued_ttl_ms),
       forced_hold_ms: Keyword.get(opts, :forced_hold_ms),
       run_fun: Keyword.get(opts, :run_fun, &AutoReview.run_gate/2),
       task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:request, %{issue: %{id: issue_id} = issue, sha: sha, settings: settings} = job, opts}, _from, state) do
    forced? = Map.get(job, :forced) == true
    queued = state |> live_queued() |> Map.delete(issue_id)
    state = %{state | queued: queued}
    free? = map_size(state.running) < settings.auto_review.acceptance_gate.max_concurrent

    cond do
      Map.has_key?(state.running, issue_id) ->
        {:reply, :running, state}

      free? and (forced? or not forced_queued?(state, settings)) ->
        start_pass(state, issue_id, sha, job, opts)

      true ->
        entry = %{at: now_ms(), identifier: Map.get(issue, :identifier) || issue_id, forced: forced?}
        {:reply, :busy, %{state | queued: Map.put(queued, issue_id, entry)}}
    end
  end

  def handle_call(:workspaces, _from, state) do
    {:reply, Enum.flat_map(state.running, fn {_issue_id, entry} -> entry.paths end), state}
  end

  def handle_call(:snapshot, _from, state) do
    running = for {issue_id, entry} <- state.running, do: %{issue_id: issue_id, identifier: entry.identifier, sha: entry.sha, forced: entry.forced}

    queued =
      state
      |> live_queued()
      |> Enum.sort_by(fn {issue_id, entry} -> {not entry.forced, entry.at, issue_id} end)
      |> Enum.map(fn {issue_id, entry} -> %{issue_id: issue_id, identifier: entry.identifier, forced: entry.forced} end)

    {:reply, %{running: Enum.sort_by(running, & &1.issue_id), queued: queued}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_issue_id, entry} -> entry.ref == ref end) do
      {issue_id, entry} ->
        if reason != :normal, do: Logger.warning("Acceptance gate pass crashed issue_id=#{issue_id} sha=#{entry.sha}: #{inspect(reason)}")
        {:noreply, %{state | running: Map.delete(state.running, issue_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp live_queued(state) do
    cutoff = now_ms() - state.queued_ttl_ms
    Map.filter(state.queued, fn {_issue_id, %{at: queued_at}} -> queued_at > cutoff end)
  end

  # Only a forced request asked for within the hold counts: the CI poller asks again on every
  # poll while the ticket is green in Auto Review, so an older one has stopped asking.
  defp forced_queued?(state, settings) do
    cutoff = now_ms() - forced_hold_ms(state, settings)
    Enum.any?(state.queued, fn {_issue_id, entry} -> entry.forced and entry.at > cutoff end)
  end

  defp forced_hold_ms(%{forced_hold_ms: hold_ms}, _settings) when is_integer(hold_ms), do: hold_ms
  defp forced_hold_ms(_state, settings), do: 2 * (settings.ci.poll_interval_ms || settings.pr_review.poll_interval_ms || settings.polling.interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp start_pass(state, issue_id, sha, job, opts) do
    run_fun = state.run_fun

    case Task.Supervisor.start_child(state.task_supervisor, fn -> run_fun.(job, opts) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        identifier = Map.get(job.issue, :identifier) || issue_id
        entry = %{sha: sha, ref: ref, paths: pass_paths(job, sha), identifier: identifier, forced: Map.get(job, :forced) == true}
        {:reply, :started, %{state | running: Map.put(state.running, issue_id, entry)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp pass_paths(%{issue: issue, record: record, settings: settings}, sha) do
    repo_key = Map.get(record, :repo_key)
    identifier = Map.get(issue, :identifier)
    context_worktree = AcceptanceGate.Context.worktree_path(settings, repo_key, identifier, sha)
    agent_worktree = AcceptanceGate.worktree_path(settings, repo_key, identifier, sha)
    paths = [Map.get(record, :workspace_path), context_worktree, agent_worktree | AcceptanceGate.tmp_dirs(agent_worktree)]
    Enum.filter(paths, &is_binary/1)
  end
end
