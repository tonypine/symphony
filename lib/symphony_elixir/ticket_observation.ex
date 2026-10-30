defmodule SymphonyElixir.TicketObservation do
  @moduledoc """
  Writes what Symphony reads of a ticket in Linear into its record (`SymphonyElixir.TicketState`),
  so the record learns from every poll: the ticket's state as the record's `phase`, its title,
  description, team, project, labels, priority, assignee, open blockers and sub-issues (each by id,
  identifier and state), parent, URL, creation time and Linear's `updatedAt`.

  `observe/3` reads the record (a new one when the ticket has none), applies
  `SymphonyElixir.TicketState.observe/4` and writes the observed fields back through
  `SymphonyElixir.RunStore.update_ticket_state/3` only when one changed, so an identical poll writes
  nothing and a write never touches the record's holds, verdicts or other fields. A fact older than
  the record's `linear_updated_at` is dropped. The record keeps which read brought its last change
  (`observed_from`: the poll, a by-id read, the PR and CI watcher or a webhook delivery). Only
  `SymphonyElixir.Dispatch.Candidates` reads the observed fields, and an observation records no
  ledger event, except for drift.

  Drift: under `dispatch.source: record`, the phase of a record Symphony owns (`phase_owner:
  :symphony`, written by a move of Symphony's or the Director's) is not read back from Linear. When
  Linear says another state, the observation keeps the record's phase (the other fields apply as
  usual), records `drift.detected` with both states, moves the ticket back in Linear to the record's
  phase (`SymphonyElixir.Tracker.update_issue_state/2`) and records `drift.reverted`, or
  `drift.revert_failed` with the error (a crash of the move included). Nobody is asked: the hand move
  is rolled back. The move back runs in a task of its own once the record is written, so a slow
  Linear never holds up the read that found the drift, and a webhook delivery's bound never cuts it
  off before its outcome is recorded. A ticket has one move back under way at a time: an observation
  that finds the drift meanwhile adds nothing. A failed move back is tried again by the next
  observation that finds the same difference, never sooner, and each event is written once per
  Linear fact (its `updatedAt`). A Linear state read before the record's
  phase was written (`updatedAt` older than `phase_at`) is an older fact: the phase is kept and
  nothing is moved. A phase an observation wrote (`:external`, such as a new ticket's Todo) follows
  Linear, and under `dispatch.source: poll` every phase does, as before. A record the Director
  cancelled (`SymphonyElixir.DirectorMoves`' `:cancel`, phase `Canceled` owned by Symphony) is
  terminal once Linear took the cancel: a later Linear state is no drift on it, and is applied as
  Linear wrote it. While the cancel's Linear write is still pending (a `:phase` mark on the record),
  Linear's state is drift as on any phase Symphony owns, and the ticket is moved back to Canceled.

  `observe_delivery/2` observes what a Linear webhook delivery says (`SymphonyElixir.Linear.Webhook.parse/1`)
  the same way, under the repo that already holds the ticket's record, or marks the record removed. A
  ticket with no record yet is filed under the one repo whose poll scope takes it
  (`SymphonyElixir.Routing.PollScope`), from a by-id read of it. `observe_held/2` does the same for a
  by-id read, which carries no repo key either, and leaves a ticket with no record to the poll.

  A delivery that changes a record (`:updated`, or `:removed`) asks for a poll of the record's repo
  at once (`SymphonyElixir.Orchestrator.request_refresh/3`), so dispatch reads the change from Linear
  within seconds instead of at the next timed poll; the orchestrator coalesces the requests as it
  does Symphony's own moves. A by-id read or a poll asks for none.

  A write that changed a record, other than the poll's and a by-id read's, and a removal, are
  announced as `{:ticket_record, repo_key, issue_id, :changed, fields}`
  (`SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records/0`), `fields` naming the observed
  fields the write changed (all of them for a new record, `[:removed_at]` for a removal): with
  `dispatch.source: record` the orchestrator asks for a cycle of the ticket's repo at once, and the
  PR watcher re-decides the ticket when its phase or blockers changed. The poll's and the by-id
  reads' changes are not announced, since the cycle that made them dispatches from them right after.

  Every read other than a webhook delivery is compared with the webhook: a read that changes a field
  the webhook carries (state, identifier, title, labels, priority, assignee, URL) of an existing
  record, while `linear.webhooks.enabled` is on, counts as "poll first", and the last ten keep the
  ticket and the fields; a read that changes none of them while the record's last change came from a
  webhook counts as "webhook first", once for each change the webhook brought.

  Reconcile: under `dispatch.source: record` the repo poll runs on `linear.reconcile_interval_ms` and
  only reconciles the record with Linear (`reconcile_all/3`). It observes the repo's tickets as any
  poll does (a change made in Linear is applied, drift moved back), then, in a task of its own, projects
  again what the record marks as failed (`pending_projection`: a move of Symphony's whose Linear write
  failed, a hold's label) and reads by id the repo's records no read observed yet, once each. It never
  decides a phase: it re-projects the record's own.

  What each observation did, and the drift it found, are counted in a public ETS table owned by this
  server, for the state payload: the counts are diagnostic and start again from zero when Symphony
  restarts. Without the server (some tests), counting is a no-op and the summary is all zeros.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, DirectorMoves, Hold, Orchestrator, RunStore, TicketSignals, TicketState, Tracker}
  alias SymphonyElixir.Linear.{Issue, Webhook}
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.Routing.{PollScope, Resolver}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @table __MODULE__
  @outcomes [:updated, :unchanged, :stale]
  @recent_limit 10
  @canceled_phases ["canceled", "cancelled"]
  # The records no read observed yet that one reconcile reads by id: one Linear page.
  @fill_limit 50
  # Well under Linear's 5 s delivery timeout, which also covers the signature check and the relay.
  @delivery_timeout_ms 2_000
  # The record's fields an `Issue` webhook delivery carries, which a later read should find unchanged.
  @webhook_fields [:issue_identifier, :phase, :title, :labels, :priority, :assignee, :url]

  @type outcome :: :updated | :unchanged | :stale

  @typedoc """
  What `observe_delivery/2` did with a delivery: an observation's outcome, `:unrouted` (no repo, or
  several, hold a record of the ticket), `:removed` (a record marked removed), `:no_record` (a
  removal of a ticket with no record) or `:error` (the store refused it, or the observation crashed
  or timed out).
  """
  @type delivery_outcome :: outcome() | :unrouted | :removed | :no_record | :error

  @typedoc "How many observations had each outcome."
  @type counts :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          errors: non_neg_integer()
        }

  @typedoc "How many issues of a by-id read had each outcome, and how many no single repo holds."
  @type held_counts :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          unrouted: non_neg_integer(),
          errors: non_neg_integer()
        }

  @typedoc "A read that changed fields a webhook should have brought first."
  @type poll_first :: %{
          identifier: String.t() | nil,
          fields: [atom()],
          source: TicketState.observation_source(),
          at: DateTime.t()
        }

  @type compare :: %{webhook_first: non_neg_integer(), poll_first: non_neg_integer(), poll_first_recent: [poll_first()]}

  @typedoc "A drift an observation found on a phase Symphony owns, and whether moving the ticket back worked."
  @type drift_entry :: %{
          identifier: String.t() | nil,
          record_phase: String.t(),
          linear_phase: String.t(),
          outcome: :reverted | :revert_failed,
          at: DateTime.t()
        }

  @type drift :: %{
          detected: non_neg_integer(),
          reverted: non_neg_integer(),
          revert_failed: non_neg_integer(),
          recent: [drift_entry()]
        }

  @typedoc """
  What the reconciler did since Symphony started: when it last ran, how many changes made in Linear
  its observations applied, how many failed projections it made again, and how many records no read
  had observed it filled.
  """
  @type reconcile :: %{
          last_run_at: DateTime.t() | nil,
          applied: non_neg_integer(),
          reapplied: non_neg_integer(),
          unobserved_filled: non_neg_integer()
        }

  @type summary :: %{
          updated: non_neg_integer(),
          unchanged: non_neg_integer(),
          stale: non_neg_integer(),
          unrouted: non_neg_integer(),
          errors: non_neg_integer(),
          compare: compare(),
          drift: drift(),
          reconcile: reconcile()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Observes one `issue` of `repo_key`. `opts`:

  - `:now` — the observation time, defaulting to now
  - `:source` — the read it came from (`t:SymphonyElixir.TicketState.observation_source/0`),
    defaulting to `:poll`
  - `:terminal_states` — the states whose blockers no longer block, defaulting to the repo's
    `tracker.terminal_states`
  - `:compare` — whether a read that changes a webhook field counts as "poll first", defaulting to
    `linear.webhooks.enabled`
  - `:dispatch_source` — `"record"` or `"poll"`, defaulting to `dispatch.source`: under `"record"` a
    phase Symphony owns is kept and Linear moved back (see the module doc)
  - `:task_supervisor` — the `Task.Supervisor` the move back runs under, defaulting to
    `SymphonyElixir.TaskSupervisor`

  Returns `{:ok, :updated}` when the record changed and was written, `{:ok, :unchanged}` when it
  already held what the issue says, `{:ok, :stale}` when the issue is older than the record (it is
  dropped), and `{:error, reason}` when the store refused the read or the write.
  """
  @spec observe(String.t(), Issue.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def observe(repo_key, %Issue{id: issue_id} = issue, opts \\ []) when is_binary(issue_id) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    source = Keyword.get(opts, :source, :poll)
    issue = %{issue | blocked_by: open_blockers(issue, repo_key, opts)}

    result =
      with {:ok, stored} <- read(repo_key, issue_id),
           do: observe_record(repo_key, stored, issue, {now, source}, opts)

    count(result)
    result
  end

  @doc """
  Observes what a verified Linear webhook delivery says (`SymphonyElixir.Linear.Webhook.parse/1`):
  an `Issue` create or update goes through `observe/3` with `source: :webhook`, under the repo whose
  record of the ticket the reads already keep, and an `Issue` remove marks the ticket's record in
  every configured repo removed. Any other delivery is not observed, and gives nil.

  A ticket no configured repo has a record of yet (a new one) is filed under the one repo whose poll
  would return it, as `SymphonyElixir.Routing.PollScope.route/3` decides from the delivery's fields.
  A delivery carries no blockers or sub-issues, so the record is written from a by-id read of the
  ticket (`:tracker`'s `fetch_issue_states_by_ids/1`, default `SymphonyElixir.Tracker`), still with
  `source: :webhook`: a new record is `:updated`, asks for the poll below and is announced, so under
  `dispatch.source: record` a new ticket dispatches from its first delivery. A ticket no repo's scope
  or several take, or whose scope the delivery can't settle, is `:unrouted` and nothing is written:
  the next poll files it; so is one the read doesn't return, and a failed read is `:error`. A ticket
  held in several repos is `:unrouted` too, as the poll counts it a conflict.

  The work runs in a task bounded by `:timeout_ms` (default two seconds, well under the five Linear
  waits for an answer), so a crash or a hang is logged and returned as `:error`, never raised. A
  drift's move back runs outside that bound, in a task of its own.
  A delivery that updated a record, or marked one removed, asks the orchestrator for a poll of that
  repo at once; no other outcome asks for one.
  `opts`: `:repos`, `:timeout_ms`, `:orchestrator` (the server asked for the poll, default
  `SymphonyElixir.Orchestrator`), `:tracker`, `:tracker_settings` and `:viewer_id` (those of
  `SymphonyElixir.Routing.PollScope.route/3`), and those of `observe/3`.
  """
  @spec observe_delivery(Webhook.parsed(), keyword()) :: delivery_outcome() | nil
  def observe_delivery(parsed, opts \\ []) do
    if observed_delivery?(parsed), do: bounded(parsed, opts)
  end

  @doc """
  Observes every issue of `issues` for `repo_key` (see `observe/3`), and returns how many had each
  outcome. A store error is logged with the issue it was for and counted under `errors`; it never
  stops the others.
  """
  @spec observe_all(String.t(), [Issue.t()], keyword()) :: counts()
  def observe_all(repo_key, issues, opts) when is_list(issues) do
    opts = Keyword.put_new_lazy(opts, :terminal_states, fn -> terminal_states(repo_key) end)

    Enum.reduce(issues, empty_summary(), fn issue, acc ->
      case observe_issue(repo_key, issue, opts) do
        {:ok, outcome} ->
          Map.update!(acc, outcome, &(&1 + 1))

        {:error, reason} ->
          log_failure(repo_key, issue, reason)
          Map.update!(acc, :errors, &(&1 + 1))
      end
    end)
  end

  @doc """
  Reconciles `repo_key`'s ticket records with what the repo poll read of Linear (`issues`), as the
  repo poll does under `dispatch.source: record`. Each issue is observed (`observe_all/3`): a change
  made in Linear is applied (counted under `applied`), and drift on a phase Symphony owns is moved
  back. Then, in a task of its own (`:task_supervisor`), so the caller never waits on Linear:

  - each projection the record marks as failed (`TicketState.pending_projection`) is made again from
    the record as it is right before the write: a phase Symphony owns is written to Linear
    (`Tracker.update_issue_state/2`), a hold's label set or cleared as the record holds the hold
    (`Tracker.set_machine_label/2`, `Tracker.clear_machine_label/2`), the labels and Decisions
    section the pause projector renders applied again (`SymphonyElixir.Pauses.Projector.apply/2`),
    and that mark dropped (counted
    under `reapplied`); a newer mark written meanwhile stays. A projection the poll's issue already
    shows is dropped with no write; one whose phase is no longer Symphony's, or whose ticket was
    removed, is dropped too; one whose write fails stays for the next run.
  - the repo's records no read observed yet (no `linear_updated_at`, not removed, never found
    missing) and the poll did not return are read by id, at most 50 a run, and observed (counted
    under `unobserved_filled`). One Linear does not return (archived or deleted) is marked
    `not_found_at` and not read again.

  Returns the observations' counts. `opts`: `:tracker` (default `SymphonyElixir.Tracker`),
  `:task_supervisor` (default `SymphonyElixir.TaskSupervisor`), and those of `observe/3`.
  """
  @spec reconcile_all(String.t(), [Issue.t()], keyword()) :: counts()
  def reconcile_all(repo_key, issues, opts) when is_binary(repo_key) and is_list(issues) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    counts = observe_all(repo_key, issues, opts)
    remember_reconcile(now, counts.updated)
    follow_up(repo_key, issues, opts)
    counts
  end

  @doc """
  Observes the issues of a by-id read, which carries no repo key, the way `observe_delivery/2`
  observes a delivery: each issue goes through `observe/3` under the repo whose record of the ticket
  the reads already keep. A ticket no configured repo has a record of yet is skipped and counted
  `unrouted`, as the poll creates its record; one held in several repos is `unrouted` too, as the poll
  counts it a conflict. A store error is logged with the issue it was for and counted under `errors`.
  `opts`: `:repos`, defaulting to the configured repos, and those of `observe/3`.
  """
  @spec observe_held([Issue.t()], keyword()) :: held_counts()
  def observe_held(issues, opts \\ []) when is_list(issues) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)

    Enum.reduce(issues, Map.put(empty_summary(), :unrouted, 0), fn issue, acc ->
      {outcome, _repo_key} = observe_held_issue(issue, repos, opts)
      key = held_count_key(outcome)
      Map.update!(acc, key, &(&1 + 1))
    end)
  end

  @doc """
  Observes `issues` that may belong to several repos, such as the PR and CI watcher's read, which
  covers every repo. Each issue goes to the repo it routes to (`SymphonyElixir.Routing.Resolver.with_repo_key/2`;
  an issue that already has a key keeps it), and an issue no repo takes is skipped. `opts`: `:repos`,
  defaulting to the configured repos, and those of `observe/3`. Returns the outcomes across repos.
  """
  @spec observe_routed([Issue.t()], keyword()) :: counts()
  def observe_routed(issues, opts \\ []) when is_list(issues) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)

    issues
    |> Enum.flat_map(&route(&1, repos))
    |> Enum.group_by(fn {repo_key, _issue} -> repo_key end, fn {_repo_key, issue} -> issue end)
    |> Enum.reduce(empty_summary(), fn {repo_key, repo_issues}, acc ->
      Map.merge(acc, observe_all(repo_key, repo_issues, opts), fn _outcome, left, right -> left + right end)
    end)
  end

  @doc """
  How many observations had each outcome since Symphony started, how many issues of a by-id read or
  a delivery no single repo holds a record of (`unrouted`), the comparison with the
  webhook: how many reads found the webhook first, how many the poll first, and the last ten poll
  first, newest first, and the drift on phases Symphony owns: how many observations found it, how
  many moved the ticket back and how many failed to, and the last ten, newest first.
  """
  @spec summary() :: summary()
  def summary do
    entries = :ets.tab2list(@table)
    poll_first = lookup(entries, :poll_first, 0)
    detected = lookup(entries, :drift_detected, 0)

    counts = Map.new([:unrouted, :errors | @outcomes], &{&1, lookup(entries, &1, 0)})

    counts
    |> Map.put(:compare, %{
      webhook_first: lookup(entries, :webhook_first, 0),
      poll_first: poll_first,
      poll_first_recent: recent(entries, :poll_first, poll_first)
    })
    |> Map.put(:drift, %{
      detected: detected,
      reverted: lookup(entries, :drift_reverted, 0),
      revert_failed: lookup(entries, :drift_revert_failed, 0),
      recent: recent(entries, :drift, detected)
    })
    |> Map.put(:reconcile, %{
      last_run_at: lookup(entries, :reconcile_last_run_at, nil),
      applied: lookup(entries, :reconcile_applied, 0),
      reapplied: lookup(entries, :reconcile_reapplied, 0),
      unobserved_filled: lookup(entries, :reconcile_unobserved_filled, 0)
    })
  rescue
    ArgumentError ->
      empty_summary()
      |> Map.put(:unrouted, 0)
      |> Map.put(:compare, %{webhook_first: 0, poll_first: 0, poll_first_recent: []})
      |> Map.put(:drift, %{detected: 0, reverted: 0, revert_failed: 0, recent: []})
      |> Map.put(:reconcile, %{last_run_at: nil, applied: 0, reapplied: 0, unobserved_filled: 0})
  end

  @doc "Forgets every count."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp observe_issue(repo_key, %Issue{id: issue_id} = issue, opts) when is_binary(issue_id), do: observe(repo_key, issue, opts)

  defp observe_issue(_repo_key, _issue, _opts) do
    bump(:errors)
    {:error, :invalid_issue}
  end

  defp remember_reconcile(now, applied) do
    :ets.insert(@table, {:reconcile_last_run_at, now})
    bump(:reconcile_applied, applied)
  rescue
    ArgumentError -> :ok
  end

  # The reconcile's Linear writes and by-id read, in a task of its own. One that can't start is left
  # to the next run: the marks and the unobserved records stay as they are.
  defp follow_up(repo_key, issues, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
    polled = for %Issue{id: issue_id} = issue <- issues, is_binary(issue_id), into: %{}, do: {issue_id, issue}
    {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> reconcile_records(repo_key, polled, opts) end)
    :ok
  catch
    kind, reason -> Logger.warning("Ticket reconcile: the follow-up did not start repo_key=#{repo_key}: #{inspect({kind, reason})}")
  end

  defp reconcile_records(repo_key, polled, opts) do
    case RunStore.list_ticket_states(repo_key) do
      records when is_list(records) ->
        tracker = Keyword.get(opts, :tracker, Tracker)
        records = Enum.map(records, &TicketState.normalize/1)

        # A question's request comment is posted again by the Inbox's sweep, which reads the
        # ticket's comments (`SymphonyElixir.NeedsDecisionHold`), so it is never posted twice.
        for record <- records,
            mark <- record.pending_projection,
            mark.type != :question_comment,
            do: reproject(repo_key, record.issue_id, TicketState.projection_of(mark), Map.get(polled, record.issue_id), tracker)

        fill_unobserved(repo_key, records, polled, tracker, opts)

      {:error, reason} ->
        Logger.warning("Ticket reconcile: the records could not be read repo_key=#{repo_key}: #{inspect(reason)}")
    end

    :ok
  end

  # Makes a failed projection again from the record's truth, unless the poll already shows it or it
  # no longer applies, and drops its mark once Linear holds it. The record is read again right before
  # the write, so a move or a hold since the run listed the records is the one written; and only that
  # read's mark is dropped, so a mark written while Linear is written stays for the next run. A move
  # that lands in Linear between this read and the write is drift, which the next observation moves back.
  defp reproject(repo_key, issue_id, projection, polled, tracker) do
    with %{} = stored <- RunStore.get_ticket_state(repo_key, issue_id),
         record = TicketState.normalize(stored),
         %{} = mark <- Enum.find(record.pending_projection, &(TicketState.projection_of(&1) == projection)) do
      case projection_write(record, projection, polled) do
        :none -> TicketSignals.clear_projection(repo_key, issue_id, mark)
        write -> project_again(record, mark, write, tracker)
      end
    else
      # The record is gone or can't be read, or another run dropped the mark: nothing to project now.
      _none -> :ok
    end
  end

  defp project_again(record, mark, write, tracker) do
    case project_write(write, record, tracker) do
      :ok ->
        bump(:reconcile_reapplied)
        TicketSignals.clear_projection(record.repo_key, record.issue_id, mark)

      {:error, reason} ->
        Logger.warning(
          "Ticket reconcile: projecting #{inspect(TicketState.projection_of(mark))} again failed issue_id=#{record.issue_id} " <>
            "issue_identifier=#{record.issue_identifier}: #{inspect(reason)}"
        )
    end
  end

  # The write a mark asks for, or `:none` when there is nothing to write.
  defp projection_write(%{removed_at: %DateTime{}}, _projection, _polled), do: :none

  defp projection_write(record, :phase, polled) do
    cond do
      record.phase_owner != :symphony or not is_binary(record.phase) -> :none
      match?(%Issue{state: state} when state == record.phase, polled) -> :none
      true -> {:state, record.phase}
    end
  end

  # The reply to a question the Director answered while Linear refused it, with its Decisions entry
  # (`SymphonyElixir.DirectorMoves.project_answer/5`); a question no longer answered (reopened) has none.
  defp projection_write(record, {:question_answer, question_id, comment_id}, _polled) do
    case Enum.find(record.questions, &(&1.id == question_id)) do
      %{state: :answered} -> {:answer, question_id, comment_id}
      _not_answered -> :none
    end
  end

  # The labels and section the pause projector renders, from the record as it is now.
  defp projection_write(_record, :pause, _polled), do: :projector

  defp projection_write(record, {:hold_label, kind}, polled) do
    held? = TicketState.hold?(record, kind)
    name = Hold.label(kind)

    case polled do
      %Issue{labels: labels} when is_list(labels) ->
        if Enum.any?(labels, &(String.downcase(&1) == String.downcase(name))) == held?, do: :none, else: {:label, name, held?}

      _not_polled ->
        {:label, name, held?}
    end
  end

  defp project_write(write, %{issue_id: issue_id} = record, tracker) do
    case write do
      {:state, phase} -> tracker.update_issue_state(issue_id, phase)
      {:label, name, true} -> tracker.set_machine_label(issue_id, name)
      {:label, name, false} -> tracker.clear_machine_label(issue_id, name)
      {:answer, question_id, comment_id} -> project_answer(record, question_id, comment_id, tracker)
      :projector -> Projector.apply(record, tracker: tracker)
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp project_answer(record, question_id, comment_id, tracker),
    do: DirectorMoves.project_answer(record.repo_key, record.issue_id, question_id, comment_id, tracker: tracker)

  # The repo's records no read observed yet, read by id at most `@fill_limit` a run: one request when there
  # are any, none otherwise. A record Linear does not return (archived or deleted) is marked not found
  # and not read again, so the next run reads the next ones.
  defp fill_unobserved(repo_key, records, polled, tracker, opts) do
    ids =
      for %{linear_updated_at: nil, removed_at: nil, not_found_at: nil, issue_id: issue_id} <- records,
          not Map.has_key?(polled, issue_id),
          do: issue_id

    with [_ | _] = ids <- Enum.take(ids, @fill_limit),
         {:ok, issues} <- fetch_by_ids(tracker, ids) do
      counts = observe_all(repo_key, issues, Keyword.put(opts, :source, :by_id))
      bump(:reconcile_unobserved_filled, counts.updated)
      returned = MapSet.new(issues, & &1.id)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      for issue_id <- ids, not MapSet.member?(returned, issue_id), do: mark_not_found(repo_key, issue_id, now)
      :ok
    else
      [] -> :ok
      {:error, reason} -> Logger.warning("Ticket reconcile: reading the unobserved records failed repo_key=#{repo_key}: #{inspect(reason)}")
    end
  end

  defp mark_not_found(repo_key, issue_id, now) do
    case RunStore.update_ticket_state(repo_key, issue_id, %{not_found_at: now, updated_at: now}) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Ticket reconcile: marking a record not found failed issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    end
  end

  defp fetch_by_ids(tracker, ids) do
    tracker.fetch_issue_states_by_ids(ids)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp observe_record(repo_key, stored, %Issue{id: issue_id} = issue, {now, source}, opts) do
    record = stored || TicketState.new(repo_key, issue_id)
    owned = owned_phase(stored, issue, opts)

    case TicketState.observe(record, keep_phase(issue, owned), now, source) do
      {_record, :stale} ->
        {:ok, :stale}

      {_record, :unchanged} ->
        compare(source, stored, stored, now, opts)
        revert(owned, stored, issue, now, opts)
        {:ok, :unchanged}

      {observed, :changed} ->
        change = {repo_key, issue_id, changed(stored, observed)}
        revert = fn -> revert(owned, stored, issue, now, opts) end
        stored |> write_and_compare(observed, source, now, opts, revert) |> announce(change, source)
    end
  end

  defp observed_delivery?({:issue, _action, %Issue{}, _updated_at}), do: true
  defp observed_delivery?({:issue_removed, issue_id, _identifier}), do: is_binary(issue_id)
  defp observed_delivery?(_parsed), do: false

  # A changed record is announced (`ObservabilityPubSub.subscribe_ticket_records/0`), so dispatch from
  # the record considers it at once; not for the poll's and the by-id reads, which the cycle that
  # made them dispatches from right after.
  defp announce({:ok, :updated} = written, {repo_key, issue_id, fields}, source) when source not in [:poll, :by_id] do
    :ok = ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, fields)
    written
  end

  defp announce(result, _change, _source), do: result

  # The observed fields an observation changed, every one of a new record's, without the times that
  # say when it was read.
  defp changed(stored, observed) do
    before = if stored, do: TicketState.observation(stored), else: %{}

    for {field, value} <- TicketState.observation(observed),
        field not in [:linear_updated_at, :observed_at, :observed_from, :updated_at],
        Map.get(before, field) != value,
        do: field
  end

  # `revert` moves a drifted ticket back once the record is written (`revert/5`).
  defp write_and_compare(stored, observed, source, now, opts, revert) do
    with {:ok, :updated} = written <- write(stored, observed) do
      compare(source, stored, observed, now, opts)
      revert.()
      written
    end
  end

  # A read compares with the webhook only when it isn't one, and only for a ticket that had a record.
  defp compare(:webhook, _stored, _observed, _now, _opts), do: :ok
  defp compare(_source, nil, _observed, _now, _opts), do: :ok

  defp compare(source, stored, observed, now, opts) do
    stored = TicketState.normalize(stored)
    changed = Enum.reject(@webhook_fields, &(Map.get(stored, &1) == Map.get(observed, &1)))

    cond do
      changed != [] -> if(compare?(opts), do: poll_first(observed, changed, source, now), else: :ok)
      stored.observed_from == :webhook -> webhook_first(stored)
      true -> :ok
    end
  end

  # The last ten entries kept under `{tag, seq}`, newest first, of `count` so far.
  defp recent(entries, tag, count),
    do: for(n <- count..max(count - @recent_limit + 1, 1)//-1, {_key, entry} <- [List.keyfind(entries, {tag, n}, 0)], do: entry)

  # What the observation does with Linear's state: nil applies it; `:older` keeps the record's phase,
  # as Linear's state was read before Symphony wrote it; a drift keeps it and moves Linear back. Only
  # under `dispatch.source: record`, on a record whose phase Symphony owns and Linear contradicts.
  # A record the Director cancelled is terminal once Linear took the cancel: a later Linear state is
  # applied, never drift. While the cancel's Linear write is still pending (a `:phase` mark), a Linear
  # state is drift like any other, so the record stays Canceled until the reconciler projects it.
  defp owned_phase(nil, _issue, _opts), do: nil

  defp owned_phase(stored, %Issue{state: linear_phase} = issue, opts) do
    record = TicketState.normalize(stored)

    cond do
      not owned?(record, linear_phase) -> nil
      linear_phase == record.phase or not record_source?(opts) -> nil
      older?(issue.updated_at, record.phase_at) -> :older
      canceled?(record.phase) and not projection_pending?(record) -> nil
      true -> %{identifier: record.issue_identifier || issue.identifier, record_phase: record.phase, linear_phase: linear_phase}
    end
  end

  defp owned?(record, linear_phase), do: record.phase_owner == :symphony and is_binary(record.phase) and is_binary(linear_phase)

  defp canceled?(phase), do: String.downcase(String.trim(phase)) in @canceled_phases

  defp projection_pending?(record), do: Enum.any?(record.pending_projection, &(TicketState.projection_of(&1) == :phase))

  defp record_source?(opts), do: Keyword.get_lazy(opts, :dispatch_source, &Config.dispatch_source/0) == "record"

  defp older?(%DateTime{} = fact, %DateTime{} = written), do: DateTime.compare(fact, written) == :lt
  defp older?(_fact, _written), do: false

  # A missing state keeps the record's phase (`TicketState.observe/4`).
  defp keep_phase(issue, nil), do: issue
  defp keep_phase(issue, _owned), do: %{issue | state: nil}

  # Starts moving a drifted ticket back in a task of its own (`:task_supervisor`), so the Linear call
  # lies outside the read that found the drift: a webhook delivery's bound can't cut it off before its
  # outcome is recorded. A move back that can't start is left to the next observation, as the record
  # already keeps its phase.
  defp revert(%{} = drift, stored, issue, now, opts) do
    move = Map.merge(drift, %{repo_key: stored.repo_key, issue_id: stored.issue_id, fact: drift_fact(drift, issue.updated_at), at: now})
    supervisor = Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
    {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> move_back(move) end)
    :ok
  catch
    kind, reason ->
      Logger.warning("Ticket drift: the move back did not start issue_id=#{stored.issue_id} issue_identifier=#{drift.identifier}: #{inspect({kind, reason})}")
  end

  defp revert(_owned, _stored, _issue, _now, _opts), do: :ok

  # Records the drift, moves the ticket back in Linear to the record's phase and records how that
  # went, one move back of a ticket at a time: one that finds another under way adds nothing. Each
  # event is keyed by the Linear fact, so the next observation of the same fact, which tries the move
  # again, adds no duplicate. The counts are kept and the ticket let go before the outcome is
  # recorded, so whoever reads that outcome finds both settled.
  defp move_back(%{repo_key: repo_key, issue_id: issue_id, record_phase: record_phase, linear_phase: linear_phase} = move) do
    slot = {:moving_back, repo_key, issue_id}

    if claim(slot) do
      payload = %{record_phase: record_phase, linear_phase: linear_phase}

      Logger.info("Ticket drift: Linear shows #{linear_phase}, the record holds #{record_phase}; moving it back issue_id=#{issue_id} issue_identifier=#{move.identifier}")
      record_drift(move, "drift.detected", payload)

      {outcome, type, payload} =
        case move_in_linear(issue_id, record_phase) do
          :ok ->
            {:reverted, "drift.reverted", payload}

          {:error, reason} ->
            Logger.warning("Ticket drift: moving back to #{record_phase} failed issue_id=#{issue_id} issue_identifier=#{move.identifier}: #{inspect(reason)}")
            {:revert_failed, "drift.revert_failed", Map.put(payload, :error, inspect(reason))}
        end

      remember_drift(move |> Map.take([:identifier, :record_phase, :linear_phase, :at]) |> Map.put(:outcome, outcome))
      release(slot)
      record_drift(move, type, payload)
    end

    :ok
  end

  # A crash of the move is a failed move, so the drift always gets its outcome.
  defp move_in_linear(issue_id, phase) do
    Tracker.update_issue_state(issue_id, phase)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The ticket's move back slot, held by the task moving it back. A slot whose task died without
  # letting go (a crash, or its supervisor restarted) is taken over. Without the table (some tests)
  # nothing is held.
  defp claim(slot) do
    :ets.insert_new(@table, {slot, self()}) or take_over(slot)
  rescue
    ArgumentError -> true
  end

  defp take_over(slot) do
    with [{^slot, holder}] <- :ets.lookup(@table, slot),
         false <- Process.alive?(holder) do
      :ets.delete_object(@table, {slot, holder})
      :ets.insert_new(@table, {slot, self()})
    else
      _held_or_let_go -> false
    end
  end

  defp release(slot) do
    :ets.delete_object(@table, {slot, self()})
  rescue
    ArgumentError -> true
  end

  defp drift_fact(drift, %DateTime{} = updated_at), do: "#{drift.record_phase}:#{drift.linear_phase}:#{DateTime.to_iso8601(updated_at)}"
  defp drift_fact(_drift, _updated_at), do: nil

  defp record_drift(%{repo_key: repo_key, issue_id: issue_id, fact: fact, at: at}, type, payload) do
    key = if fact, do: "#{type}:#{fact}"
    TicketSignals.record_event(repo_key, issue_id, type, payload, idempotency: key, at: at)
  end

  # Counts the drift and its outcome, and keeps it among the last ten.
  defp remember_drift(%{outcome: outcome} = entry) do
    seq = :ets.update_counter(@table, :drift_detected, 1, {:drift_detected, 0})
    bump(if outcome == :reverted, do: :drift_reverted, else: :drift_revert_failed)
    :ets.insert(@table, {{:drift, seq}, entry})
    :ets.delete(@table, {:drift, seq - @recent_limit})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp compare?(opts), do: Keyword.get_lazy(opts, :compare, fn -> Webhook.settings().enabled end)

  defp poll_first(observed, fields, source, now) do
    seq = :ets.update_counter(@table, :poll_first, 1, {:poll_first, 0})
    :ets.insert(@table, {{:poll_first, seq}, %{identifier: observed.issue_identifier, fields: fields, source: source, at: now}})
    :ets.delete(@table, {:poll_first, seq - @recent_limit})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Once for each change a webhook brought: the record's `observed_at` names that change.
  defp webhook_first(stored) do
    key = {:confirmed, stored.repo_key, stored.issue_id}

    if :ets.lookup(@table, key) != [{key, stored.observed_at}] do
      :ets.insert(@table, {key, stored.observed_at})
      bump(:webhook_first)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp bounded(parsed, opts) do
    {observe_fun, opts} = Keyword.pop(opts, :observe_fun, &observe_parsed/2)
    {timeout_ms, opts} = Keyword.pop(opts, :timeout_ms, @delivery_timeout_ms)
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> observe_fun.(parsed, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        delivery_failed(parsed, {:exit, reason})

      nil ->
        delivery_failed(parsed, :timeout)
    end
  end

  defp delivery_failed(parsed, reason) do
    Logger.warning("Linear webhook observation failed for issue_id=#{parsed_issue_id(parsed)}: #{inspect(reason)}")
    bump(:errors)
    :error
  end

  defp parsed_issue_id({:issue, _action, %Issue{id: id}, _updated_at}), do: id
  defp parsed_issue_id({:issue_removed, id, _identifier}), do: id

  defp observe_parsed({:issue, _action, issue, _updated_at}, opts) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)
    {orchestrator, opts} = Keyword.pop(opts, :orchestrator, Orchestrator)
    {outcome, repo_key} = observe_held_issue(issue, repos, Keyword.put(opts, :source, :webhook), :file)
    if outcome == :updated, do: Orchestrator.request_refresh(orchestrator, repo_key, due: :now)
    outcome
  end

  defp observe_parsed({:issue_removed, issue_id, _identifier}, opts) do
    {repos, opts} = Keyword.pop_lazy(opts, :repos, &configured_repos/0)
    {orchestrator, opts} = Keyword.pop(opts, :orchestrator, Orchestrator)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    removals = for repo_key <- repo_keys(repos), do: {repo_key, mark_removed(repo_key, issue_id, now)}
    for {repo_key, :removed} <- removals, do: Orchestrator.request_refresh(orchestrator, repo_key, due: :now)
    outcomes = Enum.map(removals, fn {_repo_key, outcome} -> outcome end)

    cond do
      :error in outcomes -> :error
      :removed in outcomes -> :removed
      true -> :no_record
    end
  end

  # A delivery or a by-id read updates the record the reads already keep. A ticket no repo has a
  # record of yet is filed by a delivery (`new: :file`) under the one repo whose poll scope takes it
  # (`PollScope.route/3`), so a new ticket dispatches from its first delivery; a by-id read leaves it
  # unrouted for the poll. One held in several repos is unrouted, as the poll counts a ticket two
  # repos return as a conflict. Gives the outcome with the repo it was observed under (nil when none).
  defp observe_held_issue(issue, repos, opts, new \\ :unrouted)

  defp observe_held_issue(%Issue{id: issue_id} = issue, repos, opts, new) when is_binary(issue_id) do
    case {holder(issue, repos), new} do
      {{:ok, repo_key}, _new} -> observe_under(repo_key, issue, opts)
      {:none, :file} -> file_new(issue, repos, opts)
      {{:error, repo_key, reason}, _new} -> held_failed(repo_key, issue, reason)
      {_none_or_several, _new} -> unrouted()
    end
  end

  defp observe_held_issue(_issue, _repos, _opts, _new) do
    bump(:errors)
    {:error, nil}
  end

  defp observe_under(repo_key, issue, opts),
    do: {delivered(repo_key, issue, observe(repo_key, %{issue | repo_key: repo_key}, opts)), repo_key}

  # A delivery never carries the ticket's blockers or sub-issues, which dispatch reads, so the new
  # record is filed from a by-id read of the ticket (one Linear request) under the repo its delivery
  # routes to. A ticket the read doesn't return is left to the poll.
  defp file_new(issue, repos, opts) do
    {scope_opts, opts} = Keyword.split(opts, [:tracker_settings, :viewer_id])

    case PollScope.route(issue, repos, scope_opts) do
      {:ok, repo_key} -> file_read(repo_key, issue, opts)
      :unrouted -> unrouted()
    end
  end

  defp file_read(repo_key, %Issue{id: issue_id} = issue, opts) do
    case fetch_by_ids(Keyword.get(opts, :tracker, Tracker), [issue_id]) do
      {:ok, issues} ->
        case Enum.find(issues, &match?(%Issue{id: ^issue_id}, &1)) do
          %Issue{} = read -> observe_under(repo_key, read, opts)
          nil -> unrouted()
        end

      {:error, reason} ->
        held_failed(repo_key, issue, {:by_id_read, reason})
    end
  end

  defp unrouted do
    bump(:unrouted)
    {:unrouted, nil}
  end

  defp held_failed(repo_key, issue, reason) do
    bump(:errors)
    {delivered(repo_key, issue, {:error, reason}), repo_key}
  end

  defp held_count_key(:error), do: :errors
  defp held_count_key(outcome), do: outcome

  defp holder(%Issue{id: issue_id}, repos) do
    repos
    |> repo_keys()
    |> Enum.reduce_while({:ok, []}, fn repo_key, {:ok, held} ->
      case read(repo_key, issue_id) do
        {:ok, nil} -> {:cont, {:ok, held}}
        {:ok, _record} -> {:cont, {:ok, [repo_key | held]}}
        {:error, reason} -> {:halt, {:error, repo_key, reason}}
      end
    end)
    |> case do
      {:ok, [repo_key]} -> {:ok, repo_key}
      {:ok, []} -> :none
      {:ok, _several} -> :several
      error -> error
    end
  end

  # `observe/3` counts its own error; the holder's read is counted where it fails.
  defp delivered(_repo_key, _issue, {:ok, outcome}), do: outcome

  defp delivered(repo_key, issue, {:error, reason}) do
    log_failure(repo_key, issue, reason)
    :error
  end

  defp mark_removed(repo_key, issue_id, now) do
    with {:ok, stored} when not is_nil(stored) <- read(repo_key, issue_id),
         removed = TicketState.mark_removed(stored, now),
         :ok <- RunStore.update_ticket_state(repo_key, issue_id, Map.take(removed, [:removed_at, :updated_at])) do
      :ok = ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, [:removed_at])
      :removed
    else
      {:ok, nil} -> :no_record
      {:error, reason} -> removal_failed(repo_key, issue_id, reason)
    end
  end

  defp removal_failed(repo_key, issue_id, reason) do
    Logger.warning("Ticket removal failed for issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    bump(:errors)
    :error
  end

  defp log_failure(repo_key, issue, reason) do
    Logger.warning("Ticket observation failed for issue_id=#{issue_id(issue)} issue_identifier=#{identifier(issue)} repo_key=#{repo_key}: #{inspect(reason)}")
  end

  defp lookup(entries, key, default) do
    case List.keyfind(entries, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp route(%Issue{} = issue, repos) do
    case Resolver.with_repo_key(issue, repos) do
      %Issue{repo_key: repo_key} = routed when is_binary(repo_key) and repo_key != "" -> [{repo_key, routed}]
      _unrouted -> []
    end
  end

  defp route(_issue, _repos), do: []

  defp repo_keys(repos), do: for(%{name: repo_key} when is_binary(repo_key) <- repos, do: repo_key)

  defp configured_repos do
    case Config.repos() do
      {:ok, repos} -> repos
      {:error, _reason} -> []
    end
  end

  defp read(repo_key, issue_id) do
    case RunStore.get_ticket_state(repo_key, issue_id) do
      {:error, reason} -> {:error, reason}
      stored -> {:ok, stored}
    end
  end

  defp write(nil, observed) do
    with :ok <- RunStore.put_ticket_state(observed), do: {:ok, :updated}
  end

  defp write(_stored, observed) do
    with :ok <- RunStore.update_ticket_state(observed.repo_key, observed.issue_id, TicketState.observation(observed)),
         do: {:ok, :updated}
  end

  defp open_blockers(%Issue{blocked_by: :unknown}, _repo_key, _opts), do: :unknown

  defp open_blockers(issue, repo_key, opts) do
    terminal_states = Keyword.get_lazy(opts, :terminal_states, fn -> terminal_states(repo_key) end)
    Issue.open_blockers(issue, terminal_states)
  end

  defp terminal_states(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> settings.tracker.terminal_states
      {:error, _reason} -> []
    end
  end

  defp count({:ok, outcome}), do: bump(outcome)
  defp count({:error, _reason}), do: bump(:errors)

  defp bump(key, by \\ 1) do
    :ets.update_counter(@table, key, by, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp empty_summary, do: %{updated: 0, unchanged: 0, stale: 0, errors: 0}

  defp issue_id(%Issue{id: id}), do: id
  defp issue_id(_issue), do: nil

  defp identifier(%Issue{identifier: identifier}), do: identifier
  defp identifier(_issue), do: nil
end
