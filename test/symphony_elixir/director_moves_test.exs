defmodule SymphonyElixir.DirectorMovesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AuditLog, DirectorMoves, PlanComments, PrReviewPoller, SubIssueWait}

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
  end

  defmodule CannedLinearClient do
    def fetch_issue_by_identifier(_identifier), do: Application.fetch_env!(:symphony_elixir, :director_moves_test_fetch)
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

    test "needs a reason and a ticket in review", %{opts: opts} do
      put_issues([pr("In Progress")])

      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "  "}, opts)
      assert {:error, {:invalid, "reason is required"}} = DirectorMoves.move(:rework, "MOT-40", %{}, opts)
      assert {:error, {:conflict, _message}} = DirectorMoves.move(:rework, "MOT-40", %{reason: "No"}, opts)
      refute_received {:memory_tracker_comment, _id, _body}
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
    assert DirectorMoves.moves() == [:approve_plan, :approve_pr, :rework, :decisions, :sign_off, :backlog]
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
