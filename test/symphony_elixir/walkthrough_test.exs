defmodule SymphonyElixir.WalkthroughTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Walkthrough

  describe "section/1" do
    test "returns the walkthrough's body up to the next heading" do
      description = """
      ## Why

      Because.

      ## User walkthrough

      Nothing changes on screen.

      1. Do a thing → see it.

      ## After release

      1. Check it on your own machine.
      """

      assert Walkthrough.section(description) == "Nothing changes on screen.\n\n1. Do a thing → see it."
    end

    test "is nil without the heading, with an empty section or without a description" do
      assert Walkthrough.section("## Acceptance criteria\n\n- works") == nil
      assert Walkthrough.section("## User walkthrough\n\n## After release\n") == nil
      assert Walkthrough.section(nil) == nil
    end
  end

  describe "steps/2" do
    test "a named test with backticks and the › separator" do
      assert [step] = Walkthrough.steps("1. Parse each step → the right proof. Proved by: `make-all` › `test/symphony_elixir/walkthrough_test.exs`.", "make-all")

      assert step == %{
               number: 1,
               text: "Parse each step → the right proof.",
               proof: %{by: :test, check: "make-all", test: "test/symphony_elixir/walkthrough_test.exs"}
             }

      assert Walkthrough.named_test?(step)
      assert Walkthrough.proof_line(step) == "Proved by: `make-all` › test/symphony_elixir/walkthrough_test.exs"
    end

    test "a named test written plainly with a > separator, on its own line" do
      text = """
      2. Install release N+1 over N
         → the app restarts on N+1.
         Proved by: macos-e2e > update_restart_e2e.py scenario "installs while a run is active"
      """

      assert [%{number: 2, text: step_text, proof: proof}] = Walkthrough.steps(text, "make-all")
      assert step_text == "Install release N+1 over N\n   → the app restarts on N+1."
      assert proof == %{by: :test, check: "macos-e2e", test: ~s(update_restart_e2e.py scenario "installs while a run is active")}
    end

    test "a test alone is a test the repo's proof check runs" do
      assert [step] = Walkthrough.steps("1. Write a step → it parses. Proved by: `test/symphony_elixir/walkthrough_test.exs`.", " make-all ")

      assert step.proof == %{by: :test, check: "make-all", test: "test/symphony_elixir/walkthrough_test.exs"}
      assert step.text == "Write a step → it parses."
      assert Walkthrough.proof_line(step) == "Proved by: `make-all` › test/symphony_elixir/walkthrough_test.exs"

      assert [%{proof: %{by: :test, check: "make-all", test: ~s(scenario "installs while a run is active")}}] =
               Walkthrough.steps(~s(1. Install it.\n   Proved by: scenario "installs while a run is active"), "make-all")
    end

    test "without a proof check every step is a QA step, whatever its line says" do
      text = """
      1. Log in. Proved by: `make-all` › test/login_test.exs
      2. Log out. Proved by: test/logout_test.exs
      3. Look at it. Proved by: QA
      4. Sign up.
      """

      for proof_check <- [nil, "", "  "] do
        steps = Walkthrough.steps(text, proof_check)

        assert Enum.map(steps, & &1.proof) == List.duplicate(%{by: :qa}, 4)
        assert Enum.map(steps, & &1.text) == ["Log in.", "Log out.", "Look at it.", "Sign up."]
      end
    end

    test "a check without a test" do
      assert [%{proof: %{by: :test, check: "make-all", test: nil}} = step] = Walkthrough.steps("1. It builds. Proved by: `make-all`", "make-all")
      assert Walkthrough.proof_line(step) == "Proved by: `make-all`"

      assert [%{proof: %{by: :test, check: "make-all", test: nil}}] = Walkthrough.steps("1. It builds. Proved by: make-all ›", "make-all")
      assert [%{proof: %{by: :test, check: "Make-All", test: nil}}] = Walkthrough.steps("1. It builds. Proved by: make-all", "Make-All")
    end

    test "Proved by: QA, in any case and with a note" do
      assert [first, second, third] =
               Walkthrough.steps(
                 """
                 1. Open the window → it looks finished. Proved by: QA
                 2. Open the menu → it reads right. proved by: qa (light mode only).
                 3. Look at it. Proved by: `QA`
                 """,
                 "make-all"
               )

      for step <- [first, second, third] do
        assert step.proof == %{by: :qa}
        refute Walkthrough.named_test?(step)
        assert Walkthrough.proof_line(step) == "Proved by: QA"
      end

      assert first.text == "Open the window → it looks finished."

      assert [%{proof: %{by: :qa}}, %{proof: %{by: :qa}}] =
               Walkthrough.steps("1. One. Proved by: `QA`: desktop only.\n2. Two. Proved by: QA - dark mode", "make-all")
    end

    test "a check whose name starts with qa is a named test, not QA" do
      assert [first, second, third, fourth] =
               Walkthrough.steps(
                 """
                 1. Log in. Proved by: `qa-e2e` › login
                 2. Log out. Proved by: QA suite › logout
                 3. Sign up. Proved by: qa_smoke
                 4. Reset. Proved by: QA (smoke) > reset
                 """,
                 "make-all"
               )

      assert first.proof == %{by: :test, check: "qa-e2e", test: "login"}
      assert second.proof == %{by: :test, check: "QA suite", test: "logout"}
      assert third.proof == %{by: :test, check: "make-all", test: "qa_smoke"}
      assert fourth.proof == %{by: :test, check: "QA (smoke)", test: "reset"}
      assert Enum.all?([first, second, third, fourth], &Walkthrough.named_test?/1)
    end

    test "a step without the line, or with nothing after it, is a QA step" do
      assert [%{number: 1, text: "Click Save → saved.", proof: %{by: :qa}}, %{number: 2, text: "Undo.", proof: %{by: :qa}}] =
               Walkthrough.steps("1. Click Save → saved.\n2. Undo. Proved by:", "make-all")
    end

    test "lines before the first step are not steps, and a step runs until the next one" do
      text = """
      Nothing changes on screen.

      1) First step
         - with a detail
             3. a deeper numbered line stays in the step
      2. Second step. Proved by: `make-all` › the playbook tests
      """

      assert [first, second] = Walkthrough.steps(text, "make-all")
      assert first.number == 1
      assert first.text =~ "with a detail"
      assert first.text =~ "a deeper numbered line stays in the step"
      assert first.proof == %{by: :qa}
      assert second.proof == %{by: :test, check: "make-all", test: "the playbook tests"}
    end

    test "only the last Proved by: is the proof" do
      assert [%{text: text, proof: %{by: :qa}}] = Walkthrough.steps("1. Read where it says Proved by: x › y in the docs. Proved by: QA", "make-all")
      assert text == "Read where it says Proved by: x › y in the docs."
    end

    test "no steps in empty text or without text" do
      assert Walkthrough.steps("Nothing changes on screen.", "make-all") == []
      assert Walkthrough.steps(nil, "make-all") == []
    end
  end

  describe "record_proofs/2" do
    @description """
    ## Goal

    Plain steps. Proved by: nothing here, this is the goal.

    ## User walkthrough

    Nothing changes on screen.

    1. Write a ticket. Expected: it is saved.
    2. Push the branch.
       Expected: the steps end with their proofs.
       Proved by: `ci` › test/old_test.exs

    3. Look at the menu. Expected: it looks finished. Proved by: QA
    4. Reach QA. Expected: QA links the tests.

    ## After release

    1. Check it on your own machine.
    """

    test "appends a proof to a step without one and replaces a test proof, leaving every other byte" do
      assert {:ok, description} =
               Walkthrough.record_proofs(@description, [
                 %{"step" => 1, "test" => " test/symphony_elixir/walkthrough_test.exs "},
                 %{"step" => 2, "test" => ~s(scenario "pushes the branch")}
               ])

      assert description ==
               String.replace(@description, "1. Write a ticket. Expected: it is saved.\n", "1. Write a ticket. Expected: it is saved. Proved by: `test/symphony_elixir/walkthrough_test.exs`\n")
               |> String.replace("   Proved by: `ci` › test/old_test.exs\n", ~s(   Proved by: `scenario "pushes the branch"`\n))

      assert [first, second, third, fourth] = description |> Walkthrough.section() |> Walkthrough.steps("make-all")
      assert first.proof == %{by: :test, check: "make-all", test: "test/symphony_elixir/walkthrough_test.exs"}
      assert second.proof == %{by: :test, check: "make-all", test: ~s(scenario "pushes the branch")}
      assert third.proof == %{by: :qa}
      assert fourth.proof == %{by: :qa}
    end

    test "the last step of the section, and a step written a second time, keep the section's shape" do
      assert {:ok, once} = Walkthrough.record_proofs(@description, [%{"step" => 4, "test" => "test/a_test.exs"}])
      assert {:ok, twice} = Walkthrough.record_proofs(once, [%{"step" => 4, "test" => "test/b_test.exs"}])

      assert twice =~ "4. Reach QA. Expected: QA links the tests. Proved by: `test/b_test.exs`\n\n## After release\n\n1. Check it on your own machine.\n"
      refute twice =~ "test/a_test.exs"

      assert {:ok, last} = Walkthrough.record_proofs("## User walkthrough\n\n1. Do it.", [%{"step" => 1, "test" => "test/a_test.exs"}])
      assert last == "## User walkthrough\n\n1. Do it. Proved by: `test/a_test.exs`"
    end

    test "refuses a check name, a QA proof, a step the walkthrough lacks and an author's Proved by: QA" do
      for {proofs, message} <- [
            {[%{"step" => 1, "test" => "make-all › test/x_test.exs"}], "name the test only, never a check"},
            {[%{"step" => 1, "test" => "ci > test/x_test.exs"}], "name the test only, never a check"},
            {[%{"step" => 1, "test" => "QA"}], "`QA` is not a test"},
            {[%{"step" => 1, "test" => "`test/x_test.exs`"}], "one non-blank line without backticks"},
            {[%{"step" => 1, "test" => " "}], "one non-blank line without backticks"},
            {[%{"step" => 1, "test" => "a\nb"}], "one non-blank line without backticks"},
            {[%{"step" => 0, "test" => "test/x_test.exs"}], "positive integer `step`"},
            {[%{"step" => "1", "test" => "test/x_test.exs"}], "positive integer `step`"},
            {[], "non-empty list"},
            {nil, "non-empty list"},
            {[%{"step" => 9, "test" => "test/x_test.exs"}], "the walkthrough has no step 9"},
            {[%{"step" => 1, "test" => "test/x_test.exs"}, %{"step" => 3, "test" => "test/y_test.exs"}], "step 3 ends with `Proved by: QA`"}
          ] do
        assert {:error, {:invalid_walkthrough_proof, error}} = Walkthrough.record_proofs(@description, proofs)
        assert error =~ message
      end
    end

    test "refuses a description without a walkthrough" do
      for description <- ["## Goal\n\n1. Not a walkthrough.", nil] do
        assert {:error, {:invalid_walkthrough_proof, "the description has no `## User walkthrough` section"}} =
                 Walkthrough.record_proofs(description, [%{"step" => 1, "test" => "test/x_test.exs"}])
      end

      assert {:error, {:invalid_walkthrough_proof, "the walkthrough has no step 1"}} =
               Walkthrough.record_proofs("## User walkthrough", [%{"step" => 1, "test" => "test/x_test.exs"}])
    end
  end
end
