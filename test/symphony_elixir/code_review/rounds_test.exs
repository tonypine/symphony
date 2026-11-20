defmodule SymphonyElixir.CodeReview.RoundsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodeReview.Rounds
  alias SymphonyElixir.ReviewAgent

  @previous "1111111111111111111111111111111111111111"

  defp finding(file, line_range, summary \\ "A problem.") do
    %{summary: summary, file: file, line_range: line_range, quoted_snippet: "x", suggested_fix: "Fix it."}
  end

  # Answers `git diff -U0 previous..HEAD -- file` with `hunks` per file; a file it doesn't know fails.
  defp git(hunks) do
    fn ["diff", "--no-color", "--no-ext-diff", "-U0", "#{@previous}..HEAD", "--", file] ->
      case Map.fetch(hunks, file) do
        {:ok, headers} -> {:ok, Enum.map_join(headers, "\n", &"#{&1}\n+changed")}
        :error -> :error
      end
    end
  end

  describe "previous_head/2" do
    test "is the newest other head a review judged, skipping inconclusive ones" do
      verdicts = [
        %{outcome: "inconclusive", head_sha: "ccc"},
        %{outcome: "request_changes", head_sha: "head"},
        %{outcome: "request_changes", head_sha: "bbb"},
        %{outcome: "approve", head_sha: "aaa"}
      ]

      assert Rounds.previous_head(verdicts, "head") == "bbb"
      assert Rounds.previous_head([%{outcome: "block", head_sha: nil}], "head") == nil
      assert Rounds.previous_head([], "head") == nil
    end
  end

  describe "mark/3" do
    test "a finding on lines that did not change is unchanged, one on changed lines changed" do
      hunks = %{"lib/a.ex" => ["@@ -10,2 +10,3 @@", "@@ -30 +31 @@"], "lib/b.ex" => ["@@ -5,2 +4,0 @@"]}

      findings = [
        finding("lib/a.ex", {1, 9}),
        finding("lib/a.ex", {12, 20}),
        finding("lib/a.ex", {31, 31}),
        finding("lib/b.ex", {5, 5}),
        finding("lib/b.ex", {7, 8}),
        finding("lib/c.ex", {1, 1})
      ]

      assert Enum.map(Rounds.mark(findings, @previous, git(hunks)), &Map.get(&1, :since_last_review)) ==
               [:unchanged, :changed, :changed, :changed, :unchanged, nil]
    end

    test "marks nothing on a pull request not reviewed before" do
      findings = [finding("lib/a.ex", {1, 1})]
      assert Rounds.mark(findings, nil, fn _args -> flunk("no git without a previous head") end) == findings
    end
  end

  describe "annotate/3 and details/3" do
    test "each marked finding's comment says what it is, and the round counts the ones missed earlier" do
      missed = Map.put(finding("lib/a.ex", {1, 2}, "Old problem."), :since_last_review, :unchanged)
      fixed = Map.put(finding("lib/a.ex", {9, 9}, "New problem."), :since_last_review, :changed)
      unmarked = finding("lib/c.ex", {3, 3}, "Unknown.")
      comments = Enum.map([missed, fixed, unmarked], &ReviewAgent.finding_comment/1) ++ ["[could not be placed] Elsewhere."]

      annotated = Rounds.annotate(comments, [missed, fixed, unmarked], @previous)

      assert Enum.at(annotated, 0) =~ "Old problem. (lib/a.ex:1-2) Suggested fix: Fix it. Missed earlier: these lines did not change since the review of `1111111`."
      assert Enum.at(annotated, 1) =~ "New problem. (lib/a.ex:9-9) Suggested fix: Fix it. These lines changed since the review of `1111111`."
      assert Enum.slice(annotated, 2, 2) == Enum.slice(comments, 2, 2)

      assert Rounds.details(annotated, [missed, fixed, unmarked], @previous) == %{
               findings_count: 4,
               previous_head: @previous,
               missed_earlier: 1,
               missed_findings: [%{summary: "Old problem.", file: "lib/a.ex", line_range: [1, 2]}]
             }
    end

    test "a first round only counts its findings" do
      comments = ["One.", "Two."]
      assert Rounds.annotate(comments, [], nil) == comments
      assert Rounds.details(comments, [], nil) == %{findings_count: 2}
    end
  end
end
