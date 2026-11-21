defmodule SymphonyElixir.Conductor.Answer do
  @moduledoc """
  The Conductor's answer (`SymphonyElixir.Conductor`), read from its turn's text and checked against
  its schema: one JSON object with

    * `instructions`: what the next run should focus on, a non-blank string, cut to 3,000 characters;
    * `update`: for the person, markdown in the Conductor's own voice, a string of at most 1,200
      characters, or null (a blank string reads
      as null);
    * `refs`: the ids of the events the update rests on (optional; only ids the facts carry are kept);
    * `ask_person`: null, or a question to the person: `title`, `question`, `why`, `if_unanswered`,
      `recommendation_reason` and two to four `options`, each with a `label`, an `effect`,
      `recommended` and the `action` Symphony takes when it is picked, one of `actions/0`
      (`rework` with its `finding`, cut to 600 characters). A question with an option whose action
      is missing or not one of them is dropped and logged, and the rest of the answer is kept: the
      turn records its message without the question;
    * `steer` (a watch turn's, `SymphonyElixir.Conductor.Watch`): null, or guidance for the running
      run: `message` (at most 1,500 characters) and `when` (`next_turn` or `now`);
    * `blocks` (optional): at most 3 message blocks to pick, each `{"type": ...}` with the facts it
      points at (`steps`, `evidence`, `budget`, `path`, `attempts`, `compare`, `findings`, `epic`;
      `SymphonyElixir.Conductor.Blocks` resolves them); an unknown or malformed entry is dropped, and
      never fails the answer;
    * `stop` (a watch turn's): null, or `{"reason": ...}` to end the running run;
    * `route` (a turn's at `after_qa_blocked`, `route: true`): null, `{"to": "rerun"}` (QA runs
      again on the same change), `{"to": "rework", "finding": ...}` (the ticket goes to Rework with
      the finding: what must change so QA can prove the step, a non-blank string cut to 600
      characters) or a `ticket` route (below). At `after_qa_fail`, `after_rework` and `during_run`
      (`route: :ticket`) only a `ticket` route is read, and any other is ignored; at every other
      junction the field is ignored;
    * a `ticket` route, `{"to": "ticket", "relation": "blocks" | "follow_up", "repo": ..., "title":
      ..., "problem": ..., "wanted": ..., "acceptance": [...], "walkthrough": [...], "evidence":
      [<event id>, ...], "existing": <identifier>}`: a ticket Symphony files for a problem that is
      not the current ticket's to solve (`SymphonyElixir.Conductor.Filing`). It is read as given,
      each text trimmed (a blank or non-string one reads as nil) and the lists kept to their
      non-blank strings; `Filing` refuses one missing a section or naming a repo Symphony does not
      manage, and the turn records its message without it, so a malformed ticket route never
      refuses the answer;
    * `plan` (the Grooming turn's, `plan: true`): the ticket's plan, as `plan.written` holds it
      (`SymphonyElixir.TicketPlan`) but for what Symphony fills in (`version`, `reason`, `by`):
      `shape` (`single` or `split`), `layers` (the names of `layers/0` it gives, each once: a name
      outside it is dropped, `engine` reads as `logic`, its older name, and a missing or empty
      list reads as none, so layers never refuse a plan), `summary` (for a person,
      cut to 600 characters), `text` (for agents, cut to 12,000), `checks` (at least one, at most 30,
      and at least one of kind `outcome`), `size` (`tokens` and `runs`, whole numbers) and, for a
      split, `sub_tickets` (at least one, at most 12). A check holds a `kind` (`outcome`, `qa`, `evidence`), a
      `statement` (cut to 600) and its `proof` (`test`, `qa`, `design`, `attached`); a `qa` check
      also the `action` and what to `expect`, and any check may say the app `state` it needs (each
      cut to 400), the `size` it is walked at (`normal`, `wide`) and a Gallery `story`. A sub-ticket
      holds a `title` (cut to 120) and an `ask` (cut to 4,000), the sibling keys it waits `after`,
      a `repo`, and the `identifier` of a sub-ticket the ticket already has, which is adopted
      instead of created. A check keeps the `id` it gives and is left without one otherwise:
      `SymphonyElixir.TicketPlan.write/4` names the checks. A sub-ticket with no `key` gets
      `s<its place>`. With a question (`ask_person`) the plan is left unread: the person answers
      first. A Grooming answer holds a plan or a question; one with neither is refused, and so is
      a plan that misses this shape. Its `instructions` may be null.

    * `done` and `tree` (a turn's on a ticket with sub-tickets, `tree: true`: `sub_ticket_ended` and
      `final_check`, `SymphonyElixir.Conductor.Tree`): `done` is `true` when the final check found
      the whole ticket done, anything else reads as `false`; `tree` lists at most 10 operations on
      the sub-tickets, each `{"op": ...}` with the `reason` it is made for (required, cut to 1,000
      characters): `add` (a new sub-ticket: `title`, `ask`, the identifiers of the sub-tickets it
      waits `after`, a `repo`), `cancel` (`ticket`, a sub-ticket's identifier), `rewrite`
      (`ticket`, its new `ask`, and `stop: true` to stop its run first) and `stop` (`ticket`). An
      operation that misses its shape is dropped and logged, and never fails the answer. Such a
      turn's `instructions` may be null.

    * a turn's that answers a person's message (`message: true`, the `message` junction): `update`
      is the reply and must be there; `ask` is `true` when the message changes what is asked
      (anything else reads as `false`, and so does `true` beside a question), and then the new
      `plan` must come in the same answer, with the `reason` it changed for (cut to 1,000
      characters); `ask: true` with no plan is refused. `message: :reply` (a finished ticket's) reads the reply
      and no `ask`. `plan: :optional` reads a plan when the
      answer holds one (`child_message`). Its `instructions` may be null;
    * `new_ticket` (`new_ticket: true`, a message on a finished ticket): null, or the ticket to
      create for what the message asks: a `title` (cut to 120), an `ask` (cut to 4,000) and
      optionally a `repo`. One that misses its shape is dropped and logged;
    * `waive` (`waive: true`): the checks of the plan nobody can prove the way the plan says, each
      `{"check_id": ..., "reason": ...}` (the reason cut to 1,000 characters); an entry that misses
      its shape is dropped and logged.

    * `hold` (`hold: true`: at `before_merge`, at `message` and on a watch turn): null, or
      `{"reason": ...}` to hold the ticket's merge, when the pull request is about to merge work
      that is not what is asked now (the plan changed under it, a check is open). The reason, a
      non-blank string cut to 1,000 characters, becomes the next run's instructions, so an answer
      that holds may leave `instructions` null. One that misses its shape is dropped and logged,
      and never fails the answer.

  A text longer than its limit is cut to it at a sentence or word boundary (`Facts.fit/2`) and
  logged, never refused; only an answer that is not readable (not JSON, a wrong type, a blank
  required text) is.

  A watch turn (`watch: true`) may leave `instructions` null. An answer that misses the schema is
  refused with why, in plain words: a malformed `route` too, since it decides a move.
  """

  require Logger

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.ReviewAgent
  alias SymphonyElixir.TicketPlan

  @instructions_max 3_000
  @update_max 1_200
  @finding_max 600
  @steer_max 1_500
  @title_max 120
  @blocks_max 3
  @evidence_max 4
  @compare_text_max 80
  @question_fields ~w(title question why if_unanswered recommendation_reason)
  @actions ~w(continue rerun rework accept_without_qa cancel)
  @ticket_title_max 120
  @ticket_text_max 2_000
  @ticket_items_max 12
  @ticket_item_max 500
  @plan_shapes ~w(single split)
  @plan_layers ~w(screen gallery api logic config tests tooling docs)
  # Names a plan may still give and what each reads as: `engine` was `logic`'s name.
  @older_layers %{"engine" => "logic"}
  @plan_summary_max 600
  @plan_text_max 12_000
  @check_kinds ~w(outcome qa evidence)
  @check_proofs ~w(test qa design attached)
  @check_sizes ~w(normal wide)
  @check_statement_max 600
  @check_walk_max 400
  @sub_ticket_ask_max 4_000
  @id_max 20
  @operations ~w(add cancel rewrite stop)
  @operations_max 10
  @reason_max 1_000
  @waivers_max 20

  @type t :: %{
          instructions: String.t() | nil,
          update: String.t() | nil,
          refs: [String.t()],
          ask_person: map() | nil,
          steer: %{message: String.t(), when: String.t()} | nil,
          stop: %{reason: String.t()} | nil,
          blocks: [map()],
          route: %{to: String.t()} | %{to: String.t(), finding: String.t()} | ticket_route() | nil,
          plan: plan() | nil,
          done: boolean(),
          tree: [operation()],
          ask: boolean(),
          new_ticket: new_ticket() | nil,
          waive: [%{check_id: String.t(), reason: String.t()}],
          hold: %{reason: String.t()} | nil
        }

  @typedoc "The ticket a message on a finished ticket asks for: its title, its ask and, optionally, its repo."
  @type new_ticket :: %{required(:title) => String.t(), required(:ask) => String.t(), optional(:repo) => String.t()}

  @typedoc """
  One operation on a ticket's sub-tickets (see the module doc): its `op`, its `reason`, and what the
  op takes (`title`, `ask`, `after` and `repo`; or `ticket`, and for a `rewrite` its `ask` and `stop`).
  """
  @type operation :: %{required(:op) => String.t(), required(:reason) => String.t(), optional(atom()) => term()}

  @typedoc """
  A plan as the answer gave it (see the module doc), its keys as `plan.written` names them;
  `SymphonyElixir.TicketPlan.write/4` records it.
  """
  @type plan :: %{
          required(:shape) => String.t(),
          required(:layers) => [String.t()],
          required(:summary) => String.t(),
          required(:text) => String.t(),
          required(:checks) => [map()],
          required(:size) => %{tokens: non_neg_integer(), runs: non_neg_integer()},
          optional(:sub_tickets) => [map()],
          optional(:reason) => String.t()
        }

  @typedoc "A `ticket` route as the answer gave it (see the module doc); `SymphonyElixir.Conductor.Filing` checks it."
  @type ticket_route :: %{
          to: String.t(),
          relation: String.t() | nil,
          repo: String.t() | nil,
          title: String.t() | nil,
          problem: String.t() | nil,
          wanted: String.t() | nil,
          acceptance: [String.t()],
          walkthrough: [String.t()],
          evidence: [String.t()],
          existing: String.t() | nil
        }

  @typedoc """
  What picking a question's option makes Symphony do (`SymphonyElixir.Conductor`): `continue` clears
  the pause only, `rerun` runs the stage again, `rework` moves the ticket to Rework with the
  option's finding, `accept_without_qa` records QA's `skip` verdict and moves it to Merging (in QA
  only), `cancel` cancels it.
  """
  @type action :: String.t()

  @doc "The actions a question's option may name, the closed list Symphony acts on."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  The layers a plan may name, the list the Grooming facts offer. A plan's other names are dropped
  (`engine` reads as `logic`), and a plan may name none.
  """
  @spec layers() :: [String.t()]
  def layers, do: @plan_layers

  @doc "The most characters `instructions` may hold."
  @spec instructions_max() :: pos_integer()
  def instructions_max, do: @instructions_max

  @doc "The most characters `update` may hold."
  @spec update_max() :: pos_integer()
  def update_max, do: @update_max

  @doc """
  The answer among `texts` (the turn's text candidates, most specific first): the first JSON object
  in them that meets the schema, else the first refusal.
  """
  @spec read([String.t()], keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(texts, opts \\ []) when is_list(texts) do
    texts
    |> Enum.flat_map(&ReviewAgent.json_object_candidates/1)
    |> Enum.reduce_while({:error, "the answer holds no JSON object"}, fn candidate, error ->
      case parse(candidate, opts) do
        {:ok, answer} -> {:halt, {:ok, answer}}
        {:error, _reason} = refused -> {:cont, first_error(error, refused)}
      end
    end)
  end

  defp first_error({:error, "the answer holds no JSON object"}, refused), do: refused
  defp first_error(error, _refused), do: error

  @doc """
  Checks one JSON object's text against the schema; `watch: true` for a watch turn's, `route: true`
  for a turn's at `after_qa_blocked`, whose every route is read, `route: :ticket` for a turn's
  at a junction whose `ticket` route only is read, `plan: true` for the Grooming turn's, whose
  `plan` is read, and `tree: true` for a turn's on a ticket with sub-tickets, whose `done` and
  `tree` are read; `message: true` for a turn's that answers a person's message, `plan: :optional`,
  `new_ticket: true`, `waive: true` and `hold: true` as the module doc says.
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    message = Keyword.get(opts, :message, false)
    plan_opt = Keyword.get(opts, :plan, false)

    with {:ok, %{} = answer} <- decode(text),
         {:ok, instructions} <- instructions(Map.get(answer, "instructions"), nullable?(opts) or holds?(answer, opts)),
         {:ok, update} <- update(Map.get(answer, "update"), message != false),
         {:ok, refs} <- refs(Map.get(answer, "refs")),
         {:ok, ask_person} <- ask_person(Map.get(answer, "ask_person")),
         {:ok, steer} <- steer(Map.get(answer, "steer")),
         {:ok, stop} <- stop(Map.get(answer, "stop")),
         {:ok, route} <- route(Map.get(answer, "route"), Keyword.get(opts, :route, false)),
         asks? = message == true and Map.get(answer, "ask") == true and is_nil(ask_person),
         {:ok, plan} <- plan(Map.get(answer, "plan"), plan_read(plan_opt, asks?, answer), ask_person) do
      read = %{instructions: instructions, update: update, refs: refs, ask_person: ask_person, steer: steer, stop: stop, blocks: blocks(Map.get(answer, "blocks"))}
      {:ok, read |> Map.merge(%{route: route, plan: plan, ask: asks?}) |> Map.merge(extras(answer, opts))}
    end
  end

  # A turn whose answer is about something else than the next run may leave `instructions` null.
  defp nullable?(opts), do: Enum.any?([:plan, :tree, :message, :watch], &(Keyword.get(opts, &1, false) != false))

  # A hold's reason is the next run's instructions, so an answer that holds may leave them null.
  defp holds?(answer, opts), do: Keyword.get(opts, :hold, false) and is_map(Map.get(answer, "hold"))

  # What only some turns' answers are read for: the tree, a new ticket, the waivers, the hold.
  defp extras(answer, opts) do
    tree? = Keyword.get(opts, :tree, false)

    %{
      done: tree? and Map.get(answer, "done") == true,
      tree: if(tree?, do: operations(Map.get(answer, "tree")), else: []),
      new_ticket: if(Keyword.get(opts, :new_ticket, false), do: new_ticket(Map.get(answer, "new_ticket"))),
      waive: if(Keyword.get(opts, :waive, false), do: waivers(Map.get(answer, "waive")), else: []),
      hold: if(Keyword.get(opts, :hold, false), do: hold(Map.get(answer, "hold")))
    }
  end

  # The merge the turn holds, with why; one that misses its shape is dropped.
  defp hold(nil), do: nil

  defp hold(%{} = hold) do
    case optional_text(hold, "reason", @reason_max, "hold") do
      reason when is_binary(reason) -> %{reason: reason}
      _blank -> dropped_hold()
    end
  end

  defp hold(_hold), do: dropped_hold()

  defp dropped_hold do
    Logger.warning("Conductor answer's `hold` was dropped: it needs a `reason`")
    nil
  end

  # How the plan is read: the Grooming turn's must be there (`true`), a message that changes the ask
  # must bring one (`:ask`), and where one is optional it is read when the answer holds one.
  defp plan_read(true, _asks?, _answer), do: true
  defp plan_read(_opt, true, _answer), do: :ask
  defp plan_read(:optional, _asks?, %{"plan" => %{}}), do: true
  defp plan_read(_opt, _asks?, _answer), do: false

  # The ticket a message on a finished ticket asks for; one that misses its shape is dropped.
  defp new_ticket(nil), do: nil

  defp new_ticket(%{} = ticket) do
    with title when is_binary(title) <- optional_text(ticket, "title", @ticket_title_max, "new_ticket"),
         ask when is_binary(ask) <- optional_text(ticket, "ask", @sub_ticket_ask_max, "new_ticket") do
      put_text(%{title: title, ask: ask}, :repo, ticket, 200, "new_ticket")
    else
      _malformed -> dropped_new_ticket()
    end
  end

  defp new_ticket(_ticket), do: dropped_new_ticket()

  defp dropped_new_ticket do
    Logger.warning("Conductor answer's `new_ticket` was dropped: it needs a `title` and an `ask`")
    nil
  end

  # The waivers that are well formed, one per check; the rest are dropped one by one and logged.
  defp waivers(waivers) when is_list(waivers) do
    waivers
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {waiver, place} -> waiver |> waiver("waive[#{place}]") |> kept("waive[#{place}]") end)
    |> Enum.uniq_by(& &1.check_id)
    |> Enum.take(@waivers_max)
  end

  defp waivers(_waivers), do: []

  defp waiver(%{} = waiver, where) do
    with check_id when is_binary(check_id) <- optional_text(waiver, "check_id", @id_max, where),
         reason when is_binary(reason) <- optional_text(waiver, "reason", @reason_max, where) do
      %{check_id: check_id, reason: reason}
    end
  end

  defp waiver(_waiver, _where), do: nil

  # The operations that are well formed, the first ten; the rest are dropped one by one and logged.
  defp operations(operations) when is_list(operations) do
    operations
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {operation, place} -> operation |> operation("tree[#{place}]") |> kept("tree[#{place}]") end)
    |> Enum.take(@operations_max)
  end

  defp operations(_operations), do: []

  defp kept(nil, where) do
    Logger.warning("Conductor answer's `#{where}` was dropped: it misses its shape or its reason")
    []
  end

  defp kept(operation, _where), do: [operation]

  defp operation(%{"op" => op} = operation, where) when op in @operations do
    with reason when is_binary(reason) <- optional_text(operation, "reason", @reason_max, where),
         %{} = read <- operation(op, operation, where) do
      Map.merge(read, %{op: op, reason: reason})
    else
      _malformed -> nil
    end
  end

  defp operation(_operation, _where), do: nil

  defp operation("add", operation, where) do
    with title when is_binary(title) <- optional_text(operation, "title", @ticket_title_max, where),
         ask when is_binary(ask) <- optional_text(operation, "ask", @sub_ticket_ask_max, where) do
      waits = for id <- List.wrap(Map.get(operation, "after")), is_binary(id), String.trim(id) != "", uniq: true, do: String.trim(id)
      put_text(%{title: title, ask: ask, after: waits}, :repo, operation, 200, where)
    end
  end

  defp operation("rewrite", operation, where) do
    with ticket when is_binary(ticket) <- optional_text(operation, "ticket", 50, where),
         ask when is_binary(ask) <- optional_text(operation, "ask", @sub_ticket_ask_max, where) do
      %{ticket: ticket, ask: ask, stop: Map.get(operation, "stop") == true}
    end
  end

  defp operation(_cancel_or_stop, operation, where) do
    with ticket when is_binary(ticket) <- optional_text(operation, "ticket", 50, where), do: %{ticket: ticket}
  end

  # Read only for the Grooming turn, and only when it asked nothing: a question leaves the plan to
  # the turn that reads the person's answer.
  defp plan(_plan, false = _read?, _ask_person), do: {:ok, nil}
  defp plan(_plan, true, %{} = _ask_person), do: {:ok, nil}
  defp plan(nil, true, nil), do: {:error, "the answer holds neither a `plan` nor a question (`ask_person`)"}
  defp plan(plan, :ask, nil) when not is_map(plan), do: {:error, "`ask` is true, so the answer must hold the new `plan`"}

  defp plan(%{} = plan, _read, nil) do
    with {:ok, shape} <- one_of(plan, "shape", @plan_shapes, "plan"),
         layers = plan_layers(Map.get(plan, "layers")),
         {:ok, summary} <- required_text(plan, "summary", @plan_summary_max, "plan"),
         {:ok, text} <- required_text(plan, "text", @plan_text_max, "plan"),
         {:ok, checks} <- entries(Map.get(plan, "checks"), "plan.checks", TicketPlan.max_checks(), &check/2),
         :ok <- with_outcome(checks),
         {:ok, size} <- plan_size(Map.get(plan, "size")),
         {:ok, sub_tickets} <- sub_tickets(Map.get(plan, "sub_tickets"), shape) do
      read = %{shape: shape, layers: layers, summary: summary, text: text, checks: checks, size: size}
      plan = put_text(read, :reason, plan, @reason_max, "plan")
      {:ok, if(sub_tickets, do: Map.put(plan, :sub_tickets, sub_tickets), else: plan)}
    end
  end

  defp plan(_plan, true, nil), do: {:error, "`plan` must be an object"}

  # Layers only add QA to work a person sees, so they never refuse a plan: unknown names are dropped.
  defp plan_layers(layers) when is_list(layers) do
    layers |> Enum.map(&Map.get(@older_layers, &1, &1)) |> Enum.filter(&(&1 in @plan_layers)) |> Enum.uniq()
  end

  defp plan_layers(_layers), do: []

  defp with_outcome(checks) do
    if Enum.any?(checks, &(&1.kind == "outcome")), do: :ok, else: {:error, "`plan.checks` holds no check of kind `outcome`"}
  end

  defp plan_size(%{"tokens" => tokens, "runs" => runs}) when is_integer(tokens) and tokens >= 0 and is_integer(runs) and runs >= 0,
    do: {:ok, %{tokens: tokens, runs: runs}}

  defp plan_size(_size), do: {:error, "`plan.size` must hold `tokens` and `runs`, both whole numbers"}

  defp check(%{} = check, place) do
    where = "plan.checks[#{place}]"

    with {:ok, kind} <- one_of(check, "kind", @check_kinds, where),
         {:ok, statement} <- required_text(check, "statement", @check_statement_max, where),
         {:ok, proof} <- one_of(check, "proof", @check_proofs, where),
         :ok <- walkable(check, kind, where) do
      %{kind: kind, statement: statement, proof: proof}
      |> put_text(:id, check, @id_max, where)
      |> put_text(:state, check, @check_walk_max, where)
      |> put_text(:action, check, @check_walk_max, where)
      |> put_text(:expect, check, @check_walk_max, where)
      |> put_text(:story, check, 200, where)
      |> put_present(:size, if(Map.get(check, "size") in @check_sizes, do: Map.get(check, "size")))
      |> then(&{:ok, &1})
    end
  end

  defp check(_check, place), do: {:error, "`plan.checks[#{place}]` must be an object"}

  # A QA check is walked: it says what to do and what to expect.
  defp walkable(check, "qa", where) do
    case Enum.find(["action", "expect"], &is_nil(optional_text(check, &1, @check_walk_max, where))) do
      nil -> :ok
      field -> {:error, "`#{where}.#{field}` must be a non-blank string: a `qa` check says what to do and what to expect"}
    end
  end

  defp walkable(_check, _kind, _where), do: :ok

  defp sub_tickets(_entries, "single"), do: {:ok, nil}
  defp sub_tickets(entries, "split"), do: entries(entries, "plan.sub_tickets", TicketPlan.max_sub_tickets(), &sub_ticket/2)

  defp sub_ticket(%{} = entry, place) do
    where = "plan.sub_tickets[#{place}]"

    with {:ok, title} <- required_text(entry, "title", @ticket_title_max, where),
         {:ok, ask} <- required_text(entry, "ask", @sub_ticket_ask_max, where) do
      waits = for key <- List.wrap(Map.get(entry, "after")), is_binary(key), String.trim(key) != "", uniq: true, do: String.trim(key)

      %{key: key(entry, place), title: title, ask: ask, after: waits}
      |> put_text(:repo, entry, 200, where)
      |> put_text(:identifier, entry, 50, where)
      |> then(&{:ok, &1})
    end
  end

  defp sub_ticket(_entry, place), do: {:error, "`plan.sub_tickets[#{place}]` must be an object"}

  # A list of 1 to `max` entries whose every entry reads (`read.(entry, its place)`), else the first refusal.
  defp entries([_ | _] = entries, where, max, _read) when length(entries) > max,
    do: {:error, "`#{where}` lists #{length(entries)} entries, and a plan holds at most #{max}"}

  defp entries([_ | _] = entries, _where, _max, read) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, place}, {:ok, acc} ->
      case read.(entry, place) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, _why} = refused -> {:halt, refused}
      end
    end)
  end

  defp entries(_entries, where, _max, _read), do: {:error, "`#{where}` must list at least one entry"}

  # The key the sub-ticket entry gives, else its place's (`s2`).
  defp key(entry, place) do
    case Map.get(entry, "key") do
      key when is_binary(key) -> if String.trim(key) == "", do: "s#{place}", else: key |> String.trim() |> String.slice(0, @id_max)
      _missing -> "s#{place}"
    end
  end

  defp one_of(map, field, allowed, where) do
    value = Map.get(map, field)
    if value in allowed, do: {:ok, value}, else: {:error, "`#{where}.#{field}` must be one of #{Enum.join(allowed, ", ")}"}
  end

  defp required_text(map, field, max, where) do
    case optional_text(map, field, max, where) do
      nil -> {:error, "`#{where}.#{field}` must be a non-blank string"}
      text -> {:ok, text}
    end
  end

  defp optional_text(map, field, max, where) do
    case Map.get(map, field) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: fit(String.trim(text), max, "#{where}.#{field}")
      _missing -> nil
    end
  end

  defp put_text(entry, key, source, max, where), do: put_present(entry, key, optional_text(source, Atom.to_string(key), max, where))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, _other} -> {:error, "the answer is not a JSON object"}
      {:error, _reason} -> {:error, "the answer is not valid JSON"}
    end
  end

  defp instructions(nil, true = _watch?), do: {:ok, nil}

  defp instructions(text, _watch?) when is_binary(text) do
    text = String.trim(text)

    if text == "", do: {:error, "`instructions` is blank"}, else: {:ok, fit(text, @instructions_max, "instructions")}
  end

  defp instructions(_text, _watch?), do: {:error, "`instructions` must be a string"}

  defp steer(nil), do: {:ok, nil}

  defp steer(%{"message" => message, "when" => moment}) when is_binary(message) and moment in ["next_turn", "now"] do
    message = String.trim(message)

    if message == "", do: {:error, "`steer.message` is blank"}, else: {:ok, %{message: fit(message, @steer_max, "steer.message"), when: moment}}
  end

  defp steer(_steer), do: {:error, "`steer` must be null or hold a `message` and `when` (`next_turn` or `now`)"}

  defp stop(nil), do: {:ok, nil}
  defp stop(%{"reason" => reason}) when is_binary(reason) and reason != "", do: {:ok, %{reason: String.trim(reason)}}
  defp stop(_stop), do: {:error, "`stop` must be null or hold a `reason`"}

  # Read only where Symphony takes a route; anywhere else the field is ignored. Where only a ticket
  # route is taken, any other route is ignored too.
  defp route(_route, false = _read?), do: {:ok, nil}
  defp route(nil, _read), do: {:ok, nil}
  defp route(%{"to" => "ticket"} = route, _read), do: {:ok, ticket_route(route)}
  defp route(_route, :ticket), do: {:ok, nil}
  defp route(%{"to" => "rerun"} = route, true) when map_size(route) == 1, do: {:ok, %{to: "rerun"}}

  defp route(%{"to" => "rework", "finding" => finding} = route, true) when is_binary(finding) and map_size(route) == 2 do
    finding = String.trim(finding)

    if finding == "",
      do: {:error, "`route.finding` is blank"},
      else: {:ok, %{to: "rework", finding: fit(finding, @finding_max, "route.finding")}}
  end

  defp route(_route, true),
    do: {:error, "`route` must be null, `{\"to\": \"rerun\"}`, `{\"to\": \"rework\", \"finding\": ...}` or `{\"to\": \"ticket\", ...}`"}

  # Read as given: `Filing` names what a ticket route misses, so the turn's message is still kept.
  defp ticket_route(route) do
    %{
      to: "ticket",
      relation: ticket_text(route, "relation", 40),
      repo: ticket_text(route, "repo", 200),
      title: ticket_text(route, "title", @ticket_title_max),
      problem: ticket_text(route, "problem", @ticket_text_max),
      wanted: ticket_text(route, "wanted", @ticket_text_max),
      acceptance: ticket_items(route, "acceptance", @ticket_item_max),
      walkthrough: ticket_items(route, "walkthrough", @ticket_item_max),
      evidence: ticket_items(route, "evidence", 200),
      existing: ticket_text(route, "existing", 40)
    }
  end

  defp ticket_text(route, field, max) do
    case Map.get(route, field) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: fit(String.trim(text), max, "route.#{field}")
      _missing -> nil
    end
  end

  defp ticket_items(route, field, max) do
    case Map.get(route, field) do
      items when is_list(items) ->
        items
        |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
        |> Enum.map(&fit(String.trim(&1), max, "route.#{field}"))
        |> Enum.uniq()
        |> Enum.take(@ticket_items_max)

      _missing ->
        []
    end
  end

  # A reply to a person's message must be there.
  defp update(text, true = _required?) do
    case update(text) do
      {:ok, nil} -> {:error, "`update` must hold the reply to the person's message"}
      read -> read
    end
  end

  defp update(text, false), do: update(text)

  defp update(nil), do: {:ok, nil}

  defp update(text) when is_binary(text) do
    text = String.trim(text)

    if text == "", do: {:ok, nil}, else: {:ok, fit(text, @update_max, "update")}
  end

  defp update(_text), do: {:error, "`update` must be a string or null"}

  # The picks that are well formed, the first three; the rest are dropped one by one.
  defp blocks(picks) when is_list(picks), do: picks |> Enum.flat_map(&block/1) |> Enum.take(@blocks_max)
  defp blocks(_picks), do: []

  defp block(%{"type" => type} = pick) when type in ["budget", "path", "findings", "epic"],
    do: if(map_size(pick) == 1, do: [%{type: type}], else: [])

  defp block(%{"type" => "steps"} = pick), do: with_run(pick, "steps", [])

  defp block(%{"type" => "attempts", "step_id" => step_id} = pick) when is_binary(step_id) and step_id != "",
    do: with_run(Map.delete(pick, "step_id"), "attempts", step_id: step_id)

  defp block(%{"type" => "evidence", "refs" => refs} = pick) when is_list(refs) and refs != [] and map_size(pick) == 2 do
    if length(refs) <= @evidence_max and Enum.all?(refs, &id?/1), do: [%{type: "evidence", refs: Enum.uniq(refs)}], else: []
  end

  defp block(%{"type" => "compare", "expected" => expected, "actual" => actual} = pick) when map_size(pick) == 3 do
    with {:ok, expected} <- side(expected),
         {:ok, actual} <- side(actual) do
      [%{type: "compare", expected: expected, actual: actual}]
    else
      :error -> []
    end
  end

  defp block(_pick), do: []

  # `steps` and `attempts` take an optional `run_id`, and nothing else.
  defp with_run(pick, type, fields) do
    case Map.delete(pick, "type") do
      empty when map_size(empty) == 0 -> [Map.merge(%{type: type}, Map.new(fields))]
      %{"run_id" => run_id} = only when map_size(only) == 1 -> if id?(run_id), do: [Map.merge(%{type: type, run_id: run_id}, Map.new(fields))], else: []
      _extra -> []
    end
  end

  defp side(%{"text" => text} = side) when is_binary(text) and map_size(side) == 1 do
    text = String.trim(text)
    if text != "" and String.length(text) <= @compare_text_max, do: {:ok, %{text: text}}, else: :error
  end

  defp side(%{"ref" => ref} = side) when map_size(side) == 1, do: if(id?(ref), do: {:ok, %{ref: ref}}, else: :error)
  defp side(_side), do: :error

  defp id?(value), do: is_binary(value) and value != ""

  defp refs(nil), do: {:ok, []}

  defp refs(refs) when is_list(refs) do
    if Enum.all?(refs, &is_binary/1), do: {:ok, Enum.uniq(refs)}, else: {:error, "`refs` must list event ids"}
  end

  defp refs(_refs), do: {:error, "`refs` must list event ids"}

  defp ask_person(nil), do: {:ok, nil}

  defp ask_person(%{} = ask) do
    with {:ok, fields} <- question_fields(ask),
         {:ok, options} <- options(Map.get(ask, "options")) do
      case actioned(options, Map.get(ask, "options")) do
        {:ok, options} ->
          {:ok, Map.put(fields, :options, options)}

        {:error, why} ->
          Logger.warning("Conductor answer's question #{inspect(fields.title)} was dropped: #{why}")
          {:ok, nil}
      end
    end
  end

  defp ask_person(_ask), do: {:error, "`ask_person` must be an object or null"}

  defp question_fields(ask) do
    Enum.reduce_while(@question_fields, {:ok, %{}}, fn field, {:ok, fields} ->
      case Map.get(ask, field) do
        value when is_binary(value) and value != "" -> {:cont, {:ok, Map.put(fields, String.to_existing_atom(field), question_text(field, value))}}
        _missing -> {:halt, {:error, "`ask_person.#{field}` must be a non-blank string"}}
      end
    end)
  end

  defp question_text("title", value), do: fit(value, @title_max, "ask_person.title")
  defp question_text(_field, value), do: value

  # A text over its limit is cut, not refused: the answer is still worth recording.
  defp fit(text, max, field) do
    fitted = Facts.fit(text, max)
    if fitted != text, do: Logger.warning("Conductor answer's `#{field}` was #{String.length(text)} characters; cut to #{max}")
    fitted
  end

  defp options(options) when is_list(options) and length(options) in 2..4 do
    Enum.reduce_while(options, {:ok, []}, fn
      %{"label" => label, "effect" => effect} = option, {:ok, acc} when is_binary(label) and is_binary(effect) ->
        {:cont, {:ok, acc ++ [%{label: label, effect: effect, recommended: Map.get(option, "recommended") == true}]}}

      _option, _acc ->
        {:halt, {:error, "each of `ask_person.options` needs a `label` and an `effect`"}}
    end)
  end

  defp options(_options), do: {:error, "`ask_person.options` must list two to four options"}

  # Each option's action, from the closed list Symphony acts on; one it can't act on drops the question.
  defp actioned(options, raw) do
    Enum.zip(options, raw)
    |> Enum.reduce_while({:ok, []}, fn {option, raw_option}, {:ok, acc} ->
      case action(Map.get(raw_option, "action"), Map.get(raw_option, "finding")) do
        {:ok, action} -> {:cont, {:ok, acc ++ [Map.merge(option, action)]}}
        {:error, why} -> {:halt, {:error, "option #{inspect(option.label)} #{why}"}}
      end
    end)
  end

  defp action("rework", finding) when is_binary(finding) do
    case String.trim(finding) do
      "" -> {:error, "sends the ticket to Rework with a blank `finding`"}
      finding -> {:ok, %{action: "rework", finding: fit(finding, @finding_max, "ask_person.options.finding")}}
    end
  end

  defp action("rework", _finding), do: {:error, "sends the ticket to Rework without a `finding`"}
  defp action(action, _finding) when action in @actions, do: {:ok, %{action: action}}
  defp action(action, _finding), do: {:error, "names the action #{inspect(action)}, not one of #{Enum.join(@actions, ", ")}"}
end
