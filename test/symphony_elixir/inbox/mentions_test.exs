defmodule SymphonyElixir.Inbox.MentionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Inbox.{Mentions, ReviewBrief}

  describe "texts/1" do
    test "reads every text an action shows: its fields, steps, options, effects, trade-offs and why recommended" do
      item = %{
        kind: :action,
        ask: "Leave the old text to TP-891",
        review: %{
          title: "Leave the old text to TP-891",
          question: "Should TP-892 leave it?",
          why: "Code Review sent PR #448 back.",
          if_unanswered: "TP-892 stays in Rework.",
          unblocks: "TP-880",
          steps: ["Open #12"],
          options: [%{label: "Leave it", effect: "TP-892 goes back.", recommended: true, tradeoffs: [%{kind: "good", text: "Merges today, unlike TP-893."}]}],
          recommendation_reason: "It is one line."
        }
      }

      assert Mentions.texts(item) == [
               "Leave the old text to TP-891",
               "Leave the old text to TP-891",
               "Should TP-892 leave it?",
               "Code Review sent PR #448 back.",
               "TP-892 stays in Rework.",
               "TP-880",
               "Open #12",
               "Leave it",
               "TP-892 goes back.",
               "Merges today, unlike TP-893.",
               "It is one line."
             ]
    end

    test "reads a plan's parsed brief, the markdown of one that didn't parse, and nothing without a brief" do
      brief =
        ReviewBrief.parse("""
        ## Review brief

        **What to review:** the plan for TP-923.

        - TP-947: agents write decisions in your words.

        **What changed since the last brief:**

        - TP-988 filed.

        **Decisions needed:**

        1. Chips for TP-952?
           - Options: A; B
           - Recommendation: B, see #12

        **How to approve / change / reject:**

        - Approve: move TP-923 on.
        """)

      texts = Mentions.texts(%{kind: :plan, ask: "Approve the plan", review: %{brief: brief}})
      assert Mentions.scan(texts) == ["TP-923", "TP-947", "TP-988", "TP-952", "#12"]

      assert Mentions.texts(%{kind: :plan, ask: "Approve the plan", review: %{brief: %{format: "raw", markdown: "See TP-1"}}}) == ["Approve the plan", "See TP-1"]
      assert Mentions.texts(%{kind: :plan, ask: "Approve the plan", review: %{brief: nil}}) == ["Approve the plan"]
    end

    test "reads what the quality gate found and asked, a hold's reason and what clears it, and only the ask of another kind" do
      assert Mentions.texts(%{kind: :clarify, ask: "Answer", review: %{found: "Like TP-1", questions: ["And TP-2?"]}}) == ["Answer", "Like TP-1", "And TP-2?"]
      assert Mentions.texts(%{kind: :blocked, ask: "Unblock", review: %{reason: "Waits on #3", clearing_condition: nil}}) == ["Unblock", "Waits on #3"]
      assert Mentions.texts(%{kind: :pr, ask: "Merge TP-4", review: nil}) == ["Merge TP-4"]
    end
  end

  describe "scan/1 and classify/1" do
    test "finds tickets and pull requests as written, once each, in order" do
      assert Mentions.scan(["TP-892 waits on PR #448 and #449; TP-892's parent is TP-923 (see PR#450)."]) ==
               ["TP-892", "PR #448", "#449", "TP-923", "PR#450"]

      assert Enum.map(["TP-892", "PR #448", "#449", "PR#450"], &Mentions.classify/1) ==
               [{:ticket, "TP-892"}, {:pull_request, 448}, {:pull_request, 449}, {:pull_request, 450}]
    end

    test "skips what only looks like a mention: lowercase keys, anchors, HTML entities, longer words" do
      assert Mentions.scan(["tp-1 x-TP-2 TP-3x https://example.com/#4 &#5; issue#6 a/#7 TP-8-9"]) == []
      assert Mentions.scan(["[TP-1](https://linear.app/acme/issue/TP-1/title)"]) == ["TP-1"]
    end
  end

  describe "summary/1" do
    test "keeps the first sentence as plain text" do
      assert Mentions.summary("Part of TP-923 (the Inbox). Resolve mentions.") == "Part of TP-923 (the Inbox)."
      assert Mentions.summary("No full stop at all") == "No full stop at all"
      assert Mentions.summary("Version 1.2 ships today! Then more.") == "Version 1.2 ships today!"
    end

    test "never keeps markdown, links, URLs, HTML or headings" do
      text = """
      <!-- symphony:summary:start -->
      ## What to build

      > **Find** _mentions_ in `the text` with [a link](https://example.com/a) and ![shot](https://x/y.png), see https://linear.app/x <b>now</b>.
      """

      assert Mentions.summary(text) == "Find mentions in the text with a link and, see now."

      for text <- ["- [ ] **Bold** item", "1. ~~Gone~~ `code` [x]", "---\n### Heading\n| a | b |\n__Under__ *it*", "```\ncode\n```\nAfter the fence."] do
        summary = Mentions.summary(text)
        refute summary =~ ~r/[*_`\[\]#|~]|https?:|<|>/, "#{inspect(text)} → #{inspect(summary)}"
      end

      assert Mentions.summary("snake_case_name stays.") == "snake_case_name stays."
    end

    test "is at most 160 characters, and nil for nothing" do
      long = String.duplicate("word ", 60) <> "end."
      summary = Mentions.summary(long)
      assert String.length(summary) == 160
      assert String.ends_with?(summary, "…")

      assert Mentions.summary(String.duplicate("a", 159) <> ".") == String.duplicate("a", 159) <> "."
      assert Mentions.summary("## Only a heading") == nil
      assert Mentions.summary("   ") == nil
      assert Mentions.summary(nil) == nil
    end
  end
end
