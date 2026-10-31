defmodule SymphonyElixir.AgentRunnerProgressTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.PrWatchSupport
  alias SymphonyElixir.Questions
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketState
  alias SymphonyElixir.WorkspaceHead

  @pr_url "https://github.com/example/repo/pull/337"
  @now_ms 1_791_000_000_000
  @rate_limited {:error, {:linear_rate_limited, 1_791_000_030_000}}

  defmodule ProgressAgent do
    # Coding-agent stand-in: every turn completes and is reported to the test, or, with
    # `:progress_api_unreachable` set, ends as Claude's turn does when it can't reach the model API.
    # `:progress_turn_hook` runs with the turn's options, as a tool the agent calls would.
    def start_session(_workspace, opts) do
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_session_started, opts})
      {:ok, %{}}
    end

    def run_turn(_session, _prompt, _issue, opts) do
      count = Application.get_env(:symphony_elixir, :progress_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :progress_agent_turns, count)
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_turn, count})
      if hook = Application.get_env(:symphony_elixir, :progress_turn_hook), do: hook.(opts)

      case Application.get_env(:symphony_elixir, :progress_api_unreachable) do
        %{} = info -> {:error, {:model_api_unreachable, info}}
        nil -> {:ok, %{session_id: "sess-#{count}"}}
      end
    end

    def stop_session(_session), do: :ok
  end

  defmodule ProgressGitHub do
    # Stands in for GitHub.PullRequest.fetch_ci_status/2 and reports the configured PR head;
    # `{:by_turn, results}` gives the result read after each turn (the last one repeats).
    def fetch_ci_status(pr_url, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:pr_head_fetched, pr_url})

      case Application.fetch_env!(:symphony_elixir, :progress_pr_head_result) do
        {:by_turn, results} -> Enum.at(results, Application.get_env(:symphony_elixir, :progress_agent_turns, 1) - 1) || List.last(results)
        result -> result
      end
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :progress_agent_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-rework", checks: []}})
    RunStore.delete_ticket_state("default", "issue-progress")

    on_exit(fn ->
      RunStore.delete_ticket_state("default", "issue-progress")

      for key <- [
            :progress_agent_recipient,
            :progress_agent_turns,
            :progress_pr_head_result,
            :progress_api_unreachable,
            :progress_turn_hook,
            :memory_tracker_update_issue_state_result,
            :memory_tracker_create_comment_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  test "a Rework run whose new commits are the PR head moves to Code Review without another turn" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")

    assert turns() == 1
    assert_received {:pr_head_fetched, @pr_url}
    assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
  end

  describe "the designed handoff signal" do
    defp designed_repos do
      [[key: "default", workflow: Workflow.workflow_file_path(), team: "Test"]]
    end

    test "a run that ends quietly with a PR open does not advance" do
      assert_raise RuntimeError, ~r/rework_handoff_failed.*handoff_signal_missing/, fn ->
        run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())
      end

      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff_missing", %{to: "Code Review", reason: "after rework"})
    end

    test "the explicit handoff signal moves the ticket to Code Review" do
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})

      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "after rework", head: "sha-rework", move: true})
    end

    test "a signal for another head does not advance this run" do
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-other", branch: "auto/TP-337"})

      assert_raise RuntimeError, ~r/rework_handoff_failed.*handoff_signal_missing/, fn ->
        run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())
      end

      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "an In Progress run whose PR is already on its head hands off to Code Review after one quiet turn" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})

      assert :ok = run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert_signal("handoff", %{to: "Code Review", reason: "with its PR already on its head", head: "sha-pushed", move: true})
    end

    test "a quiet In Progress run whose PR head can't be read hands nothing off" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:error, :unavailable})

      assert :ok = run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
    end

    test "a failed move after the quiet handoff fails the run" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

      assert_raise RuntimeError, ~r/pushed_pr_head_handoff_failed/, fn ->
        run_issue!("In Progress", heads: ["sha-pushed"], repos: designed_repos())
      end
    end

    test "an earlier run's own move record does not advance a later head" do
      # First cycle: a real handoff signal advances the ticket to Code Review, and the run records
      # its own move in the ledger.
      assert :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: "sha-rework", branch: "auto/TP-337"})
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}

      # Second cycle: a later Rework run pushes a new head to the PR and emits no signal of its own.
      # The earlier run's move record is bound to the earlier head, so it must not stand in for this
      # run's signal.
      next_run()
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-new", checks: []}})

      assert_raise RuntimeError, ~r/rework_handoff_failed.*handoff_signal_missing/, fn ->
        run_issue!("Rework", heads: ["sha-rework", "sha-new"], repos: designed_repos())
      end

      refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end
  end

  test "a re-dispatched Rework run whose rework an earlier run pushed moves on after one empty turn" do
    run_issue!("Rework", heads: ["sha-old"], handoff: "sha-old", max_turns: 1)

    assert RunStore.get_rework_base("default", "issue-progress") == "sha-old"
    refute_received {:memory_tracker_state_update, _issue_id, _state}

    next_run()
    run_issue!("Rework", heads: ["sha-rework"], handoff: "sha-rework")

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    assert RunStore.get_rework_base("default", "issue-progress") == nil
  end

  test "a fresh Rework run that starts on the PR head does not move on after an empty turn" do
    run_issue!("Rework", heads: ["sha-rework"], states: ["Rework", "Todo"])

    assert turns() == 2
    refute_received {:memory_tracker_state_update, _issue_id, _state}
    assert RunStore.get_rework_base("default", "issue-progress") == nil
  end

  test "a Rework run with unresolved review comments on the current head keeps going" do
    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: "default",
               issue_id: "issue-progress",
               issue_identifier: "TP-337",
               pr_url: @pr_url,
               workspace_path: "/tmp",
               status: "rework_requested",
               pending_last_addressed_comment_id: "comment-337",
               pending_reviewer_comments: [%{id: "comment-337", kind: "inline_comment", author: "Reviewer", body: "Rename this."}],
               updated_at: ~U[2026-10-03 12:00:00Z]
             })

    run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

    assert turns() == 2
    refute_received {:pr_head_fetched, _pr_url}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a Rework run keeps going while its commits are not the PR head or the head is unreadable" do
    for pr_head_result <- [{:ok, %{commit_sha: "sha-old", checks: []}}, {:error, :gh_unavailable}] do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
      next_run()

      run_issue!("Rework", heads: ["sha-old", "sha-rework", "sha-rework-2"], states: ["Rework", "Done"])

      assert turns() == 2
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end
  end

  test "two consecutive empty turns stop the run and park the issue in Backlog" do
    run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)

    assert turns() == 2
    assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue in Backlog" <> _note}
    assert_signal("blocked", %{to: "Backlog", reason: "idle_park", from: "In Progress"})
  end

  describe "a parked ticket (TP-1326)" do
    test "asks its question in Backlog, held until a person answers it" do
      run_issue!("Rework", heads: ["sha-same"], pr_url: nil, max_turns: 5)

      assert [%{title: "TP-337 is parked: its last 2 turns changed nothing", options: [%{label: "Run it again"} | _]} = question] =
               Questions.open({:ticket, "default", "issue-progress"})

      assert {:ok, %{reasons: [%{kind: :question, waits_on: %{question_id: id}}]}} = Pauses.get({:ticket, "default", "issue-progress"})
      assert id == question.id
      assert_signal("blocked", %{to: "Backlog", reason: "idle_park", from: "Rework"})
      record = TicketState.normalize(RunStore.get_ticket_state("default", "issue-progress"))
      assert record.phase == "Backlog"
      assert %{kind: :action, state: "Backlog"} = Item.from_question(record, question)
    end

    test "is paused on a reason Unblock releases when its question can't be asked" do
      # An identifier the question's plain-words check refuses.
      issue = %Issue{id: "issue-progress", identifier: "`TP-337`", state: "In Progress", repo_key: "default"}
      fetcher = fn _ids -> {:ok, [issue]} end

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, issue_state_fetcher: fetcher) end)

      assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}

      assert {:ok, %{reasons: [%{kind: :environment, waits_on: %{condition: "idle_park"}, releasable: true, text: text}]}} =
               Pauses.get({:ticket, "default", "issue-progress"})

      assert text == "2 turns in In Progress made no new commit and no state change, so Symphony parked it in Backlog"
      assert Questions.open({:ticket, "default", "issue-progress"}) == []
      assert log =~ "Failed to ask the park's question"
    end

    test "pushes its unpushed commits first, and parks whatever the push says" do
      test_pid = self()

      for {result, logged} <- [
            {{:pushed, "auto/TP-337"}, "Pushed issue_id=issue-progress issue_identifier=TP-337's unpushed commits to origin auto/TP-337 before parking it"},
            {{:error, :origin_mismatch}, "they stay in its workspace reason=:origin_mismatch"},
            {:nothing, "Parking"}
          ] do
        next_run()
        pusher = fn workspace, nil, _source_repo -> send(test_pid, {:pushed_from, workspace}) && result end

        opts = [heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: [workspace_pusher: pusher]]
        log = capture_log(fn -> run_issue!("In Progress", opts) end)

        assert_received {:pushed_from, workspace}
        assert workspace =~ "TP-337"
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert log =~ logged
      end
    end
  end

  describe "a run whose ticket waits on a decision" do
    test "ends after the turn that set the Needs Decision hold, without parking it or handing it off" do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
        :ok = SymphonyElixir.Hold.set("default", "issue-progress", :needs_decision, %{reason: "Which reading is right?"})
      end)

      run_issue!("In Progress", heads: ["sha-rework"], repos: designed_repos(), max_turns: 5)

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
    end

    test "ends after the turn that posted the request, even before its hold is in the store" do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn opts ->
        CommentRegistry.record_human_action_request(Keyword.fetch!(opts, :linear_comment_registry))
      end)

      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)

      assert turns() == 1
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
    end
  end

  test "a turn that can't reach the model API ends the run on the provider hold, so outage turns never park the issue" do
    info = outage_info()
    Application.put_env(:symphony_elixir, :progress_api_unreachable, info)

    # Two runs in a row during the outage: each ends on its first turn, before the empty-turn check.
    for run <- 1..2 do
      assert {:model_api_unreachable, ^info} = catch_exit(run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5))
      assert turns() == run
    end

    refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue" <> _note}
  end

  test "an issue refreshed from Linear with no PR recorded is parked, saying it has no PR" do
    fetcher = linear_issue_fetcher()

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, issue_state_fetcher: fetcher) end)

    assert turns() == 2
    assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    refute_received {:pr_head_fetched, _pr_url}

    assert log =~
             "Parking issue_id=issue-progress issue_identifier=TP-337 in Backlog after 2 turns with no new commit or state change; " <>
               "Symphony has no open PR recorded for it, so CI on its head was not checked"

    refute log =~ "at dispatch"
  end

  test "a run whose issue had a PR at dispatch warns after each refresh that shows no PR" do
    fetcher = linear_issue_fetcher()

    Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
      :ok = TicketPullRequest.mark_finished("default", @pr_url, "closed")
    end)

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, issue_state_fetcher: fetcher) end)

    warning =
      "issue_id=issue-progress issue_identifier=TP-337 had PR #{@pr_url} at dispatch, " <>
        "but Symphony's record of its PR now shows no open PR; checks on its PR will not run"

    # The PR URL dropping out of the first refresh counts as a change, so the run parks after three turns.
    assert turns() == 3
    assert log |> String.split(warning) |> length() == turns() + 1
    assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
  end

  test "a run whose refreshed issue still has its PR does not warn about a lost PR" do
    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5) end)

    assert turns() == 2
    refute log =~ "at dispatch"
  end

  describe "the ticket's PR from Symphony's record, with none attached in Linear" do
    setup do
      :ok = TicketPullRequest.record_created("default", "issue-progress", @pr_url, "auto/TP-337")
    end

    test "a Rework run moves to Code Review once its commits are the recorded PR's head" do
      run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", pr_url: nil)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
    end

    test "empty Rework turns wait for CI pending on the recorded PR's head instead of parking" do
      pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: pending}})

      run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4, pr_url: nil)

      assert turns() == 4
      assert_received {:pr_head_fetched, @pr_url}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "the run moves on the recorded PR once its pushed head is the PR head, with no reviewer turn before" do
      pending = [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: pending}})

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, reviewer: true, pr_url: nil)
        end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute log =~ "reviewer"
    end

    test "a closed or merged PR is no in-flight PR" do
      for finished <- ["closed", "merged"] do
        :ok = TicketPullRequest.record_created("default", "issue-progress", @pr_url, "auto/TP-337")
        :ok = TicketPullRequest.mark_finished("default", @pr_url, finished)
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, pr_url: nil) end)

        assert turns() == 2
        refute_received {:pr_head_fetched, _pr_url}
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert log =~ "Symphony has no open PR recorded for it, so CI on its head was not checked"
        refute log =~ "at dispatch"
      end
    end

    test "a run whose recorded PR closes mid-run warns that its PR checks will not run" do
      Application.put_env(:symphony_elixir, :progress_turn_hook, fn _opts ->
        :ok = TicketPullRequest.mark_finished("default", @pr_url, "closed")
      end)

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, pr_url: nil) end)

      assert log =~
               "issue_id=issue-progress issue_identifier=TP-337 had PR #{@pr_url} at dispatch, " <>
                 "but Symphony's record of its PR now shows no open PR; checks on its PR will not run"

      assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end
  end

  test "empty Rework turns while CI on the pushed PR head is pending do not park the issue" do
    pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: pending}})

    run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4)

    assert turns() == 4
    assert_received {:pr_head_fetched, @pr_url}
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "empty Rework turns with no pending CI on the PR head still park the issue" do
    pending = [%{name: "macos-e2e", status: "IN_PROGRESS", conclusion: nil}]
    green = [%{name: "macos-e2e", status: "COMPLETED", conclusion: "SUCCESS"}]

    for pr_head_result <- [
          {:ok, %{commit_sha: "sha-pushed", checks: green}},
          {:ok, %{commit_sha: "sha-pushed", checks: []}},
          {:ok, %{commit_sha: "sha-other", checks: pending}},
          {:error, :gh_unavailable}
        ] do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
      next_run()

      run_issue!("Rework", heads: ["sha-pushed"], max_turns: 4)

      assert turns() == 2
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end
  end

  describe "the stop after a PR is open" do
    test "waits until the workspace HEAD is the PR head, so a committed fix is pushed first" do
      pr_heads = [{:ok, %{commit_sha: "sha-old", checks: []}}, {:ok, %{commit_sha: "sha-fix", checks: []}}]
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, pr_heads})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-old", "sha-fix"], handoff: "sha-fix", max_turns: 4) end)

      assert turns() == 2
      # Once the fix is the PR head, the stop hands it off.
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "Not stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened; workspace HEAD sha-fix is not its PR head sha-old"
      assert log =~ "Stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened"
    end

    test "still stops after the first turn when the workspace HEAD is the PR head" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})

      for heads <- [["sha-pushed"], ["sha-old", "sha-pushed"]] do
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: heads, max_turns: 4) end)

        assert turns() == 1
        assert_received {:pr_head_fetched, @pr_url}
        assert log =~ "Stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened"
        refute log =~ "Not stopping"
      end
    end

    test "stops as before when the workspace HEAD or the PR head is unreadable" do
      for {heads, pr_head_result} <- [
            {[nil], {:ok, %{commit_sha: "sha-old", checks: []}}},
            {["sha-old", "sha-fix"], {:error, :gh_unavailable}},
            {["sha-old", "sha-fix"], {:ok, %{commit_sha: nil, checks: []}}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: heads, max_turns: 4)

        assert turns() == 1
      end
    end
  end

  describe "a run on an issue whose PR is already open" do
    @pending_checks [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    setup do
      # The conflict that started the run stays pending until the PR poller sees the PR clean,
      # so the post-PR stop never ends the run.
      :ok = put_pending_conflict()
    end

    test "moves to Code Review as soon as CI runs on the head it pushed, instead of turning until it is parked" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
      refute log =~ "Parking"
      assert_signal("handoff", %{to: "Code Review", reason: "with CI running on its pushed head", head: "sha-fixed", move: true})
    end

    test "refreshed from Linear, takes its PR from Symphony's record, so CI running on the head it pushed moves it to Code Review" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})
      fetcher = linear_issue_fetcher()

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, issue_state_fetcher: fetcher)
        end)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
    end

    test "with Code Review's reviewer on, pushes and moves to Code Review with no reviewer turn before the push" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6, reviewer: true) end)

      # The turn that pushed is the last: no reviewer-agent guidance turn follows it.
      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
      refute log =~ "reviewer-agent guidance"
    end

    test "waits a turn for the checks of the head it pushed to show up, then moves to Code Review" do
      no_checks = {:ok, %{commit_sha: "sha-fixed", checks: []}}
      pending = {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [no_checks, pending]})

      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "without the retired auto_review block moves to Code Review as soon as its pushed head is green" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", auto_review: nil) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "CI is green on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
    end

    test "hands off as CI running, not green, while a rerun of its pushed head's failed jobs is starting" do
      # TP-546: the failed checks leave the rollup until the rerun's new attempt queues them, so
      # only the checks that passed are left.
      passed = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}]
      run_not_finished = %{commit_sha: "sha-fixed", checks: passed, workflow_runs: [%{id: "987", status: "QUEUED", conclusion: nil}]}

      # The head's workflow run is not finished; then, with that run unread, the PR watcher's record
      # of the rerun it started on this head.
      rerun = %{Attempts.new() | reruns: %{"sha-fixed" => ["dialyzer"]}}

      for {ci_status, attempts} <- [{run_not_finished, nil}, {%{commit_sha: "sha-fixed", checks: passed}, rerun}] do
        if attempts, do: PrWatchSupport.update_watch!("default", "issue-progress", &%{&1 | attempts: attempts})
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, ci_status})
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], handoff: "sha-fixed", auto_review: nil) end)

        assert turns() == 1
        assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
        assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
        refute log =~ "CI is green"
      end
    end

    test "is still parked when it pushed nothing, its head is red or has no checks, or its head is not the PR head" do
      for {heads, pr_head_result} <- [
            {["sha-same"], {:ok, %{commit_sha: "sha-same", checks: @green_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-fixed", checks: @red_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-fixed", checks: []}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-dirty", checks: @green_checks}}},
            {["sha-dirty", "sha-fixed"], {:ok, %{commit_sha: "sha-dirty", checks: @pending_checks}}},
            {["sha-dirty", "sha-fixed"], {:error, :gh_unavailable}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: heads, max_turns: 6)

        assert turns() == if(length(heads) == 1, do: 2, else: 3)
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      end
    end

    test "keeps turning when its workspace HEAD is unreadable" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: nil, checks: @green_checks}})

      run_issue!("In Progress", heads: [nil], max_turns: 3)

      assert turns() == 3
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "landing on a green pushed head is left to the Merging flow" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      run_issue!("Merging", heads: ["sha-dirty", "sha-fixed"], states: ["Merging", "Merging", "Done"], max_turns: 5)

      assert turns() == 3
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end
  end

  describe "a CI-fix run that pushes nothing" do
    # TP-656: the red check was a flake (also red on main), and its rerun on the PR head passed.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    test "on an approved PR goes back to Merging once CI on its head is green" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony moved this issue back to Merging: " <> note}
      assert note =~ "CI on the PR head `sha-same` is green, so the approval still covers the PR and auto-merge turns back on"
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI fix run for issue_id=issue-progress issue_identifier=TP-337 pushed nothing and CI on its PR head sha-same is green; moving back to Merging"
      refute log =~ "Parking"
      assert_signal("handoff", %{to: "Merging", kind: :ci_fix, head: "sha-same", move: true})
    end

    test "on a PR that was not approved goes to the post-PR state once CI on its head is green" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      for {auto_review, post_pr_state} <- [{%{enabled: true}, "Code Review"}, {nil, "Code Review"}] do
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6, auto_review: auto_review) end)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", ^post_pr_state}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

        assert log =~
                 "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a CI fix run with no new commit; moving to #{post_pr_state}"
      end
    end

    test "on an approved PR goes to the post-PR state when its head is not the commit that failed" do
      # An earlier CI-fix run pushed `sha-same` and ended before it handed the PR off.
      :ok = put_pending_ci_failure(approved: true, commit_sha: "sha-red")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", _state}
      refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

      assert log =~
               "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a CI fix run with no new commit; moving to Code Review"

      assert_signal("handoff", %{to: "Code Review", reason: "with CI green on its PR head", head: "sha-same", move: true})
    end

    test "waits while CI on its head runs, then goes back to Merging once it is green" do
      :ok = put_pending_ci_failure(approved: true)
      pending = {:ok, %{commit_sha: "sha-same", checks: [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]}}
      green = {:ok, %{commit_sha: "sha-same", checks: @green_checks}}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [pending, pending, pending, green]})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 4
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "Not parking issue_id=issue-progress issue_identifier=TP-337; waiting for CI on its pushed head sha-same"
    end

    test "is still parked when the check on its head is still red, has no checks or is not the PR head" do
      :ok = put_pending_ci_failure(approved: true)

      for pr_head_result <- [
            {:ok, %{commit_sha: "sha-same", checks: @red_checks}},
            {:ok, %{commit_sha: "sha-same", checks: []}},
            {:ok, %{commit_sha: "sha-other", checks: @green_checks}}
          ] do
        Application.put_env(:symphony_elixir, :progress_pr_head_result, pr_head_result)
        next_run()

        run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue in Backlog" <> _note}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
      end
    end

    test "in Rework is still parked on a green head: a rework that adds no commit is not done" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      run_issue!("Rework", heads: ["sha-same"], max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Merging"}
    end

    test "fails the run when its move back to Merging or to the post-PR state fails" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      for approved <- [true, false] do
        :ok = put_pending_ci_failure(approved: approved)
        next_run()

        assert_raise RuntimeError, ~r/green_fix_handoff_failed/, fn ->
          run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)
        end
      end
    end
  end

  describe "a CI Fix run that returns to its origin" do
    # The CI Fix lane's return: a mechanical repair that pushed nothing goes back where it came
    # from, rather than to the post-PR state review would judge again.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]

    test "a repair on a Code Review ticket returns to Code Review, clearing the recorded origin" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Code Review")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("CI Fix", heads: ["sha-same"], max_turns: 6, repos: designed_repos()) end)

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert SymphonyElixir.CiFix.origin("default", "issue-progress") == nil
      assert_signal("ci fix return", %{to: "Code Review", kind: :ci_fix, head: "sha-same", move: true})
      assert log =~ "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same"
      assert log =~ "returning it to its CI Fix origin"
    end

    test "a repair on a Merging ticket returns to Merging, where the PR watcher turns auto-merge on again" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Merging")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      run_issue!("CI Fix", heads: ["sha-same"], max_turns: 6, repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert SymphonyElixir.CiFix.origin("default", "issue-progress") == nil
    end

    test "a repair that pushed a new head returns to its origin with the approval re-bound to it" do
      :ok = put_pending_ci_failure(approved: true)
      :ok = SymphonyElixir.CiFix.record_origin("default", "issue-progress", "Code Review")
      # The approval the lane carries, bound to the head the red one replaced.
      :ok = RunStore.record_ticket_verdict("default", "issue-progress", "code_review", "sha-same", "approve")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-new", checks: @green_checks}})

      run_issue!("CI Fix", heads: ["sha-same", "sha-new"], max_turns: 6, repos: designed_repos())

      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert SymphonyElixir.CiFix.origin("default", "issue-progress") == nil

      # The approval moved with the ticket: the head it now covers is the repair's, not the red one's.
      assert [%{head_sha: "sha-new", outcome: "approve"} | _] =
               SymphonyElixir.Handoff.verdicts("default", "issue-progress", "code_review")

      assert_signal("ci fix return", %{to: "Code Review", kind: :ci_fix, head: "sha-new", move: true})
    end

    test "a repair that lost its origin goes to the post-PR state rather than guessing" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: @green_checks}})

      opts = [heads: ["sha-same"], max_turns: 6, repos: designed_repos(), auto_review: %{enabled: true}]
      log = capture_log(fn -> run_issue!("CI Fix", opts) end)

      # A designed repo's post-PR state is `Code Review`, where the head is judged afresh.
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "No CI Fix origin recorded for issue_id=issue-progress issue_identifier=TP-337"
      assert log =~ "moving it to Code Review"
    end
  end

  describe "a merge-conflict run that pushes nothing" do
    # TP-658: the PR no longer conflicts by the time the run looks (the base branch moved on), so
    # there is nothing to resolve.
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]

    test "on an approved PR goes back to Merging once it is mergeable and green" do
      :ok = put_pending_conflict(approved: true, head_sha: "sha-same")
      put_green_pr_head("MERGEABLE")

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 6) end)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Merging"}
      assert_received {:memory_tracker_comment, "issue-progress", "Symphony moved this issue back to Merging: " <> note}
      assert note =~ "the merge conflict run found nothing to resolve and pushed no commit, the PR no longer conflicts with the base branch"
      assert note =~ "CI on the PR head `sha-same` is green, so the approval still covers the PR and auto-merge turns back on"
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "merge conflict run for issue_id=issue-progress issue_identifier=TP-337 pushed nothing and CI on its PR head sha-same is green; moving back to Merging"
      refute log =~ "Parking"
    end

    test "goes to the post-PR state when the PR was not approved, or its head is not the one that conflicted" do
      for {approved, conflict_head, auto_review, post_pr_state} <- [
            {false, "sha-same", %{enabled: true}, "Code Review"},
            {false, "sha-same", nil, "Code Review"},
            {true, "sha-dirty", %{enabled: true}, "Code Review"}
          ] do
        :ok = put_pending_conflict(approved: approved, head_sha: conflict_head)
        put_green_pr_head("MERGEABLE")
        next_run()

        log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], handoff: "sha-same", max_turns: 6, auto_review: auto_review) end)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", ^post_pr_state}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony moved" <> _note}

        assert log =~
                 "CI is green on issue_id=issue-progress issue_identifier=TP-337's PR head sha-same after a merge conflict run with no new commit; moving to #{post_pr_state}"
      end
    end

    test "is still parked while the PR conflicts or GitHub has not worked out whether it does, even with a CI failure pending too" do
      for {mergeable, ci_failure?} <- [{"CONFLICTING", false}, {"UNKNOWN", false}, {"CONFLICTING", true}] do
        :ok = put_pending_conflict(approved: true, head_sha: "sha-same")
        if ci_failure?, do: :ok = put_pending_ci_failure(approved: true)
        put_green_pr_head(mergeable)
        next_run()

        run_issue!("In Progress", heads: ["sha-same"], max_turns: 6)

        assert turns() == 2
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        assert_received {:memory_tracker_comment, "issue-progress", "Symphony parked this issue in Backlog" <> _note}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
      end
    end

    defp put_green_pr_head(mergeable) do
      pr_head = %{commit_sha: "sha-same", mergeable: mergeable, checks: @green_checks}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, pr_head})
    end
  end

  describe "a fix run that pushed a commit and then waits on CI" do
    # TP-662: a Rework run asked for a CI fix pushed it, then spent its turns waiting on CI. The CI
    # failure that started it stays pending until the run ends, so the rework never reads finished.
    @pending_checks [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]
    @green_checks [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    @red_checks [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]

    test "in Rework moves to Code Review instead of Backlog while CI on its pushed head runs or once it is green" do
      for {checks, ci} <- [{@pending_checks, "running"}, {@green_checks, "green"}] do
        :ok = put_pending_ci_failure(approved: false)
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: checks}})
        next_run()

        log = capture_log(fn -> run_issue!("Rework", heads: ["sha-same", "sha-fixed"], handoff: "sha-fixed", max_turns: 6) end)

        # The turn that pushed, then two turns with no new commit.
        assert turns() == 3
        assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
        refute_received {:memory_tracker_state_update, "issue-progress", _state}
        refute_received {:memory_tracker_comment, "issue-progress", "Symphony parked" <> _note}
        assert RunStore.get_rework_base("default", "issue-progress") == nil
        assert log =~ "CI is #{ci} on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Code Review"
        refute log =~ "Parking"
      end
    end

    test "in Rework moves on when an earlier run of the rework pushed the head" do
      :ok = put_pending_ci_failure(approved: false)
      :ok = RunStore.put_rework_base("default", "issue-progress", "sha-same")
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      run_issue!("Rework", heads: ["sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "outside Rework moves to Code Review through the pushed-head hand-off on the turn it pushed" do
      :ok = put_pending_ci_failure(approved: true)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      run_issue!("In Progress", heads: ["sha-same", "sha-fixed"], handoff: "sha-fixed", max_turns: 6)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "is still parked when its pushed head is red, or when it pushed nothing and CI is red" do
      for {state, heads} <- [{"Rework", ["sha-same", "sha-fixed"]}, {"Rework", ["sha-fixed"]}, {"In Progress", ["sha-fixed"]}] do
        :ok = put_pending_ci_failure(approved: false)
        Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @red_checks}})
        next_run()

        run_issue!(state, heads: heads, max_turns: 6)

        assert turns() == length(heads) + 1
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        refute_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      end
    end

    test "fails the run when its move to Code Review fails, keeping the rework base" do
      :ok = put_pending_ci_failure(approved: false)
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

      assert_raise RuntimeError, ~r/pushed_head_handoff_failed/, fn ->
        run_issue!("Rework", heads: ["sha-same", "sha-fixed"], max_turns: 6)
      end

      assert RunStore.get_rework_base("default", "issue-progress") == "sha-same"
    end
  end

  test "a turn that adds a commit or follows a state change resets the empty-turn count" do
    run_issue!("In Progress",
      heads: ["sha-1", "sha-1", "sha-2", "sha-2", "sha-2"],
      states: ["In Progress", "In Progress", "In Progress", "Todo", "Done"],
      pr_url: nil,
      max_turns: 5
    )

    assert turns() == 5
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "empty landing turns are left to the Merging CI wait" do
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-same", checks: green}})

    run_issue!("Merging", heads: ["sha-same"], states: ["Merging", "Merging", "Done"], max_turns: 5)

    assert turns() == 3
    refute_received {:memory_tracker_state_update, _issue_id, _state}
  end

  test "a failed state move after a finished rework, a green pushed head or an idle park fails the run" do
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :linear_down})

    assert_raise RuntimeError, ~r/rework_handoff_failed/, fn ->
      run_issue!("Rework", heads: ["sha-old", "sha-rework"])
    end

    next_run()

    assert_raise RuntimeError, ~r/idle_park_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)
    end

    next_run()
    :ok = put_pending_conflict()
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: green}})

    assert_raise RuntimeError, ~r/pushed_head_handoff_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"])
    end
  end

  test "a run's agent session tells the orchestrator as each Symphony tool call starts and ends" do
    capture_log(fn ->
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self())
    end)

    assert_received {:progress_session_started, session_opts}
    on_tool_call = Keyword.fetch!(session_opts, :on_tool_call)
    call = %{name: "github_sync_base", started_at: DateTime.utc_now(), deadline: nil}
    call_id = make_ref()

    on_tool_call.({:started, call_id, call})
    on_tool_call.({:finished, call_id})

    assert_received {:mcp_tool_call, "issue-progress", {:started, ^call_id, ^call}}
    assert_received {:mcp_tool_call, "issue-progress", {:finished, ^call_id}}
  end

  test "a run without an orchestrator to tell starts its agent session without a tool call notice" do
    capture_log(fn ->
      assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework")
    end)

    assert_received {:progress_session_started, session_opts}
    assert Keyword.fetch!(session_opts, :on_tool_call) == nil
  end

  describe "a Linear rate limit on a run's own Linear call" do
    test "a finished rework waits it out on its post-PR move instead of failing the run" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [@rate_limited])

      log =
        capture_log(fn ->
          assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self(), runner_opts: linear_wait_opts())
        end)

      assert turns() == 1
      assert_received {:linear_wait_slept, 30_000}
      # The orchestrator hears of the wait, so its watchdogs hold off until it ends.
      assert_received {:linear_wait, "issue-progress", 30_000}
      assert_received {:memory_tracker_state_update, "issue-progress", "Code Review"}
      assert log =~ "Linear call failed while moving issue_id=issue-progress issue_identifier=TP-337 to Code Review after rework"
      refute log =~ "Agent run failed"
    end

    test "a workpad bootstrap tells the orchestrator it is waiting before the first turn" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [@rate_limited])

      capture_log(fn ->
        assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], handoff: "sha-rework", recipient: self(), runner_opts: linear_wait_opts())
      end)

      # The orchestrator hears of the wait before any agent event, so its first-turn stall
      # check holds off until it ends.
      {:messages, messages} = Process.info(self(), :messages)
      wait_at = Enum.find_index(messages, &match?({:linear_wait, "issue-progress", 30_000}, &1))
      assert is_integer(wait_at)
      assert wait_at < Enum.find_index(messages, &match?({:progress_turn, 1}, &1))
      assert_received {:linear_wait_slept, 30_000}
      assert_received {:memory_tracker_comment, "issue-progress", "## Symphony Workpad" <> _}
    end

    test "an idle park waits it out on its state move and its note instead of failing the run" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [@rate_limited])
      # The first comment is the workpad bootstrap's; the second is the park note.
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [:ok, @rate_limited])

      log =
        capture_log(fn ->
          assert :ok = run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: linear_wait_opts())
        end)

      assert turns() == 2
      assert_received {:linear_wait_slept, 30_000}
      assert_received {:linear_wait_slept, 30_000}
      assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert_received {:memory_tracker_comment, "issue-progress", workpad}
      assert workpad =~ "## Symphony Workpad"
      assert_received {:memory_tracker_comment, "issue-progress", note}
      assert note =~ "Symphony parked this issue in Backlog"
      assert log =~ "Linear call failed while parking issue_id=issue-progress issue_identifier=TP-337 in Backlog"
      refute log =~ "Agent run failed for"
    end

    test "a move still rate-limited when the wait runs out ends the run as a Linear wait" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, @rate_limited)
      runner_opts = [linear_retry_opts: [max_wait_ms: 0]]

      capture_log(fn ->
        assert {:linear_unavailable, {:idle_park_failed, {:linear_rate_limited, 1_791_000_030_000}}} =
                 catch_exit(run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, runner_opts: runner_opts))
      end)
    end
  end

  defp put_pending_conflict(opts \\ []) do
    head = Keyword.get(opts, :head_sha, "sha-dirty")

    conflict = %{
      pr_url: @pr_url,
      head_ref: "auto/TP-337",
      head_sha: head,
      base_ref: "main",
      base_sha: "sha-main",
      conflict_key: "#{head}|sha-main",
      approved: Keyword.get(opts, :approved, false)
    }

    PrWatchSupport.put_fix!("default", "issue-progress", :pr_conflict, conflict, identifier: "TP-337", pr_url: @pr_url)
  end

  defp put_pending_ci_failure(opts) do
    failure = %{
      commit_sha: Keyword.get(opts, :commit_sha, "sha-same"),
      failed_checks: [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}],
      log_excerpt: "stub_test.exs:21 failed",
      approved: Keyword.fetch!(opts, :approved)
    }

    PrWatchSupport.put_fix!("default", "issue-progress", :ci_failure, failure, identifier: "TP-337", pr_url: @pr_url)
  end

  defp linear_wait_opts do
    parent = self()
    [linear_retry_opts: [now_ms_fun: fn -> @now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]]
  end

  # `heads` is the workspace HEAD at run start and after each turn (the last one repeats);
  # `states` is the issue state after each turn (the last one repeats). `handoff` is a head the
  # push and PR tool hooks already emitted the handoff signal for, as a run that pushed it would.
  defp run_issue!(state, opts) do
    heads = Keyword.fetch!(opts, :heads)

    if handoff = Keyword.get(opts, :handoff),
      do: :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: handoff, branch: "auto/TP-337"})

    states = Keyword.get(opts, :states, [state])
    pr_url = Keyword.get(opts, :pr_url, @pr_url)
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-progress-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-337")
    File.mkdir_p!(workspace)
    reviewer? = Keyword.get(opts, :reviewer, false)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      workspace_root: test_root,
      max_turns: Keyword.get(opts, :max_turns, 3),
      auto_review: Keyword.get(opts, :auto_review, %{enabled: true}),
      repos: Keyword.get(opts, :repos),
      review_agent: if(reviewer?, do: %{enabled: true, kind: "codex", command: "reviewer app-server"})
    )

    issue = %Issue{
      id: "issue-progress",
      identifier: "TP-337",
      title: "Leave Rework",
      description: "Fix the PR",
      state: state,
      repo_key: "default"
    }

    if pr_url, do: :ok = TicketPullRequest.record_created("default", "issue-progress", pr_url, "auto/TP-337")

    try do
      AgentRunner.run(
        issue,
        Keyword.get(opts, :recipient),
        [
          workspace_path: workspace,
          agent_module: ProgressAgent,
          github: ProgressGitHub,
          workspace_head_reader: fn ^workspace, nil -> at_turn(heads) end,
          issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, fn _ids -> {:ok, [%{issue | state: at_turn(states, -1)}]} end),
          issue_enricher: &{:ok, &1}
        ] ++ Keyword.get(opts, :runner_opts, [])
      )
    after
      File.rm_rf(test_root)
    end
  end

  # The newest signal recorded for the run's issue, asserting its name and details.
  defp assert_signal(name, details) do
    assert [%{name: ^name, details: ^details} | _rest] = RunStore.get_ticket_state("default", "issue-progress").signals
  end

  # Refreshes the issue through the Linear client, as the runner does in production.
  defp linear_issue_fetcher do
    graphql_fun = fn "query SymphonyLinearIssuesById" <> _query, %{ids: ["issue-progress"]} ->
      issue = %{"id" => "issue-progress", "identifier" => "TP-337", "title" => "Leave Rework", "state" => %{"name" => "In Progress"}}
      {:ok, %{"data" => %{"issues" => %{"nodes" => [issue]}}}}
    end

    &Client.fetch_issue_states_by_ids_for_test(&1, graphql_fun)
  end

  defp at_turn(values, offset \\ 0) do
    Enum.at(values, turns() + offset) || List.last(values)
  end

  defp turns, do: Application.get_env(:symphony_elixir, :progress_agent_turns, 0)

  # Another run on the same ticket: its turns count from zero, and the pause a park set is lifted, as
  # a person's Unblock lifts it.
  defp next_run do
    Application.delete_env(:symphony_elixir, :progress_agent_turns)
    {:ok, _pause} = Pauses.clear_reasons({:ticket, "default", "issue-progress"}, fn _reason -> true end, by: Pauses.director())
  end

  # What Claude's turn reports when it can't reach the model API.
  defp outage_info do
    %{provider: "anthropic", scope: :all, window: nil, resets_at: nil, utilization: nil, source: :api_unreachable, error: "ENOTFOUND"}
  end

  test "the workspace HEAD and its unpushed commits read from a local git checkout only" do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-head-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    try do
      System.cmd("git", ["-C", repo, "init", "-b", "main"])
      assert WorkspaceHead.read(repo, nil) == nil

      File.write!(Path.join(repo, "README.md"), "# test")
      System.cmd("git", ["-C", repo, "add", "README.md"])
      System.cmd("git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"])
      {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert WorkspaceHead.read(repo, nil) == String.trim(sha)
      assert WorkspaceHead.read(repo, "worker-1") == nil
      assert WorkspaceHead.read(Path.join(root, "missing"), nil) == nil

      # With no remote-tracking branch at all, nothing says the commit is unpushed.
      assert WorkspaceHead.unpushed_head(repo, nil) == nil

      System.cmd("git", ["-C", repo, "update-ref", "refs/remotes/origin/main", "HEAD"])
      assert WorkspaceHead.unpushed_head(repo, nil) == nil

      File.write!(Path.join(repo, "fix.txt"), "fix")
      System.cmd("git", ["-C", repo, "add", "fix.txt"])
      System.cmd("git", ["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "fix"])
      {fix_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])

      assert WorkspaceHead.unpushed_head(repo, nil) == String.trim(fix_sha)
      assert WorkspaceHead.unpushed_head(repo, "worker-1") == nil
      assert WorkspaceHead.unpushed_head(nil, nil) == nil
      assert WorkspaceHead.unpushed_head(Path.join(root, "missing"), nil) == nil

      System.cmd("git", ["-C", repo, "update-ref", "refs/remotes/origin/auto/TP-337", "HEAD"])
      assert WorkspaceHead.unpushed_head(repo, nil) == nil
    after
      File.rm_rf(root)
    end
  end
end
