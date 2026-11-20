defmodule SymphonyElixir.CodeReview.Rounds do
  @moduledoc """
  What a Code Review round's change request says about the rounds before it (TP-1516).

  A review asks for every problem it finds in one verdict, so a second "changes requested" on the
  same pull request should be about the fix or something new. When the pull request was reviewed
  before, each finding is compared with the last reviewed head: Symphony reads, with git, which
  lines of the finding's file changed between that head and this one. A finding none of whose lines
  changed was there for the earlier review to find, and is marked missed earlier; one on lines that
  changed is about the change since. A finding whose file git cannot compare is left unmarked.

  The verdict's details carry the round's count of findings and of findings missed earlier, so the
  ticket's history (and the Director's ticket page, which shows them on the verdict's row) tells a
  ticket that went through three rounds of one finding each from one fixed in a round.
  """

  alias SymphonyElixir.ReviewAgent

  @reviewed_outcomes ["approve", "request_changes", "block"]
  @hunk_header ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  @type git :: ([String.t()] -> {:ok, String.t()} | :error)
  @type mark :: :changed | :unchanged

  @doc """
  The head the pull request was last reviewed on, other than `head`: the newest of `verdicts`
  (newest first, `SymphonyElixir.Handoff.verdicts/3`) that judged the change, approving it or not.
  An inconclusive review reached no verdict, so it is not one. Nil when no other head was reviewed.
  """
  @spec previous_head([map()], String.t() | nil) :: String.t() | nil
  def previous_head(verdicts, head) when is_list(verdicts) do
    Enum.find_value(verdicts, fn
      %{outcome: outcome, head_sha: previous}
      when outcome in @reviewed_outcomes and is_binary(previous) and previous != head ->
        previous

      _verdict ->
        nil
    end)
  end

  @doc """
  Each finding with `:since_last_review` set to `:unchanged` when none of its lines changed between
  `previous_head` and `HEAD`, `:changed` when one did, and left as it is when `git` cannot compare
  its file. Nothing is marked without a previous head.
  """
  @spec mark([ReviewAgent.finding()], String.t() | nil, git()) :: [ReviewAgent.finding()]
  def mark(findings, nil, _git), do: findings

  def mark(findings, previous_head, git) when is_list(findings) and is_binary(previous_head) do
    Enum.map(findings, fn finding ->
      case changed_lines(git, previous_head, finding.file) do
        {:ok, ranges} -> Map.put(finding, :since_last_review, since_last_review(finding.line_range, ranges))
        :error -> finding
      end
    end)
  end

  @doc """
  The change request's comments with each marked finding's comment saying what it is: missed earlier,
  or about lines changed since the last reviewed head. A comment that is no marked finding's stays as
  it is.
  """
  @spec annotate([String.t()], [ReviewAgent.finding()], String.t() | nil) :: [String.t()]
  def annotate(comments, _marked, nil), do: comments

  def annotate(comments, marked, previous_head) do
    notes = Map.new(for %{since_last_review: mark} = finding <- marked, do: {ReviewAgent.finding_comment(finding), note(mark, previous_head)})
    Enum.map(comments, fn comment -> comment <> Map.get(notes, comment, "") end)
  end

  @doc """
  The round's details for its verdict: `findings_count`, the change request's findings (its
  comments), and, once the pull request was reviewed before, `previous_head` and `missed_earlier`
  (how many findings sit on lines that did not change since), with `missed_findings` naming them.
  """
  @spec details([String.t()], [ReviewAgent.finding()], String.t() | nil) :: map()
  def details(comments, marked, previous_head) do
    missed = Enum.filter(marked, &(Map.get(&1, :since_last_review) == :unchanged))
    base = %{findings_count: length(comments)}

    case previous_head do
      nil ->
        base

      previous_head ->
        Map.merge(base, %{
          previous_head: previous_head,
          missed_earlier: length(missed),
          missed_findings: Enum.map(missed, &missed_finding/1)
        })
    end
  end

  defp missed_finding(%{summary: summary, file: file, line_range: {start_line, end_line}}) do
    %{summary: summary, file: file, line_range: [start_line, end_line]}
  end

  defp note(:unchanged, previous_head), do: " Missed earlier: these lines did not change since the review of `#{short(previous_head)}`."
  defp note(:changed, previous_head), do: " These lines changed since the review of `#{short(previous_head)}`."

  defp short(head), do: String.slice(head, 0, 7)

  defp since_last_review({start_line, end_line}, ranges) do
    if Enum.any?(ranges, fn {first, last} -> first <= end_line and last >= start_line end), do: :changed, else: :unchanged
  end

  # The lines of `file` at HEAD that changed since `previous_head`, from the zero-context diff's hunk
  # headers. A hunk that only deletes touches the lines on either side of the cut.
  defp changed_lines(git, previous_head, file) do
    case git.(["diff", "--no-color", "--no-ext-diff", "-U0", "#{previous_head}..HEAD", "--", file]) do
      {:ok, output} ->
        {:ok,
         output
         |> String.split("\n")
         |> Enum.flat_map(fn line ->
           case Regex.run(@hunk_header, line) do
             [_header, start] ->
               [{String.to_integer(start), String.to_integer(start)}]

             [_header, start, "0"] ->
               [{String.to_integer(start), String.to_integer(start) + 1}]

             [_header, start, count] ->
               first = String.to_integer(start)
               [{first, first + String.to_integer(count) - 1}]

             nil ->
               []
           end
         end)}

      :error ->
        :error
    end
  end
end
