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

  describe "steps/1" do
    test "a named test with backticks and the › separator" do
      assert [step] = Walkthrough.steps("1. Parse each step → the right proof. Proved by: `make-all` › `test/symphony_elixir/walkthrough_test.exs`.")

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

      assert [%{number: 2, text: step_text, proof: proof}] = Walkthrough.steps(text)
      assert step_text == "Install release N+1 over N\n   → the app restarts on N+1."
      assert proof == %{by: :test, check: "macos-e2e", test: ~s(update_restart_e2e.py scenario "installs while a run is active")}
    end

    test "a check without a test" do
      assert [%{proof: %{by: :test, check: "make-all", test: nil}} = step] = Walkthrough.steps("1. It builds. Proved by: `make-all`")
      assert Walkthrough.proof_line(step) == "Proved by: `make-all`"

      assert [%{proof: %{by: :test, check: "make-all", test: nil}}] = Walkthrough.steps("1. It builds. Proved by: make-all ›")
    end

    test "Proved by: QA, in any case and with a note" do
      assert [first, second, third] =
               Walkthrough.steps("""
               1. Open the window → it looks finished. Proved by: QA
               2. Open the menu → it reads right. proved by: qa (light mode only).
               3. Look at it. Proved by: `QA`
               """)

      for step <- [first, second, third] do
        assert step.proof == %{by: :qa}
        refute Walkthrough.named_test?(step)
        assert Walkthrough.proof_line(step) == "Proved by: QA"
      end

      assert first.text == "Open the window → it looks finished."
    end

    test "a step without the line, or with nothing after it, is a QA step" do
      assert [%{number: 1, text: "Click Save → saved.", proof: %{by: :qa}}, %{number: 2, text: "Undo.", proof: %{by: :qa}}] =
               Walkthrough.steps("1. Click Save → saved.\n2. Undo. Proved by:")
    end

    test "lines before the first step are not steps, and a step runs until the next one" do
      text = """
      Nothing changes on screen.

      1) First step
         - with a detail
             3. a deeper numbered line stays in the step
      2. Second step. Proved by: `make-all` › the playbook tests
      """

      assert [first, second] = Walkthrough.steps(text)
      assert first.number == 1
      assert first.text =~ "with a detail"
      assert first.text =~ "a deeper numbered line stays in the step"
      assert first.proof == %{by: :qa}
      assert second.proof == %{by: :test, check: "make-all", test: "the playbook tests"}
    end

    test "only the last Proved by: is the proof" do
      assert [%{text: text, proof: %{by: :qa}}] = Walkthrough.steps("1. Read where it says Proved by: x › y in the docs. Proved by: QA")
      assert text == "Read where it says Proved by: x › y in the docs."
    end

    test "no steps in empty text or without text" do
      assert Walkthrough.steps("Nothing changes on screen.") == []
      assert Walkthrough.steps(nil) == []
    end
  end
end
