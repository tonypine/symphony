defmodule SymphonyElixir.HumanActions.PlainWordsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanActions.PlainWords

  defp request(attrs) do
    Map.merge(
      %{
        title: "Leave the old text to TP-891",
        question: "Should TP-892 (Retire two old review steps) leave the old text to TP-891?",
        why: "Code Review sent PR #448 back a second time.",
        options: [
          %{label: "Leave it to TP-891", effect: "TP-892 goes back to Code Review.", recommended: true},
          %{label: "Remove it now", effect: "The next run deletes the old text."}
        ]
      },
      attrs
    )
  end

  test "finds backticks" do
    assert PlainWords.tokens("Handle `the partials` now, or ` later") == [backticks: "`the partials`", backticks: "`"]
  end

  test "finds template syntax" do
    assert PlainWords.tokens("the legacy {% else %} branches") == [template: "{% else %}"]
    assert PlainWords.tokens("a stray %} closer and {% opener") == [template: "%}", template: "{%"]
  end

  test "finds a path" do
    assert PlainWords.tokens("See lib/… and lib/foo, ./setup, ~/notes, /etc and a/b/c.") ==
             [path: "lib/", path: "lib/foo", path: "./setup", path: "~/notes", path: "/etc", path: "a/b/c"]

    assert PlainWords.tokens("the render_hold/2 helper") == [path: "render_hold/2"]
  end

  test "finds a link" do
    assert PlainWords.tokens("See https://github.com/acme/web/pull/7.") == [link: "https://github.com/acme/web/pull/7"]
  end

  test "finds a file name with an extension" do
    assert PlainWords.tokens("(parent_tickets.liquid, foo.ex) and *.liquid, .md and Request.render.") ==
             [file: "parent_tickets.liquid", file: "foo.ex", file: "*.liquid", file: ".md", file: "Request.render"]
  end

  test "finds a commit hash" do
    assert PlainWords.tokens("Code Review sent it back (head 2f5af5ab). Then 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b.") ==
             [hash: "2f5af5ab", hash: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"]
  end

  test "finds a branch name" do
    assert PlainWords.tokens("the next run syncs main into auto/TP-892, then origin/main.") == [branch: "auto/TP-892", branch: "origin/main"]
  end

  test "lets ticket identifiers, PR numbers, numbers and ordinary sentences pass" do
    for text <- [
          "TP-891 (Remove the retired review states) lands first.",
          "PR #448 and #454 change the same text.",
          "It failed 1234567 times, 3.5 times a day, version 1.19.x, at 05:48 on 2026-10-13.",
          "Ship it now, e.g. today. That is, i.e. before the release... Done!",
          "Pick A and/or B: client/server stays a word.",
          "Users see \"a warning\" (once)."
        ] do
      assert PlainWords.tokens(text) == [], text
    end

    assert PlainWords.tokens(nil) == []
  end

  test "names each token by the field the tool's input names it" do
    request =
      request(%{
        title: "Settle parent_tickets.liquid",
        why: "Head 2f5af5ab.",
        if_unanswered: "auto/TP-892 waits.",
        unblocks: "the handoff of `main`",
        recommendation_reason: "See lib/foo.",
        question: "How should TP-892 handle {% else %}?",
        options: [
          %{label: "Defer `it`", effect: "Edit plan_pipeline.liquid.", recommended: true, tradeoffs: [%{kind: "good", text: "Fast"}, %{kind: "risk", text: "origin/main moves."}]},
          %{label: "Strip", effect: "Strip them.", tradeoffs: [%{kind: "cost", text: nil}, "free text"]}
        ]
      })

    assert PlainWords.findings(request) == [
             %{field: "title", token: "parent_tickets.liquid", kind: :file},
             %{field: "decision.question", token: "{% else %}", kind: :template},
             %{field: "why", token: "2f5af5ab", kind: :hash},
             %{field: "if_unanswered", token: "auto/TP-892", kind: :branch},
             %{field: "unblocks", token: "`main`", kind: :backticks},
             %{field: "decision.recommendation_reason", token: "lib/foo", kind: :path},
             %{field: "decision.options[0].label", token: "`it`", kind: :backticks},
             %{field: "decision.options[0].effect", token: "plan_pipeline.liquid", kind: :file},
             %{field: "decision.options[0].tradeoffs[1].text", token: "origin/main", kind: :branch}
           ]
  end

  test "reads the option lines of a parsed request too" do
    assert PlainWords.findings(%{options: ["**Strip them**: edit foo.ex."]}) == [%{field: "decision.options[0]", token: "foo.ex", kind: :file}]
  end

  test "checks a request: ok in plain words, else a message naming each token and field and asking for plain words" do
    assert PlainWords.check(request(%{})) == :ok

    assert {:error, message} =
             PlainWords.check(request(%{question: "How should TP-892 handle `parent_tickets.liquid`?", why: "Head 2f5af5ab, see https://x.io/a."}))

    assert message ==
             "A decision is read by the Director, who does not read code. " <>
               ~s(`decision.question` has backticks "`parent_tickets.liquid`", the file name "parent_tickets.liquid"; ) <>
               ~s(`why` has the commit hash "2f5af5ab", the link "https://x.io/a". ) <>
               "Rewrite it in plain words: say what the thing does, not where it lives or what it is called in the code. " <>
               "Name a ticket by its identifier and a short name, and a PR as PR #123."
  end

  test "the standard's rewritten example passes" do
    rewritten = %{
      title: "Let TP-892 ship without the old instructions' Final verification text",
      question:
        "TP-892 (Remove the Final verification and Supervisor check flows) keeps failing Code Review because the older set of agent " <>
          "instructions still describes the Final verification step. Should TP-892 leave that text to TP-891 (Remove the retired review " <>
          "states), which deletes it anyway?",
      why:
        "Code Review sent PR #448 back a second time. Its only finding is the old Final verification text. You decided earlier today " <>
          "that TP-891 removes it. The reviewer accepts that only if TP-892's description says so.",
      if_unanswered: "TP-892 stays in Rework. Each time it goes back to Code Review unchanged, it is sent back for the same reason.",
      recommendation_reason: "It is one line of text, and it lets TP-892 merge without touching TP-891's work.",
      options: [
        %{
          label: "Leave it to TP-891",
          effect: "You add one line to TP-892's description saying TP-891 removes the old text. TP-892 goes back to Code Review with no code change.",
          recommended: true,
          tradeoffs: [
            %{kind: "good", text: "TP-892 can merge today."},
            %{kind: "cost", text: "The old instructions describe a step that no longer exists until TP-891 lands."}
          ]
        },
        %{
          label: "Remove it in TP-892 now",
          effect: "The next run deletes the old text and goes back to Code Review.",
          tradeoffs: [
            %{kind: "good", text: "TP-892 is complete on its own."},
            %{kind: "risk", text: "TP-891's PR #454 changes the same text, so whichever merges second needs its clash fixed."}
          ]
        },
        %{
          label: "Wait for TP-891",
          effect: "TP-892 waits until TP-891 merges, takes in its changes and goes back to Code Review.",
          tradeoffs: [%{kind: "cost", text: "TP-892 waits as long as TP-891 does."}]
        }
      ]
    }

    assert PlainWords.check(rewritten) == :ok
  end
end
