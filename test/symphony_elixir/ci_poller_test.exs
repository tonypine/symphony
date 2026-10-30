defmodule SymphonyElixir.CiPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.{TicketObservation, TicketPullRequest, TicketState}

  @repo_key "default"
  @in_review_pr "https://github.com/example/repo/pull/2401"

  defmodule FakeTracker do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(states) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:fetch_issues_by_states, states})
      {:ok, Application.get_env(:symphony_elixir, :ci_test_issues, [])}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)

      issues =
        :symphony_elixir
        |> Application.get_env(:ci_test_issues, [])
        |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted, id) end)

      {:ok, issues}
    end

    def update_issue_state(issue_id, state_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:issue_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:issue_comment, issue_id, body})
      :ok
    end
  end

  defmodule FakeGitHub do
    def fetch_ci_status(pr_url, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_ci_status, pr_url})

      with {:ok, status} <- next_status() do
        {:ok, put_required_checks(status, Keyword.get(opts, :required_checks))}
      end
    end

    # A landing read carries the base branch's required checks, as `PullRequest` reads them.
    defp put_required_checks(status, true) do
      case Application.get_env(:symphony_elixir, :ci_test_required_checks) do
        nil -> status
        names -> Map.put(status, :required_checks, names)
      end
    end

    defp put_required_checks(status, _landing_read), do: status

    def rerun_failed(run_id, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:rerun_failed, run_id})
      :ok
    end

    def fetch_failed_log(run_id, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_failed_log, run_id})

      case Application.get_env(:symphony_elixir, :ci_test_failed_log_error) do
        nil ->
          logs_by_run_id = Application.get_env(:symphony_elixir, :ci_test_failed_logs_by_run_id, %{})
          {:ok, Map.get(logs_by_run_id, run_id, Application.get_env(:symphony_elixir, :ci_test_failed_log, "line 1\nERROR: failed\nline 3"))}

        reason ->
          {:error, reason}
      end
    end

    defp next_status do
      case Application.get_env(:symphony_elixir, :ci_test_statuses, []) do
        [status | rest] ->
          Application.put_env(:symphony_elixir, :ci_test_statuses, rest)
          {:ok, status}

        [] ->
          {:ok, Application.fetch_env!(:symphony_elixir, :ci_test_status)}
      end
    end
  end

  defmodule PartiallyFailingRerunGitHub do
    def fetch_ci_status(pr_url, opts), do: FakeGitHub.fetch_ci_status(pr_url, opts)

    def rerun_failed(run_id, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:rerun_failed, run_id})

      case Application.get_env(:symphony_elixir, :ci_test_rerun_error_run_id) do
        ^run_id -> {:error, :rerun_unavailable}
        _ -> :ok
      end
    end

    def fetch_failed_log(run_id, opts), do: FakeGitHub.fetch_failed_log(run_id, opts)
  end

  # Reads the head's CI through `PullRequest.fetch_ci_status/2`, from the status check rollups in
  # `:ci_test_rollups`, one per read.
  defmodule RollupGitHub do
    alias SymphonyElixir.GitHub.PullRequest

    def fetch_ci_status(pr_url, opts) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:fetch_ci_status, pr_url})
      [rollup | rest] = Application.fetch_env!(:symphony_elixir, :ci_test_rollups)
      Application.put_env(:symphony_elixir, :ci_test_rollups, rest)

      runner = fn
        ["pr", "view", ^pr_url, "--json", _fields], _opts ->
          pr = %{"state" => "OPEN", "url" => pr_url, "headRefName" => "feature/fix-ci", "headRefOid" => "abc123", "statusCheckRollup" => rollup}
          {Jason.encode!(pr), 0}

        ["api", "repos/example/repo/actions/runs?head_sha=abc123&per_page=100"], _opts ->
          {Jason.encode!(%{"workflow_runs" => []}), 0}
      end

      PullRequest.fetch_ci_status(pr_url, Keyword.put(opts, :gh_runner, runner))
    end

    def rerun_failed(run_id, opts), do: FakeGitHub.rerun_failed(run_id, opts)
    def fetch_failed_log(run_id, opts), do: FakeGitHub.fetch_failed_log(run_id, opts)
  end

  defmodule FailingGitHub do
    def fetch_ci_status(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_ci_status, pr_url})
      {:error, :rate_limited}
    end
  end

  defmodule ReviewGitHub do
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :ci_test_review_activity)}
    end
  end

  defmodule FailingUpdateRunStore do
    def list_issue_runs(_repo_key, _issue_id), do: []
    def list_all_runs(:all), do: []
    def list_ci_checks, do: [Application.fetch_env!(:symphony_elixir, :ci_test_ci_record)]
    def update_ci_check(_issue_id, _attrs), do: {:error, :write_failed}
    def put_ci_check(_record), do: :ok
    def delete_ci_check(_issue_id), do: :ok
  end

  defmodule FailingEscalationFinalUpdateRunStore do
    def list_issue_runs(repo_key, issue_id), do: SymphonyElixir.RunStore.list_issue_runs(repo_key, issue_id)
    def list_all_runs(limit), do: SymphonyElixir.RunStore.list_all_runs(limit)
    def list_ci_checks(repo_key), do: SymphonyElixir.RunStore.list_ci_checks(repo_key)
    def list_pr_reviews(repo_key), do: SymphonyElixir.RunStore.list_pr_reviews(repo_key)
    def put_ci_check(record), do: SymphonyElixir.RunStore.put_ci_check(record)
    def delete_ci_check(repo_key, issue_id), do: SymphonyElixir.RunStore.delete_ci_check(repo_key, issue_id)

    def update_ci_check(_repo_key, _issue_id, %{status: "escalated"}), do: {:error, :write_failed}

    def update_ci_check(repo_key, issue_id, attrs),
      do: SymphonyElixir.RunStore.update_ci_check(repo_key, issue_id, attrs)
  end

  defmodule FailingLandingFallbackRunStore do
    def list_issue_runs(repo_key, issue_id), do: SymphonyElixir.RunStore.list_issue_runs(repo_key, issue_id)
    def list_all_runs(limit), do: SymphonyElixir.RunStore.list_all_runs(limit)
    def list_ci_checks(repo_key), do: SymphonyElixir.RunStore.list_ci_checks(repo_key)
    def list_pr_reviews(repo_key), do: SymphonyElixir.RunStore.list_pr_reviews(repo_key)
    def put_ci_check(record), do: SymphonyElixir.RunStore.put_ci_check(record)
    def delete_ci_check(repo_key, issue_id), do: SymphonyElixir.RunStore.delete_ci_check(repo_key, issue_id)

    def update_ci_check(_repo_key, _issue_id, %{landing_fallback_sha: sha}) when is_binary(sha), do: {:error, :write_failed}

    def update_ci_check(repo_key, issue_id, attrs),
      do: SymphonyElixir.RunStore.update_ci_check(repo_key, issue_id, attrs)
  end

  defmodule TicketStatesDownRunStore do
    def list_ticket_states(_repo_key), do: {:error, :store_down}
  end

  defmodule RaisingRunStore do
    def list_ci_checks(_repo_key), do: raise("ci poll exploded")
  end

  defmodule CountingRunStore do
    def list_issue_runs(repo_key, issue_id) do
      bump(:list_issue_runs)
      SymphonyElixir.RunStore.list_issue_runs(repo_key, issue_id)
    end

    def list_all_runs(limit), do: SymphonyElixir.RunStore.list_all_runs(limit)

    def list_ci_checks(repo_key), do: SymphonyElixir.RunStore.list_ci_checks(repo_key)

    def list_pr_reviews(repo_key) do
      bump(:list_pr_reviews)
      SymphonyElixir.RunStore.list_pr_reviews(repo_key)
    end

    def put_ci_check(record), do: SymphonyElixir.RunStore.put_ci_check(record)

    def update_ci_check(repo_key, issue_id, attrs),
      do: SymphonyElixir.RunStore.update_ci_check(repo_key, issue_id, attrs)

    def delete_ci_check(repo_key, issue_id), do: SymphonyElixir.RunStore.delete_ci_check(repo_key, issue_id)

    defp bump(key) do
      counts = Application.get_env(:symphony_elixir, :ci_test_store_counts, %{})
      Application.put_env(:symphony_elixir, :ci_test_store_counts, Map.update(counts, key, 1, &(&1 + 1)))
    end
  end

  defmodule FailingTransitionTracker do
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_issue_ids), do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:issue_state_update, issue_id, state_name})
      {:error, :linear_unavailable}
    end
  end

  # Reads only the issues in the states asked for, as Linear does, so an issue outside the watched
  # states (`Backlog`, an active state) is read by id.
  defmodule StateFilteringTracker do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(states) do
      wanted = MapSet.new(states)
      {:ok, issues} = FakeTracker.fetch_issues_by_states(states)
      {:ok, Enum.filter(issues, fn %Issue{state: state} -> MapSet.member?(wanted, state) end)}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:fetch_issue_states_by_ids, issue_ids})

      case Application.get_env(:symphony_elixir, :ci_test_issue_read_error) do
        nil -> FakeTracker.fetch_issue_states_by_ids(issue_ids)
        reason -> {:error, reason}
      end
    end

    def update_issue_state(issue_id, state_name), do: FakeTracker.update_issue_state(issue_id, state_name)
    def create_comment(issue_id, body), do: FakeTracker.create_comment(issue_id, body)
  end

  defmodule FailingAutoReviewTracker do
    def fetch_issues_by_states(states), do: FakeTracker.fetch_issues_by_states(states)

    def update_issue_state(issue_id, state_name) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:issue_state_update, issue_id, state_name})
      {:error, :linear_unavailable}
    end
  end

  defmodule FailingCommentTracker do
    def fetch_issues_by_states(states), do: FakeTracker.fetch_issues_by_states(states)
    def update_issue_state(issue_id, state_name), do: FakeTracker.update_issue_state(issue_id, state_name)

    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:issue_comment, issue_id, body})
      {:error, :linear_unavailable}
    end
  end

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-ci-poller-audit-#{System.unique_integer([:positive])}"
      )

    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :ci_test_issues)
      Application.delete_env(:symphony_elixir, :ci_test_status)
      Application.delete_env(:symphony_elixir, :ci_test_statuses)
      Application.delete_env(:symphony_elixir, :ci_test_rollups)
      Application.delete_env(:symphony_elixir, :ci_test_required_checks)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log_error)
      Application.delete_env(:symphony_elixir, :ci_test_failed_logs_by_run_id)
      Application.delete_env(:symphony_elixir, :ci_test_rerun_error_run_id)
      Application.delete_env(:symphony_elixir, :ci_test_recipient)
      Application.delete_env(:symphony_elixir, :ci_test_review_activity)
      Application.delete_env(:symphony_elixir, :ci_test_ci_record)
      Application.delete_env(:symphony_elixir, :ci_test_issue_read_error)

      if previous_audit_dir do
        Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir)
      else
        Application.delete_env(:symphony_elixir, :audit_log_dir)
      end

      File.rm_rf(audit_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3}
    )

    Application.put_env(:symphony_elixir, :ci_test_recipient, self())
    :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", @in_review_pr, "feature/fix-ci")
    {:ok, audit_dir: audit_root}
  end

  test "disabled ci config makes no GitHub calls" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: false}
    )

    assert {:ok, %{mode: :disabled, discovered: 0, processed: 0, actions: []}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FailingGitHub)

    refute_receive {:fetch_ci_status, _}
  end

  test "a poll only observes the head: no move, no comment and no rerun" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status())
    put_run(issue, now)

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:observed, "issue-2401", "green"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    refute_receive {:memory_tracker_comment, _, _}
  end

  test "a designed repo's Code Review state is watched so its head can be called green" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3},
      repos: [[key: "default", workflow: Workflow.workflow_file_path(), team: "Test"]]
    )

    Application.put_env(:symphony_elixir, :ci_test_issues, [])

    assert {:ok, %{discovered: 0, processed: 0, actions: []}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: ~U[2026-05-06 09:00:00Z])

    assert_receive {:fetch_issues_by_states, states}
    assert "Code Review" in states
    # The QA state's run is green-head gated too, so its head must be watched as well.
    assert "QA" in states
    # Every phase whose head goes red routes to the CI Fix lane, Rework included.
    assert "Rework" in states
  end

  test "a Merging head is ready to land once every check its base branch requires passed" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = %{in_review_issue() | state: "Merging"}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    put_run(issue, now)

    make_all = %{name: "make all", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}
    preview = %{name: "deploy/preview", status: "QUEUED", conclusion: nil}
    Application.put_env(:symphony_elixir, :ci_test_status, %{green_status() | checks: [make_all, preview]})

    # Without required checks, the head waits on every check.
    result = CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = result
    assert CiPoller.landing_ready_head("issue-2401") == nil

    Application.put_env(:symphony_elixir, :ci_test_required_checks, ["make all"])

    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert CiPoller.observed_head("issue-2401") == %{commit_sha: "abc123", conclusion: "IN_PROGRESS"}
    assert CiPoller.landing_ready_head("issue-2401", repo_key: @repo_key) == "abc123"

    # Outside Merging, the poller reads no required checks.
    Application.put_env(:symphony_elixir, :ci_test_issues, [in_review_issue()])

    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 2, :minute))

    assert CiPoller.landing_ready_head("issue-2401") == nil
    assert CiPoller.landing_ready_head("issue-unknown") == nil
  end

  test "landing_action lands a pending head once every check the base branch requires passed" do
    make_all = %{name: "make all", status: "COMPLETED", conclusion: "SUCCESS"}
    lint = %{name: "lint", status: "COMPLETED", conclusion: "SUCCESS"}
    preview = %{name: "deploy/preview", status: "QUEUED", conclusion: nil}
    pending_lint = %{lint | status: "IN_PROGRESS", conclusion: nil}
    status = fn checks, required -> %{state: "OPEN", commit_sha: "abc123", checks: checks, required_checks: required} end

    assert CiPoller.landing_action(status.([make_all, lint, preview], ["make all", "lint"])) == :success
    assert CiPoller.landing_action(status.([make_all, lint], ["make all"])) == :success

    # A required check still running, or not reported yet, holds it; so does no required check at all.
    assert CiPoller.landing_action(status.([make_all, pending_lint, preview], ["make all", "lint"])) == :pending
    assert CiPoller.landing_action(status.([make_all, preview], ["make all", "lint"])) == :pending
    assert CiPoller.landing_action(status.([make_all, preview], [])) == :pending
    assert CiPoller.landing_action(Map.delete(status.([make_all, preview], nil), :required_checks)) == :pending

    # A failed check holds it, required or not.
    red_preview = %{preview | status: "COMPLETED", conclusion: "FAILURE"}
    assert {:failure, [%{name: "deploy/preview"}]} = CiPoller.landing_action(status.([make_all, red_preview], ["make all"]))
  end

  test "an issue whose record no longer holds an open PR is named in a warning; one that never had a PR is not" do
    now = ~U[2026-05-06 09:00:00Z]
    pr_url = "https://github.com/example/repo/pull/2401"
    issue = in_review_issue()
    verification = %Issue{id: "issue-2402", identifier: "ACME-2402", title: "Final verification", state: "Code Review"}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue, verification])
    Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
    :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "feature/fix-ci")
    put_run(issue, now)

    poll = &CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, &1, :minute))

    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(0)

    # The record lost its open PR while the poller still watches CI on it.
    :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, "closed")

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(1)
      end)

    assert log =~
             "issue_id=issue-2401 issue_identifier=ACME-2401 is in Code Review with no open PR in Symphony's record of its pull request; " <>
               "Symphony still watches CI on #{pr_url} for it"

    refute log =~ "ACME-2402"
  end

  test "polls the PR Symphony recorded for a ticket, also after a run store restart" do
    now = ~U[2026-05-06 09:00:00Z]
    pr_url = "https://github.com/example/repo/pull/2401"
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
    :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "auto/ACME-2401")
    put_run(issue, now)

    restart_run_store()

    assert {:ok, %{discovered: 1, actions: [{:observed, "issue-2401", "watching"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [%{issue_id: "issue-2401", pr_url: ^pr_url}] = RunStore.list_ci_checks(@repo_key)
  end

  test "a ticket whose recorded PR closed or merged has no PR to poll" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    pr_url = @in_review_pr
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
    put_run(issue, now)

    for state <- ["closed", "merged"] do
      :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "feature/fix-ci")
      :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, state)

      assert {:ok, %{discovered: 0, actions: []}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      assert [] = RunStore.list_ci_checks(@repo_key)
    end
  end

  test "a merged or closed PR the poll reads marks its ticket's PR record" do
    now = ~U[2026-05-06 09:00:00Z]
    pr_url = "https://github.com/example/repo/pull/2401"
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])

    for {gh_state, pr_state} <- [{"MERGED", "merged"}, {"CLOSED", "closed"}] do
      :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "feature/fix-ci")
      Application.put_env(:symphony_elixir, :ci_test_status, %{green_status() | state: gh_state})
      put_run(issue, now)

      assert {:ok, %{actions: [{:cleanup, "issue-2401", "closed"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      assert %{state: ^pr_state} = TicketPullRequest.get(@repo_key, "issue-2401")
    end
  end

  test "a rerun whose failed checks left the rollup reads pending, not green, until they report again" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    lint = %{name: "lint", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}
    failed = %{failed_status("abc123") | checks: [lint | failed_status("abc123").checks]}
    # GitHub dropped the failed `specs` check while the rerun's new attempt queues its jobs.
    rerun_starting = %{green_status() | checks: [lint]}
    rerun_running = %{rerun_starting | checks: [lint, %{name: "specs", status: "QUEUED", conclusion: nil, run_id: "987"}]}
    rerun_green = %{green_status() | checks: [lint | green_status().checks]}

    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_statuses, [failed, rerun_starting, rerun_running, rerun_green])
    put_run(issue, now)
    poll = fn minutes -> CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, minutes, :minute)) end

    assert {:ok, %{actions: [{:observed, "issue-2401", "red"}]}} = poll.(0)
    refute_received {:rerun_failed, _run_id}

    # The PR watcher reran the failed `specs` check of this head (rule R22).
    attempts = %{Attempts.new() | reruns: %{"abc123" => ["specs"]}}
    SymphonyElixir.PrWatchSupport.put_watch!(@repo_key, "issue-2401", attempts: attempts, head_sha: "abc123")

    # Every reader of the head's CI sees the same rerun as pending.
    assert rerun_starting |> CiPoller.put_rerun_pending("issue-2401") |> CiPoller.ci_action() == :pending
    assert rerun_running |> CiPoller.put_rerun_pending("issue-2401") |> CiPoller.ci_action() == :pending
    assert rerun_green |> CiPoller.put_rerun_pending("issue-2401") |> CiPoller.ci_action() == :success
    assert %{rerun_starting | commit_sha: "def456"} |> CiPoller.put_rerun_pending("issue-2401") |> CiPoller.ci_action() == :success
    assert rerun_starting |> CiPoller.put_rerun_pending("issue-other") |> CiPoller.ci_action() == :success
    assert rerun_starting |> CiPoller.put_rerun_pending(nil) |> CiPoller.ci_action() == :success

    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(1)
    assert [%{status: "watching", last_observed_conclusion: "IN_PROGRESS"}] = RunStore.list_ci_checks()

    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(2)
    assert {:ok, %{actions: [{:observed, "issue-2401", "green"}]}} = poll.(3)
    refute_receive {:issue_state_update, _, _}
  end

  test "ci_action reads a head green only once the workflow runs that reported its checks finished" do
    lint = %{name: "lint", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}
    status = %{green_status() | checks: [lint | green_status().checks]}

    # Required checks all present and green, with no workflow runs read: green as before.
    assert CiPoller.ci_action(status) == :success
    assert CiPoller.ci_action(Map.put(status, :workflow_runs, [%{id: "987", status: "COMPLETED", conclusion: "SUCCESS"}])) == :success

    # The rerun's new attempt is queued, or a job with `needs:` hasn't been created yet.
    assert CiPoller.ci_action(Map.put(status, :workflow_runs, [%{id: "987", status: "QUEUED", conclusion: nil}])) == :pending
    assert CiPoller.ci_action(Map.put(status, :workflow_runs, [%{id: "987", status: "IN_PROGRESS", conclusion: nil}])) == :pending

    # A run that reported no check to the rollup (a deployment waiting on approval) doesn't hold the head.
    assert CiPoller.ci_action(Map.put(status, :workflow_runs, [%{id: "555", status: "WAITING", conclusion: nil}])) == :success

    # A failed check still reads as a failure.
    failed = Map.put(failed_status("abc123"), :workflow_runs, [%{id: "987", status: "IN_PROGRESS", conclusion: nil}])
    assert {:failure, [%{name: "specs"}]} = CiPoller.ci_action(failed)
  end

  test "a startup failure reads as a red head, not a pending one" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, startup_failure_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:observed, "issue-2401", "red"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:rerun_failed, _run_id}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "red", last_observed_conclusion: "FAILURE", failed_checks: [%{conclusion: "STARTUP_FAILURE"}]}] = RunStore.list_ci_checks()
  end

  test "a head whose only failed check is one a person must clear is not red: it reads as its other checks" do
    now = ~U[2026-10-20 19:30:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    put_run(issue, now)
    protected = %{name: "protected paths", status: "COMPLETED", conclusion: "FAILURE", run_id: "988"}
    specs = fn status, conclusion -> %{name: "specs", status: status, conclusion: conclusion, run_id: "987"} end

    poll = fn checks ->
      Application.put_env(:symphony_elixir, :ci_test_status, %{failed_status("abc123") | checks: checks})
      CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
    end

    # The other checks passed: green, with the check a person clears still listed.
    assert {:ok, %{actions: [{:observed, "issue-2401", "green"}]}} = poll.([protected, specs.("COMPLETED", "SUCCESS")])
    assert [%{status: "green", failed_checks: [%{name: "protected paths"}]}] = RunStore.list_ci_checks()

    # Another check still runs: watching.
    assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.([protected, specs.("IN_PROGRESS", nil)])

    # Another check failed beside it: red.
    assert {:ok, %{actions: [{:observed, "issue-2401", "red"}]}} = poll.([protected, specs.("COMPLETED", "FAILURE")])
    assert [%{status: "red", failed_checks: [%{name: "protected paths"}, %{name: "specs"}]}] = RunStore.list_ci_checks()
  end

  describe "dispatch.source: record" do
    test "a poll finds the tickets whose records are in its states and reads no Linear" do
      now = ~U[2026-05-06 09:00:00Z]
      record_source!()
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())

      merging = %{in_review_issue() | id: "issue-2402", identifier: "ACME-2402", state: "Merging"}
      todo = %{in_review_issue() | id: "issue-2403", identifier: "ACME-2403", state: "Todo"}
      removed = %{in_review_issue() | id: "issue-2404", identifier: "ACME-2404"}

      for issue <- [in_review_issue(), merging, todo, removed] do
        :ok = TicketPullRequest.record_created(@repo_key, issue.id, "https://github.com/example/repo/pull/#{issue.identifier}", "auto/#{issue.identifier}")
        put_run(issue, now, "success", "run-#{issue.id}")
        assert {:ok, :updated} = TicketObservation.observe(@repo_key, %{issue | updated_at: now}, source: :poll)
      end

      # A webhook said ACME-2404 was removed: its record stays, and it is never listed.
      assert :ok = RunStore.put_ticket_state(TicketState.mark_removed(RunStore.get_ticket_state(@repo_key, removed.id), now))

      # Linear would answer with a ticket the records don't have: the poll must not ask it.
      Application.put_env(:symphony_elixir, :ci_test_issues, [%{in_review_issue() | id: "issue-linear-only"}])

      assert {:ok, %{discovered: 2, processed: 2, actions: actions}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      assert Enum.sort(actions) == [{:observed, "issue-2401", "green"}, {:observed, "issue-2402", "green"}]
      assert Enum.sort(Enum.map(RunStore.list_ci_checks(@repo_key), & &1.issue_id)) == ["issue-2401", "issue-2402"]
      refute_received {:fetch_issues_by_states, _states}

      # A poll scoped to one repo reads its tickets from the records too.
      assert {:ok, %{processed: 2}} =
               CiPoller.poll_once(repo_key: @repo_key, tracker: FakeTracker, github: FakeGitHub, now: now)

      refute_received {:fetch_issues_by_states, _states}
    end

    test "records that can't be read fail the poll instead of reading as no tickets" do
      record_source!()

      opts = [repo_key: @repo_key, tracker: FakeTracker, github: FakeGitHub, run_store: TicketStatesDownRunStore]
      assert {:error, :store_down} = CiPoller.poll_once(opts)
      refute_received {:fetch_issues_by_states, _states}
    end
  end

  describe "with a duplicate run on the head that GitHub cancelled" do
    setup do
      now = ~U[2026-10-06 14:58:00Z]
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      put_run(issue, now)

      check = fn name, run_id, conclusion ->
        status = if conclusion == "", do: "IN_PROGRESS", else: "COMPLETED"
        url = "https://github.com/example/repo/actions/runs/#{run_id}/job/#{name}"
        %{"name" => name, "status" => status, "conclusion" => conclusion, "workflowName" => "ci", "detailsUrl" => url}
      end

      cancelled = for name <- ["server-static", "android", "macos"], do: check.(name, 222, "CANCELLED")
      poll = fn minutes -> CiPoller.poll_once(tracker: FakeTracker, github: RollupGitHub, now: DateTime.add(now, minutes, :minute)) end
      {:ok, check: check, cancelled: cancelled, poll: poll}
    end

    test "reads pending while the other run goes on, and starts no rerun or CI-fix run", %{check: check, cancelled: cancelled, poll: poll} do
      running = [check.("server-static", 111, "SUCCESS"), check.("android", 111, "SUCCESS"), check.("macos", 111, "")]
      Application.put_env(:symphony_elixir, :ci_test_rollups, [running ++ cancelled, running ++ cancelled])

      assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(0)
      assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} = poll.(5)
      assert [%{status: "watching", last_observed_conclusion: "IN_PROGRESS"}] = RunStore.list_ci_checks()

      refute_received {:rerun_failed, _run_id}
      refute_received {:fetch_failed_log, _run_id}
      refute_received {:issue_state_update, _issue_id, _state}
    end

    test "reads green once the other run passed", %{check: check, cancelled: cancelled, poll: poll} do
      green = for name <- ["server-static", "android", "macos"], do: check.(name, 111, "SUCCESS")
      Application.put_env(:symphony_elixir, :ci_test_rollups, [cancelled ++ green])

      assert {:ok, %{actions: [{:observed, "issue-2401", "green"}]}} = poll.(0)
      refute_received {:rerun_failed, _run_id}
      refute_received {:issue_state_update, _issue_id, _state}
    end
  end

  test "each repository keeps only the states it watches from the shared read" do
    now = ~U[2026-05-06 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      repos: multi_repo_config()
    )

    # Auto Review is off, so no repository watches its state, yet the shared read returns an issue in it.
    issue = %{in_review_issue() | id: "issue-pin-85", identifier: "PIN4WOO-85", state: "Auto Review"}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])

    assert :ok =
             RunStore.put_run(%{
               repo_key: "secondary",
               run_id: "run-pin-85",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/PIN4WOO-85",
               worker_host: nil,
               started_at: DateTime.add(now, -2, :minute),
               ended_at: DateTime.add(now, -1, :minute)
             })

    assert {:ok, %{discovered: 0, processed: 0}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:fetch_issues_by_states, states}
    refute "Auto Review" in states
    refute_receive {:fetch_issues_by_states, _states}
    assert [] = RunStore.list_ci_checks("secondary")
  end

  test "polls ci lifecycle records for non-default repos" do
    now = ~U[2026-05-06 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3},
      repos: multi_repo_config()
    )

    issue = %{
      in_review_issue()
      | id: "issue-pin-84",
        identifier: "PIN4WOO-84",
        url: "https://linear.test/PIN4WOO-84"
    }

    :ok = TicketPullRequest.record_created("secondary", "issue-pin-84", "https://github.com/woocommerce/pinterest-for-woocommerce/pull/1185", nil)

    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_statuses, [failed_status("abc123"), failed_status("abc123")])
    Application.put_env(:symphony_elixir, :ci_test_failed_log, "line 1\nERROR: non-default repo failed\nstack")

    assert :ok =
             RunStore.put_run(%{
               repo_key: "secondary",
               run_id: "run-pin-84",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/PIN4WOO-84",
               worker_host: nil,
               started_at: DateTime.add(now, -2, :minute),
               ended_at: DateTime.add(now, -1, :minute)
             })

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:observed, "issue-pin-84", "red"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:rerun_failed, _run_id}
    refute_receive {:issue_state_update, _issue_id, _state}
    assert [] = RunStore.list_ci_checks(@repo_key)

    assert [
             %{
               repo_key: "secondary",
               issue_id: "issue-pin-84",
               status: "red",
               head_ref_name: "feature/fix-ci",
               is_cross_repository: false,
               head_repository: %{"nameWithOwner" => "example/repo"},
               last_observed_sha: "abc123",
               failed_checks: [%{name: "specs"}]
             }
           ] = RunStore.list_ci_checks("secondary")

    assert CiPoller.observed_head("issue-pin-84", repo_key: "secondary") == %{commit_sha: "abc123", conclusion: "FAILURE"}
  end

  test "a poll's run-store cost doesn't grow with the store" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
    put_run(issue, now)

    poll = fn ->
      assert {:ok, %{actions: [{:observed, "issue-2401", "watching"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
    end

    small = reductions(poll)
    put_other_runs(2_000, now)
    large = reductions(poll)

    assert large < small * 1.5, "a CI poll took #{large} reductions over 2001 runs, #{small} over 1"
  end

  test "transient GitHub errors are recorded without dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    put_run(issue, now)

    assert {:ok, %{actions: [{:poll_error, "issue-2401", :rate_limited}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FailingGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "watching", error: ":rate_limited"}] = RunStore.list_ci_checks()
  end

  test "the published status shows the PR watcher's GitHub delivery health beside the poller's own" do
    {:ok, state} = CiPoller.init(tracker: FakeTracker, poll_interval_ms: 3_600_000, repo_key: @repo_key)
    Process.cancel_timer(state.timer_ref)

    assert %{status: :running, poll_interval_ms: 3_600_000, webhooks: webhooks} = CiPoller.status()
    assert %{enabled: false, relay: "smee", events_received: 0, repos: %{}} = webhooks
  end

  test "poll callback backs off, emits degradation audit, and recovers" do
    {:ok, state} =
      CiPoller.init(
        tracker: FakeTracker,
        run_store: RaisingRunStore,
        poll_interval_ms: 100,
        poller_max_backoff_ms: 250,
        poller_degraded_threshold: 2,
        repo_key: @repo_key
      )

    Process.cancel_timer(state.timer_ref)

    log =
      capture_log([level: :error], fn ->
        assert {:noreply, failed_once} = CiPoller.handle_info(:poll, state)
        assert failed_once.consecutive_failures == 1
        assert failed_once.current_backoff_ms == 100
        Process.cancel_timer(failed_once.timer_ref)

        assert {:noreply, degraded} = CiPoller.handle_info(:poll, failed_once)
        assert degraded.consecutive_failures == 2
        assert degraded.current_backoff_ms == 200
        assert degraded.degraded?
        Process.cancel_timer(degraded.timer_ref)

        assert {:noreply, capped} = CiPoller.handle_info(:poll, degraded)
        assert capped.consecutive_failures == 3
        assert capped.current_backoff_ms == 250
        Process.cancel_timer(capped.timer_ref)

        successful = %{capped | opts: Keyword.put(capped.opts, :run_store, RunStore)}

        info_log =
          capture_log([level: :info], fn ->
            assert {:noreply, recovered} = CiPoller.handle_info(:poll, successful)
            assert recovered.consecutive_failures == 0
            assert recovered.current_backoff_ms == nil
            refute recovered.degraded?
            Process.cancel_timer(recovered.timer_ref)
          end)

        assert info_log =~ "CI poll recovered after 3 consecutive failures"
      end)

    assert log =~ "CI poll raised"
    assert log =~ "ci poll exploded"
    assert log =~ "CI poll backing off after 2 consecutive failures; next poll in 200ms"
    assert log =~ "CI poll backing off after 3 consecutive failures; next poll in 250ms"

    assert audit_event?("poller_degraded", "ci", "degraded")
    assert audit_event?("poller_recovered", "ci", "recovered")
  end

  defp pending_status do
    %{green_status() | checks: [%{name: "specs", status: "IN_PROGRESS", conclusion: nil, run_id: "987"}]}
  end

  defp in_review_issue do
    %Issue{
      id: "issue-2401",
      identifier: "ACME-2401",
      title: "Handle CI",
      state: "Code Review",
      url: "https://linear.test/ACME-2401",
      labels: []
    }
  end

  # A designed repo: the machine whose red heads route to the CI Fix lane.
  # Stops the run store and starts it again, as a Symphony restart does; its records are on disk.
  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end

  defp put_run(issue, now, status \\ "success", run_id \\ "run-1") do
    RunStore.put_run(%{
      repo_key: @repo_key,
      run_id: run_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      status: status,
      workspace_path: "/tmp/workspaces/ACME-2401",
      worker_host: nil,
      started_at: DateTime.add(now, -2, :minute),
      ended_at: run_ended_at(status, now)
    })
  end

  # Finished runs of other issues, as a store holding months of history has.
  defp put_other_runs(count, now) do
    for n <- 1..count do
      run = %{repo_key: @repo_key, run_id: "other-#{n}", issue_id: "other-#{n}", kind: "agent", status: "success", workspace_path: "/tmp/other"}
      assert :ok = RunStore.put_run(Map.put(run, :started_at, DateTime.add(now, -n, :minute)))
    end
  end

  # The reductions of `fun`'s second call, so both measure a warm cycle.
  defp reductions(fun) do
    fun.()
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end

  defp run_ended_at("running", _now), do: nil
  defp run_ended_at(_status, now), do: DateTime.add(now, -1, :minute)

  defp record_source! do
    File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n")
    Cache.clear()
  end

  defp multi_repo_config do
    [
      %{key: @repo_key, workflow: Workflow.workflow_file_path(), default: true, team: "Test"},
      %{key: "secondary", workflow: Workflow.workflow_file_path(), team: "PIN4WOO", labels: ["Bug"]}
    ]
  end

  defp green_status(sha \\ "abc123") do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      head_ref_name: "feature/fix-ci",
      is_cross_repository: false,
      head_repository: %{"nameWithOwner" => "example/repo"},
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}
      ]
    }
  end

  defp failed_status(sha) do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      head_ref_name: "feature/fix-ci",
      is_cross_repository: false,
      head_repository: %{"nameWithOwner" => "example/repo"},
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"}
      ]
    }
  end

  defp startup_failure_status(sha) do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      head_ref_name: "feature/fix-ci",
      is_cross_repository: false,
      head_repository: %{"nameWithOwner" => "example/repo"},
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "STARTUP_FAILURE", run_id: "987"}
      ]
    }
  end

  defp audit_event?(event_type, poller, status) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: event_type)

    Enum.any?(events, fn event ->
      event["poller"] == poller and event["status"] == status
    end)
  end
end
