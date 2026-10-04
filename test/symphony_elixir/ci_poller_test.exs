defmodule SymphonyElixir.CiPollerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, post: 3, json_response: 2]

  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.Notifications

  @endpoint SymphonyElixirWeb.Endpoint

  @repo_key "default"

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
      send(recipient, {:ci_failure_at_transition, issue_id, SymphonyElixir.CiPoller.pending_ci_failure(issue_id)})
      send(recipient, {:issue_state_update, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:issue_comment, issue_id, body})
      :ok
    end
  end

  defmodule FakeGitHub do
    def fetch_ci_status(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_ci_status, pr_url})
      next_status()
    end

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
    def list_runs(:all), do: []
    def list_ci_checks, do: [Application.fetch_env!(:symphony_elixir, :ci_test_ci_record)]
    def update_ci_check(_issue_id, _attrs), do: {:error, :write_failed}
    def put_ci_check(_record), do: :ok
    def delete_ci_check(_issue_id), do: :ok
  end

  defmodule FailingEscalationFinalUpdateRunStore do
    def list_runs(repo_key, scope), do: SymphonyElixir.RunStore.list_runs(repo_key, scope)
    def list_ci_checks(repo_key), do: SymphonyElixir.RunStore.list_ci_checks(repo_key)
    def list_pr_reviews(repo_key), do: SymphonyElixir.RunStore.list_pr_reviews(repo_key)
    def put_ci_check(record), do: SymphonyElixir.RunStore.put_ci_check(record)
    def delete_ci_check(repo_key, issue_id), do: SymphonyElixir.RunStore.delete_ci_check(repo_key, issue_id)

    def update_ci_check(_repo_key, _issue_id, %{status: "escalated"}), do: {:error, :write_failed}

    def update_ci_check(repo_key, issue_id, attrs),
      do: SymphonyElixir.RunStore.update_ci_check(repo_key, issue_id, attrs)
  end

  defmodule RaisingRunStore do
    def list_runs(:all), do: raise("ci poll exploded")
    def list_ci_checks, do: []
  end

  defmodule CountingRunStore do
    def list_runs(repo_key, scope) do
      bump(:list_runs)
      SymphonyElixir.RunStore.list_runs(repo_key, scope)
    end

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
    def list_ci_checks(_repo_key), do: [%{issue_id: "issue-2401", pr_url: "https://github.com/example/repo/pull/2401"}]
    def list_runs(_repo_key, _scope), do: raise("webhook poll exploded")
  end

  defmodule FailingTransitionTracker do
    def fetch_issues_by_states(_states), do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:issue_state_update, issue_id, state_name})
      {:error, :linear_unavailable}
    end
  end

  defmodule FakeQaRunner do
    def request(job, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :ci_test_recipient), {:qa_request, job})
      :started
    end
  end

  defmodule QaFailureStore do
    def list_ci_checks(_repo_key), do: [Application.fetch_env!(:symphony_elixir, :ci_test_ci_record)]
    def update_ci_check(_repo_key, _issue_id, _attrs), do: {:error, :store_down}
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
      Application.delete_env(:symphony_elixir, :ci_test_failed_log)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log_error)
      Application.delete_env(:symphony_elixir, :ci_test_failed_logs_by_run_id)
      Application.delete_env(:symphony_elixir, :ci_test_rerun_error_run_id)
      Application.delete_env(:symphony_elixir, :ci_test_recipient)
      Application.delete_env(:symphony_elixir, :ci_test_review_activity)
      Application.delete_env(:symphony_elixir, :ci_test_ci_record)
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

  test "green ci records no dispatch and posts no comments" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status())
    put_run(issue, now)

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    refute_receive {:memory_tracker_comment, _, _}
  end

  test "with Auto Review off In Review and Merging issues are watched" do
    now = ~U[2026-05-06 09:00:00Z]
    Application.put_env(:symphony_elixir, :ci_test_issues, [])

    assert {:ok, %{discovered: 0, processed: 0, actions: []}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:fetch_issues_by_states, ["In Review", "Merging"]}
  end

  test "a Merging issue's head is recorded and a red head goes through the CI-failure dispatch" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = %{in_review_issue() | state: "Merging"}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    running_status = %{green_status() | checks: [%{name: "specs", status: "IN_PROGRESS", conclusion: nil, run_id: "987"}]}
    Application.put_env(:symphony_elixir, :ci_test_statuses, [running_status, green_status()])
    put_run(issue, now)

    assert CiPoller.observed_head("issue-2401") == nil

    assert {:ok, %{discovered: 1, actions: [{:watching, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert CiPoller.observed_head("issue-2401") == %{commit_sha: "abc123", conclusion: "IN_PROGRESS"}

    assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert %{conclusion: "SUCCESS"} = CiPoller.observed_head("issue-2401", repo_key: @repo_key)

    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 2, :minute))

    assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 3, :minute))

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}
    assert CiPoller.observed_head("issue-2401") == %{commit_sha: "def456", conclusion: "FAILURE"}
  end

  describe "with Auto Review on" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3},
        auto_review: %{enabled: true}
      )

      :ok
    end

    test "green CI asks the QA runner for a pass on the PR head" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, now)

      assert {:ok, %{discovered: 1, processed: 1, actions: [{:qa_started, "issue-2401", "abc123"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: now)

      assert_receive {:fetch_issues_by_states, ["In Review", "Auto Review", "Merging"]}
      assert_receive {:qa_request, %{issue: %Issue{id: "issue-2401"}, sha: "abc123", record: %{workspace_path: "/tmp/workspaces/ACME-2401"}}}
      refute_receive {:issue_state_update, _, _}
      assert [%{status: "green"}] = RunStore.list_ci_checks()
    end

    test "red CI sends an Auto Review issue back to In Progress" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
      put_run(issue, now)

      assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

      assert_receive {:issue_state_update, "issue-2401", "In Progress"}
      refute_receive {:issue_state_update, "issue-2401", "In Review"}
    end

    test "a CI-fix run handed to Auto Review while CI runs on its pushed head gets QA once that head is green" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      new_head_pending = %{pending_status() | commit_sha: "def456"}
      Application.put_env(:symphony_elixir, :ci_test_statuses, [failed_status("abc123"), failed_status("abc123"), new_head_pending])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
      put_run(issue, now)
      poll = &CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: DateTime.add(now, &1, :minute))

      assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} = poll.(0)
      assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} = poll.(1)
      assert %{} = CiPoller.pending_ci_failure("issue-2401")

      # The fix run pushed def456 and moved the issue back to Auto Review while its CI ran.
      assert {:ok, %{actions: [{:watching, "issue-2401"}]}} = poll.(2)
      assert {:ok, %{actions: [{:qa_started, "issue-2401", "def456"}]}} = poll.(3)

      assert_receive {:qa_request, %{issue: %Issue{id: "issue-2401"}, sha: "def456"}}
      assert CiPoller.pending_ci_failure("issue-2401") == nil
      assert_receive {:issue_state_update, "issue-2401", "In Progress"}
      refute_receive {:issue_state_update, "issue-2401", _state}
    end

    test "green CI leaves an In Review issue where it is" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = in_review_issue()
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, now)

      assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      refute_receive {:issue_state_update, _, _}
    end

    test "a stored QA verdict for the head is applied again until the move succeeds" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "auto review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, now)

      assert {:ok, %{actions: [{:qa_started, "issue-2401", "abc123"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: now)

      :ok =
        RunStore.update_ci_check(@repo_key, "issue-2401", %{
          qa_sha: "abc123",
          qa_verdict: "pass",
          qa_target_state: "In Review",
          qa_applied: false
        })

      assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :auto_review, :linear_unavailable}]}} =
               CiPoller.poll_once(tracker: FailingAutoReviewTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: DateTime.add(now, 1, :minute))

      assert_receive {:issue_state_update, "issue-2401", "In Review"}

      assert {:ok, %{actions: [{:auto_review_qa, "issue-2401", :pass, "In Review"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: DateTime.add(now, 2, :minute))

      assert [%{qa_applied: true}] = RunStore.list_ci_checks()
    end

    test "pending QA failures are read and cleared per issue" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, now)

      assert {:ok, _summary} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: now)

      assert CiPoller.pending_qa_failure("issue-2401") == nil
      assert CiPoller.pending_qa_failure(nil) == nil
      assert :ok = CiPoller.complete_pending_qa_failure("issue-2401")

      qa_failure = %{commit_sha: "abc123", summary: "broken", findings: ["`symphony check` exits 0 on a bad config"]}
      :ok = RunStore.update_ci_check(@repo_key, "issue-2401", %{qa_failure: qa_failure})

      assert CiPoller.pending_qa_failure("issue-2401") == qa_failure
      assert CiPoller.pending_qa_failure("issue-2401", repo_key: @repo_key) == qa_failure
      assert CiPoller.pending_qa_failure("other-issue") == nil
      assert :ok = CiPoller.complete_pending_qa_failure("issue-2401", repo_key: @repo_key)
      assert CiPoller.pending_qa_failure("issue-2401") == nil
    end

    test "clearing a QA failure reports a store error" do
      record = %{repo_key: @repo_key, issue_id: "issue-2401", qa_failure: %{findings: ["x"]}}
      Application.put_env(:symphony_elixir, :ci_test_ci_record, record)

      assert {:error, :store_down} =
               CiPoller.complete_pending_qa_failure("issue-2401", repo_key: @repo_key, run_store: QaFailureStore)
    end

    test "a conflicting PR with no checks goes to Rework with a comment" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, conflicting_status())
      put_run(issue, now)

      assert {:ok, %{actions: [{:auto_review_conflict, "issue-2401", "Rework"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, qa_runner: FakeQaRunner, now: now)

      assert_receive {:issue_state_update, "issue-2401", "Rework"}
      assert_receive {:issue_comment, "issue-2401", body}
      assert body =~ "PR conflicts with `develop`; merge it and push."
      refute_receive {:qa_request, _job}
    end

    test "a conflicting PR without a base branch names the repository's base branch" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      status = %{conflicting_status() | base_ref_name: nil, merge_state_status: nil}
      Application.put_env(:symphony_elixir, :ci_test_status, status)
      put_run(issue, now)

      log =
        capture_log(fn ->
          assert {:ok, %{actions: [{:auto_review_conflict, "issue-2401", "Rework"}]}} =
                   CiPoller.poll_once(tracker: FailingCommentTracker, github: FakeGitHub, now: now)
        end)

      assert_receive {:issue_state_update, "issue-2401", "Rework"}
      assert_receive {:issue_comment, "issue-2401", body}
      assert body =~ "PR conflicts with `main`; merge it and push."
      assert log =~ "Failed to comment on ACME-2401 about its conflicting PR"
    end

    test "a failed move to Rework is retried on the next poll without commenting" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, conflicting_status())
      put_run(issue, now)

      capture_log(fn ->
        assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :auto_review_conflict, :linear_unavailable}]}} =
                 CiPoller.poll_once(tracker: FailingAutoReviewTracker, github: FakeGitHub, now: now)
      end)

      refute_receive {:issue_comment, _issue_id, _body}

      assert {:ok, %{actions: [{:auto_review_conflict, "issue-2401", "Rework"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))
    end

    test "a clean PR with pending checks keeps waiting" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])

      Application.put_env(:symphony_elixir, :ci_test_status, %{
        conflicting_status()
        | mergeable: "MERGEABLE",
          merge_state_status: "BLOCKED",
          checks: [%{name: "specs", status: "IN_PROGRESS", conclusion: nil, run_id: "987"}]
      })

      put_run(issue, now)

      assert {:ok, %{actions: [{:watching, "issue-2401"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      refute_receive {:issue_state_update, _issue_id, _state}
      refute_receive {:issue_comment, _issue_id, _body}
      assert [%{status: "watching"}] = RunStore.list_ci_checks()
    end

    test "a conflicting PR that has checks, or is not in Auto Review, keeps waiting" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: "Auto Review"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])

      Application.put_env(:symphony_elixir, :ci_test_status, %{
        conflicting_status()
        | checks: [%{name: "specs", status: "QUEUED", conclusion: nil, run_id: "987"}]
      })

      put_run(issue, now)

      assert {:ok, %{actions: [{:watching, "issue-2401"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

      Application.put_env(:symphony_elixir, :ci_test_issues, [in_review_issue()])
      Application.put_env(:symphony_elixir, :ci_test_status, conflicting_status())

      assert {:ok, %{actions: [{:watching, "issue-2401"}]}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

      refute_receive {:issue_state_update, _issue_id, _state}
      refute_receive {:issue_comment, _issue_id, _body}
    end

    test "an issue with no state is not treated as in Auto Review" do
      now = ~U[2026-05-06 09:00:00Z]
      issue = %{in_review_issue() | state: nil}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_status, green_status())
      put_run(issue, now)

      # Nor in any state the repository watches, so it isn't picked up at all.
      assert {:ok, %{discovered: 0, processed: 0, actions: []}} =
               CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
    end
  end

  test "first failure reruns failed jobs without dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "startup failure conclusion follows failure path instead of pending" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, startup_failure_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], failed_checks: [%{conclusion: "STARTUP_FAILURE"}]}] =
             RunStore.list_ci_checks()
  end

  test "first failure reruns every distinct failed workflow run before dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, multi_failed_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", ["987", "654"]}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    assert_receive {:rerun_failed, "654"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], rerun_run_ids: ["987", "654"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "partial multi-run rerun failure persists successful run ids before retry" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, multi_failed_status("abc123"))
    Application.put_env(:symphony_elixir, :ci_test_rerun_error_run_id, "654")
    put_run(issue, now)

    assert {:ok, %{actions: [{:poll_error, "issue-2401", {:rerun_failed, "654", :rerun_unavailable}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: PartiallyFailingRerunGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    assert_receive {:rerun_failed, "654"}

    assert [
             %{
               status: "rerun_requested",
               rerun_run_ids: ["987"],
               rerun_attempted_shas: [],
               error: "{:rerun_failed, \"654\", :rerun_unavailable}"
             }
           ] = RunStore.list_ci_checks()

    Application.delete_env(:symphony_elixir, :ci_test_rerun_error_run_id)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", ["987", "654"]}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: PartiallyFailingRerunGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:rerun_failed, "654"}
    refute_receive {:rerun_failed, "987"}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], rerun_run_ids: ["987", "654"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "second failure dispatches once with prompt ci failure context" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_statuses, [failed_status("abc123"), failed_status("abc123"), failed_status("abc123")])
    Application.put_env(:symphony_elixir, :ci_test_failed_log, Enum.map_join(1..5, "\n", &"line #{&1}") <> "\nERROR: specs failed\nstack")
    put_run(issue, now)
    Notifications.subscribe()

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:ci_failure_at_transition, "issue-2401",
                    %{
                      commit_sha: "abc123",
                      head_ref_name: "feature/fix-ci",
                      is_cross_repository: false,
                      head_repository: %{"nameWithOwner" => "example/repo"},
                      log_excerpt: transition_log_excerpt
                    }}

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}
    assert_receive {:fetch_failed_log, "987"}
    assert_receive {:notification_event, %{event: "ci_failed", state: "In Progress", metadata: %{retry_count: 1}}}
    assert transition_log_excerpt =~ "ERROR: specs failed"

    assert %{
             commit_sha: "abc123",
             head_ref_name: "feature/fix-ci",
             is_cross_repository: false,
             head_repository: %{"nameWithOwner" => "example/repo"},
             failed_checks: [%{name: "specs"}],
             log_excerpt: log_excerpt
           } = CiPoller.pending_ci_failure("issue-2401")

    assert log_excerpt =~ "ERROR: specs failed"
    refute log_excerpt =~ "line 1"

    prompt = PromptBuilder.build_prompt(issue, ci_failure: CiPoller.pending_ci_failure("issue-2401"))
    assert prompt =~ "CI failure:"
    assert prompt =~ "Failed checks: specs"
    assert prompt =~ "Commit SHA: abc123"
    assert prompt =~ "ERROR: specs failed"

    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 2, :minute))

    refute_receive {:issue_state_update, _, _}
  end

  test "pending ci failure normalizes persisted string-key metadata" do
    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: "default",
               issue_id: "issue-ci-strings",
               issue_identifier: "RSM-CI-STRINGS",
               status: "dispatch_requested",
               ci_retry_count: 1,
               ci_failure: %{
                 "commit_sha" => "abc123",
                 "head_ref_name" => "feature/string-ci",
                 "is_cross_repository" => false,
                 "head_repository" => %{"nameWithOwner" => "example/repo"},
                 "failed_checks" => [%{"name" => "specs"}],
                 "log_excerpt" => "specs failed"
               },
               updated_at: ~U[2026-05-06 09:00:00Z]
             })

    assert %{
             commit_sha: "abc123",
             head_ref_name: "feature/string-ci",
             is_cross_repository: false,
             head_repository: %{"nameWithOwner" => "example/repo"},
             failed_checks: [%{"name" => "specs"}],
             log_excerpt: "specs failed"
           } = CiPoller.pending_ci_failure("issue-ci-strings")
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
        url: "https://linear.test/PIN4WOO-84",
        pr_urls: ["https://github.com/woocommerce/pinterest-for-woocommerce/pull/1185"]
    }

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

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:rerun_requested, "issue-pin-84", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}

    assert {:ok, %{actions: [{:state_transitioned, "issue-pin-84", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:ci_failure_at_transition, "issue-pin-84", %{commit_sha: "abc123", log_excerpt: transition_log_excerpt}}
    assert_receive {:issue_state_update, "issue-pin-84", "In Progress"}
    assert transition_log_excerpt =~ "ERROR: non-default repo failed"
    assert [] = RunStore.list_ci_checks(@repo_key)

    assert [
             %{
               repo_key: "secondary",
               issue_id: "issue-pin-84",
               status: "dispatch_requested",
               head_ref_name: "feature/fix-ci",
               is_cross_repository: false,
               head_repository: %{"nameWithOwner" => "example/repo"},
               ci_retry_count: 1,
               ci_failure: %{commit_sha: "abc123"}
             }
           ] = RunStore.list_ci_checks("secondary")

    assert %{log_excerpt: log_excerpt} = CiPoller.pending_ci_failure("issue-pin-84")
    assert log_excerpt =~ "ERROR: non-default repo failed"
  end

  test "failed log fetch errors back off without dispatching or consuming retries" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
    Application.put_env(:symphony_elixir, :ci_test_failed_log_error, :log_not_ready)
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    assert {:ok, %{actions: [{:poll_error, "issue-2401", {:failed_log_unavailable, "987", :log_not_ready}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:fetch_failed_log, "987"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "rerun_requested", ci_retry_count: 0, dispatched_shas: [], error: "{:failed_log_unavailable, \"987\", :log_not_ready}"}] =
             RunStore.list_ci_checks()
  end

  test "failed persistence prevents dispatch transition and ci notification" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    Application.put_env(:symphony_elixir, :ci_test_ci_record, %{
      repo_key: @repo_key,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_url: issue.url,
      pr_url: List.first(issue.pr_urls),
      workspace_path: "/tmp/workspaces/ACME-2401",
      status: "rerun_requested",
      ci_retry_count: 0,
      rerun_attempted_shas: ["abc123"],
      dispatched_shas: [],
      updated_at: now
    })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:update_error, "issue-2401", {:update_ci_check_failed, :write_failed}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, run_store: FailingUpdateRunStore, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}
    refute_receive {:notification_event, %{event: "ci_failed"}}
  end

  test "max retries escalates instead of dispatching again" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["def456"],
               dispatched_shas: ["abc123"],
               updated_at: now
             })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:escalated, "issue-2401", "In Review"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    assert_receive {:notification_event, %{event: "ci_escalated", state: "In Review", metadata: %{max_retries: 1, escalation_state: "In Review"}}}

    assert [%{status: "escalated", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "escalation persists pending transition before final ci update" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["def456"],
               dispatched_shas: ["abc123"],
               updated_at: now
             })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:update_error, "issue-2401", {:update_ci_check_failed, :write_failed}}]}} =
             CiPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               run_store: FailingEscalationFinalUpdateRunStore,
               now: DateTime.add(now, 1, :minute)
             )

    assert_receive {:ci_failure_at_transition, "issue-2401", %{commit_sha: "def456", log_excerpt: log_excerpt}}
    assert is_binary(log_excerpt) and log_excerpt != ""
    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    refute_receive {:notification_event, %{event: "ci_escalated"}}

    assert [
             %{
               status: "escalate_transition_pending",
               target_issue_state: "In Review",
               ci_failure: %{commit_sha: "def456"},
               last_action: nil,
               last_action_at: nil
             }
           ] = RunStore.list_ci_checks()
  end

  test "green ci resets retry state without Linear label writes" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               rerun_run_id: "987",
               rerun_run_ids: ["987"],
               updated_at: now
             })

    assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert [
             %{
               status: "green",
               ci_retry_count: 0,
               dispatched_shas: [],
               rerun_attempted_shas: [],
               rerun_run_id: nil,
               rerun_run_ids: [],
               ci_failure: nil
             }
           ] = RunStore.list_ci_checks()
  end

  test "green ci releases failure ownership but defers finalize while rework run is active" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
    put_run(issue, now, "running")

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               updated_at: now
             })

    assert {:ok, %{actions: [{:green_deferred, "issue-2401", :rework_in_progress}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}

    # Green CI no longer "owns" the issue: the failure-derived owned status and
    # retry count are cleared so ci_owned_issue?/2 stops blocking the rework,
    # even though we still defer finalizing to green until the rework lands.
    assert [
             %{
               status: "watching",
               ci_retry_count: 0,
               last_action: "green_deferred",
               last_observed_conclusion: "SUCCESS"
             }
           ] = RunStore.list_ci_checks()

    refute CiPoller.ci_owned_issue?(issue.id, repo_key: @repo_key)
  end

  test "green ci poll prefetches runs and reviews once per cycle across checks" do
    now = ~U[2026-05-06 09:00:00Z]
    issue_a = in_review_issue()

    issue_b = %{
      issue_a
      | id: "issue-2402",
        identifier: "ACME-2402",
        url: "https://linear.test/ACME-2402",
        pr_urls: ["https://github.com/example/repo/pull/2402"]
    }

    Application.put_env(:symphony_elixir, :ci_test_issues, [issue_a, issue_b])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
    Application.put_env(:symphony_elixir, :ci_test_store_counts, %{})
    on_exit(fn -> Application.delete_env(:symphony_elixir, :ci_test_store_counts) end)

    put_run(issue_a, now, "running")

    RunStore.put_run(%{
      repo_key: @repo_key,
      run_id: "run-2",
      issue_id: issue_b.id,
      issue_identifier: issue_b.identifier,
      status: "running",
      workspace_path: "/tmp/workspaces/ACME-2402",
      worker_host: nil,
      started_at: DateTime.add(now, -2, :minute),
      ended_at: nil
    })

    for issue <- [issue_a, issue_b] do
      assert :ok =
               RunStore.put_ci_check(%{
                 repo_key: @repo_key,
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 issue_url: issue.url,
                 pr_url: List.first(issue.pr_urls),
                 workspace_path: "/tmp/workspaces/#{issue.identifier}",
                 status: "dispatch_requested",
                 ci_retry_count: 2,
                 dispatched_shas: ["abc123"],
                 rerun_attempted_shas: ["abc123"],
                 updated_at: now
               })
    end

    assert {:ok, %{processed: 2, actions: actions}} =
             CiPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               run_store: CountingRunStore,
               now: DateTime.add(now, 1, :minute)
             )

    assert Enum.all?(actions, &match?({:green_deferred, _, :rework_in_progress}, &1))

    # One list_runs for discovery plus one prefetch, and a single
    # list_pr_reviews prefetch — independent of the number of CI checks.
    assert %{list_runs: 2, list_pr_reviews: 1} =
             Application.fetch_env!(:symphony_elixir, :ci_test_store_counts)
  end

  test "green ci defers while PR rework comments are pending then resets after completion" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               updated_at: now
             })

    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rework_transition_pending",
               pending_reviewer_comments: [%{id: "comment-1", body: "Please adjust."}],
               updated_at: now
             })

    assert {:ok, %{actions: [{:green_deferred, "issue-2401", :rework_in_progress}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    # Deferring finalize must not leave the record CI-owned; otherwise the
    # PR-review poller can never dispatch the rework that clears these pending
    # comments, deadlocking both pollers.
    assert [%{status: "watching", ci_retry_count: 0, last_action: "green_deferred"}] =
             RunStore.list_ci_checks()

    refute CiPoller.ci_owned_issue?(issue.id, repo_key: @repo_key)

    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rework_requested",
               pending_reviewer_comments: [],
               updated_at: DateTime.add(now, 2, :minute)
             })

    assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 3, :minute))

    assert [
             %{
               status: "green",
               ci_retry_count: 0,
               dispatched_shas: [],
               rerun_attempted_shas: [],
               last_action: "green"
             }
           ] = RunStore.list_ci_checks()
  end

  test "Linear transition errors use CI poll backoff" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               consecutive_errors: 2,
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    poll_time = DateTime.add(now, 1, :minute)

    assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :dispatch, :linear_unavailable}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: poll_time
             )

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}

    assert [%{status: "state_transition_error", consecutive_errors: 3, next_poll_at: next_poll_at}] =
             RunStore.list_ci_checks()

    assert DateTime.diff(next_poll_at, poll_time, :millisecond) == 1_000

    assert {:ok, %{actions: [{:backing_off, "issue-2401", ^next_poll_at}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: DateTime.add(poll_time, 999, :millisecond)
             )
  end

  test "pr review poller yields rework ownership while ci owns the issue" do
    now = ~U[2026-05-06 09:00:00Z]

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: "issue-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               updated_at: now
             })

    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: @repo_key,
               issue_id: "issue-2401",
               issue_identifier: "ACME-2401",
               pr_url: "https://github.com/example/repo/pull/2401",
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "watching",
               updated_at: now
             })

    Application.put_env(:symphony_elixir, :ci_test_review_activity, %{
      pr_url: "https://github.com/example/repo/pull/2401",
      state: "OPEN",
      review_decision: "CHANGES_REQUESTED",
      latest_activity_at: DateTime.add(now, -31, :minute),
      latest_review_activity_at: DateTime.add(now, -31, :minute),
      comments: [
        %{
          id: "reviewer-review",
          kind: "review",
          state: "CHANGES_REQUESTED",
          author: "human-reviewer",
          body: "Please address.",
          url: "https://github.com/example/repo/pull/2401#pullrequestreview-1",
          created_at: DateTime.add(now, -31, :minute),
          updated_at: DateTime.add(now, -31, :minute)
        }
      ]
    })

    assert {:ok, %{actions: [{:ci_owned, "issue-2401", :rework}]}} =
             SymphonyElixir.PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: ReviewGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}
  end

  test "log truncation starts at the first error inside the retained window" do
    log = Enum.map_join(1..5, "\n", &"line #{&1}") <> "\nwarning\nERROR: broken\nstack\nlast"

    assert CiPoller.log_excerpt_for_test(log, 5) == "ERROR: broken\nstack\nlast"
  end

  test "log truncation replaces invalid utf-8 bytes instead of raising" do
    log = <<"ERROR: broken\n", 0xFF, 0xFE, "\nlast">>

    assert CiPoller.log_excerpt_for_test(log, 5) == "ERROR: broken\n??\nlast"
  end

  test "Linear transition failure clears dispatch marker so the SHA can be redispatched" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    poll_time = DateTime.add(now, 1, :minute)

    assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :dispatch, :linear_unavailable}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: poll_time
             )

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}

    assert [
             %{
               status: "state_transition_error",
               ci_retry_count: 0,
               dispatched_shas: [],
               ci_failure: %{commit_sha: "abc123"},
               log_excerpt: log_excerpt
             }
           ] = RunStore.list_ci_checks()

    assert is_binary(log_excerpt) and log_excerpt != ""

    # A subsequent poll past the backoff window should re-dispatch the same SHA
    # because the previous Linear transition never landed.
    later = DateTime.add(poll_time, 2, :minute)

    assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: later
             )

    assert_receive {:ci_failure_at_transition, "issue-2401", %{commit_sha: "abc123"}}
    assert_receive {:issue_state_update, "issue-2401", "In Progress"}

    assert [%{status: "dispatch_requested", ci_retry_count: 1, dispatched_shas: ["abc123"]}] =
             RunStore.list_ci_checks()
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

  test "new head SHA clears dispatched/rerun history and downgrades escalated status" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "escalated",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               rerun_run_id: "old-run",
               rerun_run_ids: ["old-run"],
               last_observed_sha: "abc123",
               updated_at: now
             })

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:rerun_failed, "987"}

    assert [
             %{
               status: "rerun_requested",
               ci_retry_count: 2,
               dispatched_shas: [],
               rerun_attempted_shas: ["def456"],
               rerun_run_ids: ["987"],
               last_observed_sha: "def456"
             }
           ] = RunStore.list_ci_checks()
  end

  test "new head SHA downgrades pending escalation and clears rerun run ids" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "escalate_transition_pending",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               rerun_run_id: "old-run",
               rerun_run_ids: ["old-run"],
               last_observed_sha: "abc123",
               updated_at: now
             })

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:rerun_failed, "987"}

    assert [
             %{
               status: "rerun_requested",
               dispatched_shas: [],
               rerun_attempted_shas: ["def456"],
               rerun_run_ids: ["987"],
               last_observed_sha: "def456"
             }
           ] = RunStore.list_ci_checks()
  end

  test "dispatched SHA escalates after max retries once no agent is running" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: ["abc123"],
               last_observed_sha: "abc123",
               updated_at: now
             })

    assert {:ok, %{actions: [{:escalated, "issue-2401", "In Review"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    assert [%{status: "escalated", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "dispatched SHA is protected from escalation while an agent is running" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    put_run(issue, now, "running")

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: ["abc123"],
               last_observed_sha: "abc123",
               updated_at: now
             })

    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "failure_already_handled", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "freshly dispatched SHA is protected from escalation until the start-grace window lapses" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    # No running agent yet: the orchestrator has not picked up the In Progress
    # issue, so the rework run is not "running" in the dispatch->running gap.
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: ["abc123"],
               last_observed_sha: "abc123",
               last_action: "dispatch",
               last_action_at: now,
               updated_at: now
             })

    # Within the grace window the just-dispatched agent must not be escalated.
    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "failure_already_handled", ci_retry_count: 1}] = RunStore.list_ci_checks()

    # Past the grace window with still no running agent, escalation proceeds.
    assert {:ok, %{actions: [{:escalated, "issue-2401", "In Review"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 3, :minute))

    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    assert [%{status: "escalated", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "escalated status survives a transient poll error" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "escalated",
               ci_retry_count: 3,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               last_observed_sha: "abc123",
               updated_at: now
             })

    assert {:ok, %{actions: [{:poll_error, "issue-2401", :rate_limited}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FailingGitHub, now: DateTime.add(now, 1, :minute))

    assert [%{status: "escalated", ci_retry_count: 3, error: ":rate_limited"}] = RunStore.list_ci_checks()
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

    test "a signed red check_suite takes the CI-failure path once, and the next poll does not dispatch again", %{name: name} do
      issue = %{in_review_issue() | state: "Merging"}
      Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
      Application.put_env(:symphony_elixir, :ci_test_statuses, [pending_status()])
      Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
      put_run(issue, DateTime.utc_now())
      start_webhook_poller(name, on_webhook_result: fn -> :ok end)

      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> CiPoller.observed_head("issue-2401") != nil end)

      deliver_webhook("check_suite", check_suite_completed("abc123"), 202)

      assert_receive {:issue_state_update, "issue-2401", "In Progress"}, 5_000

      send(name, :poll)
      assert_receive {:fetch_ci_status, _pr_url}, 5_000
      assert_eventually(fn -> match?(%{webhooks: %{results_via_poll: 0}}, CiPoller.status()) end)
      :sys.get_state(name)

      refute_receive {:issue_state_update, "issue-2401", _state}, 200
      assert [%{status: "failure_already_handled", dispatched_shas: ["abc123"], ci_retry_count: 1}] = RunStore.list_ci_checks()
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

    test "a webhook poll that fails is logged and the poller keeps running", %{name: name} do
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
      state: "In Review",
      url: "https://linear.test/ACME-2401",
      pr_urls: ["https://github.com/example/repo/pull/2401"],
      labels: []
    }
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

  defp run_ended_at("running", _now), do: nil
  defp run_ended_at(_status, now), do: DateTime.add(now, -1, :minute)

  defp multi_repo_config do
    [
      %{key: @repo_key, workflow: Workflow.workflow_file_path(), default: true, team: "Test"},
      %{key: "secondary", workflow: Workflow.workflow_file_path(), team: "PIN4WOO", labels: ["Bug"]}
    ]
  end

  defp conflicting_status do
    %{
      green_status()
      | checks: []
    }
    |> Map.merge(%{mergeable: "CONFLICTING", merge_state_status: "DIRTY", base_ref_name: "develop"})
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

  defp multi_failed_status(sha) do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      head_ref_name: "feature/fix-ci",
      is_cross_repository: false,
      head_repository: %{"nameWithOwner" => "example/repo"},
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"},
        %{name: "lint", status: "COMPLETED", conclusion: "FAILURE", run_id: "654"},
        %{name: "specs retry", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"}
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
