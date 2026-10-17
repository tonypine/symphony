defmodule SymphonyElixir.TicketState do
  @moduledoc """
  The canonical per-ticket state machine record.

  A record holds everything the machine owns for one ticket: its current phase, the phase
  a CI Fix stay came from (so a mechanical repair can return it), the holds that pause it
  (Blocked / Needs Decision), the CI state of each PR head it has seen, its verdict records, its
  signals ledger (the timeline both the machinery and agents read) and the runs dispatched since it
  last made progress, which `SymphonyElixir.DispatchLoop` counts, and the decisions a person recorded
  on it (`SymphonyElixir.Decisions`), which the description's Decisions section projects, and
  the PR and CI watcher's fact record (`pr_watch`, written by `SymphonyElixir.PrWatch.Repo`).

  The record is persisted by `SymphonyElixir.RunStore`; this module owns its shape and the
  operations that move it. It is inert by design: nothing dispatches on a record yet. It exists so
  every later sub-ticket of the state-machine redesign reads and writes the ticket's state in one
  place, and so the signals ledger can be injected into run prompts (see
  `SymphonyElixir.PromptBuilder`).
  """

  alias SymphonyElixir.PrDecision
  alias SymphonyElixir.PrWatch.Attempts

  @max_signals 50
  @max_verdicts 50
  @max_ci_states 20
  # The dispatch-loop limits are validated to at most this many runs (`Config.Schema.Watchdog`).
  @max_dispatches 50

  @hold_kinds [:blocked, :needs_decision]

  @typedoc """
  What a hold waits on, structured so the machine can clear it on its own: the dependency key(s)
  it is blocked by (`type: "dependency"`), an access need (`type: "access"`) or the fix ticket a
  self-heal filed (`type: "fix_ticket"`).
  """
  @type waits_on :: %{type: String.t(), keys: [String.t()]} | nil

  @typedoc "A hold pauses the ticket in its phase; the label is only its projection."
  @type hold :: %{
          kind: :blocked | :needs_decision,
          reason: String.t() | nil,
          clearing_condition: String.t() | nil,
          waits_on: waits_on(),
          decision: map() | nil,
          set_at: DateTime.t() | nil
        }

  @typedoc "A verdict record binds an outcome to the head SHA it judged."
  @type verdict :: %{
          kind: String.t(),
          head_sha: String.t() | nil,
          outcome: String.t(),
          recorded_at: DateTime.t() | nil
        }

  @typedoc "One entry of the signals ledger."
  @type signal :: %{name: String.t(), details: map(), at: DateTime.t()}

  @typedoc """
  One run Symphony dispatched for the ticket: its run kind, the state and PR head it started on, and
  how it ended (`outcome`, nil while it runs): the exit, and the PR head it left.
  """
  @type dispatch :: %{
          kind: String.t(),
          run_id: String.t() | nil,
          state: String.t() | nil,
          head: String.t() | nil,
          at: DateTime.t() | nil,
          outcome: %{exit: String.t(), head: String.t() | nil, at: DateTime.t() | nil} | nil
        }

  @typedoc """
  A person's grant to unlock a protected path that a run used (`SymphonyElixir.PathUnlock`): the
  grant's id, the run that used it and when. A used grant never unlocks the path again.
  """
  @type path_unlock :: %{id: String.t(), run_id: String.t() | nil, at: DateTime.t() | nil}

  @typedoc """
  One decision a person recorded on the ticket (`SymphonyElixir.Decisions`): the id of the request
  comment it answers (or `ruling-<comment id>`), the day, the request's title and question, the
  answer and what it means for scope. The list keeps the order they were recorded in, which numbers
  them `D1`, `D2`…
  """
  @type decision :: %{
          key: String.t(),
          date: Date.t() | String.t(),
          title: String.t(),
          question: String.t(),
          answer: String.t(),
          scope: String.t()
        }

  @typedoc "The CI state of one PR head."
  @type ci_state :: %{head_sha: String.t() | nil, status: String.t(), updated_at: DateTime.t() | nil}

  @typedoc """
  What the self-heal lane last did for this ticket: the broken component and the failure signature
  it last saw, the repo that owns the fix (the design's scope rule), the fix ticket it filed or
  reused, and how many times the flow has retried the block. It is how a recurring block is
  compared old against new (`SymphonyElixir.SelfHeal`).
  """
  @type self_heal :: %{
          component: String.t(),
          scope: String.t() | nil,
          signature: String.t(),
          fix_ticket: String.t() | nil,
          attempts: non_neg_integer(),
          at: DateTime.t() | nil
        }

  @typedoc """
  What the landing order keeps of a watched ticket: its state and head, and since when; the files
  its open PR changes; and the PR it waits for (`SymphonyElixir.LandingOrder.wait/0`), and since when.
  """
  @type landing :: %{
          state: String.t() | nil,
          head_sha: String.t() | nil,
          state_since: DateTime.t(),
          progress_at: DateTime.t(),
          files: [String.t()] | nil,
          waits_for: map() | nil,
          waits_since: DateTime.t() | nil
        }

  @typedoc """
  What the PR and CI watcher last read of the ticket's PR (`SymphonyElixir.PrWatch`): the facts
  `SymphonyElixir.PrDecision.decide/1` reads, the PR and head they were read on, how they arrived
  (`:poll` or `:webhook`) and when, when a webhook delivery last named the PR (`delivered_at`), the
  CI the last read found (`read_ci`, which a delivery's patch of `facts` leaves), the base branch it
  was read on, whether GitHub's rate limit stopped the read (with when it
  resets), the rate limit the read left, and what the landing order keeps of the ticket (its state
  and head, and since when, its files and the PR it waits for). `decision` is what the watcher
  decided on the last read (`SymphonyElixir.PrDecision`): the rule, the kind of action, its reason,
  who a wait is on and what ends it. `stay` is the phase of the current stay (the one a move of the
  watcher put the ticket in, else the one it was read in), and `applied` lists the actions done in
  that stay, per head and rule (`SymphonyElixir.PrDecision.Apply`), `attempts` the CI Fix runs counted and what
  else the watcher keeps between reads (`SymphonyElixir.PrWatch.Attempts`), `fix` what the ticket's
  CI Fix run reads (the red head's failure, the conflict), and `links` the links it added.
  """
  @type pr_watch :: %{
          facts: PrDecision.Facts.t(),
          pr_url: String.t() | nil,
          head_sha: String.t() | nil,
          source: :poll | :webhook,
          read_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil,
          read_ci: :pending | :green | :none | :red | :required_missing | nil,
          base_ref: String.t() | nil,
          github: :ok | {:rate_limited, DateTime.t() | nil},
          rate_limit: %{remaining: non_neg_integer() | nil, reset_at: DateTime.t() | nil} | nil,
          landing: landing() | nil,
          stay: PrDecision.Facts.phase() | nil,
          decision: map() | nil,
          applied: [map()],
          attempts: map(),
          fix: %{ci_failure: map() | nil, pr_conflict: map() | nil},
          links: [map()]
        }

  @type t :: %{
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          phase: String.t() | nil,
          ci_fix_origin: String.t() | nil,
          holds: [hold()],
          ci_states: [ci_state()],
          verdicts: [verdict()],
          signals: [signal()],
          self_heal: self_heal() | nil,
          dispatches: [dispatch()],
          path_unlocks: [path_unlock()],
          decisions: [decision()],
          pr_watch: pr_watch() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  A new record for `repo_key`'s `issue_id`, with any `attrs` applied. `attrs` may set `:phase`,
  `:issue_identifier`, `:holds`, `:ci_states`, `:verdicts` and `:signals`; anything else is kept.
  """
  @spec new(String.t(), String.t(), map()) :: t()
  def new(repo_key, issue_id, attrs \\ %{}) when is_binary(issue_id) do
    attrs
    |> Map.new()
    |> Map.put(:repo_key, repo_key)
    |> Map.put(:issue_id, issue_id)
    |> normalize()
  end

  @doc """
  Fills a record's defaults and normalizes its lists, so a record read from the store and a record
  built by a caller have the same shape. A non-map is treated as an empty record.
  """
  @spec normalize(map() | term()) :: t()
  def normalize(record) when is_map(record) do
    %{
      repo_key: map_string(record, :repo_key),
      issue_id: map_string(record, :issue_id),
      issue_identifier: map_string(record, :issue_identifier),
      phase: map_string(record, :phase),
      ci_fix_origin: map_string(record, :ci_fix_origin),
      holds: normalize_holds(Map.get(record, :holds)),
      ci_states: normalize_ci_states(Map.get(record, :ci_states)),
      verdicts: normalize_verdicts(Map.get(record, :verdicts)),
      signals: normalize_signals(Map.get(record, :signals)),
      self_heal: normalize_self_heal(Map.get(record, :self_heal)),
      dispatches: normalize_dispatches(Map.get(record, :dispatches)),
      path_unlocks: normalize_path_unlocks(Map.get(record, :path_unlocks)),
      decisions: normalize_decisions(Map.get(record, :decisions)),
      pr_watch: normalize_pr_watch(Map.get(record, :pr_watch)),
      updated_at: map_datetime(record, :updated_at)
    }
  end

  def normalize(_record) do
    %{
      repo_key: nil,
      issue_id: nil,
      issue_identifier: nil,
      phase: nil,
      ci_fix_origin: nil,
      holds: [],
      ci_states: [],
      verdicts: [],
      signals: [],
      self_heal: nil,
      dispatches: [],
      path_unlocks: [],
      decisions: [],
      pr_watch: nil,
      updated_at: nil
    }
  end

  @doc """
  Marks the grants in `ids` that no run used yet as used by `run_id`, and returns them with the
  record. A grant already used is left out, so each one unlocks its path for one run only.
  """
  @spec claim_path_unlocks(t(), [String.t()], String.t() | nil, DateTime.t()) :: {t(), [String.t()]}
  def claim_path_unlocks(record, ids, run_id, at \\ DateTime.utc_now()) when is_list(ids) do
    record = normalize(record)
    used = MapSet.new(record.path_unlocks, & &1.id)
    claimed = ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.reject(&MapSet.member?(used, &1))

    case claimed do
      [] ->
        {record, []}

      claimed ->
        unlocks = Enum.map(claimed, &%{id: &1, run_id: normalize_string(run_id), at: at})
        {%{record | path_unlocks: record.path_unlocks ++ unlocks, updated_at: at}, claimed}
    end
  end

  @doc """
  Appends the `entries` whose key the record does not hold yet to its decisions, each once, and
  returns the record with its whole list. When the record holds no decision yet, the `backfill` ones
  (the decisions a description recorded before the store kept them) go first, so a ticket is
  backfilled once and never twice. A record nothing is added to is returned as it was.
  """
  @spec put_decisions(t(), [map()], [map()], DateTime.t()) :: t()
  def put_decisions(record, entries, backfill \\ [], at \\ DateTime.utc_now()) when is_list(entries) and is_list(backfill) do
    record = normalize(record)
    base = if record.decisions == [], do: normalize_decisions(backfill), else: record.decisions
    keys = MapSet.new(base, & &1.key)
    added = entries |> normalize_decisions() |> Enum.reject(&MapSet.member?(keys, &1.key))

    case base ++ added do
      same when same == record.decisions -> record
      decisions -> %{record | decisions: decisions, updated_at: at}
    end
  end

  @doc "The decisions recorded on the ticket, in the order they were recorded."
  @spec decisions(t()) :: [decision()]
  def decisions(record), do: record |> normalize() |> Map.fetch!(:decisions)

  @doc """
  Sets the watcher's fact record (`t:pr_watch/0`); nil clears it, as when the ticket leaves the
  watched phases. A record whose `facts` is not a `PrDecision.Facts` struct reads as nil.
  """
  @spec put_pr_watch(t(), map() | nil, DateTime.t()) :: t()
  def put_pr_watch(record, pr_watch, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:pr_watch, normalize_pr_watch(pr_watch))
    |> Map.put(:updated_at, at)
  end

  @doc "The watcher's fact record, or nil when the ticket is not watched."
  @spec pr_watch(t()) :: pr_watch() | nil
  def pr_watch(record), do: record |> normalize() |> Map.fetch!(:pr_watch)

  @doc "Sets the record's phase, the state the machine believes the ticket is in."
  @spec put_phase(t(), String.t() | nil, DateTime.t()) :: t()
  def put_phase(record, phase, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:phase, normalize_string(phase))
    |> Map.put(:updated_at, at)
  end

  @doc """
  Records the phase a CI Fix ticket came from, so a mechanical repair can return it there. The
  origin is recorded when the ticket enters the CI Fix state (see `SymphonyElixir.CiFix`); a `nil`
  clears it.
  """
  @spec put_ci_fix_origin(t(), String.t() | nil, DateTime.t()) :: t()
  def put_ci_fix_origin(record, origin, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:ci_fix_origin, normalize_string(origin))
    |> Map.put(:updated_at, at)
  end

  @doc "The phase the ticket's current CI Fix stay came from, or nil."
  @spec ci_fix_origin(t()) :: String.t() | nil
  def ci_fix_origin(record), do: record |> normalize() |> Map.fetch!(:ci_fix_origin)

  @doc """
  Records what the self-heal lane last did for the ticket: the broken component, the repo that owns
  the fix, the failure signature, the fix ticket it filed or reused and the retry count. A record
  with no `:component` clears it, which is how a healed ticket forgets the block.
  """
  @spec put_self_heal(t(), map(), DateTime.t()) :: t()
  def put_self_heal(record, attrs, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.put(:self_heal, self_heal_from(attrs, at))
    |> Map.put(:updated_at, at)
  end

  @doc "The ticket's self-heal bookkeeping, or nil when it has none."
  @spec self_heal(t()) :: self_heal() | nil
  def self_heal(record), do: record |> normalize() |> Map.fetch!(:self_heal)

  @doc """
  Drops the stale fix-ticket pointer from the ticket's self-heal bookkeeping, keeping the broken
  component, the failure signature and the retry count. The fix ticket a hold waited on has gone
  terminal, so it no longer owns the component; the signature stays so a block that recurs after the
  repair landed is compared against the failure the repair was for rather than judged as a first
  one. A record with no bookkeeping is unchanged.
  """
  @spec clear_fix_ticket(t(), DateTime.t()) :: t()
  def clear_fix_ticket(record, at \\ DateTime.utc_now()) do
    record
    |> normalize()
    |> Map.update!(:self_heal, &drop_fix_ticket/1)
    |> Map.put(:updated_at, at)
  end

  @doc """
  Records a named signal at the head of the ledger, with `details` (a map) and the time it
  happened. Unknown signal names are kept as given; the ledger is bounded to the newest entries.
  """
  @spec record_signal(t(), String.t(), map(), DateTime.t()) :: t()
  def record_signal(record, name, details \\ %{}, at \\ DateTime.utc_now()) do
    signal = %{name: normalize_string(name) || "", details: Map.new(details || %{}), at: at}

    record
    |> normalize()
    |> Map.update!(:signals, &Enum.take([signal | &1], @max_signals))
    |> Map.put(:updated_at, at)
  end

  @doc """
  Sets (or replaces) a hold of `kind`. A hold records why the ticket waits and what clears it; a
  Needs Decision hold also carries its decision payload.
  """
  @spec set_hold(t(), :blocked | :needs_decision, map(), DateTime.t()) :: t()
  def set_hold(record, kind, attrs \\ %{}, at \\ DateTime.utc_now()) when kind in @hold_kinds do
    hold = %{
      kind: kind,
      reason: map_string(attrs, :reason),
      clearing_condition: map_string(attrs, :clearing_condition),
      waits_on: map_waits_on(attrs),
      decision: map_decision(attrs),
      set_at: at
    }

    record
    |> normalize()
    |> Map.update!(:holds, fn holds -> [hold | Enum.reject(holds, &(&1.kind == kind))] end)
    |> Map.put(:updated_at, at)
  end

  @doc """
  Clears the hold of `kind`, if set; the ticket continues in place. A hold that lifts is progress —
  a person unblocked it, answered its decision, or what it waited on landed — so the runs dispatched
  before it are no longer counted as a loop.
  """
  @spec clear_hold(t(), :blocked | :needs_decision, DateTime.t()) :: t()
  def clear_hold(record, kind, at \\ DateTime.utc_now()) when kind in @hold_kinds do
    record = normalize(record)
    held? = Enum.any?(record.holds, &(&1.kind == kind))

    record
    |> Map.update!(:holds, &Enum.reject(&1, fn hold -> hold.kind == kind end))
    |> Map.update!(:dispatches, &if(held?, do: [], else: &1))
    |> Map.put(:updated_at, at)
  end

  @doc "The hold of `kind` on the record, or nil."
  @spec get_hold(t(), :blocked | :needs_decision) :: hold() | nil
  def get_hold(record, kind) when kind in @hold_kinds do
    record |> normalize() |> Map.fetch!(:holds) |> Enum.find(&(&1.kind == kind))
  end

  @doc "Whether a hold of `kind` is set."
  @spec hold?(t(), :blocked | :needs_decision) :: boolean()
  def hold?(record, kind) when kind in @hold_kinds do
    record |> normalize() |> Map.fetch!(:holds) |> Enum.any?(&(&1.kind == kind))
  end

  @doc """
  Records a verdict bound to the head SHA it judged. A verdict is a decision recorded, so the runs
  dispatched before it are no longer counted as a loop.
  """
  @spec record_verdict(t(), String.t(), String.t() | nil, String.t(), DateTime.t()) :: t()
  def record_verdict(record, kind, head_sha, outcome, at \\ DateTime.utc_now()) do
    verdict = %{
      kind: normalize_string(kind) || "",
      head_sha: normalize_string(head_sha),
      outcome: normalize_string(outcome) || "",
      recorded_at: at
    }

    record
    |> normalize()
    |> Map.update!(:verdicts, &Enum.take([verdict | &1], @max_verdicts))
    |> Map.put(:dispatches, [])
    |> Map.put(:updated_at, at)
  end

  @doc "Upserts the CI state (`running` / `green` / `red`) of one PR head, newest first."
  @spec record_ci_state(t(), String.t() | nil, String.t(), DateTime.t()) :: t()
  def record_ci_state(record, head_sha, status, at \\ DateTime.utc_now()) do
    head_sha = normalize_string(head_sha)
    state = %{head_sha: head_sha, status: normalize_string(status) || "", updated_at: at}

    record
    |> normalize()
    |> Map.update!(:ci_states, fn states ->
      [state | Enum.reject(states, &(&1.head_sha == head_sha))] |> Enum.take(@max_ci_states)
    end)
    |> Map.put(:updated_at, at)
  end

  @doc """
  Upserts the CI state of one PR head with last-write-wins ordering: a write whose `at` is older
  than the entry the record already holds for that head is dropped (`:stale`), so a slow webhook
  delivery can't overwrite a newer poll. A write that repeats the held status is `:unchanged`; any
  other accepted write is `:changed`, which is what projects the ticket's CI label. `at` is the
  check's completion time (or the observation time when the read carries none).
  """
  @spec put_ci_state(t(), String.t() | nil, String.t(), DateTime.t()) ::
          {t(), :changed | :unchanged | :stale}
  def put_ci_state(record, head_sha, status, at) when is_struct(at, DateTime) do
    record = normalize(record)
    head_sha = normalize_string(head_sha)
    status = normalize_string(status) || ""

    case ci_state(record, head_sha) do
      %{updated_at: %DateTime{} = existing_at} = existing ->
        cond do
          DateTime.compare(at, existing_at) == :lt -> {record, :stale}
          existing.status == status -> {record, :unchanged}
          true -> {record_ci_state(record, head_sha, status, at), :changed}
        end

      _none ->
        {record_ci_state(record, head_sha, status, at), :changed}
    end
  end

  @doc """
  The ticket's current (newest) CI state, or nil before any was recorded. Entries are kept
  newest-first, so this is the state of the head the ticket is on now.
  """
  @spec current_ci_state(t()) :: ci_state() | nil
  def current_ci_state(record) do
    record |> normalize() |> Map.fetch!(:ci_states) |> List.first()
  end

  @doc "The record's CI state for `head_sha`, or nil."
  @spec ci_state(t(), String.t() | nil) :: ci_state() | nil
  def ci_state(record, head_sha) do
    head_sha = normalize_string(head_sha)

    record
    |> normalize()
    |> Map.fetch!(:ci_states)
    |> Enum.find(&(&1.head_sha == head_sha))
  end

  @doc """
  Records a run Symphony dispatched for the ticket at the head of its dispatches: `attrs` names its
  `:kind` (an atom or a string), `:run_id`, and the `:state` and PR `:head` it starts on. The list is
  bounded to the newest entries.
  """
  @spec record_dispatch(t(), map(), DateTime.t()) :: t()
  def record_dispatch(record, attrs, at \\ DateTime.utc_now()) when is_map(attrs) do
    dispatch = %{
      kind: kind_string(Map.get(attrs, :kind)) || "",
      run_id: map_string(attrs, :run_id),
      state: map_string(attrs, :state),
      head: map_string(attrs, :head),
      at: at,
      outcome: nil
    }

    record
    |> normalize()
    |> Map.update!(:dispatches, &Enum.take([dispatch | &1], @max_dispatches))
    |> Map.put(:updated_at, at)
  end

  @doc """
  Records how the dispatched run `run_id` ended: its `:exit` and the PR `:head` it left. A run that
  `counted: false` names (one stopped by a usage limit, say) is dropped instead, so it never counts
  towards a loop. A run the record does not list is ignored.
  """
  @spec record_dispatch_outcome(t(), String.t() | nil, map(), DateTime.t()) :: t()
  def record_dispatch_outcome(record, run_id, attrs, at \\ DateTime.utc_now()) when is_map(attrs) do
    record = normalize(record)
    run_id = normalize_string(run_id)

    if run_id && Enum.any?(record.dispatches, &(&1.run_id == run_id)) do
      record
      |> Map.update!(:dispatches, &put_dispatch_outcome(&1, run_id, attrs, at))
      |> Map.put(:updated_at, at)
    else
      record
    end
  end

  @doc "The runs dispatched since the ticket last made progress, newest first."
  @spec dispatches(t()) :: [dispatch()]
  def dispatches(record), do: record |> normalize() |> Map.fetch!(:dispatches)

  @doc "The newest `limit` signals, newest first, for prompt injection."
  @spec recent_signals(t(), non_neg_integer()) :: [signal()]
  def recent_signals(record, limit \\ 10) when is_integer(limit) and limit >= 0 do
    record |> normalize() |> Map.fetch!(:signals) |> Enum.take(limit)
  end

  defp normalize_pr_watch(%{facts: %PrDecision.Facts{} = facts} = watch) do
    %{
      facts: facts,
      pr_url: map_string(watch, :pr_url),
      head_sha: map_string(watch, :head_sha),
      source: if(Map.get(watch, :source) == :webhook, do: :webhook, else: :poll),
      read_at: map_datetime(watch, :read_at),
      delivered_at: map_datetime(watch, :delivered_at),
      read_ci: read_ci(Map.get(watch, :read_ci)),
      base_ref: map_string(watch, :base_ref),
      github: normalize_github(Map.get(watch, :github)),
      rate_limit: normalize_rate_limit(Map.get(watch, :rate_limit)),
      landing: normalize_landing(Map.get(watch, :landing)),
      stay: stay(Map.get(watch, :stay)),
      decision: map_decision(watch),
      applied: maps(Map.get(watch, :applied)),
      attempts: Attempts.normalize(Map.get(watch, :attempts)),
      fix: normalize_fix(Map.get(watch, :fix)),
      links: maps(Map.get(watch, :links))
    }
  end

  defp normalize_pr_watch(_watch), do: nil

  defp stay(stay) when stay in [:in_progress, :code_review, :qa, :rework, :ci_fix, :merging], do: stay
  defp stay(_stay), do: nil

  defp normalize_fix(%{} = fix), do: %{ci_failure: map_or_nil(Map.get(fix, :ci_failure)), pr_conflict: map_or_nil(Map.get(fix, :pr_conflict))}
  defp normalize_fix(_fix), do: %{ci_failure: nil, pr_conflict: nil}

  defp map_or_nil(%{} = map), do: map
  defp map_or_nil(_value), do: nil

  defp read_ci(ci) when ci in [:pending, :green, :none, :red, :required_missing], do: ci
  defp read_ci(_ci), do: nil

  defp normalize_github({:rate_limited, reset_at}), do: {:rate_limited, datetime(reset_at)}
  defp normalize_github(_github), do: :ok

  defp normalize_rate_limit(%{} = limit) do
    remaining = Map.get(limit, :remaining)
    %{remaining: if(is_integer(remaining) and remaining >= 0, do: remaining), reset_at: map_datetime(limit, :reset_at)}
  end

  defp normalize_rate_limit(_limit), do: nil

  defp normalize_landing(%{state_since: %DateTime{} = since, progress_at: %DateTime{} = progress_at} = landing) do
    %{
      state: map_string(landing, :state),
      head_sha: map_string(landing, :head_sha),
      state_since: since,
      progress_at: progress_at,
      files: string_list_or_nil(Map.get(landing, :files)),
      waits_for: map_or_nil(Map.get(landing, :waits_for)),
      waits_since: map_datetime(landing, :waits_since)
    }
  end

  defp normalize_landing(_landing), do: nil

  defp string_list_or_nil(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list_or_nil(_list), do: nil

  defp maps(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp maps(_list), do: []

  defp datetime(%DateTime{} = datetime), do: datetime
  defp datetime(_value), do: nil

  defp normalize_holds(holds) when is_list(holds) do
    holds
    |> Enum.flat_map(&normalize_hold/1)
    |> Enum.uniq_by(& &1.kind)
  end

  defp normalize_holds(_holds), do: []

  defp normalize_hold(%{kind: kind} = hold) when kind in @hold_kinds do
    [
      %{
        kind: kind,
        reason: map_string(hold, :reason),
        clearing_condition: map_string(hold, :clearing_condition),
        waits_on: map_waits_on(hold),
        decision: map_decision(hold),
        set_at: map_datetime(hold, :set_at)
      }
    ]
  end

  defp normalize_hold(_hold), do: []

  defp normalize_verdicts(verdicts) when is_list(verdicts) do
    verdicts
    |> Enum.flat_map(&normalize_verdict/1)
    |> Enum.take(@max_verdicts)
  end

  defp normalize_verdicts(_verdicts), do: []

  defp normalize_verdict(%{kind: kind} = verdict) when is_binary(kind) do
    [
      %{
        kind: kind,
        head_sha: map_string(verdict, :head_sha),
        outcome: map_string(verdict, :outcome) || "",
        recorded_at: map_datetime(verdict, :recorded_at)
      }
    ]
  end

  defp normalize_verdict(_verdict), do: []

  defp normalize_ci_states(states) when is_list(states) do
    states
    |> Enum.flat_map(&normalize_ci_state/1)
    |> Enum.take(@max_ci_states)
  end

  defp normalize_ci_states(_states), do: []

  defp normalize_ci_state(%{head_sha: head_sha} = state) when is_binary(head_sha) or is_nil(head_sha) do
    [
      %{
        head_sha: normalize_string(head_sha),
        status: map_string(state, :status) || "",
        updated_at: map_datetime(state, :updated_at)
      }
    ]
  end

  defp normalize_ci_state(_state), do: []

  defp normalize_signals(signals) when is_list(signals) do
    signals
    |> Enum.flat_map(&normalize_signal/1)
    |> Enum.take(@max_signals)
  end

  defp normalize_signals(_signals), do: []

  defp normalize_signal(%{name: name} = signal) when is_binary(name) do
    [%{name: name, details: Map.new(Map.get(signal, :details) || %{}), at: map_datetime(signal, :at)}]
  end

  defp normalize_signal(_signal), do: []

  defp put_dispatch_outcome(dispatches, run_id, %{counted: false}, _at), do: Enum.reject(dispatches, &(&1.run_id == run_id))

  defp put_dispatch_outcome(dispatches, run_id, attrs, at) do
    outcome = %{exit: map_string(attrs, :exit) || "", head: map_string(attrs, :head), at: at}
    Enum.map(dispatches, &if(&1.run_id == run_id, do: %{&1 | outcome: outcome}, else: &1))
  end

  defp normalize_path_unlocks(unlocks) when is_list(unlocks) do
    for %{id: id} = unlock <- unlocks, is_binary(id) do
      %{id: id, run_id: map_string(unlock, :run_id), at: map_datetime(unlock, :at)}
    end
  end

  defp normalize_path_unlocks(_unlocks), do: []

  # Each key once, at its first place.
  defp normalize_decisions(decisions) when is_list(decisions) do
    decisions
    |> Enum.flat_map(&normalize_decision/1)
    |> Enum.uniq_by(& &1.key)
  end

  defp normalize_decisions(_decisions), do: []

  defp normalize_decision(%{key: key} = decision) when is_binary(key) and key != "" do
    [
      %{
        key: key,
        date: normalize_date(Map.get(decision, :date)),
        title: text(decision, :title),
        question: text(decision, :question),
        answer: text(decision, :answer),
        scope: text(decision, :scope)
      }
    ]
  end

  defp normalize_decision(_decision), do: []

  defp normalize_date(%Date{} = date), do: date
  defp normalize_date(date) when is_binary(date), do: date
  defp normalize_date(_date), do: ""

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp normalize_dispatches(dispatches) when is_list(dispatches) do
    dispatches
    |> Enum.flat_map(&normalize_dispatch/1)
    |> Enum.take(@max_dispatches)
  end

  defp normalize_dispatches(_dispatches), do: []

  defp normalize_dispatch(%{kind: kind} = dispatch) when is_binary(kind) do
    [
      %{
        kind: kind,
        run_id: map_string(dispatch, :run_id),
        state: map_string(dispatch, :state),
        head: map_string(dispatch, :head),
        at: map_datetime(dispatch, :at),
        outcome: normalize_dispatch_outcome(Map.get(dispatch, :outcome))
      }
    ]
  end

  defp normalize_dispatch(_dispatch), do: []

  defp normalize_dispatch_outcome(%{} = outcome),
    do: %{exit: map_string(outcome, :exit) || "", head: map_string(outcome, :head), at: map_datetime(outcome, :at)}

  defp normalize_dispatch_outcome(_outcome), do: nil

  defp kind_string(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp kind_string(kind), do: normalize_string(kind)

  # Self-heal bookkeeping keeps only a non-blank component: anything else is no bookkeeping at all.
  defp normalize_self_heal(attrs) when is_map(attrs), do: self_heal_from(attrs, map_datetime(attrs, :at))

  defp normalize_self_heal(_attrs), do: nil

  # A record with no bookkeeping has no fix ticket to drop.
  defp drop_fix_ticket(nil), do: nil
  defp drop_fix_ticket(self_heal), do: Map.put(self_heal, :fix_ticket, nil)

  defp self_heal_from(attrs, at) do
    case normalize_string(Map.get(attrs, :component)) do
      nil ->
        nil

      component ->
        %{
          component: component,
          scope: map_string(attrs, :scope),
          signature: map_string(attrs, :signature) || "",
          fix_ticket: map_string(attrs, :fix_ticket),
          attempts: normalize_attempts(Map.get(attrs, :attempts)),
          at: at
        }
    end
  end

  defp normalize_attempts(value) when is_integer(value) and value >= 0, do: value
  defp normalize_attempts(_value), do: 0

  defp map_decision(attrs) do
    case Map.get(attrs, :decision) do
      decision when is_map(decision) -> Map.new(decision)
      _decision -> nil
    end
  end

  # `waits_on` keeps only its structured half: a non-empty string type and a list of string keys.
  defp map_waits_on(attrs) do
    case Map.get(attrs, :waits_on) do
      %{type: type} = waits_on when is_binary(type) ->
        case String.trim(type) do
          "" -> nil
          trimmed -> %{type: trimmed, keys: normalize_keys(Map.get(waits_on, :keys))}
        end

      _waits_on ->
        nil
    end
  end

  defp normalize_keys(keys) when is_list(keys) do
    keys
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_keys(_keys), do: []

  defp map_string(map, key), do: normalize_string(Map.get(map, key))

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp map_datetime(map, key) do
    case Map.get(map, key) do
      %DateTime{} = datetime -> datetime
      _datetime -> nil
    end
  end
end
