defmodule SymphonyElixir.OrchestratorPlanCommentsTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{PlanComments, RunKind, SubIssueWait}

  @waiting "Waiting on sub-tickets"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)
    :ok
  end

  test "a person's comment on a plan under review sends the parent back for a revision run" do
    backlog = [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}, %{id: "child-2", identifier: "MOT-32", state: "Backlog"}]
    parent = parent("In Review", backlog, [~U[2026-10-04 12:10:00Z]])

    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [
      comment("c1", "Split MOT-32 in two", ~U[2026-10-04 12:10:00Z])
    ])

    log = capture_log([level: :info], fn -> send(self(), {:state, act(state(), parent)}) end)

    assert_received {:state, state}
    assert_received {:memory_tracker_plan_comments, "parent"}
    assert_received {:memory_tracker_state_update, "parent", "In Progress"}
    assert log =~ "Moved breakdown parent to In Progress to revise its plan from 1 new comment(s)"
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:10:00Z]}

    # Back in In Progress, the parent's never-approved plan is not held: the revision run is a breakdown run.
    revising = %{parent | state: "In Progress"}
    assert Orchestrator.should_dispatch_issue_for_test(revising, state)
    assert RunKind.classify(revising) == :breakdown

    # Nothing is promoted and the same comment is not read again.
    assert Orchestrator.act_on_plan_comments_for_test(state, [parent]) == state
    refute_received {:memory_tracker_plan_comments, _issue_id}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a person's comment on an unapproved plan in Human Review starts no run and leaves the parent there" do
    parent = parent("Human Review", [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}], [~U[2026-10-04 12:10:00Z]])

    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Review", "Human Review")], [
      comment("c1", "Split MOT-31 in two", ~U[2026-10-04 12:10:00Z])
    ])

    log = capture_log([level: :info], fn -> assert act(state(), parent) == state() end)

    refute_received {:memory_tracker_plan_comments, _issue_id}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    refute log =~ "revise its plan"
  end

  test "a supervisor's note on a plan under review starts no run" do
    parent = parent("In Review", [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}], [~U[2026-10-04 12:11:00Z]])

    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [
      comment("s1", "Supervisor review: plan reviewed, Tony decides. MOT-31 could be split.", ~U[2026-10-04 12:10:00Z]),
      comment("s2", "Supervisor note: MOT-31 overlaps MOT-30's journey", ~U[2026-10-04 12:11:00Z])
    ])

    state = act(state(), parent)

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:11:00Z]}
  end

  test "Symphony's own comments and integration bots start no run" do
    parent = parent("In Review", [], [~U[2026-10-04 12:20:00Z]])

    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [
      comment("workpad", "## Symphony Workpad\n\nPlan", ~U[2026-10-04 12:05:00Z]),
      comment("action", "## Action needed: free Linear capacity", ~U[2026-10-04 12:06:00Z]),
      comment("linkback", "Linked to a pull request", ~U[2026-10-04 12:07:00Z], bot?: true),
      comment("reply", "Done: MOT-32 is now two tickets.", ~U[2026-10-04 11:58:00Z], parent_id: "old")
    ])

    state = Orchestrator.act_on_plan_comments_for_test(state(), [parent])

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    # Read once; only a newer comment reads Linear again.
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:20:00Z]}
  end

  test "a comment made before the last run ended does not start another one" do
    parent = parent("In Review", [], [~U[2026-10-04 12:10:00Z]])
    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [comment("c1", "Thanks", ~U[2026-10-04 12:10:00Z])])
    state = %{state() | completed_run_metadata: %{"parent" => %{last_ran_at: ~U[2026-10-04 12:15:00Z]}}}

    Orchestrator.act_on_plan_comments_for_test(state, [parent])

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a person's comment made while a revision run worked is picked up once the parent is back in In Review" do
    parent = parent("In Review", [%{id: "child-1", identifier: "MOT-31", state: "Backlog"}], [~U[2026-10-04 12:40:00Z]])

    # The revision run started at 12:20, read c1, answered it at 12:35 and moved the parent back to
    # In Review at 12:38. Tony commented at 12:30, while the parent was In Progress.
    put_feedback(
      "parent",
      [
        change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review"),
        change(~U[2026-10-04 12:15:00Z], "In Review", "In Progress"),
        change(~U[2026-10-04 12:38:00Z], "In Progress", "In Review")
      ],
      [
        comment("c1", "Split MOT-32 in two", ~U[2026-10-04 12:10:00Z]),
        comment("c2", "Also rename MOT-31", ~U[2026-10-04 12:30:00Z]),
        comment("run-reply", "Done: MOT-32 is now MOT-32 and MOT-33.", ~U[2026-10-04 12:35:00Z], parent_id: "c1"),
        comment("run-artifact", "## Journeys\n\nChanged: history split", ~U[2026-10-04 12:36:00Z])
      ]
    )

    run = %{started_at: ~U[2026-10-04 12:20:00Z], last_ran_at: ~U[2026-10-04 12:40:00Z], comment_ids: ["run-reply", "run-artifact"]}
    state = %{state() | completed_run_metadata: %{"parent" => run}, plan_comment_checks: %{"parent" => ~U[2026-10-04 12:10:00Z]}}

    log = capture_log([level: :info], fn -> send(self(), {:state, act(state, parent)}) end)

    assert_received {:state, state}
    assert_received {:memory_tracker_state_update, "parent", "In Progress"}
    assert log =~ "from 1 new comment(s)"
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:40:00Z]}

    # Once the next run answers c2 under its thread, the run's own comments start nothing.
    put_feedback("parent", [change(~U[2026-10-04 12:58:00Z], "In Progress", "In Review")], [
      comment("c2", "Also rename MOT-31", ~U[2026-10-04 12:30:00Z]),
      comment("run-2-reply", "Done: MOT-31 is renamed.", ~U[2026-10-04 12:55:00Z], parent_id: "c2")
    ])

    run = %{started_at: ~U[2026-10-04 12:45:00Z], last_ran_at: ~U[2026-10-04 13:00:00Z], comment_ids: ["run-2-reply"]}
    state = %{state | completed_run_metadata: %{"parent" => run}}
    act(state, %{parent | comments: [%{author: "Tony", body: "comment", created_at: ~U[2026-10-04 12:55:00Z]}]})

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a read of the comments that crashes, or cannot start, leaves them to the next poll" do
    parent = parent("In Review", [], [~U[2026-10-04 12:10:00Z]])
    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, :unreadable)

    log = capture_log(fn -> send(self(), {:state, act(state(), parent)}) end)

    assert_received {:state, state}
    assert_received {:memory_tracker_plan_comments, "parent"}
    assert log =~ "Async Linear task plan_comments exited before replying"
    assert state.plan_comment_checks == %{}
    assert state.tracker_tasks == %{}

    put_feedback("parent", [change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [comment("c1", "Split it", ~U[2026-10-04 12:10:00Z])])
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.TaskSupervisor)

    log = capture_log(fn -> send(self(), {:state, act(state(), parent)}) end)

    assert_received {:state, state}
    assert log =~ "Failed to start async Linear task plan_comments: :task_supervisor_unavailable"
    assert state.plan_comment_checks == %{}
    refute_received {:memory_tracker_plan_comments, _issue_id}
  end

  test "a comment on an approved plan gets one reply under its thread and changes nothing" do
    approved = [%{id: "child-1", identifier: "MOT-31", state: "In Progress"}]
    parent = parent(@waiting, approved, [~U[2026-10-04 12:10:00Z], nil])

    put_feedback("parent", [change(~U[2026-10-04 11:00:00Z], "In Review", @waiting)], [
      comment("c1", "Can we drop the history screen?", ~U[2026-10-04 12:05:00Z]),
      comment("c2", "And rename it", ~U[2026-10-04 12:10:00Z], parent_id: "c1")
    ])

    state = Orchestrator.act_on_plan_comments_for_test(state(), [parent])

    assert_received {:memory_tracker_reply, "parent", "c1", reply}
    assert reply == PlanComments.reply("MOT-30")
    assert reply =~ ~r/^If this asks for a change to the plan: /
    refute_received {:memory_tracker_reply, _issue_id, _thread_id, _body}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:10:00Z]}
    refute Orchestrator.should_dispatch_issue_for_test(parent, state)
  end

  test "a note in a thread on an approved plan, or a comment from before Symphony started, gets no reply" do
    approved = [%{id: "child-1", identifier: "MOT-31", state: "In Progress"}]
    parent = parent(@waiting, approved, [~U[2026-10-04 12:20:00Z]])

    put_feedback("parent", [change(~U[2026-10-04 11:00:00Z], "In Review", @waiting)], [
      comment("status", "MOT-31 is halfway, MOT-32 next", ~U[2026-10-04 11:30:00Z]),
      comment("status-reply", PlanComments.reply("MOT-30"), ~U[2026-10-04 11:31:00Z], parent_id: "status"),
      comment("fyi", "FYI: the design review moved to Friday", ~U[2026-10-04 12:20:00Z], parent_id: "status")
    ])

    state = act(state(), parent)

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_reply, _issue_id, _thread_id, _body}
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:20:00Z]}

    # The first poll after a restart: a parent already waiting gets no burst of replies to old comments.
    put_feedback("parent", [change(~U[2026-10-04 11:00:00Z], "In Review", @waiting)], [
      comment("question", "Should MOT-32 wait for the API?", ~U[2026-10-04 12:20:00Z])
    ])

    state = act(%{state() | plan_comments_since: ~U[2026-10-04 13:00:00Z]}, parent)

    assert_received {:memory_tracker_plan_comments, "parent"}
    refute_received {:memory_tracker_reply, _issue_id, _thread_id, _body}
    assert state.plan_comment_checks == %{"parent" => ~U[2026-10-04 12:20:00Z]}
  end

  test "retries on the next poll when Linear fails" do
    parent = parent("In Review", [], [~U[2026-10-04 12:10:00Z]])
    feedback = %{"parent" => feedback([change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review")], [comment("c1", "Split it", ~U[2026-10-04 12:10:00Z])])}

    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, {:error, :timeout})
    log = capture_log(fn -> assert act(state(), parent).plan_comment_checks == %{} end)
    assert log =~ "Failed to read comments on breakdown parent"

    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, feedback)
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})
    log = capture_log(fn -> assert act(state(), parent).plan_comment_checks == %{} end)
    assert log =~ "Failed to move breakdown parent to In Progress for its plan's comments"

    approved = %{parent | state: @waiting, sub_issues: [%{id: "child-1", identifier: "MOT-31", state: "Todo"}]}

    Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, %{
      "parent" => feedback([change(~U[2026-10-04 12:00:00Z], "In Review", @waiting)], [comment("c1", "Split it", ~U[2026-10-04 12:10:00Z])])
    })

    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
    log = capture_log(fn -> assert act(state(), approved).plan_comment_checks == %{} end)
    assert log =~ "Failed to reply to a comment on an approved breakdown plan"
  end

  test "skips parents that are running, have no dated comment, or are not breakdown parents under review" do
    parent = parent("In Review", [], [~U[2026-10-04 12:10:00Z]])
    state = %{state() | claimed: MapSet.new(["parent"])}

    assert Orchestrator.act_on_plan_comments_for_test(state, [parent]) == state
    assert act(state(), %{parent | comments: [%{author: "x", body: "y", created_at: nil}]}) == state()
    assert Orchestrator.act_on_plan_comments_for_test(state(), [%{parent | comments: nil}]) == state()
    assert Orchestrator.act_on_plan_comments_for_test(state(), [%{parent | state: "In Progress"}]) == state()
    assert Orchestrator.act_on_plan_comments_for_test(state(), [%{parent | labels: []}]) == state()
    refute_received {:memory_tracker_plan_comments, _issue_id}
  end

  defp act(state, issue), do: Orchestrator.act_on_plan_comments_for_test(state, [issue])

  defp parent(state, sub_issues, comment_times) do
    %Issue{
      id: "parent",
      identifier: "MOT-30",
      title: "Plan an MVP",
      state: state,
      labels: ["breakdown"],
      sub_issues: sub_issues,
      comments: Enum.map(comment_times, &%{author: "Tony", body: "comment", created_at: &1})
    }
  end

  defp put_feedback(issue_id, changes, comments),
    do: Application.put_env(:symphony_elixir, :memory_tracker_plan_comments, %{issue_id => feedback(changes, comments)})

  defp feedback(changes, comments), do: %{state_changes: changes, comments: comments}

  defp change(at, from, to), do: %{at: at, from: from, to: to}

  defp comment(id, body, created_at, opts \\ []) do
    %{id: id, body: body, created_at: created_at, parent_id: Keyword.get(opts, :parent_id), bot?: Keyword.get(opts, :bot?, false)}
  end

  defp state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
