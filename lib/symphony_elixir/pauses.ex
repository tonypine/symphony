defmodule SymphonyElixir.Pauses do
  @moduledoc """
  The one answer to "why is this not moving": a pause on a subject (a ticket, a repository or
  Symphony itself) with one or more reasons, who set it and since when. This module decides every
  change to a pause.

  A reason says what the subject waits on, structured so the machine can tell when it ends:

    * `:question` - an answer to a question (`waits_on: %{question_id: id}`);
    * `:ticket` - another ticket reaching a terminal state (`waits_on: %{identifier: "TP-12"}`, a
      ticket's identifier as Linear writes it);
    * `:build` - a Symphony build containing a fix (`waits_on: %{version: "0.0.1.731"}`, a release's
      version, or `%{pull_request: 448}`);
    * `:person` - the Director (`waits_on: %{action: "unblock" | "restart"}`);
    * `:environment` - a named condition (`waits_on: %{condition: name}`).

  Each reason has `text`, one line in plain words of at most 300 characters (a default per kind, or
  the writer's; a longer one is refused), `set_by` (`%{kind: :person | :run | :rule | :symphony,
  name: name}`), `set_at` and `releasable`: whether the Director may release it. A `:person` reason
  always is; a `:ticket` or `:environment` reason is when its writer says so; a `:question` or
  `:build` reason never is.

  A ticket's pause lives on its record (`SymphonyElixir.TicketState`, field `pause`), and each change
  records a ledger event (`SymphonyElixir.TicketEvents`): `pause.set` for the first reason,
  `pause.reason_added` for each further one, `pause.reason_cleared` for a reason cleared while
  others remain and `pause.cleared` when none is left. A repository's or Symphony's pause is kept by
  `SymphonyElixir.RunStore` under its subject and records no event.

  Symphony's own pause stops dispatch while it has the Director's reason (their Pause) or an
  update's (the menu bar app's, waiting on the version it installs): `dispatch_reason/1` makes
  either from the control API's reason and `dispatch_status/1` gives the pause as the state
  payload reads it. A usage limit's `:environment` reason (`SymphonyElixir.UsageLimit`) sits on it
  too, holding only the runs its hold covers. Ticket pages never show it.

  A repository's pause stops dispatch for that repository alone while it has the Director's reason
  (`repository_reason/1`); its candidates are skipped with `repository_skip_reason/1`.

  A reason is known by its kind and `waits_on`: setting the same one again changes nothing and
  records nothing. Each write reads, changes and writes the pause in one store transaction that
  holds its lock (`RunStore.update_ticket_pause/4`, `RunStore.update_subject_pause/2`), so
  concurrent writers never lose each other's reasons. A ticket's event is appended in that same
  transaction, so the pause never changes without its event and the events follow the order the
  changes were written in; the live channel's notice of it goes out once it commits. A writer that
  changes a ticket's record with its own change takes the pause's change from `set_change/4` or
  `clear_reason_change/4` and stores both in one transaction: a question
  (`SymphonyElixir.Questions`) and its reason never disagree.

  A `:ticket` reason's line says why the ticket is waited on (`ticket_reason/2`): a blocker it is
  blocked by (`:dependency`, the blocked-by sync and a run's block report), the fix ticket self-heal
  filed for it (`:fix_ticket`) or a pull request competing for its files (`:landing`).

  Once a change to a ticket's pause commits, its labels are projected from it
  (`SymphonyElixir.Pauses.Projector.project_now/2`).

  An operator's Stop pauses its ticket on the Director's reason (`stop_reason/1`, written by
  `stop/2`): a `:person` reason waiting on Unblock, so the dispatcher, which reads the pause, does not
  start the ticket again while Symphony's copy still reads the state it had. The reason is in the
  run store, so a stopped ticket is still stopped after Symphony restarts. Each poll reads the
  stopped tickets (`stopped/0`) by id and judges each one again (`confirm_stop/3`): one that is gone,
  terminal or no longer in an active state, or whose phase was written after the stop (a person's
  move on the board), has the reason released (`release_stop/2`). Unblock and Restart release it too.

  `backfilled: true` marks a reason the backfill from the holds sets (`SymphonyElixir.Pauses.Backfill`):
  its event carries `source: "backfill"` and an idempotency key starting `backfill:`, which the
  ledger's own backfill (`SymphonyElixir.TicketEvents.Backfill`) never takes for a live write, and
  which a second write of the same reason never records again.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.{RunStore, TicketEvents, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @kinds [:question, :ticket, :build, :person, :environment]
  @setter_kinds [:person, :run, :rule, :symphony]
  @person_actions ~w(unblock restart)
  @symphony %{kind: :symphony, name: "Symphony"}
  @director %{kind: :person, name: "Director"}
  # An operator's stop: the Director's reason on a ticket, released by Unblock (as the backfill of the
  # stops' holds wrote it too, `SymphonyElixir.Pauses.Backfill`).
  @stop_waits_on %{action: "unblock"}
  # The longest line a reason may have: the ledger (`SymphonyElixir.TicketEvents.Types`) refuses more.
  @max_text 300
  # The only names a reason's default line shows: a ticket's identifier and a release's version.
  @identifier ~r/\A[A-Z][A-Z0-9]*-\d+\z/
  @version ~r/\A\d+(\.\d+)+\z/
  # The menu bar app's reason for an update's pause (`ControlAction.updatePauseReason`).
  @update_reason ~r/\Aupdating to v(\d+(?:\.\d+)+)\z/
  @dispatch_kinds [:person, :build]
  @repository_text "You paused this repository"
  @symphony_text "You paused Symphony"

  @typedoc "What a pause holds: a ticket of a repository, a repository, or Symphony itself."
  @type subject :: {:ticket, String.t(), String.t()} | {:repository, String.t()} | :symphony

  @type kind :: :question | :ticket | :build | :person | :environment

  @typedoc "Who set a reason, or cleared one: a person, a run, a rule or Symphony, by name."
  @type set_by :: %{kind: :person | :run | :rule | :symphony, name: String.t()}

  @type reason :: %{
          kind: kind(),
          waits_on: map(),
          text: String.t(),
          set_by: set_by(),
          set_at: DateTime.t() | nil,
          releasable: boolean()
        }

  @typedoc "A pause: its subject, its reasons in the order they were set, who set it and since when."
  @type pause :: %{subject: subject(), reasons: [reason(), ...], set_by: set_by(), since: DateTime.t() | nil}

  @typedoc """
  A reason as a writer gives it: its `kind` and `waits_on`, and optionally its `text` and whether
  the Director may release it (`releasable`).
  """
  @type reason_input :: %{
          required(:kind) => kind(),
          required(:waits_on) => map(),
          optional(:text) => String.t(),
          optional(:releasable) => boolean()
        }

  @typedoc """
  `set_by:` (or `by:` when clearing; default Symphony), `at:` (a `DateTime`, default now) and
  `backfilled:` (a reason the backfill sets, see the module doc).
  """
  @type opt :: {:set_by, set_by()} | {:by, set_by()} | {:at, DateTime.t()} | {:backfilled, boolean()}

  @type result :: {:ok, pause() | nil} | {:error, term()}

  @typedoc """
  A change to a ticket's pause, for a writer that stores it with its own change: the pause to write
  (nil once cleared) and the ledger events that record it, none when nothing changes.
  """
  @type ticket_change :: {:ok, pause() | nil, [SymphonyElixir.TicketEvents.Event.t()]} | {:error, term()}

  @typedoc "Why a `:ticket` reason waits on its ticket (`ticket_reason/2`)."
  @type ticket_source :: :dependency | :fix_ticket | :landing

  @typedoc """
  A stopped ticket as the store holds it: its id, repo and identifier, when it was stopped, and
  when its record's phase was last written (nil when never).
  """
  @type stop :: %{
          issue_id: String.t(),
          repo_key: String.t() | nil,
          identifier: String.t() | nil,
          stopped_at: DateTime.t() | nil,
          phase_at: DateTime.t() | nil
        }

  @doc """
  The `:ticket` reason that waits on `identifier` for `source`, with its line: `Waiting for TP-12 to
  finish` for a blocker, `Waiting for TP-12 to finish: it fixes what stopped this ticket` for a fix
  ticket and `Waiting for TP-12 to land: it changes the same files` for a competing pull request.
  """
  @spec ticket_reason(ticket_source(), String.t()) :: reason_input()
  def ticket_reason(source, identifier) when source in [:dependency, :fix_ticket, :landing] and is_binary(identifier) do
    %{kind: :ticket, waits_on: %{identifier: identifier}, text: ticket_text(source, identifier)}
  end

  @doc """
  Why a `:ticket` reason waits on its ticket, read from its line (`ticket_reason/2`): `:fix_ticket`,
  `:landing`, or `:dependency` for a blocker's line (also the default line of a `:ticket` reason);
  nil for any other reason.
  """
  @spec ticket_source(reason() | term()) :: ticket_source() | nil
  def ticket_source(%{kind: :ticket, waits_on: %{identifier: identifier}, text: text}) when is_binary(identifier) do
    Enum.find([:dependency, :fix_ticket, :landing], &(ticket_text(&1, identifier) == text))
  end

  def ticket_source(_reason), do: nil

  @doc "Whether `value` is a ticket's identifier as a `:ticket` reason takes it (`TP-12`)."
  @spec identifier?(term()) :: boolean()
  def identifier?(value), do: is_binary(value) and value =~ @identifier

  @doc """
  The reason the Director's Pause (`reason`, the control API's) gives Symphony's pause: the
  menu bar app's update pause (`updating to v0.0.1.42`) waits on that build (`:build`,
  `waits_on: %{version: version}`), any other the Director (`:person`, `waits_on: %{action:
  "unblock"}`, `You paused Symphony` without a reason). Either keeps `reason` as its line, cut to a
  reason's longest line, so a long reason still pauses.
  """
  @spec dispatch_reason(String.t() | nil) :: reason_input()
  def dispatch_reason(reason) do
    text = cut_line(reason)

    case text && Regex.run(@update_reason, text) do
      [_text, version] -> %{kind: :build, waits_on: %{version: version}, text: text}
      nil -> %{kind: :person, waits_on: %{action: "unblock"}, text: text || @symphony_text, releasable: true}
    end
  end

  @doc """
  The reason the Director's Pause of a repository (`reason`, the control API's) gives its pause: a
  `:person` reason waiting on `unblock`, its line `reason` cut to a reason's longest line (`You
  paused this repository` without one).
  """
  @spec repository_reason(String.t() | nil) :: reason_input()
  def repository_reason(reason) do
    %{kind: :person, waits_on: %{action: "unblock"}, text: cut_line(reason) || @repository_text, releasable: true}
  end

  @doc """
  The line a paused repository's candidates are skipped with: `the repository is paused by you since
  2026-10-30 12:44 UTC`, then the Director's reasons when they gave any.
  """
  @spec repository_skip_reason(pause()) :: String.t()
  def repository_skip_reason(%{reasons: reasons} = pause) do
    since = if at = Map.get(pause, :since), do: " since #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}", else: ""

    case for(%{kind: :person, text: text} <- reasons, text != @repository_text, do: text) do
      [] -> "the repository is paused by you#{since}"
      texts -> "the repository is paused by you#{since}: #{Enum.join(texts, "; ")}"
    end
  end

  @doc """
  The reasons of Symphony's pause that stop all dispatch: the Director's (`:person`) and an
  update's (`:build`). A usage limit's (`:environment`) holds only the runs it covers.
  """
  @spec dispatch_reasons(pause() | nil) :: [reason()]
  def dispatch_reasons(%{reasons: reasons}), do: Enum.filter(reasons, &(&1.kind in @dispatch_kinds))
  def dispatch_reasons(nil), do: []

  @doc """
  The line a candidate the paused pass skips is given, one text per reason that stops dispatch
  (`dispatch_reasons/1`) joined by `; `, from the same reasons the pause header shows: an update's
  `dispatch is paused: updating to v0.0.1.756`, the Director's `dispatch is paused by the
  operator`, then their note when they gave one. The reason's kind picks the wording. Nil when no
  reason stops dispatch.
  """
  @spec dispatch_skip_reason(pause() | nil) :: String.t() | nil
  def dispatch_skip_reason(pause) do
    case dispatch_reasons(pause) do
      [] -> nil
      reasons -> Enum.map_join(reasons, "; ", &skip_text/1)
    end
  end

  defp skip_text(%{kind: :build, text: text}), do: "dispatch is paused: #{text}"
  defp skip_text(%{kind: :person, text: @symphony_text}), do: "dispatch is paused by the operator"
  defp skip_text(%{kind: :person, text: text}), do: "dispatch is paused by the operator: #{text}"

  @doc """
  Symphony's pause as the state payload and the control API give it: `paused` while a reason
  stops all dispatch (`dispatch_reasons/1`), with the first one's line as `reason` and its time as
  `paused_at`, as the operator pause read before it lived here, and every reason (`kind`, `text`,
  `since`, `waits_on`) in the order they were set.
  """
  @spec dispatch_status(pause() | nil) :: %{
          paused: boolean(),
          reason: String.t() | nil,
          paused_at: DateTime.t() | nil,
          reasons: [%{kind: kind(), text: String.t(), since: DateTime.t() | nil, waits_on: map()}]
        }
  def dispatch_status(pause) do
    reasons = Enum.map((pause && pause.reasons) || [], &%{kind: &1.kind, text: &1.text, since: &1.set_at, waits_on: &1.waits_on})

    case dispatch_reasons(pause) do
      [first | _rest] -> %{paused: true, reason: first.text, paused_at: first.set_at, reasons: reasons}
      [] -> %{paused: false, reason: nil, paused_at: nil, reasons: reasons}
    end
  end

  @doc """
  Pauses `subject` on `reason`: a subject that is not paused records `pause.set`; a paused one gains
  the reason, as with `add_reason/3`. Returns the pause.
  """
  @spec set(subject(), reason_input(), [opt()]) :: result()
  def set(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, reason} <- new_reason(reason, opts, :set_by) do
      update(subject, reason.set_at, &add(subject, &1, reason, source(opts)))
    end
  end

  @doc """
  Adds `reason` to the pause of `subject`, recording `pause.reason_added`; `{:error, :not_paused}`
  when the subject is not paused.
  """
  @spec add_reason(subject(), reason_input(), [opt()]) :: result()
  def add_reason(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, reason} <- new_reason(reason, opts, :set_by) do
      update(subject, reason.set_at, fn
        nil -> {:error, :not_paused}
        pause -> add(subject, pause, reason, source(opts))
      end)
    end
  end

  @doc """
  Clears the reason of `subject`'s pause with `reason`'s kind and `waits_on`. Others left, the pause
  stays and records `pause.reason_cleared`; none left, the pause clears and records `pause.cleared`.
  A reason the pause doesn't hold changes nothing. Returns the pause, nil once cleared.
  """
  @spec clear_reason(subject(), reason_input(), [opt()]) :: result()
  def clear_reason(subject, reason, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, target} <- new_reason(reason, opts, :by) do
      update(subject, target.set_at, &drop(subject, &1, target))
    end
  end

  @doc """
  Clears each reason of `subject`'s pause that `match?` holds for, one by one as `clear_reason/3`
  does, in the order they were set. Returns the pause left (nil once cleared); the first refused
  clear stops there and is the error. A subject not paused is unchanged.
  """
  @spec clear_reasons(subject(), (reason() -> boolean()), [opt()]) :: result()
  def clear_reasons(subject, match?, opts \\ []) when is_function(match?, 1) do
    with {:ok, %{reasons: reasons} = pause} <- get(subject) do
      reasons
      |> Enum.filter(match?)
      |> Enum.reduce_while({:ok, pause}, fn reason, _left -> clear_next(subject, reason, opts) end)
    end
  end

  defp clear_next(subject, reason, opts) do
    case clear_reason(subject, reason, opts) do
      {:ok, _pause} = cleared -> {:cont, cleared}
      error -> {:halt, error}
    end
  end

  @doc """
  The change `set/3` makes to `pause`, the pause of ticket `ticket` as its writer read it under the
  record's lock (`RunStore.update_ticket_question/4`): that writer stores the pause and its events in
  its own transaction. Pure: it writes nothing.
  """
  @spec set_change(subject(), pause() | nil, reason_input(), [opt()]) :: ticket_change()
  def set_change(ticket, pause, reason, opts) do
    with {:ok, ticket} <- ticket(ticket),
         {:ok, reason} <- new_reason(reason, opts, :set_by),
         do: changed(add(ticket, normalize(pause), reason, source(opts)))
  end

  @doc """
  The change `clear_reason/3` makes to `pause`, the pause of ticket `ticket` as its writer read it
  under the record's lock, as `set_change/4` gives it. Pure: it writes nothing.
  """
  @spec clear_reason_change(subject(), pause() | nil, reason_input(), [opt()]) :: ticket_change()
  def clear_reason_change(ticket, pause, reason, opts) do
    with {:ok, ticket} <- ticket(ticket),
         {:ok, target} <- new_reason(reason, opts, :by),
         do: changed(drop(ticket, normalize(pause), target))
  end

  @doc "Clears `subject`'s pause whatever its reasons, recording `pause.cleared`. A subject not paused is unchanged."
  @spec clear(subject(), [opt()]) :: result()
  def clear(subject, opts \\ []) do
    with {:ok, subject} <- subject(subject),
         {:ok, by} <- setter(opts, :by),
         {:ok, at} <- at(opts) do
      update(subject, at, fn
        nil -> unchanged(nil)
        pause -> change(subject, nil, "pause.cleared", cleared_payload(pause.reasons, by), at)
      end)
    end
  end

  @doc "The pause of `subject`, or nil when it is not paused."
  @spec get(subject()) :: result()
  def get(subject) do
    with {:ok, subject} <- subject(subject), do: read(subject)
  end

  @doc "Whether `subject` is paused."
  @spec paused?(subject()) :: boolean()
  def paused?(subject), do: reasons(subject) != []

  @doc "Why `subject` is paused: one line in plain words per reason, in the order they were set."
  @spec why(subject()) :: [String.t()]
  def why(subject), do: subject |> reasons() |> Enum.map(& &1.text)

  @doc "Whether the Director may release `subject`'s pause: any of its reasons is releasable."
  @spec releasable?(subject()) :: boolean()
  def releasable?(subject), do: subject |> reasons() |> Enum.any?(& &1.releasable)

  @doc "Who stops a ticket and releases its stop from the Director: the person setting the reason."
  @spec director() :: set_by()
  def director, do: @director

  @doc "The pause reason an operator's stop at `stopped_at` sets: the Director's, released by Unblock."
  @spec stop_reason(DateTime.t()) :: reason_input()
  def stop_reason(%DateTime{} = stopped_at) do
    %{
      kind: :person,
      waits_on: @stop_waits_on,
      text: "Stopped by you at #{format_time(stopped_at)}. Unblock runs it again; Restart starts it over from main."
    }
  end

  @doc "Whether a ticket's pause reason is an operator's stop (`stop_reason/1`)."
  @spec stop_reason?(reason() | term()) :: boolean()
  def stop_reason?(%{kind: :person, waits_on: @stop_waits_on}), do: true
  def stop_reason?(_reason), do: false

  @doc "Pauses `ticket` on an operator's stop, set by the Director at `stopped_at`."
  @spec stop(subject(), DateTime.t()) :: :ok | {:error, term()}
  def stop(ticket, %DateTime{} = stopped_at) do
    with {:ok, _pause} <- set(ticket, stop_reason(stopped_at), set_by: @director, at: stopped_at), do: :ok
  end

  @doc """
  Releases `ticket`'s stop: its stop reason is cleared (by `opts[:by]`, Symphony by default); every
  other reason stays.
  """
  @spec release_stop(subject(), [opt()]) :: :ok | {:error, term()}
  def release_stop(ticket, opts \\ []) do
    with {:ok, _pause} <- clear_reason(ticket, %{kind: :person, waits_on: @stop_waits_on}, Keyword.take(opts, [:by])), do: :ok
  end

  @doc "Why the dispatcher skips `ticket` for a stop: its stop reason's line, or nil when it is not stopped."
  @spec stop_skip_reason(subject()) :: String.t() | nil
  def stop_skip_reason(ticket) do
    case ticket |> reasons() |> Enum.find(&stop_reason?/1) do
      %{text: text} -> text
      nil -> nil
    end
  end

  @doc "Whether `ticket`'s pause has an operator's stop."
  @spec stopped?(subject()) :: boolean()
  def stopped?(ticket), do: stop_skip_reason(ticket) != nil

  @doc "The stopped tickets in the store, of every repo: those whose pause has an operator's stop."
  @spec stopped(module()) :: [stop()]
  def stopped(store \\ RunStore) do
    case store.list_all_ticket_states() do
      records when is_list(records) -> records |> Enum.map(&TicketState.normalize/1) |> Enum.flat_map(&stop_of/1)
      _error -> []
    end
  end

  @doc """
  What a poll's read calls for: keep the stop, or clear it. `issue` is the ticket as the poll read
  it by id (nil when Linear no longer returns it) and `candidate?` whether its state is active and
  not terminal; a phase written after the stop is a move on the board.
  """
  @spec confirm_stop(stop(), Issue.t() | nil, boolean()) :: :keep | :clear
  def confirm_stop(_stop, nil, _candidate?), do: :clear
  def confirm_stop(_stop, %Issue{}, false = _candidate?), do: :clear

  def confirm_stop(%{phase_at: %DateTime{} = phase_at, stopped_at: %DateTime{} = stopped_at}, %Issue{}, true) do
    if DateTime.compare(phase_at, stopped_at) == :gt, do: :clear, else: :keep
  end

  def confirm_stop(_stop, %Issue{}, true), do: :keep

  # A record's pause is written under its repo and id, so a record with a stop reason has both.
  defp stop_of(record) do
    case record |> TicketState.pause_reasons() |> Enum.find(&stop_reason?/1) do
      nil ->
        []

      reason ->
        [%{issue_id: record.issue_id, repo_key: record.repo_key, identifier: record.issue_identifier, stopped_at: reason.set_at, phase_at: record.phase_at}]
    end
  end

  defp format_time(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  @doc """
  A pause as stored or given, with its reasons validated (each kind and `waits_on` once, at its
  first place) and its defaults filled; nil for anything that is not a pause with at least one
  valid reason.
  """
  @spec normalize(term()) :: pause() | nil
  def normalize(%{subject: subject, reasons: reasons} = pause) when is_list(reasons) do
    with {:ok, subject} <- subject(subject),
         [first | _rest] = reasons <- reasons |> Enum.flat_map(&normalize_reason/1) |> Enum.uniq_by(&key/1) do
      %{
        subject: subject,
        reasons: reasons,
        set_by: set_by(Map.get(pause, :set_by)) || first.set_by,
        since: datetime(Map.get(pause, :since)) || first.set_at
      }
    else
      _invalid -> nil
    end
  end

  def normalize(_pause), do: nil

  defp reasons(subject) do
    case get(subject) do
      {:ok, %{reasons: reasons}} -> reasons
      _none -> []
    end
  end

  # The change to a pause, from the pause the store read under its lock (see `update/3`): pure, as
  # the store may run it more than once.
  defp add(subject, nil, reason, source) do
    pause = %{subject: subject, reasons: [reason], set_by: reason.set_by, since: reason.set_at}
    change(subject, pause, "pause.set", reason_payload(reason, source), reason.set_at)
  end

  defp add(subject, pause, reason, source) do
    if Enum.any?(pause.reasons, &(key(&1) == key(reason))) do
      unchanged(pause)
    else
      change(subject, %{pause | reasons: pause.reasons ++ [reason]}, "pause.reason_added", reason_payload(reason, source), reason.set_at)
    end
  end

  defp source(opts), do: if(Keyword.get(opts, :backfilled) == true, do: :backfill)

  defp drop(_subject, nil, _target), do: unchanged(nil)

  defp drop(subject, pause, target) do
    case Enum.split_with(pause.reasons, &(key(&1) == key(target))) do
      {[], _reasons} ->
        unchanged(pause)

      {cleared, []} ->
        change(subject, nil, "pause.cleared", cleared_payload(cleared, target.set_by), target.set_at)

      {[cleared], reasons} ->
        payload = cleared |> cleared_reason() |> Map.put(:by, target.set_by)
        change(subject, %{pause | reasons: reasons}, "pause.reason_cleared", payload, target.set_at)
    end
  end

  defp unchanged(pause), do: {:ok, pause}

  # A ticket's event is built (and validated) before anything is written, so a pause whose event the
  # ledger refuses is never stored, and the store appends it with the pause. Any other subject
  # records no event.
  defp change({:ticket, repo_key, issue_id}, pause, type, payload, at) do
    with {:ok, event} <- TicketEvents.build(repo_key, issue_id, type, payload, at: at, idempotency: idempotency(type, payload)),
         do: {:write, pause, [event], pause}
  end

  defp change(_subject, pause, _type, _payload, _at), do: {:write, pause, pause}

  # A ticket's change as a writer of its record stores it: the pause with its events, none when
  # nothing changes; a refusal passes through.
  defp changed({:write, pause, events, _pause}), do: {:ok, pause, events}
  defp changed(unchanged), do: with({:ok, pause} <- unchanged, do: {:ok, pause, []})

  # The pause is read, changed and written in one store transaction that holds its lock, with the
  # ticket's event appended in it; the event's notice goes out once it commits. Each change is
  # announced once the write committed: a reason lifted may free the ticket to dispatch, so the
  # orchestrator runs a dispatch cycle at once (`SymphonyElixir.Orchestrator`), and the PR watcher
  # re-decides the ticket on any change (`SymphonyElixir.PrWatch.Repo`). A write that changes nothing
  # announces nothing.
  defp update({:ticket, repo_key, issue_id}, at, fun) do
    with {:ok, pause, events} <- RunStore.update_ticket_pause(repo_key, issue_id, at, fun) do
      Enum.each(events, &TicketEvents.notify/1)
      if events != [], do: ObservabilityPubSub.broadcast_ticket_record_changed(repo_key, issue_id, [:pause])
      if events != [], do: Projector.project_now({:ticket, repo_key, issue_id})
      {:ok, pause}
    end
  end

  defp update(subject, _at, fun), do: RunStore.update_subject_pause(subject, &fun.(normalize(&1)))

  defp read({:ticket, repo_key, issue_id}) do
    with record when not is_tuple(record) <- RunStore.get_ticket_state(repo_key, issue_id),
         do: {:ok, TicketState.normalize(record).pause}
  end

  defp read(subject) do
    with pause when not is_tuple(pause) <- RunStore.get_subject_pause(subject), do: {:ok, normalize(pause)}
  end

  defp reason_payload(reason, source) do
    payload = %{reason: reason.kind, text: reason.text, waits_on: reason.waits_on, set_by: reason.set_by, releasable: reason.releasable}
    if source, do: Map.put(payload, :source, source), else: payload
  end

  # A backfilled reason's event is keyed by its type and the reason, so it is recorded once.
  defp idempotency(type, %{source: :backfill} = payload), do: "backfill:#{type}:#{payload.reason}:#{hash(payload.waits_on)}"
  defp idempotency(_type, _payload), do: nil

  defp hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp cleared_payload(reasons, by), do: %{cleared: Enum.map(reasons, &cleared_reason/1), by: by}

  defp cleared_reason(reason), do: %{reason: reason.kind, text: reason.text, waits_on: reason.waits_on}

  defp key(reason), do: {reason.kind, reason.waits_on}

  defp new_reason(reason, opts, setter_key) when is_map(reason) do
    with {:ok, set_by} <- setter(opts, setter_key),
         {:ok, at} <- at(opts) do
      case normalize_reason(Map.merge(reason, %{set_by: set_by, set_at: at})) do
        [reason] -> {:ok, reason}
        [] -> {:error, {:invalid_reason, reason}}
      end
    end
  end

  defp new_reason(reason, _opts, _setter_key), do: {:error, {:invalid_reason, reason}}

  defp at(opts) do
    case Keyword.get_lazy(opts, :at, &DateTime.utc_now/0) do
      %DateTime{} = at -> {:ok, at}
      _at -> {:error, {:invalid_option, :at}}
    end
  end

  defp setter(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, @symphony}
      {:ok, value} -> if set_by = set_by(value), do: {:ok, set_by}, else: {:error, {:invalid_set_by, value}}
    end
  end

  defp normalize_reason(%{kind: kind, waits_on: %{} = waits_on} = reason) when kind in @kinds do
    with %{} = waits_on <- waits_on(kind, waits_on),
         text = line(Map.get(reason, :text)) || default_text(kind, waits_on),
         true <- String.length(text) <= @max_text do
      [
        %{
          kind: kind,
          waits_on: waits_on,
          text: text,
          set_by: set_by(Map.get(reason, :set_by)) || @symphony,
          set_at: datetime(Map.get(reason, :set_at)),
          releasable: releasable(kind, Map.get(reason, :releasable))
        }
      ]
    else
      _invalid -> []
    end
  end

  defp normalize_reason(_reason), do: []

  defp waits_on(:question, waits_on), do: one(waits_on, :question_id)
  defp waits_on(:ticket, waits_on), do: matching(waits_on, :identifier, @identifier)
  defp waits_on(:environment, waits_on), do: one(waits_on, :condition)
  defp waits_on(:build, %{pull_request: number}) when is_integer(number) and number > 0, do: %{pull_request: number}
  defp waits_on(:build, waits_on), do: matching(waits_on, :version, @version)
  defp waits_on(:person, %{action: action}) when is_atom(action), do: waits_on(:person, %{action: Atom.to_string(action)})
  defp waits_on(:person, %{action: action}) when action in @person_actions, do: %{action: action}
  defp waits_on(:person, _waits_on), do: nil

  defp one(waits_on, field) do
    if value = line(Map.get(waits_on, field)), do: %{field => value}
  end

  # A value the default line shows: only one that matches `pattern`.
  defp matching(waits_on, field, pattern) do
    with %{^field => value} = waits_on <- one(waits_on, field),
         true <- value =~ pattern,
         do: waits_on,
         else: (_invalid -> nil)
  end

  defp ticket_text(:dependency, identifier), do: "Waiting for #{identifier} to finish"
  defp ticket_text(:fix_ticket, identifier), do: "Waiting for #{identifier} to finish: it fixes what stopped this ticket"
  defp ticket_text(:landing, identifier), do: "Waiting for #{identifier} to land: it changes the same files"

  defp default_text(:question, _waits_on), do: "Waiting for your answer"
  defp default_text(:ticket, %{identifier: identifier}), do: "Waiting for #{identifier} to finish"
  defp default_text(:build, %{version: version}), do: "Waiting for Symphony version #{version}, which has the fix"
  defp default_text(:build, %{pull_request: _number}), do: "Waiting for a Symphony build with the fix"
  defp default_text(:person, %{action: action}), do: "Waiting for you to #{action} it"
  defp default_text(:environment, _waits_on), do: "Waiting for the environment to be ready"

  defp releasable(:person, _releasable), do: true
  defp releasable(kind, releasable) when kind in [:ticket, :environment], do: releasable == true
  defp releasable(_kind, _releasable), do: false

  defp set_by(%{kind: kind, name: name}) when kind in @setter_kinds do
    if name = line(name), do: %{kind: kind, name: name}
  end

  defp set_by(_set_by), do: nil

  defp subject({:ticket, repo_key, issue_id} = subject) when is_binary(repo_key) and is_binary(issue_id) do
    if line(repo_key) && line(issue_id), do: {:ok, subject}, else: {:error, {:invalid_subject, subject}}
  end

  defp subject({:repository, repo_key} = subject) when is_binary(repo_key) do
    if line(repo_key), do: {:ok, subject}, else: {:error, {:invalid_subject, subject}}
  end

  defp subject(:symphony), do: {:ok, :symphony}
  defp subject(subject), do: {:error, {:invalid_subject, subject}}

  defp ticket({:ticket, _repo_key, _issue_id} = ticket), do: subject(ticket)
  defp ticket(subject), do: {:error, {:invalid_subject, subject}}

  # A reason's line as the control API gives it, cut to a reason's longest line; nil when blank.
  defp cut_line(value), do: with(line when is_binary(line) <- line(value), do: String.slice(line, 0, @max_text))

  # One line: whitespace runs collapse to one space; blank is nil.
  defp line(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      line -> line
    end
  end

  defp line(_value), do: nil

  defp datetime(%DateTime{} = datetime), do: datetime
  defp datetime(_value), do: nil
end
