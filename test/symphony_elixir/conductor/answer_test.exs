defmodule SymphonyElixir.Conductor.AnswerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Conductor.Answer

  @question %{
    "title" => "The login step failed three times",
    "question" => "Should Symphony try another approach or wait for you?",
    "why" => "QA failed the same step three times.",
    "if_unanswered" => "The ticket stays paused.",
    "recommendation_reason" => "A fourth try would repeat the third.",
    "options" => [
      %{"label" => "Try another approach", "effect" => "The next rework starts over.", "recommended" => true, "action" => "rework", "finding" => "  Start from the login form. "},
      %{"label" => "Wait for me", "effect" => "Nothing runs until you say.", "action" => "continue"}
    ]
  }

  defp json(map), do: Jason.encode!(map)

  test "reads the instructions, the update, its refs and the question" do
    text = json(%{"instructions" => "  Fix the login step first. ", "update" => "QA failed the login step.", "refs" => ["evt_1", "evt_1", "evt_2"], "ask_person" => @question})

    assert {:ok, answer} = Answer.parse(text)
    assert answer.instructions == "Fix the login step first."
    assert answer.update == "QA failed the login step."
    assert answer.refs == ["evt_1", "evt_2"]

    assert answer.ask_person == %{
             title: "The login step failed three times",
             question: "Should Symphony try another approach or wait for you?",
             why: "QA failed the same step three times.",
             if_unanswered: "The ticket stays paused.",
             recommendation_reason: "A fourth try would repeat the third.",
             options: [
               %{label: "Try another approach", effect: "The next rework starts over.", recommended: true, action: "rework", finding: "Start from the login form."},
               %{label: "Wait for me", effect: "Nothing runs until you say.", recommended: false, action: "continue"}
             ]
           }
  end

  test "every action of the closed list is read" do
    for action <- Answer.actions() -- ["rework"] do
      options = [%{"label" => "A", "effect" => "x", "action" => action}, %{"label" => "B", "effect" => "y", "action" => "continue"}]
      assert {:ok, %{ask_person: %{options: [%{action: ^action} | _rest]}}} = Answer.parse(json(%{"instructions" => "x", "ask_person" => Map.put(@question, "options", options)}))
    end

    assert Answer.actions() == ["continue", "rerun", "rework", "back_to_review", "accept_without_qa", "cancel"]
  end

  test "a question with an option Symphony cannot act on is dropped, and the rest of the answer kept" do
    [rework, wait] = @question["options"]

    for {options, why} <- [
          {[rework, Map.delete(wait, "action")], ~s(option "Wait for me" names the action nil)},
          {[rework, Map.put(wait, "action", "merge")], ~s(option "Wait for me" names the action "merge", not one of)},
          {[Map.delete(rework, "finding"), wait], ~s(option "Try another approach" sends the ticket to Rework without a `finding`)},
          {[Map.put(rework, "finding", " "), wait], ~s(option "Try another approach" sends the ticket to Rework with a blank `finding`)}
        ] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          text = json(%{"instructions" => "Go on.", "update" => "QA is stuck.", "ask_person" => Map.put(@question, "options", options)})
          assert {:ok, %{instructions: "Go on.", update: "QA is stuck.", ask_person: nil}} = Answer.parse(text)
        end)

      assert log =~ "question \"The login step failed three times\" was dropped"
      assert log =~ why
    end
  end

  test "a missing or blank update is none, and so is a missing question and refs" do
    assert {:ok, %{update: nil, refs: [], ask_person: nil}} = Answer.parse(json(%{"instructions" => "Go on."}))
    assert {:ok, %{update: nil}} = Answer.parse(json(%{"instructions" => "Go on.", "update" => "  ", "ask_person" => nil}))
  end

  test "refuses an answer outside the schema, saying why" do
    for {answer, why} <- [
          {"[1]", "the answer is not a JSON object"},
          {"{not json", "the answer is not valid JSON"},
          {json(%{}), "`instructions` must be a string"},
          {json(%{"instructions" => " "}), "`instructions` is blank"},
          {json(%{"instructions" => "x", "update" => 3}), "`update` must be a string or null"},
          {json(%{"instructions" => "x", "refs" => [1]}), "`refs` must list event ids"},
          {json(%{"instructions" => "x", "refs" => "evt_1"}), "`refs` must list event ids"},
          {json(%{"instructions" => "x", "ask_person" => "yes"}), "`ask_person` must be an object or null"},
          {json(%{"instructions" => "x", "ask_person" => Map.delete(@question, "why")}), "`ask_person.why` must be a non-blank string"},
          {json(%{"instructions" => "x", "ask_person" => Map.put(@question, "options", [hd(@question["options"])])}), "`ask_person.options` must list two to four options"},
          {json(%{"instructions" => "x", "ask_person" => Map.put(@question, "options", [%{"label" => "A"}, %{"label" => "B"}])}), "each of `ask_person.options` needs a `label` and an `effect`"}
        ] do
      assert Answer.parse(answer) == {:error, why}, answer
    end
  end

  test "a text over its limit is cut at a boundary and the answer accepted" do
    sentence = "This is one sentence of the advice. "
    instructions = String.duplicate(sentence, 100)
    steer = String.duplicate("word ", 400)
    title = String.duplicate("t", 130)
    question = Map.put(@question, "title", title)
    update = String.duplicate("u", Answer.update_max() + 5)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        text = json(%{"instructions" => instructions, "update" => update, "ask_person" => question, "steer" => %{"message" => steer, "when" => "now"}})
        assert {:ok, answer} = Answer.parse(text, watch: true)
        send(self(), {:answer, answer})
      end)

    assert_received {:answer, answer}
    assert String.length(answer.instructions) <= Answer.instructions_max()
    assert String.ends_with?(answer.instructions, "advice. [cut by Symphony]")
    assert String.length(answer.update) == Answer.update_max()
    assert String.length(answer.steer.message) <= 1_500
    assert String.ends_with?(answer.steer.message, "word [cut by Symphony]")
    assert String.length(answer.ask_person.title) == 120
    assert log =~ "`instructions` was"
    assert log =~ "`update` was"
    assert log =~ "`steer.message` was"
    assert log =~ "`ask_person.title` was"
  end

  test "blocks: well formed picks are kept, the first 3, and the rest are dropped one by one" do
    picks = [
      %{"type" => "steps"},
      %{"type" => "steps", "run_id" => "run-1"},
      %{"type" => "steps", "run_id" => 4},
      %{"type" => "steps", "extra" => 1},
      %{"type" => "budget"},
      %{"type" => "budget", "extra" => 1},
      %{"type" => "path"},
      %{"type" => "nonsense"},
      %{"type" => "question"},
      "steps",
      %{"type" => "findings"}
    ]

    assert {:ok, %{blocks: blocks}} = Answer.parse(json(%{"instructions" => "x", "blocks" => picks}))
    assert blocks == [%{type: "steps"}, %{type: "steps", run_id: "run-1"}, %{type: "budget"}]

    assert {:ok, %{blocks: [%{type: "epic"}, %{type: "findings"}, %{type: "path"}]}} =
             Answer.parse(json(%{"instructions" => "x", "blocks" => [%{"type" => "epic"}, %{"type" => "findings"}, %{"type" => "path"}, %{"type" => "budget"}]}))

    assert {:ok, %{blocks: []}} = Answer.parse(json(%{"instructions" => "x", "blocks" => "steps"}))
    assert {:ok, %{blocks: []}} = Answer.parse(json(%{"instructions" => "x"}))
  end

  test "blocks: evidence, attempts and compare picks are checked for their own fields" do
    picks = [
      %{"type" => "evidence", "refs" => ["e1", "e1", "e2"]},
      %{"type" => "evidence", "refs" => []},
      %{"type" => "evidence", "refs" => ["a", "b", "c", "d", "e"]},
      %{"type" => "evidence", "refs" => [1]},
      %{"type" => "evidence", "refs" => ["a"], "extra" => 1},
      %{"type" => "attempts", "step_id" => "build"},
      %{"type" => "attempts", "step_id" => "build", "run_id" => "run-1"},
      %{"type" => "attempts", "step_id" => "build", "run_id" => ""},
      %{"type" => "attempts", "step_id" => "build", "extra" => 1},
      %{"type" => "attempts"},
      %{"type" => "compare", "expected" => %{"text" => " A list "}, "actual" => %{"ref" => "e1"}},
      %{"type" => "compare", "expected" => %{"text" => String.duplicate("a", 81)}, "actual" => %{"ref" => "e1"}},
      %{"type" => "compare", "expected" => %{"text" => " "}, "actual" => %{"ref" => "e1"}},
      %{"type" => "compare", "expected" => %{"text" => "A", "label" => "x"}, "actual" => %{"ref" => "e1"}},
      %{"type" => "compare", "expected" => %{"ref" => ""}, "actual" => %{"ref" => "e1"}},
      %{"type" => "compare", "expected" => %{"text" => "A"}, "actual" => %{"ref" => "e1"}, "expected_label" => "x"}
    ]

    for {pick, expected} <- [
          {Enum.at(picks, 0), [%{type: "evidence", refs: ["e1", "e2"]}]},
          {Enum.at(picks, 5), [%{type: "attempts", step_id: "build"}]},
          {Enum.at(picks, 6), [%{type: "attempts", step_id: "build", run_id: "run-1"}]},
          {Enum.at(picks, 10), [%{type: "compare", expected: %{text: "A list"}, actual: %{ref: "e1"}}]}
        ] do
      assert {:ok, %{blocks: ^expected}} = Answer.parse(json(%{"instructions" => "x", "blocks" => [pick]}))
    end

    dropped = Enum.reject(picks, &(&1 in [Enum.at(picks, 0), Enum.at(picks, 5), Enum.at(picks, 6), Enum.at(picks, 10)]))
    assert {:ok, %{blocks: []}} = Answer.parse(json(%{"instructions" => "x", "blocks" => dropped}))
  end

  test "a watch turn may steer or stop the run and leave the instructions null" do
    assert {:ok, %{instructions: nil, steer: %{message: "Read the error first.", when: "now"}, stop: %{reason: "It loops."}}} =
             Answer.parse(json(%{"instructions" => nil, "steer" => %{"message" => " Read the error first. ", "when" => "now"}, "stop" => %{"reason" => "It loops."}}), watch: true)

    assert {:ok, %{steer: nil, stop: nil}} = Answer.parse(json(%{"instructions" => "Go on."}))
    assert Answer.parse(json(%{"instructions" => nil})) == {:error, "`instructions` must be a string"}
    assert {:ok, %{instructions: nil}} = Answer.read([json(%{"steer" => nil})], watch: true)

    steer = "`steer` must be null or hold a `message` and `when` (`next_turn` or `now`)"

    for {answer, why} <- [
          {%{"steer" => %{"message" => "x", "when" => "later"}}, steer},
          {%{"steer" => "x"}, steer},
          {%{"steer" => %{"message" => " ", "when" => "now"}}, "`steer.message` is blank"},
          {%{"stop" => %{"reason" => ""}}, "`stop` must be null or hold a `reason`"}
        ] do
      assert Answer.parse(json(answer), watch: true) == {:error, why}
    end
  end

  test "a route is read only where Symphony takes one, and a malformed one is refused there" do
    rework = %{"to" => "rework", "finding" => "  Add a flag QA can set to make the state request fail. "}

    assert {:ok, %{route: %{to: "rework", finding: "Add a flag QA can set to make the state request fail."}}} =
             Answer.parse(json(%{"instructions" => "Build the flag.", "route" => rework}), route: true)

    assert {:ok, %{route: %{to: "rerun"}}} = Answer.parse(json(%{"instructions" => "Use the stand-in.", "route" => %{"to" => "rerun"}}), route: true)
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "Go on.", "route" => nil}), route: true)
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "Go on."}), route: true)

    # At every other junction the field is ignored, whatever it holds.
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "Go on.", "route" => rework}))
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "Go on.", "route" => "merge"}))

    long = String.duplicate("Add a seam. ", 80)
    assert {:ok, %{route: %{finding: finding}}} = Answer.parse(json(%{"instructions" => "x", "route" => %{"to" => "rework", "finding" => long}}), route: true)
    assert String.length(finding) <= 600 and String.ends_with?(finding, " [cut by Symphony]")

    malformed = "`route` must be null, `{\"to\": \"rerun\"}`, `{\"to\": \"rework\", \"finding\": ...}` or `{\"to\": \"ticket\", ...}`"

    for {route, why} <- [
          {%{"to" => "merge"}, malformed},
          {%{"to" => "rework"}, malformed},
          {%{"to" => "rerun", "finding" => "x"}, malformed},
          {%{"to" => "rework", "finding" => 3}, malformed},
          {"rerun", malformed},
          {%{"to" => "rework", "finding" => " "}, "`route.finding` is blank"}
        ] do
      assert Answer.parse(json(%{"instructions" => "x", "route" => route}), route: true) == {:error, why}
    end
  end

  test "a ticket route is read as given where Symphony may file one, and only there" do
    route = %{
      "to" => "ticket",
      "relation" => "blocks",
      "repo" => " symphony ",
      "title" => String.duplicate("Long title ", 20),
      "problem" => "QA builds a Mac app Cycle lacks.",
      "wanted" => "  ",
      "acceptance" => ["A pass starts.", " ", 3, "A pass starts."],
      "walkthrough" => "not a list",
      "evidence" => ["evt_1"],
      "existing" => 12
    }

    assert {:ok, %{route: ticket}} = Answer.parse(json(%{"instructions" => "x", "route" => route}), route: :ticket)
    assert %{to: "ticket", relation: "blocks", repo: "symphony", problem: "QA builds a Mac app Cycle lacks.", wanted: nil, existing: nil} = ticket
    assert ticket.acceptance == ["A pass starts."]
    assert ticket.walkthrough == []
    assert ticket.evidence == ["evt_1"]
    assert String.length(ticket.title) <= 120

    # At `after_qa_blocked` it is one route among the others.
    assert {:ok, %{route: %{to: "ticket"}}} = Answer.parse(json(%{"instructions" => "x", "route" => route}), route: true)

    # Where only a ticket route is read, any other is ignored; where none is, a ticket route is too.
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "x", "route" => %{"to" => "rerun"}}), route: :ticket)
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "x", "route" => "merge"}), route: :ticket)
    assert {:ok, %{route: nil}} = Answer.parse(json(%{"instructions" => "x", "route" => route}))
  end

  test "reads the first answer that meets the schema among the turn's texts, else the first refusal" do
    assert {:ok, %{instructions: "Second."}} =
             Answer.read(["Here it is: ```json\n{\"instructions\": \"\"}\n```", "{\"instructions\": \"Second.\"}"])

    assert Answer.read(["{\"instructions\": \"\"}", "{\"update\": 1}"]) == {:error, "`instructions` is blank"}
    assert Answer.read(["no json here", ""]) == {:error, "the answer holds no JSON object"}
    assert Answer.read([]) == {:error, "the answer holds no JSON object"}
  end

  describe "the Grooming turn's plan" do
    @plan %{
      "shape" => "single",
      "layers" => ["screen", "api", "screen"],
      "summary" => " The ticket list keeps its filter. ",
      "text" => "Approach: store the filter in the view state.\n\nOut of scope: sorting.",
      "checks" => [
        %{"kind" => "outcome", "statement" => "The filter is kept after a reload.", "proof" => "test"},
        %{
          "kind" => "qa",
          "statement" => "The list shows the filtered tickets.",
          "proof" => "qa",
          "state" => "3 tickets, 1 Done",
          "action" => "Pick Done in the filter, then reload",
          "expect" => "1 ticket",
          "size" => "wide",
          "story" => "ticket-list/filtered"
        },
        %{"id" => " proof ", "kind" => "evidence", "statement" => "A screenshot of the list.", "proof" => "attached", "size" => "huge"}
      ],
      "size" => %{"tokens" => 2_000_000, "runs" => 2}
    }

    defp grooming(attrs), do: Answer.parse(json(attrs), plan: true)
    defp plan(attrs), do: grooming(%{"plan" => Map.merge(@plan, attrs)})

    test "a plan with more checks or sub-tickets than a person reads is refused, naming the limit" do
      check = %{"kind" => "outcome", "statement" => "It works.", "proof" => "test"}
      sub = %{"title" => "A part", "ask" => "Build it."}
      assert {:ok, %{plan: %{checks: checks}}} = plan(%{"checks" => List.duplicate(check, 30)})
      assert length(checks) == 30
      assert plan(%{"checks" => List.duplicate(check, 31)}) == {:error, "`plan.checks` lists 31 entries, and a plan holds at most 30"}

      assert {:ok, %{plan: %{sub_tickets: subs}}} = plan(%{"shape" => "split", "sub_tickets" => List.duplicate(sub, 12)})
      assert length(subs) == 12

      assert plan(%{"shape" => "split", "sub_tickets" => List.duplicate(sub, 13)}) ==
               {:error, "`plan.sub_tickets` lists 13 entries, and a plan holds at most 12"}
    end

    test "is read as plan.written holds it, each check with the id it gave or none, and the instructions may be null" do
      assert {:ok, %{instructions: nil, plan: plan}} = grooming(%{"plan" => @plan, "update" => "I wrote the plan."})
      assert %{shape: "single", layers: ["screen", "api"], summary: "The ticket list keeps its filter.", size: %{tokens: 2_000_000, runs: 2}} = plan
      assert plan.text =~ "Out of scope: sorting."
      refute Map.has_key?(plan, :sub_tickets)

      # A check that names no id has none here: `TicketPlan.write/4` names it.
      assert plan.checks == [
               %{kind: "outcome", statement: "The filter is kept after a reload.", proof: "test"},
               %{
                 kind: "qa",
                 statement: "The list shows the filtered tickets.",
                 proof: "qa",
                 state: "3 tickets, 1 Done",
                 action: "Pick Done in the filter, then reload",
                 expect: "1 ticket",
                 size: "wide",
                 story: "ticket-list/filtered"
               },
               %{id: "proof", kind: "evidence", statement: "A screenshot of the list.", proof: "attached"}
             ]
    end

    test "a check that carries after_merge is read as a plain check, without the key" do
      marked = %{"kind" => "outcome", "statement" => "The page loads.", "proof" => "test", "after_merge" => true}

      assert {:ok, %{plan: %{checks: [read | _rest]}}} = plan(%{"checks" => [marked | @plan["checks"]]})
      assert read == %{kind: "outcome", statement: "The page loads.", proof: "test"}
    end

    test "is not read at another turn, which answers as before" do
      assert {:ok, %{plan: nil}} = Answer.parse(json(%{"instructions" => "x", "plan" => @plan}))
      assert Answer.parse(json(%{"plan" => @plan})) == {:error, "`instructions` must be a string"}
    end

    test "a split names its sub-tickets, each with a key; a single plan keeps none" do
      subs = [
        %{"title" => "The API returns the filter", "ask" => "Add the filter to the list endpoint.", "repo" => "web"},
        %{"key" => "screen", "title" => "The list keeps it", "ask" => "Read the filter.", "after" => ["s1", " ", 3, "s1"]},
        %{"title" => "The docs", "ask" => "Describe it.", "identifier" => " TP-12 "}
      ]

      assert {:ok, %{plan: %{shape: "split", sub_tickets: sub_tickets}}} = plan(%{"shape" => "split", "sub_tickets" => subs})

      assert sub_tickets == [
               %{key: "s1", title: "The API returns the filter", ask: "Add the filter to the list endpoint.", after: [], repo: "web"},
               %{key: "screen", title: "The list keeps it", ask: "Read the filter.", after: ["s1"]},
               %{key: "s3", title: "The docs", ask: "Describe it.", after: [], identifier: "TP-12"}
             ]

      assert {:ok, %{plan: plan}} = plan(%{"sub_tickets" => subs})
      refute Map.has_key?(plan, :sub_tickets)
    end

    test "an over-long text is cut, never refused" do
      long = String.duplicate("word ", 3_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{plan: plan}} = plan(%{"summary" => long, "text" => long, "checks" => [%{"kind" => "outcome", "statement" => long, "proof" => "test"}]})
          assert String.length(plan.summary) <= 600
          assert String.length(plan.text) <= 12_000
          assert [%{statement: statement}] = plan.checks
          assert String.length(statement) <= 600
        end)

      assert log =~ "`plan.summary` was 14999 characters; cut to 600"
    end

    test "a question leaves the plan unread, and an answer with neither is refused" do
      assert {:ok, %{plan: nil, ask_person: %{title: _title}}} = grooming(%{"plan" => %{"shape" => "nonsense"}, "ask_person" => @question})
      assert grooming(%{"update" => "Nothing to plan."}) == {:error, "the answer holds neither a `plan` nor a question (`ask_person`)"}
    end

    test "a plan that misses its shape is refused, with what is wrong" do
      check = %{"kind" => "outcome", "statement" => "It works.", "proof" => "test"}

      for {attrs, why} <- [
            {%{"shape" => "epic"}, "`plan.shape` must be one of single, split"},
            {%{"summary" => " "}, "`plan.summary` must be a non-blank string"},
            {%{"text" => 3}, "`plan.text` must be a non-blank string"},
            {%{"checks" => []}, "`plan.checks` must list at least one entry"},
            {%{"checks" => ["it works"]}, "`plan.checks[1]` must be an object"},
            {%{"checks" => [check, %{check | "kind" => "wish"}]}, "`plan.checks[2].kind` must be one of outcome, qa, evidence"},
            {%{"checks" => [%{check | "proof" => "trust"}]}, "`plan.checks[1].proof` must be one of test, qa, design, attached"},
            {%{"checks" => [%{check | "statement" => ""}]}, "`plan.checks[1].statement` must be a non-blank string"},
            {%{"checks" => [%{check | "kind" => "evidence"}]}, "`plan.checks` holds no check of kind `outcome`"},
            {%{"checks" => [check, %{"kind" => "qa", "statement" => "Seen.", "proof" => "qa", "action" => "Open it"}]},
             "`plan.checks[2].expect` must be a non-blank string: a `qa` check says what to do and what to expect"},
            {%{"size" => %{"tokens" => "many", "runs" => 1}}, "`plan.size` must hold `tokens` and `runs`, both whole numbers"},
            {%{"shape" => "split"}, "`plan.sub_tickets` must list at least one entry"},
            {%{"shape" => "split", "sub_tickets" => ["one"]}, "`plan.sub_tickets[1]` must be an object"},
            {%{"shape" => "split", "sub_tickets" => [%{"title" => "One"}]}, "`plan.sub_tickets[1].ask` must be a non-blank string"},
            {%{"shape" => "split", "sub_tickets" => [%{"ask" => "One"}]}, "`plan.sub_tickets[1].title` must be a non-blank string"}
          ] do
        assert plan(attrs) == {:error, why}
      end

      assert grooming(%{"plan" => "single"}) == {:error, "`plan` must be an object"}
      assert Answer.layers() == ~w(screen gallery api logic config tests tooling docs)
    end

    test "layers never refuse a plan: unknown names are dropped, an empty or missing list reads as none" do
      assert {:ok, %{plan: %{layers: ["screen", "tests"], checks: [_ | _]}}} = plan(%{"layers" => ["backend", "screen", "tests", 3, "android", "tests"]})
      assert {:ok, %{plan: %{layers: [], checks: [_ | _]}}} = plan(%{"layers" => []})
      assert {:ok, %{plan: %{layers: [], checks: [_ | _]}}} = plan(%{"layers" => "screen"})
      assert {:ok, %{plan: %{layers: []}}} = grooming(%{"plan" => Map.delete(@plan, "layers")})
      # `engine` is `logic`'s older name, and plans already recorded hold it.
      assert {:ok, %{plan: %{layers: ["logic", "docs"]}}} = plan(%{"layers" => ["engine", "docs", "logic"]})
    end
  end

  describe "a turn's answer on a ticket with sub-tickets" do
    defp tree(attrs), do: Answer.parse(Jason.encode!(attrs), tree: true)

    test "holds done and the operations, each with its reason; the instructions may be null" do
      operations = [
        %{"op" => "add", "title" => "The docs", "ask" => "Write them.", "after" => ["TP-2", " ", 3, "TP-2"], "repo" => "web", "reason" => "Nobody holds them."},
        %{"op" => "cancel", "ticket" => " TP-3 ", "reason" => "The API covers it."},
        %{"op" => "rewrite", "ticket" => "TP-4", "ask" => "Read the new field.", "stop" => true, "reason" => "The field was renamed."},
        %{"op" => "rewrite", "ticket" => "TP-5", "ask" => "Read it.", "reason" => "Same."},
        %{"op" => "stop", "ticket" => "TP-6", "reason" => "It builds on TP-3."}
      ]

      assert {:ok, %{instructions: nil, done: true, tree: tree}} = tree(%{"done" => true, "tree" => operations})

      assert tree == [
               %{op: "add", title: "The docs", ask: "Write them.", after: ["TP-2"], repo: "web", reason: "Nobody holds them."},
               %{op: "cancel", ticket: "TP-3", reason: "The API covers it."},
               %{op: "rewrite", ticket: "TP-4", ask: "Read the new field.", stop: true, reason: "The field was renamed."},
               %{op: "rewrite", ticket: "TP-5", ask: "Read it.", stop: false, reason: "Same."},
               %{op: "stop", ticket: "TP-6", reason: "It builds on TP-3."}
             ]

      assert {:ok, %{done: false, tree: []}} = tree(%{"done" => "yes", "tree" => "none"})
      assert {:ok, %{done: false, tree: []}} = tree(%{})
    end

    test "an operation that misses its shape or its reason is dropped and logged, and at most ten are kept" do
      malformed = [
        "cancel TP-3",
        %{"op" => "merge", "ticket" => "TP-3", "reason" => "Why not."},
        %{"op" => "cancel", "ticket" => "TP-3"},
        %{"op" => "cancel", "reason" => "No ticket."},
        %{"op" => "add", "title" => "The docs", "reason" => "No ask."},
        %{"op" => "add", "ask" => "Write them.", "reason" => "No title."},
        %{"op" => "rewrite", "ticket" => "TP-4", "reason" => "No ask."},
        %{"op" => "rewrite", "ask" => "Read it.", "reason" => "No ticket."},
        %{"op" => "stop", "ticket" => "TP-6", "reason" => "It is kept."}
      ]

      {result, log} = with_log(fn -> tree(%{"tree" => malformed}) end)
      assert {:ok, %{tree: [%{op: "stop", ticket: "TP-6"}], dropped: dropped}} = result

      assert log =~ "tree[1] was left out"
      assert log =~ "tree[8] was left out"
      refute log =~ "tree[9]"

      # Why each was left out is kept, in words the next turn can act on.
      assert dropped == [
               "tree[1] was left out: an operation must be an object",
               ~s(tree[2] was left out: `op` must be one of add, cancel, rewrite, stop, reorder, depend, not "merge"),
               "tree[3] was left out: it needs a `reason`, a non-blank string",
               "tree[4] was left out: it needs the `ticket` it is about",
               "tree[5] was left out: an `add` needs a `title` and an `ask`",
               "tree[6] was left out: an `add` needs a `title` and an `ask`",
               "tree[7] was left out: a `rewrite` needs the `ticket` and its new `ask`",
               "tree[8] was left out: a `rewrite` needs the `ticket` and its new `ask`"
             ]

      many = for n <- 1..12, do: %{"op" => "stop", "ticket" => "TP-#{n}", "reason" => "Stop."}
      assert {{:ok, %{tree: kept, dropped: over}}, _log} = with_log(fn -> tree(%{"tree" => many}) end)
      assert length(kept) == 10
      assert over == ["the stop of TP-11 was left out: an answer holds at most 10 operations", "the stop of TP-12 was left out: an answer holds at most 10 operations"]

      assert {{:ok, %{tree: [], dropped: ["`tree` was left out: it must be a list of operations"]}}, _log} = with_log(fn -> tree(%{"tree" => "none"}) end)
    end

    test "reorder, depend and an add's place and key are read, each with what it takes (TP-1621)" do
      operations = [
        %{"op" => "add", "title" => "The base", "ask" => "Build the base.", "before" => "TP-2", "key" => "base", "reason" => "It goes first."},
        %{"op" => "reorder", "ticket" => "TP-3", "before" => "TP-2", "reason" => "It is needed sooner."},
        %{"op" => "reorder", "ticket" => "TP-4", "to" => "last", "reason" => "It can wait."},
        %{"op" => "depend", "ticket" => "TP-2", "after" => ["base", " TP-3 ", ""], "reason" => "It builds on both."},
        %{"op" => "depend", "ticket" => "TP-5", "after" => [], "reason" => "It waits on nothing now."}
      ]

      assert {:ok, %{tree: tree, dropped: []}} = tree(%{"tree" => operations})

      assert tree == [
               %{op: "add", title: "The base", ask: "Build the base.", after: [], before: "TP-2", key: "base", reason: "It goes first."},
               %{op: "reorder", ticket: "TP-3", before: "TP-2", reason: "It is needed sooner."},
               %{op: "reorder", ticket: "TP-4", to: "last", reason: "It can wait."},
               %{op: "depend", ticket: "TP-2", after: ["base", "TP-3"], reason: "It builds on both."},
               %{op: "depend", ticket: "TP-5", after: [], reason: "It waits on nothing now."}
             ]

      malformed = [
        %{"op" => "reorder", "ticket" => "TP-3", "reason" => "Nowhere."},
        %{"op" => "reorder", "ticket" => "TP-3", "before" => "TP-2", "to" => "first", "reason" => "Both."},
        %{"op" => "reorder", "ticket" => "TP-3", "to" => "middle", "reason" => "No such place."},
        %{"op" => "reorder", "before" => "TP-2", "reason" => "No ticket."},
        %{"op" => "depend", "ticket" => "TP-2", "reason" => "No list."},
        %{"op" => "depend", "after" => ["TP-3"], "reason" => "No ticket."}
      ]

      {{:ok, %{tree: [], dropped: dropped}}, log} = with_log(fn -> tree(%{"tree" => malformed}) end)
      assert log =~ "tree[6] was left out"
      reorder = ~s[a `reorder` needs either `before`, the sub-ticket it goes in front of, or `to`, "first" or "last", not both]

      assert dropped == [
               "tree[1] was left out: " <> reorder,
               "tree[2] was left out: " <> reorder,
               "tree[3] was left out: " <> reorder,
               "tree[4] was left out: a `reorder` needs the `ticket` it moves",
               "tree[5] was left out: a `depend` needs `after`: the complete list of sub-tickets it waits on, `[]` for none",
               "tree[6] was left out: a `depend` needs the `ticket` and the list it waits `after`"
             ]
    end

    test "a plan outside Grooming needs no sub-tickets, and the ones it lists are read as the same intent (TP-1621)" do
      plan = %{
        "reason" => "The design changed.",
        "shape" => "split",
        "summary" => "A real queue.",
        "text" => "Approach: the engine first.",
        "checks" => [%{"kind" => "outcome", "statement" => "A slot belongs to one ticket.", "proof" => "test"}],
        "size" => %{"tokens" => 1, "runs" => 4}
      }

      kept = fn attrs -> Answer.parse(Jason.encode!(%{"update" => "Done.", "plan" => Map.merge(plan, attrs)}), plan: :optional, tree: true, sub_tickets: :kept) end

      # A split plan with no sub-tickets, or an empty list, is the next version; the list stays Symphony's.
      assert {:ok, %{plan: %{shape: "split", reason: "The design changed."} = read}} = kept.(%{})
      refute Map.has_key?(read, :sub_tickets)
      assert {:ok, %{plan: read}} = kept.(%{"sub_tickets" => []})
      refute Map.has_key?(read, :sub_tickets)

      # One named by its identifier with no ask keeps that sub-ticket; one with an ask rewrites it; a new one adds.
      entries = [
        %{"key" => "front", "title" => "The engine", "ask" => "Build the engine."},
        %{"identifier" => "TP-1607", "title" => "Engine and API"},
        %{"identifier" => "TP-1609", "ask" => "Home reads the queue.", "after" => ["front", " "]}
      ]

      assert {:ok, %{plan: %{sub_tickets: listed}}} = kept.(%{"sub_tickets" => entries})

      assert listed == [
               %{key: "front", title: "The engine", ask: "Build the engine."},
               %{key: "s2", identifier: "TP-1607", title: "Engine and API"},
               %{key: "s3", identifier: "TP-1609", ask: "Home reads the queue.", after: ["front"]}
             ]

      # A new one without a title or an ask is refused, with what to write instead.
      assert {:error, why} = kept.(%{"sub_tickets" => [%{"identifier" => "TP-1607"}, %{"title" => "The engine"}]})
      assert why =~ "`plan.sub_tickets[2]` names no `identifier`, so it would be a new sub-ticket, and a new one needs a `title` and an `ask`."
      assert why =~ "leave `plan.sub_tickets` out and change the sub-tickets with `tree` operations"
      assert {:error, "`plan.sub_tickets[1]` must be an object"} = kept.(%{"sub_tickets" => ["TP-1607"]})

      # Where the list is Symphony's alone, it is not read at all.
      ignored = Answer.parse(Jason.encode!(%{"update" => "Done.", "plan" => Map.put(plan, "sub_tickets", [%{"title" => "x"}])}), plan: :optional, sub_tickets: :ignored)
      assert {:ok, %{plan: read}} = ignored
      refute Map.has_key?(read, :sub_tickets)

      # Grooming's split still lists its sub-tickets, each complete.
      assert {:error, "`plan.sub_tickets` must list at least one entry"} = Answer.parse(Jason.encode!(%{"plan" => plan}), plan: true)
    end

    test "any other turn's answer holds neither" do
      assert {:ok, %{done: false, tree: []}} = Answer.parse(Jason.encode!(%{"instructions" => "Go on.", "done" => true, "tree" => [%{"op" => "stop"}]}))
    end
  end

  describe "a turn that answers a message" do
    @plan %{
      "shape" => "single",
      "layers" => ["engine"],
      "summary" => "It keeps the filter.",
      "text" => "Approach: store it.",
      "checks" => [%{"kind" => "outcome", "statement" => "The filter survives.", "proof" => "test"}],
      "size" => %{"tokens" => 1, "runs" => 1}
    }

    defp said(attrs, opts \\ [message: true]), do: Answer.parse(Jason.encode!(attrs), opts)

    test "the reply must be there, and nothing else has to be" do
      assert {:ok, read} = said(%{"update" => "Done."})
      assert %{update: "Done.", instructions: nil, ask: false, plan: nil, new_ticket: nil, waive: []} = read
      assert said(%{"update" => " "}) == {:error, "`update` must hold the reply to the person's message"}
      assert said(%{}) == {:error, "`update` must hold the reply to the person's message"}
      assert said(%{"update" => 7}) == {:error, "`update` must be a string or null"}
    end

    test "a changed ask must bring its plan, with the reason it changed for" do
      assert {:ok, %{ask: true, plan: %{reason: "More was asked.", checks: [%{kind: "outcome"}]}}} =
               said(%{"update" => "Ok.", "ask" => true, "plan" => Map.put(@plan, "reason", "More was asked.")})

      assert said(%{"update" => "Ok.", "ask" => true}) == {:error, "`ask` is true, so the answer must hold the new `plan`"}
      assert said(%{"update" => "Ok.", "ask" => true, "plan" => "later"}) == {:error, "`ask` is true, so the answer must hold the new `plan`"}
      assert {:error, "`plan.shape` must be one of single, split"} = said(%{"update" => "Ok.", "ask" => true, "plan" => %{}})
      # No changed ask, or a finished ticket's answer: the plan is left unread.
      assert {:ok, %{ask: false, plan: nil}} = said(%{"update" => "Ok.", "plan" => @plan})
      assert {:ok, %{ask: false, plan: nil}} = said(%{"update" => "Ok.", "ask" => true, "plan" => @plan}, message: :reply)
      assert said(%{"ask" => true}, message: :reply) == {:error, "`update` must hold the reply to the person's message"}
    end

    test "a question leaves the changed ask and its plan unread" do
      question = %{
        "title" => "Which list?",
        "question" => "Which list is meant?",
        "why" => "There are two.",
        "if_unanswered" => "It waits.",
        "recommendation_reason" => "The first is the usual one.",
        "options" => [%{"label" => "The first", "effect" => "It goes on.", "recommended" => true, "action" => "continue"}, %{"label" => "Cancel", "effect" => "It ends.", "action" => "cancel"}]
      }

      assert {:ok, %{ask: false, plan: nil, ask_person: %{title: "Which list?"}}} = said(%{"update" => "I need to know.", "ask" => true, "ask_person" => question})
    end

    test "`resume` runs the ticket again only from a message turn, and never beside a question (TP-1657)" do
      question = %{
        "title" => "Which stage?",
        "question" => "Which stage is meant?",
        "why" => "There are two.",
        "if_unanswered" => "It waits.",
        "recommendation_reason" => "QA is the usual one.",
        "options" => [%{"label" => "QA", "effect" => "It goes to QA.", "recommended" => true, "action" => "continue"}, %{"label" => "Cancel", "effect" => "It ends.", "action" => "cancel"}]
      }

      assert {:ok, %{resume: true}} = said(%{"update" => "I run it again.", "resume" => true})
      assert {:ok, %{resume: false}} = said(%{"update" => "Ok."})
      assert {:ok, %{resume: false}} = said(%{"update" => "Ok.", "resume" => "yes"})
      assert {:ok, %{resume: false}} = said(%{"update" => "I need to know.", "resume" => true, "ask_person" => question})
      assert {:ok, %{resume: false}} = said(%{"instructions" => "Go on.", "resume" => true}, [])
    end

    test "an optional plan is read when the answer holds one" do
      assert {:ok, %{plan: nil, update: nil}} = said(%{"tree" => []}, plan: :optional, tree: true)
      assert {:ok, %{plan: %{summary: "It keeps the filter."}}} = said(%{"plan" => @plan}, plan: :optional)
      assert {:error, "`plan.shape` must be one of single, split"} = said(%{"plan" => %{}}, plan: :optional)
      assert {:ok, %{plan: nil}} = said(%{"plan" => "later"}, plan: :optional)
    end

    test "a new ticket is read only where one may be created, and one that misses its shape is dropped" do
      new = %{"title" => "Keep the search text", "ask" => "Also keep the search text.", "repo" => "default"}

      assert {:ok, %{new_ticket: %{title: "Keep the search text", ask: "Also keep the search text.", repo: "default"}}} =
               said(%{"update" => "Ok.", "new_ticket" => new}, message: :reply, new_ticket: true)

      assert {:ok, %{new_ticket: nil}} = said(%{"update" => "Ok.", "new_ticket" => new})
      assert {:ok, %{new_ticket: nil}} = said(%{"update" => "Ok."}, message: :reply, new_ticket: true)

      log =
        capture_log(fn ->
          assert {:ok, %{new_ticket: nil}} = said(%{"update" => "Ok.", "new_ticket" => %{"title" => "No ask"}}, message: :reply, new_ticket: true)
          assert {:ok, %{new_ticket: nil}} = said(%{"update" => "Ok.", "new_ticket" => "one"}, message: :reply, new_ticket: true)
        end)

      assert log =~ "`new_ticket` was dropped"
    end
  end

  describe "the merge hold (TP-1589)" do
    defp holding(hold, opts \\ [hold: true]), do: Answer.parse(Jason.encode!(%{"instructions" => "Go on.", "hold" => hold}), opts)

    test "is read where a turn may hold the merge, with its reason, and a malformed one is dropped" do
      assert {:ok, %{hold: %{reason: "It merges the marker the person asked to remove."}}} = holding(%{"reason" => " It merges the marker the person asked to remove. "})
      assert {:ok, %{hold: nil}} = holding(%{"reason" => "It merges the marker."}, [])
      assert {:ok, %{hold: nil}} = holding(nil)

      long = String.duplicate("It merges the old work. ", 60)
      capture_log(fn -> send(self(), holding(%{"reason" => long})) end)
      assert_received {:ok, %{hold: %{reason: reason}}}
      assert String.length(reason) <= 1_000

      log =
        capture_log(fn ->
          assert {:ok, %{hold: nil}} = holding(%{"reason" => " "})
          assert {:ok, %{hold: nil}} = holding("hold it")
        end)

      assert log =~ "`hold` was dropped: it needs a `reason`"
    end
  end

  describe "the move (TP-1656)" do
    defp moving(move, opts), do: Answer.parse(Jason.encode!(%{"instructions" => "Go on.", "update" => "I moved it.", "move" => move}), opts)

    # What each junction's answer is read for (`Conductor`'s read opts): the move is read at every one.
    @every_junction [
      [plan: true],
      [message: true, tree: true, waive: true, hold: true],
      [message: :reply, new_ticket: true, tree: true],
      [plan: :optional, tree: true],
      [waive: true],
      [route: :ticket],
      [route: true],
      [hold: true, waive: true],
      [watch: true, route: :ticket, hold: true, waive: true],
      [tree: true, waive: true],
      []
    ]

    test "is read at every junction, its stage trimmed and its reason cut to 1,000 characters" do
      move = %{"stage" => " QA ", "reason" => " Nothing is left to code; the person said to go on to QA. "}

      for opts <- @every_junction do
        answer = %{"instructions" => "Go on.", "update" => "I moved it.", "move" => move}
        answer = if opts[:plan] == true, do: Map.merge(answer, %{"plan" => nil, "ask_person" => @question}), else: answer
        assert {:ok, %{move: %{stage: "QA", reason: "Nothing is left to code; the person said to go on to QA."}}} = Answer.parse(Jason.encode!(answer), opts), inspect(opts)
      end

      assert {:ok, %{move: nil}} = moving(nil, [])
      assert {:ok, %{move: nil}} = Answer.parse(Jason.encode!(%{"instructions" => "Go on."}))

      long = String.duplicate("It has nothing to code. ", 60)
      capture_log(fn -> send(self(), moving(%{"stage" => "QA", "reason" => long}, [])) end)
      assert_received {:ok, %{move: %{reason: reason}}}
      assert String.length(reason) <= 1_000
    end

    test "a move that misses its shape refuses the answer, with why" do
      shape = "`move` must be null or `{\"stage\": ..., \"reason\": ...}`, both strings"

      for {move, why} <- [
            {%{"stage" => " ", "reason" => "Go on."}, "`move.stage` is blank"},
            {%{"stage" => "QA", "reason" => ""}, "`move.reason` is blank"},
            {%{"stage" => "QA"}, shape},
            {%{"reason" => "Go on."}, shape},
            {%{"stage" => 3, "reason" => "Go on."}, shape},
            {"QA", shape}
          ] do
        assert moving(move, []) == {:error, why}, inspect(move)
      end
    end
  end

  describe "waivers" do
    defp waiving(waive, opts \\ [waive: true]), do: Answer.parse(Jason.encode!(%{"instructions" => "Go on.", "waive" => waive}), opts)

    test "are read where a turn may waive, one per check, and a malformed one is dropped" do
      assert {:ok, %{waive: [%{check_id: "c2", reason: "No test can reach it."}]}} = waiving([%{"check_id" => " c2 ", "reason" => "No test can reach it."}])
      assert {:ok, %{waive: []}} = waiving([%{"check_id" => "c2", "reason" => "No test can reach it."}], [])
      assert {:ok, %{waive: []}} = waiving("c2")
      assert {:ok, %{waive: []}} = waiving(nil)

      log =
        capture_log(fn ->
          assert {:ok, %{waive: [%{check_id: "c1", reason: "First."}]}} =
                   waiving([%{"check_id" => "c1", "reason" => "First."}, %{"check_id" => "c1", "reason" => "Again."}, %{"check_id" => "c3"}, %{"reason" => "No check."}, "c4"])
        end)

      assert log =~ "`waive[3]` was dropped"
      assert log =~ "`waive[4]` was dropped"
      assert log =~ "`waive[5]` was dropped"

      many = for n <- 1..25, do: %{"check_id" => "c#{n}", "reason" => "Why."}
      assert {:ok, %{waive: kept}} = waiving(many)
      assert length(kept) == 20
    end
  end
end
