defmodule SymphonyElixir.Conductor.AnswerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Conductor.Answer

  @question %{
    "title" => "The login step failed three times",
    "question" => "Should Symphony try another approach or wait for you?",
    "why" => "QA failed the same step three times.",
    "if_unanswered" => "The ticket stays paused.",
    "recommendation_reason" => "A fourth try would repeat the third.",
    "options" => [
      %{"label" => "Try another approach", "effect" => "The next rework starts over.", "recommended" => true},
      %{"label" => "Wait for me", "effect" => "Nothing runs until you say."}
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
               %{label: "Try another approach", effect: "The next rework starts over.", recommended: true},
               %{label: "Wait for me", effect: "Nothing runs until you say.", recommended: false}
             ]
           }
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

  test "reads the first answer that meets the schema among the turn's texts, else the first refusal" do
    assert {:ok, %{instructions: "Second."}} =
             Answer.read(["Here it is: ```json\n{\"instructions\": \"\"}\n```", "{\"instructions\": \"Second.\"}"])

    assert Answer.read(["{\"instructions\": \"\"}", "{\"update\": 1}"]) == {:error, "`instructions` is blank"}
    assert Answer.read(["no json here", ""]) == {:error, "the answer holds no JSON object"}
    assert Answer.read([]) == {:error, "the answer holds no JSON object"}
  end
end
