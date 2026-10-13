defmodule SymphonyElixir.Inbox.Item do
  @moduledoc """
  One thing that waits on the Director, as the Inbox lists it (`SymphonyElixir.Inbox`).

  `kind` says what waits:

  - `:action`: an open `linear_request_human_action` request (`SymphonyElixir.HumanActions.Request`),
    whatever else the ticket is; its review is the request: why, the steps or the options, about
    how long, what it unblocks;
  - `:final_verification`: a `Final verification:` ticket to sign off;
  - `:plan`: a plan parent (label `plan` or `breakdown`) whose plan waits for approval, with its
    sub-tickets in landing order;
  - `:pr`: any other ticket in `In Review` or `Human Review`, a pull request to review, with its
    PR, CI result and QA verdict;
  - `:clarify`: a ticket the quality gate holds for clarification or skipped, with its score, its
    round and what the gate found;
  - `:blocked`: a ticket an access hold pauses in place (`SymphonyElixir.Hold`), with the reason the
    hold recorded and what clears it; the Director lifts it with `Unblock`.

  A plan, PR or final verification carries its `## Review brief` comment parsed
  (`SymphonyElixir.Inbox.ReviewBrief`) as `review.brief`, nil when it has none.

  `state_machine` is the repo's resolved version (`SymphonyElixir.StateMachine.version/1`): the app
  offers `Restart` only on a designed repo, since the control API refuses it on a legacy one.

  A hold only becomes a `:blocked` item when nothing else already waits on the ticket: `from_node/4`
  reads the store's hold after `SymphonyElixir.HumanActions.Waiting` found no entry, so an open
  request or a review keeps its own, richer item. A dependency or fix-ticket hold clears on its own
  and is not listed at all — only an access hold waits on a person.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hold
  alias SymphonyElixir.HumanActions.{Collector, Waiting}
  alias SymphonyElixir.Inbox.ReviewBrief
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.QaAgent.Report
  alias SymphonyElixir.StateMachine

  @type kind :: :action | :final_verification | :plan | :pr | :clarify | :blocked
  @type t :: %{
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:repo_key) => String.t() | nil,
          optional(:state_machine) => StateMachine.version(),
          required(:kind) => kind(),
          required(:state) => String.t() | nil,
          required(:ask) => String.t(),
          required(:waiting_since) => DateTime.t() | nil,
          required(:url) => String.t() | nil,
          required(:review) => map()
        }

  @pull_request_url ~r{^https://github\.com/[^/]+/[^/]+/pull/\d+}
  @verdict_pattern ~r/^\*\*Verdict:\*\*\s*(\w+)/m
  @option_pattern ~r/^\*\*(.+?)\*\*(\s*\(recommended\))?\s*[:—-]?\s*(.*)$/i
  @ci_passed ["SUCCESS", "NEUTRAL", "SKIPPED"]
  @ci_failed ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]

  @doc """
  The item of an issue node read from Linear (the fields of `SymphonyElixir.Inbox`'s detail query),
  or nil when nothing about it waits on a person. `lookups` reads what Symphony knows locally:
  `:ci` (`(issue_id, repo_key) -> conclusion | nil`) and `:hold` (`(repo_key, issue_id) -> hold | nil`).
  """
  @spec from_node(map(), String.t() | nil, Schema.t(), map()) :: t() | nil
  def from_node(node, repo_key, settings, lookups) do
    case Waiting.entries([node], settings) do
      [entry] -> build(node, entry, repo_key, settings, lookups)
      [] -> from_hold(node, repo_key, settings, lookups)
    end
  end

  defp build(node, entry, repo_key, settings, lookups) do
    %{
      issue_id: entry.issue_id,
      identifier: entry.identifier,
      title: entry.title,
      repo_key: repo_key,
      state_machine: StateMachine.version(settings),
      kind: entry.kind,
      state: entry.state,
      ask: ask(entry, node, settings),
      waiting_since: entry.waiting_since,
      url: entry.url,
      review: review(entry.kind, node, repo_key, settings, lookups)
    }
  end

  # A ticket an access hold pauses in place waits on a person's Unblock, so it is listed with the
  # reason the hold recorded even though no review covers it. A dependency or fix-ticket hold
  # clears on its own, so it is not listed.
  defp from_hold(node, repo_key, settings, lookups) do
    with hold when is_map(hold) <- store_hold(repo_key, node["id"], lookups),
         true <- Hold.access_wait?(hold) do
      %{
        issue_id: node["id"],
        identifier: node["identifier"],
        title: node["title"],
        repo_key: repo_key,
        state_machine: StateMachine.version(settings),
        kind: :blocked,
        state: get_in(node, ["state", "name"]),
        ask: Map.get(hold, :reason) || "Unblock the ticket and it continues",
        waiting_since: Map.get(hold, :set_at),
        url: node["url"],
        review: %{reason: Map.get(hold, :reason), clearing_condition: Map.get(hold, :clearing_condition)}
      }
    else
      _none -> nil
    end
  end

  defp store_hold(repo_key, issue_id, lookups) do
    case Map.get(lookups, :hold) do
      fun when is_function(fun, 2) -> fun.(repo_key, issue_id)
      _none -> nil
    end
  end

  defp ask(%{kind: :action}, node, settings), do: Collector.newest_request(node, settings).title
  defp ask(%{headline: headline}, _node, _settings) when is_binary(headline), do: headline
  defp ask(%{kind: :plan}, _node, _settings), do: "Approve the plan"
  defp ask(%{kind: :final_verification}, _node, _settings), do: "Sign off the final verification"
  defp ask(%{kind: :pr}, _node, _settings), do: "Review the pull request"

  # A merge confirmation's hold carries the move its confirmation performs (`Merging`), so the
  # Inbox's Decide says the ticket moves; an ordinary decision's carries none.
  defp review(:action, node, repo_key, settings, lookups) do
    {comment_id, request} = Collector.newest_open_request(node, settings)

    %{
      comment_id: comment_id,
      title: request.title,
      question: request.question,
      why: request.why,
      unblocks: request.unblocks,
      est_minutes: request.est_minutes,
      steps: request.steps,
      options: Enum.map(request.options, &option/1),
      requested_at: request.created_at,
      confirm: MergeConfirmation.confirm_target(store_hold(repo_key, node["id"], lookups))
    }
  end

  defp review(:plan, node, _repo_key, _settings, _lookups), do: %{brief: brief(node), sub_tickets: sub_tickets(node)}

  defp review(:pr, node, repo_key, _settings, lookups),
    do: %{brief: brief(node), pull_request: pull_request(node, repo_key, lookups)}

  defp review(:final_verification, node, _repo_key, _settings, _lookups), do: %{brief: brief(node)}

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

  defp pull_request(node, repo_key, lookups) do
    %{
      url: pull_request_url(node),
      ci: ci_result(lookups.ci.(node["id"], repo_key)),
      qa: qa(node)
    }
  end

  defp pull_request_url(node) do
    node
    |> get_in(["attachments", "nodes"])
    |> List.wrap()
    |> Enum.map(& &1["url"])
    |> Enum.find(&(is_binary(&1) and Regex.match?(@pull_request_url, &1)))
  end

  @doc """
  True for a pull request whose checks are green: CI passed, and QA does not say otherwise. Its
  notification offers Approve and Merge.
  """
  @spec checks_green?(t()) :: boolean()
  def checks_green?(%{kind: :pr, review: %{pull_request: %{ci: "passed"} = pull_request}}) do
    get_in(pull_request, [:qa, :verdict]) not in ["fail", "blocked"]
  end

  def checks_green?(_item), do: false

  @doc "A CI conclusion as `passed`, `failed` or `pending`; nil before the CI poller saw the PR."
  @spec ci_result(String.t() | nil) :: String.t() | nil
  def ci_result(nil), do: nil
  def ci_result(conclusion) when conclusion in @ci_passed, do: "passed"
  def ci_result(conclusion) when conclusion in @ci_failed, do: "failed"
  def ci_result(_conclusion), do: "pending"

  defp qa(node) do
    node
    |> comments()
    |> Enum.filter(&(is_binary(&1["body"]) and String.starts_with?(String.trim(&1["body"]), Report.heading())))
    |> Enum.max_by(&(&1["createdAt"] || ""), fn -> nil end)
    |> case do
      %{"body" => body, "id" => comment_id} ->
        verdict = with [_, verdict] <- Regex.run(@verdict_pattern, body), do: verdict
        %{verdict: verdict, report_url: comment_url(node["url"], comment_id)}

      nil ->
        nil
    end
  end

  # Linear links a comment as its issue's URL with `#comment-` and the comment id's first block.
  defp comment_url(issue_url, comment_id), do: "#{issue_url}#comment-#{comment_id |> String.split("-") |> hd()}"

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

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
