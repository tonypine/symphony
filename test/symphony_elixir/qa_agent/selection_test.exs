defmodule SymphonyElixir.QaAgent.SelectionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.{RunStore, TicketEvents}

  @live_server %{paths: ["lib/**"], walkthrough_mentions: ["Director"]}
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

  defp record_proof!(issue_id, step) do
    payload = %{caption: "step #{step}", proof: %{step: step, test: "test/director_test.exs"}}
    {:ok, _event} = TicketEvents.record("repo-a", issue_id, "evidence", payload, actor: {:agent, "run-1", "implementation"})
  end

  test "a Director step no event proves asks for the live server, whatever the description's Proved by: line says", %{issue: issue} do
    assert {true, "the PR changes the server and the `## User walkthrough` names `Director`"} =
             Selection.live(issue, @live_server, @server_change, "make-all")
  end

  test "a Director step a recorded test proves is not QA's to walk, so it asks for no live server", %{issue: issue} do
    record_proof!(issue.id, 1)

    assert {false, "no `## User walkthrough` step names `Director`"} = Selection.live(issue, @live_server, @server_change, "make-all")

    # Without the repo's proof check the proof proves nothing, and QA walks the Director step.
    assert {true, _why} = Selection.live(issue, @live_server, @server_change, nil)
    assert {true, _why} = Selection.live(issue, @live_server, @server_change)
  end

  test "a recorded proof of every step leaves QA nothing to walk live", %{issue: issue} do
    record_proof!(issue.id, 1)
    record_proof!(issue.id, 2)

    assert {false, "a test recorded on the ticket proves every `## User walkthrough` step"} =
             Selection.live(issue, %{@live_server | walkthrough_mentions: []}, @server_change, "make-all")
  end

  test "a walkthrough with no numbered step is read whole", %{issue: issue} do
    issue = %{issue | description: "## User walkthrough\n\nOpen the Director and look around.\n"}
    assert {true, _why} = Selection.live(issue, @live_server, @server_change, "make-all")
  end

  test "the labels override the diff, and qa:fixture wins over qa:live", %{issue: issue} do
    assert {true, "the issue has the `qa:live` label"} = Selection.live(%{issue | labels: ["qa:live"]}, @live_server, [], "make-all")

    assert {false, "the issue has the `qa:fixture` label"} =
             Selection.live(%{issue | labels: ["qa:live", "qa:fixture"]}, @live_server, @server_change, "make-all")
  end

  test "a ticket without a walkthrough asks for no live server", %{issue: issue} do
    assert {false, "the ticket has no `## User walkthrough`"} =
             Selection.live(%{issue | description: "Directors' notes"}, @live_server, @server_change, "make-all")
  end

  test "a server that lists no mentions runs for any walked step", %{issue: issue} do
    assert {true, "the PR changes the server and the ticket has a `## User walkthrough`"} =
             Selection.live(issue, %{@live_server | walkthrough_mentions: []}, @server_change, "make-all")
  end

  test "a server-only change selects the macos_app playbook whose live server should run", %{issue: issue} do
    live = %{"start_cmd" => "scripts/qa-server-start.sh", "paths" => ["lib/**"], "walkthrough_mentions" => ["Director"]}
    macos_app = %{"build" => "make", "app" => "A.app", "paths" => ["macos/**"], "live" => live}
    playbooks = %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "auto_review" => %{"playbooks" => playbooks}})

    assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue, @server_change, settings.auto_review)
    assert {:skip, _reason} = Selection.decide(%{issue | labels: ["qa:fixture"]}, @server_change, settings.auto_review)
  end
end
