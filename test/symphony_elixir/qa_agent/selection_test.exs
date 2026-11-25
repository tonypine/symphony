defmodule SymphonyElixir.QaAgent.SelectionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.Verification

  @server_change ["lib/symphony_elixir/questions.ex"]
  @walkthrough """
  ## User walkthrough

  1. In the Director, press Decide on the held ticket. Proved by: `test/director_test.exs`
  2. Run `symphony status`.
  """

  setup do
    :ok = RunStore.clear()
    issue_id = "issue-selection-#{System.unique_integer([:positive])}"
    {:ok, issue: %Issue{id: issue_id, identifier: "TP-1", labels: [], description: @walkthrough}}
  end

  defp groom!(issue_id, checks) do
    :ok = RunStore.put_ticket_state(%{repo_key: "repo-a", issue_id: issue_id, issue_identifier: "TP-1"})

    plan = %{
      reason: "Grooming",
      by: "grooming",
      shape: "single",
      layers: ["engine"],
      summary: "The Director shows the decision.",
      text: "Draw the decision in the Director.",
      checks: checks,
      size: %{tokens: 100_000, runs: 1}
    }

    {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", issue_id, plan)
    :ok
  end

  @live %{source: "live", page: "Home", window: %{width: 1440, height: 900}, appearance: "light"}
  @fixture %{source: "fixture", fixture: "macos/Tests/Fixtures/director-app", page: "Inbox", window: %{width: 2560, height: 1440}, appearance: "dark"}
  @outcome %{id: "c1", kind: "outcome", statement: "The decision is stored.", proof: "test"}

  defp qa_check(id, statement, setting) do
    check = %{id: id, kind: "qa", statement: statement, proof: "qa", action: "Open it", expect: "It shows"}
    if setting, do: Map.put(check, :setting, setting), else: check
  end

  test "a QA check QA walks that is set to the live server makes the pass live, whatever its words", %{issue: issue} do
    groom!(issue.id, [@outcome, qa_check("c2", "The Home screen shows the decision after the move.", @live)])
    assert Selection.user_walkthrough?(%{issue | description: nil})
    assert {true, "the plan's QA check c2 is set to the live server"} = Selection.live(issue)

    groom!(issue.id, [@outcome, qa_check("c2", "The Home screen moves.", @live), qa_check("c3", "The list moves.", @fixture), qa_check("c4", "It stays.", @live)])
    assert {true, "the plan's QA checks c2, c4 are set to the live server"} = Selection.live(issue)
  end

  test "no word in a step makes a pass live: QA checks set to a fixture read fixtures only", %{issue: issue} do
    groom!(issue.id, [@outcome, qa_check("c2", "In the Director's Inbox, press Decide.", @fixture)])
    assert {false, "no QA check of the plan that QA walks is set to the live server"} = Selection.live(issue)

    # A ticket with no plan, whatever its walkthrough names, gets fixtures only.
    other = %{issue | id: issue.id <> "-ungroomed"}
    assert {false, "the ticket has no plan, so no QA check is set to the live server"} = Selection.live(other)
  end

  test "a live QA check that QA no longer walks, waived or proved by a recorded test, does not make the pass live", %{issue: issue} do
    groom!(issue.id, [@outcome, qa_check("c2", "The Home screen moves.", @live), qa_check("c3", "The list moves.", @live)])
    assert {true, "the plan's QA checks c2, c3 are set to the live server"} = Selection.live(issue)

    proof = %{check_id: "c2", by: "test", test: "test/director_test.exs"}
    {:ok, _event} = SymphonyElixir.TicketChecks.prove("repo-a", issue.id, proof, actor: {:agent, "run-1", "implementation"})
    assert {true, "the plan's QA check c3 is set to the live server"} = Selection.live(issue)

    {:ok, _event} = SymphonyElixir.TicketChecks.waive("repo-a", issue.id, "c3", "Covered elsewhere.")
    assert {false, "no QA check of the plan that QA walks is set to the live server"} = Selection.live(issue)
  end

  test "a plan whose QA checks carry no setting reads fixtures only", %{issue: issue} do
    groom!(issue.id, [@outcome, qa_check("c2", "The Director shows the decision.", nil)])
    assert Selection.user_walkthrough?(issue)
    assert {false, "no QA check of the plan that QA walks is set to the live server"} = Selection.live(issue)

    groom!(issue.id, [@outcome])
    refute Selection.user_walkthrough?(issue)
    assert {false, "no QA check of the plan that QA walks is set to the live server"} = Selection.live(issue)
  end

  test "the labels override the plan, and qa:fixture wins over qa:live", %{issue: issue} do
    assert {true, "the issue has the `qa:live` label"} = Selection.live(%{issue | labels: ["qa:live"]})

    groom!(issue.id, [@outcome, qa_check("c2", "The Home screen moves.", @live)])
    assert {false, "the issue has the `qa:fixture` label"} = Selection.live(%{issue | labels: ["qa:live", "qa:fixture"]})
  end

  test "a change outside its paths selects the macos_app playbook when the plan sets a QA check on the live server", %{issue: issue} do
    dev_server = %{"start_cmd" => "scripts/qa-server-start.sh", "health_check_url" => "http://127.0.0.1:8090/api/v1/state", "runs" => "live_qa_pass"}
    macos_app = %{"build" => "make", "app" => "A.app", "paths" => ["macos/**"]}
    playbooks = %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}

    assert {:ok, settings} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "verification" => %{"dev_server" => dev_server}, "auto_review" => %{"playbooks" => playbooks}})

    opts = Verification.selection_opts(settings)

    # The walkthrough names the Director, but no plan sets the server: nothing selects the app.
    assert {:skip, _reason} = Selection.decide(issue, @server_change, settings.auto_review, opts)

    groom!(issue.id, [@outcome, qa_check("c2", "The Home screen moves.", @live)])
    assert {:run, [%{kind: "macos_app", live_server: true}]} = Selection.decide(issue, @server_change, settings.auto_review, opts)
    assert {:skip, _reason} = Selection.decide(%{issue | labels: ["qa:fixture"]}, @server_change, settings.auto_review, opts)

    # A server that runs on another rule gives the playbook no live server, and nothing selects it.
    for runs <- ["symphony_host", "every_qa_pass"] do
      {:ok, other} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "verification" => %{"dev_server" => %{dev_server | "runs" => runs}}, "auto_review" => %{"playbooks" => playbooks}})
      assert {:skip, _reason} = Selection.decide(issue, @server_change, other.auto_review, Verification.selection_opts(other))
    end
  end

  test "no setting of the macos_app playbook matches words or paths to start the server: the old keys are refused" do
    for {key, value} <- [{"live", %{"start_cmd" => "start", "walkthrough_mentions" => ["Director"], "paths" => ["lib/**"]}}, {"dev_server", true}] do
      macos_app = %{"build" => "make", "app" => "A.app", key => value}
      assert {:error, message} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "auto_review" => %{"playbooks" => %{"macos_app" => macos_app}}})
      assert inspect(message) =~ "auto_review.playbooks.macos_app.#{key} is gone"
    end
  end
end
