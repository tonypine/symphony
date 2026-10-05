defmodule SymphonyElixir.AgentRunnerProgressTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.WorkspaceHead

  @pr_url "https://github.com/example/repo/pull/337"
  @now_ms 1_791_000_000_000
  @rate_limited {:error, {:linear_rate_limited, 1_791_000_030_000}}

  defmodule ProgressAgent do
    # Coding-agent stand-in: every turn completes and is reported to the test.
    def start_session(_workspace, _opts), do: {:ok, %{}}

    def run_turn(_session, _prompt, _issue, _opts) do
      count = Application.get_env(:symphony_elixir, :progress_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :progress_agent_turns, count)
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_turn, count})
      {:ok, %{session_id: "sess-#{count}"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule ProgressReviewer do
    # Pre-push reviewer stand-in: approves the diff and reports the review to the test.
    def start_session(_workspace, _opts), do: {:ok, %{}}

    def run_turn(_session, _prompt, _issue, _opts) do
      turns = Application.get_env(:symphony_elixir, :progress_agent_turns, 0)
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_reviewed, turns})
      {:ok, %{result: ~s({"verdict":"approve","comments":[]})}}
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

    on_exit(fn ->
      for key <- [
            :progress_agent_recipient,
            :progress_agent_turns,
            :progress_pr_head_result,
            :memory_tracker_update_issue_state_result,
            :memory_tracker_create_comment_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  test "a Rework run whose new commits are the PR head moves to Auto Review without another turn" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"])

    assert turns() == 1
    assert_received {:pr_head_fetched, @pr_url}
    assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
  end

  test "with Auto Review off a finished Rework run moves to In Review" do
    run_issue!("Rework", heads: ["sha-old", "sha-rework"], auto_review: nil)

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "In Review"}
  end

  test "a re-dispatched Rework run whose rework an earlier run pushed moves on after one empty turn" do
    run_issue!("Rework", heads: ["sha-old"], max_turns: 1)

    assert RunStore.get_rework_base("default", "issue-progress") == "sha-old"
    refute_received {:memory_tracker_state_update, _issue_id, _state}

    Application.delete_env(:symphony_elixir, :progress_agent_turns)
    run_issue!("Rework", heads: ["sha-rework"])

    assert turns() == 1
    assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
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
      Application.delete_env(:symphony_elixir, :progress_agent_turns)

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
  end

  test "an issue with many attachments and no PR is still parked, saying it has no PR" do
    fetcher = linear_issue_fetcher(screenshot_attachments(21..30))

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5, issue_state_fetcher: fetcher) end)

    assert turns() == 2
    assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    refute_received {:pr_head_fetched, _pr_url}

    assert log =~
             "Parking issue_id=issue-progress issue_identifier=TP-337 in Backlog after 2 turns with no new commit or state change; " <>
               "it has no attached PR, so CI on its head was not checked"

    refute log =~ "at dispatch"
  end

  test "a run whose issue had a PR at dispatch warns after each refresh that shows no PR" do
    fetcher = linear_issue_fetcher(screenshot_attachments(21..30))

    log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-same"], max_turns: 5, issue_state_fetcher: fetcher) end)

    warning =
      "issue_id=issue-progress issue_identifier=TP-337 had PR #{@pr_url} at dispatch, " <>
        "but its refreshed Linear attachments show no PR; checks on its PR will not run"

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
      Application.delete_env(:symphony_elixir, :progress_agent_turns)

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

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-old", "sha-fix"], max_turns: 4) end)

      assert turns() == 2
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert log =~ "Not stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened; workspace HEAD sha-fix is not its PR head sha-old"
      assert log =~ "Stopping agent run for issue_id=issue-progress issue_identifier=TP-337 after PR opened"
    end

    test "still stops after the first turn when the workspace HEAD is the PR head" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-pushed", checks: []}})

      for heads <- [["sha-pushed"], ["sha-old", "sha-pushed"]] do
        Application.delete_env(:symphony_elixir, :progress_agent_turns)

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
        Application.delete_env(:symphony_elixir, :progress_agent_turns)

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

    test "moves to Auto Review as soon as CI runs on the head it pushed, instead of turning until it is parked" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], max_turns: 6) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Auto Review"
      refute log =~ "Parking"
    end

    test "finds its PR past the first page of attachments, so CI running on the head it pushed moves it to Auto Review" do
      # MOT-40: QA screenshots pushed the PR attachment past the first 20 attachments Linear returns.
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})
      fetcher = linear_issue_fetcher([pr_attachment() | screenshot_attachments(21..22)])

      log =
        capture_log(fn ->
          run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], pr_url: nil, max_turns: 6, issue_state_fetcher: fetcher)
        end)

      assert turns() == 1
      assert_received {:pr_head_fetched, @pr_url}
      assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Auto Review"
    end

    test "lets the pre-push reviewer review the head it pushed before moving to Auto Review" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], max_turns: 6, reviewer: true) end)

      # The reviewer runs after the turn that pushed, and the run moves on after the turn it approved.
      assert turns() == 2
      {:messages, messages} = Process.info(self(), :messages)
      reviewed_at = Enum.find_index(messages, &match?({:progress_reviewed, 1}, &1))
      assert is_integer(reviewed_at)
      assert reviewed_at < Enum.find_index(messages, &match?({:memory_tracker_state_update, "issue-progress", "Auto Review"}, &1))
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
      assert log =~ "CI is running on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to Auto Review"
    end

    test "waits a turn for the checks of the head it pushed to show up, then moves to Auto Review" do
      no_checks = {:ok, %{commit_sha: "sha-fixed", checks: []}}
      pending = {:ok, %{commit_sha: "sha-fixed", checks: @pending_checks}}
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:by_turn, [no_checks, pending]})

      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], max_turns: 6)

      assert turns() == 2
      assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
      refute_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
    end

    test "with Auto Review off moves to In Review as soon as its pushed head is green" do
      Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: @green_checks}})

      log = capture_log(fn -> run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"], auto_review: nil) end)

      assert turns() == 1
      assert_received {:memory_tracker_state_update, "issue-progress", "In Review"}
      assert log =~ "CI is green on issue_id=issue-progress issue_identifier=TP-337's pushed head sha-fixed on its PR; moving to In Review"
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
        Application.delete_env(:symphony_elixir, :progress_agent_turns)

        run_issue!("In Progress", heads: heads, max_turns: 6)

        assert turns() == if(length(heads) == 1, do: 2, else: 3)
        assert_received {:memory_tracker_state_update, "issue-progress", "Backlog"}
        refute_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
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

    Application.delete_env(:symphony_elixir, :progress_agent_turns)

    assert_raise RuntimeError, ~r/idle_park_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-same"], pr_url: nil, max_turns: 5)
    end

    Application.delete_env(:symphony_elixir, :progress_agent_turns)
    :ok = put_pending_conflict()
    green = [%{name: "make-all", status: "COMPLETED", conclusion: "SUCCESS"}]
    Application.put_env(:symphony_elixir, :progress_pr_head_result, {:ok, %{commit_sha: "sha-fixed", checks: green}})

    assert_raise RuntimeError, ~r/pushed_head_handoff_failed/, fn ->
      run_issue!("In Progress", heads: ["sha-dirty", "sha-fixed"])
    end
  end

  describe "a Linear rate limit on a run's own Linear call" do
    test "a finished rework waits it out on its post-PR move instead of failing the run" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [@rate_limited])

      log =
        capture_log(fn ->
          assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], recipient: self(), runner_opts: linear_wait_opts())
        end)

      assert turns() == 1
      assert_received {:linear_wait_slept, 30_000}
      # The orchestrator hears of the wait, so its watchdogs hold off until it ends.
      assert_received {:linear_wait, "issue-progress", 30_000}
      assert_received {:memory_tracker_state_update, "issue-progress", "Auto Review"}
      assert log =~ "Linear call failed while moving issue_id=issue-progress issue_identifier=TP-337 to Auto Review after rework"
      refute log =~ "Agent run failed"
    end

    test "a workpad bootstrap tells the orchestrator it is waiting before the first turn" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [@rate_limited])

      capture_log(fn ->
        assert :ok = run_issue!("Rework", heads: ["sha-old", "sha-rework"], recipient: self(), runner_opts: linear_wait_opts())
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

  defp put_pending_conflict do
    RunStore.put_pr_review(%{
      repo_key: "default",
      issue_id: "issue-progress",
      issue_identifier: "TP-337",
      pr_url: @pr_url,
      workspace_path: "/tmp",
      status: "conflict_active_run",
      conflict_context: %{
        pr_url: @pr_url,
        head_ref: "auto/TP-337",
        head_sha: "sha-dirty",
        base_ref: "main",
        base_sha: "sha-main",
        conflict_key: "sha-dirty|sha-main"
      },
      updated_at: ~U[2026-10-04 08:29:00Z]
    })
  end

  defp linear_wait_opts do
    parent = self()
    [linear_retry_opts: [now_ms_fun: fn -> @now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]]
  end

  # `heads` is the workspace HEAD at run start and after each turn (the last one repeats);
  # `states` is the issue state after each turn (the last one repeats).
  defp run_issue!(state, opts) do
    heads = Keyword.fetch!(opts, :heads)
    states = Keyword.get(opts, :states, [state])
    pr_url = Keyword.get(opts, :pr_url, @pr_url)
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-progress-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-337")
    File.mkdir_p!(workspace)
    reviewer? = Keyword.get(opts, :reviewer, false)
    if reviewer?, do: init_reviewed_repo!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      workspace_root: test_root,
      max_turns: Keyword.get(opts, :max_turns, 3),
      auto_review: Keyword.get(opts, :auto_review, %{enabled: true}),
      review_agent: if(reviewer?, do: %{enabled: true, kind: "codex", command: "reviewer app-server", run_on: "always"})
    )

    issue = %Issue{id: "issue-progress", identifier: "TP-337", title: "Leave Rework", description: "Fix the PR", state: state, pull_request_url: pr_url}

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
          issue_enricher: &{:ok, &1},
          review_agent_module: ProgressReviewer
        ] ++ Keyword.get(opts, :runner_opts, [])
      )
    after
      File.rm_rf(test_root)
    end
  end

  # A checkout with a commit past `origin/main`, for the pre-push reviewer to read its diff from.
  defp init_reviewed_repo!(repo) do
    git = &System.cmd("git", ["-C", repo | &1])
    git.(["init", "-b", "main"])
    git.(["config", "user.name", "Test User"])
    git.(["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# test")
    git.(["add", "README.md"])
    git.(["commit", "-m", "initial"])
    git.(["update-ref", "refs/remotes/origin/main", "HEAD"])
    File.write!(Path.join(repo, "fix.txt"), "conflict fixed\n")
    git.(["add", "fix.txt"])
    git.(["commit", "-m", "fix: resolve the conflict"])
  end

  # Refreshes the issue through the Linear client, as the runner does in production: Linear returns
  # 20 screenshot attachments first and `next_page` after them.
  defp linear_issue_fetcher(next_page) do
    attachments = fn nodes, next_cursor ->
      %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => is_binary(next_cursor), "endCursor" => next_cursor}}
    end

    graphql_fun = fn
      "query SymphonyLinearIssuesById" <> _query, %{ids: ["issue-progress"]} ->
        issue = %{
          "id" => "issue-progress",
          "identifier" => "TP-337",
          "title" => "Leave Rework",
          "state" => %{"name" => "In Progress"},
          "attachments" => attachments.(screenshot_attachments(1..20), "after-20")
        }

        {:ok, %{"data" => %{"issues" => %{"nodes" => [issue]}}}}

      "query SymphonyLinearIssueAttachments" <> _query, %{id: "issue-progress", after: "after-20"} ->
        {:ok, %{"data" => %{"issue" => %{"attachments" => attachments.(next_page, nil)}}}}
    end

    &Client.fetch_issue_states_by_ids_for_test(&1, graphql_fun)
  end

  defp screenshot_attachments(range) do
    Enum.map(range, &%{"title" => "Screenshot #{&1}", "url" => "https://uploads.linear.app/qa/#{&1}.png", "sourceType" => "upload"})
  end

  defp pr_attachment, do: %{"title" => "PR #337", "url" => @pr_url, "sourceType" => "github", "metadata" => %{"status" => "open"}}

  defp at_turn(values, offset \\ 0) do
    Enum.at(values, turns() + offset) || List.last(values)
  end

  defp turns, do: Application.get_env(:symphony_elixir, :progress_agent_turns, 0)

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
