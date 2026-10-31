defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Projections for the observability API.
  """

  alias SymphonyElixir.{
    Artifacts,
    BuildInfo,
    Config,
    ForcedStatus,
    Inbox,
    Initiatives,
    Orchestrator,
    Pauses,
    PlanBrief,
    PrWatch,
    Quality,
    RetiredStates,
    RunKind,
    RunStore,
    Sessions,
    Setup,
    StrayProcesses,
    TicketObservation,
    TicketState,
    URLUtils,
    UsageLimit
  }

  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.Dispatch.Shadow, as: DispatchShadow
  alias SymphonyElixir.GitHub.WebhookSetup.Cache, as: WebhookSetupCache
  alias SymphonyElixir.Linear.Webhook, as: LinearWebhook
  alias SymphonyElixir.Linear.Webhook.Deliveries, as: LinearWebhookDeliveries
  alias SymphonyElixir.Pauses.Backfill, as: PauseBackfill
  alias SymphonyElixir.Repo.Status, as: RepoStatus
  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixirWeb.WatchPayload

  @empty_codex_totals %{
    input_tokens: 0,
    uncached_input_tokens: 0,
    cached_input_tokens: 0,
    cache_creation_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec state_payload(GenServer.name(), timeout(), GenServer.server(), GenServer.name(), GenServer.server(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, stray_processes \\ StrayProcesses, inbox \\ Inbox, setup \\ Setup, github_updates \\ []) do
    now = DateTime.utc_now()
    generated_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        run_history = Map.get(snapshot, :run_history, [])
        blocked = Map.get(snapshot, :blocked, [])
        shipped_today = Map.get(snapshot, :shipped_today, [])
        waiting_on_you = Inbox.items(snapshot, inbox)
        repositories = Map.get(snapshot, :repositories, [])
        records = ticket_state_records()
        status = &with_ticket_status(&1, records, repositories)

        %{
          generated_at: generated_at,
          build: Map.take(BuildInfo.current(), [:version, :sha]),
          uptime_seconds: uptime_seconds(),
          repos: repo_keys(snapshot),
          counts: %{
            running: length(snapshot.running),
            watching: length(Map.get(snapshot, :watching, [])),
            conflicts: length(Map.get(snapshot, :conflicts, [])),
            retrying: length(snapshot.retrying),
            claimed: length(Map.get(snapshot, :claimed, [])),
            forced: length(Map.get(snapshot, :forced, [])),
            shipped_today: length(shipped_today),
            waiting_on_you: length(waiting_on_you),
            review_inconclusive: review_inconclusive_counts(run_history)
          },
          running: Enum.map(snapshot.running, &(&1 |> running_entry_payload() |> status.())),
          sessions: sessions_payload(snapshot.running),
          watching: snapshot |> Map.get(:watching, []) |> Enum.map(&(&1 |> watching_entry_payload() |> status.())),
          waiting_on_you: Enum.map(waiting_on_you, &waiting_on_you_payload(&1, now)),
          inbox_read: Inbox.read?(inbox),
          conflicts: snapshot |> Map.get(:conflicts, []) |> Enum.map(&conflict_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &(&1 |> retry_entry_payload() |> status.())),
          drain_report: drain_report_payload(RetiredStates.drain_report()),
          setup: setup |> setup_payload() |> Map.put(:github_updates, WebhookSetupCache.state_section(github_updates)),
          awaiting_clarification:
            snapshot
            |> Map.get(:awaiting_clarification, [])
            |> Enum.map(&awaiting_clarification_entry_payload/1),
          skipped:
            snapshot
            |> Map.get(:skipped, [])
            |> Enum.map(&skipped_entry_payload/1),
          run_history: Enum.map(run_history, &run_history_payload/1),
          codex_totals: normalize_codex_totals(Map.get(snapshot, :codex_totals)),
          pollers: normalize_pollers(Map.get(snapshot, :pollers)),
          pause: normalize_pause(Map.get(snapshot, :pause)),
          repositories: Enum.map(repositories, &repository_payload/1),
          all_repositories_paused: repositories != [] and Enum.all?(repositories, & &1.pause),
          usage_limits: snapshot |> Map.get(:usage_limits, []) |> Enum.map(&usage_limit_payload(&1, now)),
          stray_processes: stray_processes |> StrayProcesses.warnings() |> Enum.map(&Map.delete(&1, :start_time)),
          budget: normalize_budget(Map.get(snapshot, :budget)),
          dispatch_state: normalize_dispatch_state(snapshot),
          epic_lanes: normalize_epic_lanes(Map.get(snapshot, :epic_lanes)),
          finishing: normalize_finishing(Map.get(snapshot, :finishing)),
          auto_merge: snapshot |> Map.get(:auto_merge, []) |> Enum.map(&auto_merge_payload/1),
          landing_waits: snapshot |> Map.get(:landing_waits, []) |> Enum.map(&landing_wait_payload/1),
          red_bases: PrWatch.red_bases(),
          issues: watched_issues_payload(records),
          silent_waits: Enum.map(PrWatch.silent_waits(), &WatchPayload.silent_wait/1),
          rate_limit: WatchPayload.rate_limit(PrWatch.rate_limit()),
          slot_waiting: snapshot |> Map.get(:slot_waiting, []) |> Enum.map(&(&1 |> slot_waiting_payload() |> status.())),
          dispatch_skipped: snapshot |> Map.get(:dispatch_skipped, []) |> Enum.map(&(&1 |> dispatch_skipped_payload() |> status.())),
          shipped_today: Enum.map(shipped_today, &shipped_payload/1),
          blocked: Enum.map(blocked, &blocked_payload/1),
          app_update: WatchPayload.app_update(blocked, PrWatch.Release.latest()),
          forced: snapshot |> Map.get(:forced, []) |> Enum.map(&forced_payload/1),
          concurrency: Map.get(snapshot, :concurrency),
          claimed: Map.get(snapshot, :claimed, []),
          rate_limits: snapshot.rate_limits,
          linear_usage: normalize_linear_usage(get_in(snapshot, [:polling, :linear, :usage])),
          linear_webhooks: linear_webhooks_payload(),
          dispatch_shadow: dispatch_shadow_payload(),
          reconcile: reconcile_payload(),
          pause_backfill: pause_backfill_payload(PauseBackfill.summary()),
          orchestrator: Orchestrator.diagnostics(orchestrator)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @doc """
  The plan tickets followed to done (`SymphonyElixir.Initiatives.list/4`): active ones first, then
  in review, then done in the last 7 days, each with its sub-tickets in landing order, what each
  waits on, counts by stage and its slot line from `epic_lanes`. Read from
  what Symphony cached on its last poll: it makes no Linear request.
  """
  @spec initiatives_payload(GenServer.name(), timeout(), GenServer.name(), GenServer.name()) :: map()
  def initiatives_payload(orchestrator, snapshot_timeout_ms, initiatives \\ Initiatives, inbox \\ Inbox) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        lanes = Map.get(snapshot, :epic_lanes)

        listed =
          snapshot
          |> Initiatives.list(initiatives, inbox)
          |> Enum.sort_by(&{group_rank(&1.group), &1.identifier || ""})
          |> Enum.map(&initiative_payload(&1, lanes))

        %{
          generated_at: generated_at,
          read: Initiatives.read?(initiatives),
          counts: Map.new(~w(active in_review done), fn group -> {group, Enum.count(listed, &(&1.group == group))} end),
          initiatives: listed
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp group_rank("active"), do: 0
  defp group_rank("in_review"), do: 1
  defp group_rank(_done), do: 2

  defp initiative_payload(initiative, lanes) do
    %{
      issue_id: initiative.id,
      identifier: initiative.identifier,
      title: initiative.title,
      state: initiative.state,
      repo_key: initiative.repo_key,
      url: URLUtils.present_url(initiative.url),
      group: initiative.group,
      completed_at: initiative.completed_at,
      counts: initiative.counts,
      slot: initiative_slot(lanes, initiative.id),
      sub_tickets: Enum.map(initiative.sub_tickets, &sub_ticket_payload/1)
    }
  end

  defp sub_ticket_payload(sub_ticket) do
    %{
      issue_id: sub_ticket.id,
      identifier: sub_ticket.identifier,
      title: sub_ticket.title,
      state: sub_ticket.state,
      url: URLUtils.present_url(sub_ticket.url),
      blocked_by: Enum.map(sub_ticket.blocked_by, & &1.identifier),
      waits_on: sub_ticket.waits_on,
      waiting_for: sub_ticket.waiting_for
    }
  end

  # The initiative's line in the epic lanes: the lane it runs or holds, the reason it yielded it, or
  # its place in the queue for one; nil when it has no lane.
  defp initiative_slot(%{lanes: lanes, queued_epics: queued}, issue_id) do
    case Enum.find(lanes, &(&1.issue_id == issue_id)) do
      %{status: status} = lane ->
        %{status: status, identifier: get_in(lane, [:sub_issue, :identifier]), reason: Map.get(lane, :reason)}

      nil ->
        case Enum.find_index(queued, &(&1.issue_id == issue_id)) do
          nil -> nil
          index -> %{status: "queued", position: index + 1, identifier: nil, reason: nil}
        end
    end
  end

  defp initiative_slot(_lanes, _issue_id), do: nil

  @doc """
  Everything that waits on the Director (`SymphonyElixir.Inbox.items/2`), oldest first, with
  counts by kind. Read from what Symphony cached on its last poll: it makes no Linear request.
  """
  @spec inbox_payload(GenServer.name(), timeout(), GenServer.name()) :: map()
  def inbox_payload(orchestrator, snapshot_timeout_ms, inbox \\ Inbox) do
    now = DateTime.utc_now()
    generated_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        items = Inbox.items(snapshot, inbox)
        by_kind = Enum.frequencies_by(items, &Atom.to_string(&1.kind))

        %{
          generated_at: generated_at,
          counts: Map.new(~w(plan pr action clarify blocked), &{&1, Map.get(by_kind, &1, 0)}) |> Map.put("total", length(items)),
          items: Enum.map(items, &inbox_item_payload(&1, now))
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp inbox_item_payload(item, now) do
    %{
      issue_id: item.issue_id,
      identifier: item.identifier,
      title: item.title,
      repo_key: item.repo_key,
      kind: Atom.to_string(item.kind),
      state: item.state,
      ask: item.ask,
      waiting_since: iso8601(item.waiting_since),
      waiting_seconds: waiting_seconds(item.waiting_since, now),
      url: URLUtils.present_url(item.url),
      review: inbox_review_payload(item.review),
      references: Map.get(item, :references, %{}),
      context: Map.get(item, :context)
    }
  end

  defp inbox_review_payload(%{requested_at: requested_at} = review), do: %{review | requested_at: iso8601(requested_at)}
  defp inbox_review_payload(review), do: review

  @doc """
  One entry per configured repo (see `SymphonyElixir.Repo.Status`). When the
  orchestrator snapshot is unavailable the repos are still listed, with no
  worktrees, next to an `error`.
  """
  @spec repos_payload(GenServer.name(), timeout()) :: {:ok, map()} | {:error, term()}
  def repos_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {running, error} =
      case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = snapshot -> {Map.get(snapshot, :running, []), nil}
        :timeout -> {[], %{code: "snapshot_timeout", message: "Snapshot timed out"}}
        :unavailable -> {[], %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
      end

    with {:ok, repos} <- RepoStatus.list(running) do
      payload = %{generated_at: generated_at, repos: repos}
      {:ok, if(error, do: Map.put(payload, :error, error), else: payload)}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        watching = snapshot |> Map.get(:watching, []) |> Enum.find(&(&1.identifier == issue_identifier))
        waiting = waiting_entry(snapshot, issue_identifier)

        if is_nil(running) and is_nil(retry) and is_nil(watching) and is_nil(waiting) do
          untracked_issue_payload(issue_identifier)
        else
          payload = issue_payload_body(issue_identifier, running, retry, watching, waiting)
          record = ticket_state_record(payload.repo_key, payload.issue_id, issue_identifier)
          {:ok, record_payload(payload, record)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  # A ticket waiting for a slot, or one the last dispatch pass passed over, as `{list, entry}`.
  defp waiting_entry(snapshot, issue_identifier) do
    Enum.find_value([:slot_waiting, :dispatch_skipped], fn list ->
      entry = snapshot |> Map.get(list, []) |> Enum.find(&(&1.identifier == issue_identifier))
      entry && {list, entry}
    end)
  end

  # A ticket Symphony no longer runs or watches is still served while its ticket state record
  # holds it, so the ticket page can show its Code Review and QA verdicts.
  defp untracked_issue_payload(issue_identifier) do
    case ticket_state_by_identifier(issue_identifier) do
      nil ->
        {:error, :issue_not_found}

      record ->
        payload = issue_payload_body(issue_identifier, nil, nil, nil, nil)

        {:ok, record_payload(%{payload | repo_key: record.repo_key, issue_id: record.issue_id}, record)}
    end
  end

  # What the ticket's record adds to its payload: its verdicts, the watcher's block, a plan's brief
  # (`SymphonyElixir.PlanBrief`) and why it does not move (`ticket_status/2`).
  defp record_payload(payload, record) do
    repository_paused = is_binary(payload.repo_key) and Pauses.paused?({:repository, payload.repo_key})

    payload
    |> Map.put(:verdicts, verdicts_payload(record))
    |> Map.put(:watch, WatchPayload.watch(record))
    |> Map.put(:plan_brief, plan_brief_payload(record))
    |> Map.merge(ticket_status(record, repository_paused))
  end

  # The one answer to "why is this ticket not moving", as the ticket payload and each ticket entry
  # of the state payload carry it: its pause (`pause_payload/1`, nil when it moves), the questions
  # still waiting for an answer, and whether its repository is paused.
  defp ticket_status(record, repository_paused) do
    %{
      pause: pause_payload(record),
      open_questions: open_questions_payload(record),
      repository_paused: repository_paused
    }
  end

  # A state payload entry with its ticket's status, read from the records the payload read once and
  # from the repositories' pauses in the snapshot.
  defp with_ticket_status(entry, records, repositories) do
    repo_key = entry.repo_key
    record = Map.get(records, if(is_nil(repo_key), do: entry.issue_id, else: {repo_key, entry.issue_id}))
    repository_paused = Enum.any?(repositories, &(&1.repo_key == repo_key and not is_nil(&1.pause)))
    Map.merge(entry, ticket_status(record, repository_paused))
  end

  @doc """
  A configured repository and its pause (`SymphonyElixir.Pauses`, subject `{:repository, repo_key}`)
  as the state payload's `repositories` and the control API give it: `paused`, and the pause's
  reasons, who set it and since when, as a ticket's pause reads (nil when not paused).
  """
  @spec repository_payload(%{repo_key: String.t(), pause: map() | nil}) :: map()
  def repository_payload(%{repo_key: repo_key} = repository),
    do: %{repo_key: repo_key, paused: not is_nil(repository.pause), pause: pause_payload(repository)}

  @doc """
  Why a ticket or a repository does not move (`SymphonyElixir.Pauses`), from its record: since when,
  who set the pause, each reason in plain words with what it waits on, who set it and when, and
  whether the Director may release it, in the order they were set; and `releasable`, whether they
  may release any of them. Nil when nothing pauses it.
  """
  @spec pause_payload(map() | nil) :: map() | nil
  def pause_payload(%{pause: %{reasons: reasons} = pause}) do
    %{
      since: iso8601(pause.since),
      set_by: pause.set_by,
      reasons:
        Enum.map(reasons, fn reason ->
          %{kind: reason.kind, text: reason.text, waits_on: reason.waits_on, set_by: reason.set_by, set_at: iso8601(reason.set_at), releasable: reason.releasable}
        end),
      releasable: Enum.any?(reasons, & &1.releasable)
    }
  end

  def pause_payload(_record), do: nil

  # The ticket's questions still waiting for an answer (`SymphonyElixir.Questions`), in the order
  # they were asked: each one's id, title, who asked it and when, and the state its confirmation
  # moves the ticket into.
  defp open_questions_payload(%{questions: questions}) do
    for %{state: :open} = question <- questions do
      %{
        id: question.id,
        title: Map.get(question, :title),
        asked_by: Map.get(question, :asked_by),
        asked_at: question |> Map.get(:asked_at) |> iso8601(),
        confirm: Map.get(question, :confirm)
      }
    end
  end

  defp open_questions_payload(_record), do: []

  # The plan's brief the record holds, with when it was read, nil when it holds none.
  defp plan_brief_payload(record) do
    case PlanBrief.from_record(record) do
      nil -> nil
      brief -> %{brief | read_at: iso8601(brief.read_at)}
    end
  end

  defp ticket_state_record(repo_key, issue_id, issue_identifier) when is_binary(repo_key) and is_binary(issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      %{} = record -> TicketState.normalize(record)
      _none_or_error -> ticket_state_by_identifier(issue_identifier)
    end
  end

  defp ticket_state_record(_repo_key, _issue_id, issue_identifier), do: ticket_state_by_identifier(issue_identifier)

  # A store error reads as no record: `normalize/1` turns the wrapped error into an empty one.
  defp ticket_state_by_identifier(issue_identifier) do
    RunStore.list_all_ticket_states()
    |> List.wrap()
    |> Enum.map(&TicketState.normalize/1)
    |> Enum.find(&(&1.issue_identifier == issue_identifier))
  end

  # Every ticket state record, read once for the state payload, by `{repo_key, issue_id}` and by
  # `issue_id` alone (an entry without a repo key). A store error reads as no record.
  defp ticket_state_records do
    records = RunStore.list_all_ticket_states() |> List.wrap() |> Enum.map(&TicketState.normalize/1)
    Map.merge(Map.new(records, &{&1.issue_id, &1}), Map.new(records, &{{&1.repo_key, &1.issue_id}, &1}))
  end

  # The issues the PR and CI watcher watches, with the facts it last read of each one's PR, read
  # from the ticket state records so they are there right after a restart.
  defp watched_issues_payload(records) do
    watched = for {{_repo_key, _issue_id}, record} <- records, record.pr_watch, do: record

    watched
    |> Enum.sort_by(&{&1.repo_key || "", &1.issue_identifier || &1.issue_id || ""})
    |> Enum.map(&watched_issue_payload/1)
  end

  defp watched_issue_payload(record) do
    %{issue_id: record.issue_id, identifier: record.issue_identifier, repo_key: record.repo_key, watch: WatchPayload.watch(record)}
  end

  @doc """
  Check Now (`POST /api/v1/issues/:issue_identifier/watch/check`): the watcher reads and decides on
  the ticket at once (`SymphonyElixir.PrWatch.check/2`), and the payload carries its new `watch`
  block.
  """
  @spec watch_check_payload(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def watch_check_payload(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    with {:ok, record} <- PrWatch.check(issue_identifier, opts) do
      {:ok, %{issue_identifier: issue_identifier, issue_id: record.issue_id, repo_key: record.repo_key, watch: WatchPayload.watch(record)}}
    end
  end

  @verdict_kinds ["code_review", "qa"]

  # The ticket's Code Review and QA verdicts, newest first, as the ledger keeps them.
  defp verdicts_payload(nil), do: []

  defp verdicts_payload(record) do
    record.verdicts
    |> Enum.filter(&(&1.kind in @verdict_kinds))
    |> Enum.map(&%{kind: &1.kind, outcome: &1.outcome, head_sha: &1.head_sha, recorded_at: iso8601(&1.recorded_at)})
  end

  @spec transcript_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    transcript_payload(current_repo_key(), issue_identifier, orchestrator, snapshot_timeout_ms)
  end

  @spec transcript_payload(String.t() | nil, String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(repo_key, issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        transcript_payload_from_snapshot(snapshot, repo_key, issue_identifier)

      _ ->
        {:error, :snapshot_unavailable}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @doc """
  A page of `repo_key`'s ticket `issue_id`'s events (`SymphonyElixir.TicketEvents`), as the events
  feed answers them: each with its summary, and its artifacts as
  `{id, kind, mime, label, available, url}`. `available` says whether `url` (the artifact route,
  relative to the server) serves the bytes: false for an artifact the store marks expired, and for
  an id the store doesn't know, whose other fields are null. The page's artifacts are read in one
  `SymphonyElixir.Artifacts.list/1` call.
  """
  @spec ticket_events_json(String.t(), String.t(), [Event.t()]) :: [map()]
  def ticket_events_json(repo_key, issue_id, events) do
    artifacts = ticket_artifacts(repo_key, issue_id, events)
    Enum.map(events, &ticket_event_json(&1, artifacts))
  end

  @doc """
  The page `events` grouped by run, oldest first: each entry an event (`ticket_events_json/3`'s
  shape, with its `children`) or a run, placed where its first event on the page falls.

  An event whose `parent` names an earlier event on the page sits in that event's `children`, at any
  depth. Otherwise an event whose `run_id` names a run of `history` sits in that run's `events`, and
  any other event stays at the top level. A run is `{kind: "run", run_id, run_kind, run_number,
  status, verdict, started_at, ended_at, exit, head, summary, events}`, its header read from
  `history` (the ticket's `run.started`, `run.ended` and `verdict.recorded` events, oldest first),
  not from the page: `status` is `running` until its `run.ended`, then `ended`, and `verdict` is the
  newest verdict naming the run (`{kind, outcome, head, at}`), else null.
  """
  @spec ticket_timeline_json(String.t(), String.t(), [Event.t()], [Event.t()]) :: [map()]
  def ticket_timeline_json(repo_key, issue_id, events, history) do
    runs = run_headers(history)

    {placed, _seen} =
      Enum.map_reduce(events, MapSet.new(), fn event, seen ->
        {{event, timeline_place(event, seen, runs)}, MapSet.put(seen, event.id)}
      end)

    timeline = %{
      artifacts: ticket_artifacts(repo_key, issue_id, events),
      runs: runs,
      members: Enum.group_by(placed, &elem(&1, 1), &elem(&1, 0))
    }

    placed
    |> Enum.flat_map(fn
      {event, :top} -> [{:event, event}]
      {_event, {:run, run_id}} -> [{:run, run_id}]
      {_event, {:event, _parent}} -> []
    end)
    |> Enum.uniq()
    |> Enum.map(&timeline_entry(&1, timeline))
  end

  # A parent must come earlier on the page, so a `parent` chain never loops.
  defp timeline_place(%Event{parent: parent, run_id: run_id}, seen, runs) do
    cond do
      is_binary(parent) and MapSet.member?(seen, parent) -> {:event, parent}
      is_binary(run_id) and is_map_key(runs, run_id) -> {:run, run_id}
      true -> :top
    end
  end

  defp timeline_entry({:event, event}, timeline) do
    event
    |> ticket_event_json(timeline.artifacts)
    |> Map.put(:children, timeline_members({:event, event.id}, timeline))
  end

  defp timeline_entry({:run, run_id}, timeline) do
    Map.put(Map.fetch!(timeline.runs, run_id), :events, timeline_members({:run, run_id}, timeline))
  end

  defp timeline_members(place, timeline) do
    timeline.members |> Map.get(place, []) |> Enum.map(&timeline_entry({:event, &1}, timeline))
  end

  defp run_headers(history) do
    verdicts =
      history
      |> Enum.filter(&(&1.type == "verdict.recorded" and is_binary(&1.run_id)))
      |> Map.new(&{&1.run_id, &1})

    history
    |> Enum.filter(&(&1.type in ["run.started", "run.ended"] and is_binary(&1.run_id)))
    |> Enum.group_by(& &1.run_id)
    |> Map.new(fn {run_id, events} -> {run_id, run_header(run_id, events, Map.get(verdicts, run_id))} end)
  end

  defp run_header(run_id, events, verdict) do
    started = Enum.find(events, &(&1.type == "run.started"))
    ended = events |> Enum.filter(&(&1.type == "run.ended")) |> List.last()

    %{
      kind: "run",
      run_id: run_id,
      run_kind: payload_field(started, :run_kind) || payload_field(ended, :run_kind),
      run_number: payload_field(started, :run_number) || payload_field(ended, :run_number),
      status: if(ended, do: "ended", else: "running"),
      verdict: verdict && run_verdict_json(verdict),
      started_at: started && DateTime.to_iso8601(started.at),
      ended_at: ended && DateTime.to_iso8601(ended.at),
      exit: payload_field(ended, :exit),
      head: payload_field(ended, :head) || payload_field(started, :head),
      summary: (ended || started).summary
    }
  end

  defp run_verdict_json(%Event{payload: payload} = verdict) do
    %{
      kind: Map.get(payload, :kind),
      outcome: Map.get(payload, :outcome),
      head: Map.get(payload, :head) || verdict.head_sha,
      at: DateTime.to_iso8601(verdict.at)
    }
  end

  defp payload_field(nil, _key), do: nil
  defp payload_field(%Event{payload: payload}, key), do: Map.get(payload, key)

  # One read of the ticket's artifacts for the whole page, skipped when the page names none. A store
  # that can't be read answers an error, which `Map.new/2` raises on, as the feed's other reads do.
  defp ticket_artifacts(repo_key, issue_id, events) do
    if Enum.any?(events, &(&1.artifacts != [])),
      do: [repo_key: repo_key, issue_id: issue_id] |> Artifacts.list() |> Map.new(&{&1.id, &1}),
      else: %{}
  end

  defp ticket_event_json(%Event{} = event, artifacts) do
    %{
      id: event.id,
      seq: event.seq,
      at: event.at && DateTime.to_iso8601(event.at),
      type: event.type,
      phase: event.phase,
      actor: event.actor,
      run_id: event.run_id,
      head_sha: event.head_sha,
      parent: event.parent,
      supersedes: event.supersedes,
      idempotency: event.idempotency,
      payload: event.payload,
      summary: event.summary,
      artifacts: Enum.map(event.artifacts, &ticket_artifact_json(&1, artifacts))
    }
  end

  defp ticket_artifact_json(id, artifacts) do
    case Map.fetch(artifacts, id) do
      {:ok, artifact} ->
        %{
          id: id,
          kind: artifact.kind,
          mime: artifact.mime,
          label: artifact.label,
          available: not Map.get(artifact, :expired, false),
          url: "/api/v1/artifacts/" <> id
        }

      :error ->
        %{id: id, kind: nil, mime: nil, label: nil, available: false, url: nil}
    end
  end

  defp normalize_token_map(tokens) when is_map(tokens) do
    input_tokens = integer_map_value(tokens, :input_tokens)
    cached_input_tokens = integer_map_value(tokens, :cached_input_tokens)

    uncached_input_tokens =
      integer_map_value(tokens, :uncached_input_tokens, uncached_input_tokens(input_tokens, cached_input_tokens))

    cache_creation_input_tokens = integer_map_value(tokens, :cache_creation_input_tokens)

    %{
      input_tokens: uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cached_input_tokens: cached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      output_tokens: integer_map_value(tokens, :output_tokens),
      total_tokens: integer_map_value(tokens, :total_tokens)
    }
  end

  # How long this Symphony has run: the Erlang VM's wall clock since it started.
  defp uptime_seconds do
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp normalize_pollers(pollers) when is_map(pollers) do
    %{
      ci: normalize_poller_status(Map.get(pollers, :ci, Map.get(pollers, "ci"))),
      pr_review: normalize_poller_status(Map.get(pollers, :pr_review, Map.get(pollers, "pr_review")))
    }
  end

  defp normalize_pollers(_pollers), do: %{ci: :unavailable, pr_review: :unavailable}

  # Linear requests per caller and per query over the last hour, busiest first.
  defp normalize_linear_usage(%{window_ms: window_ms, total: total, callers: callers, queries: queries}) do
    %{
      window_ms: window_ms,
      total: total,
      callers: Enum.map(callers, &Map.take(&1, [:caller, :requests])),
      queries: Enum.map(queries, &Map.take(&1, [:query, :requests]))
    }
  end

  defp normalize_linear_usage(_usage), do: %{window_ms: 3_600_000, total: 0, callers: [], queries: []}

  # The Linear webhook's settings, the deliveries counted since Symphony started with what observing
  # them into the record did, and how often a later read found the webhook first or the poll first.
  # The Setup server's payload; without a running server, the payload of one that hasn't checked yet.
  defp setup_payload(setup) do
    case Setup.payload(setup) do
      {:error, :not_running} -> Setup.not_checked_yet()
      payload -> payload
    end
  end

  defp linear_webhooks_payload do
    settings = LinearWebhook.settings()
    summary = LinearWebhookDeliveries.summary()
    compare = TicketObservation.summary().compare

    %{
      enabled: settings.enabled,
      secret_configured: LinearWebhook.secret(settings) != nil,
      total: summary.total,
      rejected: summary.rejected,
      last_at: iso8601(summary.last_at),
      last_type: summary.last_type,
      last_action: summary.last_action,
      last_rejected_at: iso8601(summary.last_rejected_at),
      last_rejected_reason: summary.last_rejected_reason,
      counts: summary.counts,
      rejected_reasons: summary.rejected_reasons,
      observations: summary.observations,
      recent: Enum.map(summary.recent, &%{&1 | received_at: iso8601(&1.received_at)}),
      compare: %{
        webhook_first: compare.webhook_first,
        poll_first: compare.poll_first,
        poll_first_recent: Enum.map(compare.poll_first_recent, &%{&1 | at: iso8601(&1.at)})
      }
    }
  end

  # Where dispatch reads its candidates from (`dispatch.source`), and how the candidates the ticket
  # records give compared with the poll cache's (`SymphonyElixir.Dispatch.Shadow`): cycles compared
  # and with a difference, the differences of the last `window` cycles, the last ten that appeared,
  # newest first, and the differences the record's newer write explained (`record_newer`: how many,
  # and the identifier and side of the last five, newest first).
  defp dispatch_shadow_payload do
    summary = DispatchShadow.summary()

    %{
      source: Config.dispatch_source(),
      window: Config.dispatch_shadow_window(),
      cycles_compared: summary.cycles_compared,
      cycles_with_differences: summary.cycles_with_differences,
      window_cycles: summary.window_cycles,
      window_differences: summary.window_differences,
      recent: Enum.map(summary.recent, &%{&1 | at: iso8601(&1.at)}),
      record_newer: summary.record_newer
    }
  end

  # The last startup's backfill of the holds and decisions into pauses and questions
  # (`SymphonyElixir.Pauses.Backfill`): the records it read and converted, the pauses and questions
  # it created and what it skipped; nil before it ran.
  defp pause_backfill_payload(%{at: at} = summary), do: %{summary | at: iso8601(at)}
  defp pause_backfill_payload(nil), do: nil

  # The reconciler under `dispatch.source: record` (`TicketObservation.reconcile_all/3`): when it last
  # ran, its interval, the changes made in Linear it applied, the failed projections it made again and
  # the never observed records it filled; and the drift observations found on phases Symphony owns:
  # how many, how many were moved back in Linear and how many failed to, and the last ten, newest
  # first, with the ticket, both states and the outcome.
  defp reconcile_payload do
    %{drift: drift, reconcile: reconcile} = TicketObservation.summary()

    %{
      last_run_at: iso8601(reconcile.last_run_at),
      interval_ms: Config.linear_reconcile_interval_ms(),
      applied: reconcile.applied,
      reapplied: reconcile.reapplied,
      unobserved_filled: reconcile.unobserved_filled,
      detected: drift.detected,
      reverted: drift.reverted,
      revert_failed: drift.revert_failed,
      recent: Enum.map(drift.recent, &%{&1 | at: iso8601(&1.at)})
    }
  end

  defp normalize_poller_status(%{} = status) do
    %{
      status: Map.get(status, :status, Map.get(status, "status")),
      consecutive_failures: integer_map_value(status, :consecutive_failures),
      current_backoff_ms: integer_or_nil(Map.get(status, :current_backoff_ms, Map.get(status, "current_backoff_ms"))),
      poll_interval_ms: integer_or_nil(Map.get(status, :poll_interval_ms, Map.get(status, "poll_interval_ms"))),
      webhooks: normalize_webhooks(Map.get(status, :webhooks))
    }
  end

  defp normalize_poller_status(:unavailable), do: :unavailable
  defp normalize_poller_status(_status), do: :unavailable

  # GitHub webhook deliveries the PR and CI watcher has seen, how many CI results arrived through
  # them versus through the timed poll, and each repository's delivery health
  # (`SymphonyElixir.PrWatch.Health`).
  defp normalize_webhooks(%{} = webhooks) do
    %{
      enabled: Map.get(webhooks, :enabled) == true,
      relay: Map.get(webhooks, :relay),
      last_event_at: iso8601(Map.get(webhooks, :last_event_at)),
      events_received: integer_map_value(webhooks, :events_received),
      rejected: integer_map_value(webhooks, :rejected),
      results_via_webhook: integer_map_value(webhooks, :results_via_webhook),
      results_via_poll: integer_map_value(webhooks, :results_via_poll),
      repos: webhooks |> Map.get(:repos, %{}) |> Map.new(fn {repo_key, health} -> {repo_key, normalize_delivery_health(health)} end)
    }
  end

  defp normalize_webhooks(_webhooks), do: nil

  defp normalize_delivery_health(health) do
    %{
      healthy: Map.get(health, :healthy) == true,
      silent: Map.get(health, :silent) == true,
      last_delivery_at: iso8601(Map.get(health, :last_delivery_at)),
      signature_failures_24h: integer_map_value(health, :signature_failures_24h),
      missed: integer_map_value(health, :missed),
      missed_at: iso8601(Map.get(health, :missed_at))
    }
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp integer_map_value(map, key, default \\ 0) do
    string_key = Atom.to_string(key)

    case Map.get(map, key, Map.get(map, string_key, default)) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, watching, waiting) do
    entries = [running, retry, watching, waiting && elem(waiting, 1)]

    payload = %{
      repo_key: repo_key_from_entries(entries),
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(entries),
      status: issue_status(running, retry, watching, waiting),
      workspace: workspace_payload(issue_identifier, running, retry),
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }

    payload
    |> put_watching_issue_payload(watching)
    |> put_waiting_issue_payload(waiting)
    |> put_connected_payload(entries)
  end

  # Where a tracked ticket sits among the others, from what the orchestrator holds
  # (`SymphonyElixir.Connected`); an untracked ticket has none.
  defp put_connected_payload(payload, entries) do
    case Enum.find_value(entries, &(&1 && Map.get(&1, :connected))) do
      nil -> payload
      connected -> Map.put(payload, :connected, connected)
    end
  end

  defp put_watching_issue_payload(payload, nil), do: payload
  defp put_watching_issue_payload(payload, watching), do: Map.put(payload, :watching, watching_issue_payload(watching))

  defp put_waiting_issue_payload(payload, nil), do: payload
  defp put_waiting_issue_payload(payload, {list, entry}), do: Map.put(payload, list, waiting_issue_payload(entry))

  defp issue_id_from_entries(entries), do: Enum.find_value(entries, &(&1 && &1.issue_id))

  defp repo_key_from_entries(entries), do: Enum.find_value(entries, &(&1 && Map.get(&1, :repo_key)))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, retry, watching, waiting) do
    cond do
      running -> "running"
      retry -> "retrying"
      watching -> "watching"
      waiting -> waiting |> elem(0) |> Atom.to_string()
      true -> "untracked"
    end
  end

  defp sessions_payload(running) do
    running
    |> Sessions.list()
    |> Enum.map(&%{&1 | started_at: iso8601(&1.started_at)})
  end

  defp running_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_kind: Map.get(entry, :run_kind),
      run_profile: profile_payload(Map.get(entry, :run_profile)),
      reviewer_profile: profile_payload(Map.get(entry, :reviewer_run_profile)),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: running_message(entry),
      linear_wait_until: entry |> Map.get(:linear_wait_until) |> iso8601(),
      pending_tool: entry |> Map.get(:pending_tool) |> pending_tool_payload(),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(Map.get(entry, :last_event_at) || entry.last_codex_timestamp),
      forced: Map.get(entry, :forced, false),
      tokens: %{
        input_tokens: entry_input_tokens(entry),
        uncached_input_tokens: entry_uncached_input_tokens(entry),
        cached_input_tokens: entry_cached_input_tokens(entry),
        cache_creation_input_tokens: entry_cache_creation_input_tokens(entry),
        output_tokens: entry_output_tokens(entry),
        total_tokens: entry_total_tokens(entry)
      }
    }
  end

  defp watching_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      last_ran_at: iso8601(entry.last_ran_at),
      seconds_since_last_run: entry.seconds_since_last_run
    }
  end

  defp drain_report_payload(%{stragglers: stragglers, landed: landed}) do
    %{
      stragglers:
        Enum.map(stragglers, fn straggler ->
          %{
            issue_id: straggler.id,
            issue_identifier: straggler.identifier || straggler.id,
            title: straggler.title,
            url: URLUtils.present_url(straggler.url),
            state: straggler.state,
            wait: Atom.to_string(straggler.wait),
            waits_on: straggler.waits_on,
            move: straggler.move
          }
        end),
      landed:
        Enum.map(landed, fn landing ->
          %{issue_id: landing.id, issue_identifier: landing.identifier || landing.id, from: landing.from, to: landing.to}
        end)
    }
  end

  defp waiting_on_you_payload(item, now) do
    %{
      issue_id: item.issue_id,
      issue_identifier: item.identifier,
      repo_key: item.repo_key,
      title: item.title,
      url: URLUtils.present_url(item.url),
      state: item.state,
      kind: Atom.to_string(item.kind),
      decision: decision?(item),
      headline: item.ask,
      waiting_since: iso8601(item.waiting_since),
      waiting_seconds: waiting_seconds(item.waiting_since, now)
    }
  end

  # A request with options reads "Decision" in the app, as the Inbox's does; an older hand-written
  # one with steps stays an action.
  defp decision?(%{kind: :action, review: %{options: [_ | _]}}), do: true
  defp decision?(_item), do: false

  defp waiting_seconds(%DateTime{} = since, now), do: max(DateTime.diff(now, since, :second), 0)
  defp waiting_seconds(_since, _now), do: nil

  defp conflict_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      linear_state: Map.get(entry, :linear_state),
      url: URLUtils.present_url(Map.get(entry, :url)),
      repo_keys: Map.get(entry, :repo_keys, [])
    }
  end

  defp retry_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      forced: Map.get(entry, :forced, false)
    }
  end

  defp awaiting_clarification_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      rounds_asked: Map.get(entry, :rounds_asked, 0),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp skipped_entry_payload(entry) do
    %{
      kind: entry |> Map.get(:kind) |> quality_gate_kind(),
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      error: entry |> Map.get(:error) |> quality_gate_error(),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp running_issue_payload(running) do
    %{
      repo_key: Map.get(running, :repo_key),
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      transcript_path: Map.get(running, :transcript_path),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: running_message(running),
      linear_wait_until: running |> Map.get(:linear_wait_until) |> iso8601(),
      pending_tool: running |> Map.get(:pending_tool) |> pending_tool_payload(),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      tokens: %{
        input_tokens: entry_input_tokens(running),
        uncached_input_tokens: entry_uncached_input_tokens(running),
        cached_input_tokens: entry_cached_input_tokens(running),
        cache_creation_input_tokens: entry_cache_creation_input_tokens(running),
        output_tokens: entry_output_tokens(running),
        total_tokens: entry_total_tokens(running)
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      repo_key: Map.get(retry, :repo_key),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  # What a ticket waiting for a slot or passed over by a dispatch gate waits on, and since when.
  defp waiting_issue_payload(entry) do
    %{state: entry.state, reason: entry.reason, since: iso8601(Map.get(entry, :since))}
  end

  defp watching_issue_payload(watching) do
    %{
      repo_key: Map.get(watching, :repo_key),
      state: watching.state,
      url: URLUtils.present_url(watching.url),
      pull_request_url: URLUtils.pull_request_url(watching),
      last_ran_at: iso8601(watching.last_ran_at),
      seconds_since_last_run: watching.seconds_since_last_run
    }
  end

  defp run_history_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_id: entry.run_id,
      kind: Map.get(entry, :kind, "agent"),
      run_kind: Map.get(entry, :run_kind),
      model: Map.get(entry, :model),
      effort: Map.get(entry, :effort),
      profile_label: RunKind.label(entry),
      reviewer_profile: entry |> Map.get(:reviewer_profile) |> profile_payload(),
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      status: entry.status,
      attempt: Map.get(entry, :attempt),
      started_at: iso8601(entry.started_at),
      ended_at: iso8601(Map.get(entry, :ended_at)),
      error: Map.get(entry, :error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: Map.get(entry, :tokens, %{}),
      review_inconclusive_cause: Map.get(entry, :review_inconclusive_cause)
    }
  end

  # The run history's inconclusive Code Review runs, counted per cause (`ReviewAgent.inconclusive_cause/1`).
  defp review_inconclusive_counts(run_history) do
    run_history
    |> Enum.map(&Map.get(&1, :review_inconclusive_cause))
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
  end

  # Accepts the in-memory profile (`kind`) and the stored run record form (`run_kind`).
  defp profile_payload(nil), do: nil

  defp profile_payload(profile) do
    %{
      kind: to_string(Map.get(profile, :kind) || Map.get(profile, :run_kind)),
      model: Map.get(profile, :model),
      effort: Map.get(profile, :effort),
      label: RunKind.label(profile)
    }
  end

  defp normalize_codex_totals(totals) when is_map(totals) do
    normalized = Map.merge(@empty_codex_totals, totals)
    input_tokens = integer_map_value(totals, :input_tokens)
    cached_input_tokens = integer_map_value(totals, :cached_input_tokens)
    cache_creation_input_tokens = integer_map_value(totals, :cache_creation_input_tokens)

    uncached =
      if Map.has_key?(totals, :uncached_input_tokens) or Map.has_key?(totals, "uncached_input_tokens") do
        integer_map_value(totals, :uncached_input_tokens)
      else
        uncached_input_tokens(input_tokens, cached_input_tokens)
      end

    normalized
    |> Map.put(:input_tokens, uncached + cached_input_tokens + cache_creation_input_tokens)
    |> Map.put(:uncached_input_tokens, uncached)
    |> Map.put(:cached_input_tokens, cached_input_tokens)
    |> Map.put(:cache_creation_input_tokens, cache_creation_input_tokens)
    |> Map.put(:output_tokens, integer_map_value(totals, :output_tokens))
    |> Map.put(:total_tokens, integer_map_value(totals, :total_tokens))
  end

  defp normalize_codex_totals(_totals), do: @empty_codex_totals

  defp repo_keys(snapshot) when is_map(snapshot) do
    [
      snapshot |> Map.get(:running, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:watching, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:retrying, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:awaiting_clarification, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:skipped, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:conflicts, []) |> Enum.flat_map(&(Map.get(&1, :repo_keys, []) || []))
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Symphony's own pause (`SymphonyElixir.Pauses.dispatch_status/1`): `paused`, `reason` and
  # `paused_at` as the operator pause read before (the menu bar app finds an update's version in
  # `reason`), and every reason with its kind, line, time and what it waits on.
  defp normalize_pause(pause) when is_map(pause) do
    %{
      paused: Map.get(pause, :paused, false),
      reason: Map.get(pause, :reason),
      paused_at: iso8601(Map.get(pause, :paused_at)),
      reasons: pause |> Map.get(:reasons, []) |> Enum.map(&pause_reason_payload/1)
    }
  end

  defp normalize_pause(_pause) do
    %{paused: false, reason: nil, paused_at: nil, reasons: []}
  end

  defp pause_reason_payload(reason),
    do: %{kind: reason.kind, text: reason.text, since: iso8601(Map.get(reason, :since)), waits_on: reason.waits_on}

  defp usage_limit_payload(entry, now) do
    %{
      provider: entry.provider,
      scope: UsageLimit.scope_label(entry.scope),
      reason: Map.get(entry, :reason),
      window: Map.get(entry, :window),
      phase: optional_string(Map.get(entry, :phase)),
      since: iso8601(Map.get(entry, :since)),
      resets_at: iso8601(Map.get(entry, :resets_at)),
      resume_at: iso8601(entry.resume_at),
      source: optional_string(Map.get(entry, :source)),
      error: Map.get(entry, :error),
      utilization: Map.get(entry, :utilization),
      issue_identifier: Map.get(entry, :issue_identifier),
      banner: UsageLimit.banner(entry, now)
    }
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp normalize_budget(budget) when is_map(budget) do
    %{
      per_issue_limit: Map.get(budget, :per_issue_limit),
      daily_limit: Map.get(budget, :daily_limit),
      daily_used: Map.get(budget, :daily_used, 0),
      daily_remaining: Map.get(budget, :daily_remaining),
      daily_paused: Map.get(budget, :daily_paused, false)
    }
  end

  defp normalize_budget(_budget) do
    %{
      per_issue_limit: nil,
      daily_limit: nil,
      daily_used: 0,
      daily_remaining: nil,
      daily_paused: false
    }
  end

  defp normalize_epic_lanes(%{lanes: lanes, queued_epics: queued, shared: shared} = epic_lanes) do
    %{
      max_total: Map.get(epic_lanes, :max_total),
      lanes: lanes,
      queued_epics: queued,
      shared: shared
    }
  end

  defp normalize_epic_lanes(_epic_lanes), do: %{max_total: nil, lanes: [], queued_epics: [], shared: %{slots: nil, used: 0}}

  defp normalize_finishing(%{slots: slots, used: used, running: running}), do: %{slots: slots, used: used, running: running}
  defp normalize_finishing(_finishing), do: %{slots: nil, used: 0, running: []}

  defp landing_wait_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      pull_request_url: entry.pr_url,
      state: entry.state,
      waits_for: %{
        issue_id: entry.waits_for.issue_id,
        issue_identifier: entry.waits_for.issue_identifier,
        pull_request_url: entry.waits_for.pr_url,
        state: entry.waits_for.state
      },
      shared_files: entry.shared_files,
      files: entry.files,
      reason: entry.reason,
      since: iso8601(entry.since)
    }
  end

  defp auto_merge_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      pull_request_url: entry.pr_url,
      state: entry.state,
      head_sha: entry.head_sha,
      status: entry.status,
      updated_at: iso8601(entry.updated_at)
    }
  end

  defp shipped_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      repo_key: entry.repo_key,
      completed_at: iso8601(entry.completed_at)
    }
  end

  defp slot_waiting_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      repo_key: Map.get(entry, :repo_key),
      title: Map.get(entry, :title),
      state: entry.state,
      reason: entry.reason,
      attempt: Map.get(entry, :attempt),
      since: iso8601(Map.get(entry, :since)),
      forced: Map.get(entry, :forced, false)
    }
  end

  defp dispatch_skipped_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      repo_key: Map.get(entry, :repo_key),
      title: Map.get(entry, :title),
      state: entry.state,
      reason: entry.reason,
      since: iso8601(Map.get(entry, :since))
    }
  end

  defp blocked_payload(entry) do
    blockers = Enum.map(entry.blockers, &%{issue_identifier: &1.identifier, state: &1.state})
    reason = Map.get(entry, :reason)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      kind: entry |> Map.get(:kind, :blockers) |> Atom.to_string(),
      reason: reason,
      blocked_by: blockers,
      summary: blocked_summary(entry.identifier, reason, blockers)
    }
  end

  defp blocked_summary(identifier, reason, _blockers) when is_binary(reason), do: "#{identifier} #{reason}"
  defp blocked_summary(identifier, nil, blockers), do: "#{identifier} waiting on " <> Enum.map_join(blockers, ", ", &blocker_label/1)

  # Tickets an app update would release: each one waits only for the running app to include a fix.
  defp forced_payload(entry) do
    status = %{
      phase: Map.get(entry, :phase),
      running: Map.get(entry, :running, false),
      waiting_on: Map.get(entry, :waiting_on),
      blockers: Map.get(entry, :blockers, [])
    }

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      repo_key: Map.get(entry, :repo_key),
      state: entry.state,
      forced_since: iso8601(entry.forced_since),
      forced_for_seconds: Map.get(entry, :forced_for_seconds),
      stale: Map.get(entry, :stale, false),
      position: entry.position,
      waiting_on_human: Map.get(entry, :waiting_on_human, false),
      sub_issue: forced_sub_issue_payload(Map.get(entry, :sub_issue))
    }
    |> Map.merge(status)
    |> Map.put(:summary, if(status.phase, do: ForcedStatus.summary(status)))
  end

  defp forced_sub_issue_payload(%{issue_id: issue_id} = part),
    do: %{issue_id: issue_id, issue_identifier: Map.get(part, :identifier), state: Map.get(part, :state)}

  defp forced_sub_issue_payload(_no_part), do: nil

  defp blocker_label(%{issue_identifier: identifier, state: state}) do
    "#{identifier || "an unknown issue"} (#{state || "unknown state"})"
  end

  defp normalize_dispatch_state(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, :dispatch_state) do
      %{active?: active?, blockers: blockers} when is_list(blockers) ->
        normalized =
          blockers
          |> Enum.map(&normalize_blocker/1)
          |> Enum.reject(&is_nil/1)

        %{active?: active? == true or normalized == [], blockers: normalized}

      _ ->
        synthesize_dispatch_state(snapshot)
    end
  end

  # Backwards-compat fallback for snapshots that don't carry an explicit
  # dispatch_state (older test fixtures or external callers). Derives manual
  # and budget blockers from the legacy pause/budget fields.
  defp synthesize_dispatch_state(snapshot) do
    pause = Map.get(snapshot, :pause)
    budget = Map.get(snapshot, :budget)

    blockers =
      []
      |> maybe_synth_manual(pause)
      |> maybe_synth_budget(budget)
      |> Enum.reverse()

    %{active?: blockers == [], blockers: blockers}
  end

  defp maybe_synth_manual(blockers, %{paused: true} = pause) do
    [
      %{
        kind: :manual,
        reason: Map.get(pause, :reason),
        since: iso8601(Map.get(pause, :paused_at))
      }
      | blockers
    ]
  end

  defp maybe_synth_manual(blockers, _pause), do: blockers

  defp maybe_synth_budget(blockers, %{daily_paused: true} = budget) do
    [
      %{
        kind: :budget,
        used: Map.get(budget, :daily_used, 0),
        limit: Map.get(budget, :daily_limit, 0),
        day_started_on: nil,
        resets_on: nil
      }
      | blockers
    ]
  end

  defp maybe_synth_budget(blockers, _budget), do: blockers

  defp normalize_blocker(%{kind: :manual} = b) do
    %{
      kind: :manual,
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since)),
      reasons: Map.get(b, :reasons, [])
    }
  end

  defp normalize_blocker(%{kind: :budget} = b) do
    %{
      kind: :budget,
      used: Map.get(b, :used, 0),
      limit: Map.get(b, :limit, 0),
      day_started_on: Map.get(b, :day_started_on),
      resets_on: Map.get(b, :resets_on)
    }
  end

  defp normalize_blocker(%{kind: :missing_api_key} = b) do
    %{kind: :missing_api_key, provider: Map.get(b, :provider)}
  end

  defp normalize_blocker(%{kind: :config_invalid} = b) do
    %{
      kind: :config_invalid,
      message: Map.get(b, :message),
      since: iso8601(Map.get(b, :since)),
      consecutive_failures: Map.get(b, :consecutive_failures, 0)
    }
  end

  defp normalize_blocker(%{kind: :tracker_unavailable} = b) do
    %{
      kind: :tracker_unavailable,
      tracker: Map.get(b, :tracker),
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since)),
      consecutive_failures: Map.get(b, :consecutive_failures, 0)
    }
  end

  defp normalize_blocker(%{kind: :usage_limit} = b) do
    %{
      kind: :usage_limit,
      provider: Map.get(b, :provider),
      scope: UsageLimit.scope_label(Map.get(b, :scope, :all)),
      reason: Map.get(b, :reason),
      window: Map.get(b, :window),
      phase: optional_string(Map.get(b, :phase)),
      resets_at: iso8601(Map.get(b, :resets_at)),
      resume_at: iso8601(Map.get(b, :resume_at)),
      text: Map.get(b, :text)
    }
  end

  defp normalize_blocker(_), do: nil

  defp quality_gate_identifier(entry) do
    Map.get(entry, :identifier) || Map.get(entry, :issue_id) || "unknown"
  end

  defp quality_gate_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp quality_gate_kind(kind) when is_binary(kind), do: kind
  defp quality_gate_kind(_kind), do: "unknown"

  defp quality_gate_error(nil), do: nil
  defp quality_gate_error(error) when is_binary(error), do: error
  defp quality_gate_error(error), do: inspect(error)

  defp workspace_payload(issue_identifier, running, retry) do
    if running || retry do
      %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      }
    end
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Path.expand(Config.settings!().workspace.root), issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp running_transcript_payload(running, repo_key) do
    tokens = transcript_tokens(running)
    reviewer_tokens = transcript_reviewer_tokens(running)

    %{
      repo_key: Map.get(running, :repo_key) || repo_key,
      issue_id: running.issue_id,
      issue_identifier: running.identifier,
      state: running.state,
      session_id: running.session_id,
      started_at: iso8601(running.started_at),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      turn_count: Map.get(running, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(running, reviewer_tokens),
      events: transcript_events(running)
    }
  end

  defp watching_transcript_payload(watching, repo_key) do
    tokens = transcript_tokens(watching)
    reviewer_tokens = transcript_reviewer_tokens(watching)

    %{
      repo_key: Map.get(watching, :repo_key) || repo_key,
      issue_id: watching.issue_id,
      issue_identifier: watching.identifier,
      state: watching.state,
      session_id: Map.get(watching, :session_id),
      started_at: iso8601(Map.get(watching, :started_at) || Map.get(watching, :last_ran_at)),
      last_event_at: iso8601(Map.get(watching, :last_event_at) || Map.get(watching, :last_ran_at)),
      turn_count: Map.get(watching, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(watching, reviewer_tokens),
      events: transcript_events(watching)
    }
  end

  defp retry_transcript_payload(retry, repo_key) do
    tokens = transcript_tokens(retry)
    reviewer_tokens = transcript_reviewer_tokens(retry)

    %{
      repo_key: Map.get(retry, :repo_key) || repo_key,
      issue_id: retry.issue_id,
      issue_identifier: retry.identifier,
      state: Map.get(retry, :state, "retrying"),
      session_id: Map.get(retry, :session_id),
      started_at: iso8601(Map.get(retry, :started_at)),
      last_event_at: iso8601(Map.get(retry, :last_event_at) || Map.get(retry, :last_ran_at)),
      turn_count: Map.get(retry, :turn_count, 0),
      tokens: tokens,
      executor_tokens: executor_tokens(tokens, reviewer_tokens),
      reviewer_tokens: reviewer_tokens,
      review_agent_enabled: review_agent_enabled?(retry, reviewer_tokens),
      events: transcript_events(retry)
    }
  end

  defp transcript_tokens(%{tokens: tokens}) when is_map(tokens) do
    input_tokens = Map.get(tokens, :input_tokens, 0)
    cached_input_tokens = Map.get(tokens, :cached_input_tokens, 0)
    cache_creation_input_tokens = Map.get(tokens, :cache_creation_input_tokens, 0)
    uncached_input_tokens = Map.get(tokens, :uncached_input_tokens, uncached_input_tokens(input_tokens, cached_input_tokens))

    %{
      input_tokens: uncached_input_tokens + cached_input_tokens + cache_creation_input_tokens,
      uncached_input_tokens: uncached_input_tokens,
      cached_input_tokens: cached_input_tokens,
      cache_creation_input_tokens: cache_creation_input_tokens,
      output_tokens: Map.get(tokens, :output_tokens, 0),
      total_tokens: Map.get(tokens, :total_tokens, 0)
    }
  end

  defp transcript_tokens(entry) when is_map(entry) do
    %{
      input_tokens: entry_input_tokens(entry),
      uncached_input_tokens: entry_uncached_input_tokens(entry),
      cached_input_tokens: entry_cached_input_tokens(entry),
      cache_creation_input_tokens: entry_cache_creation_input_tokens(entry),
      output_tokens: entry_output_tokens(entry),
      total_tokens: entry_total_tokens(entry)
    }
  end

  defp transcript_reviewer_tokens(%{reviewer_tokens: tokens}) when is_map(tokens), do: normalize_token_map(tokens)

  defp transcript_reviewer_tokens(entry) when is_map(entry) do
    %{
      input_tokens: reviewer_input_tokens(entry),
      uncached_input_tokens: reviewer_uncached_input_tokens(entry),
      cached_input_tokens: Map.get(entry, :reviewer_cached_input_tokens, 0),
      cache_creation_input_tokens: Map.get(entry, :reviewer_cache_creation_input_tokens, 0),
      output_tokens: Map.get(entry, :reviewer_output_tokens, 0),
      total_tokens: Map.get(entry, :reviewer_total_tokens, 0)
    }
  end

  defp executor_tokens(tokens, reviewer_tokens) do
    %{
      input_tokens: subtract_token(tokens, reviewer_tokens, :input_tokens),
      uncached_input_tokens: subtract_token(tokens, reviewer_tokens, :uncached_input_tokens),
      cached_input_tokens: subtract_token(tokens, reviewer_tokens, :cached_input_tokens),
      cache_creation_input_tokens: subtract_token(tokens, reviewer_tokens, :cache_creation_input_tokens),
      output_tokens: subtract_token(tokens, reviewer_tokens, :output_tokens),
      total_tokens: subtract_token(tokens, reviewer_tokens, :total_tokens)
    }
  end

  defp subtract_token(tokens, reviewer_tokens, key) do
    max(Map.get(tokens, key, 0) - Map.get(reviewer_tokens, key, 0), 0)
  end

  defp review_agent_enabled?(entry, reviewer_tokens) do
    Map.get(entry, :review_agent_enabled, false) == true or Map.get(reviewer_tokens, :total_tokens, 0) > 0
  end

  defp transcript_payload_from_snapshot(snapshot, repo_key, issue_identifier) do
    case transcript_entry(snapshot, repo_key, issue_identifier) do
      {:running, running} -> {:ok, running_transcript_payload(running, repo_key)}
      {:watching, watching} -> {:ok, watching_transcript_payload(watching, repo_key)}
      {:retry, retry} -> {:ok, retry_transcript_payload(retry, repo_key)}
      nil -> {:error, :issue_not_found}
    end
  end

  defp transcript_entry(snapshot, repo_key, issue_identifier) do
    [
      {:running, Map.get(snapshot, :running, [])},
      {:watching, Map.get(snapshot, :watching, [])},
      {:retry, Map.get(snapshot, :retrying, [])}
    ]
    |> Enum.find_value(fn {kind, entries} ->
      case Enum.find(entries, &transcript_entry_matches?(&1, repo_key, issue_identifier)) do
        nil -> nil
        entry -> {kind, entry}
      end
    end)
  end

  defp transcript_entry_matches?(entry, repo_key, issue_identifier) do
    repo_key_matches?(entry, repo_key) and Map.get(entry, :identifier) == issue_identifier
  end

  defp transcript_events(entry) do
    Quality.transcript_file_events(Map.get(entry, :transcript_path)) ++ buffered_transcript_events(entry)
  end

  defp buffered_transcript_events(%{transcript_buffer: queue}) do
    cond do
      :queue.is_queue(queue) -> :queue.to_list(queue)
      is_list(queue) -> queue
      true -> []
    end
  end

  defp buffered_transcript_events(_entry), do: []

  defp repo_key_matches?(_entry, nil), do: true
  defp repo_key_matches?(entry, repo_key), do: Map.get(entry, :repo_key) == repo_key

  defp current_repo_key, do: Config.repo_key_or_nil()

  # A run waiting out a Linear rate limit or outage has no new agent message to show.
  defp running_message(%{linear_wait_until: %DateTime{}}), do: "waiting for Linear"
  # Nor does a run waiting on one of Symphony's own tool calls.
  defp running_message(%{pending_tool: %{name: name, age_ms: age_ms}}), do: "waiting on #{name} for #{div(age_ms, 60_000)}m"
  defp running_message(running), do: summarize_message(running.last_codex_message)

  defp pending_tool_payload(%{name: name, started_at: started_at, age_ms: age_ms}) do
    %{name: name, started_at: iso8601(started_at), age_ms: age_ms}
  end

  defp pending_tool_payload(_pending_tool), do: nil

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: MessageHumanizer.humanize(message)

  defp entry_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> uncached_input_tokens(Map.get(entry, :codex_input_tokens, 0), Map.get(entry, :codex_cached_input_tokens, 0))
    end
  end

  defp entry_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :uncached_input_tokens) do
      entry_uncached_input_tokens(entry) + entry_cached_input_tokens(entry) + entry_cache_creation_input_tokens(entry)
    else
      max(Map.get(entry, :codex_input_tokens, 0), 0)
    end
  end

  defp entry_cached_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cached_input_tokens, Map.get(entry, :codex_cached_input_tokens, 0)), 0)

  defp entry_cache_creation_input_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :cache_creation_input_tokens, Map.get(entry, :codex_cache_creation_input_tokens, 0)), 0)

  defp entry_output_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :output_tokens, Map.get(entry, :codex_output_tokens, 0)), 0)

  defp entry_total_tokens(entry) when is_map(entry),
    do: max(Map.get(entry, :total_tokens, Map.get(entry, :codex_total_tokens, 0)), 0)

  defp reviewer_uncached_input_tokens(entry) when is_map(entry) do
    case Map.get(entry, :reviewer_uncached_input_tokens) do
      value when is_integer(value) -> max(value, 0)
      _ -> uncached_input_tokens(Map.get(entry, :reviewer_input_tokens, 0), Map.get(entry, :reviewer_cached_input_tokens, 0))
    end
  end

  defp reviewer_input_tokens(entry) when is_map(entry) do
    if Map.has_key?(entry, :reviewer_uncached_input_tokens) do
      reviewer_uncached_input_tokens(entry) + Map.get(entry, :reviewer_cached_input_tokens, 0) +
        Map.get(entry, :reviewer_cache_creation_input_tokens, 0)
    else
      max(Map.get(entry, :reviewer_input_tokens, 0), 0)
    end
  end

  defp uncached_input_tokens(input_tokens, cached_input_tokens) when is_integer(input_tokens) and is_integer(cached_input_tokens) do
    max(input_tokens - cached_input_tokens, 0)
  end

  defp uncached_input_tokens(_input_tokens, _cached_input_tokens), do: 0

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
