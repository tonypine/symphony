defmodule SymphonyElixir.PrReviewPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Notifications.Event
  alias SymphonyElixir.PrReviewPoller

  @repo_key "default"

  defmodule FakeTracker do
    alias SymphonyElixir.Linear.Issue

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states) do
      {:ok, Application.get_env(:symphony_elixir, :pr_review_test_issues, [])}
    end

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)

      issues =
        :symphony_elixir
        |> Application.get_env(:pr_review_test_issues, [])
        |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted, id) end)

      {:ok, issues}
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name) do
      if take_failure(:pr_review_test_state_update_failures, issue_id) do
        {:error, :linear_unavailable}
      else
        recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
        maybe_send_pending_context_at_transition(recipient, issue_id)
        send(recipient, {:issue_state_update, issue_id, state_name})
        :ok
      end
    end

    defp maybe_send_pending_context_at_transition(recipient, issue_id) do
      if Application.get_env(:symphony_elixir, :pr_review_test_capture_pending_at_transition, false) do
        comments = SymphonyElixir.PrReviewPoller.pending_reviewer_comments(issue_id)
        conflict = SymphonyElixir.PrReviewPoller.pending_pr_conflict(issue_id)

        send(recipient, {:pending_reviewer_comments_at_transition, issue_id, comments})
        send(recipient, {:pending_pr_conflict_at_transition, issue_id, conflict})
      end
    end

    defp take_failure(key, value) do
      failures = Application.get_env(:symphony_elixir, key, [])

      if value in failures do
        Application.put_env(:symphony_elixir, key, List.delete(failures, value))
        true
      else
        false
      end
    end
  end

  defmodule IssueReadFailingTracker do
    alias SymphonyElixir.Linear.Issue

    # The issue sits outside the watched states (`Backlog`), so the poller reads it by id.
    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states), do: {:ok, []}

    @spec fetch_issue_states_by_ids([String.t()]) :: {:error, term()}
    def fetch_issue_states_by_ids(_issue_ids), do: {:error, :linear_unavailable}

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name), do: FakeTracker.update_issue_state(issue_id, state_name)
  end

  defmodule FakeGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :pr_review_test_activity)}
    end
  end

  defmodule FakeLearningProvider do
    @spec review(map(), map()) :: {:ok, String.t()}
    def review(request, settings) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:learning_reflection, request, settings})

      {:ok, Application.get_env(:symphony_elixir, :learning_test_response, ~s({"learnings":[]}))}
    end
  end

  defmodule CrashingLearningProvider do
    @spec review(map(), map()) :: no_return()
    def review(request, settings) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:learning_reflection, request, settings})

      raise "learning provider crashed"
    end
  end

  defmodule FailingGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:error, term()}
    def fetch_activity(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_fetch, pr_url})

      {:error, Application.get_env(:symphony_elixir, :pr_review_test_github_error, :rate_limited)}
    end
  end

  defmodule ActionGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :pr_review_test_activity)}
    end

    @spec reply_to_comment(String.t(), map(), String.t(), keyword()) :: :ok
    def reply_to_comment(pr_url, comment, body, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_reply, pr_url, comment, body})
      :ok
    end

    @spec request_review(String.t(), [String.t()], keyword()) :: :ok
    def request_review(pr_url, reviewers, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_request_review, pr_url, reviewers})
      :ok
    end
  end

  defmodule FailingActionGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :pr_review_test_activity)}
    end

    @spec reply_to_comment(String.t(), map(), String.t(), keyword()) :: :ok
    def reply_to_comment(pr_url, comment, body, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_reply, pr_url, comment, body})
      :ok
    end

    @spec request_review(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
    def request_review(pr_url, reviewers, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)

      if take_request_review_failure() do
        send(recipient, {:github_request_review_failed, pr_url, reviewers})
        {:error, :gh_transient}
      else
        send(recipient, {:github_request_review, pr_url, reviewers})
        :ok
      end
    end

    defp take_request_review_failure do
      case Application.get_env(:symphony_elixir, :pr_review_test_request_review_failures, 0) do
        count when is_integer(count) and count > 0 ->
          Application.put_env(:symphony_elixir, :pr_review_test_request_review_failures, count - 1)
          true

        _count ->
          false
      end
    end
  end

  defmodule PartialFailReplyGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :pr_review_test_activity)}
    end

    @spec reply_to_comment(String.t(), map(), String.t(), keyword()) :: :ok | {:error, term()}
    def reply_to_comment(pr_url, comment, body, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      comment_id = Map.get(comment, :id)

      if comment_id in Application.get_env(:symphony_elixir, :pr_review_test_reply_failures, []) do
        send(recipient, {:github_reply_failed, pr_url, comment})
        {:error, :gh_transient}
      else
        send(recipient, {:github_reply, pr_url, comment, body})
        :ok
      end
    end

    @spec request_review(String.t(), [String.t()], keyword()) :: :ok
    def request_review(pr_url, reviewers, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_request_review, pr_url, reviewers})
      :ok
    end
  end

  defmodule FailingListRunStore do
    @spec list_pr_reviews() :: {:error, term()}
    def list_pr_reviews, do: {:error, :disk_full}

    @spec update_pr_review(String.t(), map()) :: :ok
    def update_pr_review(issue_id, attrs) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:update_review, issue_id, attrs})
      :ok
    end
  end

  defmodule RaisingRunStore do
    @spec list_pr_reviews() :: no_return()
    def list_pr_reviews, do: raise("poll exploded")
  end

  defmodule StatefulRunStore do
    @spec list_issue_runs(String.t(), String.t()) :: [map()]
    def list_issue_runs(_repo_key, issue_id) do
      :symphony_elixir
      |> Application.get_env(:pr_review_test_runs, [])
      |> Enum.filter(&(&1.issue_id == issue_id))
    end

    @spec list_pr_reviews() :: [map()]
    def list_pr_reviews do
      :symphony_elixir
      |> Application.get_env(:pr_review_test_review_records, %{})
      |> Map.values()
    end

    @spec put_pr_review(map()) :: :ok | {:error, term()}
    def put_pr_review(%{issue_id: issue_id} = record) do
      if take_failure(:pr_review_test_put_failures, issue_id) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})
        Application.put_env(:symphony_elixir, :pr_review_test_review_records, Map.put(records, issue_id, record))
        recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
        send(recipient, {:put_review, issue_id})
        :ok
      end
    end

    @spec update_pr_review(String.t(), map()) :: :ok | {:error, term()}
    def update_pr_review(issue_id, attrs) do
      if take_failure(:pr_review_test_update_status_failures, Map.get(attrs, :status)) or take_attr_failure(attrs) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})

        case Map.fetch(records, issue_id) do
          {:ok, record} ->
            Application.put_env(
              :symphony_elixir,
              :pr_review_test_review_records,
              Map.put(records, issue_id, Map.merge(record, attrs))
            )

            recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
            send(recipient, {:update_review, issue_id, attrs})
            :ok

          :error ->
            {:error, :pr_review_not_found}
        end
      end
    end

    defp take_attr_failure(attrs) do
      failures = Application.get_env(:symphony_elixir, :pr_review_test_update_attr_failures, [])

      case Enum.find(failures, &Map.has_key?(attrs, &1)) do
        nil ->
          false

        attr ->
          Application.put_env(:symphony_elixir, :pr_review_test_update_attr_failures, List.delete(failures, attr))
          true
      end
    end

    @spec delete_pr_review(String.t()) :: :ok | {:error, term()}
    def delete_pr_review(issue_id) do
      if take_failure(:pr_review_test_delete_failures, issue_id) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})
        Application.put_env(:symphony_elixir, :pr_review_test_review_records, Map.delete(records, issue_id))
        :ok
      end
    end

    @spec get_paused() :: map()
    def get_paused do
      Application.get_env(:symphony_elixir, :pr_review_test_pause, %{paused: false, reason: nil, paused_at: nil})
    end

    defp take_failure(key, value) do
      failures = Application.get_env(:symphony_elixir, key, [])

      if value in failures do
        Application.put_env(:symphony_elixir, key, List.delete(failures, value))
        true
      else
        false
      end
    end
  end

  defmodule FakeWorkspace do
    @spec remove(String.t(), String.t() | nil) :: {:ok, [String.t()]}
    def remove(workspace_path, worker_host) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:remove_workspace, workspace_path, worker_host})

      {:ok, [workspace_path]}
    end
  end

  defmodule FailingWorkspace do
    @spec remove(String.t(), String.t() | nil) :: {:error, atom(), String.t()}
    def remove(workspace_path, worker_host) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:remove_workspace, workspace_path, worker_host})

      {:error, :branch_checked_out, "error: cannot delete branch 'auto/ACME-1780' checked out at '/tmp/peer-worktree'"}
    end
  end

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-pr-review-poller-audit-#{System.unique_integer([:positive])}"
      )

    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_review_test_issues)
      Application.delete_env(:symphony_elixir, :pr_review_test_activity)
      Application.delete_env(:symphony_elixir, :pr_review_test_recipient)
      Application.delete_env(:symphony_elixir, :pr_review_test_runs)
      Application.delete_env(:symphony_elixir, :pr_review_test_review_records)
      Application.delete_env(:symphony_elixir, :pr_review_test_put_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_update_status_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_update_attr_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_state_update_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_capture_pending_at_transition)
      Application.delete_env(:symphony_elixir, :pr_review_test_delete_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_github_error)
      Application.delete_env(:symphony_elixir, :pr_review_test_pause)
      Application.delete_env(:symphony_elixir, :pr_review_test_request_review_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_reply_failures)
      Application.delete_env(:symphony_elixir, :learning_test_response)

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
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_recipient, self())
    {:ok, audit_dir: audit_root}
  end

  test "discovers in-review PRs and persists workspace tracking metadata" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-1",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/ACME-1780",
               worker_host: nil,
               started_at: DateTime.add(now, -120, :second),
               ended_at: DateTime.add(now, -60, :second)
             })

    assert {:ok, %{discovered: 1, processed: 1}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [
             %{
               issue_id: "issue-1780",
               issue_identifier: "ACME-1780",
               pr_url: "https://github.com/example/repo/pull/1780",
               workspace_path: "/tmp/workspaces/ACME-1780",
               status: "watching"
             }
           ] = RunStore.list_pr_reviews()
  end

  test "a poll's run-store cost doesn't grow with the store" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    activity = open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "head-sha", base_ref_oid: "base-sha")
    Application.put_env(:symphony_elixir, :pr_review_test_activity, activity)

    for {run_id, status, minutes} <- [{"run-1", "success", -10}, {"run-2", "running", -1}] do
      run = %{repo_key: @repo_key, run_id: run_id, issue_id: issue.id, status: status, workspace_path: "/tmp/workspaces/ACME-1780"}
      assert :ok = RunStore.put_run(Map.put(run, :started_at, DateTime.add(now, minutes, :minute)))
    end

    poll = fn ->
      assert {:ok, %{actions: [{:active_run, "issue-1780", :conflict}]}} =
               PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
    end

    small = reductions(poll)

    for n <- 1..2_000 do
      run = %{repo_key: @repo_key, run_id: "other-#{n}", issue_id: "other-#{n}", status: "success", workspace_path: "/tmp/other"}
      assert :ok = RunStore.put_run(Map.put(run, :started_at, DateTime.add(now, -n, :hour)))
    end

    large = reductions(poll)

    assert large < small * 1.5, "a PR review poll took #{large} reductions over 2002 runs, #{small} over 2"
  end

  test "each repository keeps only the states it watches from the shared read" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_auto_merge: false,
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      repos: multi_repo_config()
    )

    # Auto-merge is off, so no repository watches Merging, yet the shared read returns an issue in it.
    issue = %{
      in_review_issue(id: "issue-pin-85", identifier: "PIN4WOO-85", pr_url: "https://github.com/example/repo/pull/85", updated_at: now)
      | state: "Merging"
    }

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    assert :ok = RunStore.put_run(Map.put(review_run(issue, "/tmp/workspaces/PIN4WOO-85", now), :repo_key, "secondary"))

    assert {:ok, %{discovered: 0, processed: 0}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [] = RunStore.list_pr_reviews("secondary")
  end

  test "polls review lifecycle records for non-default repos" do
    now = ~U[2026-05-01 09:00:00Z]
    comment_at = DateTime.add(now, -45, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      repos: multi_repo_config()
    )

    issue =
      in_review_issue(
        id: "issue-pin-84",
        identifier: "PIN4WOO-84",
        pr_url: "https://github.com/woocommerce/pinterest-for-woocommerce/pull/1185",
        updated_at: now
      )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(comment_at,
        pr_number: 1185,
        pr_title: "Fix catalog sync",
        comments: [
          %{
            id: "comment-pin-1",
            kind: "inline_comment",
            author: "reviewer",
            body: "Please handle this edge case.",
            path: "lib/sync.ex",
            line: 42,
            created_at: comment_at,
            updated_at: comment_at
          }
        ]
      )
    )

    assert :ok =
             RunStore.put_run(
               Map.merge(review_run(issue, "/tmp/workspaces/PIN4WOO-84", now), %{
                 repo_key: "secondary"
               })
             )

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:state_transitioned, "issue-pin-84", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:issue_state_update, "issue-pin-84", "In Progress"}
    assert [] = RunStore.list_pr_reviews(@repo_key)

    assert [
             %{
               repo_key: "secondary",
               issue_id: "issue-pin-84",
               status: "rework_requested",
               pending_reviewer_comments: [%{id: "comment-pin-1"}]
             }
           ] = RunStore.list_pr_reviews("secondary")

    assert [%{id: "comment-pin-1"}] = PrReviewPoller.pending_reviewer_comments("issue-pin-84")
  end

  test "polling ignores malicious Linear GitHub attachments before GitHub fetch" do
    now = ~U[2026-05-01 09:00:00Z]

    issue =
      Client.normalize_issue_for_test(%{
        "id" => "issue-malicious",
        "identifier" => "ACME-MAL",
        "title" => "Malicious attachment",
        "state" => %{"name" => "In Review"},
        "url" => "https://linear.app/example/issue/ACME-MAL",
        "attachments" => %{
          "nodes" => [
            %{
              "sourceType" => "github",
              "url" => "https://github-evil.attacker.tld/org/repo/pull/42"
            }
          ]
        },
        "updatedAt" => "2026-05-01T09:00:00Z"
      })

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-malicious",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/ACME-MAL",
               worker_host: nil,
               started_at: DateTime.add(now, -120, :second),
               ended_at: DateTime.add(now, -60, :second)
             })

    assert {:ok, %{discovered: 0, processed: 0, actions: []}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FailingGitHub, now: now)

    assert RunStore.list_pr_reviews() == []
    refute_receive {:github_fetch, _pr_url}
  end

  test "discovers workspace from newest completed run regardless of store order" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))

    Application.put_env(:symphony_elixir, :pr_review_test_runs, [
      review_run(issue, "/tmp/workspaces/old", DateTime.add(now, -2, :hour)),
      review_run(issue, "/tmp/workspaces/new", DateTime.add(now, -5, :minute)),
      review_run(issue, "/tmp/workspaces/running", now, %{status: "running"})
    ])

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert [%{workspace_path: "/tmp/workspaces/new"}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "waits for cooldown before moving a rework issue back to an active state" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -10, :minute)
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [
          %{
            kind: "inline_comment",
            author: "reviewer",
            body: "Please split this.",
            url: "https://github.com/example/repo/pull/1780#discussion_r1",
            created_at: latest_review_at,
            updated_at: latest_review_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:cooling_down, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}

    latest_review_at = DateTime.add(now, -31, :minute)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [
          %{
            kind: "inline_comment",
            author: "reviewer",
            body: "Please split this.",
            url: "https://github.com/example/repo/pull/1780#discussion_r1",
            created_at: latest_review_at,
            updated_at: latest_review_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "rework_requested", target_issue_state: "In Progress", last_action: "rework"}] =
             RunStore.list_pr_reviews()
  end

  test "plain non-bot reviewer comments trigger rework after cooldown and are stored for the prompt" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_capture_pending_at_transition, true)
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        head_ref_name: "auto/ACME-1780",
        head_ref_oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:pending_reviewer_comments_at_transition, "issue-1780", [%{id: "comment-1", author: "human-reviewer", body: "Please refactor this before merge."}]}

    assert_receive {:pending_pr_conflict_at_transition, "issue-1780", nil}
    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "rework_requested",
               pending_reviewer_comments_reviewed_head_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               pending_last_addressed_comment_id: "comment-1",
               pending_reviewer_comments: [
                 %{id: "comment-1", author: "human-reviewer", body: "Please refactor this before merge."}
               ]
             } = record
           ] = RunStore.list_pr_reviews()

    refute Map.has_key?(record, :last_addressed_comment_id)
    assert PrReviewPoller.pending_pr_head_ref("issue-1780") == "auto/ACME-1780"
  end

  test "discovers a Human Review issue's PR like an In Review one, unless human_review is null" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = %{in_review_issue(updated_at: now) | state: "Human Review"}
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))

    assert :ok =
             RunStore.put_run(%{
               repo_key: @repo_key,
               run_id: "run-1",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/ACME-1780",
               worker_host: nil,
               started_at: DateTime.add(now, -120, :second),
               ended_at: DateTime.add(now, -60, :second)
             })

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_human_review_state: nil,
      pr_review_mode: "polling",
      pr_review_auto_merge: false,
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    assert {:ok, %{discovered: 0}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_auto_merge: false,
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    assert {:ok, %{discovered: 1}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [%{issue_id: "issue-1780", status: "watching"}] = RunStore.list_pr_reviews()
  end

  test "cross-repo reviewer comments remain watching and do not expose a PR head ref" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        is_cross_repository: true,
        head_ref_name: "contributor/fork-fix",
        head_ref_oid: "fork-head-sha",
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}

    assert [
             %{
               status: "watching",
               is_cross_repository: true,
               head_ref_name: "contributor/fork-fix",
               pending_reviewer_comments_reviewed_head_sha: "fork-head-sha",
               pending_last_addressed_comment_id: "comment-1",
               pending_reviewer_comments: [
                 %{id: "comment-1", author: "human-reviewer", body: "Please refactor this before merge."}
               ]
             }
           ] = RunStore.list_pr_reviews()

    assert PrReviewPoller.pending_pr_head_ref("issue-1780") == nil
  end

  test "emits reviewer_commented once when actionable reviewer comments trigger rework" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert :ok = SymphonyElixir.Notifications.subscribe()

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:notification_event,
                    %Event{
                      event: "reviewer_commented",
                      issue_id: "issue-1780",
                      issue_identifier: "ACME-1780",
                      issue_title: "Review manager",
                      issue_url: "https://linear.app/example/issue/ACME-1780",
                      pr_url: "https://github.com/example/repo/pull/1780",
                      state: "In Progress",
                      reason: "1 actionable reviewer comment discovered",
                      timestamp: ^now,
                      metadata: %{
                        source: "pr_review_poller",
                        comment_count: 1,
                        latest_comment_id: "comment-1"
                      }
                    }},
                   500

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: DateTime.add(now, 1, :minute)
             )

    refute_receive {:notification_event, %Event{event: "reviewer_commented"}}, 50
  end

  test "backfills legacy issue title before reviewer_commented notification" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      now
      |> review_record()
      |> Map.delete(:issue_title)
      |> RunStore.put_pr_review()

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert :ok = SymphonyElixir.Notifications.subscribe()

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:notification_event,
                    %Event{
                      event: "reviewer_commented",
                      issue_title: "Review manager"
                    }},
                   500

    assert [%{issue_title: "Review manager"}] = RunStore.list_pr_reviews()
  end

  test "plain reviewer comments still respect cooldown" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -10, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:cooling_down, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "cooling_down", pending_last_addressed_comment_id: "comment-1"}] = RunStore.list_pr_reviews()
  end

  test "configured ignored users do not trigger comment rework" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["symphony-bot", "agent-user"]
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{id: "bot-comment", kind: "comment", author: "symphony-bot", body: "Automated status.", created_at: latest_comment_at},
          %{id: "configured-comment", kind: "comment", author: "agent-user", body: "Operator follow-up.", created_at: latest_comment_at}
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: nil,
               now: now
             )

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "watching"} = record] = RunStore.list_pr_reviews()
    refute Map.has_key?(record, :pending_last_addressed_comment_id)
  end

  test "a PR whose only comment is the Linear linkback stays in review" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)
    linkback = "<!-- linear-linkback -->\n<details><summary>TP-5 The search is spread out</summary></details>"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["github-actions[bot]"]
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    for comments <- [
          [%{id: "linear-linkback", kind: "comment", author: "linear-code", body: linkback, created_at: latest_comment_at}],
          [%{id: "linear-rest", kind: "comment", author: "linear[bot]", body: "Linked to TP-5.", created_at: latest_comment_at}],
          # The marker is enough, whoever posted it: here the PR author's account.
          [%{id: "linkback-as-author", kind: "comment", author: "pr-author", body: "  " <> linkback, created_at: latest_comment_at}]
        ] do
      Application.put_env(
        :symphony_elixir,
        :pr_review_test_activity,
        open_activity(latest_comment_at, pr_author: "pr-author", comments: comments)
      )

      assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
               PrReviewPoller.poll_once(
                 tracker: FakeTracker,
                 github: FakeGitHub,
                 current_gh_user: nil,
                 now: now
               )

      refute_receive {:issue_state_update, _, _}
      assert [%{status: "watching"} = record] = RunStore.list_pr_reviews()
      refute Map.has_key?(record, :pending_last_addressed_comment_id)
      assert PrReviewPoller.pending_reviewer_comments("issue-1780") == []
    end
  end

  test "a human review comment next to the Linear linkback still triggers comment rework" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "linear-linkback",
            kind: "comment",
            author: "linear-code",
            body: "<!-- linear-linkback -->\n<details><summary>TP-5</summary></details>",
            created_at: DateTime.add(latest_comment_at, -5, :minute)
          },
          %{id: "human-comment", kind: "inline_comment", author: "reviewer", body: "Rename this helper.", created_at: latest_comment_at}
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: nil,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
    assert [%{id: "human-comment", author: "reviewer"}] = pending = PrReviewPoller.pending_reviewer_comments("issue-1780")
    assert SymphonyElixir.RunKind.classify(%Issue{id: "issue-1780", state: "In Progress"}, reviewer_comments: pending) == :review_feedback

    assert PrReviewPoller.trigger_comment_log_fields("issue-1780") ==
             ~s(trigger_comment_id=human-comment trigger_comment_author=reviewer trigger_comment="Rename this helper." pending_comments=1)
  end

  test "the trigger comment log fields fall back when nothing is pending" do
    assert PrReviewPoller.trigger_comment_log_fields("issue-without-review") == "trigger_comment=none"
  end

  test "PR author comments posted by Symphony or without text do not trigger comment rework" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        pr_author: "pr-author",
        comments: [
          %{id: "marked-comment", kind: "inline_comment", author: "pr-author", body: "Fixed in abc123.\n\n<!-- symphony:agent -->", created_at: latest_comment_at},
          %{id: "legacy-reply", kind: "comment", author: "pr-author", body: "Symphony AI handled this in abc123.", created_at: latest_comment_at},
          %{id: "legacy-note", kind: "comment", author: "PR-Author", body: "Automated note from Symphony AI: done.", created_at: latest_comment_at},
          %{id: "reply-review", kind: "review", state: "COMMENTED", author: "pr-author", body: "", created_at: latest_comment_at}
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: nil,
               now: now
             )

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "watching", review_self_users: ["pr-author"]} = record] = RunStore.list_pr_reviews()
    refute Map.has_key?(record, :pending_last_addressed_comment_id)
  end

  test "operator inline review comments on their own agent PR trigger rework on the same PR" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        pr_author: "symphony-operator",
        comments: [
          %{
            id: "agent-reply",
            kind: "inline_comment",
            author: "symphony-operator",
            body: "Done.\n\n<!-- symphony:agent -->",
            created_at: DateTime.add(latest_comment_at, -5, :minute)
          },
          %{
            id: "operator-inline",
            kind: "inline_comment",
            author: "Symphony-Operator",
            body: "Rename this helper.",
            path: "lib/example.ex",
            line: 7,
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: "symphony-operator",
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{pending_reviewer_comments: [%{id: "operator-inline", path: "lib/example.ex"}], review_self_users: ["symphony-operator"]}] =
             RunStore.list_pr_reviews()
  end

  test "Symphony-marked current gh user comments do not trigger comment rework when detected" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        pr_author: "someone-else",
        comments: [
          %{id: "self-comment", kind: "comment", author: "symphony-operator", body: "Self follow-up.\n\n<!-- symphony:agent -->", created_at: latest_comment_at}
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: "symphony-operator",
               now: now
             )

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "watching"}] = RunStore.list_pr_reviews()
  end

  test "human reviewer comment still triggers rework after cooldown when PR author differs" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["symphony-bot"]
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        pr_author: "pr-author",
        comments: [
          %{id: "author-comment", kind: "comment", author: "pr-author", body: "Symphony AI handled this.", created_at: latest_comment_at},
          %{id: "bot-comment", kind: "comment", author: "symphony-bot", body: "Automated status.", created_at: latest_comment_at},
          %{
            id: "reviewer-comment",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this.",
            path: "lib/example.ex",
            line: 42,
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: "symphony-operator",
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{pending_reviewer_comments: [%{id: "reviewer-comment"}]}] = RunStore.list_pr_reviews()
  end

  test "last addressed comment cursor deduplicates comments across later polls" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this function.",
            path: "lib/example.ex",
            line: 42,
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", now: DateTime.add(now, 5, :minute))

    assert [%{last_addressed_comment_id: "comment-1", pending_reviewer_comments: []}] =
             RunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: DateTime.add(now, 10, :minute)
             )

    refute_receive {:issue_state_update, _, _}
  end

  test "deleting the cursor comment does not re-trigger rework for already-addressed comments" do
    now = ~U[2026-05-01 09:00:00Z]
    addressed_at = DateTime.add(now, -60, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    # Settled record: Symphony already addressed the reviewer comments, the cursor
    # advanced to the latest one (comment-2), and the per-cycle reply ledger was cleared.
    :ok =
      put_review(now, %{
        status: "watching",
        last_addressed_comment_id: "comment-2",
        last_addressed_comment_at: addressed_at
      })

    # The reviewer deletes the cursor comment (comment-2); only the older,
    # already-addressed comment-1 remains in the PR.
    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(addressed_at,
        comments: [
          %{
            id: "comment-1",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this function.",
            path: "lib/example.ex",
            line: 42,
            created_at: DateTime.add(addressed_at, -5, :minute),
            updated_at: DateTime.add(addressed_at, -5, :minute)
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: DateTime.add(now, 10, :minute)
             )

    refute_receive {:issue_state_update, _, _}
  end

  test "moves an approved issue back to an active state for orchestrator-owned merge handling" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "merge_requested", target_issue_state: "In Progress", last_action: "merge"}] =
             RunStore.list_pr_reviews()
  end

  test "moves an approved cross-repo issue to merge even when reviewer comments remain" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)
    issue = in_review_issue(updated_at: now)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        is_cross_repository: true,
        head_ref_name: "contributor/fork-fix",
        head_ref_oid: "fork-head-sha",
        review_decision: "APPROVED",
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    :ok = put_review(now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "merge_requested",
               target_issue_state: "In Progress",
               last_action: "merge",
               is_cross_repository: true,
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = RunStore.list_pr_reviews()

    assert PrReviewPoller.pending_pr_head_ref("issue-1780") == nil
  end

  test "dispatches merge conflicts with PR metadata for the next prompt" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_capture_pending_at_transition, true)
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        mergeable: "CONFLICTING",
        merge_state_status: "DIRTY",
        head_ref_name: "auto/ACME-1780",
        head_ref_oid: "head-sha",
        base_ref_name: "main",
        base_ref_oid: "base-sha"
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :conflict, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:pending_reviewer_comments_at_transition, "issue-1780", []}

    assert_receive {:pending_pr_conflict_at_transition, "issue-1780",
                    %{
                      head_ref: "auto/ACME-1780",
                      head_sha: "head-sha",
                      base_ref: "main",
                      base_sha: "base-sha",
                      conflict_key: "head-sha|base-sha"
                    }}

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "conflict_requested",
               last_action: "conflict",
               conflict_retry_count: 1,
               dispatched_conflict_keys: ["head-sha|base-sha"],
               conflict_context: %{
                 pr_url: "https://github.com/example/repo/pull/1780",
                 head_ref: "auto/ACME-1780",
                 head_sha: "head-sha",
                 base_ref: "main",
                 base_sha: "base-sha",
                 conflict_key: "head-sha|base-sha",
                 retry_count: 1,
                 max_retries: 3
               }
             }
           ] = RunStore.list_pr_reviews()

    # Found outside Merging, the conflict is not on an approved PR.
    assert %{
             head_ref: "auto/ACME-1780",
             head_sha: "head-sha",
             base_ref: "main",
             base_sha: "base-sha",
             conflict_key: "head-sha|base-sha",
             approved: false
           } = PrReviewPoller.pending_pr_conflict("issue-1780")
  end

  test "deduplicates repeated polls of the same merge conflict" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "conflict_requested",
        conflict_retry_count: 1,
        dispatched_conflict_keys: ["head-sha|base-sha"],
        last_conflict_key: "head-sha|base-sha",
        conflict_context: %{
          pr_url: "https://github.com/example/repo/pull/1780",
          head_ref: "auto/ACME-1780",
          head_sha: "head-sha",
          base_ref: "main",
          base_sha: "base-sha",
          conflict_key: "head-sha|base-sha",
          retry_count: 1,
          max_retries: 3
        }
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        mergeable: "CONFLICTING",
        head_ref_oid: "head-sha",
        base_ref_oid: "base-sha"
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}, 50
    assert [%{conflict_retry_count: 1, dispatched_conflict_keys: ["head-sha|base-sha"]}] = RunStore.list_pr_reviews()
    assert %{conflict_key: "head-sha|base-sha"} = PrReviewPoller.pending_pr_conflict("issue-1780")
  end

  test "escalates new merge conflicts after the retry limit" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        conflict_retry_count: 3,
        dispatched_conflict_keys: ["old-head|base-sha"]
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        mergeable: "CONFLICTING",
        head_ref_oid: "new-head",
        base_ref_oid: "base-sha"
      )
    )

    assert {:ok, %{actions: [{:conflict_escalated, "issue-1780", 3}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}, 50

    assert [
             %{
               status: "conflict_escalated",
               conflict_retry_count: 3,
               target_issue_state: "In Review",
               error: "merge conflict retry limit reached"
             }
           ] = RunStore.list_pr_reviews()
  end

  test "does not dispatch merge conflicts while an agent run is active" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_runs, [
      review_run(issue, "/tmp/workspaces/ACME-1780", now, %{status: "running"})
    ])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        mergeable: "CONFLICTING",
        head_ref_oid: "head-sha",
        base_ref_oid: "base-sha"
      )
    )

    assert {:ok, %{actions: [{:active_run, "issue-1780", :conflict}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}, 50
    assert [%{status: "conflict_active_run"} = record] = StatefulRunStore.list_pr_reviews()
    refute Map.has_key?(record, :conflict_retry_count)
  end

  test "leaves a merge conflict alone while the issue is parked for a person, until the label goes" do
    now = ~U[2026-05-01 09:00:00Z]
    parked = %{in_review_issue(updated_at: now) | state: "Backlog", labels: ["needs-human"]}
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [parked])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "head-sha", base_ref_oid: "base-sha")
    )

    poll = &PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, &1, :minute))

    log =
      capture_log([level: :info], fn ->
        for minute <- [1, 2, 3] do
          assert {:ok, %{actions: [{:conflict_awaiting_human_action, "issue-1780"}]}} = poll.(minute)
        end
      end)

    assert [_once] = String.split(log, "conflicts with the base branch while the issue waits in Backlog for a person") |> tl()
    refute_receive {:issue_state_update, _issue_id, _state}, 50

    assert [%{status: "conflict_awaiting_human_action", conflict_context: %{conflict_key: "head-sha|base-sha"}} = record] =
             RunStore.list_pr_reviews()

    assert Map.get(record, :conflict_retry_count, 0) == 0
    assert Map.get(record, :dispatched_conflict_keys, []) == []

    # A person removes the label: the next conflicting poll takes the conflict path as before.
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [%{parked | labels: []}])

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :conflict, "In Progress"}]}} = poll.(4)
    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "conflict_requested", conflict_retry_count: 1, dispatched_conflict_keys: ["head-sha|base-sha"]}] =
             RunStore.list_pr_reviews()
  end

  test "a parked issue's conflict waits even with the conflict retries spent" do
    now = ~U[2026-05-01 09:00:00Z]
    parked = %{in_review_issue(updated_at: now) | labels: ["Needs-Human", "breakdown"]}
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [parked])
    :ok = put_review(now, %{conflict_retry_count: 3, dispatched_conflict_keys: ["old-head|base-sha"]})

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "new-head", base_ref_oid: "base-sha")
    )

    assert {:ok, %{actions: [{:conflict_awaiting_human_action, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _issue_id, _state}, 50
    assert [%{status: "conflict_awaiting_human_action", conflict_retry_count: 3}] = RunStore.list_pr_reviews()
  end

  test "with human_review: null a conflict on an In Review issue with an open request waits for the person" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_human_review_state: nil,
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "head-sha", base_ref_oid: "base-sha")
    )

    request = %{"id" => "c1", "body" => "## Action needed: Add the signing secrets", "createdAt" => "2026-05-01T08:00:00.000Z"}

    linear_client = fn query, %{id: issue_id}, _opts ->
      assert query =~ "SymphonyAgentHumanActionScope"
      issue_node = %{"id" => issue_id, "comments" => %{"nodes" => [request]}, "history" => %{"nodes" => []}}
      {:ok, %{"data" => %{"issue" => issue_node}}}
    end

    assert {:ok, %{actions: [{:conflict_awaiting_human_action, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, linear_client: linear_client, now: now)

    refute_receive {:issue_state_update, _issue_id, _state}, 50

    failing = fn _query, _variables, _opts -> {:error, :linear_unavailable} end

    assert {:ok, %{actions: [{:poll_error, "issue-1780", {:issue_read_failed, :linear_unavailable}}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, linear_client: failing, now: now)

    refute_receive {:issue_state_update, _issue_id, _state}, 50
  end

  test "a merge conflict on an issue in an active state with a person's label takes the conflict path" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = %{in_review_issue(updated_at: now) | state: "In Progress", labels: ["needs-human"]}
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "head-sha", base_ref_oid: "base-sha")
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :conflict, "In Progress"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)
  end

  test "a failed issue read on a merge conflict records a poll error instead of moving the issue" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, mergeable: "CONFLICTING", head_ref_oid: "head-sha", base_ref_oid: "base-sha")
    )

    assert {:ok, %{actions: [{:poll_error, "issue-1780", {:issue_read_failed, :linear_unavailable}}]}} =
             PrReviewPoller.poll_once(tracker: IssueReadFailingTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _issue_id, _state}, 50
    assert [record] = RunStore.list_pr_reviews()
    assert Map.get(record, :dispatched_conflict_keys, []) == []
  end

  test "clears merge conflict state when the PR becomes clean and skips cross-repo conflicts" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "conflict_requested",
        conflict_retry_count: 1,
        dispatched_conflict_keys: ["head-sha|base-sha"],
        last_conflict_key: "head-sha|base-sha",
        conflict_context: %{
          head_sha: "head-sha",
          base_sha: "base-sha",
          conflict_key: "head-sha|base-sha"
        }
      })

    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, mergeable: "MERGEABLE"))

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [
             %{
               conflict_context: nil,
               conflict_retry_count: 0,
               dispatched_conflict_keys: [],
               last_conflict_key: nil,
               last_conflict_at: nil
             }
           ] = RunStore.list_pr_reviews()

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        mergeable: "CONFLICTING",
        is_cross_repository: true,
        head_ref_oid: "fork-head",
        base_ref_oid: "base-sha"
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}, 50
  end

  test "defers state transitions while dispatch is paused and processes them on resume" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_pause, %{
      paused: true,
      reason: "deploy window",
      paused_at: now
    })

    assert {:ok, %{actions: [{:state_transition_deferred, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}, 50

    assert [
             %{
               status: "merge_deferred",
               target_issue_state: "In Progress",
               last_action: nil,
               last_action_at: nil,
               last_review_decision: "APPROVED"
             }
           ] = StatefulRunStore.list_pr_reviews()

    Application.put_env(:symphony_elixir, :pr_review_test_pause, %{paused: false, reason: nil, paused_at: nil})

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: DateTime.add(now, 5, :second)
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "merge_requested", target_issue_state: "In Progress", last_action: "merge"}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "defers rework state transitions while dispatch is paused" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -31, :minute)
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [
          %{
            kind: "inline_comment",
            author: "reviewer",
            body: "Please split this.",
            url: "https://github.com/example/repo/pull/1780#discussion_r1"
          }
        ]
      )
    )

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_pause, %{
      paused: true,
      reason: "deploy window",
      paused_at: now
    })

    assert {:ok, %{actions: [{:state_transition_deferred, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}, 50

    assert [
             %{
               status: "rework_deferred",
               target_issue_state: "In Progress",
               last_action: nil,
               last_action_at: nil,
               last_review_decision: "CHANGES_REQUESTED"
             }
           ] = StatefulRunStore.list_pr_reviews()
  end

  test "auto reply and auto request review are off by default when comments are completed" do
    now = ~U[2026-05-01 09:00:00Z]

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    refute_receive {:github_reply, _, _, _}
    refute_receive {:github_request_review, _, _}
    assert [%{last_addressed_comment_id: "comment-1", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()
  end

  test "emits rework_pushed once when pending reviewer comments are completed" do
    now = ~U[2026-05-01 09:00:00Z]

    :ok =
      put_review(now, %{
        status: "rework_requested",
        issue_title: "Review manager",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = SymphonyElixir.Notifications.subscribe()

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:notification_event,
                    %Event{
                      event: "rework_pushed",
                      issue_id: "issue-1780",
                      issue_identifier: "ACME-1780",
                      issue_title: "Review manager",
                      issue_url: "https://linear.app/example/issue/ACME-1780",
                      pr_url: "https://github.com/example/repo/pull/1780",
                      state: "In Progress",
                      reason: "1 actionable reviewer comment addressed",
                      timestamp: ^now,
                      metadata: %{
                        source: "pr_review_poller",
                        comment_count: 1,
                        latest_comment_id: "comment-1"
                      }
                    }},
                   500

    assert [%{last_addressed_comment_id: "comment-1", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: DateTime.add(now, 1, :minute))
    refute_receive {:notification_event, %Event{event: "rework_pushed"}}, 50
  end

  test "backfills legacy issue title before rework_pushed notification" do
    now = ~U[2026-05-01 09:00:00Z]

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      now
      |> review_record(%{
        status: "rework_requested",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })
      |> Map.delete(:issue_title)
      |> RunStore.put_pr_review()

    assert :ok = SymphonyElixir.Notifications.subscribe()

    assert :ok =
             PrReviewPoller.complete_pending_reviewer_comments(
               "issue-1780",
               tracker: FakeTracker,
               github: ActionGitHub,
               now: now
             )

    assert_receive {:notification_event,
                    %Event{
                      event: "rework_pushed",
                      issue_title: "Review manager"
                    }},
                   500

    assert [%{issue_title: "Review manager", last_addressed_comment_id: "comment-1"}] = RunStore.list_pr_reviews()
  end

  test "does not emit rework_pushed when no reviewer comments are completed" do
    now = ~U[2026-05-01 09:00:00Z]

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: []
      })

    assert :ok = SymphonyElixir.Notifications.subscribe()
    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    refute_receive {:notification_event, %Event{event: "rework_pushed"}}, 50
    assert [%{last_addressed_comment_id: "comment-1", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()
  end

  test "pending reviewer comment lookup errors are recorded and block cursor completion" do
    now = ~U[2026-05-01 09:00:00Z]

    log =
      capture_log([level: :warning], fn ->
        assert [] =
                 PrReviewPoller.pending_reviewer_comments(
                   "issue-1780",
                   run_store: FailingListRunStore,
                   now: now
                 )
      end)

    assert log =~ "Failed to load pending PR review comments issue_id=issue-1780"

    assert_receive {:update_review, "issue-1780",
                    %{
                      pending_reviewer_comments_lookup_error: ":disk_full",
                      pending_reviewer_comments_lookup_error_at: ^now
                    }}

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_reviewer_comments_lookup_error: ":disk_full",
        pending_reviewer_comments_lookup_error_at: now,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert {:error, {:pending_reviewer_comments_lookup_error, ":disk_full"}} =
             PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    refute_receive {:github_reply, _, _, _}

    assert [
             %{
               pending_reviewer_comments_lookup_error: ":disk_full",
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = RunStore.list_pr_reviews()
  end

  test "successful pending reviewer comment lookup clears prior lookup errors" do
    now = ~U[2026-05-01 09:00:00Z]

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_reviewer_comments_lookup_error: ":disk_full",
        pending_reviewer_comments_lookup_error_at: DateTime.add(now, -1, :minute),
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert [%{id: "comment-1"}] = PrReviewPoller.pending_reviewer_comments("issue-1780", now: now)

    assert [
             %{
               pending_reviewer_comments_lookup_error: nil,
               pending_reviewer_comments_lookup_error_at: nil,
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = RunStore.list_pr_reviews()
  end

  test "auto reply and auto request review run only when explicitly enabled" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, reviewed_sha} = git_workspace_with_commit!()
    commit_sha = add_git_commit!(workspace_path, "docs: address review comments")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true,
      pr_review_auto_request_review: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        reviewed_commit_sha: reviewed_sha,
        review_self_users: ["symphony-operator"],
        pending_last_addressed_comment_id: "comment-2",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42},
          %{id: "comment-0", kind: "inline_comment", author: "Symphony-Operator", body: "Rename this.", path: "lib/example.ex", line: 7},
          %{id: "comment-2", kind: "comment", author: "maintainer", body: "Also update docs."}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-0"}, _operator_reply_body}

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Follow-up commit: `#{commit_sha}`. " <>
               "Please check the current diff; reply here if it still needs work."

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "pr-review-summary"}, summary_body}

    assert summary_body ==
             "Automated note from Symphony AI: these PR-level review comments were marked complete after the latest follow-up update. " <>
               "Follow-up commit: `#{commit_sha}`. " <>
               "Please check the current diff; reply if anything still needs work.\n\nComments:\n- maintainer PR comment (`comment-2`): Also update docs."

    assert_receive {:github_request_review, "https://github.com/example/repo/pull/1780", ["human-reviewer", "maintainer"]}

    assert [%{last_addressed_comment_id: "comment-2", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()
  end

  test "auto reply skips bot comment ids the agent recorded in the workspace skip file" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, reviewed_sha} = git_workspace_with_commit!()
    _commit_sha = add_git_commit!(workspace_path, "fix: address review")

    skip_file = Path.join(workspace_path, ".symphony-skip-comments.json")
    File.write!(skip_file, Jason.encode!(%{"skip_comment_ids" => ["bot-noise"]}))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        reviewed_commit_sha: reviewed_sha,
        pending_last_addressed_comment_id: "bot-noise",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42},
          %{id: "bot-noise", kind: "comment", author: "coderabbitai[bot]", body: "Summary of changes."}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    # The human comment is still replied to.
    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, _body}
    # The skipped bot comment gets no reply (neither inline nor summary).
    refute_receive {:github_reply, _, %{id: "bot-noise"}, _}
    refute_receive {:github_reply, _, %{id: "pr-review-summary"}, _}

    # The skip file is consumed (deleted) after the run.
    refute File.exists?(skip_file)
  end

  test "auto reply ignores skip entries for human (non-bot) comments" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, reviewed_sha} = git_workspace_with_commit!()
    _commit_sha = add_git_commit!(workspace_path, "fix: address review")

    File.write!(
      Path.join(workspace_path, ".symphony-skip-comments.json"),
      Jason.encode!(%{"skip_comment_ids" => ["comment-1"]})
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        reviewed_commit_sha: reviewed_sha,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    # A human comment is replied to even if the agent (wrongly) listed it to skip.
    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, _body}
  end

  test "auto reply uses a recorded follow-up sha that differs from the reviewed sha" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        reviewed_commit_sha: "111111111111",
        addressed_commit_sha: "222222222222",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Follow-up commit: `222222222222`. " <>
               "Please check the current diff; reply here if it still needs work."
  end

  test "auto reply omits follow-up commit when workspace HEAD equals the reviewed sha" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, reviewed_sha} = git_workspace_with_commit!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{
            id: "comment-1",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this.",
            path: "lib/example.ex",
            line: 42,
            commit_id: reviewed_sha
          }
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Please check the current diff; reply here if it still needs work."
  end

  test "auto reply does not treat current PR head as the reviewed sha" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, reviewed_sha} = git_workspace_with_commit!()
    follow_up_sha = add_git_commit!(workspace_path, "docs: address review comments")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        head_ref_oid: follow_up_sha,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{
            id: "comment-1",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this.",
            path: "lib/example.ex",
            line: 42,
            commit_id: reviewed_sha
          }
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Follow-up commit: `#{follow_up_sha}`. " <>
               "Please check the current diff; reply here if it still needs work."
  end

  test "auto reply derives reviewed sha from the most recent pending comment" do
    now = ~U[2026-05-01 09:00:00Z]
    {workspace_path, older_reviewed_sha} = git_workspace_with_commit!()
    latest_reviewed_sha = add_git_commit!(workspace_path, "docs: second review commit")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: workspace_path,
        pending_last_addressed_comment_id: "comment-2",
        pending_reviewer_comments: [
          %{
            id: "comment-1",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please split this.",
            path: "lib/example.ex",
            line: 42,
            commit_id: older_reviewed_sha
          },
          %{
            id: "comment-2",
            kind: "inline_comment",
            author: "human-reviewer",
            body: "Please rename this.",
            path: "lib/example.ex",
            line: 84,
            commit_id: latest_reviewed_sha
          }
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, first_reply}
    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-2"}, second_reply}

    refute first_reply =~ "Follow-up commit:"
    refute second_reply =~ "Follow-up commit:"
  end

  test "auto reply omits follow-up commit for remote worker records without a workspace" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        workspace_path: nil,
        worker_host: "remote-worker-1",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Please check the current diff; reply here if it still needs work."
  end

  test "review comments remain pending until the remote PR head advances" do
    now = ~U[2026-05-01 09:00:00Z]
    reviewed_head_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    follow_up_head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_reviewer_comments_reviewed_head_sha: reviewed_head_sha,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, head_ref_oid: reviewed_head_sha))

    log =
      capture_log([level: :warning], fn ->
        assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)
      end)

    assert log =~ "Leaving PR review comments pending because PR head did not advance"
    assert log =~ "issue_id=issue-1780"
    assert log =~ "issue_identifier=ACME-1780"
    refute_receive {:github_reply, _, _, _}

    assert [
             %{
               status: "rework_requested",
               pending_reviewer_comments_reviewed_head_sha: ^reviewed_head_sha,
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = RunStore.list_pr_reviews()

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now, head_ref_oid: follow_up_head_sha)
    )

    assert :ok =
             PrReviewPoller.complete_pending_reviewer_comments(
               "issue-1780",
               github: ActionGitHub,
               now: DateTime.add(now, 1, :minute)
             )

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}
    assert reply_body =~ "Follow-up commit: `#{follow_up_head_sha}`."

    assert [
             %{
               last_addressed_comment_id: "comment-1",
               pending_reviewer_comments_reviewed_head_sha: nil,
               pending_reviewer_comments: []
             }
           ] = RunStore.list_pr_reviews()
  end

  test "new pending reviewer comment refreshes the reviewed head sha to the current PR head" do
    now = ~U[2026-05-01 09:00:00Z]
    earlier_comment_at = DateTime.add(now, -90, :minute)
    latest_comment_at = DateTime.add(now, -31, :minute)
    stale_reviewed_head_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    advanced_head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_reviewer_comments_reviewed_head_sha: stale_reviewed_head_sha,
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "comment", author: "human-reviewer", body: "Please refactor this before merge."}
        ]
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        head_ref_oid: advanced_head_sha,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: earlier_comment_at,
            updated_at: earlier_comment_at
          },
          %{
            id: "comment-2",
            kind: "comment",
            author: "human-reviewer",
            body: "Also rename this module.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-2",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    assert {:ok, _result} = PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [
             %{
               pending_reviewer_comments_reviewed_head_sha: ^advanced_head_sha,
               pending_last_addressed_comment_id: "comment-2",
               pending_reviewer_comments: [%{id: "comment-1"}, %{id: "comment-2"}]
             }
           ] = RunStore.list_pr_reviews()
  end

  test "PR-level auto reply summary includes readable references and body excerpts" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_last_addressed_comment_id: "PRR_kw1",
        pending_reviewer_comments: [
          %{
            id: "PRR_kw1",
            kind: "review",
            author: "copilot-pull-request-reviewer[bot]",
            body: "## Pull request overview\n\nGenerated summary.",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-1"
          }
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "pr-review-summary"}, summary_body}

    assert summary_body ==
             "Automated note from Symphony AI: these PR-level review comments were marked complete after the latest follow-up update. " <>
               "Please check the current diff; reply if anything still needs work.\n\nComments:\n- [copilot-pull-request-reviewer\\[bot\\] review summary (`PRR_kw1`)](https://github.com/example/repo/pull/1780#pullrequestreview-1): Pull request overview"

    assert [%{last_addressed_comment_id: "PRR_kw1", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()
  end

  test "auto reply fires for non-rework statuses when pending comments are present" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "cooling_down",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, reply_body}

    assert reply_body ==
             "Automated note from Symphony AI: this review comment was marked complete after the latest follow-up update. " <>
               "Please check the current diff; reply here if it still needs work."

    assert [%{last_addressed_comment_id: "comment-1", pending_reviewer_comments: []}] = RunStore.list_pr_reviews()
  end

  test "auto reply does not duplicate successful replies when request review fails after cursor advancement" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true,
      pr_review_auto_request_review: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_last_addressed_comment_id: "comment-2",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42},
          %{id: "comment-2", kind: "comment", author: "maintainer", body: "Also update docs."}
        ]
      })

    Application.put_env(:symphony_elixir, :pr_review_test_request_review_failures, 1)
    assert :ok = SymphonyElixir.Notifications.subscribe()

    log =
      capture_log([level: :warning], fn ->
        assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: FailingActionGitHub, now: now)
      end)

    assert log =~ "Failed to request follow-up PR review issue_id=issue-1780"

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, _reply_body}
    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "pr-review-summary"}, _summary_body}

    assert_receive {:github_request_review_failed, "https://github.com/example/repo/pull/1780", ["human-reviewer", "maintainer"]}

    assert_receive {:notification_event,
                    %Event{
                      event: "rework_pushed",
                      metadata: %{comment_count: 2, latest_comment_id: "comment-2"}
                    }},
                   500

    assert [
             %{
               last_addressed_comment_id: "comment-2",
               pending_reviewer_comments: [],
               pending_last_addressed_comment_id: nil,
               replied_comment_ids: ["comment-1", "comment-2"],
               auto_request_review_error: "{:auto_request_review_failed, :gh_transient}"
             }
           ] = RunStore.list_pr_reviews()

    assert :ok =
             PrReviewPoller.complete_pending_reviewer_comments(
               "issue-1780",
               github: FailingActionGitHub,
               now: DateTime.add(now, 1, :minute)
             )

    refute_receive {:github_reply, _, _, _}, 50
    refute_receive {:github_request_review, _, _}, 50
  end

  test "inline auto reply partial failures retry only unreplied comments" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true
    )

    :ok =
      put_review(now, %{
        status: "rework_requested",
        pending_last_addressed_comment_id: "comment-2",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42},
          %{id: "comment-2", kind: "inline_comment", author: "maintainer", body: "Please rename this.", path: "lib/example.ex", line: 84}
        ]
      })

    Application.put_env(:symphony_elixir, :pr_review_test_reply_failures, ["comment-2"])

    assert {:error, {:auto_reply_failed, "comment-2", :gh_transient}} =
             PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: PartialFailReplyGitHub, now: now)

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, _reply_body}
    assert_receive {:github_reply_failed, "https://github.com/example/repo/pull/1780", %{id: "comment-2"}}

    assert [
             %{
               pending_last_addressed_comment_id: "comment-2",
               pending_reviewer_comments: [%{id: "comment-1"}, %{id: "comment-2"}],
               replied_comment_ids: ["comment-1"]
             }
           ] = RunStore.list_pr_reviews()

    Application.put_env(:symphony_elixir, :pr_review_test_reply_failures, [])

    assert :ok =
             PrReviewPoller.complete_pending_reviewer_comments(
               "issue-1780",
               github: PartialFailReplyGitHub,
               now: DateTime.add(now, 1, :minute)
             )

    refute_receive {:github_reply, _, %{id: "comment-1"}, _}, 50
    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-2"}, _reply_body}

    assert [
             %{
               last_addressed_comment_id: "comment-2",
               pending_reviewer_comments: [],
               replied_comment_ids: ["comment-1", "comment-2"]
             }
           ] = RunStore.list_pr_reviews()
  end

  test "auto reply state update failures are logged and recorded after posting" do
    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["agent-user"],
      pr_review_auto_reply: true
    )

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" =>
        review_record(now, %{
          status: "rework_requested",
          pending_last_addressed_comment_id: "comment-1",
          pending_reviewer_comments: [
            %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
          ]
        })
    })

    Application.put_env(:symphony_elixir, :pr_review_test_update_attr_failures, [:replied_comment_ids])

    log =
      capture_log([level: :error], fn ->
        assert {:error, {:auto_reply_state_update_failed, "comment-1", {:update_pr_review_failed, :disk_full}}} =
                 PrReviewPoller.complete_pending_reviewer_comments(
                   "issue-1780",
                   run_store: StatefulRunStore,
                   github: ActionGitHub,
                   now: now
                 )
      end)

    assert log =~ "Auto reply posted but failed to persist replied_comment_ids"
    assert log =~ "retries may duplicate GitHub replies"

    assert_receive {:github_reply, "https://github.com/example/repo/pull/1780", %{id: "comment-1"}, _reply_body}
    assert_receive {:update_review, "issue-1780", %{auto_reply_state_update_error: error}}
    assert error =~ "comment-1"

    assert [
             %{
               auto_reply_state_update_error: stored_error,
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert stored_error =~ "comment-1"
  end

  test "completion advances pending comments for any status when auto reply is disabled" do
    now = ~U[2026-05-01 09:00:00Z]

    :ok =
      put_review(now, %{
        status: "watching",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "inline_comment", author: "human-reviewer", body: "Please split this.", path: "lib/example.ex", line: 42}
        ]
      })

    assert :ok = PrReviewPoller.complete_pending_reviewer_comments("issue-1780", github: ActionGitHub, now: now)

    refute_receive {:github_reply, _, _, _}
    refute_receive {:github_request_review, _, _}

    assert [
             %{
               status: "watching",
               last_addressed_comment_id: "comment-1",
               pending_last_addressed_comment_id: nil,
               pending_reviewer_comments: []
             }
           ] = RunStore.list_pr_reviews()
  end

  test "polling clears stale pending comments after the addressed cursor catches up" do
    now = ~U[2026-05-01 09:00:00Z]
    comment_at = DateTime.add(now, -45, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "watching",
        last_addressed_comment_id: "comment-1",
        pending_last_addressed_comment_id: "comment-1",
        pending_reviewer_comments: [
          %{id: "comment-1", kind: "comment", author: "human-reviewer", body: "Already handled.", created_at: comment_at}
        ]
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(comment_at,
        comments: [
          %{id: "comment-1", kind: "comment", author: "human-reviewer", body: "Already handled.", created_at: comment_at}
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [%{pending_reviewer_comments: [], pending_last_addressed_comment_id: nil}] = RunStore.list_pr_reviews()
  end

  test "approval wins over stale cleanup" do
    now = ~U[2026-05-01 09:00:00Z]
    old_activity_at = DateTime.add(now, -8, :day)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(old_activity_at, review_decision: "APPROVED")
    )

    :ok = put_review(now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
    refute_receive {:remove_workspace, _, _}, 50
  end

  test "does not respawn rework when only PR activity changed after handled review comments" do
    now = ~U[2026-05-01 09:00:00Z]
    review_activity_at = DateTime.add(now, -90, :minute)
    latest_pr_activity_at = DateTime.add(now, -10, :minute)
    last_action_at = DateTime.add(review_activity_at, 30, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "rework_requested",
        last_action: "rework",
        last_action_at: last_action_at,
        last_activity_at: review_activity_at,
        last_review_activity_at: review_activity_at
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_pr_activity_at,
        latest_review_activity_at: review_activity_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [%{kind: "review", author: "reviewer", body: "Already handled.", url: "https://github.com/example/repo/pull/1780#pullrequestreview-1"}]
      )
    )

    assert {:ok, %{actions: [{:already_handled, "issue-1780", :rework}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}

    assert [
             %{
               status: "watching",
               last_activity_at: ^latest_pr_activity_at,
               last_review_activity_at: ^review_activity_at
             }
           ] = RunStore.list_pr_reviews()
  end

  test "bodyless changes_requested review after a handled review bumps last_review_activity_at and redispatches rework" do
    now = ~U[2026-05-01 09:00:00Z]
    old_review_at = DateTime.add(now, -180, :minute)
    last_action_at = DateTime.add(old_review_at, 30, :minute)
    new_review_at = DateTime.add(now, -45, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "rework_requested",
        last_action: "rework",
        last_action_at: last_action_at,
        last_activity_at: old_review_at,
        last_review_activity_at: old_review_at
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(new_review_at,
        review_decision: "CHANGES_REQUESTED",
        latest_review_activity_at: new_review_at,
        comments: [
          %{
            id: "bodyless-review",
            kind: "review",
            state: "CHANGES_REQUESTED",
            author: "human-reviewer",
            body: "",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-2",
            created_at: new_review_at,
            updated_at: new_review_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "rework_requested",
               last_review_activity_at: ^new_review_at
             }
           ] = RunStore.list_pr_reviews()
  end

  test "Symphony-marked author comments after a handled changes-requested review do not redispatch rework" do
    now = ~U[2026-05-01 09:00:00Z]
    reviewer_activity_at = DateTime.add(now, -120, :minute)
    last_action_at = DateTime.add(now, -50, :minute)
    author_comment_at = DateTime.add(now, -35, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "rework_requested",
        last_action: "rework",
        last_action_at: last_action_at,
        last_activity_at: reviewer_activity_at,
        last_review_activity_at: reviewer_activity_at,
        last_addressed_comment_id: "reviewer-comment"
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(author_comment_at,
        pr_author: "pr-author",
        review_decision: "CHANGES_REQUESTED",
        latest_review_activity_at: author_comment_at,
        comments: [
          %{
            id: "reviewer-comment",
            kind: "review",
            state: "CHANGES_REQUESTED",
            author: "human-reviewer",
            body: "Please address.",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-1",
            created_at: reviewer_activity_at,
            updated_at: reviewer_activity_at
          },
          %{
            id: "author-followup",
            kind: "comment",
            author: "pr-author",
            body: "Pinging for review.\n\n<!-- symphony:agent -->",
            created_at: author_comment_at,
            updated_at: author_comment_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:already_handled, "issue-1780", :rework}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: nil,
               now: now
             )

    refute_receive {:issue_state_update, _, _}

    assert [
             %{
               status: "watching",
               last_activity_at: ^author_comment_at,
               last_review_activity_at: ^reviewer_activity_at
             }
           ] = RunStore.list_pr_reviews()
  end

  test "CHANGES_REQUESTED reviews from ignored users or marked by Symphony do not redispatch rework after cooldown" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -31, :minute)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      pr_review_ignored_users: ["symphony-bot"]
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        pr_author: "pr-author",
        review_decision: "CHANGES_REQUESTED",
        latest_review_activity_at: latest_review_at,
        comments: [
          %{
            id: "operator-review",
            kind: "review",
            state: "CHANGES_REQUESTED",
            author: "symphony-operator",
            body: "Nudging this back to draft.\n\n<!-- symphony:agent -->",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-1",
            created_at: latest_review_at,
            updated_at: latest_review_at
          },
          %{
            id: "bot-review",
            kind: "review",
            state: "CHANGES_REQUESTED",
            author: "symphony-bot",
            body: "Automated nudge.",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-2",
            created_at: latest_review_at,
            updated_at: latest_review_at
          }
        ]
      )
    )

    assert {:ok, %{actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               current_gh_user: "symphony-operator",
               now: now
             )

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "watching"}] = RunStore.list_pr_reviews()
  end

  test "records issue state transition errors without crashing the poll" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -31, :minute)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at, review_decision: "APPROVED")
    )

    :ok = put_review(now)

    Application.put_env(:symphony_elixir, :pr_review_test_state_update_failures, ["issue-1780"])

    assert {:ok, %{actions: [{:state_transition_error, "issue-1780", :merge, :linear_unavailable}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert [%{status: "state_transition_error", error: ":linear_unavailable", last_action: "merge"}] =
             RunStore.list_pr_reviews()
  end

  test "cleans up workspace and tracking when PR is merged or stale" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert [] = RunStore.list_pr_reviews()

    stale_activity_at = DateTime.add(now, -8, :day)
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(stale_activity_at))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "stale"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert [] = RunStore.list_pr_reviews()
  end

  test "defers merged-PR workspace cleanup until the issue's agent run ends" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    :ok = put_review(now)

    run = %{
      repo_key: @repo_key,
      run_id: "run-landing-1780",
      issue_id: "issue-1780",
      issue_identifier: "ACME-1780",
      status: "running",
      workspace_path: "/tmp/workspaces/ACME-1780",
      worker_host: nil,
      started_at: DateTime.add(now, -60, :second)
    }

    :ok = RunStore.put_run(run)

    assert {:ok, %{actions: [{:cleanup_deferred, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    refute_received {:remove_workspace, _workspace_path, _worker_host}
    assert [%{issue_id: "issue-1780", status: "watching"}] = RunStore.list_pr_reviews()

    :ok = RunStore.put_run(Map.merge(run, %{status: "success", ended_at: now}))

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert [] = RunStore.list_pr_reviews()
  end

  test "does not run learning reflection when learnings are disabled" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    :ok = put_review(now, %{run_id: "run-1780"})

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               provider_module: FakeLearningProvider,
               now: now
             )

    refute_receive {:learning_reflection, _, _}, 50
    assert [] = RunStore.list_learnings()
  end

  test "captures learnings once when a tracked PR is merged" do
    previous_key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", previous_key) end)

    now = ~U[2026-05-01 09:00:00Z]
    transcript_path = Path.join(System.tmp_dir!(), "learning-transcript-#{System.unique_integer([:positive])}.jsonl")
    File.write!(transcript_path, Jason.encode!(%{event: "tool", command: "mix test"}) <> "\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      learnings: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        max_total_per_repo: 10,
        max_per_run: 2
      }
    )

    issue =
      in_review_issue(
        updated_at: now,
        comments: [%{author: "Operator", body: "Remember to update docs.", created_at: now}]
      )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(now,
        state: "MERGED",
        comments: [
          %{
            kind: "review",
            author: "reviewer",
            body: "Prefer the existing StatusDashboard helpers.",
            url: "https://github.com/example/repo/pull/1780#pullrequestreview-1"
          },
          %{
            kind: "comment",
            author: "reviewer",
            body: String.duplicate("a", 7_999) <> "🔥tail",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1"
          }
        ]
      )
    )

    Application.put_env(
      :symphony_elixir,
      :learning_test_response,
      ~s({"learnings":[{"rule":"Prefer existing StatusDashboard helpers before adding new formatting paths.","tags":["dashboard","repo-patterns"],"evidence_quote":"Prefer the existing StatusDashboard helpers."},{"rule":"Document every new workflow config block in both examples.","tags":["docs","workflow-config"],"evidence_quote":"Remember to update docs."},{"rule":"Do not persist more than two records in this test.","tags":["limit","test-only"],"evidence_quote":"third"}]})
    )

    :ok = put_review(now, %{run_id: "run-1780", transcript_path: transcript_path})

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               provider_module: FakeLearningProvider,
               now: now
             )

    assert_receive {:learning_reflection, request, settings}
    refute_receive {:learning_reflection, _, _}, 50

    assert settings.model == "claude-haiku-4-5-20251001"
    assert request.system =~ "Return ONLY strict JSON"
    assert request.user =~ "Repository:\ngithub.com/example/repo"
    assert request.user =~ "Prefer the existing StatusDashboard helpers."
    assert request.user =~ "[truncated]"
    assert request.user =~ "mix test"
    assert Jason.encode!(request)

    learnings = RunStore.list_learnings()
    assert length(learnings) == 2

    assert %{
             host: "github.com",
             owner: "example",
             repo: "repo",
             tags: ["docs", "workflow-config"],
             evidence_quote: "Remember to update docs.",
             evidence_issue_identifier: "ACME-1780",
             evidence_issue_url: "https://linear.app/example/issue/ACME-1780",
             evidence_pr_number: 1780,
             evidence_run_id: "run-1780",
             created_at: ^now
           } =
             Enum.find(learnings, &(Map.get(&1, :rule) == "Document every new workflow config block in both examples."))

    assert %{
             tags: ["dashboard", "repo-patterns"],
             evidence_quote: "Prefer the existing StatusDashboard helpers."
           } =
             Enum.find(
               learnings,
               &(Map.get(&1, :rule) == "Prefer existing StatusDashboard helpers before adding new formatting paths.")
             )
  end

  test "records crashed learning reflection and continues cleanup" do
    previous_key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", previous_key) end)

    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      learnings: %{enabled: true, provider: "anthropic", model: "claude-haiku-4-5-20251001"}
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_delete_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now, %{run_id: "run-1780"})
    })

    log =
      capture_log([level: :error], fn ->
        assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :disk_full}]}} =
                 PrReviewPoller.poll_once(
                   tracker: FakeTracker,
                   run_store: StatefulRunStore,
                   github: FakeGitHub,
                   workspace: FakeWorkspace,
                   provider_module: CrashingLearningProvider,
                   now: now
                 )
      end)

    assert_receive {:learning_reflection, _, _}
    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert log =~ "Learning reflection crashed issue_id=issue-1780"
    assert log =~ "learning provider crashed"

    assert [
             %{
               status: "cleanup_pending",
               learning_reflected_at: ^now,
               learning_reflection_count: 0,
               learning_reflection_error: error,
               workspace_removed_at: ^now
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert error =~ "capture_crashed"
    assert error =~ "learning provider crashed"
  end

  test "logs and discards malformed learning reflection output" do
    previous_key = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", previous_key) end)

    now = ~U[2026-05-01 09:00:00Z]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7,
      learnings: %{enabled: true, provider: "anthropic", model: "claude-haiku-4-5-20251001"}
    )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :learning_test_response, "not json")
    :ok = put_review(now, %{run_id: "run-1780"})

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
                 PrReviewPoller.poll_once(
                   tracker: FakeTracker,
                   github: FakeGitHub,
                   workspace: FakeWorkspace,
                   provider_module: FakeLearningProvider,
                   now: now
                 )
      end)

    assert_receive {:learning_reflection, _, _}
    assert log =~ "Learning reflection malformed LLM output"
    assert [] = RunStore.list_learnings()
  end

  test "does not remove workspace again when review delete fails after cleanup" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_delete_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :disk_full}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}

    assert [%{status: "cleanup_pending", workspace_removed_at: ^now}] =
             StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: DateTime.add(now, 5, :second)
             )

    refute_receive {:remove_workspace, _, _}, 50
    assert [] = StatefulRunStore.list_pr_reviews()
  end

  test "backs off workspace cleanup errors instead of retrying every poll" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :branch_checked_out}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FailingWorkspace,
               now: now,
               poll_interval_ms: 5_000
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}

    assert [
             %{
               status: "cleanup_error",
               consecutive_errors: 1,
               next_poll_at: next_poll_at,
               error: error
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert DateTime.diff(next_poll_at, now, :millisecond) == 5_000
    assert error =~ "checked out"

    assert {:ok, %{actions: [{:backing_off, "issue-1780", ^next_poll_at}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FailingWorkspace,
               now: DateTime.add(now, 1, :second),
               poll_interval_ms: 5_000
             )

    refute_receive {:github_fetch, _pr_url}, 50
    refute_receive {:remove_workspace, _, _}, 50
  end

  test "does not remove workspace again when cleanup mark update fails before delete failure" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["cleanup_pending"])
    Application.put_env(:symphony_elixir, :pr_review_test_delete_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :disk_full}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert_receive {:put_review, "issue-1780"}

    assert [%{status: "cleanup_pending", workspace_removed_at: ^now}] =
             StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "merged"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: DateTime.add(now, 5, :second)
             )

    refute_receive {:remove_workspace, _, _}, 50
    assert [] = StatefulRunStore.list_pr_reviews()
  end

  test "reports cleanup error when workspace removal update and fallback put both fail" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["cleanup_pending"])
    Application.put_env(:symphony_elixir, :pr_review_test_put_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    expected_reason =
      {:workspace_removed_update_failed, {:update_pr_review_failed, :disk_full}, :disk_full}

    log =
      capture_log([level: :warning], fn ->
        assert {:ok,
                %{
                  actions: [
                    {:cleanup_error, "issue-1780", ^expected_reason}
                  ]
                }} =
                 PrReviewPoller.poll_once(
                   tracker: FakeTracker,
                   run_store: StatefulRunStore,
                   github: FakeGitHub,
                   workspace: FakeWorkspace,
                   now: now
                 )
      end)

    assert_receive {:remove_workspace, "/tmp/workspaces/ACME-1780", nil}
    assert log =~ "Failed to update PR review workspace removal issue_id=issue-1780"
    assert log =~ "Failed to persist PR review workspace removal issue_id=issue-1780"

    assert [%{status: "watching"} = record] = StatefulRunStore.list_pr_reviews()
    refute Map.has_key?(record, :workspace_removed_at)
  end

  test "continues review discovery when one record fails to persist" do
    now = ~U[2026-05-01 09:00:00Z]

    failing_issue =
      in_review_issue(
        id: "issue-fail",
        identifier: "ACME-FAIL",
        pr_url: "https://github.com/example/repo/pull/1",
        updated_at: now
      )

    ok_issue =
      in_review_issue(
        id: "issue-ok",
        identifier: "ACME-OK",
        pr_url: "https://github.com/example/repo/pull/2",
        updated_at: now
      )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [failing_issue, ok_issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))
    Application.put_env(:symphony_elixir, :pr_review_test_put_failures, ["issue-fail"])

    Application.put_env(:symphony_elixir, :pr_review_test_runs, [
      review_run(failing_issue, "/tmp/workspaces/ACME-FAIL", now),
      review_run(ok_issue, "/tmp/workspaces/ACME-OK", now)
    ])

    assert {:ok, %{discovered: 1, processed: 1}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:put_review, "issue-ok"}

    assert [%{issue_id: "issue-ok", workspace_path: "/tmp/workspaces/ACME-OK"}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "backs off GitHub polling after repeated fetch failures" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now, %{consecutive_errors: 2})
    })

    assert :ok = SymphonyElixir.Notifications.subscribe()

    assert {:ok, %{actions: [{:poll_error, "issue-1780", :rate_limited}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FailingGitHub,
               now: now,
               poll_interval_ms: 5_000
             )

    assert_receive {:github_fetch, "https://github.com/example/repo/pull/1780"}

    assert_receive {:notification_event,
                    %SymphonyElixir.Notifications.Event{
                      event: "run_failed",
                      issue_identifier: "ACME-1780",
                      metadata: %{source: "pr_review_poller", consecutive_errors: 3}
                    }},
                   500

    assert [%{consecutive_errors: 3, next_poll_at: next_poll_at}] =
             StatefulRunStore.list_pr_reviews()

    assert DateTime.diff(next_poll_at, now, :millisecond) == 5_000

    assert {:ok, %{actions: [{:backing_off, "issue-1780", ^next_poll_at}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FailingGitHub,
               now: DateTime.add(now, 1, :second),
               poll_interval_ms: 5_000
             )

    refute_receive {:github_fetch, _pr_url}, 50
  end

  test "poll callback uses cached interval when workflow config becomes invalid" do
    {:ok, state} = PrReviewPoller.init(poll_interval_ms: 123)
    Process.cancel_timer(state.timer_ref)

    File.write!(Workflow.workflow_file_path(), "---\npr_review:\n  mode: [broken]\n---\n")

    assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
    assert next_state.poll_interval_ms == 123
    assert Keyword.fetch!(next_state.opts, :poll_interval_ms) == 123
    assert is_reference(next_state.timer_ref)

    Process.cancel_timer(next_state.timer_ref)
  end

  test "poll callback logs exceptions and keeps scheduling" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    {:ok, state} =
      PrReviewPoller.init(
        tracker: FakeTracker,
        run_store: RaisingRunStore,
        poll_interval_ms: 123,
        now: now
      )

    Process.cancel_timer(state.timer_ref)

    log =
      capture_log([level: :error], fn ->
        assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
        assert next_state.poll_interval_ms == 123
        assert Keyword.fetch!(next_state.opts, :poll_interval_ms) == 123
        assert next_state.consecutive_failures == 1
        assert next_state.current_backoff_ms == 123
        assert is_reference(next_state.timer_ref)
        Process.cancel_timer(next_state.timer_ref)
      end)

    assert log =~ "PR review poll raised"
    assert log =~ "poll exploded"
  end

  test "poll callback backs off, emits degradation audit, and recovers" do
    {:ok, state} =
      PrReviewPoller.init(
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
        assert {:noreply, failed_once} = PrReviewPoller.handle_info(:poll, state)
        assert failed_once.consecutive_failures == 1
        assert failed_once.current_backoff_ms == 100
        Process.cancel_timer(failed_once.timer_ref)

        assert {:noreply, degraded} = PrReviewPoller.handle_info(:poll, failed_once)
        assert degraded.consecutive_failures == 2
        assert degraded.current_backoff_ms == 200
        assert degraded.degraded?
        Process.cancel_timer(degraded.timer_ref)

        assert {:noreply, capped} = PrReviewPoller.handle_info(:poll, degraded)
        assert capped.consecutive_failures == 3
        assert capped.current_backoff_ms == 250
        Process.cancel_timer(capped.timer_ref)

        successful = %{capped | opts: Keyword.put(capped.opts, :run_store, StatefulRunStore)}

        info_log =
          capture_log([level: :info], fn ->
            assert {:noreply, recovered} = PrReviewPoller.handle_info(:poll, successful)
            assert recovered.consecutive_failures == 0
            assert recovered.current_backoff_ms == nil
            refute recovered.degraded?
            Process.cancel_timer(recovered.timer_ref)
          end)

        assert info_log =~ "PR review poll recovered after 3 consecutive failures"
      end)

    assert log =~ "PR review poll raised"
    assert log =~ "poll exploded"
    assert log =~ "PR review poll backing off after 2 consecutive failures; next poll in 200ms"
    assert log =~ "PR review poll backing off after 3 consecutive failures; next poll in 250ms"

    assert audit_event?("poller_degraded", "pr_review", "degraded")
    assert audit_event?("poller_recovered", "pr_review", "recovered")
  end

  test "poll callback logs warning-level signals for review action errors" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["merge_transition_pending"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    {:ok, state} =
      PrReviewPoller.init(
        tracker: FakeTracker,
        run_store: StatefulRunStore,
        github: FakeGitHub,
        poll_interval_ms: 123,
        now: now
      )

    Process.cancel_timer(state.timer_ref)

    log =
      capture_log([level: :warning], fn ->
        assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
        Process.cancel_timer(next_state.timer_ref)
      end)

    refute_receive {:issue_state_update, _, _}, 50
    assert log =~ "PR review transition update error issue_id=issue-1780 action=merge"
    assert log =~ "update_pr_review_failed"
  end

  test "failed pending action persistence prevents Linear transition" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["merge_transition_pending"])

    assert {:ok,
            %{
              actions: [
                {:state_transition_update_error, "issue-1780", :merge, {:update_pr_review_failed, :disk_full}}
              ]
            }} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}, 50

    assert [
             %{
               status: "watching"
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: DateTime.add(now, 5, :second)
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
  end

  test "failed transition success marker keeps pending reviewer comments durable and retryable" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["rework_requested"])

    assert {:ok,
            %{
              actions: [
                {:state_transition_update_error, "issue-1780", :rework, {:update_pr_review_failed, :disk_full}}
              ]
            }} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "rework_transition_pending",
               last_action: nil,
               pending_reviewer_comments: [%{id: "comment-1"}]
             } = record
           ] = StatefulRunStore.list_pr_reviews()

    assert Map.get(record, :last_action_at) == nil

    assert [%{id: "comment-1"}] =
             PrReviewPoller.pending_reviewer_comments("issue-1780", run_store: StatefulRunStore)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: DateTime.add(now, 5, :second)
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{last_action: "rework", last_action_at: %DateTime{}, pending_reviewer_comments: [%{id: "comment-1"}]}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "failed Linear transition keeps pending reviewer comments durable and retryable" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_comment_at = DateTime.add(now, -31, :minute)
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_comment_at,
        comments: [
          %{
            id: "comment-1",
            kind: "comment",
            author: "human-reviewer",
            body: "Please refactor this before merge.",
            url: "https://github.com/example/repo/pull/1780#issuecomment-1",
            created_at: latest_comment_at,
            updated_at: latest_comment_at
          }
        ]
      )
    )

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    # Fail the Linear transition itself (after the pending context is persisted).
    Application.put_env(:symphony_elixir, :pr_review_test_state_update_failures, ["issue-1780"])

    assert {:ok, %{actions: [{:state_transition_error, "issue-1780", :rework, :linear_unavailable}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    # The Linear transition never landed, so no issue state update is emitted.
    refute_receive {:issue_state_update, _, _}, 50

    assert [
             %{
               status: "state_transition_error",
               error: ":linear_unavailable",
               last_action: "rework",
               last_action_at: nil,
               pending_reviewer_comments: [%{id: "comment-1"}]
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert [%{id: "comment-1"}] =
             PrReviewPoller.pending_reviewer_comments("issue-1780", run_store: StatefulRunStore)

    # A subsequent poll retries the transition; with Linear recovered it lands.
    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: DateTime.add(now, 5, :second)
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{last_action: "rework", last_action_at: %DateTime{}, pending_reviewer_comments: [%{id: "comment-1"}]}] =
             StatefulRunStore.list_pr_reviews()
  end

  defp put_review(now, attrs \\ %{}) do
    now
    |> review_record(attrs)
    |> RunStore.put_pr_review()
  end

  defp git_workspace_with_commit! do
    workspace_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-pr-review-workspace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace_path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(workspace_path) end)

    git!(workspace_path, ["init", "-b", "main"])
    git!(workspace_path, ["config", "user.name", "Test User"])
    git!(workspace_path, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(workspace_path, "README.md"), "# Review test\n")
    git!(workspace_path, ["add", "README.md"])
    git!(workspace_path, ["commit", "-m", "fix: address review comment"])

    {workspace_path, git!(workspace_path, ["rev-parse", "--short=12", "HEAD"]) |> String.trim()}
  end

  defp add_git_commit!(workspace_path, message) do
    file_path = Path.join(workspace_path, "change-#{System.unique_integer([:positive])}.md")

    File.write!(file_path, "Review update\n")
    git!(workspace_path, ["add", file_path])
    git!(workspace_path, ["commit", "-m", message])
    git!(workspace_path, ["rev-parse", "--short=12", "HEAD"]) |> String.trim()
  end

  defp git!(workspace_path, args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp multi_repo_config do
    [
      %{key: @repo_key, workflow: Workflow.workflow_file_path(), default: true, team: "Test"},
      %{key: "secondary", workflow: Workflow.workflow_file_path(), team: "PIN4WOO", labels: ["Bug"]}
    ]
  end

  defp review_record(now, attrs \\ %{}) do
    %{
      repo_key: @repo_key,
      issue_id: "issue-1780",
      issue_identifier: "ACME-1780",
      issue_title: "Review manager",
      issue_url: "https://linear.app/example/issue/ACME-1780",
      pr_url: "https://github.com/example/repo/pull/1780",
      workspace_path: "/tmp/workspaces/ACME-1780",
      worker_host: nil,
      status: "watching",
      inserted_at: now,
      updated_at: now
    }
    |> Map.merge(attrs)
  end

  defp in_review_issue(opts) do
    updated_at = Keyword.fetch!(opts, :updated_at)
    id = Keyword.get(opts, :id, "issue-1780")
    identifier = Keyword.get(opts, :identifier, "ACME-1780")
    pr_url = Keyword.get(opts, :pr_url, "https://github.com/example/repo/pull/1780")

    %Issue{
      id: id,
      identifier: identifier,
      title: "Review manager",
      description: "Poll PR state",
      state: "In Review",
      url: "https://linear.app/example/issue/#{identifier}",
      pr_urls: [pr_url],
      comments: Keyword.get(opts, :comments, []),
      updated_at: updated_at
    }
  end

  defp review_run(%Issue{} = issue, workspace_path, now, attrs \\ %{}) do
    %{
      run_id: "run-#{issue.id}",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      status: "success",
      workspace_path: workspace_path,
      worker_host: nil,
      started_at: DateTime.add(now, -120, :second),
      ended_at: DateTime.add(now, -60, :second)
    }
    |> Map.merge(attrs)
  end

  defp open_activity(latest_activity_at, opts \\ []) do
    %{
      pr_url: "https://github.com/example/repo/pull/1780",
      pr_number: Keyword.get(opts, :pr_number, 1780),
      pr_title: Keyword.get(opts, :pr_title, "Ship review manager"),
      pr_description: Keyword.get(opts, :pr_description, "PR body"),
      pr_author: Keyword.get(opts, :pr_author),
      state: Keyword.get(opts, :state, "OPEN"),
      review_decision: Keyword.get(opts, :review_decision),
      mergeable: Keyword.get(opts, :mergeable),
      merge_state_status: Keyword.get(opts, :merge_state_status),
      head_ref_name: Keyword.get(opts, :head_ref_name),
      head_ref_oid: Keyword.get(opts, :head_ref_oid),
      base_ref_name: Keyword.get(opts, :base_ref_name),
      base_ref_oid: Keyword.get(opts, :base_ref_oid),
      is_cross_repository: Keyword.get(opts, :is_cross_repository, false),
      latest_activity_at: latest_activity_at,
      latest_review_activity_at: Keyword.get(opts, :latest_review_activity_at, latest_activity_at),
      comments: Keyword.get(opts, :comments, [])
    }
  end

  defp audit_event?(event_type, poller, status) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: event_type)

    Enum.any?(events, fn event ->
      event["poller"] == poller and event["status"] == status
    end)
  end

  # The reductions of `fun`'s second call, so both measure a warm cycle.
  defp reductions(fun) do
    fun.()
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end
end
