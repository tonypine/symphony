defmodule SymphonyElixir.DirectorMovesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AuditLog, DirectorMoves, Hold, PlanComments, PrReviewPoller, RunStore, SubIssueWait}

  @waiting "Waiting on sub-tickets"

  defmodule MissingStateTracker do
    def workflow_state_exists?(_state, _teams), do: {:ok, false}
  end

  defmodule FakeGitHub do
    def fetch_activity(pr_url, _opts) do
      send(self(), {:fetch_activity, pr_url})
      Application.fetch_env!(:symphony_elixir, :director_moves_test_activity)
    end

    def disable_auto_merge(pr_url, pr_node_id, _opts) do
      send(self(), {:disable_auto_merge, pr_url, pr_node_id})
      Application.get_env(:symphony_elixir, :director_moves_test_disable, :ok)
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

  defmodule UnwritableStore do
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
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
      Application.delete_env(:symphony_elixir, :director_moves_test_disable)
      Application.delete_env(:symphony_elixir, :director_moves_test_close)
      Application.delete_env(:symphony_elixir, :director_moves_test_workspace)
      SubIssueWait.reset_for_test(@waiting)
      restore_app_env(:audit_log_dir, previous_audit_dir)
      File.rm_rf(audit_dir)
    end)

    %{opts: [server: server, clock: fn -> :counters.get(clock, 1) end, github: FakeGitHub], clock: clock}
  end

  describe "approve_plan" do
    test "moves a plan in In Review or Human Review to the waiting state and writes an audit record", %{opts: opts} do
      for state <- ["In Review", "Human Review"] do
        put_issues([plan(state)])

        assert {:ok, result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

        assert result == %{
                 move: "approve_plan",
                 issue_id: "plan",
                 issue_identifier: "MOT-30",
                 from_state: state,
                 to_state: @waiting,
                 moved: true,
                 commented: false,
                 undo_window_ms: 10_000
               }

        assert_received {:memory_tracker_state_update, "plan", @waiting}
        refute_received {:memory_tracker_comment, _id, _body}
      end

      assert [%{"move" => "approve_plan", "issue_identifier" => "MOT-30", "from_state" => "In Review", "to_state" => @waiting}, %{"from_state" => "Human Review"}] =
               audit_records()
    end

    test "records the move's signal in the ticket's signals ledger", %{opts: opts} do
      RunStore.delete_ticket_state("repo-director", "plan")
      put_issues([%{plan("In Review") | repo_key: "repo-director"}])

      assert {:ok, _result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      assert [%{name: "decision returned", details: %{move: "approve_plan", from: "In Review", to: @waiting}}] =
               RunStore.get_ticket_state("repo-director", "plan").signals
    end

    test "refuses a plan outside the review states, a ticket that is not a plan, and a turned-off waiting state", %{opts: opts} do
      put_issues([plan("In Progress"), pr("In Review")])
      assert {:error, {:conflict, message}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert message == "MOT-30 is In Progress; the Director answers it only from In Review or Human Review"
      assert {:error, {:conflict, "MOT-40 is a pull request; approve_plan is for a plan"}} = DirectorMoves.move(:approve_plan, "MOT-40", %{}, opts)

      put_issues([plan("In Review")])
      settings = Config.settings!()
      disable = fn -> :disabled = SubIssueWait.check_tracker_state(settings, [], tracker: MissingStateTracker) end
      capture_log(disable)
      assert {:error, {:conflict, "the waiting state is turned off" <> _}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      refute_received {:memory_tracker_state_update, _id, _state}
      assert audit_records() == []
    end

    test "answers a designed repo's plan in Plan Review, and names Plan Review when it is elsewhere", %{opts: opts} do
      designed_workflow!()

      put_issues([plan("Plan Review")])
      assert {:ok, %{from_state: "Plan Review", to_state: @waiting}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert_received {:memory_tracker_state_update, "plan", @waiting}

      put_issues([plan("In Progress")])
      assert {:error, {:conflict, message}} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)
      assert message == "MOT-30 is In Progress; the Director answers it only from In Review or Human Review or Plan Review"
    end
  end

  describe "approve_pr" do
    test "moves a pull request in review to Merging", %{opts: opts} do
      put_issues([pr("Human Review")])

      assert {:ok, %{to_state: "Merging", from_state: "Human Review"}} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      assert_received {:memory_tracker_state_update, "pr", "Merging"}
    end

    test "refuses a plan, a final verification and a pull request already merging", %{opts: opts} do
      put_issues([plan("In Review"), final_verification("In Review"), pr("Merging")])

      assert {:error, {:conflict, "MOT-30 is a plan; approve_pr is for a pull request"}} = DirectorMoves.move(:approve_pr, "MOT-30", %{}, opts)
      assert {:error, {:conflict, "MOT-50 is a final verification; approve_pr is for a pull request"}} = DirectorMoves.move(:approve_pr, "MOT-50", %{}, opts)
      assert {:error, {:conflict, "MOT-40 is Merging;" <> _}} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      refute_received {:memory_tracker_state_update, _id, _state}
    end
  end

  describe "rework" do
    test "posts the reason, then moves the ticket to Rework", %{opts: opts} do
      put_issues([pr("In Review")])

      assert {:ok, %{to_state: "Rework", commented: true}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "  The totals are wrong  "}, opts)
      assert_received {:memory_tracker_comment, "pr", "Sent to Rework by the Director:\n\nThe totals are wrong"}
      assert_received {:memory_tracker_state_update, "pr", "Rework"}
      assert [%{"move" => "rework", "comment" => "Sent to Rework by the Director:\n\nThe totals are wrong"}] = audit_records()
    end

    test "rejects a designed repo's plan from Plan Review", %{opts: opts} do
      designed_workflow!()
      put_issues([plan("Plan Review")])

      assert {:ok, %{to_state: "Rework", commented: true}} = DirectorMoves.move(:rework, "MOT-30", %{reason: "  Split MOT-31 differently  "}, opts)
      assert_received {:memory_tracker_comment, "plan", "Sent to Rework by the Director:\n\nSplit MOT-31 differently"}
      assert_received {:memory_tracker_state_update, "plan", "Rework"}
    end

    test "needs a reason and a ticket in review", %{opts: opts} do
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

    defp designed_workflow! do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: "designed", workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    end

    defp restart_issue(fields \\ []) do
      struct(%{pr("Rework") | pr_urls: [@restart_pr_url]}, fields)
    end

    test "closes the pull request, removes the workspace and moves the ticket to In Progress", %{opts: opts} do
      designed_workflow!()
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
      designed_workflow!()
      github_activity(state: "OPEN")
      RunStore.delete_ticket_state("repo-restart", "pr")
      put_issues([%{restart_issue() | repo_key: "repo-restart"}])

      assert {:ok, _result} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      assert [%{name: "restart", details: %{move: "restart", from: "Rework", to: "In Progress"}}] =
               RunStore.get_ticket_state("repo-restart", "pr").signals
    end

    test "a ticket with no pull request restarts just the same", %{opts: opts} do
      designed_workflow!()
      put_issues([%{pr("In Progress") | pr_urls: []}])

      assert {:ok, %{to_state: "In Progress"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert_received {:remove_workspaces, "MOT-40"}
      assert_received {:memory_tracker_state_update, "pr", "In Progress"}
    end

    test "a restart can't be undone: it closed the pull request and removed the workspace", %{opts: opts} do
      designed_workflow!()
      github_activity(state: "OPEN")
      put_issues([restart_issue()])

      assert {:ok, %{to_state: "In Progress", undo_window_ms: nil}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      put_issues([%{restart_issue() | state: "In Progress"}])

      assert {:error, {:conflict, message}} = DirectorMoves.undo("MOT-40", restart_opts(opts))

      assert message ==
               "MOT-40 was restarted; the pull request is closed and the workspace is gone, so it can't be undone"

      refute_received {:memory_tracker_state_update, "pr", "Rework"}
    end

    test "a legacy repo is refused: its Rework already is the full reset", %{opts: opts} do
      put_issues([restart_issue()])

      assert {:error, {:conflict, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert message == "MOT-40 is on the legacy state machine, where Rework already closes the pull request and starts over"
      refute_received {:memory_tracker_state_update, _id, _state}
      refute_received {:memory_tracker_comment, _id, _body}
    end

    test "a terminal ticket is refused", %{opts: opts} do
      designed_workflow!()
      put_issues([%{restart_issue() | state: "Done"}])

      assert {:error, {:conflict, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))
      assert message == "MOT-40 is Done; only an open ticket can be restarted"
      refute_received {:remove_workspaces, _identifier}
    end

    test "needs a reason", %{opts: opts} do
      designed_workflow!()
      put_issues([restart_issue()])

      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "  "}, restart_opts(opts))
      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:restart, "MOT-40", %{}, restart_opts(opts))
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a reset GitHub refuses stops the move, so nothing is half-done", %{opts: opts} do
      designed_workflow!()
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
      designed_workflow!()
      github_activity(state: "OPEN")
      Application.put_env(:symphony_elixir, :director_moves_test_workspace, {:error, :busy})
      put_issues([restart_issue()])

      assert {:error, {:restart, message}} = DirectorMoves.move(:restart, "MOT-40", %{reason: "No"}, restart_opts(opts))

      assert message == "MOT-40 was not restarted: couldn't remove the workspace of MOT-40 ({:error, :busy})"
      refute_received {:memory_tracker_state_update, _id, _state}
    end

    test "a move Linear refuses after the reset is a partial move", %{opts: opts} do
      designed_workflow!()
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
    test "posts one comment with the picks on a plan in In Review, and leaves it there", %{opts: opts} do
      put_issues([plan("In Review")])
      picks = [%{question: " Where are gift cards bought? ", answer: "B. In the app only"}, %{question: "Who pays?", answer: "A. The buyer"}]

      assert {:ok, %{moved: false, commented: true, to_state: "In Review", undo_window_ms: nil}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: picks}, opts)

      assert_received {:memory_tracker_comment, "plan", body}

      assert body ==
               "Decisions on the plan, from the Director:\n\n1. Where are gift cards bought?\n   **Pick:** B. In the app only\n\n2. Who pays?\n   **Pick:** A. The buyer"

      refute_received {:memory_tracker_state_update, _id, _state}
      # Nothing moved, so there is nothing to undo.
      assert {:error, {:conflict, "there is no move on MOT-30 to undo"}} = DirectorMoves.undo("MOT-30", opts)
    end

    test "moves a plan in Human Review to In Review before posting the comment", %{opts: opts} do
      put_issues([plan("Human Review")])

      assert {:ok, %{moved: true, from_state: "Human Review", to_state: "In Review"}} =
               DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B"}]}, opts)

      assert {:messages, [{:memory_tracker_state_update, "plan", "In Review"}, {:memory_tracker_comment, "plan", _body}]} =
               Process.info(self(), :messages)
    end

    test "needs picks, on a plan in review", %{opts: opts} do
      put_issues([plan("In Review"), pr("In Review")])

      for input <- [%{}, %{picks: []}, %{picks: nil}, %{picks: [%{question: "Q", answer: " "}]}, %{picks: ["B"]}] do
        assert {:error, {:invalid, "picks must list each decision's question and answer"}} = DirectorMoves.move(:decisions, "MOT-30", input, opts)
      end

      assert {:error, {:conflict, "MOT-40 is a pull request; decisions is for a plan"}} =
               DirectorMoves.move(:decisions, "MOT-40", %{picks: [%{question: "Q", answer: "B"}]}, opts)
    end

    test "fails when Linear refuses the move, before posting anything", %{opts: opts} do
      put_issues([plan("Human Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      assert {:error, {:linear, :boom}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B"}]}, opts)
      refute_received {:memory_tracker_comment, _id, _body}

      # On a plan in In Review nothing moved, so a refused comment is Linear's error alone.
      put_issues([plan("In Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :comment_failed}])
      assert {:error, {:linear, :comment_failed}} = DirectorMoves.move(:decisions, "MOT-30", %{picks: [%{question: "Q", answer: "B"}]}, opts)
      assert audit_records() == []
    end
  end

  describe "a move Linear takes only half of" do
    test "decisions moved to In Review whose comment Linear refuses keep the move, its audit record and its undo", %{opts: opts} do
      put_issues([plan("Human Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [{:error, :comment_failed}])
      picks = %{picks: [%{question: "Q", answer: "B"}]}

      assert {:error, {:partial, message}} = DirectorMoves.move(:decisions, "MOT-30", picks, opts)
      assert message == "moved MOT-30 to In Review, but Linear refused the decisions comment (:comment_failed); send the decisions again"
      assert_received {:memory_tracker_state_update, "plan", "In Review"}
      refute_received {:memory_tracker_comment, _id, _body}

      assert [%{"move" => "decisions", "from_state" => "Human Review", "to_state" => "In Review", "failed" => "comment"}] =
               audit_records()

      # Sent again, the plan is in In Review: the comment goes, with no second move.
      put_issues([plan("In Review")])
      assert {:ok, %{moved: false, commented: true}} = DirectorMoves.move(:decisions, "MOT-30", picks, opts)
      assert_received {:memory_tracker_comment, "plan", _body}
      refute_received {:memory_tracker_state_update, _id, _state}

      assert {:ok, %{undone: "decisions", to_state: "Human Review"}} = DirectorMoves.undo("MOT-30", opts)
    end

    test "a rework comment whose move Linear refuses is recorded, and not posted twice when sent again", %{opts: opts} do
      put_issues([pr("In Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_failed}])

      assert {:error, {:partial, message}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)

      assert message ==
               "posted the comment on MOT-40, but Linear refused the move to Rework (:state_failed); send it again to make the move without posting the comment twice"

      assert_received {:memory_tracker_comment, "pr", "Sent to Rework by the Director:\n\nNo"}

      assert [%{"move" => "rework", "from_state" => "In Review", "to_state" => "In Review", "comment" => "Sent to Rework by the Director:\n\nNo", "failed" => "move"}] =
               audit_records()

      assert {:ok, %{to_state: "Rework", commented: true}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)
      refute_received {:memory_tracker_comment, _id, _body}
      assert_received {:memory_tracker_state_update, "pr", "Rework"}

      # Once the move went through, the same reason later is a new comment.
      assert {:ok, _result} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)
      assert_received {:memory_tracker_comment, "pr", _body}
    end

    test "a different reason, or the ticket in another state, posts the comment again", %{opts: opts} do
      put_issues([pr("In Review")])
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

  describe "sign_off" do
    test "moves a final verification in review to Done, and refuses anything else", %{opts: opts} do
      put_issues([final_verification("Human Review"), pr("In Review")])

      assert {:ok, %{to_state: "Done"}} = DirectorMoves.move(:sign_off, "MOT-50", %{}, opts)
      assert_received {:memory_tracker_state_update, "verify", "Done"}
      assert {:error, {:conflict, "MOT-40 is a pull request; sign_off is for a final verification"}} = DirectorMoves.move(:sign_off, "MOT-40", %{}, opts)
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
    end

    test "refuses a ticket with no hold, and one waiting on something other than access", %{opts: opts} do
      put_issues([pr("In Progress")])
      assert {:error, {:conflict, "MOT-40 is not waiting on an access hold"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)

      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      :ok = Hold.set("repo-director", "pr", :blocked, %{reason: "waiting on MOT-1", waits_on: %{type: "dependency", keys: ["MOT-1"]}})

      assert {:error, {:conflict, "MOT-40 is not waiting on an access hold"}} = DirectorMoves.move(:unblock, "MOT-40", %{}, opts)
      assert Hold.held?("repo-director", "pr", :blocked)
      refute_received {:memory_tracker_comment, _id, _body}
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

      assert {:error, {:invalid, "request_comment_id is required"}} =
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

      # A legacy ticket never carries the hold, so a decision never lands on one.
      put_issues([pr("In Progress")])

      assert {:error, {:conflict, "MOT-40 is not waiting on a decision"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c"}, opts)

      refute_received {:memory_tracker_reply, _issue_id, _parent, _body}
    end

    test "answers a request that parked the ticket in Human Review with no hold, then moves it to Todo", %{opts: opts} do
      # A legacy repo's request, and one made before the repo moved to the designed machine.
      for issue <- [pr("Human Review"), %{pr("Human Review") | repo_key: "repo-director"}] do
        put_issues([issue])

        assert {:ok, %{moved: true, from_state: "Human Review", to_state: "Todo"}} =
                 DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, opts)

        assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
        assert_received {:memory_tracker_state_update, "pr", "Todo"}
      end

      put_issues([pr("Human Review")])

      assert {:ok, %{to_state: "Rework"}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1", move: "rework"}, opts)

      assert_received {:memory_tracker_state_update, "pr", "Rework"}
    end

    test "a reply Linear refuses on a parked request moves nothing", %{opts: opts} do
      put_issues([pr("Human Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :reply_failed})

      assert {:error, {:linear, :reply_failed}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "c"}, opts)

      refute_received {:memory_tracker_state_update, _issue_id, _state}
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
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
    end

    test "the decision answers at once while the orchestrator is too busy to take the refresh", %{opts: opts} do
      put_issues([%{pr("In Progress") | repo_key: "repo-director"}])
      set_decision_hold()
      test_pid = self()

      # An orchestrator still busy with a poll: it takes the refresh request and never replies.
      busy =
        spawn(fn ->
          receive do
            {:"$gen_call", {caller, _tag}, :request_refresh} ->
              send(test_pid, {:refresh_requested, caller})
              Process.sleep(:infinity)
          end
        end)

      assert {:ok, %{move: "decide", moved: false}} =
               DirectorMoves.move(:decide, "MOT-40", %{picks: picks(), request_comment_id: "comment-1"}, Keyword.put(opts, :orchestrator, busy))

      assert_received {:memory_tracker_reply, "pr", "comment-1", _comment}
      refute Hold.held?("repo-director", "pr", :needs_decision)
      assert_receive {:refresh_requested, caller}

      # The orchestrator going away mid-call ends the request with a warning, not a crash.
      ref = Process.monitor(caller)

      log =
        capture_log(fn ->
          Process.exit(busy, :kill)
          assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
        end)

      assert log =~ "Director move couldn't ask the orchestrator to poll again"
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
      assert {:error, :issue_not_found} = DirectorMoves.move(:approve_pr, "MOT-404", %{}, opts)
      assert {:error, :issue_not_found} = DirectorMoves.undo("MOT-404", opts)
    end

    test "Linear's errors come back, and a failed comment leaves the state alone", %{opts: opts} do
      put_issues([pr("In Review")])
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :comment_failed})

      assert {:error, {:linear, :comment_failed}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)
      refute_received {:memory_tracker_state_update, _id, _state}

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :state_failed})
      assert {:error, {:linear, :state_failed}} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
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
        assert DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts) == expected
      end
    after
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :director_moves_test_fetch)
    end
  end

  describe "undo" do
    test "moves the ticket back within 10 s, once", %{opts: opts, clock: clock} do
      put_issues([pr("In Review")])
      assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      assert_received {:memory_tracker_state_update, "pr", "Merging"}

      put_issues([pr("Merging")])
      :counters.put(clock, 1, 10_000)

      assert {:ok, %{move: "undo", undone: "approve_pr", from_state: "Merging", to_state: "In Review"}} = DirectorMoves.undo("MOT-40", opts)
      assert_received {:memory_tracker_state_update, "pr", "In Review"}
      assert [%{"move" => "approve_pr"}, %{"move" => "undo", "from_state" => "Merging", "to_state" => "In Review"}] = audit_records()

      assert {:error, {:conflict, "there is no move on MOT-40 to undo"}} = DirectorMoves.undo("MOT-40", opts)
    end

    test "refuses after 10 s", %{opts: opts, clock: clock} do
      put_issues([pr("In Review")])
      assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      put_issues([pr("Merging")])
      :counters.put(clock, 1, 10_001)

      assert {:error, {:conflict, "the move on MOT-40 is more than 10 s old; move it in Linear instead"}} = DirectorMoves.undo("MOT-40", opts)
      refute_received {:memory_tracker_state_update, "pr", "In Review"}
    end

    test "refuses once the ticket moved on", %{opts: opts} do
      put_issues([pr("In Review")])
      assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      put_issues([pr("Done")])

      assert {:error, {:conflict, "MOT-40 moved on to Done since; move it in Linear instead"}} = DirectorMoves.undo("MOT-40", opts)
    end

    test "refuses an approved plan once Symphony promoted its sub-tickets", %{opts: opts} do
      backlog = [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}]
      put_issues([%{plan("In Review") | sub_issues: backlog}])
      assert {:ok, _result} = DirectorMoves.move(:approve_plan, "MOT-30", %{}, opts)

      put_issues([%{plan(@waiting) | sub_issues: [%{hd(backlog) | state: "Todo"}]}])

      assert {:error, {:conflict, "Symphony already promoted the sub-tickets of MOT-30; move them in Linear instead"}} =
               DirectorMoves.undo("MOT-30", opts)

      put_issues([%{plan(@waiting) | sub_issues: backlog}])
      assert {:ok, %{to_state: "In Review"}} = DirectorMoves.undo("MOT-30", opts)
    end

    test "fails when Linear refuses the move back, and keeps the move to undo", %{opts: opts} do
      put_issues([pr("In Review")])
      assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      put_issues([pr("Merging")])
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :boom}])

      assert {:error, {:linear, :boom}} = DirectorMoves.undo("MOT-40", opts)
      assert {:ok, _result} = DirectorMoves.undo("MOT-40", opts)
    end
  end

  describe "undo of approve_pr" do
    @pr_url "https://github.com/example/repo/pull/40"

    test "turns GitHub auto-merge off before moving the ticket back, and forgets the poller's auto-merge state", %{opts: opts} do
      auto_merge = %{state: "enabled", head_sha: "head-1", enabled_head_sha: "head-1"}
      :ok = RunStore.put_pr_review(%{repo_key: "default", issue_id: "pr", pr_url: @pr_url, auto_merge: auto_merge})
      approve_then_merging(opts, repo_key: "default")
      github_activity(state: "OPEN", auto_merge_enabled: true)

      log = capture_log(fn -> assert {:ok, %{undone: "approve_pr", to_state: "In Review"}} = DirectorMoves.undo("MOT-40", opts) end)

      assert [{:fetch_activity, @pr_url}, {:disable_auto_merge, @pr_url, "PR_node"}, {:memory_tracker_state_update, "pr", "In Review"}] =
               mailbox()

      assert log =~ "Director undo turned GitHub auto-merge off issue_id=pr issue_identifier=MOT-40"
      assert PrReviewPoller.auto_merge("pr", repo_key: "default") == nil
    end

    test "with auto-merge off, or no pull request on the ticket, just moves it back", %{opts: opts} do
      approve_then_merging(opts)
      github_activity(state: "OPEN", auto_merge_enabled: false)
      assert {:ok, %{to_state: "In Review"}} = DirectorMoves.undo("MOT-40", opts)
      assert [{:fetch_activity, @pr_url}, {:memory_tracker_state_update, "pr", "In Review"}] = mailbox()

      put_issues([pr("In Review")])
      assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts)
      put_issues([pr("Merging")])
      mailbox()
      assert {:ok, %{to_state: "In Review"}} = DirectorMoves.undo("MOT-40", opts)
      assert [{:memory_tracker_state_update, "pr", "In Review"}] = mailbox()
    end

    test "refuses a pull request that already merged", %{opts: opts} do
      approve_then_merging(opts)
      github_activity(state: "MERGED", auto_merge_enabled: true)

      assert {:error, {:conflict, "MOT-40 already merged; move it in Linear instead"}} = DirectorMoves.undo("MOT-40", opts)
      assert [{:fetch_activity, @pr_url}] = mailbox()
    end

    test "answers GitHub's error and leaves the ticket in Merging when GitHub refuses or can't be read", %{opts: opts} do
      approve_then_merging(opts)
      github_activity(state: "OPEN", auto_merge_enabled: true)
      Application.put_env(:symphony_elixir, :director_moves_test_disable, {:error, :forbidden})

      assert {:error, {:github, message}} = DirectorMoves.undo("MOT-40", opts)
      assert message == "GitHub refused to turn auto-merge off on #{@pr_url} (:forbidden); MOT-40 stays in Merging"
      assert [{:fetch_activity, @pr_url}, {:disable_auto_merge, @pr_url, "PR_node"}] = mailbox()

      github_activity(state: "OPEN", auto_merge_enabled: true, pr_node_id: nil)
      assert {:error, {:github, "GitHub refused to turn auto-merge off on " <> rest}} = DirectorMoves.undo("MOT-40", opts)
      assert rest =~ "(:missing_pr_node_id)"

      Application.put_env(:symphony_elixir, :director_moves_test_activity, {:error, :gh_down})
      assert {:error, {:github, "couldn't read #{@pr_url} (:gh_down); MOT-40 stays in Merging"}} == DirectorMoves.undo("MOT-40", opts)
      refute_received {:memory_tracker_state_update, "pr", "In Review"}

      # The move is still there to undo once GitHub answers.
      github_activity(state: "OPEN", auto_merge_enabled: true)
      Application.put_env(:symphony_elixir, :director_moves_test_disable, :ok)
      capture_log(fn -> assert {:ok, %{to_state: "In Review"}} = DirectorMoves.undo("MOT-40", opts) end)
      assert_received {:memory_tracker_state_update, "pr", "In Review"}
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
    assert {:error, :issue_not_found} = DirectorMoves.move(:approve_pr, "MOT-404", %{})
    assert {:error, :issue_not_found} = DirectorMoves.undo("MOT-404")
  end

  test "lists its moves and its undo window" do
    assert DirectorMoves.moves() == [:approve_plan, :approve_pr, :rework, :restart, :decisions, :sign_off, :backlog, :unblock, :decide]
    assert DirectorMoves.undo_window_ms() == 10_000
  end

  test "an audit log that can't be written still makes the move", %{opts: opts} do
    put_issues([pr("In Review")])
    blocker = Path.join(System.tmp_dir!(), "director-moves-blocker-#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(blocker, "audit"))

    log = capture_log(fn -> assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, opts) end)
    assert log =~ "Failed to record director_move audit event"
  after
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(System.tmp_dir!(), "unused"))
  end

  defp approve_then_merging(opts, fields \\ []) do
    issue = struct(pr("In Review"), [pr_urls: [@pr_url]] ++ fields)
    put_issues([issue])
    assert {:ok, _result} = DirectorMoves.move(:approve_pr, "MOT-40", %{}, Keyword.put(opts, :github, FakeGitHub))
    put_issues([%{issue | state: "Merging"}])
    mailbox()
  end

  defp github_activity(fields) do
    Application.put_env(:symphony_elixir, :director_moves_test_activity, {:ok, Map.merge(%{pr_url: @pr_url, pr_node_id: "PR_node"}, Map.new(fields))})
  end

  defp mailbox do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.each(messages, fn message -> receive do: (^message -> :ok) end)
    messages
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

  defp set_decision_hold do
    :ok =
      Hold.set("repo-director", "pr", :needs_decision, %{
        reason: "Add the signing secrets, or ship unsigned builds?",
        clearing_condition: "when the decision is recorded",
        decision: %{title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"}
      })
  end

  defp plan(state), do: %Issue{id: "plan", identifier: "MOT-30", title: "Plan an MVP", state: state, labels: ["plan"]}
  defp pr(state), do: %Issue{id: "pr", identifier: "MOT-40", title: "Add checkout", state: state, labels: []}
  defp final_verification(state), do: %Issue{id: "verify", identifier: "MOT-50", title: "Final verification: Plan an MVP", state: state}

  defp audit_records do
    {:ok, stream} = AuditLog.query(event_type: "director_move")
    Enum.to_list(stream)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
