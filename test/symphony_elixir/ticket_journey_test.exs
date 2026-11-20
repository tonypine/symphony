defmodule SymphonyElixir.TicketJourneyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketJourney, TicketPlan}

  @repo_key "journey-repo"
  @issue_id "journey-issue"

  @outcome %{id: "c1", kind: "outcome", statement: "The page shows\nthe plan.", proof: "test"}
  @walk %{id: "c2", kind: "qa", statement: "The panel folds.", proof: "qa", state: "A groomed ticket", action: "Fold it", expect: "One line", size: "wide"}
  @attached %{id: "c3", kind: "evidence", statement: "The design was compared.", proof: "attached"}
  @design %{id: "c4", kind: "qa", statement: "The panel matches the design.", proof: "design", action: "Open it", expect: "It matches"}
  @plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["engine"],
    summary: "The ticket page shows the plan.",
    text: "Read the plan from the ledger and draw it.",
    checks: [@outcome, @walk, @attached, @design],
    size: %{tokens: 200_000, runs: 2}
  }

  @description """
  Intro.

  ## User walkthrough

  Nothing changes on screen.

  1. Open the page.
  2. Fold the panel.

  ## Acceptance criteria

  - It folds.
  """

  setup do
    :ok = RunStore.clear()
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "JRN-1"})
    :ok
  end

  defp issue(description \\ @description), do: %Issue{id: @issue_id, identifier: "JRN-1", description: description}
  defp plan!(plan \\ @plan), do: TicketPlan.write(@repo_key, @issue_id, plan) |> elem(1)
  defp prove!(proof), do: TicketChecks.prove(@repo_key, @issue_id, proof, actor: {:agent, "run-1", "implementation"}, head_sha: "abc1234") |> elem(1)

  defp proof!(step, test) do
    {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, "evidence", %{caption: "proof", proof: %{step: step, test: test}}, actor: {:agent, "run-1", "implementation"})
  end

  describe "a ticket that is not groomed" do
    test "is read from its description, as before plans" do
      refute TicketJourney.groomed?(issue())
      refute TicketJourney.groomed?(@issue_id)
      refute TicketJourney.groomed?(nil)
      refute TicketJourney.groomed?(%{id: nil})

      assert [%{number: 1, text: "Open the page.", proof: %{by: :qa}}, %{number: 2, text: "Fold the panel.", proof: %{by: :qa}}] = TicketJourney.steps(issue())
      assert TicketJourney.steps(issue("No walkthrough.")) == []
      assert TicketJourney.steps(nil) == []

      assert TicketJourney.journey(issue(), "make-all") == nil
      assert TicketJourney.plan_text(issue()) == nil
      assert TicketJourney.plan_text(nil) == nil
      assert TicketJourney.body(issue(), fn -> "the description" end) == "the description"
      refute TicketJourney.on_screen?(issue())
      refute TicketJourney.on_screen?(nil)
      assert TicketJourney.unproved(issue()) == []
      assert TicketJourney.unproved(nil) == []
      assert TicketJourney.record_walked(@repo_key, issue(), [%{name: "[c2] folds", status: :pass}]) == :ok
      assert TicketJourney.record_walked(@repo_key, nil, [%{name: "[c2] folds", status: :pass}]) == :ok
      assert RunStore.list_ticket_events(@issue_id, []) == []
    end

    test "its recorded proofs are laid over the walkthrough's steps" do
      proof!(2, "folds the panel")

      assert [%{number: 1, proof: %{by: :qa}}, %{number: 2, proof: %{by: :test, check: "make-all", test: "folds the panel"}}] = TicketJourney.steps(issue(), "make-all")
      assert [%{number: 2, text: "", proof: %{by: :test, check: "make-all"}}] = TicketJourney.proof_steps(issue(), "make-all")
      assert TicketJourney.proof_steps(issue(), nil) == []

      assert TicketJourney.walked_text(issue(), "make-all") == "Open the page."
      assert TicketJourney.walked_text(issue(), nil) == "Open the page.\nFold the panel."
      assert TicketJourney.walked_text(issue("## User walkthrough\n\nLook at it."), nil) == "Look at it."
      assert TicketJourney.walked_text(issue("Nothing."), nil) == nil
      assert TicketJourney.walked_text(nil, nil) == nil

      proof!(1, "opens the page")
      assert TicketJourney.walked_text(issue(), "make-all") == ""
    end

    test "whether it has a walkthrough and its acceptance list are the caller's to parse" do
      assert TicketJourney.walkthrough?(issue())
      refute TicketJourney.walkthrough?(issue("Nothing."))
      refute TicketJourney.walkthrough?(nil)
      refute TicketJourney.walkthrough?(issue(), fn _description -> false end)

      assert TicketJourney.acceptance(issue()) == []
      assert TicketJourney.acceptance(issue(), fn description -> [String.length(description)] end) == [String.length(@description)]
      assert TicketJourney.acceptance(nil, fn description -> [description] end) == [nil]
    end
  end

  describe "a groomed ticket" do
    setup do
      {:ok, _ask} = TicketPlan.record_ask(@repo_key, @issue_id, "Show the plan on the ticket page.\n")
      {:ok, _ask} = TicketPlan.record_ask(@repo_key, @issue_id, "And fold it.", source: "message")
      plan!()
      :ok
    end

    test "its QA checks are the steps, numbered by their place in the plan, and its description is not read" do
      assert TicketJourney.groomed?(issue())
      assert TicketJourney.groomed?(@issue_id)

      assert [
               %{number: 2, check_id: "c2", proof: %{by: :qa}, text: "[c2] The panel folds.\nState: A groomed ticket\nAction: Fold it\nExpect: One line\nSize: wide"},
               %{number: 4, check_id: "c4", proof: %{by: :qa}, text: "[c4] The panel matches the design.\nAction: Open it\nExpect: It matches"}
             ] = TicketJourney.steps(issue())

      assert TicketJourney.steps(@issue_id) == TicketJourney.steps(issue())
      assert TicketJourney.walkthrough?(issue("Nothing."))
      assert TicketJourney.walkthrough?(issue(), fn _description -> false end)
      assert TicketJourney.acceptance(issue(), fn _description -> ["read"] end) == ["[c1] The page shows the plan."]

      assert %{source: "the QA checks of the ticket's plan", text: text, steps: [%{number: 2}, %{number: 4}]} = TicketJourney.journey(issue(), nil)
      assert text =~ "2. [c2] The panel folds.\nState: A groomed ticket"
      assert text =~ "\n4. [c4] The panel matches the design."
      assert %{source: "the QA checks of the epic's plan"} = TicketJourney.journey(issue(), nil, "the epic")
    end

    test "a check a test proves is not walked, and the pre-check reads every test-proved check" do
      prove!(%{check_id: "c1", by: "test", test: "test/plan_test.exs › shows the plan"})
      prove!(%{check_id: "c2", by: "test", test: "test/plan_test.exs: folds"})
      prove!(%{check_id: "c3", by: "attached"})
      prove!(%{check_id: "c4", by: "qa"})

      assert [%{number: 2, check_id: "c2", proof: %{by: :test, check: "make-all", test: "test/plan_test.exs: folds"}}, %{number: 4, proof: %{by: :qa}}] =
               TicketJourney.steps(issue(), "make-all")

      assert [%{number: 2, proof: %{by: :qa}}, %{number: 4}] = TicketJourney.steps(issue(), nil)

      assert [
               %{number: 1, check_id: "c1", text: "[c1] The page shows the plan.", proof: %{by: :test, check: "make-all", test: "test/plan_test.exs › shows the plan"}},
               %{number: 2, check_id: "c2", proof: %{by: :test}}
             ] = TicketJourney.proof_steps(issue(), "make-all")

      assert TicketJourney.proof_steps(issue(), nil) == []
      assert TicketJourney.walked_text(issue(), "make-all") == "[c4] The panel matches the design.\nAction: Open it\nExpect: It matches"
    end

    test "a waived check is no step and no criterion, and a plan with no QA check has nothing to walk" do
      {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c1", "Nothing can test it.", by: :person)
      {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c2", "Nothing to fold.")

      assert [%{number: 4}] = TicketJourney.steps(issue())
      assert TicketJourney.acceptance(issue()) == []

      plan!(%{@plan | checks: [@outcome]})
      assert TicketJourney.steps(issue()) == []
      refute TicketJourney.walkthrough?(issue())
      assert TicketJourney.walked_text(issue(), "make-all") == nil
      assert %{text: "The plan names no QA check: no step is yours to walk.", steps: []} = TicketJourney.journey(issue(), nil)
    end

    test "the plan's layers say whether the change shows on screen" do
      refute TicketJourney.on_screen?(issue())
      plan!(%{@plan | layers: ["engine", "gallery"]})
      assert TicketJourney.on_screen?(issue())
      plan!(%{@plan | layers: ["screen"]})
      assert TicketJourney.on_screen?(@issue_id)
    end

    test "the prompt carries the ask, the plan and the checks" do
      prove!(%{check_id: "c1", by: "test", test: "plan_test.exs › shows the plan"})
      prove!(%{check_id: "c4", by: "design"})
      {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")

      assert TicketJourney.plan_text(issue()) == """
             ## Ask

             Show the plan on the ticket page.

             And fold it.

             ## Plan

             Read the plan from the ledger and draw it.

             ## Checks

             - [c1] outcome, proof: test, proved by test (plan_test.exs › shows the plan): The page shows the plan.
             - [c2] qa, proof: qa, open: The panel folds.
               State: A groomed ticket
               Action: Fold it
               Expect: One line
             - [c3] evidence, proof: attached, waived: The design was compared.
             - [c4] qa, proof: design, proved by design: The panel matches the design.
               Action: Open it
               Expect: It matches\
             """

      body = TicketJourney.body(issue(), fn -> flunk("the description is not read") end)
      assert body =~ "<linear_ticket_plan>\n## Ask"
      assert String.ends_with?(body, "</linear_ticket_plan>")
    end

    test "a plan with no ask and no check still reads" do
      :ok = RunStore.clear()
      plan!(%{@plan | checks: []})
      assert TicketJourney.plan_text(@issue_id) == "## Ask\n\nNo ask was recorded.\n\n## Plan\n\nRead the plan from the ledger and draw it.\n\n## Checks\n\nThe plan has no check."
    end

    test "check_proofs/2 takes a test for a check the plan proves by a test or an attachment" do
      assert TicketJourney.check_proofs(@issue_id, [%{"step" => " c1 ", "test" => " plan_test.exs › shows the plan "}, %{"check" => "c3", "test" => "attached_test.exs"}]) ==
               {:ok, [%{check_id: "c1", test: "plan_test.exs › shows the plan"}, %{check_id: "c3", test: "attached_test.exs"}]}

      unknown = [%{"check" => "c9", "test" => "x"}]
      assert {:error, {:invalid_walkthrough_proof, message}} = TicketJourney.check_proofs(@issue_id, unknown)
      assert message == "`c9` is not a check of this ticket's plan. Its checks are: c1, c2, c3, c4"

      assert {:error, {:invalid_walkthrough_proof, "check c2 is proved by QA (`proof: qa` in the plan): leave it for QA"}} =
               TicketJourney.check_proofs(@issue_id, [%{"check" => "c1", "test" => "x"}, %{"check" => "c2", "test" => "x"}])

      assert {:error, {:invalid_walkthrough_proof, "check c4 is proved by QA (`proof: design` in the plan): leave it for QA"}} =
               TicketJourney.check_proofs(@issue_id, [%{"check" => "c4", "test" => "x"}])

      for test <- ["  ", "a `b`", "a\nb"] do
        assert {:error, {:invalid_walkthrough_proof, "check c1: the test must be one non-blank line without backticks"}} =
                 TicketJourney.check_proofs(@issue_id, [%{"check" => "c1", "test" => test}])
      end

      for proof <- [%{"step" => 1, "test" => "x"}, %{"step" => "c1"}, "c1"] do
        assert {:error, {:invalid_walkthrough_proof, "this ticket has a plan: each proof needs the id of the check it proves as `step` (`c1`) and a string `test`"}} =
                 TicketJourney.check_proofs(@issue_id, [proof])
      end

      for proofs <- [[], nil, %{}] do
        assert {:error, {:invalid_walkthrough_proof, "`proofs` must be a non-empty list of objects, each with a check's id as `step` and a `test`"}} =
                 TicketJourney.check_proofs(@issue_id, proofs)
      end
    end

    test "record_walked/4 proves the checks QA saw pass, by their id in the step's name" do
      prove!(%{check_id: "c1", by: "test", test: "plan_test.exs"})
      {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")

      results = [
        %{name: "[c1] The page shows the plan", status: :pass, details: "Linked."},
        %{name: "Step 2 [c2] The panel folds", status: :pass, details: "It folded to one line."},
        %{name: "c3: compared", status: :pass, details: ""},
        %{name: "[c4] matches", status: :fail, details: "It does not."},
        %{name: "abc4d", status: :pass},
        %{status: :pass}
      ]

      opts = [actor: {:agent, "qa-1", "qa"}, run_id: "qa-1", head_sha: "def5678"]
      assert TicketJourney.record_walked(@repo_key, issue(), results, opts) == :ok

      assert [%{id: "c1", proved_by: %{by: "test"}}, %{id: "c2", state: :proved, proved_by: proved}, %{id: "c3", state: :waived}, %{id: "c4", state: :open}] = TicketChecks.list(@issue_id)
      assert %{by: "qa", details: "It folded to one line.", head: "def5678", run_id: "qa-1"} = proved

      assert TicketJourney.record_walked(@repo_key, issue(), [%{name: "[c4] matches", status: "pass"}], opts) == :ok
      assert %{state: :proved, proved_by: %{by: "design", details: nil}} = Enum.find(TicketChecks.list(@issue_id), &(&1.id == "c4"))

      # The same check on the same head is one proof.
      before = length(RunStore.list_ticket_events(@issue_id, types: ["check.proved"]))
      assert TicketJourney.record_walked(@repo_key, issue(), results, opts) == :ok
      assert length(RunStore.list_ticket_events(@issue_id, types: ["check.proved"])) == before
    end

    test "unproved/1 lists the open checks a test or an attachment proves, and its message names them" do
      assert [%{id: "c1"}, %{id: "c3"}] = unproved = TicketJourney.unproved(issue())
      message = TicketJourney.unproved_message(unproved)

      assert message =~ "The plan has 2 open check(s) that a test or an attachment proves, so the ticket is not handed off yet:"
      assert message =~ "- [c1] The page shows the plan. (proof: test)\n- [c3] The design was compared. (proof: attached)"
      assert message =~ "`linear_record_walkthrough_proofs` with the check's id as `step` and the test"
      assert message =~ "is waived by the Conductor after coding, with its reason"
      refute message =~ "—"

      prove!(%{check_id: "c1", by: "test", test: "plan_test.exs"})
      {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")
      assert TicketJourney.unproved(@issue_id) == []
    end
  end
end
