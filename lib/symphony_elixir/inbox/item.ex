defmodule SymphonyElixir.Inbox.Item do
  @moduledoc """
  One thing that waits on the Director, as the Inbox lists it (`SymphonyElixir.Inbox`).

  `kind` says what waits:

  - `:action`: an open `linear_request_human_action` request (`SymphonyElixir.HumanActions.Request`),
    whatever else the ticket is; its review is the request: why, what waits until it is answered,
    the steps or the options (each with its trade-offs), why the recommended one, what it unblocks;
  - `:plan`: a plan parent (label `plan` or `breakdown`) in `Plan Review` whose plan waits for
    approval, with its sub-tickets in landing order and its open choices: the requests the plan run
    raised (`SymphonyElixir.DecisionRequest`), each shown as an `:action`'s request is, oldest
    first;
  - `:clarify`: a ticket the quality gate holds for clarification or skipped, with its score, its
    round and what the gate found;
  - `:blocked`: a ticket an access or dispatch-loop hold pauses in place (`SymphonyElixir.Hold`),
    with the reason the hold recorded and what clears it; the Director lifts it with `Unblock`.

  A plan carries its `## Review brief` comment parsed (`SymphonyElixir.Inbox.ReviewBrief`) as
  `review.brief`, nil when it has none. Its questions are never read from the brief: the brief
  links to the requests, and `review.decisions` lists them. `review.unapplied_answers` counts the
  answers given since the plan last came back to `Plan Review`, which no revision has applied yet:
  the Inbox warns before such a plan is approved.

  `from_question/2`, `from_plan_brief/2` and `from_pause/2` build the items from the ticket's record
  (`SymphonyElixir.TicketState`): an open Question (`SymphonyElixir.Questions`), the plan's brief
  captured as it entered `Plan Review` (`SymphonyElixir.PlanBrief`, which reads it with
  `plan_from_node/2`) and a pause with a reason the Director may release
  (`SymphonyElixir.Pauses`). `SymphonyElixir.Inbox.FromRecord` lists them; nothing here reads a
  Linear comment for an answer.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{DecisionRequest, PlanBrief, TicketState}
  alias SymphonyElixir.HumanActions.{Collector, Waiting}
  alias SymphonyElixir.Inbox.ReviewBrief
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.PlanReview

  @type kind :: :action | :plan | :clarify | :blocked
  @type t :: %{
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:repo_key) => String.t() | nil,
          required(:kind) => kind(),
          required(:state) => String.t() | nil,
          required(:ask) => String.t(),
          required(:waiting_since) => DateTime.t() | nil,
          required(:url) => String.t() | nil,
          required(:review) => map()
        }

  @option_pattern ~r/^\*\*(.+?)\*\*(\s*\(recommended\))?\s*[:—-]?\s*(.*)$/i

  @doc """
  What the Inbox shows of a plan, read from its Linear issue node (the fields
  `SymphonyElixir.PlanBrief` reads), or nil when the node is no plan (label `plan` or `breakdown`) in
  `settings`' `Plan Review`: its latest `## Review brief` comment parsed, its sub-tickets in landing
  order and its open choices, each the request the plan run raised with the id of its Question.
  """
  @spec plan_from_node(map(), Schema.t()) :: %{brief: map() | nil, sub_tickets: [map()], decisions: [map()]} | nil
  def plan_from_node(node, settings) do
    labels = node |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"])

    if PlanReview.in_state?(get_in(node, ["state", "name"]), settings) and Enum.any?(labels, &Issue.breakdown_label?/1),
      do: %{brief: brief(node), sub_tickets: sub_tickets(node), decisions: plan_decisions(node, settings)}
  end

  # A request as the Inbox shows it, an action's or a plan's: what it asks, why, what waits until it
  # is answered, the options with their trade-offs and why the recommended one. `comment_id` is what
  # the answer replies under, and `question_id` the Question its hidden line names (nil for a request
  # written before questions carried it), which the Director's answer answers.
  defp request_review(node, comment_id, request) do
    %{
      comment_id: comment_id,
      question_id: question_id(node, comment_id),
      title: request.title,
      question: request.question,
      why: request.why,
      if_unanswered: request.if_unanswered,
      unblocks: request.unblocks,
      steps: request.steps,
      options: request.options |> Enum.zip(request.tradeoffs) |> Enum.map(fn {text, tradeoffs} -> Map.put(option(text), :tradeoffs, tradeoffs) end),
      recommendation_reason: request.recommendation_reason
    }
  end

  # A plan's open choices are requests like any other, raised through the writer: each one with
  # options, oldest first, in the order the plan raised them. A hand-written request with only steps
  # is no choice to answer.
  defp plan_decisions(node, settings) do
    node
    |> Collector.open_requests(settings)
    |> Enum.filter(fn {_comment_id, request} -> request.options != [] end)
    |> Enum.sort_by(&posted_at/1)
    |> Enum.map(fn {comment_id, request} -> request_review(node, comment_id, request) end)
  end

  defp posted_at({_comment_id, %{created_at: %DateTime{} = at}}), do: DateTime.to_unix(at, :microsecond)
  defp posted_at(_request), do: 0

  @doc "A rendered request option (`**Label** (recommended): effect`) as its label, effect and whether it is recommended."
  @spec option(String.t()) :: %{label: String.t(), effect: String.t() | nil, recommended: boolean()}
  def option(text) do
    case Regex.run(@option_pattern, String.trim(text)) do
      [_, label, recommended, effect] -> %{label: String.trim(label), effect: blank_to_nil(effect), recommended: recommended != ""}
      nil -> %{label: String.trim(text), effect: nil, recommended: false}
    end
  end

  defp brief(node) do
    node
    |> comments()
    |> Enum.filter(&ReviewBrief.brief?(&1["body"]))
    |> Enum.max_by(&(&1["createdAt"] || ""), fn -> nil end)
    |> case do
      %{"body" => body} -> ReviewBrief.parse(body)
      nil -> nil
    end
  end

  # Plans file their sub-tickets in landing order.
  defp sub_tickets(node) do
    node
    |> get_in(["children", "nodes"])
    |> List.wrap()
    |> Enum.sort_by(&(&1["createdAt"] || ""))
    |> Enum.map(fn child ->
      %{identifier: child["identifier"], title: child["title"], url: child["url"], state: get_in(child, ["state", "name"])}
    end)
  end

  @doc """
  The `:action` item of `question`, an open Question on `record` (a normalized
  `SymphonyElixir.TicketState`): what it asks, as its request comment shows it. It has
  waited since the later of the move into the record's phase and when it was asked; `comment_id` is
  the request comment the pause projector wrote or found for it, nil while none.
  """
  @spec from_question(TicketState.t(), map()) :: t()
  def from_question(record, question) do
    record
    |> record_item(:action, question.title, latest([record.phase_at, question.asked_at]))
    |> Map.put(:review, Map.merge(question_review(record, question), %{requested_at: question.asked_at, confirm: MergeConfirmation.confirm_target(%{decision: %{confirm: question.confirm}})}))
  end

  @doc """
  The `:plan` item of `record` (a normalized `SymphonyElixir.TicketState`), or nil when it is no plan
  (label `plan` or `breakdown`) in `settings`' `Plan Review` with a captured brief
  (`SymphonyElixir.PlanBrief`). Its choices are the record's open Questions with options, oldest
  first, then the captured choices whose Question the record does not hold; its unapplied answers
  are the record's answers given since the plan entered its phase.
  """
  @spec from_plan_brief(TicketState.t(), Schema.t()) :: t() | nil
  def from_plan_brief(record, settings) do
    with true <- PlanReview.in_state?(record.phase, settings),
         true <- Enum.any?(record.labels, &Issue.breakdown_label?/1),
         %{} = plan <- PlanBrief.from_record(record) do
      open = Enum.filter(record.questions, &(&1.state == :open))

      record
      |> record_item(:plan, brief_headline(plan.brief) || "Approve the plan", latest([record.phase_at | Enum.map(open, & &1.asked_at)]))
      |> Map.put(:review, %{
        brief: plan.brief,
        sub_tickets: plan.sub_tickets,
        decisions: plan_choices(record, open, plan.choices),
        unapplied_answers: Enum.count(record.questions, &answered_since?(&1, record.phase_at))
      })
    else
      _not_a_plan -> nil
    end
  end

  @doc """
  The `:blocked` item of `pause`, the pause on `record` (a normalized `SymphonyElixir.TicketState`),
  from its first reason the Director may release, or nil when it has none: the reason's line and
  since when, and what clears it as the record's Blocked hold says.
  """
  @spec from_pause(TicketState.t(), map() | nil) :: t() | nil
  def from_pause(record, %{reasons: reasons}) do
    case Enum.find(reasons, & &1.releasable) do
      %{} = reason ->
        hold = TicketState.get_hold(record, :blocked)

        record
        |> record_item(:blocked, reason.text, reason.set_at)
        |> Map.put(:review, %{reason: reason.text, clearing_condition: hold && hold.clearing_condition})

      nil ->
        nil
    end
  end

  def from_pause(_record, _pause), do: nil

  defp record_item(record, kind, ask, waiting_since) do
    %{
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      title: record.title,
      repo_key: record.repo_key,
      kind: kind,
      state: record.phase,
      ask: ask,
      waiting_since: waiting_since,
      url: record.url,
      review: %{}
    }
  end

  # A Question as `request_review/3` shows a request.
  defp question_review(record, question) do
    %{
      comment_id: projected_comment(record, question.id),
      question_id: question.id,
      title: question.title,
      question: question.question,
      why: question.why,
      if_unanswered: question.if_unanswered,
      unblocks: question.unblocks,
      steps: [],
      options: Enum.map(question.options, &question_option/1),
      recommendation_reason: question.recommendation_reason
    }
  end

  defp question_option(option) do
    tradeoffs = for {kind, key} <- [{"good", :good}, {"cost", :cost}, {"risk", :risk}], text <- Map.get(option, key, []), do: %{kind: kind, text: text}
    %{label: option.label, effect: blank_to_nil(option.effect), recommended: option.recommended?, tradeoffs: tradeoffs}
  end

  defp projected_comment(%{projected: %{comments: %{} = comments}}, question_id), do: get_in(comments, [question_id, :comment])
  defp projected_comment(_record, _question_id), do: nil

  # A captured choice the record holds the Question of is shown as that Question while it is open,
  # and not at all once it ended; one whose Question the record does not hold is shown as captured.
  defp plan_choices(record, open, choices) do
    held = MapSet.new(record.questions, & &1.id)

    open
    |> Enum.filter(&(&1.options != []))
    |> Enum.sort_by(&DateTime.to_unix(&1.asked_at, :microsecond))
    |> Enum.map(&question_review(record, &1))
    |> Enum.concat(Enum.reject(choices, &MapSet.member?(held, Map.get(&1, :question_id))))
  end

  defp answered_since?(%{state: :answered, answer: %{at: %DateTime{} = at}}, %DateTime{} = since), do: DateTime.compare(at, since) == :gt
  defp answered_since?(_question, _since), do: false

  defp brief_headline(%{format: "parsed", headline: headline, what_to_review: items}) do
    [headline | Enum.map(items, & &1.text)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> nil
      text -> Waiting.brief_headline("**What to review:** " <> text)
    end
  end

  defp brief_headline(%{markdown: markdown}), do: Waiting.brief_headline(markdown)
  defp brief_headline(_brief), do: nil

  defp latest(times), do: times |> Enum.filter(&match?(%DateTime{}, &1)) |> Enum.max(DateTime, fn -> nil end)

  @doc "The Inbox item of a quality-gate hold (`kind: :clarification`) or skip, from the orchestrator snapshot."
  @spec from_quality_gate(map()) :: t()
  def from_quality_gate(entry) do
    held? = Map.get(entry, :kind) == :clarification

    %{
      issue_id: entry.issue_id,
      identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      repo_key: Map.get(entry, :repo_key),
      kind: :clarify,
      state: Map.get(entry, :state),
      ask: clarify_ask(entry),
      waiting_since: Map.get(entry, :scored_at) || Map.get(entry, :updated_at),
      url: Map.get(entry, :url),
      review: %{
        held: held?,
        score: Map.get(entry, :score),
        pass_threshold: Map.get(entry, :pass_threshold),
        round: Map.get(entry, :rounds_asked),
        max_rounds: Map.get(entry, :max_rounds),
        found: Map.get(entry, :reason),
        questions: Map.get(entry, :questions) || []
      }
    }
  end

  defp clarify_ask(%{kind: :clarification}), do: "Answer the quality gate's questions"
  defp clarify_ask(%{kind: :error}), do: "The quality gate couldn't score the ticket"
  defp clarify_ask(_entry), do: "Rewrite the ticket: the quality gate skipped it"

  defp comments(node), do: node |> get_in(["comments", "nodes"]) |> List.wrap()

  defp question_id(node, comment_id) do
    with %{"body" => body} <- Enum.find(comments(node), &(&1["id"] == comment_id)), do: DecisionRequest.question_id(body)
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
