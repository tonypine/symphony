defmodule SymphonyElixir.Conductor.Message do
  @moduledoc """
  A person's message on a ticket goes to the ticket's Conductor, which answers it at once, in any
  state of the ticket (waiting in the queue or on a dependency, running, waiting on sub-tickets):
  what Symphony does around that turn (`SymphonyElixir.Conductor.message/4`). The turn starts no
  run of the ticket and takes no slot.

  A message is the Conductor's when the Conductor and its `message` junction are on and the ticket
  is groomed, or can be groomed now (`due?/2`): it has no plan, no run but the Conductor's ever
  started on it, the `grooming` junction is on, it is not finished and no question holds it. Such
  a ticket is groomed first, outside any dispatch (`SymphonyElixir.Conductor.groom_now/3`), and
  the message is answered once its plan exists, so the plan its first run works from holds what
  the message asked. Then no run is given the message (`SymphonyElixir.Messages.prepend_unread/4`).
  A ticket that ran without a plan (Grooming off, or given up) keeps the old rule: its next run is
  given the message. The
  turn reads the whole conversation (`SymphonyElixir.Conductor.Facts`) and the message it answers
  (`facts/2`), and its reply is a `conductor.update` at the `message` junction whose `parent` is
  the message.

  ## Owed turns

  A groomed ticket is owed a turn (`owed/1`) for each `message.sent` that has no reply yet (and
  that no run read while the junction was off), and for an `ask.recorded` its parent wrote after
  the current version of its plan (`source: parent`), which the turn answers by writing the plan
  again. A ticket that can be groomed now is owed a turn for each such message too: `tend/2`
  grooms it first; a Grooming there that wrote no plan is a failed try of each message it was for,
  never one of the dispatch's, so the message gets Symphony's own reply after the third and the
  ticket's first run is still groomed. So a message written while Grooming still ran, when no turn could start, is
  answered once the plan exists: `SymphonyElixir.Conductor` says so as Grooming ends
  (`plan_written/2`).

  A person's edit of a groomed ticket's Linear description, once Symphony wrote it, is a message
  too (`source: linear_description`, `SymphonyElixir.Conductor.DescriptionEdit`): the turn reads
  the whole edited text with `rules` that say so, and when the edit changes what is asked its
  answer gives the words it adds (`added`), which are recorded as the ask in place of the whole
  description; an answer that changes the ask without them is refused, and the turn tried again.

  `tend/2` runs what a ticket is owed. It is started as a message is written (`start/3`), as a
  parent writes a new ask (`recalibrate/3`), as a plan is first written, and by the orchestrator's
  poll for a ticket still owed one (`SymphonyElixir.Orchestrator.conductor_owed/1`), which finds
  them again after a restart (`owed_tickets/1`).

  One turn works on a ticket at a time (`SymphonyElixir.Conductor.exclusive/3`): `tend/2` takes
  the ticket's lock, and while another turn holds it (a tree turn, a run's junction, Grooming)
  nothing runs and everything stays owed for the next start. One turn answers every message owed at
  that moment: its reply hangs under the newest, and each earlier one gets a one-line reply that
  points there, so no message stays without one. A turn no provider of `runs.conductor` can take
  now, or that a pause of Symphony or the repository stops, is not a failure: it waits, still owed.
  The turn is given every ask and the newest 20 messages with their replies, no more.

  A turn that failed, or whose answer Symphony refused, is counted on what it was to answer
  (`unanswered/3`, a status note under `message.try:<event id>:<n>` that says why, in plain words
  and with the exact reason of a refusal) and stays owed, so the next poll tries again; the next try
  reads each such note in its facts (`earlier_tries`, `SymphonyElixir.Conductor.Facts.turn_tries/1`),
  so it does not give the same answer again. After 3 failed tries Symphony leaves its own reply under
  the message, which says that nothing was done with it and why the last try failed, or says that
  the plan stays as it is, and the turn is owed no more. A message is as long as an ask (100,000
  characters), and the turn reads it whole.

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
    * `tree` and `waive`, as at the other junctions: on a ticket with sub-tickets the one form that
      adds, rewrites, cancels, stops, reorders and sets the dependencies of the open ones
      (`SymphonyElixir.Conductor.Tree.apply/3`); a `plan` that lists them anyway is read as the
      same changes (`SymphonyElixir.Conductor.Tree.intent/2`).

  A message may be the person's answer, in their own words, to the question the ticket is held on
  (a dispatch loop's, a quiet handoff's, a park's, a spent budget's or a block report's:
  `SymphonyElixir.DirectorMoves.answer_held_question/4`), when it names that question
  (`question_id`). The question goes into the turn's facts (`answers_question`, with `rules` that
  say what to do), and the ticket waits on the turn (`reading_reason/1`) instead of on a person.
  Once the turn ended, `settle/5` leaves the ticket moved, run again (`resume`, or a `steer`), on
  the Conductor's own question, or on the held question asked again, beside the reply: never paused
  with nothing running and nothing asked. A turn that fails 3 times asks the question again too.

  On a finished ticket (`finished?/1`) only the reply and `new_ticket` are read: the new ticket is
  created in Todo, Urgent, in the ticket's team and project and assigned as it is, as a ticket of
  its own (not a sub-ticket), linked to the finished one as related; its ask is recorded on it
  (`source: message`) with a `ticket.filed_from`.

  A message on a sub-ticket is also shown to the parent's Conductor (`child_message`), after the
  sub-ticket's own turn replied: it owes no reply, and records nothing unless it changes the tree
  or the plan. It is a turn the parent is owed (`owed/2`'s `children`), run under the parent's own
  lock, and one turn reads every such message of every sub-ticket that waits; each is then recorded
  as read on the parent (a status note under `child_message.seen:<event id>`), whatever the turn
  answered.

  A new ask on a ticket that already has a plan, written by its parent (`recalibrate/3`), starts
  the same kind of turn with the ask in place of a message: its answer is the plan's next version.
  """

  require Logger

  alias SymphonyElixir.{Conductor, Config, DirectorMoves, Messages, Orchestrator, Pauses, Questions}
  alias SymphonyElixir.Conductor.{Answer, Facts, Grooming, Steer, Tree, Watch}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, TicketEvents, TicketPlan, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @junction "message"
  @grooming "grooming"
  @description_edit "linear_description"
  @edit "This `message` is no message a person sent: it is the ticket's whole Linear description as a person edited it " <>
          "after Symphony had written it from the asks, the plan and its checks. Read what the edit adds or changes " <>
          "compared with the asks and the plan. When it changes what is asked, answer `\"ask\": true` with the plan " <>
          "written again, and put in `added` (then required: an answer without it is refused) the person's own words the edit adds, word for word: Symphony records them " <>
          "as the new ask in place of the whole description. When it changes nothing, say so in `update`."
  @child_junction "child_message"
  @finished "This ticket is finished, so nothing on it changes any more. Reply to the message. If it asks for more work, " <>
              "put that work in `new_ticket` (`title`, `ask` in the person's own words, optionally `repo`): Symphony creates it " <>
              "as a ticket of its own, linked to this one. Every other field of your answer is ignored."
  @child "A person sent this message on a sub-ticket of this ticket, and the sub-ticket's own Conductor already answered " <>
           "it. You owe no reply. Answer with `tree` operations or a new `plan` only when the message changes what this " <>
           "ticket, or another of its sub-tickets, should do; otherwise answer with nothing and nothing is recorded."
  @answers "The person's `message` is their answer, in their own words, to the question this ticket is held on " <>
             "(`answers_question`): it was not one of the question's options. Act on what the words ask, as the person " <>
             "would with the Director: `move` the ticket to the stage they name, or set `\"resume\": true` to run it " <>
             "again where it stands (with a `steer` when the run must know something). When the words can be read two " <>
             "ways that lead to different outcomes, ask with `ask_person`. When you cannot tell what they ask, leave " <>
             "`move` null and `resume` false, and say so in `update`: Symphony asks the person the question again."
  @reading_condition "conductor_answer"
  @symphony %{kind: :symphony, name: "Symphony"}
  @tries 3
  # A message holds as much as an ask, and the turn reads it whole.
  @message_max 100_000
  @try_key "message.try:"
  @seen_key "child_message.seen:"
  # How many messages, with their replies, a turn is given besides every ask.
  @conversation_messages 20
  @together "Answered together with your later message, below."
  @new_ask "This ticket's parent gave it a new ask (`new_ask`) after its plan was written. Write the plan again for what " <>
             "is asked now, as `plan`, with the `reason` it changed for. Keep the id of every check that still stands."

  @doc """
  Whether a person's message on the ticket `issue_id` is answered by the Conductor: the Conductor
  and its `message` junction are on, and the ticket is groomed or can be groomed now
  (`groomable?/2`). `opts[:settings]` is the `conductor` section (default
  `Config.conductor_settings/0`).
  """
  @spec due?(String.t() | nil, keyword()) :: boolean()
  def due?(issue_id, opts \\ []) do
    settings = Keyword.get_lazy(opts, :settings, &Config.conductor_settings/0)
    on? = Conductor.enabled?(settings) and @junction in settings.junctions
    is_binary(issue_id) and on? and (TicketPlan.groomed?(issue_id) or groomable?(issue_id, settings))
  end

  @doc """
  Whether the ticket `issue_id`, which has no plan, can be groomed now for a message, outside any
  dispatch: the `grooming` junction is on in `settings`, Symphony holds the ticket's record, the
  ticket is not finished, no question of it is open (the person's answer comes first) and Grooming
  is due before its first run (`SymphonyElixir.Conductor.Grooming.due?/2`: no plan, no run of its
  own, a try left).
  """
  @spec groomable?(String.t(), Schema.Conductor.t()) :: boolean()
  def groomable?(issue_id, settings) do
    with true <- @grooming in settings.junctions,
         %{} = record <- RunStore.get_ticket_state(issue_id),
         record = TicketState.normalize(record),
         false <- finished?(record),
         [] <- Questions.open({:ticket, record.repo_key, issue_id}) do
      Grooming.due?(:implementation, Facts.read_events(issue_id))
    else
      _not_now -> false
    end
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
    if due?(issue_id, opts) and owed?(owed(issue_id, opts)), do: notify(issue_id, opts), else: :ok
  end

  defp notify(issue_id, opts) do
    case Keyword.get(opts, :start) do
      nil -> Orchestrator.conductor_owed(issue_id)
      start -> start.(fn -> tend(issue_id, opts) end)
    end

    :ok
  end

  @typedoc """
  What a ticket is owed: the messages with no reply and the parent's asks its plan does not answer,
  each oldest first, and the messages on its sub-tickets its Conductor has not read (`children`,
  each the `event` and the sub-ticket's identifier as `child`).
  """
  @type owed :: %{messages: [Event.t()], asks: [Event.t()], children: [%{event: Event.t(), child: String.t()}]}

  @doc """
  What the ticket `issue_id` is owed (see the module doc). A ticket with no plan is owed its
  messages with no reply while the Conductor answers them (`due?/2`: it can be groomed now), and
  nothing otherwise.
  `opts` as `due?/2`'s.
  """
  @spec owed(String.t(), keyword()) :: owed()
  def owed(issue_id, opts \\ []) when is_binary(issue_id) do
    events = Facts.events(issue_id)
    open? = &(not settled?(events, &1) and tries(events, &1.id) < @tries)

    case Enum.split_while(Enum.reverse(events), &(&1.type != "plan.written")) do
      {_all, []} ->
        messages = if due?(issue_id, opts), do: open_messages(events, open?), else: []
        %{messages: messages, asks: [], children: []}

      {newer, _plan_and_older} ->
        %{
          messages: open_messages(events, open?),
          asks: for(%Event{type: "ask.recorded"} = ask <- Enum.reverse(newer), field(ask, :source) == "parent", open?.(ask), do: ask),
          children: children(issue_id, events, opts)
        }
    end
  end

  defp open_messages(events, open?), do: for(%Event{type: "message.sent"} = message <- events, open?.(message), do: message)

  # A message is settled once it has a reply, or a run read it while the junction was off.
  defp settled?(events, %Event{id: id}) do
    Enum.any?(events, fn
      %Event{type: "conductor.update", parent: ^id} -> true
      %Event{type: "message.read"} = read -> field(read, :message_id) == id
      _other -> false
    end)
  end

  # The messages on the ticket's sub-tickets that their own Conductor replied to and this ticket's
  # has not read, oldest first.
  defp children(issue_id, events, opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.conductor_settings/0)
    record = RunStore.get_ticket_state(issue_id)
    subs = for %{id: id, identifier: identifier} <- List.wrap(is_map(record) && Map.get(record, :sub_issues)), is_binary(id), do: {id, identifier}
    seen = for %Event{type: "note", idempotency: @seen_key <> id} <- events, into: MapSet.new(), do: id

    said =
      for {id, identifier} <- subs, @child_junction in settings.junctions, said = Facts.events(id), %Event{type: "message.sent"} = message <- said do
        if not MapSet.member?(seen, message.id) and Enum.any?(said, &match?(%Event{type: "conductor.update", parent: parent} when parent == message.id, &1)),
          do: %{event: message, child: identifier}
      end

    said |> Enum.reject(&is_nil/1) |> Enum.sort_by(&{DateTime.to_unix(&1.event.at, :microsecond), &1.event.id})
  end

  defp owed?(%{messages: messages, asks: asks, children: children}), do: messages != [] or asks != [] or children != []

  defp tries(events, id), do: Enum.count(events, &(&1.type == "note" and is_binary(&1.idempotency) and String.starts_with?(&1.idempotency, "#{@try_key}#{id}:")))

  @doc """
  The tickets that are owed a turn now, by their issue ids: every ticket Symphony holds a record of
  whose messages are the Conductor's (`due?/2`) and that is owed something (`owed/2`). The
  orchestrator reads it once as it starts. `opts` as `due?/2`'s.
  """
  @spec owed_tickets(keyword()) :: [String.t()]
  def owed_tickets(opts \\ []) do
    for %{issue_id: issue_id} <- List.wrap(RunStore.list_all_ticket_states()), due?(issue_id, opts), owed?(owed(issue_id, opts)), do: issue_id
  end

  @doc """
  Runs the turns the ticket `issue_id` is owed (`owed/2`), now, while it holds the ticket's lock:
  the one that writes its plan again for its parent's newest ask, one that answers every message
  with no reply, and one that reads every unread message of its sub-tickets. Then the ticket's
  parent, when it has one, is started for what it is owed in turn. A ticket with no plan is groomed
  first (`opts[:groom]`, default `SymphonyElixir.Conductor.groom_now/3`), and its messages are
  answered once the plan exists.

  `:owed` while something is still owed afterwards: another turn holds the ticket's lock, a turn
  failed and is tried again, or it cannot run now (no provider, a pause). `:done` otherwise, and
  for a ticket whose messages are not the Conductor's. `opts` are
  `SymphonyElixir.Conductor.message/4`'s and `start/3`'s.
  """
  @spec tend(String.t(), keyword()) :: :done | :owed
  def tend(issue_id, opts \\ []) do
    with true <- due?(issue_id, opts),
         %{} = record <- RunStore.get_ticket_state(issue_id),
         record = TicketState.normalize(record),
         :groomed <- groomed(record, opts),
         answer = fn -> answer(record, owed(issue_id, opts), opts) end,
         {:ok, _answered} <- Conductor.exclusive(issue_id, :skip, answer) do
      with parent_id when is_binary(parent_id) <- TicketPlan.parent_id(issue_id), do: plan_written(parent_id, opts)
      if owed?(owed(issue_id, opts)), do: :owed, else: :done
    else
      :busy -> :owed
      :ungroomed -> if owed?(owed(issue_id, opts)), do: :owed, else: :done
      _not_the_conductors -> :done
    end
  end

  # A ticket with no plan is groomed before its messages are answered, and only when a message waits
  # for an answer; one Grooming left without a plan (busy, waiting, a try that failed) stays owed
  # while it can still be groomed.
  defp groomed(record, opts) do
    cond do
      TicketPlan.groomed?(record.issue_id) -> :groomed
      owed(record.issue_id, opts).messages == [] -> :nothing
      true -> groom(record, opts)
    end
  end

  # A Grooming that failed here is a failed try of each message it was for (`unanswered/3`'s count),
  # never one of the dispatch's: after 3 the message gets Symphony's own reply, and the
  # ticket's first run is still groomed.
  defp groom(record, opts) do
    case Keyword.get(opts, :groom, &Conductor.groom_now/3).(issue(record), record.repo_key, opts) do
      {:failed, why} -> groom_failed(record, why, opts)
      _ok -> :ok
    end

    if TicketPlan.groomed?(record.issue_id), do: :groomed, else: :ungroomed
  end

  defp groom_failed(record, why, opts) do
    events = Facts.events(record.issue_id)
    plan = %{repo_key: record.repo_key, issue_id: record.issue_id}
    for %Event{} = message <- owed(record.issue_id, opts).messages, do: count(plan, message, events, nil, why)
  end

  defp answer(record, %{messages: messages, asks: asks, children: children}, opts) do
    issue = issue(record)
    with %Event{} = ask <- List.last(asks), do: Conductor.message(issue, ask, record.repo_key, opts)

    with {earlier, [%Event{} = newest]} <- Enum.split(messages, -1) do
      also = Enum.map(earlier, &%{event: &1})
      Conductor.message(issue, newest, record.repo_key, Keyword.merge(opts, finished: finished?(record), also: also))
    end

    with {earlier, [%{event: newest, child: child}]} <- Enum.split(children, -1),
         :ok <- Conductor.message(issue, newest, record.repo_key, Keyword.merge(opts, junction: @child_junction, child: child, also: earlier)) do
      for %{event: %Event{id: id}, child: child} <- children do
        note = %{text: "The Conductor read a message a person wrote on #{child}.", status: true}
        record(%{repo_key: record.repo_key, issue_id: record.issue_id}, "note", note, idempotency: @seen_key <> id)
      end
    end
  end

  defp issue(record) do
    %Issue{
      id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      description: Map.get(record, :description),
      state: record.phase,
      repo_key: record.repo_key,
      labels: List.wrap(Map.get(record, :labels))
    }
  end

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
  What the turn `plan` is about, added to its `facts`: the `message` it answers, with the
  `earlier_messages` the same reply answers (and, on a finished ticket, the `rules` that bind the
  answer), the sub-ticket's message and its reply at `child_message` (`child`, with the other
  unread ones as `other_children`), or the `new_ask` a recalibration plans for. The facts'
  `conversation` is cut to every ask and the newest #{@conversation_messages} messages.
  """
  @spec facts(map(), map()) :: map()
  def facts(facts, plan), do: facts |> capped() |> about(plan)

  # Every ask stays; of the messages, the newest #{@conversation_messages} with their replies.
  defp capped(%{conversation: said} = facts) when is_list(said) do
    older = said |> Enum.filter(&(&1.kind == "message")) |> Enum.drop(-@conversation_messages) |> MapSet.new(& &1.event_id)
    %{facts | conversation: Enum.reject(said, &MapSet.member?(older, &1.event_id))}
  end

  defp capped(facts), do: facts

  defp about(facts, %{message: %{event: %Event{type: "ask.recorded"} = ask}}) do
    new_ask = %{event_id: ask.id, source: field(ask, :source), from: field(ask, :from), text: Facts.cut(field(ask, :text), 6_000)}
    Map.merge(facts, %{new_ask: new_ask, rules: @new_ask})
  end

  defp about(facts, %{junction: @child_junction, message: %{event: message, child: child} = about}) do
    others = for %{event: event, child: child} <- Map.get(about, :also, []), do: child_said(event, child)
    facts = Map.merge(facts, %{child: child_said(message, child), rules: @child})
    if others == [], do: facts, else: Map.put(facts, :other_children, others)
  end

  defp about(facts, %{message: %{event: message, finished: finished} = about} = plan) do
    earlier = for %{event: event} <- Map.get(about, :also, []), do: said(event)
    facts = Map.put(facts, :message, said(message))
    facts = if earlier == [], do: facts, else: Map.put(facts, :earlier_messages, earlier)

    cond do
      finished -> Map.put(facts, :rules, @finished)
      field(message, :source) == @description_edit -> Map.put(facts, :rules, @edit)
      true -> answers(facts, plan, message)
    end
  end

  defp about(facts, _plan), do: facts

  # A message that answers the question the ticket is held on, in the person's own words: the
  # question goes with it, and the rules say what the turn does about it.
  defp answers(facts, plan, message) do
    with id when is_binary(id) <- field(message, :question_id),
         %{} = question <- Questions.find({:ticket, plan.repo_key, plan.issue_id}, id) do
      options = for option <- question.options, do: %{label: option.label, effect: Map.get(option, :effect)}
      answered = %{question_id: id, title: question.title, question: question.question, why: Map.get(question, :why), options: options}
      Map.merge(facts, %{answers_question: answered, rules: @answers})
    else
      _none -> facts
    end
  end

  defp said(%Event{} = message) do
    said = %{event_id: message.id, by: Messages.writer(message.actor), text: Facts.cut(field(message, :text), @message_max)}
    if field(message, :source) == @description_edit, do: Map.put(said, :source, @description_edit), else: said
  end

  defp child_said(%Event{} = message, child) do
    reply = with %Event{} = reply <- reply(message), do: Facts.cut(field(reply, :text), 1_200)
    %{identifier: child, event_id: message.id, message: Facts.cut(field(message, :text), @message_max), reply: reply}
  end

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
    |> Map.merge(%{plan: nil, done: false, tree: [], dropped: [], ask: false, waive: [], resume: false})
  end

  def limited(%{tree: [], plan: nil, ask_person: nil} = answer, %{junction: @child_junction}), do: %{answer | update: nil, refs: [], blocks: []}
  def limited(answer, _plan), do: answer

  @doc """
  Records the plan the turn `plan` answered (`answer.plan`) as the next version of the ticket's
  plan (`by: recalibration`), keeping the ticket's shape and sub-tickets, which change only through
  `tree` operations, and then, when the message changed what is asked (`answer.ask`), the message's
  words as an ask. Any turn outside Grooming writes the plan this way: a message's, and every turn on
  a ticket with sub-tickets. A plan that gives a `reason` of its own may drop an outcome nothing
  inside the ticket's life can prove (`TicketPlan.write/4`'s `drop_outcomes`); one without a
  reason may not. `{:error, why}`, in plain words, for a plan Symphony refuses; nothing is recorded
  then.
  """
  @spec write_plan(map(), Issue.t(), Answer.t(), String.t()) :: :ok | {:error, String.t()}
  def write_plan(%{issue_id: issue_id, repo_key: repo_key} = plan, %Issue{}, %{plan: %{} = answered} = answer, run_id) do
    current = TicketPlan.current(issue_id) || %{}
    kept = Map.take(current, [:shape, :sub_tickets])
    reason = Map.get(answered, :reason) || reason(plan)
    next = answered |> Map.delete(:sub_tickets) |> Map.merge(kept) |> Map.merge(%{by: "recalibration", reason: reason})
    messages = answered(plan) ++ List.wrap(get_in(plan, [:message, :event]))

    # A message that changes what is asked may change the outcomes: its ask is recorded right after.
    # An outcome is dropped only with the reason the turn gave for it.
    drop? = is_binary(Map.get(answered, :reason))
    # A new QA check says where it is walked; one it keeps keeps the stored setting (`TicketPlan.write/4`).
    opts = [run_id: run_id, idempotency: "plan.written:#{run_id}", new_ask: answer.ask == true, drop_outcomes: drop?, qa_setting: true]

    with :ok <- added_given(answer, messages),
         {:ok, _event} <- TicketPlan.write(repo_key, issue_id, next, opts),
         :ok <- record_asks(answer, repo_key, issue_id, messages, run_id) do
      :ok
    else
      {:refused, why} -> {:error, why}
      {:error, {:invalid_plan, reasons}} -> {:error, "its plan was refused: " <> Enum.join(reasons, "; ")}
      {:error, reason} -> {:error, "its plan could not be recorded: #{inspect(reason)}"}
    end
  end

  defp reason(%{message: %{event: %Event{type: "ask.recorded"} = ask}}), do: "The ask changed: #{field(ask, :from) || "the parent"} asked for something else."
  defp reason(%{junction: @child_junction, message: %{child: child}}), do: "A message on #{child} changed the plan."
  defp reason(%{message: _about}), do: "A message changed what is asked."
  defp reason(%{junction: junction}), do: "The Conductor wrote the plan again at #{junction}."

  # The earlier messages the turn `plan` answers with its newest.
  defp answered(%{junction: @junction, message: %{also: also}}), do: for(%{event: %Event{type: "message.sent"} = event} <- also, do: event)
  defp answered(_plan), do: []

  # Each message the turn answered is what is asked now, word for word, oldest first. Of a Linear
  # description edit, the words the turn says it adds (`added`, `added_given/2`).
  defp record_asks(%{ask: false}, _repo_key, _issue_id, _messages, _run_id), do: :ok

  defp record_asks(answer, repo_key, issue_id, messages, run_id) do
    asked =
      for %Event{id: id} = message <- messages do
        opts = [source: "message", from: id, run_id: run_id, idempotency: "ask.recorded:#{id}"]
        TicketPlan.record_ask(repo_key, issue_id, asked_text(message, Map.get(answer, :added)), opts)
      end

    Enum.find(asked, :ok, &match?({:error, _reason}, &1))
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
    together(plan, message, run_id)
    new_ticket(answer, plan, issue, message, opts)
  end

  def acted(answer, _plan, _issue, _run_id, _opts), do: answer

  # Each earlier message the turn answered gets a reply of its own, which points at the newest's.
  defp together(plan, %Event{id: newest}, run_id) do
    for %Event{id: id} <- answered(plan) do
      payload = %{junction: @junction, text: @together, refs: [newest]}
      record(plan, "conductor.update", payload, run_id: run_id, parent: id, idempotency: "conductor.update:together:#{id}")
    end
  end

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
  The pause an answer in the person's own words to the question `question` held the ticket on
  leaves while the Conductor reads it (`SymphonyElixir.DirectorMoves.answer_held_question/4`): the
  ticket does not dispatch until the turn that reads the words ended (`settle/5`). The Director's
  Unblock releases it too.
  """
  @spec reading_reason(map()) :: map()
  def reading_reason(%{title: title}) do
    text = String.slice("The Conductor is reading your answer: #{title}", 0, 300)
    %{kind: :environment, waits_on: %{condition: @reading_condition}, text: text, releasable: true}
  end

  @doc "Whether `reason` is the pause of an answer the Conductor is reading (`reading_reason/1`)."
  @spec reading_reason?(map()) :: boolean()
  def reading_reason?(%{kind: :environment, waits_on: %{condition: @reading_condition}}), do: true
  def reading_reason?(_reason), do: false

  @doc """
  Ends the pause of the answers the message turn `plan` read (`reading_reason/1`), each a message
  that answers, in the person's own words, a question the ticket was held on (`question_id`), once
  the turn ended with `outcome` and `held` (`:held` when it asked the person, `:moved` when it moved
  the ticket, `:ok` otherwise). So the ticket is never left paused with nothing running and
  nothing asked:

    * a turn that moved the ticket, or asked the person, leaves the move or the question: the
      pause goes;
    * one that said to run the ticket again (`resume`) or steered its next run (`steer`) lifts the
      pause in place, as the Director's Unblock does (`SymphonyElixir.DirectorMoves.run_again/2`);
    * any other answer (it could not tell what the words ask, its move was refused) has each
      question asked again (`ask_again/3`), beside the Conductor's reply.

  A turn that failed leaves the pause: it is tried again, and the third failure asks the question
  again (`unanswered/3`). Nothing for any other turn, nor once the ticket no longer waits on the
  reading (a person moved it or unblocked it meanwhile). Always `:ok`. `opts`: `moves` (the options
  of the Director's moves) and `run_again` (`(identifier, opts) -> result`, default
  `SymphonyElixir.DirectorMoves.run_again/2`).
  """
  @spec settle(map(), term(), atom(), Issue.t(), keyword()) :: :ok
  def settle(%{junction: @junction, message: %{event: %Event{type: "message.sent"}, finished: false}} = plan, {:ok, answer, _tokens}, held, %Issue{} = issue, opts) do
    ids = answered_questions(plan)

    if ids != [] and reading?({:ticket, plan.repo_key, plan.issue_id}) do
      settle_answer(plan, ids, answer, held, issue, opts)
    else
      :ok
    end
  end

  def settle(_plan, _outcome, _held, _issue, _opts), do: :ok

  defp answered_questions(%{message: %{event: message}} = plan) do
    Enum.uniq(for %Event{} = event <- answered(plan) ++ [message], id = field(event, :question_id), is_binary(id), do: id)
  end

  defp settle_answer(plan, _ids, _answer, held, _issue, _opts) when held in [:held, :moved], do: clear_reading({:ticket, plan.repo_key, plan.issue_id})

  defp settle_answer(plan, ids, answer, _held, issue, opts) do
    if Map.get(answer, :resume) == true or Map.get(answer, :steer) != nil,
      do: run_again(plan, ids, issue, opts),
      else: ask_again(plan.repo_key, plan.issue_id, ids)
  end

  defp run_again(plan, ids, issue, opts) do
    run = Keyword.get(opts, :run_again, &DirectorMoves.run_again/2)

    case run.(issue.identifier || plan.issue_id, Keyword.get(opts, :moves, [])) do
      {:ok, _lifted} ->
        :ok

      {:error, reason} ->
        Logger.warning("Conductor could not run the ticket again after an answer issue_id=#{plan.issue_id}: #{inspect(reason)}; its question is asked again")
        ask_again(plan.repo_key, plan.issue_id, ids)
    end
  end

  @doc """
  Asks the questions `ids` of the ticket `issue_id` again: each answer in the person's own words is
  taken back (`SymphonyElixir.Questions.reopen/3`, by Symphony), so the ticket is paused on the
  question again, and then the pause of the answer the Conductor read goes. A question that can't
  be reopened is logged. Nothing once the ticket no longer waits on the Conductor's reading (a move
  or the Director's Unblock came first). Always `:ok`.
  """
  @spec ask_again(String.t(), String.t(), [String.t()]) :: :ok
  def ask_again(repo_key, issue_id, ids) do
    ticket = {:ticket, repo_key, issue_id}

    if reading?(ticket) do
      Enum.each(ids, &reopen(ticket, issue_id, &1))
      clear_reading(ticket)
    else
      :ok
    end
  end

  defp reopen(ticket, issue_id, id) do
    case Questions.reopen(ticket, id, by: @symphony) do
      {:error, reason} -> Logger.warning("Could not ask question #{id} again issue_id=#{issue_id}: #{inspect(reason)}")
      _ok -> :ok
    end
  end

  # Whether the ticket still waits on the Conductor reading an answer: a move or the Director's
  # Unblock in the meantime already decided what the answer leads to.
  defp reading?(ticket) do
    case Pauses.get(ticket) do
      {:ok, %{reasons: reasons}} -> Enum.any?(reasons, &reading_reason?/1)
      _none -> false
    end
  end

  defp clear_reading(ticket) do
    with {:error, reason} <- Pauses.clear_reasons(ticket, &reading_reason?/1, by: @symphony), do: Logger.warning("Could not clear an answer's pause #{inspect(ticket)}: #{inspect(reason)}")

    :ok
  end

  @doc """
  Counts a turn that failed for `why`, in plain words, on what it was to answer (a status note),
  so it stays owed and is tried again. From the third failure on it is owed no more: a
  message gets Symphony's own reply and stays in the ticket's history, and for a parent's new ask
  the note says that the plan stays as it is. Nothing for a turn that owes nothing (`child_message`).
  """
  @spec unanswered(map(), String.t() | nil, String.t()) :: :ok
  def unanswered(%{junction: @junction, message: %{event: %Event{type: type} = event}} = plan, run_id, why) when type in ["message.sent", "ask.recorded"] do
    events = Facts.events(plan.issue_id)
    for %Event{} = owed <- answered(plan) ++ [event], do: count(plan, owed, events, run_id, why)
    :ok
  end

  def unanswered(_plan, _run_id, _why), do: :ok

  defp count(plan, %Event{type: type, id: id} = event, events, run_id, why) do
    try = tries(events, id) + 1
    left? = try < @tries

    cond do
      type == "message.sent" and reply(event) != nil ->
        :ok

      type == "message.sent" and not left? ->
        text =
          "Symphony gave up on this message: the Conductor tried #{@tries} times to answer it, and Symphony could use none of its answers. " <>
            "Nothing was done with it: the plan, the sub-tickets and the runs stay as they were. What went wrong the last time: #{why}. #{given_up(event)}"

        record(plan, "conductor.update", %{junction: @junction, text: Facts.fit(text, Answer.update_max()), refs: []}, run_id: run_id, parent: id, idempotency: "conductor.update:unanswered:#{id}")
        ask_again_answered(plan, event)

      true ->
        record(plan, "note", %{text: Facts.fit(failed(type, why, left?), 4_000), status: true}, run_id: run_id, idempotency: "#{@try_key}#{id}:#{try}")
    end
  end

  defp ask_again_answered(plan, event) do
    case field(event, :question_id) do
      question_id when is_binary(question_id) -> ask_again(plan.repo_key, plan.issue_id, [question_id])
      _none -> :ok
    end
  end

  # What becomes of a message the Conductor gave up on: an answer to a held question has its question asked again.
  defp given_up(event) do
    if is_binary(field(event, :question_id)),
      do: "Its question is asked again: answer it with one of its options, or in other words.",
      else: "It stays in the ticket's history. Send it again to have it read."
  end

  defp failed("message.sent", why, _left?), do: "The Conductor could not answer a message (#{why}). Symphony tries again."
  defp failed("ask.recorded", why, true), do: "The Conductor could not write the plan again for the new ask (#{why}). Symphony tries again."
  defp failed("ask.recorded", why, false), do: "The Conductor could not write the plan again for the new ask (#{why}), #{@tries} times. The plan stays as it is."

  defp record(plan, type, payload, opts) do
    with {:error, reason} <- TicketEvents.record(plan.repo_key, plan.issue_id, type, payload, opts),
         do: Logger.warning("Conductor could not record #{type} issue_id=#{plan.issue_id}: #{inspect(reason)}")

    :ok
  end

  # A Linear description edit holds Symphony's own projection of the ask, the plan and its checks:
  # recorded whole as an ask, the next projection would nest it inside itself. So an answer that
  # changes the ask for one names the words the edit adds (`added`), and one that does not is refused.
  defp added_given(%{ask: true} = answer, messages) do
    if Enum.any?(messages, &(field(&1, :source) == @description_edit)) and not is_binary(Map.get(answer, :added)),
      do: {:refused, "it changed the ask for a Linear description edit without `added`, the person's words the edit adds"},
      else: :ok
  end

  defp added_given(_answer, _messages), do: :ok

  defp asked_text(message, added), do: if(field(message, :source) == @description_edit, do: added, else: field(message, :text))

  defp field(%Event{payload: payload}, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
