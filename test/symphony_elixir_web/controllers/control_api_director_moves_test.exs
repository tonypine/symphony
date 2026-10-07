defmodule SymphonyElixirWeb.ControlApiDirectorMovesTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{DirectorMoves, SubIssueWait}
  alias SymphonyElixirWeb.ControlApiController

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test("Waiting on sub-tickets")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "plan", identifier: "MOT-30", title: "Plan an MVP", state: "Human Review", labels: ["plan"]},
      %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "In Review", labels: []},
      %Issue{id: "verify", identifier: "MOT-50", title: "Final verification: Plan an MVP", state: "In Review"}
    ])

    server = :"director_moves_api_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: server})
    %{moves: [server: server]}
  end

  test "each move answers with the states it moved between", %{moves: moves} do
    for {action, params, identifier, to_state} <- [
          {:approve_plan, %{}, "MOT-30", "Waiting on sub-tickets"},
          {:approve_pr, %{}, "MOT-40", "Merging"},
          {:rework, %{"reason" => "Totals are wrong"}, "MOT-40", "Rework"},
          {:decisions, %{"picks" => [%{"question" => "Where?", "answer" => "B"}]}, "MOT-30", "In Review"},
          {:sign_off, %{}, "MOT-50", "Done"},
          {:backlog, %{"note" => "Later"}, "MOT-40", "Backlog"}
        ] do
      conn = post(action, Map.put(params, "issue_identifier", identifier), moves)

      assert conn.status == 200
      assert %{"move" => move, "issue_identifier" => ^identifier, "to_state" => ^to_state} = Jason.decode!(conn.resp_body)
      assert move == Atom.to_string(action)
    end
  end

  test "undo takes the last move back", %{moves: moves} do
    assert post(:approve_pr, %{"issue_identifier" => "MOT-40"}, moves).status == 200
    merging = %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "Merging"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [merging])

    conn = post(:undo, %{"issue_identifier" => "MOT-40"}, moves)

    assert conn.status == 200
    assert %{"move" => "undo", "undone" => "approve_pr", "to_state" => "In Review"} = Jason.decode!(conn.resp_body)
    assert error(post(:undo, %{"issue_identifier" => "MOT-40"}, moves)) == {409, "move_not_allowed", "there is no move on MOT-40 to undo"}
  end

  test "undo of an approval GitHub won't turn auto-merge off for is a 502 that leaves the ticket in Merging", %{moves: moves} do
    pr_url = "https://github.com/example/repo/pull/40"
    in_review = %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "In Review", pr_urls: [pr_url]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [in_review])
    moves = [github: __MODULE__.RefusingGitHub] ++ moves
    assert post(:approve_pr, %{"issue_identifier" => "MOT-40"}, moves).status == 200
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{in_review | state: "Merging"}])

    assert error(post(:undo, %{"issue_identifier" => "MOT-40"}, moves)) ==
             {502, "github_error", "GitHub refused to turn auto-merge off on #{pr_url} (:forbidden); MOT-40 stays in Merging"}

    refute_received {:memory_tracker_state_update, "pr", "In Review"}
  end

  defmodule RefusingGitHub do
    def fetch_activity(_pr_url, _opts), do: {:ok, %{state: "OPEN", auto_merge_enabled: true, pr_node_id: "PR_node"}}
    def disable_auto_merge(_pr_url, _pr_node_id, _opts), do: {:error, :forbidden}
  end

  test "a move the ticket's state doesn't allow is a 409", %{moves: moves} do
    assert error(post(:approve_pr, %{"issue_identifier" => "MOT-30"}, moves)) ==
             {409, "move_not_allowed", "MOT-30 is a plan; approve_pr is for a pull request"}
  end

  test "a missing identifier, reason or picks is a 422", %{moves: moves} do
    for action <- [:approve_plan, :approve_pr, :rework, :decisions, :sign_off, :backlog, :undo] do
      assert error(post(action, %{"issue_identifier" => " "}, moves)) == {422, "invalid_request", "issue_identifier is required"}
    end

    assert error(post(:rework, %{"issue_identifier" => "MOT-40"}, moves)) == {422, "invalid_request", "reason is required"}

    for picks <- [nil, "B", [%{"question" => "Where?"}], ["B"]] do
      assert {422, "invalid_request", _message} = error(post(:decisions, %{"issue_identifier" => "MOT-30", "picks" => picks}, moves))
    end
  end

  test "an unknown ticket is a 404 and a Linear failure a 502", %{moves: moves} do
    assert error(post(:approve_pr, %{"issue_identifier" => "MOT-404"}, moves)) == {404, "issue_not_found", "MOT-404 was not found in Linear"}

    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})
    assert error(post(:approve_pr, %{"issue_identifier" => "MOT-40"}, moves)) == {502, "linear_error", "Linear request failed: :boom"}
  end

  test "a move Linear took only half of is a 502 that says what was done", %{moves: moves} do
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :boom}])

    assert error(post(:decisions, %{"issue_identifier" => "MOT-30", "picks" => [%{"question" => "Where?", "answer" => "B"}]}, moves)) ==
             {502, "move_incomplete", "moved MOT-30 to In Review, but Linear refused the decisions comment (:boom); send the decisions again"}
  end

  defp post(action, params, moves) do
    conn(:post, "/api/v1/control/#{action}", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> assign(:director_moves, moves)
    |> assign(:orchestrator, :no_orchestrator_in_this_test)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> then(&apply(ControlApiController, action, [&1, params]))
  end

  defp error(conn) do
    %{"error" => %{"code" => code, "message" => message}} = Jason.decode!(conn.resp_body)
    {conn.status, code, message}
  end
end
