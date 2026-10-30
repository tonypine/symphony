defmodule SymphonyElixir.LinearClientStateMachineTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  # Every repo polls the machine-owned phase states on top of the tracker's active states.
  describe "per-repo dispatch states" do
    test "every repo polls the active states and the phase states" do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        linear_tracker(
          repos: [%{key: "first_repo", workflow: Workflow.workflow_file_path(), default: true, team: "FIRST"}, %{key: "second_repo", workflow: Workflow.workflow_file_path(), team: "SECOND"}]
        )
      )

      assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun())

      states = poll_states_by_team()
      phase_states = ["Todo", "In Progress", "Waiting on sub-tickets", "Code Review", "QA", "Epic Review", "CI Fix"]
      assert states == %{"FIRST" => phase_states, "SECOND" => phase_states}
      refute "Plan Review" in states["FIRST"]
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
