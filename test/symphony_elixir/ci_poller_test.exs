defmodule SymphonyElixir.CiPollerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]

  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.CiState
  alias SymphonyElixir.PrWatch.Attempts
  alias SymphonyElixir.TicketPullRequest

  @endpoint SymphonyElixirWeb.Endpoint

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

  defmodule WebhookRaisingRunStore do
    def list_ci_checks(_repo_key), do: [%{issue_id: "issue-2401", repo_key: "default", pr_url: "https://github.com/example/repo/pull/2401"}]
    def get_ticket_state(_repo_key, _issue_id), do: nil
    def update_ci_check(_repo_key, _issue_id, _attrs), do: raise("webhook poll exploded")
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

  # FakeTracker plus the machine-label writes `SymphonyElixir.CiState` projects, so a test can see
  # the CI labels a webhook delivery or a poll puts on the ticket.
  defmodule LabelTracker do
    defdelegate fetch_issues_by_states(states), to: FakeTracker
    defdelegate fetch_issue_states_by_ids(issue_ids), to: FakeTracker
    defdelegate update_issue_state(issue_id, state_name), to: FakeTracker
    defdelegate create_comment(issue_id, body), to: FakeTracker

    def set_machine_label(issue_id, label_name) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:machine_label_set, issue_id, label_name})
      :ok
    end

    def clear_machine_label(issue_id, label_name) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:machine_label_clear, issue_id, label_name})
      :ok
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
      Application.delete_env(:symphony_elixir, :ci_test_self_pid)

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

  describe "with GitHub webhooks on" do
    @webhook_secret "s3cret"

    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3, flaky_retry: false},
        github: %{webhooks: %{enabled: true, secret: @webhook_secret}}
      )

      name = Module.concat(__MODULE__, "Poller#{System.unique_integer([:positive])}")
      start_test_endpoint(ci_poller: name)
      {:ok, name: name}
    end

    test "a signed check_suite completed for a Merging PR's head lands it green within 5 s", %{name: name} do
      issue = %{in_review_issue() | state: "Merging"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_statuses, [pending_status()])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, on_webhook_result: fn -> send(self_pid(), :refresh_requested) end)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") == %{commit_sha: "abc123", conclusion: "IN_PROGRESS"} end)

      assert %{"status" => "accepted"} = deliver_webhook("check_suite", check_suite_completed("abc123"), 202)

      assert_receive :refresh_requested, 5_000
      assert CiPoller.observed_head("issue-2401") == %{commit_sha: "abc123", conclusion: "SUCCESS"}

      assert %{webhooks: webhooks} = CiPoller.status()

      assert %{enabled: true, relay: "smee", events_received: 1, last_event_at: %DateTime{}} = webhooks
      assert %{results_via_webhook: 1, results_via_poll: 0} = webhooks
    end

    test "with the relay down the timed poll alone lands the PR", %{name: name} do
      issue = %{in_review_issue() | state: "Merging"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_statuses, [pending_status()])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, poll_interval_ms: 50, settings: Config.settings!())

      assert_eventually(fn -> CiPoller.observed_head("issue-2401") == %{commit_sha: "abc123", conclusion: "SUCCESS"} end)

      assert_eventually(fn ->
        match?(%{webhooks: %{enabled: true, events_received: 0, results_via_webhook: 0, results_via_poll: 1}}, CiPoller.status())
      end)
    end

    test "a ping catches up with a full poll at once", %{name: name} do
      Application.put_env(:symphony_elixir, :ci_test_issues, [])
      start_webhook_poller(name)
      assert_receive {:fetch_issues_by_states, _states}, 5_000

      assert %{"status" => "catching_up"} = deliver_webhook("ping", %{"zen" => "Design for failure."}, 202)

      assert_receive {:fetch_issues_by_states, _states}, 5_000
    end

    test "deliveries about unwatched PRs, ignored events and bad signatures run no poll", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name)
      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)

      deliver_webhook("check_suite", check_suite_completed("other-sha", 99), 202)
      assert %{"status" => "ignored"} = deliver_webhook("check_suite", %{"action" => "requested"}, 202)

      log =
        capture_log(fn ->
          conn = post_webhook("check_suite", Jason.encode!(check_suite_completed("abc123")), "sha256=" <> String.duplicate("0", 64))
          assert json_response(conn, 401)
        end)

      assert log =~ "Rejected GitHub webhook"
      refute log =~ "abc123"

      assert_eventually(fn -> match?(%{webhooks: %{events_received: 2, rejected: 1}}, CiPoller.status()) end)
      refute_receive {:fetch_ci_status, _pr_url}, 200
    end

    test "a burst of deliveries runs one poll", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, webhook_debounce_ms: 200)
      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)

      for event <- ["check_run", "check_run", "check_suite"] do
        deliver_webhook(event, %{"action" => "completed", "repository" => repository(), event => %{"head_sha" => "abc123"}}, 202)
      end

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      refute_receive {:fetch_ci_status, _pr_url}, 400
    end

    test "a red delivery writes the CI attribute and the CI red label without a poll", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("running")
      assert_receive {:machine_label_set, "issue-2401", "CI running"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("check_suite", check_suite_failed("abc123"), 202)

      assert_receive {:machine_label_set, "issue-2401", "CI red"}, 5_000
      assert_receive {:machine_label_clear, "issue-2401", "CI running"}, 5_000
      assert %{ci_states: [%{head_sha: "abc123", status: "red"}]} = RunStore.get_ticket_state(@repo_key, "issue-2401")
      refute_receive {:fetch_ci_status, _pr_url}, 200
    end

    test "a push to a new head projects CI running at once", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("green")
      assert_receive {:machine_label_set, "issue-2401", "CI green"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("pull_request", pull_request_synchronized("newsha"), 202)

      assert_receive {:machine_label_set, "issue-2401", "CI running"}, 5_000
      assert_receive {:machine_label_clear, "issue-2401", "CI green"}, 5_000

      assert %{ci_states: [%{head_sha: "newsha", status: "running"}, %{head_sha: "abc123", status: "green"}]} =
               RunStore.get_ticket_state(@repo_key, "issue-2401")
    end

    test "a delivery older than the poll's read cannot overwrite it", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("green")
      assert_receive {:machine_label_set, "issue-2401", "CI green"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("check_suite", check_suite_failed("abc123", "2020-01-01T00:00:00Z"), 202)

      refute_receive {:machine_label_set, "issue-2401", "CI red"}, 300
      assert %{ci_states: [%{head_sha: "abc123", status: "green"}]} = RunStore.get_ticket_state(@repo_key, "issue-2401")
    end

    test "a merged PR asks the PR watcher to read now; any other delivery does not", %{name: name} do
      start_webhook_poller(name, on_base_moved: fn -> send(self_pid(), :base_moved) end)

      deliver_webhook("pull_request", pull_request_closed(), 202)
      refute_receive :base_moved, 100

      deliver_webhook("pull_request", put_in(pull_request_closed(), ["pull_request", "merged"], true), 202)
      assert_receive :base_moved, 5_000
    end

    test "a PR closed without merging marks its ticket's PR record; a merged one is left to the polls", %{name: name} do
      pr_url = "https://github.com/example/repo/pull/2401"
      start_webhook_poller(name, on_base_moved: fn -> send(self_pid(), :base_moved) end)

      # The PR watcher moves a Merging ticket to Done before it marks its merged PR finished.
      :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "feature/fix-ci")
      deliver_webhook("pull_request", put_in(pull_request_closed(), ["pull_request", "merged"], true), 202)
      assert_receive :base_moved, 5_000
      assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-2401")

      deliver_webhook("pull_request", pull_request_closed(), 202)
      assert_eventually(fn -> match?(%{state: "closed"}, TicketPullRequest.get(@repo_key, "issue-2401")) end)

      # A push to the PR leaves the record as it is.
      :ok = TicketPullRequest.record_created(@repo_key, "issue-2401", pr_url, "feature/fix-ci")
      deliver_webhook("pull_request", pull_request_synchronized("newsha"), 202)
      :sys.get_state(name)
      assert %{state: "open"} = TicketPullRequest.get(@repo_key, "issue-2401")
    end

    test "closing a PR clears the CI labels and leaves the recorded state", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, pending_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("running")
      assert_receive {:machine_label_set, "issue-2401", "CI running"}, 5_000
      assert_receive {:machine_label_clear, "issue-2401", "CI green"}, 5_000
      assert_receive {:machine_label_clear, "issue-2401", "CI red"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("pull_request", pull_request_closed(), 202)

      for label <- ["CI green", "CI red", "CI running"] do
        assert_receive {:machine_label_clear, "issue-2401", ^label}, 5_000
      end

      refute_receive {:machine_label_set, "issue-2401", _label}, 200
      assert %{ci_states: [%{head_sha: "abc123", status: "running"}]} = RunStore.get_ticket_state(@repo_key, "issue-2401")
    end

    test "a check event on a head the record has moved past leaves the store and labels alone", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("green")
      assert_receive {:machine_label_set, "issue-2401", "CI green"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("check_suite", check_suite_failed("oldsha"), 202)

      refute_receive {:machine_label_set, "issue-2401", "CI red"}, 300
      assert %{ci_states: [%{head_sha: "abc123", status: "green"}]} = RunStore.get_ticket_state(@repo_key, "issue-2401")
    end

    test "a synchronize delivery naming no head is a no-op", %{name: name} do
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, tracker: LabelTracker, webhook_debounce_ms: 3_600_000)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)
      watcher_projects!("green")
      assert_receive {:machine_label_set, "issue-2401", "CI green"}, 5_000

      assert %{"status" => "accepted"} = deliver_webhook("pull_request", pull_request_synchronized_without_head(), 202)

      refute_receive {:machine_label_set, "issue-2401", "CI running"}, 300
      assert %{ci_states: [%{head_sha: "abc123", status: "green"}]} = RunStore.get_ticket_state(@repo_key, "issue-2401")
    end

    test "a webhook poll that fails is logged and the poller keeps running", %{name: name} do
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())

      log =
        capture_log(fn ->
          start_webhook_poller(name, run_store: WebhookRaisingRunStore)
          assert :ok = CiPoller.webhook_delivery({:ci, %{event: "check_suite", action: "completed", head_sha: nil, pr_urls: ["https://github.com/example/repo/pull/2401"]}}, name)

          assert_eventually(fn ->
            state = :sys.get_state(name)
            state.webhook_timer_ref == nil and state.webhooks.events_received == 1
          end)

          :sys.get_state(name)
        end)

      assert log =~ "CI poll for a GitHub webhook failed repo_key=default"
      assert log =~ "webhook poll exploded"
    end

    test "a webhook result asks the orchestrator to refresh", %{name: name} do
      issue = %{in_review_issue() | state: "Merging"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_statuses, [pending_status()])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name)
      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)

      deliver_webhook("check_suite", check_suite_completed("abc123"), 202)

      assert_eventually(fn -> match?(%{webhooks: %{results_via_webhook: 1}}, CiPoller.status()) end)
    end

    test "the endpoint answers 503 while the CI poller is not running" do
      assert %{"error" => %{"code" => "ci_poller_unavailable"}} = deliver_webhook("check_suite", check_suite_completed("abc123"), 503)
      assert CiPoller.webhook_delivery(:ping, Module.concat(__MODULE__, Missing)) == :unavailable
    end
  end

  # The ticket's CI label as the PR watcher projects it from its read of the head.
  defp watcher_projects!(status) do
    :ok = CiState.record(@repo_key, "issue-2401", "abc123", status, DateTime.utc_now(), tracker: LabelTracker)
  end

  defp start_webhook_poller(name, opts \\ []) do
    opts =
      Keyword.merge(
        [name: name, tracker: FakeTracker, github: FakeGitHub, poll_interval_ms: 3_600_000, webhook_debounce_ms: 10],
        opts
      )

    pid = start_supervised!({CiPoller, opts})
    Application.put_env(:symphony_elixir, :ci_test_self_pid, self())
    pid
  end

  defp self_pid, do: Application.fetch_env!(:symphony_elixir, :ci_test_self_pid)

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp deliver_webhook(event, payload, status) do
    body = Jason.encode!(payload)
    signature = "sha256=" <> (:hmac |> :crypto.mac(:sha256, @webhook_secret, body) |> Base.encode16(case: :lower))

    event
    |> post_webhook(body, signature)
    |> json_response(status)
  end

  defp post_webhook(event, body, signature) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-github-event", event)
    |> Plug.Conn.put_req_header("x-github-delivery", "delivery-1")
    |> Plug.Conn.put_req_header("x-hub-signature-256", signature)
    |> post("/api/v1/github/webhook", body)
  end

  defp check_suite_completed(head_sha, pr_number \\ 2401) do
    %{
      "action" => "completed",
      "repository" => repository(),
      "check_suite" => %{"head_sha" => head_sha, "conclusion" => "success", "pull_requests" => [%{"number" => pr_number}]}
    }
  end

  defp repository, do: %{"full_name" => "example/repo", "html_url" => "https://github.com/example/repo"}

  defp check_suite_failed(head_sha, completed_at \\ nil) do
    suite = %{"head_sha" => head_sha, "conclusion" => "failure", "pull_requests" => [%{"number" => 2401}]}
    suite = if completed_at, do: Map.put(suite, "completed_at", completed_at), else: suite

    %{"action" => "completed", "repository" => repository(), "check_suite" => suite}
  end

  defp pull_request_synchronized(head_sha) do
    %{
      "action" => "synchronize",
      "repository" => repository(),
      "pull_request" => %{"html_url" => "https://github.com/example/repo/pull/2401", "head" => %{"sha" => head_sha}}
    }
  end

  defp pull_request_closed do
    %{
      "action" => "closed",
      "repository" => repository(),
      "pull_request" => %{"html_url" => "https://github.com/example/repo/pull/2401", "head" => %{"sha" => "abc123"}}
    }
  end

  # A synchronize whose payload names no head: GitHub's shape when the head branch was deleted.
  defp pull_request_synchronized_without_head do
    %{
      "action" => "synchronize",
      "repository" => repository(),
      "pull_request" => %{"html_url" => "https://github.com/example/repo/pull/2401", "head" => %{}}
    }
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && assert_eventually(fun, attempts - 1)
    end
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

  defp put_run(issue, now, status \\ "success") do
    RunStore.put_run(%{
      repo_key: @repo_key,
      run_id: "run-1",
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
