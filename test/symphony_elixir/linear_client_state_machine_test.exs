defmodule SymphonyElixir.LinearClientStateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  # Dispatch polls the tracker's active states plus the machine-owned phase states, for every repo.
  describe "per-repo dispatch states" do
    test "every repo polls the phase states on top of the active states" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        repos: [
          %{key: "app", workflow: Workflow.workflow_file_path(), default: true, team: "APP"},
          %{key: "web", workflow: Workflow.workflow_file_path(), team: "WEB"}
        ]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      phases = ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]
      assert poll_states_by_team() == %{"APP" => phases, "WEB" => phases}
    end

    test "Plan Review is never polled: it is a person's state" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        repos: [%{key: "default", workflow: Workflow.workflow_file_path(), default: true, team: "TEAM"}]
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      refute "Plan Review" in poll_states_by_team()["TEAM"]
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
