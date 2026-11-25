defmodule SymphonyElixir.TicketPlan do
  @moduledoc """
  A groomed ticket's ask and plan, read from its events (`SymphonyElixir.TicketEvents`).

  The ask is what a person wrote, never rewritten: every `ask.recorded` of the ticket, oldest first
  (`ask/1`, `record_ask/4`): the description at Grooming, what a person typed there before the
  first projection, a parent's new ask, and a person's message (or edit of the Linear description)
  that the Conductor read as a change to what is asked (`SymphonyElixir.Conductor.Message`). The plan is a versioned document: each `plan.written` is one version
  (`versions/1`), the newest is the ticket's plan (`current/1`), and `write/4` records the next one
  with the version it assigns. A ticket is groomed exactly when it holds a `plan.written`
  (`groomed?/1`); a ticket that holds none keeps the behaviour it had before plans.

  The plan's checks and where each stands are `SymphonyElixir.TicketChecks`'s. The notes a run
  tagged (`discovery`, `base_fault`) are `notes/1`, and `parent_id/1` finds the ticket whose plan
  and notes a sub-ticket reads next to its own.

  Each plan version and each ask written is shown in Linear at once: the ticket's description is
  projected again (`SymphonyElixir.TicketProjection`).

  Every read takes the ticket's issue id, or the events a caller already holds (oldest first, as
  `SymphonyElixir.RunStore.list_ticket_events/2` reads them), so a caller that read the events once
  reads the store no more.
  """

  alias SymphonyElixir.{PrWatch, RunStore, TicketEvents, TicketProjection}
  alias SymphonyElixir.TicketEvents.{Event, Types}

  @machine_fields [:signal, :signal_details]
  # Where a `qa` check is walked and the state it is walked on, kept across versions (`placed/2`).
  @placed_fields [:setting, :walked_on]
  @ask_max 100_000
  @max_checks 30
  @max_sub_tickets 12

  @typedoc "A ticket: its issue id, or its events, oldest first."
  @type ticket :: String.t() | [Event.t()]

  @typedoc "One `ask.recorded`: the words, where they came from and the event that holds them."
  @type ask :: %{
          text: String.t() | nil,
          source: String.t() | nil,
          from: String.t() | nil,
          at: DateTime.t() | nil,
          event_id: String.t() | nil
        }

  @typedoc "A note a run tagged: its words, its tag and the event that holds it."
  @type note :: %{text: String.t() | nil, tag: String.t(), at: DateTime.t() | nil, event_id: String.t() | nil}

  @doc "Whether the ticket is groomed: it holds a `plan.written`."
  @spec groomed?(ticket()) :: boolean()
  def groomed?(ticket), do: events(ticket, "plan.written") != []

  @doc """
  The ticket's plan: the payload of its newest `plan.written` (its keys as atoms), with the event's
  id as `:event_id` and its time as `:at`. Nil for a ticket that is not groomed.
  """
  @spec current(ticket()) :: map() | nil
  def current(ticket), do: ticket |> versions() |> List.last()

  @doc "Every version of the ticket's plan, oldest first, each as `current/1` gives the newest."
  @spec versions(ticket()) :: [map()]
  def versions(ticket) do
    for %Event{} = event <- events(ticket, "plan.written") do
      event.payload |> Map.drop(@machine_fields) |> Map.merge(%{event_id: event.id, at: event.at})
    end
  end

  @doc """
  Records `plan` as the next version of the plan of `repo_key`'s ticket `issue_id`: a
  `plan.written` whose `version` is one more than the newest (1 for the first), whatever version
  `plan` names. `opts` are `SymphonyElixir.TicketEvents.record/5`'s, and `new_ask` (below).

  It names the checks: a check that comes with the id a check of an earlier version had keeps it,
  and with it what was recorded for that check; any other (no id, or one no version used) gets a
  new id that no version of the ticket ever used (`c1`, `c2`, and on from the highest ever used).
  A `qa` check that keeps an id and leaves out its `setting` or `walked_on` keeps the ones the
  newest version holding that id recorded, so a later turn that writes the checks again never
  drops them. Neither is required: a plan written before them stays valid.

  Besides what the type's schema refuses (`{:invalid_payload, fields}`), a plan is refused, with
  what is wrong in plain words (`{:invalid_plan, reasons}`), when it holds more than
  `max_checks/0` checks or `max_sub_tickets/0` sub-tickets, two checks share an id, a `qa`
  check names no `action` or nothing to `expect`, two sub-tickets share a key, or a sub-ticket
  waits `after` itself or a key the plan does not hold. With `qa_setting: true` (a later Conductor
  turn's plan), a `qa` check new to the plan that names no `setting` or no `walked_on` is refused
  too. Nothing is written then.

  Outcomes bind: a version that removes an `outcome` check of the version before it, or changes
  its statement, is refused the same way, unless an `ask.recorded` was written after that version.
  A new ask is what permits changing what the ticket must reach. The first version is free. A
  caller that records the new ask right after the version it permits says so with `new_ask: true`.

  A version written asks the PR and CI watcher to read the ticket now
  (`SymphonyElixir.PrWatch.read_ticket/2`): the code on its pull request is behind the new plan,
  so a merge GitHub would make on its own is held on that read, not on the next timer.
  """
  @spec write(String.t() | nil, String.t(), map(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def write(repo_key, issue_id, plan, opts \\ []) when is_binary(issue_id) and is_map(plan) do
    history = issue_id |> RunStore.list_ticket_events(types: ["plan.written", "ask.recorded"]) |> List.wrap() |> Enum.filter(&is_struct(&1, Event))
    earlier = versions(history)
    payload = plan |> Map.drop([:version, "version"]) |> Map.put(:version, length(earlier) + 1) |> identified(earlier) |> placed(earlier)

    {new_ask?, opts} = Keyword.pop(opts, :new_ask, false)
    {drop?, opts} = Keyword.pop(opts, :drop_outcomes, false)
    {qa_setting?, opts} = Keyword.pop(opts, :qa_setting, false)
    binding = if new_ask?, do: [], else: history

    with :ok <- sized(payload),
         {:ok, valid} <- Types.validate("plan.written", payload, :machine, nil),
         :ok <- coherent(valid, changed_outcomes(valid, binding, drop?) ++ unplaced(valid, earlier, qa_setting?)),
         {:ok, event} <- TicketEvents.record(repo_key, issue_id, "plan.written", valid, opts) do
      TicketProjection.changed(repo_key, issue_id)
      # A new version holds a merge the code is behind (`SymphonyElixir.PrDecision`'s R9a): the
      # watcher reads the ticket at once, so auto-merge goes off before GitHub can land the old code.
      :ok = PrWatch.read_ticket(repo_key, issue_id)
      {:ok, event}
    end
  end

  # A plan a person can read: no more checks or sub-tickets than the limits.
  defp sized(plan) do
    reasons =
      for {key, max, what} <- [{:checks, @max_checks, "checks"}, {:sub_tickets, @max_sub_tickets, "sub-tickets"}],
          entries = field(plan, key),
          is_list(entries) and length(entries) > max,
          do: "a plan holds at most #{max} #{what}, and this one holds #{length(entries)}"

    if reasons == [], do: :ok, else: {:error, {:invalid_plan, reasons}}
  end

  # Each check under an id of its own: the one it kept from an earlier version, else a new one no
  # version of the ticket ever used, so a new check never meets what was recorded for an old one.
  defp identified(plan, earlier) do
    key = if is_map_key(plan, "checks"), do: "checks", else: :checks

    case Map.get(plan, key) do
      checks when is_list(checks) -> Map.put(plan, key, identify(checks, used_ids(earlier)))
      _not_a_list -> plan
    end
  end

  defp identify(checks, used) do
    newest = used |> Enum.flat_map(&number/1) |> Enum.max(fn -> 0 end)

    {checks, _newest} =
      Enum.map_reduce(checks, newest, fn check, newest ->
        if is_map(check) and check_id(check) not in used, do: {put_id(check, "c#{newest + 1}"), newest + 1}, else: {check, newest}
      end)

    checks
  end

  # A `qa` check that keeps the id of a stored one and leaves out where it is walked (`setting`) or
  # the state it is walked on (`walked_on`) keeps the stored ones: a later turn never drops them.
  defp placed(plan, earlier) do
    key = if is_map_key(plan, "checks"), do: "checks", else: :checks
    stored = for %{checks: checks} <- earlier, %{} = check <- checks, into: %{}, do: {check_id(check), check}

    case Map.get(plan, key) do
      checks when is_list(checks) -> Map.put(plan, key, Enum.map(checks, &place(&1, stored)))
      _not_a_list -> plan
    end
  end

  defp place(check, stored) do
    with %{} <- check, "qa" <- field(check, :kind), %{} = before <- Map.get(stored, check_id(check)) do
      Enum.reduce(@placed_fields, check, fn name, check ->
        if is_nil(field(check, name)) and not is_nil(field(before, name)), do: put_field(check, name, field(before, name)), else: check
      end)
    else
      _new_or_other_kind -> check
    end
  end

  # With `qa_setting: true` a `qa` check new to the plan says where it is walked and on what state;
  # one kept from a version that had neither may still go without (a plan from before them).
  defp unplaced(_plan, _earlier, false), do: []

  defp unplaced(plan, earlier, true) do
    used = used_ids(earlier)
    for %{kind: "qa", id: id} = check <- plan.checks, id not in used, name <- @placed_fields, not Map.has_key?(check, name), do: "QA check #{id} has no #{name}"
  end

  defp used_ids(versions), do: for(%{checks: checks} <- versions, check <- checks, uniq: true, do: check_id(check))

  defp number("c" <> digits) do
    case Integer.parse(digits) do
      {number, ""} -> [number]
      _other -> []
    end
  end

  defp number(_id), do: []

  defp check_id(check), do: field(check, :id)
  defp put_field(check, name, value), do: Map.put(check, if(Enum.any?(Map.keys(check), &is_binary/1), do: Atom.to_string(name), else: name), value)
  defp put_id(check, id), do: check |> Map.drop([:id, "id"]) |> Map.put(if(Enum.any?(Map.keys(check), &is_binary/1), do: "id", else: :id), id)

  # Outcomes bind: a version that drops an outcome check of the one before it, or rewords it, is
  # refused, unless the person asked for something since that version was written. A drop the
  # caller permits (`drop?`) is no change; a rewording still is.
  defp changed_outcomes(plan, history, drop?) do
    {newer, older} = history |> Enum.reverse() |> Enum.split_while(&(&1.type != "plan.written"))

    case older do
      [%Event{payload: previous} | _rest] when newer == [] ->
        for %{} = check <- field(previous, :checks), field(check, :kind) == "outcome", change = outcome_change(check, plan.checks, drop?), do: change

      _first_version_or_new_ask ->
        []
    end
  end

  defp outcome_change(check, checks, drop?) do
    id = field(check, :id)

    case Enum.find(checks, &(&1.id == id)) do
      %{kind: "outcome", statement: statement} ->
        if String.trim(statement) == String.trim(to_string(field(check, :statement))), do: nil, else: "outcome check #{id} was reworded, and no new ask says so"

      _dropped ->
        if drop?, do: nil, else: "outcome check #{id} was removed, and no new ask says so"
    end
  end

  defp coherent(plan, outcome_changes) do
    checks = plan.checks
    sub_tickets = Map.get(plan, :sub_tickets, [])
    keys = Enum.map(sub_tickets, & &1.key)

    reasons =
      outcome_changes ++
        repeated("check id", Enum.map(checks, & &1.id)) ++
        for(%{kind: "qa"} = check <- checks, field <- [:action, :expect], not Map.has_key?(check, field), do: "QA check #{check.id} has no #{field}") ++
        repeated("sub-ticket key", keys) ++
        for(%{key: key} = entry <- sub_tickets, after_key <- Map.get(entry, :after, []), after_key == key or after_key not in keys, do: "sub-ticket #{key} waits after #{after_key}")

    if reasons == [], do: :ok, else: {:error, {:invalid_plan, reasons}}
  end

  defp repeated(what, values), do: for(value <- Enum.uniq(values -- Enum.uniq(values)), do: "#{what} #{value} is used twice")

  @doc "The most characters one ask holds (`ask.recorded`'s `text`). A longer one is never cut: it is not recorded."
  @spec ask_max() :: pos_integer()
  def ask_max, do: @ask_max

  @doc "The most checks one plan version holds."
  @spec max_checks() :: pos_integer()
  def max_checks, do: @max_checks

  @doc "The most sub-tickets one plan version holds."
  @spec max_sub_tickets() :: pos_integer()
  def max_sub_tickets, do: @max_sub_tickets

  @doc "Every ask of the ticket, oldest first (`t:ask/0`)."
  @spec ask(ticket()) :: [ask()]
  def ask(ticket) do
    for %Event{payload: payload} = event <- events(ticket, "ask.recorded") do
      %{text: field(payload, :text), source: field(payload, :source), from: field(payload, :from), at: event.at, event_id: event.id}
    end
  end

  @doc """
  Records what a person asked for on `repo_key`'s ticket `issue_id`, word for word, as an
  `ask.recorded`. `opts[:source]` says where it came from (`linear`, the default, `message` or
  `parent`) and `opts[:from]` the parent ticket or the message event; the other `opts` are
  `SymphonyElixir.TicketEvents.record/5`'s.
  """
  @spec record_ask(String.t() | nil, String.t(), String.t(), keyword()) :: {:ok, Event.t()} | {:error, term()}
  def record_ask(repo_key, issue_id, text, opts \\ []) when is_binary(issue_id) do
    {ask, opts} = Keyword.split(opts, [:source, :from])
    payload = %{text: text, source: Keyword.get(ask, :source, "linear"), from: Keyword.get(ask, :from)}

    with {:ok, event} <- TicketEvents.record(repo_key, issue_id, "ask.recorded", payload, opts) do
      TicketProjection.changed(repo_key, issue_id)
      {:ok, event}
    end
  end

  @doc "The notes of the ticket that carry a tag (`discovery`, `base_fault`), oldest first (`t:note/0`)."
  @spec notes(ticket()) :: [note()]
  def notes(ticket) do
    for %Event{payload: payload} = event <- events(ticket, "note"), tag = field(payload, :tag), is_binary(tag) do
      %{text: field(payload, :text), tag: tag, at: event.at, event_id: event.id}
    end
  end

  @doc """
  The issue id of the parent of the ticket `issue_id`: the ticket whose identifier its record names
  as its parent. Nil when the ticket has no parent, or Symphony holds no record of it.
  """
  @spec parent_id(String.t()) :: String.t() | nil
  def parent_id(issue_id) when is_binary(issue_id) do
    with %{parent: %{identifier: identifier}} when is_binary(identifier) <- RunStore.get_ticket_state(issue_id),
         records when is_list(records) <- RunStore.list_all_ticket_states(),
         %{issue_id: parent_id} <- Enum.find(records, &(Map.get(&1, :issue_identifier) == identifier)) do
      parent_id
    else
      _none -> nil
    end
  end

  defp events(issue_id, type) when is_binary(issue_id), do: issue_id |> RunStore.list_ticket_events(types: [type]) |> List.wrap() |> events(type)
  defp events(events, type) when is_list(events), do: Enum.filter(events, &match?(%Event{type: ^type}, &1))

  # A payload validated on write has atom keys; a stored record may have kept strings.
  defp field(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
