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
    long = String.duplicate("a", Answer.instructions_max() + 1)

    for {answer, why} <- [
          {"[1]", "the answer is not a JSON object"},
          {"{not json", "the answer is not valid JSON"},
          {json(%{}), "`instructions` must be a string"},
          {json(%{"instructions" => " "}), "`instructions` is blank"},
          {json(%{"instructions" => long}), "`instructions` is over 2000 characters"},
          {json(%{"instructions" => "x", "update" => 3}), "`update` must be a string or null"},
          {json(%{"instructions" => "x", "update" => String.duplicate("u", Answer.update_max() + 1)}), "`update` is over 900 characters"},
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
          {%{"steer" => %{"message" => String.duplicate("s", 1_501), "when" => "now"}}, "`steer.message` is over 1500 characters"},
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
