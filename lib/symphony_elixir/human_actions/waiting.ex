defmodule SymphonyElixir.HumanActions.Waiting do
  @moduledoc """
  The tickets waiting on the operator, as the state API's `waiting_on_you` lists them.

  Built from the issues `SymphonyElixir.HumanActions.Collector` reads: one entry per issue in a
  review state (`SymphonyElixir.HumanReview.review_states/1`) or with an open
  `linear_request_human_action` request (`SymphonyElixir.HumanActions.Request`). Its `kind` says
  what waits:

  - `:action`: an open request, whatever else the issue is;
  - `:final_verification`: a `Final verification:` ticket to sign off;
  - `:plan`: a plan parent (label `plan` or `breakdown`) whose plan waits for approval;
  - `:pr`: any other issue, a pull request to review.

  `waiting_since` is the latest move into the issue's current state in its history, else the
  creation of its newest open request, else nil. `headline` is the line after `**What to review:**`
  in the issue's latest `## Review brief` comment, nil when it has none.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Collector, Request}
  alias SymphonyElixir.{HumanReview, RunKind}
  alias SymphonyElixir.Linear.Issue

  @brief_heading "## Review brief"
  @what_to_review ~r/^\s*\*\*What to review:\*\*(.*)$/
  @headline_max 200

  @type kind :: :action | :final_verification | :plan | :pr
  @type entry :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          kind: kind(),
          waiting_since: DateTime.t() | nil,
          headline: String.t() | nil
        }

  @doc "The waiting entries of the issue nodes `Collector` read, in node order."
  @spec entries([map()], Schema.t()) :: [entry()]
  def entries(nodes, settings) when is_list(nodes), do: Enum.flat_map(nodes, &entry(&1, settings))

  defp entry(%{"id" => issue_id} = node, settings) when is_binary(issue_id) do
    state = get_in(node, ["state", "name"])
    requests = node |> Collector.open_requests(settings) |> Enum.map(fn {_comment_id, request} -> request end)

    if requests != [] or HumanReview.review_state?(state, settings) do
      [
        %{
          issue_id: issue_id,
          identifier: node["identifier"],
          title: node["title"],
          url: node["url"],
          state: state,
          kind: kind(node, requests),
          waiting_since: entered_at(node, state) || newest_request_at(requests),
          headline: headline(node)
        }
      ]
    else
      []
    end
  end

  defp entry(_node, _settings), do: []

  defp kind(_node, [_ | _]), do: :action

  defp kind(node, []) do
    labels = node |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(& &1["name"])

    cond do
      RunKind.classify(%Issue{title: node["title"]}) == :final_verification -> :final_verification
      Enum.any?(labels, &Issue.breakdown_label?/1) -> :plan
      true -> :pr
    end
  end

  defp entered_at(_node, nil), do: nil

  defp entered_at(node, state) do
    for(
      %{"toState" => %{"name" => to}} = change <- node |> get_in(["history", "nodes"]) |> List.wrap(),
      normalize(to) == normalize(state),
      at = parse_datetime(change["createdAt"]),
      at != nil,
      do: at
    )
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp newest_request_at(requests) do
    requests |> Enum.map(& &1.created_at) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  The headline of a review brief: the text after `**What to review:**`, or the first non-blank line
  under it when that line is empty, on one line. Nil when the body has none.
  """
  @spec brief_headline(String.t() | nil) :: String.t() | nil
  def brief_headline(body) when is_binary(body) do
    lines = String.split(body, ~r/\R/)

    case Enum.find_index(lines, &Regex.match?(@what_to_review, &1)) do
      nil ->
        nil

      index ->
        [_, rest] = Regex.run(@what_to_review, Enum.at(lines, index))

        [rest | Enum.drop(lines, index + 1)]
        |> Enum.map(&(&1 |> String.replace(~r/^\s*(?:[-*]|\d+[.)])\s+/, "") |> Request.one_line()))
        |> Enum.find(&(&1 != ""))
        |> truncate()
    end
  end

  def brief_headline(_body), do: nil

  defp headline(node) do
    node
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1["body"]) and String.starts_with?(String.trim_leading(&1["body"]), @brief_heading)))
    |> Enum.max_by(&(&1["createdAt"] || ""), fn -> nil end)
    |> case do
      %{"body" => body} -> brief_headline(body)
      nil -> nil
    end
  end

  defp truncate(nil), do: nil

  defp truncate(text) do
    if String.length(text) > @headline_max, do: String.slice(text, 0, @headline_max - 1) <> "…", else: text
  end

  defp normalize(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize(_state), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
