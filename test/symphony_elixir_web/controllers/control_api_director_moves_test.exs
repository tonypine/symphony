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
