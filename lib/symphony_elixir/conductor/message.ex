defmodule SymphonyElixir.Conductor.Message do
  @moduledoc """
  A person's message on a groomed ticket goes to the ticket's Conductor, which answers it: what
  Symphony does around that turn (`SymphonyElixir.Conductor.message/4`).

  A message is the Conductor's when the ticket is groomed and the `message` junction is on
  (`due?/2`). Then no run is given the message (`SymphonyElixir.Messages.prepend_unread/4`). The
  turn reads the whole conversation (`SymphonyElixir.Conductor.Facts`) and the message it answers
  (`facts/2`), and its reply is a `conductor.update` at the `message` junction whose `parent` is
  the message.

  ## Owed turns

  A groomed ticket is owed a turn (`owed/1`) for each `message.sent` that has no reply yet (and
  that no run read while the junction was off), and for an `ask.recorded` its parent wrote after
  the current version of its plan (`source: parent`), which the turn answers by writing the plan
  again. So a message written while Grooming still ran, when no turn could start, is answered once
  the plan exists: `SymphonyElixir.Conductor` says so as Grooming ends (`plan_written/2`).

  `tend/2` runs what a ticket is owed. It is started as a message is written (`start/3`), as a
  parent writes a new ask (`recalibrate/3`), as a plan is first written, and by the orchestrator's
  poll for a ticket still owed one (`SymphonyElixir.Orchestrator.conductor_owed/1`), which finds
  them again after a restart (`owed_tickets/1`).

  A turn that failed, or whose answer could not be read, is counted on what it was to answer
  (`unanswered/3`, a status note under `message.try:<event id>:<n>`) and stays owed, so the next
  poll tries again. After 3 failed tries Symphony leaves its own short reply under the message,
  or says that the plan stays as it is, and the turn is owed no more.

  What the answer may do besides reply (`acted/5`, `write_plan/4`):

    * `ask: true` with a `plan`: the message changes what is asked. The plan is recorded as a new
      version (`by: recalibration`, with the Conductor's reason; the ticket's shape and its
      sub-tickets stay Symphony's), then the message's words as an `ask.recorded`
      (`source: message`, `from` the message);
    * `steer`: information the working run needs. It is queued for that run when one works and
      steering is on (`SymphonyElixir.Conductor.Steer`); otherwise it is recorded as the
      Conductor's instructions, which the next run reads;
    * `stop`: the working run's work is wrong now, so it is stopped, and a
      `conductor.intervention` says why;
    * `tree` and `waive`, as at the other junctions.

  On a finished ticket (`finished?/1`) only the reply and `new_ticket` are read: the new ticket is
  created in Todo, Urgent, in the ticket's team and project and assigned as it is, as a ticket of
  its own (not a sub-ticket), linked to the finished one as related; its ask is recorded on it
  (`source: message`) with a `ticket.filed_from`.

  A message on a sub-ticket is also shown to the parent's Conductor (`child_message`), after the
  sub-ticket's own turn: it owes no reply, and records nothing unless it changes the tree or the
  plan.

  A new ask on a ticket that already has a plan, written by its parent (`recalibrate/3`), starts
  the same kind of turn with the ask in place of a message: its answer is the plan's next version.
  """

  require Logger

  alias SymphonyElixir.{Conductor, Config, Messages, Orchestrator, RunStore, TicketEvents, TicketPlan, TicketState}
  alias SymphonyElixir.Conductor.{Answer, Facts, Steer, Tree, Watch}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketEvents.Event

  @junction "message"
  @child_junction "child_message"
  @finished "This ticket is finished, so nothing on it changes any more. Reply to the message. If it asks for more work, " <>
              "put that work in `new_ticket` (`title`, `ask` in the person's own words, optionally `repo`): Symphony creates it " <>
              "as a ticket of its own, linked to this one. Every other field of your answer is ignored."
  @child "A person sent this message on a sub-ticket of this ticket, and the sub-ticket's own Conductor already answered " <>
           "it. You owe no reply. Answer with `tree` operations or a new `plan` only when the message changes what this " <>
           "ticket, or another of its sub-tickets, should do; otherwise answer with nothing and nothing is recorded."
  @tries 3
  @try_key "message.try:"
  @new_ask "This ticket's parent gave it a new ask (`new_ask`) after its plan was written. Write the plan again for what " <>
             "is asked now, as `plan`, with the `reason` it changed for. Keep the id of every check that still stands."

  @doc """
  Whether a person's message on the ticket `issue_id` is answered by the Conductor: the ticket is
  groomed, and the Conductor and its `message` junction are on. `opts[:settings]` is the
  `conductor` section (default `Config.conductor_settings/0`).
  """
  @spec due?(String.t() | nil, keyword()) :: boolean()
  def due?(issue_id, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, &Config.conductor_settings/0)
    on? = Conductor.enabled?(settings) and @junction in settings.junctions
    is_binary(issue_id) and on? and TicketPlan.groomed?(issue_id)
  end

  @doc """
  Starts what the ticket `record` is owed (`tend/2`) now that `message`, a `message.sent`, was
  written on it, when the message is the Conductor's (`due?/2`). Always `:ok`. `opts`: `start`
  (`((-> term) -> term)`, how the work starts; by default the orchestrator starts it,
  `SymphonyElixir.Orchestrator.conductor_owed/1`) and `tend/2`'s.
  """
  @spec start(map(), Event.t(), keyword()) :: :ok
  def start(record, %Event{}, opts) do
    issue_id = Map.get(record, :issue_id)
    if due?(issue_id, opts), do: notify(issue_id, opts), else: :ok
  end

  @doc """
  Starts the turn that writes the plan of the ticket `issue_id` again for the `ask.recorded` its
  parent just wrote on it (`tend/2`). Nothing starts for a ticket that has no plan yet (its Grooming
  reads the ask) or whose messages are not the Conductor's. Always `:ok`. `opts` as `start/3`'s.
  """
  @spec recalibrate(String.t(), Event.t(), keyword()) :: :ok
  def recalibrate(issue_id, %Event{}, opts \\ []) do
    if due?(issue_id, opts), do: notify(issue_id, opts), else: :ok
  end

  @doc """
  Starts what the ticket `issue_id` is owed once its plan is written: a message that arrived while
  Grooming ran had no turn to start. Nothing starts for a ticket that is owed nothing. Always `:ok`.
  `opts` as `start/3`'s.
  """
  @spec plan_written(String.t(), keyword()) :: :ok
  def plan_written(issue_id, opts \\ []) do
    if due?(issue_id, opts) and owed?(owed(issue_id)), do: notify(issue_id, opts), else: :ok
  end

  defp notify(issue_id, opts) do
    case Keyword.get(opts, :start) do
      nil -> Orchestrator.conductor_owed(issue_id)
      start -> start.(fn -> tend(issue_id, opts) end)
    end

    :ok
  end

  @typedoc "What a ticket is owed: the messages with no reply and the parent's asks its plan does not answer, each oldest first."
  @type owed :: %{messages: [Event.t()], asks: [Event.t()]}

  @doc """
  What the groomed ticket `issue_id` (or the ticket whose events these are, oldest first) is owed
  (see the module doc). A ticket with no plan is owed nothing: its Grooming comes first.
  """
  @spec owed(String.t() | [Event.t()]) :: owed()
  def owed(issue_id) when is_binary(issue_id), do: owed(Facts.events(issue_id))

  def owed(events) when is_list(events) do
    case Enum.split_while(Enum.reverse(events), &(&1.type != "plan.written")) do
      {_all, []} ->
        %{messages: [], asks: []}

      {newer, _plan_and_older} ->
        settled = for %Event{type: "conductor.update", parent: parent} when is_binary(parent) <- events, into: MapSet.new(), do: parent
        settled = for %Event{type: "message.read"} = read <- events, into: settled, do: field(read, :message_id)
        open? = &(not MapSet.member?(settled, &1.id) and tries(events, &1.id) < @tries)

        %{
          messages: for(%Event{type: "message.sent"} = message <- events, open?.(message), do: message),
          asks: for(%Event{type: "ask.recorded"} = ask <- Enum.reverse(newer), field(ask, :source) == "parent", open?.(ask), do: ask)
        }
    end
  end

  defp owed?(%{messages: messages, asks: asks}), do: messages != [] or asks != []

  defp tries(events, id), do: Enum.count(events, &(&1.type == "note" and is_binary(&1.idempotency) and String.starts_with?(&1.idempotency, "#{@try_key}#{id}:")))

  @doc """
  The tickets that are owed a turn now, by their issue ids: every ticket Symphony holds a record of
  whose messages are the Conductor's (`due?/2`) and that is owed something (`owed/1`). The
  orchestrator reads it once as it starts. `opts` as `due?/2`'s.
  """
  @spec owed_tickets(keyword()) :: [String.t()]
  def owed_tickets(opts \\ []) do
    for %{issue_id: issue_id} <- List.wrap(RunStore.list_all_ticket_states()), due?(issue_id, opts), owed?(owed(issue_id)), do: issue_id
  end

  @doc """
  Runs the turns the ticket `issue_id` is owed (`owed/1`), now: first the one that writes its plan
  again for its parent's newest ask, then one for each message with no reply, oldest first, each
  also shown to the Conductor of the ticket's parent, when it has one Symphony tracks. `:owed`
  while something is still owed afterwards (a turn failed and is tried again), `:done` otherwise,
  and for a ticket whose messages are not the Conductor's. `opts` are
  `SymphonyElixir.Conductor.message/4`'s.
  """
  @spec tend(String.t(), keyword()) :: :done | :owed
  def tend(issue_id, opts \\ []) do
    with true <- due?(issue_id, opts),
         %{} = record <- RunStore.get_ticket_state(issue_id) do
      record = TicketState.normalize(record)
      answer(record, owed(issue_id), opts)
      if owed?(owed(issue_id)), do: :owed, else: :done
    else
      _not_the_conductors -> :done
    end
  end

  defp answer(record, %{messages: messages, asks: asks}, opts) do
    with %Event{} = ask <- List.last(asks), do: Conductor.message(issue(record), ask, record.repo_key, opts)

    for %Event{} = message <- messages do
      Conductor.message(issue(record), message, record.repo_key, Keyword.put(opts, :finished, finished?(record)))
      to_parent(record, message, opts)
    end
  end

  # A message on a sub-ticket is shown to its parent's Conductor too, once its own turn answered.
  defp to_parent(record, message, opts) do
    with parent_id when is_binary(parent_id) <- TicketPlan.parent_id(record.issue_id),
         %{} = parent <- RunStore.get_ticket_state(parent_id) do
      parent = TicketState.normalize(parent)
      Conductor.message(issue(parent), message, parent.repo_key, opts |> Keyword.drop([:finished]) |> Keyword.merge(junction: @child_junction, child: record.issue_identifier))
    end
  end

  defp issue(record), do: %Issue{id: record.issue_id, identifier: record.issue_identifier, title: record.title, state: record.phase, repo_key: record.repo_key}

  @doc "Whether the ticket `record` is finished: its phase is one of its repo's terminal states (Done, Canceled)."
  @spec finished?(map()) :: boolean()
  def finished?(%{phase: phase, repo_key: repo_key}) when is_binary(phase) and is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> normalize(phase) in Enum.map(settings.tracker.terminal_states, &normalize/1)
      {:error, _reason} -> false
    end
  end

  def finished?(_record), do: false

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()

  @doc """
  What the turn `plan` is about, added to its `facts`: the `message` it answers (and, on a finished
  ticket, the `rules` that bind the answer), the sub-ticket's message and its reply at
  `child_message` (`child`), or the `new_ask` a recalibration plans for.
  """
  @spec facts(map(), map()) :: map()
  def facts(facts, %{message: %{event: %Event{type: "ask.recorded"} = ask}}) do
    new_ask = %{event_id: ask.id, source: field(ask, :source), from: field(ask, :from), text: Facts.cut(field(ask, :text), 6_000)}
    Map.merge(facts, %{new_ask: new_ask, rules: @new_ask})
  end

  def facts(facts, %{junction: @child_junction, message: %{event: message, child: child}}) do
    reply = with %Event{} = reply <- reply(message), do: Facts.cut(field(reply, :text), 1_200)
    Map.merge(facts, %{child: %{identifier: child, event_id: message.id, message: Facts.cut(field(message, :text), 4_000), reply: reply}, rules: @child})
  end

  def facts(facts, %{message: %{event: message, finished: finished}}) do
    said = %{event_id: message.id, by: Messages.writer(message.actor), text: Facts.cut(field(message, :text), 4_000)}
    facts = Map.put(facts, :message, said)
    if finished, do: Map.put(facts, :rules, @finished), else: facts
  end

  def facts(facts, _plan), do: facts

  # The Conductor's reply to `message`, when it has one.
  defp reply(%Event{id: id, issue_id: issue_id}) do
    issue_id |> RunStore.list_ticket_events(types: ["conductor.update"]) |> List.wrap() |> Enum.find(&match?(%Event{parent: ^id}, &1))
  end

  @doc """
  The answer of the turn `plan` as Symphony reads it there: on a finished ticket only the reply and
  `new_ticket`; at `child_message` no update unless the answer changes the tree or the plan, or asks
  the person.
  """
  @spec limited(Answer.t(), map()) :: Answer.t()
  def limited(answer, %{message: %{finished: true}}) do
    answer
    |> Map.merge(%{instructions: nil, ask_person: nil, steer: nil, stop: nil, route: nil})
    |> Map.merge(%{plan: nil, done: false, tree: [], ask: false, waive: []})
  end

  def limited(%{tree: [], plan: nil, ask_person: nil} = answer, %{junction: @child_junction}), do: %{answer | update: nil, refs: [], blocks: []}
  def limited(answer, _plan), do: answer

  @doc """
  Records the plan the turn `plan` answered (`answer.plan`) as the next version of the ticket's
  plan (`by: recalibration`), keeping the ticket's shape and sub-tickets, and then, when the
  message changed what is asked (`answer.ask`), the message's words as an ask. `{:error, why}`, in
  plain words, for a plan Symphony refuses; nothing is recorded then.
  """
  @spec write_plan(map(), Issue.t(), Answer.t(), String.t()) :: :ok | {:error, String.t()}
  def write_plan(%{issue_id: issue_id, repo_key: repo_key, message: %{event: message}} = plan, %Issue{}, %{plan: %{} = answered} = answer, run_id) do
    current = TicketPlan.current(issue_id) || %{}
    kept = Map.take(current, [:shape, :sub_tickets])
    reason = Map.get(answered, :reason) || reason(plan)
    next = answered |> Map.delete(:sub_tickets) |> Map.merge(kept) |> Map.merge(%{by: "recalibration", reason: reason})

    with {:ok, _event} <- TicketPlan.write(repo_key, issue_id, next, run_id: run_id, idempotency: "plan.written:#{run_id}"),
         {:ok, _ask} <- record_ask(answer.ask, repo_key, issue_id, message, run_id) do
      :ok
    else
      {:error, {:invalid_plan, reasons}} -> {:error, "its plan was refused: " <> Enum.join(reasons, "; ")}
      {:error, reason} -> {:error, "its plan could not be recorded: #{inspect(reason)}"}
    end
  end

  defp reason(%{message: %{event: %Event{type: "ask.recorded"} = ask}}), do: "The ask changed: #{field(ask, :from) || "the parent"} asked for something else."
  defp reason(%{junction: @child_junction, message: %{child: child}}), do: "A message on #{child} changed the plan."
  defp reason(_plan), do: "A message changed what is asked."

  defp record_ask(false, _repo_key, _issue_id, _message, _run_id), do: {:ok, nil}

  defp record_ask(true, repo_key, issue_id, %Event{id: id} = message, run_id) do
    opts = [source: "message", from: id, run_id: run_id, idempotency: "ask.recorded:#{id}"]
    TicketPlan.record_ask(repo_key, issue_id, field(message, :text), opts)
  end

  @doc """
  Carries out what the answer of a message turn asks for besides its reply and its plan: the new
  ticket of a finished ticket, the steer and the stop of the working run. The answer, whose reply
  names the new ticket when one was created. `opts`: `running` (`(issue_id -> run | nil)`, the
  ticket's working run, default read from the orchestrator), `stop` (as
  `SymphonyElixir.Conductor.Tree.apply/3`'s) and `Tree.create/4`'s.
  """
  @spec acted(Answer.t(), map(), Issue.t(), String.t(), keyword()) :: Answer.t()
  def acted(answer, %{junction: @junction, message: %{event: %Event{type: "message.sent"} = message}} = plan, %Issue{} = issue, run_id, opts) do
    steer(answer.steer, plan, run_id, opts)
    stop(answer.stop, plan, issue, run_id, opts)
    new_ticket(answer, plan, issue, message, opts)
  end

  def acted(answer, _plan, _issue, _run_id, _opts), do: answer

  defp steer(nil, _plan, _run_id, _opts), do: :ok

  defp steer(%{message: text, when: moment}, plan, run_id, opts) do
    case Steer.enabled?() && working_run(plan.issue_id, opts) do
      %{run_id: working} = run when is_binary(working) ->
        Steer.queue(working, %{text: text, when: moment, trigger: @junction, repo_key: plan.repo_key, issue_id: plan.issue_id})
        if moment == "now" and claude_run?(run), do: Steer.interrupt(working)
        :ok

      _none ->
        # No run to steer now: the next run reads it as the Conductor's instructions.
        payload = %{junction: @junction, text: Facts.fit(text, Answer.instructions_max())}
        record(plan, "conductor.instructions", payload, run_id: run_id, idempotency: "conductor.instructions:#{run_id}")
    end
  end

  defp claude_run?(%{run_profile: %{harness: harness}}), do: to_string(harness) == "claude"
  defp claude_run?(_run), do: false

  defp working_run(issue_id, opts) do
    running = Keyword.get(opts, :running, fn id -> Enum.find(Watch.running_in(Orchestrator.snapshot()), &(&1.issue_id == id)) end)
    running.(issue_id)
  end

  defp stop(nil, _plan, _issue, _run_id, _opts), do: :ok

  defp stop(%{reason: reason}, plan, issue, run_id, opts) do
    name = issue.identifier || plan.issue_id

    case Keyword.get(opts, :stop, &Orchestrator.stop_running/1).(name) do
      {:ok, %{stopped: true}} ->
        payload = %{action: "stopped", reason: Facts.fit(reason, 1_000), by: name, target: name}
        record(plan, "conductor.intervention", payload, run_id: run_id, idempotency: "conductor.intervention:#{run_id}:stopped")

      other ->
        Logger.info("Conductor asked to stop the run of issue_id=#{plan.issue_id} after a message; no run was stopped (#{inspect(other)})")
    end
  end

  defp new_ticket(%{new_ticket: nil} = answer, _plan, _issue, _message, _opts), do: answer

  defp new_ticket(%{new_ticket: wanted} = answer, plan, issue, message, opts) do
    case file(wanted, plan, issue, message, opts) do
      {:ok, filed} ->
        %{answer | update: Facts.fit("#{answer.update}\n\nNew ticket: #{filed.identifier}.", Answer.update_max())}

      {:error, why} ->
        Logger.warning("Conductor's new ticket was not created issue_id=#{plan.issue_id} repo_key=#{plan.repo_key}: #{why}")
        %{answer | update: Facts.fit("#{answer.update}\n\nSymphony could not create the new ticket: #{why}.", Answer.update_max())}
    end
  end

  # A ticket of its own for what a message on a finished ticket asks: related to it, never under it.
  defp file(wanted, plan, issue, message, opts) do
    from = issue.identifier || plan.issue_id
    ask = [source: "message", from: message.id, idempotency: "ask.recorded:#{message.id}"]

    with {:ok, filed} <- Tree.create(plan.repo_key, issue, Map.put(wanted, :after, []), Keyword.merge(opts, standalone: true, ask: ask)) do
      with {:error, reason} <- Keyword.get(opts, :tracker, SymphonyElixir.Tracker).add_related(from, filed.id),
           do: Logger.warning("Could not link #{filed.identifier} as related to #{from}: #{inspect(reason)}")

      _ = TicketEvents.record(filed.repo, filed.id, "ticket.filed_from", %{from: from, by: "conductor", kind: "follow_up"})
      {:ok, filed}
    end
  end

  @doc """
  Counts a turn that failed for `why`, in plain words, on what it was to answer (a status note),
  so it stays owed and is tried again. From the third failure on it is owed no more: a
  message gets Symphony's own reply and stays in the ticket's history, and for a parent's new ask
  the note says that the plan stays as it is. Nothing for a turn that owes nothing (`child_message`).
  """
  @spec unanswered(map(), String.t() | nil, String.t()) :: :ok
  def unanswered(%{junction: @junction, message: %{event: %Event{type: type, id: id} = event}} = plan, run_id, why) when type in ["message.sent", "ask.recorded"] do
    events = Facts.events(plan.issue_id)
    try = tries(events, id) + 1
    left? = try < @tries

    cond do
      type == "message.sent" and reply(event) != nil ->
        :ok

      type == "message.sent" and not left? ->
        text = "The Conductor could not read this message (#{why}), #{@tries} times, so nothing was done with it. It stays in the ticket's history. Send it again to have it read."
        record(plan, "conductor.update", %{junction: @junction, text: Facts.fit(text, Answer.update_max()), refs: []}, run_id: run_id, parent: id, idempotency: "conductor.update:unanswered:#{id}")

      true ->
        record(plan, "note", %{text: Facts.fit(failed(type, why, left?), 4_000), status: true}, run_id: run_id, idempotency: "#{@try_key}#{id}:#{try}")
    end
  end

  def unanswered(_plan, _run_id, _why), do: :ok

  defp failed("message.sent", why, _left?), do: "The Conductor could not answer a message (#{why}). Symphony tries again."
  defp failed("ask.recorded", why, true), do: "The Conductor could not write the plan again for the new ask (#{why}). Symphony tries again."
  defp failed("ask.recorded", why, false), do: "The Conductor could not write the plan again for the new ask (#{why}), #{@tries} times. The plan stays as it is."

  defp record(plan, type, payload, opts) do
    with {:error, reason} <- TicketEvents.record(plan.repo_key, plan.issue_id, type, payload, opts),
         do: Logger.warning("Conductor could not record #{type} issue_id=#{plan.issue_id}: #{inspect(reason)}")

    :ok
  end

  defp field(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
