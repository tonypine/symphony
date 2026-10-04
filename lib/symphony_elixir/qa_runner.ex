defmodule SymphonyElixir.QaRunner do
  @moduledoc """
  Runs Auto Review QA passes in the background.

  The CI poller asks for a pass when an issue in Auto Review has green CI. The runner
  starts at most `auto_review.max_concurrent` passes, and never more than
  `agent.concurrency.finishing_max`, one per issue, each as a task under
  `SymphonyElixir.TaskSupervisor` that runs `SymphonyElixir.AutoReview.run_qa/2` and
  applies its own outcome. A request for an issue that already has a pass running is a
  no-op, so a slow pass is never started twice.

  A request turned away because the runner is full leaves the issue queued until a pass
  starts for it or no request has come for it in 10 minutes. The runner remembers which
  cap turned it away: `finishing_max` when it is below `auto_review.max_concurrent`,
  otherwise `max_concurrent`. The orchestrator starts no fresh `Todo` work while a pass
  waits on `finishing_max`; a pass waiting on `max_concurrent` holds nothing back.

  A forced ticket's request (`job.forced`, see `agent.concurrency.force_label`) goes to the front
  of the queue: while one is queued, a free slot is turned away from unforced requests, so the
  forced ticket takes it on its next request. A queued forced request holds the slot only while its
  ticket keeps asking: once no request has come for it in two CI poll intervals (the ticket left
  Auto Review, or its CI is no longer green), unforced requests take free slots again. With every
  slot busy, a forced request starts on the forced allowance instead, while fewer than
  `agent.concurrency.forced_max` forced runs (the orchestrator's, read from its published snapshot,
  plus forced passes here) are going. A pass on the allowance is marked `forced` and takes no QA
  slot. Once its ticket is no longer forced (the orchestrator calls `release_forced/2`), a pass on
  the allowance gives it back and goes on as a normal pass. Forcing changes when a pass starts,
  never its verdict.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{AutoReview, Orchestrator, QaAgent}

  @type request_result :: :started | :running | :busy | {:error, term()}
  @type queued_pass :: %{issue_id: String.t(), identifier: String.t(), waiting_on: :finishing_max | :max_concurrent}

  @queued_ttl_ms 10 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts a QA pass for `job` unless one is running for the issue or the runner is at
  `max_concurrent`. `opts` are passed to `AutoReview.run_qa/2`.
  """
  @spec request(map(), keyword()) :: request_result()
  def request(%{issue: %{id: issue_id}} = job, opts \\ []) when is_binary(issue_id) do
    server = Keyword.get(opts, :qa_runner_server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :qa_runner_unavailable}
      pid -> GenServer.call(pid, {:request, job, Keyword.delete(opts, :qa_runner_server)})
    end
  end

  @doc "Issue ids with a QA pass in flight, mapped to the PR head SHA under test."
  @spec running(GenServer.server()) :: %{String.t() => String.t()}
  def running(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{}
      pid -> GenServer.call(pid, :running)
    end
  end

  @doc "The issue workspace, QA worktree and temp folders of every pass in flight."
  @spec workspaces(GenServer.server()) :: [Path.t()]
  def workspaces(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :workspaces)
    end
  end

  @doc """
  The passes in flight and the queued requests, each with `issue_id`, `identifier` and `forced`
  (a running pass also has `sha`), for the status snapshot.
  """
  @spec snapshot(GenServer.server()) :: %{running: [map()], queued: [map()]}
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{running: [], queued: []}
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc "Issue ids whose last request was turned away because the runner was full."
  @spec queued(GenServer.server()) :: [String.t()]
  def queued(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :queued)
    end
  end

  @doc "The queued passes, longest queued first, with the issue identifier and the cap each waits on."
  @spec queued_passes(GenServer.server()) :: [queued_pass()]
  def queued_passes(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :queued_passes)
    end
  end

  @doc """
  Gives the forced allowance back for the passes of `issue_ids`, issues that are no longer forced:
  each such pass goes on as a normal pass and stops counting toward `forced_max`.
  """
  @spec release_forced([String.t()], GenServer.server()) :: :ok
  def release_forced(issue_ids, server \\ __MODULE__) when is_list(issue_ids), do: GenServer.cast(server, {:release_forced, issue_ids})

  @impl true
  def init(opts) do
    {:ok,
     %{
       running: %{},
       queued: %{},
       queued_ttl_ms: Keyword.get(opts, :queued_ttl_ms, @queued_ttl_ms),
       forced_hold_ms: Keyword.get(opts, :forced_hold_ms),
       run_fun: Keyword.get(opts, :run_fun, &AutoReview.run_qa/2),
       forced_runs_fun: Keyword.get(opts, :forced_runs_fun, &orchestrator_forced_runs/0),
       task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:request, %{issue: %{id: issue_id} = issue, sha: sha} = job, opts}, _from, state) do
    settings = Map.fetch!(job, :settings)
    %{auto_review: %{max_concurrent: max_concurrent}, agent: %{finishing_max: finishing_max}} = settings
    forced? = Map.get(job, :forced) == true
    queued = state |> live_queued() |> Map.delete(issue_id)
    state = %{state | queued: queued}

    cond do
      Map.has_key?(state.running, issue_id) ->
        {:reply, :running, state}

      slot = pass_slot(state, forced?, settings) ->
        start_pass(state, issue_id, sha, job, opts, slot == :forced)

      true ->
        waiting_on = if finishing_max < max_concurrent, do: :finishing_max, else: :max_concurrent
        entry = %{at: now_ms(), identifier: Map.get(issue, :identifier) || issue_id, waiting_on: waiting_on, forced: forced?}
        {:reply, :busy, %{state | queued: Map.put(queued, issue_id, entry)}}
    end
  end

  def handle_call(:running, _from, state) do
    {:reply, Map.new(state.running, fn {issue_id, %{sha: sha}} -> {issue_id, sha} end), state}
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

  def handle_call(:queued, _from, state) do
    {:reply, state |> live_queued() |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call(:queued_passes, _from, state) do
    passes =
      state
      |> live_queued()
      |> Enum.sort_by(fn {issue_id, entry} -> {entry.at, issue_id} end)
      |> Enum.map(fn {issue_id, entry} -> %{issue_id: issue_id, identifier: entry.identifier, waiting_on: entry.waiting_on} end)

    {:reply, passes, state}
  end

  @impl true
  def handle_cast({:release_forced, issue_ids}, state) do
    released =
      for {issue_id, %{forced: true} = entry} <- state.running, issue_id in issue_ids, into: %{} do
        Logger.info("QA pass released the forced allowance issue_id=#{issue_id} issue_identifier=#{entry.identifier} sha=#{entry.sha}; no longer forced, running on as a normal pass")
        {issue_id, %{entry | forced: false}}
      end

    {:noreply, %{state | running: Map.merge(state.running, released)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_issue_id, entry} -> entry.ref == ref end) do
      {issue_id, entry} ->
        if reason != :normal, do: Logger.warning("QA pass crashed issue_id=#{issue_id} sha=#{entry.sha}: #{inspect(reason)}")
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

  # A free QA slot goes to a forced request, or to an unforced one while no forced request is
  # queued. With every QA slot busy, a forced request may take the forced allowance.
  defp pass_slot(state, forced?, settings) do
    cond do
      normal_passes(state) < min(settings.auto_review.max_concurrent, settings.agent.finishing_max) and
          (forced? or not forced_queued?(state, settings)) ->
        :qa

      forced? and forced_slot_free?(state, settings) ->
        :forced

      true ->
        nil
    end
  end

  # Only a forced request asked for within the hold counts: the CI poller asks again on every poll
  # while the ticket is green in Auto Review, so an older one has stopped asking.
  defp forced_queued?(state, settings) do
    cutoff = now_ms() - forced_hold_ms(state, settings)
    Enum.any?(state.queued, fn {_issue_id, entry} -> entry.forced and entry.at > cutoff end)
  end

  defp forced_hold_ms(%{forced_hold_ms: hold_ms}, _settings) when is_integer(hold_ms), do: hold_ms
  defp forced_hold_ms(_state, settings), do: 2 * (settings.ci.poll_interval_ms || settings.pr_review.poll_interval_ms || settings.polling.interval_ms)

  defp normal_passes(state), do: Enum.count(state.running, fn {_issue_id, entry} -> not entry.forced end)

  # The forced allowance is shared with the orchestrator's forced runs.
  defp forced_slot_free?(state, settings) do
    forced_passes = Enum.count(state.running, fn {_issue_id, entry} -> entry.forced end)
    forced_passes + state.forced_runs_fun.() < settings.agent.forced_max
  end

  # The published snapshot is read from ETS: calling the orchestrator here could deadlock, since it
  # calls this runner while it dispatches.
  defp orchestrator_forced_runs do
    case Orchestrator.snapshot_cache_entry() do
      {:ok, %{snapshot: %{running: running}}} when is_list(running) -> Enum.count(running, &(Map.get(&1, :forced) == true))
      _missing -> 0
    end
  end

  defp issue_identifier(%{issue: issue}, issue_id), do: Map.get(issue, :identifier) || issue_id

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp start_pass(state, issue_id, sha, job, opts, forced?) do
    run_fun = state.run_fun

    case Task.Supervisor.start_child(state.task_supervisor, fn -> run_fun.(job, opts) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        identifier = issue_identifier(job, issue_id)
        if forced?, do: Logger.info("QA pass started on the forced allowance issue_id=#{issue_id} issue_identifier=#{identifier} sha=#{sha} forced=true")
        entry = %{sha: sha, ref: ref, paths: pass_paths(job, sha), identifier: identifier, forced: forced?}
        {:reply, :started, %{state | running: Map.put(state.running, issue_id, entry)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The pass works in a worktree of the issue workspace, with a temp folder of its own (see
  # `QaAgent.run/3`).
  defp pass_paths(%{issue: issue, record: record, settings: settings}, sha) do
    worktree = QaAgent.worktree_path(settings, Map.get(record, :repo_key), Map.get(issue, :identifier), sha)
    Enum.filter([Map.get(record, :workspace_path), worktree], &is_binary/1) ++ QaAgent.tmp_dirs(worktree)
  end
end
