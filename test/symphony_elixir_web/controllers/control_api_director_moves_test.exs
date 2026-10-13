defmodule SymphonyElixirWeb.ControlApiDirectorMovesTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{DirectorMoves, Hold, SubIssueWait}
  alias SymphonyElixirWeb.ControlApiController

  defmodule UnwritableStore do
    def get_ticket_state(repo_key, issue_id), do: SymphonyElixir.RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test("Waiting on sub-tickets")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "plan", identifier: "MOT-30", title: "Plan an MVP", state: "Human Review", labels: ["plan"]},
      %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "In Review", labels: []}
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
          {:backlog, %{"note" => "Later"}, "MOT-40", "Backlog"}
        ] do
      conn = post(action, Map.put(params, "issue_identifier", identifier), moves)

      assert conn.status == 200
      assert %{"move" => move, "issue_identifier" => ^identifier, "to_state" => ^to_state} = Jason.decode!(conn.resp_body)
      assert move == Atom.to_string(action)
    end
  end

  test "unblock clears an access hold in place, and refuses one that isn't an access hold", %{moves: moves} do
    held = %Issue{id: "held", identifier: "MOT-60", title: "Blocked work", state: "In Progress", repo_key: "repo-api"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])
    :ok = Hold.set("repo-api", "held", :blocked, %{waits_on: %{type: "access"}})

    conn = post(:unblock, %{"issue_identifier" => "MOT-60"}, moves)

    assert conn.status == 200
    assert %{"move" => "unblock", "moved" => false, "from_state" => "In Progress", "to_state" => "In Progress"} = Jason.decode!(conn.resp_body)
    refute Hold.held?("repo-api", "held", :blocked)

    assert error(post(:unblock, %{"issue_identifier" => "MOT-60"}, moves)) ==
             {409, "move_not_allowed", "MOT-60 is not waiting on an access hold"}
  end

  test "decide answers a held ticket in place, and a redirecting answer moves it through the guard", %{moves: moves} do
    held = %Issue{id: "held", identifier: "MOT-60", title: "Needs a call", state: "In Progress", repo_key: "repo-api"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])
    :ok = Hold.set("repo-api", "held", :needs_decision, %{reason: "Add it?", clearing_condition: "when the decision is recorded", decision: %{title: "Add it"}})

    params = %{
      "issue_identifier" => "MOT-60",
      "request_comment_id" => "comment-1",
      "picks" => [%{"question" => "Add it?", "answer" => "Add it"}]
    }

    conn = post(:decide, params, moves)

    assert conn.status == 200
    assert %{"move" => "decide", "moved" => false, "from_state" => "In Progress", "to_state" => "In Progress"} = Jason.decode!(conn.resp_body)
    assert_received {:memory_tracker_reply, "held", "comment-1", body}
    assert body =~ "Decision from the Director:"
    refute Hold.held?("repo-api", "held", :needs_decision)
    refute_received {:memory_tracker_state_update, _issue_id, _state}

    # The same answer as a redirect directs the move, which goes through the guard.
    :ok = Hold.set("repo-api", "held", :needs_decision, %{reason: "Add it?"})

    conn = post(:decide, Map.merge(params, %{"request_comment_id" => "comment-2", "move" => "rework", "picks" => [%{"question" => "Add it?", "answer" => "Send it back"}]}), moves)

    assert conn.status == 200
    assert %{"move" => "decide", "moved" => true, "to_state" => "Rework"} = Jason.decode!(conn.resp_body)
    assert_received {:memory_tracker_state_update, "held", "Rework"}

    assert error(post(:decide, params, moves)) == {409, "move_not_allowed", "MOT-60 is not waiting on a decision"}
  end

  test "Continue to QA on a Code Review escalation moves the ticket into QA; an unconfigured target is a 422 that keeps the hold", %{moves: moves} do
    held = %Issue{id: "held", identifier: "MOT-60", title: "Escalated", state: "Code Review", repo_key: "repo-api"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])

    params = %{
      "issue_identifier" => "MOT-60",
      "request_comment_id" => "comment-1",
      "picks" => [%{"question" => "How should MOT-60 continue?", "answer" => "1"}]
    }

    :ok = Hold.set("repo-api", "held", :needs_decision, escalation_hold(""))

    assert error(post(:decide, params, moves)) ==
             {422, "invalid_request", "MOT-60's decision moves it to a state not configured for repo repo-api; the hold stays"}

    assert Hold.held?("repo-api", "held", :needs_decision)
    refute_received {:memory_tracker_reply, _issue_id, _parent, _body}

    :ok = Hold.set("repo-api", "held", :needs_decision, escalation_hold("QA"))
    conn = post(:decide, params, moves)

    assert conn.status == 200
    assert %{"move" => "decide", "moved" => true, "from_state" => "Code Review", "to_state" => "QA"} = Jason.decode!(conn.resp_body)
    assert_received {:memory_tracker_state_update, "held", "QA"}
    refute Hold.held?("repo-api", "held", :needs_decision)
  end

  defp escalation_hold(qa_state) do
    %{
      reason: "How should MOT-60 continue?",
      clearing_condition: "when the decision is recorded",
      decision: %{
        title: "Code Review escalated MOT-60",
        options: [
          %{label: "Continue to #{qa_state}", effect: "the ticket moves to #{qa_state} and its QA run starts"},
          %{label: "Send to Rework", effect: "the ticket moves to Rework with these reasons"}
        ],
        confirm: qa_state
      }
    }
  end

  test "a hold the store refuses to clear is a 502", %{moves: moves} do
    held = %Issue{id: "held", identifier: "MOT-60", title: "Blocked work", state: "In Progress", repo_key: "repo-api"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [held])
    :ok = Hold.set("repo-api", "held", :blocked, %{waits_on: %{type: "access"}})

    assert error(post(:unblock, %{"issue_identifier" => "MOT-60"}, [store: UnwritableStore] ++ moves)) ==
             {502, "store_error", "couldn't clear the hold on MOT-60: :boom"}
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

  test "restart resets the ticket and moves it to In Progress", %{moves: moves} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      repos: [[key: "designed", workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]]
    )

    pr_url = "https://github.com/example/repo/pull/40"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "Rework", pr_urls: [pr_url], repo_key: "designed"}
    ])

    conn =
      post(
        :restart,
        %{"issue_identifier" => "MOT-40", "reason" => "The approach is wrong"},
        [github: __MODULE__.OpenGitHub, workspace: __MODULE__.FakeWorkspace] ++ moves
      )

    assert conn.status == 200
    assert %{"move" => "restart", "from_state" => "Rework", "to_state" => "In Progress"} = Jason.decode!(conn.resp_body)
    assert_received {:memory_tracker_state_update, "pr", "In Progress"}
  end

  test "a restart on a legacy repo is a 409", %{moves: moves} do
    assert error(post(:restart, %{"issue_identifier" => "MOT-40", "reason" => "No"}, moves)) ==
             {409, "move_not_allowed", "MOT-40 is on the legacy state machine, where Rework already closes the pull request and starts over"}
  end

  test "a reset GitHub refuses is a 502 restart_incomplete", %{moves: moves} do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      repos: [[key: "designed", workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]]
    )

    pr_url = "https://github.com/example/repo/pull/40"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: "Rework", pr_urls: [pr_url]}
    ])

    assert error(
             post(
               :restart,
               %{"issue_identifier" => "MOT-40", "reason" => "No"},
               [github: __MODULE__.RefusingCloseGitHub, workspace: __MODULE__.FakeWorkspace] ++ moves
             )
           ) ==
             {502, "restart_incomplete", "MOT-40 was not restarted: GitHub refused to close #{pr_url} (:forbidden)"}
  end

  defmodule OpenGitHub do
    def fetch_activity(_pr_url, _opts), do: {:ok, %{state: "OPEN"}}
    def close(_pr_url, _opts), do: :ok
  end

  defmodule RefusingCloseGitHub do
    def fetch_activity(_pr_url, _opts), do: {:ok, %{state: "OPEN"}}
    def close(_pr_url, _opts), do: {:error, :forbidden}
  end

  defmodule FakeWorkspace do
    def remove_issue_workspaces_checked(_issue), do: :ok
  end

  test "a missing identifier, reason, picks or request comment is a 422", %{moves: moves} do
    actions = [
      :approve_plan,
      :approve_pr,
      :rework,
      :restart,
      :decisions,
      :backlog,
      :unblock,
      :decide,
      :undo
    ]

    for action <- actions do
      assert error(post(action, %{"issue_identifier" => " "}, moves)) == {422, "invalid_request", "issue_identifier is required"}
    end

    assert error(post(:rework, %{"issue_identifier" => "MOT-40"}, moves)) == {422, "invalid_request", "reason is required"}
    assert error(post(:restart, %{"issue_identifier" => "MOT-40"}, moves)) == {422, "invalid_request", "reason is required"}

    for picks <- [nil, "B", [%{"question" => "Where?"}], ["B"]] do
      assert {422, "invalid_request", _message} = error(post(:decisions, %{"issue_identifier" => "MOT-30", "picks" => picks}, moves))
    end

    # A decision names the request it answers; only picks and the request are required.
    assert {422, "invalid_request", _message} = error(post(:decide, %{"issue_identifier" => "MOT-60"}, moves))

    assert error(post(:decide, %{"issue_identifier" => "MOT-60", "picks" => [%{"question" => "Where?", "answer" => "B"}]}, moves)) ==
             {422, "invalid_request", "request_comment_id is required"}
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
