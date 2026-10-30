defmodule SymphonyElixir.DirectorMovesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AuditLog, BlockedHold, CiWait}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{DecisionRequest, DirectorMoves, DispatchLoop, Hold}
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.{OperatorStop, Pauses, PlanComments, Questions, RunStore, SelfHeal, SubIssueWait, TicketState}

  @waiting "Waiting on sub-tickets"

  defmodule MissingStateTracker do
    def workflow_state_exists?(_state, _teams), do: {:ok, false}
  end

  defmodule FakeGitHub do
    def fetch_activity(pr_url, _opts) do
      send(self(), {:fetch_activity, pr_url})
      Application.fetch_env!(:symphony_elixir, :director_moves_test_activity)
    end

    def close(pr_url, _opts) do
      send(self(), {:close_pr, pr_url})
      Application.get_env(:symphony_elixir, :director_moves_test_close, :ok)
    end
  end

  defmodule FakeWorkspace do
    def remove_issue_workspaces_checked(issue) do
      send(self(), {:remove_workspaces, issue.identifier})
      Application.get_env(:symphony_elixir, :director_moves_test_workspace, :ok)
    end
  end

  defmodule CannedLinearClient do
    def fetch_issue_by_identifier(_identifier), do: Application.fetch_env!(:symphony_elixir, :director_moves_test_fetch)
  end

  defmodule UnsettableStore do
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
  end

  defmodule UnwritableStore do
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def put_own_state_move(_issue_id, _at), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    audit_dir = Path.join(System.tmp_dir!(), "director-moves-audit-#{System.unique_integer([:positive])}")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    server = :"director_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: server})
    clock = :counters.new(1, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :director_moves_test_activity)
      Application.delete_env(:symphony_elixir, :director_moves_test_close)
      Application.delete_env(:symphony_elixir, :director_moves_test_workspace)
      SubIssueWait.reset_for_test(@waiting)
      restore_app_env(:audit_log_dir, previous_audit_dir)
      File.rm_rf(audit_dir)
    end)

    %{opts: [server: server, clock: fn -> :counters.get(clock, 1) end, github: FakeGitHub], clock: clock}
  end

  describe "approve_plan" do
    test "moves a plan in Plan Review to the waiting state and writes an audit record", %{opts: opts} do
      put_issues([plan("Plan Review")])

      assert {:ok, result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      assert result == %{
               move: "approve_plan",
               issue_id: "plan",
               issue_identifier: "MOT-30",
               from_state: "Plan Review",
               to_state: @waiting,
               moved: true,
               commented: false,
               undo_window_ms: 10_000
             }

      assert_received {:memory_tracker_state_update, "plan", @waiting}
      refute_received {:memory_tracker_comment, _id, _body}

      assert [%{"move" => "approve_plan", "issue_identifier" => "MOT-30", "from_state" => "Plan Review", "to_state" => @waiting}] =
               audit_records()
    end

    test "records the move's signal in the ticket's signals ledger", %{opts: opts} do
      RunStore.delete_ticket_state("repo-director", "plan")
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])

      assert {:ok, _result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      assert [%{name: "decision returned", details: %{move: "approve_plan", from: "Plan Review", to: @waiting}}] =
               RunStore.get_ticket_state("repo-director", "plan").signals

      # The Director's move is also a person action on the ticket's events, next to its audit record.
      assert [%{actor: %{kind: :person, name: "the Director"}, payload: payload} = event] =
               RunStore.list_ticket_events("repo-director", "plan", types: ["person.action"])

      assert payload == %{action: "move", move: "approve_plan", from: "Plan Review", to: @waiting}
      assert event.summary.title == "The Director moved the ticket to #{@waiting}"
      assert [%{"move" => "approve_plan"}] = audit_records()
    end

    test "asks for a cycle on the plan's repo at once, so its first sub-ticket dispatches on the next one", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])

      assert {:ok, _result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, Keyword.put(opts, :orchestrator, self()))

      assert_received {:"$gen_cast", {:request_refresh, "repo-director", :now}}
    end

    test "refuses a plan outside Plan Review, a ticket that is not a plan, and a turned-off waiting state", %{opts: opts} do
      put_issues([plan("In Progress"), pr("Plan Review"), %{plan(nil) | id: "stateless", identifier: "MOT-31"}])
      assert {:error, {:conflict, message}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert message == "MOT-30 is In Progress; the Director answers it only from Plan Review"
      assert {:error, {:conflict, "MOT-31 is in no state; the Director answers it only from Plan Review"}} = DirectorMoves.move(:approve_plan, "MOT-31", %{}, opts)
      assert {:error, {:conflict, "MOT-40 is not a plan; approve_plan is for a plan"}} = DirectorMoves.move(:approve_plan, "MOT-40", %{}, opts)

      put_issues([plan("Plan Review")])
      settings = Config.settings!()
      disable = fn -> :disabled = SubIssueWait.check_tracker_state(settings, [], tracker: MissingStateTracker) end
      capture_log(disable)
      assert {:error, {:conflict, "the waiting state is turned off" <> _}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      refute_received {:memory_tracker_state_update, _id, _state}
      assert audit_records() == []
    end

    test "refuses every plan while the Plan Review state is turned off", %{opts: opts} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_plan_review_state: nil)
      put_issues([plan("Plan Review")])

      assert {:error, {:conflict, "the Plan Review state is turned off, so the Director can't answer MOT-30 from the app"}} =
               DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
    end
  end

  describe "rework" do
    test "posts the reason, then rejects a plan from Plan Review", %{opts: opts} do
      put_issues([plan("Plan Review")])

      assert {:ok, %{to_state: "Rework", commented: true}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "  Split MOT-31 differently  "}, opts)
      assert_received {:memory_tracker_comment, "plan", "Sent to Rework by the Director:\n\nSplit MOT-31 differently"}
      assert_received {:memory_tracker_state_update, "plan", "Rework"}
      assert [%{"move" => "rework", "comment" => "Sent to Rework by the Director:\n\nSplit MOT-31 differently"}] = audit_records()
    end

    test "needs a reason and a plan in Plan Review", %{opts: opts} do
      put_issues([pr("In Progress")])

      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "  "}, opts)
      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:rework, "MOT-40", %{}, opts)
      assert {:error, {:conflict, _message}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)
      refute_received {:memory_tracker_comment, _id, _body}
    end
  end

  describe "restart" do
    @restart_pr_url "https://github.com/example/repo/pull/40"

    defp restart_opts(opts) do
      Keyword.merge(opts, github: FakeGitHub, workspace: FakeWorkspace)
    end

    # A ticket routed to its repo, whose PR Symphony's record holds open.
    defp restart_issue(fields \\ []) do
      :ok = SymphonyElixir.TicketPullRequest.record_created("repo-restart", "pr", @restart_pr_url, "auto/MOT-40")
      struct(%{pr("Rework") | repo_key: "repo-restart"}, fields)
    end

    test "closes the pull request, removes the workspace and moves the ticket to In Progress", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])

      assert {:ok, result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "  The approach is wrong  "}, restart_opts(opts))

      assert result == %{
               move: "restart",
               issue_id: "pr",
               issue_identifier: "MOT-40",
               from_state: "Rework",
               to_state: "In Progress",
               moved: true,
               commented: true,
               undo_window_ms: nil
             }

      assert_received {:fetch_activity, @restart_pr_url}
      assert_received {:close_pr, @restart_pr_url}
      assert_received {:remove_workspaces, "MOT-40"}

      assert_received {:memory_tracker_comment, "pr", comment}
      assert comment =~ "Restarted by the Director: MOT-40 starts again from main"
      assert comment =~ "The approach is wrong"

      assert_received {:memory_tracker_state_update, "pr", "In Progress"}

      assert [%{"move" => "restart", "from_state" => "Rework", "to_state" => "In Progress"}] = audit_records()
    end

    test "records the restart in the ticket's signals ledger", %{opts: opts} do
      github_activity(state: "OPEN")
      RunStore.delete_ticket_state("repo-restart", "pr")
      put_issues([restart_issue()])

      assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      assert [%{name: "restart", details: %{move: "restart", from: "Rework", to: "In Progress"}}] =
               RunStore.get_ticket_state("repo-restart", "pr").signals

      assert ticket_events("repo-restart", "pr", "person.action") == [{"person.action", %{action: "restart", from: "Rework", to: "In Progress"}}]
    end

    test "clears a dispatch-loop hold, so the ticket starts again with its count at zero", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])
      :ok = RunStore.record_ticket_dispatch("repo-restart", "pr", %{kind: :rework, run_id: "run-1", state: "Rework"})
      :ok = Hold.set("repo-restart", "pr", :blocked, %{reason: "dispatch_loop: 4 rework runs", waits_on: %{type: "dispatch_loop", keys: ["rework"]}})

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      refute Hold.held?("repo-restart", "pr", :blocked)
      assert RunStore.get_ticket_state("repo-restart", "pr").dispatches == []
    end

    test "lifts an operator's stop, so the ticket the Director stopped runs again from main", %{opts: opts} do
      put_issues([%{pr("Todo") | repo_key: "repo-restart"}])
      stop("repo-restart")

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "Start over"}, restart_opts(opts))
      refute Hold.held?("repo-restart", "pr", :blocked)
      refute OperatorStop.held?("repo-restart", "pr")

      assert [{"pause.cleared", %{by: %{kind: :person, name: "Director"}}}] = ticket_events("repo-restart", "pr", "pause.cleared")

      stop("repo-restart")

      log =
        capture_log(fn ->
          assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, opts |> restart_opts() |> Keyword.put(:store, UnwritableStore))
        end)

      assert log =~ "Restarted MOT-40 but couldn't clear its operator-stop hold: :boom"
    end

    test "lifts a stop paused beside a dispatch-loop hold, and clears that hold too", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-restart"}])
      :ok = Hold.set("repo-restart", "pr", :blocked, %{reason: "dispatch_loop: 4 runs", waits_on: %{type: "dispatch_loop", keys: ["implementation"]}})
      stop("repo-restart")
      assert %{waits_on: %{type: "dispatch_loop"}} = Hold.get("repo-restart", "pr", :blocked)

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "Start over"}, restart_opts(opts))
      refute OperatorStop.held?("repo-restart", "pr")
      refute Hold.held?("repo-restart", "pr", :blocked)
    end

    test "leaves any other Blocked hold, and stands when the store refuses to clear the loop's", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-restart"}])
      :ok = Hold.set("repo-restart", "pr", :blocked, %{waits_on: %{type: "access"}})

      assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert Hold.held?("repo-restart", "pr", :blocked)

      :ok = Hold.set("repo-restart", "pr", :blocked, %{waits_on: %{type: "dispatch_loop", keys: ["implementation"]}})

      log =
        capture_log(fn ->
          assert {:ok, %{to_state: "In Progress"}} =
                   DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, opts |> restart_opts() |> Keyword.put(:store, UnwritableStore))
        end)

      assert log =~ "Restarted MOT-40 but couldn't clear its dispatch-loop hold: :boom"
      assert Hold.held?("repo-restart", "pr", :blocked)
    end

    test "a ticket with no pull request restarts just the same", %{opts: opts} do
      put_issues([pr("In Progress")])

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert_received {:remove_workspaces, "MOT-40"}
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
    end

    test "a restart can't be undone: it closed the pull request and removed the workspace", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])

      assert {:ok, %{to_state: "In Progress", undo_window_ms: nil}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      put_issues([%{restart_issue() | state: "In Progress"}])

      assert {:error, {:conflict, message}} = DirectorMoves.undo("MOT-40", restart_opts(opts))

      assert message ==
               "MOT-40 was restarted; the pull request is closed and the workspace is gone, so it can't be undone"

      refute_received {:memory_tracker_state_update, "pr", "Rework"}
    end

    test "a terminal ticket is refused", %{opts: opts} do
      put_issues([%{restart_issue() | state: "Done"}])

      assert {:error, {:conflict, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert message == "MOT-40 is Done; only an open ticket can be restarted"
      refute_received {:remove_workspaces, _identifier}
    end

    test "needs a reason", %{opts: opts} do
      put_issues([restart_issue()])

      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "  "}, restart_opts(opts))
      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:restart, "MOT-40", %{}, restart_opts(opts))
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a reset GitHub refuses stops the move, so nothing is half-done", %{opts: opts} do
      github_activity(state: "OPEN")
      Application.put_env(:symphony_elixir, :director_moves_test_close, {:error, :forbidden})
      put_issues([restart_issue()])

      assert {:error, {:restart, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      assert message == "MOT-40 was not restarted: GitHub refused to close #{@restart_pr_url} (:forbidden)"
      refute_received {:memory_tracker_state_update, _id, _state}
      refute_received {:memory_tracker_comment, _id, _body}
      refute_received {:remove_workspaces, _identifier}
      assert audit_records() == []
    end

    test "a workspace that cannot be removed stops the move", %{opts: opts} do
      github_activity(state: "OPEN")
      Application.put_env(:symphony_elixir, :director_moves_test_workspace, {:error, :busy})
      put_issues([restart_issue()])

      assert {:error, {:restart, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      assert message == "MOT-40 was not restarted: couldn't remove the workspace of MOT-40 ({:error, :busy})"
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a move Linear refuses after the reset is a partial move", %{opts: opts} do
      github_activity(state: "OPEN")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :state_failed})
      put_issues([restart_issue()])

      assert {:error, {:partial, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert message =~ "MOT-40"
      assert_received {:memory_tracker_comment, "pr", _body}
      assert_received {:close_pr, @restart_pr_url}
    end

    test "the restart comment says what the reset did" do
      assert DirectorMoves.restart_comment("MOT-40", "The approach is wrong") ==
               "Restarted by the Director: MOT-40 starts again from main — its pull requests are closed, its workspace is gone, " <>
                 "and the workpad's prior attempt is superseded.\n\nThe approach is wrong"
    end
  end

  describe "decisions" do
    test "posts one comment with the picks on a plan in Plan Review, then starts its revision", %{opts: opts} do
      put_issues([plan("Plan Review")])
      picks = [%{question: " Where are gift cards bought? ", answer: "B. In the app only"}, %{question: "Who pays?", answer: "A. The buyer"}]

      assert {:ok, %{moved: true, commented: true, from_state: "Plan Review", to_state: "Rework", undo_window_ms: nil}} =
               DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)

      assert_received {:memory_tracker_comment, "plan", body}

      assert body ==
               "Decisions on the plan, from the Director:\n\n1. Where are gift cards bought?\n   **Pick:** B. In the app only\n\n2. Who pays?\n   **Pick:** A. The buyer"

      assert_received {:memory_tracker_state_update, "plan", "Rework"}
      # The revision move is Symphony's own, so the plan's sub-tickets are kept.
      assert %DateTime{} = RunStore.get_own_state_move("plan")
      # Moving the plan back to review would leave the answers unapplied, so there is nothing to undo.
      put_issues([plan("Rework")])
      assert {:error, {:conflict, "there is no move on MOT-30 to undo"}} = DirectorMoves.undo("MOT-30", opts)
    end

    test "starts the revision on every round of answers, without waiting for the comment poll", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])

      for request <- ["q1", "q2"] do
        assert {:ok, %{to_state: "Rework"}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B", request_comment_id: request}]}, opts)
        assert_received {:memory_tracker_reply, "plan", ^request, _reply}
        assert_received {:memory_tracker_state_update, "plan", "Rework"}
      end

      # The ledger names what started each revision: the plan's verdict and the move into Rework.
      events = ticket_events("repo-director", "plan", ["verdict.recorded", "phase.entered", "person.action"])

      assert [
               {"verdict.recorded", %{kind: "plan_review", outcome: "changes"}},
               {"phase.entered", %{to: "Rework", from: "Plan Review", via: "decisions"}},
               {"person.action", %{action: "move", move: "decisions", from: "Plan Review", to: "Rework"}},
               {"verdict.recorded", _second_verdict},
               {"phase.entered", _second_move},
               {"person.action", _second_action}
             ] = events
    end

    test "an approved plan gets the answers in place: it is not revised from comments", %{opts: opts} do
      put_issues([%{plan("Plan Review") | sub_issues: [%{id: "s1", identifier: "MOT-31", state: "Todo"}]}])

      assert {:ok, %{moved: false, to_state: "Plan Review"}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B"}]}, opts)
      assert_received {:memory_tracker_comment, "plan", _body}
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a revision Linear refuses to start says so, and the answers stand", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])

      assert {:error, {:partial, message}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B", request_comment_id: "q1"}]}, opts)

      assert message ==
               "posted your answers on MOT-30, but Linear refused the move to Rework that starts the plan's revision (:state_failed); " <>
                 "MOT-30 stays in Plan Review with them not yet applied, so don't approve it yet"

      assert_received {:memory_tracker_reply, "plan", "q1", _reply}
      assert [%{"move" => "decisions", "from_state" => "Plan Review", "to_state" => "Plan Review", "failed" => "revise"}] = audit_records()
      assert ticket_events("repo-director", "plan", "verdict.recorded") == []
    end

    test "needs picks, on a plan in Plan Review", %{opts: opts} do
      put_issues([plan("Plan Review"), pr("Plan Review")])

      for input <- [%{}, %{picks: []}, %{picks: nil}, %{picks: [%{question: "Q", answer: " "}]}, %{picks: ["B"]}] do
        assert {:error, {:invalid, "picks must list each decision's question and answer"}} = DirectorMoves.move(:decisions, "MOT-30", input, opts)
      end

      assert {:error, {:conflict, "MOT-40 is not a plan; decisions is for a plan"}} =
               DirectorMoves.move(:decisions, "MOT-40", %{picks: [%{question: "Q", answer: "B"}]}, opts)
    end

    test "answers each of the plan's questions under its request, records them, and clears the hold, in place", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director", description: "Plan the MVP."}])
      :ok = Hold.set("repo-director", "plan", :needs_decision, %{reason: "Which currency?", decision: %{title: "Card currency", question: "Which currency?"}})

      picks = [
        %{question: "Where are gift cards bought?", answer: "In the checkout", request_comment_id: "q1"},
        %{question: "Which currency?", answer: " The buyer's, converted at checkout ", request_comment_id: "q2"}
      ]

      assert {:ok, %{move: "decisions", moved: true, commented: true, to_state: "Rework"}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)

      assert_received {:memory_tracker_reply, "plan", "q1", first}
      assert first == "Decision from the Director:\n\n1. Where are gift cards bought?\n   **Decision:** In the checkout"
      assert_received {:memory_tracker_reply, "plan", "q2", second}
      assert second =~ "**Decision:** The buyer's, converted at checkout"
      refute_received {:memory_tracker_comment, _id, _body}
      assert_received {:memory_tracker_state_update, "plan", "Rework"}

      # The answers are the ticket's decisions before the revision run reads it.
      assert_received {:memory_tracker_description_update, "plan", description}
      assert [%{key: "q1", answer: "In the checkout"}, %{key: "q2", answer: "The buyer's, converted at checkout"}] = SymphonyElixir.Decisions.recorded(description)
      refute Hold.held?("repo-director", "plan", :needs_decision)

      # The replies are the Director's comments on a plan under review: a reply written in Linear
      # starts the same revision through the comment poll.
      assert PlanComments.human?(%{bot?: false, body: first})
      assert [%{"move" => "decisions", "comment" => comment}] = audit_records()
      assert comment =~ "Where are gift cards bought?"
    end

    test "a pick with no request goes into the one decisions comment, next to the answered ones", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      picks = [%{question: "Q1", answer: "A", request_comment_id: "q1"}, %{question: "Q2", answer: "B", request_comment_id: " "}]

      assert {:ok, %{commented: true}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)
      assert_received {:memory_tracker_reply, "plan", "q1", _reply}
      assert_received {:memory_tracker_comment, "plan", "Decisions on the plan, from the Director:\n\n1. Q2\n   **Pick:** B"}
    end

    test "an answer Linear refuses stops the move with Linear's error", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :reply_failed}])

      assert {:error, {:linear, :reply_failed}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B", request_comment_id: "q1"}]}, opts)
      assert audit_records() == []
    end

    test "a hold the store refuses to clear is reported, and the answers stand", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "plan", :needs_decision, %{reason: "Q", decision: %{title: "Q", question: "Q"}})

      log =
        capture_log(fn ->
          assert {:ok, %{move: "decisions"}} =
                   DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B", request_comment_id: "q1"}]}, Keyword.put(opts, :store, UnwritableStore))
        end)

      assert log =~ "Failed to clear the Needs Decision hold on MOT-30 after its plan's answers"
      # The revision still starts: the store is best effort, as the comment poll's own record is.
      assert log =~ "Failed to record Symphony's own move of MOT-30 to revise its plan: :boom"
      assert_received {:memory_tracker_state_update, "plan", "Rework"}
      assert_received {:memory_tracker_reply, "plan", "q1", _reply}
    end

    test "a comment Linear refuses is Linear's error alone", %{opts: opts} do
      put_issues([plan("Plan Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :comment_failed}])
      assert {:error, {:linear, :comment_failed}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B"}]}, opts)
      refute_received {:memory_tracker_state_update, _id, _state}
      assert audit_records() == []
    end
  end

  describe "changes" do
    test "posts the Director's reason on a plan in Plan Review, then starts its revision, which keeps its sub-tickets", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])

      assert {:ok, %{move: "changes", moved: true, commented: true, to_state: "Rework", undo_window_ms: nil}} =
               DirectorMoves.move(:changes, "MOT-30", %{reason: "  Ask the questions in plain words  "}, opts)

      assert_received {:memory_tracker_comment, "plan", body}
      assert body == "Changes asked by the Director:\n\nAsk the questions in plain words"
      assert PlanComments.human?(%{bot?: false, body: body})
      assert_received {:memory_tracker_state_update, "plan", "Rework"}
      assert [%{"move" => "changes", "to_state" => "Rework"}] = audit_records()
      assert [{"phase.entered", %{via: "changes", to: "Rework"}}] = ticket_events("repo-director", "plan", "phase.entered")
    end

    test "a revision Linear refuses to start says the changes are posted but not applied", %{opts: opts} do
      put_issues([plan("Plan Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])

      assert {:error, {:partial, "posted your changes on MOT-30, but Linear refused the move to Rework" <> _rest}} =
               DirectorMoves.move(:changes, "MOT-30", %{reason: "x"}, opts)
    end

    test "needs a reason and a plan in Plan Review", %{opts: opts} do
      put_issues([plan("Waiting on sub-tickets"), pr("Plan Review")])

      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:changes, "MOT-30", %{reason: " "}, opts)
      assert {:error, {:conflict, "MOT-40 is not a plan; changes is for a plan"}} = DirectorMoves.move(:changes, "MOT-40", %{reason: "x"}, opts)
      assert {:error, {:conflict, _message}} = DirectorMoves.move(:changes, "MOT-30", %{reason: "x"}, opts)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [plan("Plan Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :comment_failed}])
      assert {:error, {:linear, :comment_failed}} = DirectorMoves.move(:changes, "MOT-30", %{reason: "x"}, opts)
    end
  end

  describe "a move Linear takes only half of" do
    test "a rework comment whose move Linear refuses is recorded, and not posted twice when sent again", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])

      assert {:error, {:partial, message}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "No"}, opts)

      assert message ==
               "posted the comment on MOT-30, but Linear refused the move to Rework (:state_failed); send it again to make the move without posting the comment twice"

      assert_received {:memory_tracker_comment, "plan", "Sent to Rework by the Director:\n\nNo"}

      assert [%{"move" => "rework", "from_state" => "Plan Review", "to_state" => "Plan Review", "comment" => "Sent to Rework by the Director:\n\nNo", "failed" => "move"}] =
               audit_records()

      # The person action matches its audit record: the ticket stayed where it was.
      assert ticket_events("repo-director", "plan", "person.action") == [{"person.action", %{action: "move", move: "rework", from: "Plan Review", to: "Plan Review"}}]

      assert {:ok, %{to_state: "Rework", commented: true}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "No"}, opts)
      refute_received {:memory_tracker_comment, _id, _body}
      assert_received {:memory_tracker_state_update, "plan", "Rework"}

      # Once the move went through, the same reason later is a new comment.
      assert {:ok, _result} = DirectorMoves.move(:rework, "MOT-30", %{reason: "No"}, opts)
      assert_received {:memory_tracker_comment, "plan", _body}
    end

    test "a different reason, or the ticket in another state, posts the comment again", %{opts: opts} do
      put_issues([pr("Code Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])
      assert {:error, {:partial, _message}} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Later"}, opts)
      assert_received {:memory_tracker_comment, "pr", _body}

      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Much later"}, opts)
      assert_received {:memory_tracker_comment, "pr", "Moved to Backlog by the Director:\n\nMuch later"}

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])
      assert {:error, {:partial, _message}} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Later"}, opts)
      assert_received {:memory_tracker_comment, "pr", _body}
      put_issues([pr("In Progress")])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Later"}, opts)
      assert_received {:memory_tracker_comment, "pr", "Moved to Backlog by the Director:\n\nLater"}
    end
  end

  describe "backlog" do
    test "posts the note when there is one, then moves an open ticket to Backlog", %{opts: opts} do
      put_issues([pr("In Progress")])

      assert {:ok, %{to_state: "Backlog", commented: true}} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Wait for the API"}, opts)
      assert_received {:memory_tracker_comment, "pr", "Moved to Backlog by the Director:\n\nWait for the API"}
      assert_received {:memory_tracker_state_update, "pr", "Backlog"}

      assert {:ok, %{commented: false}} = DirectorMoves.move(:backlog, "MOT-40", %{note: nil}, opts)
      refute_received {:memory_tracker_comment, _id, _body}

      # A ticket Linear gave no state is open too.
      put_issues([pr(nil)])
      assert {:ok, %{to_state: "Backlog"}} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
    end

    test "refuses a ticket already in Backlog or closed", %{opts: opts} do
      put_issues([pr("Backlog"), %{pr("Done") | id: "done", identifier: "MOT-41"}])

      assert {:error, {:conflict, "MOT-40 is already in Backlog"}} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      assert {:error, {:conflict, "MOT-41 is Done; only an open ticket moves to Backlog"}} = DirectorMoves.move(:backlog, "MOT-41", %{}, opts)
    end
  end

  describe "unblock" do
    test "clears an access hold in place and posts its comment", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])

      :ok =
        Hold.set("repo-director", "pr", :blocked, %{
          reason: "the run reported a block",
          clearing_condition: "when the block is resolved; a person clears an access hold",
          waits_on: %{type: "access", keys: []}
        })

      assert {:ok, result} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      assert result == %{
               move: "unblock",
               issue_id: "pr",
               issue_identifier: "MOT-40",
               from_state: "In Progress",
               to_state: "In Progress",
               moved: false,
               commented: true,
               undo_window_ms: nil
             }

      refute Hold.held?("repo-director", "pr", :blocked)
      refute_received {:memory_tracker_state_update, _id, _state}
      assert_received {:memory_tracker_comment, "pr", "Unblocked by the Director: MOT-40 continues in place."}
      assert [%{name: "unblocked", details: %{by: "the Director"}}] = RunStore.get_ticket_state("repo-director", "pr").signals
      assert [%{"move" => "unblock", "from_state" => "In Progress", "to_state" => "In Progress"}] = audit_records()

      # The hold's clear, then the Director's unblock as a person action.
      assert [
               {"hold.set", %{kind: "blocked"}},
               {"hold.cleared", %{kind: "blocked"}},
               {"person.action", %{action: "unblock", from: "In Progress", to: "In Progress"}}
             ] = ticket_events("repo-director", "pr")

      assert [%{actor: %{kind: :person, name: "the Director"}}] = RunStore.list_ticket_events("repo-director", "pr", types: ["person.action"])
    end

    test "QA that cannot reach its machine pauses the ticket on it; Unblock clears the hold and the reason, and the ticket resumes (TP-1250)", %{opts: opts} do
      issue = %{pr("QA") | repo_key: "repo-director"}
      put_issues([issue])
      ticket = {:ticket, "repo-director", "pr"}
      outcome = %{verdict: :blocked, cause: {:qa_worker, "qa_worker_unreachable"}, reason: "the QA host did not answer", needs_person: true}

      assert :held = SelfHeal.heal(issue, outcome: outcome, attempts: 2, repo_key: "repo-director")
      {:ok, _pause} = CiWait.pause("repo-director", "pr", "26758a2471558f89fc0411dcf1f81aa82c0e1dc4")
      {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "MOT-9"))

      assert Hold.held?("repo-director", "pr", :blocked)
      assert Pauses.why(ticket) == ["The QA machine is not reachable", "Waiting for CI on 26758a247155 to finish", "Waiting for MOT-9 to finish"]

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute Hold.held?("repo-director", "pr", :blocked)
      assert Pauses.why(ticket) == ["Waiting for MOT-9 to finish"]
      assert [%{payload: %{by: %{kind: :person, name: "Director"}}} | _] = RunStore.list_ticket_events("repo-director", "pr", types: ["pause.reason_cleared"])
    end

    test "clears a dispatch-loop hold in place, and the ticket's count starts again", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = RunStore.record_ticket_dispatch("repo-director", "pr", %{kind: :implementation, run_id: "run-1", state: "In Progress"})

      :ok =
        Hold.set("repo-director", "pr", :blocked, %{
          reason: "dispatch_loop: 4 implementation runs in 10 minutes",
          waits_on: %{type: "dispatch_loop", keys: ["implementation"]}
        })

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute Hold.held?("repo-director", "pr", :blocked)
      assert RunStore.get_ticket_state("repo-director", "pr").dispatches == []
      assert_received {:memory_tracker_comment, "pr", "Unblocked by the Director: MOT-40 continues in place."}
    end

    test "clears a landing hold in place after the PR watcher releases its competing PRs (TP-989)", %{opts: opts} do
      put_issues([%{pr("Merging") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, BlockedHold.landing_attrs([%{issue_identifier: "MOT-1", files: ["SPEC.md"]}]))
      test_pid = self()
      release = fn repo_key, issue_id, _opts -> send(test_pid, {:release, repo_key, issue_id}) && Process.get(:release_result, :ok) end

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.move(:unblock, "MOT-40", %{}, Keyword.put(opts, :release_competitors, release))
      assert_received {:release, "repo-director", "pr"}
      refute Hold.held?("repo-director", "pr", :blocked)

      # A release that fails is reported; the hold still clears.
      :ok = Hold.set("repo-director", "pr", :blocked, BlockedHold.landing_attrs([%{issue_identifier: "MOT-1", files: ["SPEC.md"]}]))
      Process.put(:release_result, {:error, :store_down})

      log = capture_log(fn -> assert {:ok, %{move: "unblock"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, Keyword.put(opts, :release_competitors, release)) end)
      assert log =~ "couldn't release its competing pull requests"
      refute Hold.held?("repo-director", "pr", :blocked)
    end

    test "lifts an operator's stop: its pause reason, then its hold, and the ticket continues in place", %{opts: opts} do
      put_issues([%{pr("Todo") | repo_key: "repo-director"}])
      stop("repo-director")

      assert {:ok, %{move: "unblock", moved: false, commented: true}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute OperatorStop.held?("repo-director", "pr")
      refute Hold.held?("repo-director", "pr", :blocked)
      assert_received {:memory_tracker_comment, "pr", "Unblocked by the Director: MOT-40 continues in place."}
      assert [{"pause.cleared", %{by: %{kind: :person, name: "Director"}}}] = ticket_events("repo-director", "pr", "pause.cleared")
    end

    test "lifts a stop paused beside a hold that clears on its own, and leaves that hold", %{opts: opts} do
      put_issues([%{pr("Todo") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{reason: "waiting on MOT-1", waits_on: %{type: "dependency", keys: ["MOT-1"]}})
      stop("repo-director")

      assert {:ok, %{move: "unblock"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute OperatorStop.held?("repo-director", "pr")
      assert %{waits_on: %{type: "dependency"}} = Hold.get("repo-director", "pr", :blocked)
    end

    test "lifts a stop paused beside an access hold together with that hold", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{reason: "Needs a token", waits_on: %{type: "access", keys: []}})
      stop("repo-director")

      assert {:ok, %{move: "unblock"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute OperatorStop.held?("repo-director", "pr")
      refute Hold.held?("repo-director", "pr", :blocked)
    end

    test "a stop whose hold the store refuses to clear comes back as a store error", %{opts: opts} do
      put_issues([%{pr("Todo") | repo_key: "repo-director"}])
      stop("repo-director")

      assert {:error, {:store, "couldn't clear the hold on MOT-40: :boom"}} =
               DirectorMoves.move(:unblock, "MOT-40", %{}, Keyword.put(opts, :store, UnwritableStore))

      assert Hold.held?("repo-director", "pr", :blocked)
    end

    test "refuses a ticket with no hold, and one waiting on something other than access", %{opts: opts} do
      put_issues([pr("In Progress")])
      assert {:error, {:conflict, "MOT-40 is not waiting on an access hold"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{reason: "waiting on MOT-1", waits_on: %{type: "dependency", keys: ["MOT-1"]}})

      assert {:error, {:conflict, "MOT-40 is not waiting on an access hold"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)
      assert Hold.held?("repo-director", "pr", :blocked)
      refute_received {:memory_tracker_comment, _id, _body}
      # A refused move is no action: no audit record, no event.
      assert audit_records() == []
      assert ticket_events("repo-director", "pr", "person.action") == []
    end

    test "the hold is cleared even when Linear refuses the comment", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{waits_on: %{type: "access"}})
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :comment_failed})

      log = capture_log(fn -> assert {:ok, %{commented: true}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts) end)

      assert log =~ "but Linear refused the comment"
      refute Hold.held?("repo-director", "pr", :blocked)
    end

    test "a hold the store refuses to clear comes back as a store error", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{waits_on: %{type: "access"}})

      assert {:error, {:store, "couldn't clear the hold on MOT-40: :boom"}} =
               DirectorMoves.move(:unblock, "MOT-40", %{}, Keyword.put(opts, :store, UnwritableStore))

      assert Hold.held?("repo-director", "pr", :blocked)
    end
  end

  describe "an answer from the Director writes the Question first (TP-1240)" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: "repo-director", workflow: Workflow.workflow_file_path(), team: "MOT"]]
      )

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
        :persistent_term.erase({SymphonyElixir.Inbox, :items, :director_moves_inbox})
      end)

      :ok
    end

    test "Decide answers the Question in the Director's own words, then replies and records the section", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director", description: "Add checkout."}])
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}
      pick = [%{question: signing_request().question, answer: "Sign them with the old key for now"}]

      assert {:ok, %{moved: false, commented: true, undo_window_ms: 10_000}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: pick, question_id: id, request_comment_id: "comment-1"}, opts)

      assert %{state: :answered, answer: %{text: "Sign them with the old key for now", option: nil, by: %{kind: :person, name: "Director"}, at: %DateTime{}}} =
               Questions.find(ticket, id)

      assert {:ok, nil} = Pauses.get(ticket)
      refute Hold.held?("repo-director", "pr", :needs_decision)
      # The ticket's timeline says so in the Director's words.
      assert [%{summary: %{title: "You answered: Sign them with the old key for now"}}] =
               RunStore.list_ticket_events("repo-director", "pr", types: ["question.answered"])

      assert_received {:memory_tracker_reply, "pr", "comment-1", reply}
      assert reply =~ "**Decision:** Sign them with the old key for now"
      assert_received {:memory_tracker_description_update, "pr", description}
      assert [%{key: "comment-1", answer: "Sign them with the old key for now"}] = SymphonyElixir.Decisions.recorded(description)

      # The Question is answered before Linear's reply records the decision under the request.
      types = "repo-director" |> RunStore.list_ticket_events("pr", []) |> Enum.map(& &1.type)
      assert Enum.find_index(types, &(&1 == "question.answered")) < Enum.find_index(types, &(&1 == "decision.recorded"))
    end

    test "with Linear down, Decide answers the Question and clears the hold; the reply waits on the record", %{opts: opts} do
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}
      # Linear reads nothing and refuses the reply: the ticket is read from its record.
      put_issues([])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})

      log =
        capture_log(fn ->
          assert {:ok, %{moved: false, commented: false, from_state: "In Progress"}} =
                   DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)
        end)

      assert log =~ "Linear refused the reply"
      assert %{state: :answered, answer: %{option: 1, text: "Add the secrets"}} = Questions.find(ticket, id)
      assert {:ok, nil} = Pauses.get(ticket)
      refute Hold.held?("repo-director", "pr", :needs_decision)
      refute_received {:memory_tracker_reply, _issue_id, _comment_id, _body}

      record = TicketState.normalize(RunStore.get_ticket_state("repo-director", "pr"))
      assert [{:question_answer, ^id, "comment-1"}] = for(mark <- record.pending_projection, mark.type == :question_answer, do: TicketState.projection_of(mark))

      # Linear answers again: the reply goes under the request and the answer into the section.
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
      put_issues([%{pr("In Progress") | repo_key: "repo-director", description: "Add checkout."}])

      assert :ok = DirectorMoves.project_answer("repo-director", "pr", id, "comment-1")
      assert_received {:memory_tracker_reply, "pr", "comment-1", reply}
      assert reply == "Decision from the Director:\n\n1. Add the signing secrets, or ship unsigned builds?\n   **Decision:** Add the secrets"
      assert_received {:memory_tracker_description_update, "pr", description}
      assert [%{key: "comment-1", title: "Add the release signing secrets", answer: "Add the secrets"}] = SymphonyElixir.Decisions.recorded(description)

      # With no request comment known, the reply is a comment on the ticket; a reply Linear refuses again stays pending.
      assert :ok = DirectorMoves.project_answer("repo-director", "pr", id, nil)
      assert_received {:memory_tracker_comment, "pr", "Decision from the Director:" <> _rest}
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})
      assert {:error, :linear_down} = DirectorMoves.project_answer("repo-director", "pr", id, "comment-1")
      # A question no longer answered has nothing to project.
      assert :ok = DirectorMoves.project_answer("repo-director", "pr", "q-none", "comment-1")
    end

    test "with Linear down and no request known, the refused comment is marked pending with no request", %{opts: opts} do
      id = ask_signing()
      put_issues([])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})

      capture_log(fn ->
        assert {:ok, %{commented: false}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id}, opts)
      end)

      record = TicketState.normalize(RunStore.get_ticket_state("repo-director", "pr"))
      assert [{:question_answer, ^id, nil}] = for(mark <- record.pending_projection, mark.type == :question_answer, do: TicketState.projection_of(mark))
    end

    test "the Inbox row names the Question and the request: either one finds the other", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}
      opts = Keyword.put(opts, :inbox, :director_moves_inbox)
      row = %{issue_id: "pr", kind: :action, review: %{comment_id: "comment-7", question_id: id}}
      :persistent_term.put({SymphonyElixir.Inbox, :items, :director_moves_inbox}, [%{issue_id: "other", review: %{}}, row])

      # By the Question alone: the reply goes under the request its row lists.
      assert {:ok, %{commented: true}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id}, opts)
      assert_received {:memory_tracker_reply, "pr", "comment-7", _reply}
      assert %{state: :answered} = Questions.find(ticket, id)
    end

    test "a request comment's row names the Question it answers, whatever the hold carries", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}
      # The hold moved on to a request that carries no Question; the row of the answered one names it.
      :ok = Hold.set("repo-director", "pr", :needs_decision, %{reason: "q", decision: %{title: "Add the release signing secrets", question: "q"}})
      opts = Keyword.put(opts, :inbox, :director_moves_inbox)
      :persistent_term.put({SymphonyElixir.Inbox, :items, :director_moves_inbox}, [%{issue_id: "pr", review: %{comment_id: "comment-1", question_id: id}}])

      assert {:ok, _result} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)
      assert %{state: :answered, answer: %{text: "Add the secrets"}} = Questions.find(ticket, id)
    end

    test "a Question the ticket doesn't have, or one already answered, is refused before anything is written", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()

      assert {:error, {:conflict, "MOT-40 has no question q-none"}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: "q-none"}, opts)
      refute_received {:memory_tracker_reply, _issue_id, _comment_id, _body}
      assert Hold.held?("repo-director", "pr", :needs_decision)

      {:ok, _answered} = Questions.answer({:ticket, "repo-director", "pr"}, id, "1")
      assert {:error, {:conflict, "MOT-40's question " <> _rest}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id}, opts)
    end

    test "a Question the store can't answer stops Send Decisions before any reply", %{opts: opts} do
      # A plan no repo routes has no record to answer on.
      put_issues([plan("Plan Review")])
      picks = [%{question: "Q", answer: "B", question_id: "q-1", request_comment_id: "comment-9"}]

      assert {:error, {:store, "couldn't answer the question on MOT-30: " <> _reason}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)
      refute_received {:memory_tracker_reply, _issue_id, _comment_id, _body}
    end

    test "Undo within its window reopens the Question, pauses the ticket on it and sets the hold again", %{opts: opts, clock: clock} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}

      assert {:ok, %{moved: false, undo_window_ms: 10_000}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id, request_comment_id: "comment-1"}, opts)
      refute Hold.held?("repo-director", "pr", :needs_decision)
      :counters.put(clock, 1, 9_000)

      assert {:ok, %{move: "undo", undone: "decide", from_state: "In Progress", to_state: "In Progress"}} = DirectorMoves.undo("MOT-40", opts)
      # Nothing moved, so nothing moves back.
      refute_received {:memory_tracker_state_update, "pr", _state}

      assert %{state: :open, answer: nil, reopened_at: %DateTime{}} = Questions.find(ticket, id)
      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: ^id}}]}} = Pauses.get(ticket)
      assert %{decision: %{question_id: ^id}} = Hold.get("repo-director", "pr", :needs_decision)
      assert "question.reopened" in Enum.map(RunStore.list_ticket_events("repo-director", "pr", []), & &1.type)

      # The answer given again is a new answer.
      assert {:ok, %{moved: false}} = DirectorMoves.move(:decide, "MOT-40", %{picks: [%{question: "Q", answer: "Ship unsigned"}], question_id: id}, opts)
      assert %{state: :answered, answer: %{option: 2}} = Questions.find(ticket, id)
      assert ["question.answered", "question.answered"] = for(%{type: "question.answered" = type} <- RunStore.list_ticket_events("repo-director", "pr", []), do: type)
    end

    test "Undo of a Decide that moved the ticket moves it back and reopens its Question", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()

      assert {:ok, %{to_state: "Rework", undo_window_ms: 10_000}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id, request_comment_id: "comment-1", move: "rework"}, opts)

      put_issues([%{pr("Rework") | repo_key: "repo-director"}])
      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.undo("MOT-40", opts)
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
      assert %{state: :open} = Questions.find({:ticket, "repo-director", "pr"}, id)
    end

    test "an Undo the store refuses says so", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()
      ticket = {:ticket, "repo-director", "pr"}
      assert {:ok, _result} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id, request_comment_id: "comment-1"}, opts)

      # Someone reopened it meanwhile: there is no answer to take back.
      {:ok, _reopened} = Questions.reopen(ticket, id)
      assert {:error, {:store, "couldn't reopen the question on MOT-40: {:question_not_answered, :open}"}} = DirectorMoves.undo("MOT-40", opts)
    end

    test "an Undo whose hold the store won't set again says so, with the Question reopened", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      id = ask_signing()
      assert {:ok, _result} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), question_id: id, request_comment_id: "comment-1"}, opts)

      assert {:error, {:store, "reopened the question on MOT-40 but couldn't set its hold again: :boom"}} =
               DirectorMoves.undo("MOT-40", Keyword.put(opts, :store, UnsettableStore))

      assert %{state: :open} = Questions.find({:ticket, "repo-director", "pr"}, id)
    end

    test "Send Decisions answers each pick's Question before its reply", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      issue = %{id: "plan", state: "Plan Review", repo_key: "repo-director"}
      assert :ok = DecisionRequest.ask(issue, signing_request(), [])
      ticket = {:ticket, "repo-director", "plan"}
      [%{id: id}] = Questions.open(ticket)
      opts = Keyword.put(opts, :inbox, :director_moves_inbox)
      :persistent_term.put({SymphonyElixir.Inbox, :items, :director_moves_inbox}, [%{issue_id: "plan", review: %{decisions: [%{comment_id: "comment-9", question_id: id}]}}])

      picks = [%{question: "Q", answer: "Ship unsigned", question_id: id}, %{question: "Loose", answer: "B"}]
      assert {:ok, %{to_state: "Rework"}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)

      assert %{state: :answered, answer: %{option: 2}} = Questions.find(ticket, id)
      assert_received {:memory_tracker_reply, "plan", "comment-9", _reply}
      refute Hold.held?("repo-director", "plan", :needs_decision)

      # Sent again, the Question already answered is left as it is.
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      assert {:ok, _result} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "Add the secrets", request_comment_id: "comment-9"}]}, opts)
      assert %{answer: %{option: 2}} = Questions.find(ticket, id)
    end

    test "Send Decisions with Linear refusing a reply: the Question stays answered, the hold clears and the reply is marked pending", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      issue = %{id: "plan", state: "Plan Review", repo_key: "repo-director"}
      assert :ok = DecisionRequest.ask(issue, signing_request(), [])
      ticket = {:ticket, "repo-director", "plan"}
      [%{id: id}] = Questions.open(ticket)
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}, :ok])

      picks = [
        %{question: "Q", answer: "Ship unsigned", question_id: id, request_comment_id: "comment-9"},
        %{question: "Q2", answer: "B", request_comment_id: "comment-8"}
      ]

      log = capture_log(fn -> assert {:ok, %{to_state: "Rework"}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts) end)

      assert log =~ "Linear refused the reply, posted once Linear answers"
      assert %{state: :answered} = Questions.find(ticket, id)
      refute Hold.held?("repo-director", "plan", :needs_decision)
      assert_received {:memory_tracker_reply, "plan", "comment-8", _reply}

      # The refused reply waits for the reconciler; only the posted one is in the Decisions section.
      record = RunStore.get_ticket_state("repo-director", "plan")
      assert [{:question_answer, ^id, "comment-9"}] = for(mark <- record.pending_projection, mark.type == :question_answer, do: TicketState.projection_of(mark))
      assert ["comment-8"] = Enum.map(record.decisions, & &1.key)
    end

    test "Send Decisions names no Question for a pick whose Question the record doesn't hold", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}])

      picks = [%{question: "Q", answer: "B", question_id: "q-gone", request_comment_id: "comment-9"}]
      # Nothing is marked pending: the reply has no Question to post it from, so the move fails as before.
      assert {:error, {:linear, :linear_down}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)
      assert RunStore.get_ticket_state("repo-director", "plan") == nil
    end
  end

  describe "decide" do
    test "a ticket fetched with no repo key is answered and unblocked under the repo its project routes to", %{opts: opts} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [
          [key: "repo-director", workflow: Workflow.workflow_file_path(), team: "MOT", projects: ["Checkout"]],
          [key: "repo-other", workflow: Workflow.workflow_file_path(), team: "MOT", projects: ["Search"]]
        ]
      )

      put_issues([%{pr("In Progress") | team: %{key: "MOT"}, project: %{name: "Checkout"}}])
      set_decision_hold()

      assert {:ok, %{moved: false}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)
      refute Hold.held?("repo-director", "pr", :needs_decision)

      :ok = Hold.set("repo-director", "pr", :blocked, %{reason: "the run reported a block", waits_on: %{type: "access", keys: []}})

      assert {:ok, %{move: "unblock"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)
      refute Hold.held?("repo-director", "pr", :blocked)
    end

    test "a ticket whose repo routes its project by slug id is answered and sent to Rework under that repo", %{opts: opts} do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [
          [key: "repo-director", workflow: Workflow.workflow_file_path(), team: "MOT", projects: ["c0ffee12ab34"]],
          [key: "repo-other", workflow: Workflow.workflow_file_path(), team: "MOT", projects: ["5ea4c4ab12cd"]]
        ]
      )

      project = %{id: "0b9d7c1e-project", name: "Checkout", slug_id: "c0ffee12ab34"}
      put_issues([%{pr("In Progress") | team: %{key: "MOT"}, project: project}])
      set_decision_hold()

      assert {:ok, %{moved: true, to_state: "Rework"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1", move: "rework"}, opts)

      refute Hold.held?("repo-director", "pr", :needs_decision)

      # A Decide that moves the ticket is its answer and the phase it entered.
      assert ["decision.requested", "decision.recorded", "phase.entered"] = Enum.map(ticket_events("repo-director", "pr"), &elem(&1, 0))
    end

    test "records the decision in place: the reply goes under the request and the hold clears", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()

      assert {:ok, result} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)

      assert result == %{
               move: "decide",
               issue_id: "pr",
               issue_identifier: "MOT-40",
               from_state: "In Progress",
               to_state: "In Progress",
               moved: false,
               commented: true,
               undo_window_ms: nil
             }

      assert_received {:memory_tracker_reply, "pr", "comment-1", comment}
      assert comment == "Decision from the Director:\n\n1. Add the signing secrets, or ship unsigned builds?\n   **Decision:** Add the secrets"
      refute Hold.held?("repo-director", "pr", :needs_decision)
      # The decision continues the flow in place: nothing moves.
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert [%{name: "decision returned", details: %{move: "decide", from: "In Progress", to: "In Progress"}}] = RunStore.get_ticket_state("repo-director", "pr").signals
      assert [%{"move" => "decide", "from_state" => "In Progress", "to_state" => "In Progress"}] = audit_records()

      # The request, then the Director's answer naming it: the clear is no withdrawal, and the
      # Decide that moved nothing has no event of its own.
      assert [
               %{type: "decision.requested", id: request_id},
               %{type: "decision.recorded", actor: %{kind: :person, name: "the Director"}, payload: %{answer: "Add the secrets", key: "comment-1", request: request_id}}
             ] = RunStore.list_ticket_events("repo-director", "pr", [])
    end

    test "writes the answer into the description's Decisions section, so the next run reads it", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director", description: "Add checkout."}])
      set_decision_hold()

      assert {:ok, %{move: "decide"}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)

      assert_received {:memory_tracker_description_update, "pr", description}
      assert String.starts_with?(description, "Add checkout.\n\n")

      assert [
               %{
                 id: "D1",
                 key: "comment-1",
                 title: "Add the release signing secrets",
                 question: "Add the signing secrets, or ship unsigned builds?",
                 answer: "Add the secrets"
               }
             ] = SymphonyElixir.Decisions.recorded(description)
    end

    test "a pick of an option that unlocks a protected path records the path, which grants it for the ticket", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director", description: "Add the hook."}])

      request = %{
        title: "Change the workflow settings",
        question: "May MOT-40 change the workflow settings file?",
        why: "The hook lives there.",
        options: [
          %{label: "Allow this ticket to change the workflow settings file", effect: "the next run changes it", recommended: true, unlocks: ["WORKFLOW.md"]},
          %{label: "Keep it as it is", effect: "nothing changes"}
        ]
      }

      :ok = Hold.set("repo-director", "pr", :needs_decision, SymphonyElixir.NeedsDecisionHold.attrs(request))
      pick = [%{question: request.question, answer: "Allow this ticket to change the workflow settings file"}]

      assert {:ok, %{move: "decide", moved: false}} = DirectorMoves.move(:decide, "MOT-40", %{picks: pick, request_comment_id: "comment-1"}, opts)

      assert_received {:memory_tracker_description_update, "pr", description}
      refute description =~ "**Unlocks"
      assert [%{key: "comment-1", unlocks: ["WORKFLOW.md"]}] = SymphonyElixir.Decisions.recorded(description)
      assert [%{key: "comment-1", unlocks: ["WORKFLOW.md"]}] = RunStore.get_ticket_state("repo-director", "pr").decisions
      assert [%{path: "WORKFLOW.md", decision: "D1"}] = SymphonyElixir.PathUnlock.grants(%{pr("In Progress") | description: description})
    end

    test "Decide answers the Question the hold projects with the Director's pick", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])

      request = %{
        title: "Add the release signing secrets",
        question: "Add the signing secrets, or ship unsigned builds?",
        why: "Every Release run on main fails without them.",
        if_unanswered: "Every Release run on main keeps failing.",
        recommendation_reason: "Signing is a one-time setup.",
        options: [%{label: "Add the secrets", effect: "Releases are signed again.", recommended: true}, %{label: "Ship unsigned", effect: "The agent drops the signing step."}]
      }

      issue = %{id: "pr", state: "In Progress", repo_key: "repo-director"}
      assert :ok = SymphonyElixir.DecisionRequest.ask(issue, request, [])
      ticket = {:ticket, "repo-director", "pr"}
      [%{id: id}] = SymphonyElixir.Questions.open(ticket)

      pick = [%{question: request.question, answer: "Ship unsigned"}]
      assert {:ok, %{move: "decide"}} = DirectorMoves.move(:decide, "MOT-40", %{picks: pick, request_comment_id: "comment-1"}, opts)

      refute Hold.held?("repo-director", "pr", :needs_decision)
      assert %{state: :answered, answer: %{option: 2, text: "Ship unsigned", by: %{kind: :person, name: "Director"}}} = SymphonyElixir.Questions.find(ticket, id)
      assert {:ok, nil} = SymphonyElixir.Pauses.get(ticket)
    end

    test "a pick of an option that unlocks nothing records no path", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director", description: "Add the hook."}])

      options = [%{label: "Allow it", effect: "x", unlocks: ["WORKFLOW.md"]}, %{label: "Keep it as it is", effect: "nothing changes"}]
      :ok = Hold.set("repo-director", "pr", :needs_decision, %{reason: "q", decision: %{title: "t", question: "q", options: options}})
      pick = [%{question: "q", answer: "Keep it as it is"}]

      assert {:ok, %{move: "decide"}} = DirectorMoves.move(:decide, "MOT-40", %{picks: pick, request_comment_id: "comment-1"}, opts)

      assert_received {:memory_tracker_description_update, "pr", description}
      assert [decision] = SymphonyElixir.Decisions.recorded(description)
      refute Map.has_key?(decision, :unlocks)
    end

    test "a description Linear refuses to write still records the decision under the request", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_description_result, [{:error, :rate_limited}])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_description_result) end)

      log =
        capture_log(fn ->
          assert {:ok, %{move: "decide"}} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)
        end)

      assert log =~ "Failed to record decisions on issue_id=pr"
      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      refute Hold.held?("repo-director", "pr", :needs_decision)
    end

    test "a decision that directs a move sends the ticket there through the guard", %{opts: opts} do
      for {move, target} <- [{"rework", "Rework"}, {"DONE", "Done"}] do
        put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
        set_decision_hold()

        assert {:ok, result} =
                 DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1", move: move}, opts)

        assert %{moved: true, to_state: ^target, undo_window_ms: 10_000} = result
        assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
        assert_received {:memory_tracker_state_update, "pr", ^target}
        refute Hold.held?("repo-director", "pr", :needs_decision)
      end

      assert [%{"move" => "decide", "to_state" => "Rework"}, %{"to_state" => "Done"}] = audit_records()
    end

    test "a merge confirmation's hold is what Decide does when the pick is Merge: into Merging", %{opts: opts} do
      put_issues([%{pr("QA") | repo_key: "repo-director"}])
      set_merge_hold()

      merge = [%{question: "Merge MOT-40 into its base branch?", answer: "**Merge** (recommended): the ticket moves to Merging"}]
      assert {:ok, result} = DirectorMoves.move(:decide, "MOT-40", %{picks: merge, request_comment_id: "comment-1"}, opts)
      assert %{moved: true, to_state: "Merging", undo_window_ms: 10_000} = result
      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      assert_received {:memory_tracker_state_update, "pr", "Merging"}
      refute Hold.held?("repo-director", "pr", :needs_decision)
    end

    test "a Code Review escalation answered Continue to QA moves the ticket into QA", %{opts: opts} do
      put_issues([%{pr("Code Review") | repo_key: "repo-director"}])
      set_code_review_hold("QA")

      continue = [%{question: "How should MOT-40 continue after Code Review escalated it?", answer: "Continue to QA"}]
      assert {:ok, result} = DirectorMoves.move(:decide, "MOT-40", %{picks: continue, request_comment_id: "comment-1"}, opts)
      assert %{moved: true, from_state: "Code Review", to_state: "QA", undo_window_ms: 10_000} = result
      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      assert_received {:memory_tracker_state_update, "pr", "QA"}
      refute Hold.held?("repo-director", "pr", :needs_decision)
      assert [%{name: "decision returned", details: %{move: "decide", from: "Code Review", to: "QA"}}] = RunStore.get_ticket_state("repo-director", "pr").signals
    end

    test "a decision directing a move into a state the repo has not configured is refused before anything is written", %{opts: opts} do
      put_issues([%{pr("Code Review") | repo_key: "repo-director"}])
      set_code_review_hold("")

      continue = [%{question: "How should MOT-40 continue after Code Review escalated it?", answer: "1"}]

      assert {:error, {:invalid, message}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: continue, request_comment_id: "comment-1"}, opts)

      assert message == "MOT-40's decision moves it to a state not configured for repo repo-director; the hold stays"
      # The request stays open and the hold set, so the person can decide again once the state is configured.
      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert Hold.held?("repo-director", "pr", :needs_decision)
      assert audit_records() == []
    end

    test "a merge confirmation answered with anything but an option moves nothing", %{opts: opts} do
      put_issues([%{pr("QA") | repo_key: "repo-director"}])
      set_merge_hold()

      neither = [%{question: "Merge MOT-40 into its base branch?", answer: "Neither: fix the flaky test first"}]
      assert {:ok, %{moved: false}} = DirectorMoves.move(:decide, "MOT-40", %{picks: neither, request_comment_id: "comment-1"}, opts)
      refute_received {:memory_tracker_state_update, "pr", _state}
      refute Hold.held?("repo-director", "pr", :needs_decision)
    end

    test "refuses a decision that names no answer, no request, or an unknown move", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()

      assert {:error, {:invalid, "picks must list each decision's question and answer"}} =
               DirectorMoves.move(:decide, "MOT-40", %{request_comment_id: "c"}, opts)

      assert {:error, {:invalid, "picks must list each decision's question and answer"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: [%{question: "q", answer: ""}], request_comment_id: "c"}, opts)

      assert {:error, {:invalid, "question_id or request_comment_id is required"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks()}, opts)

      assert {:error, {:invalid, message}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c", move: "nope"}, opts)

      assert message =~ "move must be"

      assert {:error, {:invalid, _message}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c", move: 5}, opts)

      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
    end

    test "refuses a ticket that is not waiting on a decision", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])

      assert {:error, {:conflict, "MOT-40 is not waiting on a decision"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c"}, opts)

      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
    end

    test "a reply Linear refuses leaves the hold in place", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :reply_failed})

      assert {:error, {:linear, :reply_failed}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c"}, opts)

      assert Hold.held?("repo-director", "pr", :needs_decision)
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert audit_records() == []
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end

    test "a refused directed move is partial: the decision stays recorded and the hold is gone", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :state_failed})

      assert {:error, {:partial, message}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1", move: "rework"}, opts)

      assert message =~ "recorded the decision on MOT-40 and cleared the hold, but Linear refused the move to Rework"
      # The decision is already in Linear, so the refusal reports the move rather than taking it back.
      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      refute Hold.held?("repo-director", "pr", :needs_decision)
      assert [%{"move" => "decide", "from_state" => "In Progress", "to_state" => "In Progress"}] = audit_records()
      # Its answer is its one event: a Decide records no person action, even when its move was refused.
      assert ["decision.requested", "decision.recorded"] = Enum.map(ticket_events("repo-director", "pr"), &elem(&1, 0))
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
    end

    test "the decision answers at once while the orchestrator is too busy to take the refresh", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      test_pid = self()

      # An orchestrator still busy with a poll: it reads one message and handles nothing after it.
      busy =
        spawn(fn ->
          receive do
            message -> send(test_pid, {:orchestrator_got, message})
          end

          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(busy, :kill) end)

      assert {:ok, %{move: "decide", moved: false}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, Keyword.put(opts, :orchestrator, busy))

      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      refute Hold.held?("repo-director", "pr", :needs_decision)
      # The refresh is a cast for a cycle on the ticket's repo at once, so nothing waits on its answer.
      assert_receive {:orchestrator_got, {:"$gen_cast", {:request_refresh, "repo-director", :now}}}
    end

    test "a hold the store refuses to clear comes back as a store error", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()

      assert {:error, {:store, "couldn't clear the hold on MOT-40: :boom"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c"}, Keyword.put(opts, :store, UnwritableStore))

      assert_received {:memory_tracker_reply, "pr", "c", _comment}
      assert Hold.held?("repo-director", "pr", :needs_decision)
    end

    test "decide_comment/1 numbers each question with the answer the Director picked" do
      assert DirectorMoves.decide_comment([%{question: "Close TP-612 as a duplicate?", answer: "Close as duplicate"}]) ==
               "Decision from the Director:\n\n1. Close TP-612 as a duplicate?\n   **Decision:** Close as duplicate"

      assert DirectorMoves.decide_comment([
               %{question: "q1", answer: "a1"},
               %{question: "q2", answer: "a2"}
             ]) == "Decision from the Director:\n\n1. q1\n   **Decision:** a1\n\n2. q2\n   **Decision:** a2"
    end
  end

  describe "errors" do
    test "an unknown ticket is not found", %{opts: opts} do
      put_issues([])
      assert {:error, :issue_not_found} = DirectorMoves.move(:backlog, "MOT-404", %{}, opts)
      assert {:error, :issue_not_found} = DirectorMoves.undo("MOT-404", opts)
    end

    test "Linear's errors come back, and a failed comment leaves the state alone", %{opts: opts} do
      put_issues([plan("Plan Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :comment_failed})

      assert {:error, {:linear, :comment_failed}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "No"}, opts)
      refute_received {:memory_tracker_state_update, _id, _state}

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :state_failed})
      assert {:error, {:linear, :state_failed}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert audit_records() == []
    end

    test "a Linear read that fails comes back as Linear's error, and its not-found as not found", %{opts: opts} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "token")
      Application.put_env(:symphony_elixir, :linear_client_module, CannedLinearClient)

      rate_limited = {:linear_graphql_errors, [%{"message" => "Rate limited"}]}

      for {response, expected} <- [
            {{:error, {:linear_graphql_errors, [%{"message" => "Entity not found: Issue"}]}}, {:error, :issue_not_found}},
            {{:error, rate_limited}, {:error, {:linear, rate_limited}}},
            {{:error, :issue_not_found}, {:error, :issue_not_found}},
            {{:error, :timeout}, {:error, {:linear, :timeout}}}
          ] do
        Application.put_env(:symphony_elixir, :director_moves_test_fetch, response)
        assert DirectorMoves.move(:backlog, "MOT-40", %{}, opts) == expected
      end
    after
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :director_moves_test_fetch)
    end
  end

  describe "the record moves first" do
    setup do
      RunStore.delete_ticket_state("repo-director", "plan")
      RunStore.delete_ticket_state("repo-director", "pr")
      :ok
    end

    test "an approved plan's record is in the waiting state at once, and stays there when Linear refuses the move", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])

      assert {:ok, %{to_state: @waiting}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert_received {:memory_tracker_state_update, "plan", @waiting}
      assert %{phase: @waiting} = RunStore.get_ticket_state("repo-director", "plan")

      RunStore.delete_ticket_state("repo-director", "plan")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :linear_down}])

      log =
        capture_log(fn ->
          assert {:error, {:linear, :linear_down}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
        end)

      refute_received {:memory_tracker_state_update, "plan", _state}
      assert %{phase: @waiting} = RunStore.get_ticket_state("repo-director", "plan")
      assert log =~ "Linear refused the move; the record keeps it issue_id=plan issue_identifier=MOT-30 to=#{@waiting}"
    end

    test "a rework whose comment Linear refuses leaves the record in Rework and logs the failed projection", %{opts: opts} do
      put_issues([%{plan("Plan Review") | repo_key: "repo-director"}])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :linear_down}])

      log =
        capture_log(fn ->
          assert {:error, {:linear, :linear_down}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "Split it"}, opts)
        end)

      refute_received {:memory_tracker_state_update, "plan", _state}
      assert %{phase: "Rework"} = RunStore.get_ticket_state("repo-director", "plan")
      # The reconciler writes the move to Linear (`TicketObservation.reconcile_all/3`).
      assert [%{type: :phase, error: ":linear_down"}] = RunStore.get_ticket_state("repo-director", "plan").pending_projection

      assert log =~
               "Linear refused the Director move's comment; the record keeps the move issue_id=plan issue_identifier=MOT-30 to=Rework"
    end

    test "backlog, restart and a decision's move each write the record's phase", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{note: "Later"}, opts)
      assert %{phase: "Backlog"} = RunStore.get_ticket_state("repo-director", "pr")

      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      assert {:ok, _result} = DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1", move: "rework"}, opts)
      assert %{phase: "Rework"} = RunStore.get_ticket_state("repo-director", "pr")

      github_activity(state: "OPEN")
      RunStore.delete_ticket_state("repo-restart", "pr")
      put_issues([restart_issue()])
      assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert %{phase: "In Progress"} = RunStore.get_ticket_state("repo-restart", "pr")
    end

    test "undo puts the record back as it puts Linear back", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      assert %{phase: "Backlog"} = RunStore.get_ticket_state("repo-director", "pr")

      put_issues([%{pr("Backlog") | repo_key: "repo-director"}])
      assert {:ok, %{move: "undo", to_state: "In Progress"}} = DirectorMoves.undo("MOT-40", opts)
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
      assert %{phase: "In Progress"} = RunStore.get_ticket_state("repo-director", "pr")
    end
  end

  describe "undo" do
    test "moves the ticket back within 10 s, once", %{opts: opts, clock: clock} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      assert_received {:memory_tracker_state_update, "pr", "Backlog"}

      put_issues([%{pr("Backlog") | repo_key: "repo-director"}])
      :counters.put(clock, 1, 10_000)

      assert {:ok, %{move: "undo", undone: "backlog", from_state: "Backlog", to_state: "In Progress"}} = DirectorMoves.undo("MOT-40", opts)
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
      assert [%{"move" => "backlog"}, %{"move" => "undo", "from_state" => "Backlog", "to_state" => "In Progress"}] = audit_records()

      assert ticket_events("repo-director", "pr", "person.action") == [
               {"person.action", %{action: "move", move: "backlog", from: "In Progress", to: "Backlog"}},
               {"person.action", %{action: "move", move: "undo", from: "Backlog", to: "In Progress"}}
             ]

      assert {:error, {:conflict, "there is no move on MOT-40 to undo"}} = DirectorMoves.undo("MOT-40", opts)
    end

    test "refuses after 10 s", %{opts: opts, clock: clock} do
      put_issues([pr("In Progress")])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      put_issues([pr("Backlog")])
      :counters.put(clock, 1, 10_001)

      assert {:error, {:conflict, "the move on MOT-40 is more than 10 s old; move it in Linear instead"}} = DirectorMoves.undo("MOT-40", opts)
      refute_received {:memory_tracker_state_update, "pr", "In Progress"}
    end

    test "refuses once the ticket moved on", %{opts: opts} do
      put_issues([pr("In Progress")])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      put_issues([pr("Todo")])

      assert {:error, {:conflict, "MOT-40 moved on to Todo since; move it in Linear instead"}} = DirectorMoves.undo("MOT-40", opts)
    end

    test "refuses an approved plan once Symphony promoted its sub-tickets", %{opts: opts} do
      backlog = [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}]
      put_issues([%{plan("Plan Review") | sub_issues: backlog}])
      assert {:ok, _result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      put_issues([%{plan(@waiting) | sub_issues: [%{hd(backlog) | state: "Todo"}]}])

      assert {:error, {:conflict, "Symphony already promoted the sub-tickets of MOT-30; move them in Linear instead"}} =
               DirectorMoves.undo("MOT-30", opts)

      put_issues([%{plan(@waiting) | sub_issues: backlog}])
      assert {:ok, %{to_state: "Plan Review"}} = DirectorMoves.undo("MOT-30", opts)
    end

    test "fails when Linear refuses the move back, and keeps the move to undo", %{opts: opts} do
      put_issues([pr("In Progress")])
      assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts)
      put_issues([pr("Backlog")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :boom}])

      assert {:error, {:linear, :boom}} = DirectorMoves.undo("MOT-40", opts)
      assert {:ok, _result} = DirectorMoves.undo("MOT-40", opts)
    end
  end

  test "the Director's comments count as a person's, not as Symphony's own" do
    for body <- [
          DirectorMoves.decisions_comment([%{question: "Where?", answer: "B"}]),
          DirectorMoves.rework_comment("Split it"),
          DirectorMoves.restart_comment("MOT-40", "Start over"),
          DirectorMoves.backlog_comment("Later")
        ] do
      assert PlanComments.human?(%{bot?: false, body: body})
    end
  end

  test "runs with its default options, under its own name" do
    case DirectorMoves.start_link() do
      {:ok, pid} -> Agent.stop(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    put_issues([])
    assert {:error, :issue_not_found} = DirectorMoves.move(:backlog, "MOT-404", %{})
    assert {:error, :issue_not_found} = DirectorMoves.undo("MOT-404")
  end

  test "lists its moves and its undo window" do
    assert DirectorMoves.moves() == [:approve_plan, :rework, :restart, :decisions, :changes, :backlog, :unblock, :decide]
    assert DirectorMoves.undo_window_ms() == 10_000
  end

  test "an audit log that can't be written still makes the move", %{opts: opts} do
    put_issues([pr("In Progress")])
    blocker = Path.join(System.tmp_dir!(), "director-moves-blocker-#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(blocker, "audit"))

    log = capture_log(fn -> assert {:ok, _result} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts) end)
    assert log =~ "Failed to record director_move audit event"
  after
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(System.tmp_dir!(), "unused"))
  end

  test "an event the ledger can't write still makes the move and its audit record", %{opts: opts} do
    put_issues([%{pr("In Progress") | repo_key: "  "}])

    log = capture_log(fn -> assert {:ok, %{move: "backlog", to_state: "Backlog"}} = DirectorMoves.move(:backlog, "MOT-40", %{}, opts) end)

    assert log =~ "Failed to record the person.action event on issue_id=pr"
    assert_received {:memory_tracker_state_update, "pr", "Backlog"}
    assert [%{"move" => "backlog"}] = audit_records()
  end

  describe "a question Symphony asked beside its hold" do
    @director %{kind: :person, name: "Director"}

    # The question and the hold the orchestrator sets for a dispatch loop or a quiet handoff.
    defp ask_and_hold(repo_key, stop) do
      {:ok, question} = Questions.ask({:ticket, repo_key, "pr"}, DispatchLoop.question_attrs(stop, "MOT-40"))
      type = if match?({:quiet_handoff, _runs}, stop), do: "handoff_missing", else: "dispatch_loop"
      :ok = Hold.set(repo_key, "pr", :blocked, %{reason: "#{type}: stuck", waits_on: %{type: type, keys: [], question_id: question.id}})
      question
    end

    defp loop, do: %{kind: "implementation", count: 4, window_ms: 600_000, runs: []}

    test "the Inbox lists a quiet handoff, and Unblock lifts it, answering its question with Run it again", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      question = ask_and_hold("repo-director", {:quiet_handoff, 2})

      node = %{"id" => "pr", "identifier" => "MOT-40", "title" => "Add checkout", "url" => nil, "state" => %{"name" => "In Progress"}}
      lookups = %{hold: &Hold.get(&1, &2, :blocked)}
      assert %{kind: :blocked} = Item.from_node(node, "repo-director", %Schema{}, lookups)

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute Hold.held?("repo-director", "pr", :blocked)
      assert %{state: :answered, answer: %{option: 1, by: @director}} = Questions.find({:ticket, "repo-director", "pr"}, question.id)
      assert {:ok, nil} = Pauses.get({:ticket, "repo-director", "pr"})
      assert_received {:memory_tracker_comment, "pr", "Unblocked by the Director: MOT-40 continues in place."}
    end

    test "Restart lifts a dispatch loop or a quiet handoff, answering its question with Start it over from main", %{opts: opts} do
      for stop <- [loop(), {:quiet_handoff, 2}] do
        github_activity(state: "OPEN")
        put_issues([restart_issue()])
        question = ask_and_hold("repo-restart", stop)

        assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "Start over"}, restart_opts(opts))

        refute Hold.held?("repo-restart", "pr", :blocked)
        assert %{state: :answered, answer: %{option: 2}} = Questions.find({:ticket, "repo-restart", "pr"}, question.id)
      end
    end

    test "a Restart the store refuses to lift names the quiet handoff's hold", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])
      ask_and_hold("repo-restart", {:quiet_handoff, 3})

      log =
        capture_log(fn ->
          assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, opts |> restart_opts() |> Keyword.put(:store, UnwritableStore))
        end)

      assert log =~ "Restarted MOT-40 but couldn't clear its quiet-handoff hold: :boom"
    end

    test "answering \"Run it again\" is Unblock: the hold goes and the ticket continues in place", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = RunStore.record_ticket_dispatch("repo-director", "pr", %{kind: :implementation, run_id: "run-1", state: "In Progress"})
      question = ask_and_hold("repo-director", loop())

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.answer_held_question("MOT-40", question.id, "Run it again", opts)

      refute Hold.held?("repo-director", "pr", :blocked)
      assert RunStore.get_ticket_state("repo-director", "pr").dispatches == []
      assert %{state: :answered, answer: %{option: 1, text: "Run it again", by: @director}} = Questions.find({:ticket, "repo-director", "pr"}, question.id)
    end

    test "answering \"Start it over from main\" is Restart, its comment naming the question", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])
      question = ask_and_hold("repo-restart", loop())

      assert {:ok, %{move: "restart", to_state: "In Progress"}} = DirectorMoves.answer_held_question("MOT-40", question.id, "2", restart_opts(opts))

      assert_received {:close_pr, @restart_pr_url}
      assert_received {:memory_tracker_comment, "pr", comment}
      assert comment =~ ~s(You answered "Start it over from main" to: MOT-40 ran 4 times in 10 minutes without finishing)
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
      refute Hold.held?("repo-restart", "pr", :blocked)
      assert %{state: :answered, answer: %{option: 2}} = Questions.find({:ticket, "repo-restart", "pr"}, question.id)
    end

    test "answering \"Keep it paused\" or in the Director's own words leaves the ticket held", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])

      for answer <- ["Keep it paused", "Let me look first"] do
        question = ask_and_hold("repo-director", {:quiet_handoff, String.length(answer)})

        assert {:ok, %{move: "decide", moved: false, commented: false}} = DirectorMoves.answer_held_question("MOT-40", question.id, answer, opts)

        assert %{waits_on: %{question_id: id}} = Hold.get("repo-director", "pr", :blocked)
        assert id == question.id
        assert %{state: :answered, answer: %{text: ^answer}} = Questions.find({:ticket, "repo-director", "pr"}, question.id)
        refute_received {:memory_tracker_comment, "pr", _body}
      end

      # The hold still waits on a person: Unblock lifts it.
      assert {:ok, %{move: "unblock"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)
      refute Hold.held?("repo-director", "pr", :blocked)
    end

    test "refuses a question the ticket doesn't have, one already answered and a blank answer", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      question = ask_and_hold("repo-director", loop())

      assert {:error, {:conflict, "MOT-40 has no question q-none"}} = DirectorMoves.answer_held_question("MOT-40", "q-none", "1", opts)
      assert {:error, {:store, message}} = DirectorMoves.answer_held_question("MOT-40", question.id, "  ", opts)
      assert message =~ "couldn't answer the question on MOT-40: :blank_answer"

      assert {:ok, _result} = DirectorMoves.answer_held_question("MOT-40", question.id, "Keep it paused", opts)
      assert {:error, {:conflict, message}} = DirectorMoves.answer_held_question("MOT-40", question.id, "1", opts)
      assert message == "MOT-40's question #{question.id} is answered, not open"
      assert {:error, :issue_not_found} = DirectorMoves.answer_held_question("MOT-404", question.id, "1", opts)
    end
  end

  describe "a run's block report naming no blocker (TP-1234)" do
    # The access hold and its question, as the Linear tool sets them for an agent's block report.
    defp report_block(repo_key) do
      ticket = {:ticket, repo_key, "pr"}
      ctx = %{settings: %Schema{}, from_state: "In Progress", open_blockers: [], ticket: ticket, issue_identifier: "MOT-40"}
      {:hold, :blocked, attrs} = SymphonyElixir.TransitionGuard.resolve_request(%{"id" => "backlog", "name" => "Backlog"}, ctx)
      :ok = Hold.set(repo_key, "pr", :blocked, attrs)
      [question] = Questions.open({:ticket, repo_key, "pr"})
      question
    end

    test ~s(the Inbox lists it with its question, and Unblock answers "Unblock and run again" and lifts it), %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      question = report_block("repo-director")
      assert question.title == "The run on MOT-40 cannot continue on its own"

      node = %{"id" => "pr", "identifier" => "MOT-40", "title" => "Add checkout", "url" => nil, "state" => %{"name" => "In Progress"}}
      assert %{kind: :blocked} = Item.from_node(node, "repo-director", %Schema{}, %{hold: &Hold.get(&1, &2, :blocked)})

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      refute Hold.held?("repo-director", "pr", :blocked)
      assert %{state: :answered, answer: %{option: 1, text: "Unblock and run again"}} = Questions.find({:ticket, "repo-director", "pr"}, question.id)
      assert {:ok, nil} = Pauses.get({:ticket, "repo-director", "pr"})
    end

    test ~s(answering "Unblock and run again" resumes the ticket in place; "Keep it paused" leaves it held), %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      question = report_block("repo-director")

      assert {:ok, %{move: "decide", moved: false}} = DirectorMoves.answer_held_question("MOT-40", question.id, "Keep it paused", opts)
      assert Hold.held?("repo-director", "pr", :blocked)

      :ok = Hold.clear("repo-director", "pr", :blocked)
      question = report_block("repo-director")

      assert {:ok, %{move: "unblock", moved: false}} = DirectorMoves.answer_held_question("MOT-40", question.id, "Unblock and run again", opts)
      refute Hold.held?("repo-director", "pr", :blocked)
      assert %{state: :answered, answer: %{option: 1}} = Questions.find({:ticket, "repo-director", "pr"}, question.id)
      assert {:ok, nil} = Pauses.get({:ticket, "repo-director", "pr"})
      assert_received {:memory_tracker_comment, "pr", "Unblocked by the Director: MOT-40 continues in place."}
    end

    test "Restart leaves the block report's hold and its question, as it always left the access hold", %{opts: opts} do
      github_activity(state: "OPEN")
      put_issues([restart_issue()])
      question = report_block("repo-restart")

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "Start over"}, restart_opts(opts))

      assert %{waits_on: %{type: "access", question_id: id}} = Hold.get("repo-restart", "pr", :blocked)
      assert id == question.id
      assert %{state: :open} = Questions.find({:ticket, "repo-restart", "pr"}, question.id)
    end
  end

  defp github_activity(fields) do
    Application.put_env(:symphony_elixir, :director_moves_test_activity, {:ok, Map.merge(%{pr_url: @restart_pr_url, pr_node_id: "PR_node"}, Map.new(fields))})
  end

  defp put_issues(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp picks, do: [%{question: "Add the signing secrets, or ship unsigned builds?", answer: "Add the secrets"}]

  defp set_merge_hold do
    :ok =
      Hold.set("repo-director", "pr", :needs_decision, %{
        reason: "Merge MOT-40 into its base branch?",
        clearing_condition: "when the decision is recorded",
        decision: %{
          title: "Merge MOT-40",
          question: "Merge MOT-40 into its base branch?",
          options: [%{label: "Merge", effect: "the ticket moves to Merging"}, %{label: "Send to Rework", effect: "the ticket moves to Rework"}],
          confirm: "Merging"
        }
      })
  end

  # The hold `SymphonyElixir.CodeReview` sets on an escalation: its confirmation continues into the
  # repo's QA state, as `NeedsDecisionHold.pause/4` records it.
  defp set_code_review_hold(qa_state) do
    :ok =
      Hold.set("repo-director", "pr", :needs_decision, %{
        reason: "How should MOT-40 continue after Code Review escalated it?",
        clearing_condition: "when the decision is recorded",
        decision: %{
          title: "Code Review escalated MOT-40",
          question: "How should MOT-40 continue after Code Review escalated it?",
          options: [
            %{label: "Continue to #{qa_state}", effect: "the ticket moves to #{qa_state} and its QA run starts", recommended: true},
            %{label: "Send to Rework", effect: "the ticket moves to Rework with these reasons", recommended: false}
          ],
          confirm: qa_state,
          state: "Code Review"
        }
      })
  end

  defp signing_request do
    %{
      title: "Add the release signing secrets",
      question: "Add the signing secrets, or ship unsigned builds?",
      why: "Every Release run on main fails without them.",
      if_unanswered: "Every Release run on main keeps failing.",
      recommendation_reason: "Signing is a one-time setup.",
      options: [%{label: "Add the secrets", effect: "Releases are signed again.", recommended: true}, %{label: "Ship unsigned", effect: "The agent drops the signing step."}]
    }
  end

  # The signing question asked on MOT-40 through the one writer, its record holding what Linear last showed.
  defp ask_signing do
    assert :ok = SymphonyElixir.DecisionRequest.ask(%{id: "pr", state: "In Progress", repo_key: "repo-director"}, signing_request(), [])
    assert_received {:memory_tracker_comment, "pr", _body}
    :ok = RunStore.update_ticket_state("repo-director", "pr", %{issue_identifier: "MOT-40", phase: "In Progress"})
    [%{id: id}] = Questions.open({:ticket, "repo-director", "pr"})
    id
  end

  defp set_decision_hold do
    :ok =
      Hold.set("repo-director", "pr", :needs_decision, %{
        reason: "Add the signing secrets, or ship unsigned builds?",
        clearing_condition: "when the decision is recorded",
        decision: %{title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"}
      })
  end

  # The Director's Stop as the orchestrator leaves it: the pause reason, then the hold beside it.
  defp stop(repo_key) do
    :ok = OperatorStop.mark(repo_key, "pr", ~U[2026-10-20 08:41:25Z])
    :ok = OperatorStop.set_hold(repo_key, "pr", ~U[2026-10-20 08:41:25Z])
  end

  defp plan(state), do: %Issue{id: "plan", identifier: "MOT-30", title: "Plan an MVP", state: state, labels: ["plan"]}
  defp pr(state), do: %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: state, labels: []}

  defp audit_records do
    {:ok, stream} = AuditLog.query(event_type: "director_move")
    Enum.to_list(stream)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
