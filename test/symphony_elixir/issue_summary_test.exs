defmodule SymphonyElixir.IssueSummaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueSummary

  @start "<!-- symphony:summary:start -->"
  @finish "<!-- symphony:summary:end -->"

  defp summary!(attrs \\ %{}) do
    {:ok, summary} = IssueSummary.new(Map.merge(%{"status" => "In progress", "changelog_entry" => "Started"}, attrs))
    summary
  end

  describe "status/1" do
    test "reads the block's status line, and nil without a block or a status" do
      {:ok, description} = IssueSummary.put("Intro.", summary!(%{"status" => "PR open, waiting on Code Review"}), ~D[2026-10-13])
      assert IssueSummary.status(description) == "PR open, waiting on Code Review"
      assert IssueSummary.status("Intro.") == nil
      assert IssueSummary.status("Intro. " <> @start <> " no status " <> @finish) == nil
      assert IssueSummary.status(nil) == nil
    end
  end

  describe "new/1" do
    test "folds text onto one line and drops comment markers, so a field can't close the block" do
      assert {:ok, summary} =
               IssueSummary.new(%{
                 "status" => "  Waiting\non  review <!-- symphony:summary:end --> ",
                 "changelog_entry" => "Did\tthings",
                 "links" => %{
                   "review_brief" => " https://linear.app/acme/issue/TP-7#comment-1 ",
                   "artifacts" => [%{"label" => "[Domain] brief", "url" => "https://linear.app/acme/document/x"}, %{"label" => "PR", "url" => "http://github.com/a/b/pull/1"}]
                 }
               })

      assert summary == %{
               status: "Waiting on review symphony:summary:end",
               entry: "Did things",
               review_brief: "https://linear.app/acme/issue/TP-7#comment-1",
               artifacts: [%{label: "Domain brief", url: "https://linear.app/acme/document/x"}, %{label: "PR", url: "http://github.com/a/b/pull/1"}]
             }

      assert {:ok, %{review_brief: nil, artifacts: []}} = IssueSummary.new(%{"status" => "x", "changelog_entry" => "y", "links" => nil})
    end

    test "refuses invalid fields" do
      base = %{"status" => "x", "changelog_entry" => "y"}
      too_long = String.duplicate("a", 301)
      artifact = %{"label" => "PR", "url" => "https://github.com/a/b/pull/1"}

      for {attrs, error} <- [
            {%{"changelog_entry" => "y"}, :invalid_summary_status},
            {%{base | "status" => too_long}, :invalid_summary_status},
            {%{base | "status" => "<!---->"}, :invalid_summary_status},
            {%{base | "changelog_entry" => 3}, :invalid_summary_changelog_entry},
            {Map.put(base, "links", ["https://x.dev"]), :invalid_summary_links},
            {Map.put(base, "links", %{"review_brief" => "javascript:alert(1)"}), {:invalid_summary_url, "javascript:alert(1)"}},
            {Map.put(base, "links", %{"review_brief" => 7}), {:invalid_summary_url, nil}},
            {Map.put(base, "links", %{"artifacts" => "PR"}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => List.duplicate(artifact, 21)}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [artifact, %{"label" => "PR"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => 1, "url" => "https://x.dev"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => "[]", "url" => "https://x.dev"}]}), :invalid_summary_artifacts},
            {Map.put(base, "links", %{"artifacts" => [%{"label" => "PR", "url" => "https://x.dev/a (b)"}]}), {:invalid_summary_url, "https://x.dev/a (b)"}}
          ] do
        assert IssueSummary.new(attrs) == {:error, error}
      end
    end
  end

  describe "put/3" do
    test "appends the block after a blank line, whatever the description ends with" do
      summary = summary!()

      for {description, prefix} <- [{nil, ""}, {"", ""}, {"Goal", "Goal\n\n"}, {"Goal\n", "Goal\n\n"}, {"Goal\n\n", "Goal\n\n"}] do
        assert {:ok, written} = IssueSummary.put(description, summary, ~D[2026-10-06])
        assert written == prefix <> rendered()
      end
    end

    test "renders the status, the review brief, the artifacts and the changelog" do
      summary = summary!(%{"links" => %{"review_brief" => "https://linear.app/b", "artifacts" => [%{"label" => "PR", "url" => "https://github.com/p"}]}})
      assert {:ok, written} = IssueSummary.put("Goal", summary, ~D[2026-10-06])

      assert written ==
               "Goal\n\n" <>
                 Enum.join(
                   [
                     @start,
                     "",
                     "---",
                     "",
                     "### Symphony summary",
                     "",
                     "**Status:** In progress",
                     "",
                     "**Review brief:** [Review brief](https://linear.app/b)",
                     "",
                     "**Artifacts:**",
                     "",
                     "- [PR](https://github.com/p)",
                     "",
                     "**Changelog:**",
                     "",
                     "- 2026-10-06: Started",
                     "",
                     @finish
                   ],
                   "\n"
                 )
    end

    test "replaces the block in place, prepending one entry and keeping the newest 20" do
      {:ok, description} = IssueSummary.put("Before", summary!(%{"changelog_entry" => "entry 0"}), ~D[2026-10-01])
      description = description <> "\nAfter"

      description =
        Enum.reduce(1..24, description, fn n, acc ->
          {:ok, acc} = IssueSummary.put(acc, summary!(%{"status" => "status #{n}", "changelog_entry" => "entry #{n}"}), ~D[2026-10-02])
          acc
        end)

      assert String.starts_with?(description, "Before\n\n" <> @start)
      assert String.ends_with?(description, @finish <> "\nAfter")
      assert description =~ "**Status:** status 24"
      refute description =~ "status 23"

      entries = Regex.scan(~r/^- 2026-10-0\d: (entry \d+)$/m, description, capture: :all_but_first) |> List.flatten()
      assert length(entries) == IssueSummary.changelog_cap()
      assert List.first(entries) == "entry 24"
      assert List.last(entries) == "entry 5"
    end

    test "starts a fresh changelog when the block has none, and refuses an unterminated block" do
      assert {:ok, written} = IssueSummary.put("A\n\n#{@start}\nold\n#{@finish}", summary!(), ~D[2026-10-06])
      assert written == "A\n\n" <> rendered()

      assert IssueSummary.put("A\n\n#{@start}\nold", summary!(), ~D[2026-10-06]) == {:error, :summary_block_unterminated}
    end

    test "rewrites a block as Linear stores it: no empty heading, and the `*` changelog entries kept" do
      stored =
        "Goal\n\n## #{@start}\n\n### Symphony summary\n\n**Status:** Old\n\n**Changelog:**\n\n" <>
          "* 2026-10-05: Earlier\n* 2026-10-04: Oldest #{@finish}"

      assert {:ok, written} = IssueSummary.put(stored, summary!(), ~D[2026-10-06])

      assert String.starts_with?(written, "Goal\n\n#{@start}\n\n---\n")
      assert written =~ "- 2026-10-06: Started\n- 2026-10-05: Earlier\n- 2026-10-04: Oldest\n\n#{@finish}"
      assert {:ok, ^written} = IssueSummary.put(String.replace(written, "- 2026-10-06: Started\n", ""), summary!(), ~D[2026-10-06])
    end

    test "drops only an empty heading at the end of a text" do
      assert IssueSummary.drop_empty_heading("Goal\n\n## ") == "Goal\n\n"
      assert IssueSummary.drop_empty_heading("Goal\n##\n\n") == "Goal\n\n"
      assert IssueSummary.drop_empty_heading("## ") == ""
      assert IssueSummary.drop_empty_heading("Goal\n\n## Plan\n") == "Goal\n\n## Plan\n"
      assert IssueSummary.drop_empty_heading("Issue #12\n\n") == "Issue #12\n\n"
    end
  end

  describe "strip/1" do
    test "removes the block and the blank lines around it" do
      assert IssueSummary.strip(nil) == nil
      assert IssueSummary.strip("No block") == "No block"
      assert IssueSummary.strip("Goal\n\n" <> rendered()) == "Goal"
      assert IssueSummary.strip("Goal\n\n" <> rendered() <> "\n\nMore\n") == "Goal\n\nMore\n"
      assert IssueSummary.strip(rendered() <> "\nMore") == "More"
      assert IssueSummary.strip(rendered()) == ""
      assert IssueSummary.strip("Goal\n\n#{IssueSummary.start_marker()}\nhalf") == "Goal"
      assert IssueSummary.end_marker() == @finish
    end
  end

  describe "the changelog from the ticket's pushes and verdicts" do
    alias SymphonyElixir.TicketEvents
    alias SymphonyElixir.TicketEvents.Event

    defp event(type, at, payload), do: %Event{type: type, at: at, payload: payload}

    defp history do
      [
        event("attempt.pushed", ~U[2026-11-03 10:00:00Z], %{head: "abc1234def", attempt: 1, intent: "handoff"}),
        event("note", ~U[2026-11-03 11:00:00Z], %{text: "not a changelog line"}),
        event("verdict.recorded", ~U[2026-11-04 09:00:00Z], %{kind: "code_review", outcome: "approve", head: "abc1234def"}),
        event("verdict.recorded", ~U[2026-11-05 09:00:00Z], %{"kind" => "qa", "outcome" => "fail **now**"})
      ]
    end

    test "renders one dated line per push and verdict, in plain words" do
      assert IssueSummary.event_entries(history()) == [
               "- 2026-11-03: Attempt 1 pushed (abc1234)",
               "- 2026-11-04: Code Review verdict: approve (abc1234)",
               "- 2026-11-05: QA verdict: fail now"
             ]

      assert IssueSummary.event_entries([event("verdict.recorded", ~U[2026-11-05 09:00:00Z], %{kind: "pre_merge_check"}), event("attempt.pushed", ~U[2026-11-05 09:00:00Z], %{})]) ==
               ["- 2026-11-05: Pre Merge Check verdict", "- 2026-11-05: Attempt pushed"]

      assert IssueSummary.event_entries([event("verdict.recorded", ~U[2026-11-05 09:00:00Z], %{}), %{type: "attempt.pushed"}]) == ["- 2026-11-05: Review verdict"]

      assert IssueSummary.event_entries([event("verdict.recorded", ~U[2026-11-05 09:00:00Z], %{kind: "code_review", outcome: "request_changes"})]) ==
               ["- 2026-11-05: Code Review verdict: request changes"]
    end

    test "a run that spent its token budget has a line; any other run's end has none (TP-1418)" do
      spent = %{run_number: 2, exit: "token budget spent", budget_exhausted: %{limit: 100_000_000, tokens: %{total_tokens: 100_008_209}}}
      string_keyed = %{"exit" => "token budget spent", "budget_exhausted" => %{"limit" => 10, "tokens" => "unknown"}}

      assert IssueSummary.event_entries([
               event("run.ended", ~U[2026-11-05 11:41:00Z], spent),
               event("run.ended", ~U[2026-11-05 12:00:00Z], %{run_number: 3, exit: "ended normally"}),
               event("run.ended", ~U[2026-11-05 12:30:00Z], string_keyed)
             ]) == [
               "- 2026-11-05: Run 2 ended: token budget spent (100M tokens of a 100M limit)",
               "- 2026-11-05: A run ended: token budget spent (a 10 limit)"
             ]

      assert "run.ended" in IssueSummary.event_types()
    end

    test "put/4 writes the lines with the run's entry, newest day first" do
      {:ok, description} = IssueSummary.put("Intro.", summary!(%{"changelog_entry" => "Opened the PR"}), ~D[2026-11-04], history())

      assert description =~
               "**Changelog:**\n\n- 2026-11-05: QA verdict: fail now\n- 2026-11-04: Code Review verdict: approve (abc1234)\n- 2026-11-04: Opened the PR\n- 2026-11-03: Attempt 1 pushed (abc1234)\n\n" <>
                 @finish

      {:ok, again} = IssueSummary.put(description, summary!(%{"changelog_entry" => "Answered review"}), ~D[2026-11-05], history())
      assert again =~ "**Changelog:**\n\n- 2026-11-05: Answered review\n- 2026-11-05: QA verdict: fail now\n- 2026-11-04: Code Review verdict"
      assert length(String.split(again, "Attempt 1 pushed")) == 2
    end

    test "put_changelog/2 adds the lines the block lacks, once, and leaves every other byte" do
      {:ok, description} = IssueSummary.put("Intro.", summary!(%{"changelog_entry" => "Started"}), ~D[2026-11-02])
      projected = IssueSummary.put_changelog(description, history())

      assert projected ==
               String.replace(
                 description,
                 "- 2026-11-02: Started",
                 "- 2026-11-05: QA verdict: fail now\n- 2026-11-04: Code Review verdict: approve (abc1234)\n- 2026-11-03: Attempt 1 pushed (abc1234)\n- 2026-11-02: Started"
               )

      assert IssueSummary.put_changelog(projected, history()) == projected

      # Linear stores the entries as `*` items: they are found by their text, and the block stays as Linear has it.
      linear = String.replace(projected, "\n- 20", "\n* 20")
      assert IssueSummary.put_changelog(linear, history()) == linear
    end

    test "put_changelog/2 keeps the newest entries and leaves a description without a block alone" do
      {:ok, description} = IssueSummary.put("", summary!(), ~D[2026-11-01])
      many = for day <- 1..25, do: event("attempt.pushed", DateTime.new!(Date.new!(2026, 10, day), ~T[10:00:00]), %{attempt: day})

      assert description |> IssueSummary.put_changelog(many) |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- 20")) == 20
      undated = String.replace(description, "- 2026-11-01: Started", "- Started, no date")
      assert undated |> IssueSummary.put_changelog(history()) |> String.ends_with?("- 2026-11-03: Attempt 1 pushed (abc1234)\n- Started, no date\n\n" <> @finish)
      assert IssueSummary.put_changelog("No block.", history()) == "No block."
      assert IssueSummary.put_changelog("#{@start}\nno changelog\n#{@finish}", history()) == "#{@start}\nno changelog\n#{@finish}"
      assert IssueSummary.put_changelog(nil, history()) == nil
    end

    test "history/1 reads the ticket's pushes and verdicts from the store" do
      issue_id = "issue-summary-#{System.unique_integer([:positive])}"
      {:ok, _event} = TicketEvents.record("repo-a", issue_id, "attempt.pushed", %{head: "abc1234def", attempt: 1}, [])
      {:ok, _event} = TicketEvents.record("repo-a", issue_id, "note", %{text: "skipped"}, [])

      assert [%Event{type: "attempt.pushed"}] = IssueSummary.history(issue_id)
    end
  end

  defp rendered do
    {:ok, block} = IssueSummary.put("", summary!(), ~D[2026-10-06])
    block
  end
end
