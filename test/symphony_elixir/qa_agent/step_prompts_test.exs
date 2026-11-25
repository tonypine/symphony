defmodule SymphonyElixir.QaAgent.StepPromptsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaAgent.{PromptTerms, Selection, StepPrompts, Steps}
  alias SymphonyElixir.QaDriver

  # Made-up definitions, so a test of the mechanism never depends on today's lists.
  @terms PromptTerms.terms(tools: ~w(qa_launch_app qa_click), statuses: ~w(pass fail unprovable), symphony_tools: ~w(qa_verdict), codes: ~w(qa_app_exited qa_worker_missing))

  defp build(source, terms \\ @terms, opts \\ []), do: PromptTerms.build!("priv/qa_steps/made_up/walk.md", source, terms, opts)

  describe "building a prompt refuses what the definitions do not hold" do
    test "a QA tool the driver does not serve, naming the prompt and the tool" do
      error = assert_raise ArgumentError, fn -> build("Drag the card with `qa_drag`.") end
      assert error.message =~ "priv/qa_steps/made_up/walk.md names `qa_drag`, which is not a QA tool the driver serves (qa_launch_app, qa_click)"

      # A tool Symphony serves, a code, and a family of codes are not tools the driver lacks.
      assert build("Call `qa_click`, then `qa_verdict`; `qa_app_exited` or any `qa_worker_*` is a harness fault.") =~ "`qa_verdict`"
      assert_raise ArgumentError, ~r/names `qa_helper_\*`/, fn -> build("Any `qa_helper_*` code.") end
    end

    test "a step status outside the status list, naming the prompt and the word" do
      error = assert_raise ArgumentError, fn -> build("Answer {{status:pass}} or {{status:passed}}.") end
      assert error.message == "priv/qa_steps/made_up/walk.md gives the step status `passed`, which is not one of `pass`, `fail` or `unprovable`"

      error = assert_raise ArgumentError, fn -> build("Answer {{statuses:pass}} or {{status}}.") end
      assert error.message =~ "priv/qa_steps/made_up/walk.md has the marker {{statuses:pass}}, which names no term"
      assert_raise ArgumentError, ~r/has the marker \{\{status\}\}, which names no term/, fn -> build("Answer {{status}}.") end
    end

    test "a window size written by hand, unless it is a text the app shows" do
      error = assert_raise ArgumentError, fn -> build("Walk it at 1440×900.") end
      assert error.message == "priv/qa_steps/made_up/walk.md states the window size 1440×900 by hand: a size comes from the QA target or the step's setting"

      # A quoted text is what the app shows; a marker the caller fills keeps the size out of the source.
      assert build(~s|The row reads "Clipped at 1440×900".|) =~ "1440×900"
      assert build("A {{target}} pt window.", @terms, keep: ~w(target)) == "A {{target}} pt window."
      assert_raise ArgumentError, ~r/has the marker \{\{target\}\}/, fn -> build("A {{target}} pt window.") end
    end
  end

  describe "a built prompt states the definitions" do
    test "the status list and the tool list come from the definitions: changing one changes the prompt" do
      source = "You have {{tools}}. Answer {{statuses}}; a harness fault is {{status:fail}}."
      assert build(source) == "You have `qa_launch_app`, `qa_click`. Answer `pass`, `fail` or `unprovable`; a harness fault is `fail`."

      more = %{@terms | tools: @terms.tools ++ ["qa_scroll"], statuses: ["pass", "fail"]}
      assert build(source, more) == "You have `qa_launch_app`, `qa_click`, `qa_scroll`. Answer `pass` or `fail`; a harness fault is `fail`."
      assert PromptTerms.status_list(["pass"]) == "`pass`"
    end

    test "the built-in terms are the driver's tools and the step statuses" do
      assert %{tools: tools, statuses: statuses, codes: codes} = PromptTerms.terms()
      assert tools == QaDriver.tools()
      assert statuses == Steps.statuses()
      assert codes == PromptTerms.codes()
    end

    test "the macOS step prompts and playbook are built: every tool the driver serves is listed, and no marker is left" do
      listed = Enum.map_join(QaDriver.tools(), ", ", &"`#{&1}`")
      playbook = Selection.playbooks(%{playbooks: %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}}}) |> Enum.find(&(&1.kind == "macos_app"))

      for {name, text} <- [{"walk", StepPrompts.prompt("macos_app", "walk")}, {"design_check", StepPrompts.prompt("macos_app", "design_check")}, {"playbook", playbook.prompt}] do
        assert text =~ listed, "#{name} does not list the driver's tools"
      end

      for id <- ~w(plan walk design_check review), do: refute(StepPrompts.prompt("macos_app", id) =~ "{{", id)
      refute playbook.prompt =~ "{{"
    end
  end
end
