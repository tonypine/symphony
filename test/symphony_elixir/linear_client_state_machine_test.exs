defmodule SymphonyElixir.LinearClientStateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  # Dispatch reads each repo's own resolved state machine: a `designed` repo polls the machine-owned
  # phase states on top of the tracker's active states, a `legacy` repo polls exactly the active ones.
  describe "per-repo dispatch states" do
    test "a designed repo polls the phase states and a legacy repo does not" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        repos: [
          %{key: "legacy_repo", workflow: Workflow.workflow_file_path(), default: true, team: "LEGACY", state_machine: "legacy"},
          %{key: "designed_repo", workflow: Workflow.workflow_file_path(), team: "DESIGNED", state_machine: "designed"}
        ]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      states = poll_states_by_team()
      assert states["LEGACY"] == ["Todo", "In Progress", "Waiting on sub-tickets"]

      assert states["DESIGNED"] ==
               ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]
    end

    test "a designed repo never polls Plan Review, even when the active states name it" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_active_states: ["Todo", "Plan Review"],
        repos: [
          %{key: "legacy_repo", workflow: Workflow.workflow_file_path(), default: true, team: "LEGACY", state_machine: "legacy"},
          %{key: "designed_repo", workflow: Workflow.workflow_file_path(), team: "DESIGNED", state_machine: "designed"}
        ]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      states = poll_states_by_team()
      assert "Plan Review" in states["LEGACY"]
      refute "Plan Review" in states["DESIGNED"]
      assert "QA" in states["DESIGNED"]
    end

    test "a repo with no state_machine set polls the active states, unchanged" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        repos: [%{key: "default", workflow: Workflow.workflow_file_path(), default: true, team: "TEAM"}]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      assert poll_states_by_team() == %{"TEAM" => ["Todo", "In Progress", "Waiting on sub-tickets"]}
    end
  end

  # Records each poll's operation and variables, and answers with an empty issue page.
  defp graphql_fun do
    parent = self()

    fn query, variables ->
      [_match, operation] = Regex.run(~r/^\s*query\s+(\w+)/, query)
      send(parent, {:linear_query, operation, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
         }
       }}
    end
  end

  # The states each repo's poll filtered on, keyed by the team the repo routes to.
  defp poll_states_by_team do
    receive do
      {:linear_query, "SymphonyLinearPoll", _query, %{filter: filter}} ->
        team = get_in(filter, ["team", "key", "eq"])
        Map.put(poll_states_by_team(), team, get_in(filter, ["state", "name", "in"]))
    after
      0 -> %{}
    end
  end
end
