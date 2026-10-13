defmodule SymphonyElixir.ReviewQuality do
  @moduledoc """
  How far the Code Review agent can be trusted, for the `review` part of `GET /api/v1/history`,
  from the tickets' verdicts and signals ledger (no Linear request).

  The acceptance gate is retired: the Code Review agent judges each PR, and the repo's manual
  review setting says whether a person confirms the merge (`docs/design/state-machine.md`). A Code
  Review approval is upheld when the next judge passes it — QA passes or skips it, or the Director
  confirms the merge — and overturned when QA fails it or the Director sends it to Rework. An
  approval nobody has judged yet counts neither way.

  A verdict counts in the period when it was recorded on one of its days (UTC).
  """

  alias SymphonyElixir.{Config, RunStore, TicketState}

  @review "code_review"
  @qa "qa"
  @decision "decision returned"

  @doc """
  The review quality of `dates`. `opts`: `:ticket_states` (a list of ticket records, else every
  repo's from the store) and `:manual_review` (a repo key → `"on"`/`"off"` function).
  """
  @spec payload([Date.t()], keyword()) :: map()
  def payload(dates, opts) when is_list(dates) do
    records = Keyword.get_lazy(opts, :ticket_states, &RunStore.list_all_ticket_states/0)
    manual_review = Keyword.get(opts, :manual_review, &manual_review/1)
    in_period = MapSet.new(dates)

    tickets =
      records
      |> list_or_empty()
      |> Enum.map(&TicketState.normalize/1)
      |> Enum.filter(&is_binary(&1.issue_id))
      |> Enum.map(&ticket(&1, in_period))

    judgements = Enum.flat_map(tickets, & &1.judgements)

    %{
      agreement: agreement(judgements),
      by_repo: by_repo(judgements, manual_review),
      qa_first_pass: qa_first_pass(tickets),
      sent_to_rework: sent_to_rework(tickets),
      disagreements: disagreements(judgements)
    }
  end

  defp list_or_empty(records) when is_list(records), do: records
  defp list_or_empty(_error), do: []

  defp manual_review(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, %{manual_review: setting}} -> setting
      _error -> "off"
    end
  end

  defp ticket(record, in_period) do
    events = events(record)
    reviews = Enum.filter(events, &(&1.kind == :review and in_period?(&1, in_period)))

    %{
      record: record,
      reviewed?: reviews != [],
      sent_to_rework?: Enum.any?(events, &(in_period?(&1, in_period) and rework?(&1))),
      first_qa: events |> Enum.filter(&(&1.kind == :qa and &1.outcome in ["pass", "fail"])) |> List.first(),
      in_period: in_period,
      judgements: reviews |> Enum.filter(&(&1.outcome == "approve")) |> Enum.map(&judge(&1, record, events))
    }
  end

  # The ticket's verdicts and the Director's decisions, oldest first.
  defp events(record) do
    verdicts =
      for %{kind: kind, outcome: outcome, recorded_at: %DateTime{} = at} <- record.verdicts,
          kind in [@review, @qa],
          do: %{kind: if(kind == @review, do: :review, else: :qa), outcome: outcome, at: at}

    decisions =
      for %{name: @decision, details: details, at: %DateTime{} = at} <- record.signals,
          to = Map.get(details, :to) || Map.get(details, "to"),
          to in ["Merging", "Rework"],
          do: %{kind: :director, outcome: to, at: at}

    Enum.sort_by(verdicts ++ decisions, & &1.at, DateTime)
  end

  defp in_period?(%{at: at}, in_period), do: MapSet.member?(in_period, DateTime.to_date(at))

  defp rework?(%{kind: :review, outcome: "rework"}), do: true
  defp rework?(%{kind: :qa, outcome: "fail"}), do: true
  defp rework?(%{kind: :director, outcome: "Rework"}), do: true
  defp rework?(_event), do: false

  # What became of one approval: the judgements after it and before the next review.
  defp judge(approval, record, events) do
    later =
      events
      |> Enum.drop_while(&(&1 != approval))
      |> Enum.drop(1)
      |> Enum.take_while(&(&1.kind != :review))

    overturn = Enum.find(later, &rework?/1)
    upheld = Enum.find(later, &(&1.outcome in ["pass", "skip", "Merging"]))

    %{
      repo_key: record.repo_key,
      issue_id: record.issue_id,
      identifier: record.issue_identifier,
      approved_at: approval.at,
      verdict: verdict(overturn, upheld),
      decided_by: decided_by(overturn || upheld),
      decision: decision(overturn || upheld),
      decided_at: (overturn || upheld || %{})[:at]
    }
  end

  defp verdict(%{}, _upheld), do: :disagree
  defp verdict(nil, %{}), do: :agree
  defp verdict(nil, nil), do: :pending

  defp decided_by(%{kind: :qa}), do: "QA"
  defp decided_by(%{kind: :director}), do: "Director"
  defp decided_by(nil), do: nil

  defp decision(%{kind: :qa, outcome: "fail"}), do: "QA failed"
  defp decision(%{kind: :qa, outcome: "skip"}), do: "QA skipped"
  defp decision(%{kind: :qa}), do: "QA passed"
  defp decision(%{kind: :director, outcome: "Rework"}), do: "Sent to Rework"
  defp decision(%{kind: :director}), do: "Confirmed the merge"
  defp decision(nil), do: nil

  defp agreement(judgements) do
    agreed = Enum.count(judgements, &(&1.verdict == :agree))
    disagreed = Enum.count(judgements, &(&1.verdict == :disagree))
    %{agreed: agreed, disagreed: disagreed, pending: Enum.count(judgements, &(&1.verdict == :pending)), rate: rate(agreed, agreed + disagreed)}
  end

  defp by_repo(judgements, manual_review) do
    judgements
    |> Enum.group_by(& &1.repo_key)
    |> Enum.map(fn {repo_key, repo_judgements} ->
      repo_judgements |> agreement() |> Map.merge(%{repo_key: repo_key, manual_review: manual_review.(repo_key)})
    end)
    |> Enum.sort_by(&(&1.repo_key || ""))
  end

  defp qa_first_pass(tickets) do
    judged = Enum.filter(tickets, &(&1.first_qa != nil and in_period?(&1.first_qa, &1.in_period)))
    passed = Enum.count(judged, &(&1.first_qa.outcome == "pass"))
    %{passed: passed, judged: length(judged), rate: rate(passed, length(judged))}
  end

  defp sent_to_rework(tickets) do
    reviewed = Enum.filter(tickets, & &1.reviewed?)
    sent = Enum.count(reviewed, & &1.sent_to_rework?)
    %{sent: sent, reviewed: length(reviewed), rate: rate(sent, length(reviewed))}
  end

  defp disagreements(judgements) do
    judgements
    |> Enum.filter(&(&1.verdict == :disagree))
    |> Enum.sort_by(& &1.decided_at, {:desc, DateTime})
    |> Enum.map(fn judgement ->
      %{
        issue_id: judgement.issue_id,
        identifier: judgement.identifier,
        repo_key: judgement.repo_key,
        review: "Approved",
        decision: judgement.decision,
        decided_by: judgement.decided_by,
        decided_at: DateTime.to_iso8601(judgement.decided_at)
      }
    end)
  end

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: Float.round(count / total, 4)
end
