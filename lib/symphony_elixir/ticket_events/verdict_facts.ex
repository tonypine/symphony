defmodule SymphonyElixir.TicketEvents.VerdictFacts do
  @moduledoc """
  What a review said, as the typed fields of its `verdict.recorded` event
  (`SymphonyElixir.TicketEvents.Types`), and read back from one.

  `review/1` takes the code reviewer's result (`SymphonyElixir.ReviewAgent.Verdict.from_map/1`,
  grounded by `SymphonyElixir.ReviewAgent`) and `qa/1` the QA agent's
  (`SymphonyElixir.QaAgent.Verdict.from_map/1`): each returns the fields the event carries, every
  part of the verdict in the catalog's shape, with an empty value left out. The verdict tools refuse
  what does not fit, so nothing they accepted is dropped here.

  `findings/1` and `qa_findings/1` read a stored event's payload back: its typed fields, and for an
  event stored before them, the findings its open `details` kept (a round's `missed_findings`, or a
  deepening's `findings`), in the same shape.
  """

  @review_finding_keys [:summary, :file, :quoted_snippet, :suggested_fix, :decision]
  @qa_step_keys [:name, :status, :details, :environment, :gap, :defect]
  @qa_finding_keys [:line, :summary, :step, :viewport, :expected, :actual]

  @doc "The typed fields of a code review's verdict, from the reviewer's result."
  @spec review(map()) :: map()
  def review(result) when is_map(result) do
    compact(%{
      findings: result |> Map.get(:findings) |> list() |> Enum.map(&review_finding/1),
      comments: result |> Map.get(:comments) |> list() |> strings(),
      unread_files: result |> Map.get(:unread_files) |> list() |> strings()
    })
  end

  def review(_result), do: %{}

  @doc "The typed fields of QA's verdict, from the QA agent's result."
  @spec qa(map()) :: map()
  def qa(outcome) when is_map(outcome) do
    compact(%{
      summary: text(Map.get(outcome, :summary)),
      steps: outcome |> Map.get(:steps) |> list() |> Enum.filter(&is_map/1) |> Enum.map(&qa_step/1),
      qa_findings: outcome |> Map.get(:finding_details) |> list() |> Enum.filter(&is_map/1) |> Enum.map(&qa_finding/1) |> Enum.reject(&is_nil(&1[:line]))
    })
  end

  def qa(_outcome), do: %{}

  @doc """
  A verdict payload's code review findings: its typed `findings`, else the ones its `details` kept
  before they were typed (a deepening's `findings`, a round's `missed_findings`), each in the typed
  shape. `[]` when it has none.
  """
  @spec findings(map()) :: [map()]
  def findings(payload) when is_map(payload) do
    case field(payload, :findings) do
      [_ | _] = findings ->
        findings |> Enum.filter(&is_map/1) |> Enum.map(&review_finding/1)

      _none ->
        details = field(payload, :details) || %{}
        legacy = if is_map(details), do: field(details, :findings) || field(details, :missed_findings), else: nil
        legacy |> list() |> Enum.filter(&is_map/1) |> Enum.map(&review_finding/1)
    end
  end

  def findings(_payload), do: []

  @doc "A verdict payload's QA findings (`qa_findings`), each in the typed shape; `[]` when it has none."
  @spec qa_findings(map()) :: [map()]
  def qa_findings(payload) when is_map(payload),
    do: payload |> field(:qa_findings) |> list() |> Enum.filter(&is_map/1) |> Enum.map(&qa_finding/1)

  def qa_findings(_payload), do: []

  defp review_finding(finding) do
    @review_finding_keys
    |> Map.new(&{&1, text(field(finding, &1))})
    |> Map.put(:line_range, line_range(field(finding, :line_range)))
    |> Map.put(:since_last_review, mark(field(finding, :since_last_review)))
    |> compact()
  end

  # The reviewer's range is a `{start, end}` pair; a stored one is a map, and a legacy one a list.
  defp line_range({start_line, end_line}), do: %{start: start_line, end: end_line}
  defp line_range([start_line, end_line]), do: %{start: start_line, end: end_line}
  defp line_range(%{} = range), do: %{start: field(range, :start), end: field(range, :end)}
  defp line_range(_range), do: nil

  defp mark(mark) when mark in [:changed, :unchanged], do: Atom.to_string(mark)
  defp mark(mark) when mark in ["changed", "unchanged"], do: mark
  defp mark(_mark), do: nil

  defp qa_step(step) do
    @qa_step_keys
    |> Map.new(&{&1, text(field(step, &1))})
    |> Map.merge(%{
      evidence: step |> field(:evidence) |> list() |> strings(),
      blocked_by: step |> field(:blocked_by) |> list() |> strings(),
      checklist: if(field(step, :checklist) == true, do: true)
    })
    |> compact()
  end

  defp qa_finding(finding) do
    @qa_finding_keys
    |> Map.new(&{&1, text(field(finding, &1))})
    |> Map.put(:evidence, finding |> field(:evidence) |> list() |> strings())
    |> compact()
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp strings(values), do: values |> Enum.map(&text/1) |> Enum.reject(&is_nil/1)

  defp text(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp text(_value), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> value in [nil, []] end) |> Map.new()
end
