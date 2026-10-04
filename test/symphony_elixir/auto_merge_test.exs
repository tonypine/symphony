defmodule SymphonyElixir.AutoMergeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AutoMerge, CiPoller, PrReviewPoller}
  alias SymphonyElixir.Linear.Issue

  @repo_key "default"
  @pr_url "https://github.com/example/repo/pull/1780"
  @issue_id "issue-1780"

  defmodule FakeTracker do
    alias SymphonyElixir.Linear.Issue

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(states) do
      wanted = MapSet.new(states, &String.downcase/1)

      issues =
        :symphony_elixir
        |> Application.get_env(:auto_merge_test_issues, [])
        |> Enum.filter(&MapSet.member?(wanted, String.downcase(&1.state)))

      {:ok, issues}
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name) do
      send(recipient(), {:issue_state_update, issue_id, state_name})
      Application.get_env(:symphony_elixir, :auto_merge_test_state_result, :ok)
    end

    @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
    def create_comment(issue_id, body) do
      send(recipient(), {:issue_comment, issue_id, body})
      Application.get_env(:symphony_elixir, :auto_merge_test_comment_result, :ok)
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :auto_merge_test_recipient)
  end

  defmodule FakeGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts), do: {:ok, Application.fetch_env!(:symphony_elixir, :auto_merge_test_activity)}

    @spec enable_auto_merge(String.t(), map(), keyword()) :: :ok | {:error, term()}
    def enable_auto_merge(pr_url, request, _opts), do: reply(:enable_auto_merge, {:enable_auto_merge, pr_url, request})

    @spec squash_merge(String.t(), map(), keyword()) :: :ok | {:error, term()}
    def squash_merge(pr_url, request, _opts), do: reply(:squash_merge, {:squash_merge, pr_url, request})

    @spec update_branch(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
    def update_branch(pr_url, head_sha, _opts), do: reply(:update_branch, {:update_branch, pr_url, head_sha})

    @spec disable_auto_merge(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
    def disable_auto_merge(pr_url, pr_node_id, _opts), do: reply(:disable_auto_merge, {:disable_auto_merge, pr_url, pr_node_id})

    @spec fetch_ci_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
    def fetch_ci_status(_pr_url, _opts) do
      case Application.get_env(:symphony_elixir, :auto_merge_test_ci_status, {:error, :no_status}) do
        %{} = status -> {:ok, status}
        error -> error
      end
    end

    defp reply(call, message) do
      send(Application.fetch_env!(:symphony_elixir, :auto_merge_test_recipient), message)

      :symphony_elixir
      |> Application.get_env(:auto_merge_test_replies, %{})
      |> Map.get(call, :ok)
    end
  end

  setup do
    on_exit(fn ->
      for key <- [
            :auto_merge_test_issues,
            :auto_merge_test_activity,
            :auto_merge_test_ci_status,
            :auto_merge_test_recipient,
            :auto_merge_test_replies,
            :auto_merge_test_state_result,
            :auto_merge_test_comment_result
          ] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    audit_dir = Path.join(System.tmp_dir!(), "symphony-auto-merge-audit-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir)
      File.rm_rf(audit_dir)
    end)

    write_auto_merge_workflow!()
    Application.put_env(:symphony_elixir, :auto_merge_test_recipient, self())
    :ok
  end

  test "a green, up-to-date PR gets auto-merge once and the issue is Done after GitHub merges it" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now) end)

    assert_received {:enable_auto_merge, @pr_url, request}
    assert request == %{pr_node_id: "PR_node", head_sha: "head-1", pr_number: 1780, pr_title: "Ship it", pr_description: "PR body"}

    assert log =~ "Auto-merge ACME-1780: auto-merge on, waiting for CI on `head-1`"
    assert %{state: "enabled", enabled_head_sha: "head-1"} = PrReviewPoller.auto_merge(@issue_id)
    assert [%{issue_identifier: "ACME-1780", status: "auto-merge on, waiting for CI on `head-1`"}] = PrReviewPoller.auto_merge_statuses()

    # GitHub now shows auto-merge on: nothing more to call for this head.
    activity(head: "head-1", merge_state: "BLOCKED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 30))
    refute_received {:enable_auto_merge, _url, _request}

    activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)

    log = capture_log(fn -> assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 60)) end)

    assert_received {:issue_state_update, @issue_id, "Done"}
    assert log =~ "Auto-merge ACME-1780: merged"
    assert RunStore.list_pr_reviews(@repo_key) == []
  end

  test "a PR GitHub can already merge is squash-merged right away" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "CLEAN")
    ci_status(merge_state: "CLEAN", checks: [check("SUCCESS"), check("SKIPPED"), %{name: "lint", status: "SUCCESS", conclusion: "NEUTRAL"}])
    replies(%{enable_auto_merge: {:error, :clean_status}})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "merging"}]}} = poll(now) end)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
    assert_received {:squash_merge, @pr_url, request}
    assert request == %{pr_node_id: "PR_node", head_sha: "head-1", pr_number: 1780, pr_title: "Ship it", pr_description: "PR body"}

    assert log =~
             "Auto-merge ACME-1780: GitHub refused auto-merge (the PR can already merge); squash-merging the clean PR directly pr_url=#{@pr_url} commit_sha=head-1"

    refute_received {:issue_comment, _issue_id, _body}
    # Auto-merge still owns it, so no landing agent is dispatched.
    assert AutoMerge.owns_issue?(merging)

    # A later poll at the same head neither re-enables nor re-merges.
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "merging"}]}} = poll(DateTime.add(now, 30))
    refute_received {:enable_auto_merge, _url, _request}
    refute_received {:squash_merge, _url, _request}
    assert AutoMerge.describe(PrReviewPoller.auto_merge(@issue_id)) == "merging `head-1`"

    activity(head: "head-1", state: "MERGED")
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 60))
    assert_received {:issue_state_update, @issue_id, "Done"}
  end

  test "a clean PR with no checks in a repository that doesn't allow auto-merge is squash-merged directly" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "CLEAN")
    ci_status(merge_state: "CLEAN", checks: [])

    replies(%{
      enable_auto_merge:
        {:error,
         {:gh_failed, ["api", "graphql"], 1, ~s(gh: {"data":{"enablePullRequestAutoMerge":null},"errors":[{"type":"UNPROCESSABLE","message":"Auto merge is not allowed for this repository"}]}\n)}}
    })

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "merging"}]}} = poll(now) end)

    assert_received {:squash_merge, @pr_url, %{head_sha: "head-1", pr_title: "Ship it", pr_number: 1780}}
    assert log =~ "Auto merge is not allowed for this repository"
    assert log =~ "squash-merging the clean PR directly"
    refute log =~ "fell back to the landing agent"
    refute_received {:issue_comment, _issue_id, _body}
    assert AutoMerge.owns_issue?(merging)
  end

  test "a PR that merged while auto-merge was refused takes the merged path, not the landing agent" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "CLEAN")
    ci_status(state: "MERGED", merge_state: "UNKNOWN", checks: [])
    replies(%{enable_auto_merge: {:error, {:gh_failed, ["api", "graphql"], 1, "gh: Pull request is already merged"}}})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "merging"}]}} = poll(now) end)

    refute_received {:squash_merge, _url, _request}
    refute_received {:issue_comment, _issue_id, _body}
    assert log =~ "Auto-merge ACME-1780: GitHub refused auto-merge (gh: Pull request is already merged (exit 1)); the PR is already merged"
    assert AutoMerge.owns_issue?(merging)

    activity(head: "head-1", state: "MERGED")
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 30))
    assert_received {:issue_state_update, @issue_id, "Done"}
  end

  test "a refused PR that is red, pending, not clean, on another head or unreadable still goes to the landing agent" do
    now = ~U[2026-10-03 12:00:00Z]
    replies(%{enable_auto_merge: {:error, {:gh_failed, ["api", "graphql"], 1, "gh: Auto merge is not allowed for this repository"}}})

    for status <- [
          [merge_state: "CLEAN", checks: [check("SUCCESS"), check("FAILURE")]],
          [merge_state: "CLEAN", checks: [%{name: "make-all", status: "IN_PROGRESS", conclusion: nil}]],
          [merge_state: "UNSTABLE", checks: []],
          [merge_state: "BEHIND", checks: [check("SUCCESS")]],
          [merge_state: "CLEAN", state: "CLOSED", checks: []],
          [merge_state: "CLEAN", commit_sha: "head-2", checks: []],
          {:error, :timeout}
        ] do
      RunStore.delete_pr_review(@repo_key, @issue_id)
      put_run!(now)
      track([issue("Merging")])
      activity(head: "head-1", merge_state: "CLEAN")
      ci_status(status)

      log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(now) end)

      refute_received {:squash_merge, _url, _request}
      assert_received {:issue_comment, @issue_id, comment}
      assert comment =~ "enabling auto-merge failed: gh: Auto merge is not allowed for this repository"
      assert log =~ "fell back to the landing agent"
    end
  end

  test "a BEHIND PR gets one update-branch per head and lands once the new head is green" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BEHIND")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "updating_branch"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
    assert_received {:update_branch, @pr_url, "head-1"}
    assert AutoMerge.describe(PrReviewPoller.auto_merge(@issue_id)) == "updating branch (`head-1` is behind the base branch)"

    # GitHub hasn't moved the head yet: no second call for head-1.
    activity(head: "head-1", merge_state: "BEHIND", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "updating_branch"}]}} = poll(DateTime.add(now, 30))
    refute_received {:update_branch, _url, _head}

    # The merge commit is the new head; CI runs on it with auto-merge still on.
    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 60))
    refute_received {:enable_auto_merge, _url, _request}
    refute_received {:update_branch, _url, _head}
    assert %{state: "enabled", head_sha: "head-2", update_branch_head_sha: "head-1"} = PrReviewPoller.auto_merge(@issue_id)

    activity(head: "head-2", state: "MERGED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 90))
    assert_received {:issue_state_update, @issue_id, "Done"}
  end

  test "a failed update-branch is retried on the next poll" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BEHIND", auto_merge_enabled: true)
    replies(%{update_branch: {:error, {:gh_failed, ["api"], 1, "expected head sha didn't match current head ref (HTTP 422)"}}})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now) end)

    assert log =~ "Auto-merge update-branch failed for ACME-1780 commit_sha=head-1"
    assert %{update_branch_head_sha: nil, reason: "updating the branch failed: " <> _} = PrReviewPoller.auto_merge(@issue_id)

    replies(%{})
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "updating_branch"}]}} = poll(DateTime.add(now, 30))
    assert_received {:update_branch, @pr_url, "head-1"}
    assert_received {:update_branch, @pr_url, "head-1"}
  end

  test "a CONFLICTING PR has auto-merge turned off before the conflict-fix run, and lands only after a fresh approval" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    activity(head: "head-1", mergeable: "CONFLICTING", merge_state: "DIRTY", auto_merge_enabled: true)

    log = capture_log(fn -> assert {:ok, %{actions: [{:state_transitioned, @issue_id, :conflict, "In Progress"}]}} = poll(DateTime.add(now, 30)) end)

    # Auto-merge goes off, and the ticket hears why, before the move to In Progress dispatches the fix run.
    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert comment =~ "turned off GitHub auto-merge on #{@pr_url} because it conflicts with the base branch"
    assert comment =~ "moving this ticket to Merging again turns auto-merge back on"
    assert log =~ "Auto-merge ACME-1780: turned GitHub auto-merge off because the PR conflicts with the base branch"
    assert log =~ "Auto-merge ACME-1780: blocked: conflict on `head-1`; auto-merge off until the fix is approved again"
    assert %{head_sha: "head-1", conflict_key: "head-1|base-1"} = PrReviewPoller.pending_pr_conflict(@issue_id)
    assert %{state: "conflict", enabled_head_sha: nil, disabled_at: disabled_at} = PrReviewPoller.auto_merge(@issue_id)
    assert DateTime.compare(disabled_at, DateTime.add(now, 30)) == :eq

    assert [%{"reason" => "conflict", "head_sha" => "head-1", "pr_url" => @pr_url, "issue_identifier" => "ACME-1780"}] =
             audit_events("auto_merge_disabled")

    # The fix run pushes head-2, CI goes green and the ticket is back in review: nothing turns auto-merge on.
    track([issue("In Review")])
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 60))
    assert mailbox() == []

    # A fresh approval into Merging turns it on again for the reviewed head.
    track([issue("Merging")])
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 90))
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}
    assert %{state: "enabled", enabled_head_sha: "head-2", disabled_at: nil} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "a conflicting Merging PR with auto-merge already off gets no disable call or comment" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", mergeable: "CONFLICTING", merge_state: "DIRTY")

    assert {:ok, %{actions: [{:state_transitioned, @issue_id, :conflict, "In Progress"}]}} = poll(now)
    assert [{:issue_state_update, @issue_id, "In Progress"}] = mailbox()
    assert %{state: "conflict", disabled_at: nil} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("auto_merge_disabled") == []
  end

  test "while auto-merge can't be turned off the conflict-fix run waits, and a failed comment doesn't hold it" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", mergeable: "CONFLICTING", merge_state: "DIRTY", auto_merge_enabled: true)
    replies(%{disable_auto_merge: {:error, :forbidden}})

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:poll_error, @issue_id, {:disable_auto_merge_failed, :forbidden}}]}} = poll(now)
      end)

    assert [{:disable_auto_merge, @pr_url, "PR_node"}] = mailbox()
    assert log =~ "turning GitHub auto-merge off for the merge conflict failed; the conflict fix waits until it is off"
    assert PrReviewPoller.pending_pr_conflict(@issue_id) == nil

    replies(%{})
    Application.put_env(:symphony_elixir, :auto_merge_test_comment_result, {:error, :linear_down})

    log = capture_log(fn -> assert {:ok, %{actions: [{:state_transitioned, @issue_id, :conflict, "In Progress"}]}} = poll(DateTime.add(now, 30)) end)

    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, _comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert log =~ "Failed to comment that auto-merge was turned off for a conflict"
  end

  test "an update-branch conflict turns off the auto-merge this poll turned on, then goes to In Progress" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BEHIND")
    replies(%{update_branch: {:error, :conflict}})

    assert {:ok, %{actions: [{:state_transitioned, @issue_id, :conflict, "In Progress"}]}} = poll(now)

    assert [
             {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}},
             {:update_branch, @pr_url, "head-1"},
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, _comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert %{mergeable: "CONFLICTING", conflict_key: "head-1|base-1"} = PrReviewPoller.pending_pr_conflict(@issue_id)
    assert %{state: "conflict", update_branch_head_sha: "head-1", enabled_head_sha: nil} = PrReviewPoller.auto_merge(@issue_id)

    # The fix run owns it now: the poller only watches.
    track([issue("In Progress")])
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 30))
    assert mailbox() == []
  end

  test "a red head takes the CI-fix path with auto-merge still on and lands after the fix" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    Application.put_env(:symphony_elixir, :auto_merge_test_ci_status, %{
      pr_url: @pr_url,
      state: "OPEN",
      commit_sha: "head-1",
      checks: [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]
    })

    assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 10))

    assert_received {:issue_state_update, @issue_id, "In Progress"}

    # The fix run pushes head-2 and the issue is back in review; auto-merge stays on and is not touched.
    track([issue("In Review")])
    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 60))
    refute_received {:enable_auto_merge, _url, _request}
    assert %{state: "enabled"} = PrReviewPoller.auto_merge(@issue_id)

    activity(head: "head-2", state: "MERGED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 90))
    assert_received {:issue_state_update, @issue_id, "Done"}
  end

  test "when auto-merge can't be enabled the landing agent takes over, with the reason logged and commented" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "BLOCKED")
    ci_status(merge_state: "BLOCKED", checks: [check("SUCCESS")])

    replies(%{
      enable_auto_merge: {:error, {:gh_failed, ["api", "graphql"], 1, "gh: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)\n"}}
    })

    assert AutoMerge.owns_issue?(merging)

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(now) end)

    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
    assert log =~ "[error] Auto-merge ACME-1780: fell back to the landing agent: enabling auto-merge failed: gh: Auto merge is not allowed for this repository"
    assert_received {:issue_comment, @issue_id, comment}
    assert comment =~ "Symphony couldn't land #{@pr_url} with GitHub auto-merge (enabling auto-merge failed: gh: Auto merge is not allowed"
    assert comment =~ "so a landing agent will merge it instead."
    refute AutoMerge.owns_issue?(merging)

    # It stays with the landing agent, even across its own pushes, while the issue is in Merging.
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(DateTime.add(now, 30))
    refute_received {:enable_auto_merge, _url, _request}
    refute_received {:issue_comment, _issue_id, _body}

    # Once it leaves Merging, the next approval tries auto-merge again.
    track([issue("In Review")])
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 60))
    assert PrReviewPoller.auto_merge(@issue_id) == nil
  end

  test "a failed squash merge or fallback comment still falls back" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "CLEAN")
    ci_status(merge_state: "CLEAN", checks: [])
    replies(%{enable_auto_merge: {:error, :clean_status}, squash_merge: {:error, :timeout}})
    Application.put_env(:symphony_elixir, :auto_merge_test_comment_result, {:error, :linear_down})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(now) end)

    assert log =~ "squash merge failed: :timeout"
    assert log =~ "Failed to comment the auto-merge fallback issue_id=#{@issue_id}: :linear_down"
  end

  test "auto-merge on, green head, still BLOCKED past the landing wait falls back" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, merging_wait_timeout_ms: 60_000})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED", auto_merge_enabled: true)

    :ok = put_observed_ci!("SUCCESS")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert %{stalled_since: ^now} = PrReviewPoller.auto_merge(@issue_id)

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(DateTime.add(now, 61))
    assert_received {:issue_comment, @issue_id, comment}
    assert comment =~ "GitHub still reports BLOCKED on green `head-1` after 1 min; a required check may never report"
  end

  test "a pending head is not a stall" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, merging_wait_timeout_ms: 60_000})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED", auto_merge_enabled: true)

    :ok = put_observed_ci!("IN_PROGRESS")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 120))
    assert %{stalled_since: nil} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "a PR without a head or node id waits" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    Application.put_env(:symphony_elixir, :auto_merge_test_activity, Map.put(activity_map(head: "head-1"), :pr_node_id, nil))

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "waiting"}]}} = poll(now)
    assert AutoMerge.describe(PrReviewPoller.auto_merge(@issue_id)) == "waiting for the PR head"
    refute_received {:enable_auto_merge, _url, _request}
  end

  test "moving the issue to Done can fail and is retried on the next poll" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", state: "MERGED")
    Application.put_env(:symphony_elixir, :auto_merge_test_state_result, {:error, :linear_down})

    assert {:ok, %{actions: [{:state_transition_error, @issue_id, :done, :linear_down}]}} = poll(now)
    assert [%{status: "state_transition_error"}] = RunStore.list_pr_reviews(@repo_key)
  end

  test "a merged PR auto-merge never handled keeps the plain cleanup" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("In Review")])
    activity(head: "head-1", state: "MERGED")

    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(now)
    refute_received {:issue_state_update, _issue_id, _state}
  end

  test "a Merging PR with no run on record is still watched and landed" do
    now = ~U[2026-10-03 12:00:00Z]
    merging = issue("Merging")
    track([merging, %{issue("In Review") | id: "issue-no-run", pr_urls: ["https://github.com/example/repo/pull/9"]}])
    activity(head: "head-1", merge_state: "BLOCKED")

    assert AutoMerge.owns_issue?(merging)

    capture_log(fn -> assert {:ok, %{discovered: 1, actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now) end)

    assert_received {:enable_auto_merge, @pr_url, _request}
    assert [%{issue_id: @issue_id, workspace_path: nil}] = RunStore.list_pr_reviews(@repo_key)
    assert AutoMerge.owns_issue?(merging)

    activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)

    capture_log(fn -> assert {:ok, %{discovered: 0, actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 60)) end)

    assert_received {:issue_state_update, @issue_id, "Done"}
    assert RunStore.list_pr_reviews(@repo_key) == []
  end

  test "with auto-merge off, Merging issues are not watched and the landing agent owns them" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(pr_review_auto_merge: false)
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "BLOCKED")

    assert {:ok, %{discovered: 0, actions: []}} = poll(now)
    refute AutoMerge.owns_issue?(merging)
    refute AutoMerge.owns_issue?(%{merging | pr_urls: []})
    refute AutoMerge.owns_issue?(%{merging | repo_key: "missing-repo"})
  end

  test "each repository's poll lands only its own Merging issues" do
    now = ~U[2026-10-03 12:00:00Z]
    other_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "OTHER_WORKFLOW.md")
    File.write!(other_workflow, "Other repository.\n")

    write_auto_merge_workflow!(
      repos: [
        %{key: @repo_key, workflow: Workflow.workflow_file_path(), default: true, team: "Test"},
        %{key: "other", workflow: other_workflow, team: "Other"}
      ]
    )

    other = %{issue("Merging") | repo_key: "other"}
    track([other])
    activity(head: "head-1", merge_state: "BLOCKED")

    assert {:ok, %{discovered: 0, actions: []}} = poll(now, repo_key: @repo_key)
    refute_received {:enable_auto_merge, _pr_url, _request}

    # Polling every repository adopts and lands the PR once, under its own repository.
    capture_log(fn -> assert {:ok, %{discovered: 1, actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now) end)
    assert_received {:enable_auto_merge, @pr_url, _request}
    refute_received {:enable_auto_merge, _pr_url, _request}
    assert RunStore.list_pr_reviews(@repo_key) == []
    assert [%{issue_id: @issue_id}] = RunStore.list_pr_reviews("other")

    # An issue without a repo_key belongs to the primary repository.
    :ok = RunStore.delete_pr_review("other", @issue_id)
    track([%{other | repo_key: nil}])
    assert {:ok, %{discovered: 0}} = poll(now, repo_key: "other")
    capture_log(fn -> assert {:ok, %{discovered: 1}} = poll(now, repo_key: @repo_key) end)
    assert [%{issue_id: @issue_id}] = RunStore.list_pr_reviews(@repo_key)
  end

  test "status helpers" do
    now = ~U[2026-10-03 12:00:00Z]

    assert AutoMerge.describe(%{state: "fallback", reason: "nope"}) == "fell back to the landing agent: nope"
    assert AutoMerge.describe(%{state: "conflict", head_sha: nil}) == "blocked: conflict on an unknown head"
    assert AutoMerge.conflict_comment(nil) =~ "turned off GitHub auto-merge on this PR"

    # GitHub shows auto-merge on, but the activity has no PR node id to turn it off with.
    assert {:error, :missing_pr_node_id} =
             AutoMerge.disable_for_conflict(%{}, %{auto_merge_enabled: true}, AutoMerge.conflict(nil, "h", now), [], now)

    assert AutoMerge.describe(nil) == nil
    assert AutoMerge.fallback_comment(nil, %{reason: "nope"}) =~ "couldn't land this PR"
    assert %{state: "merged", head_sha: nil} = AutoMerge.merged(nil, now)
    assert %{state: "conflict", head_sha: "h"} = AutoMerge.conflict(%{state: "enabled", head_sha: "h"}, "h", now)
    refute AutoMerge.merging?(nil)
    refute AutoMerge.merging?(%Issue{state: nil})
    refute AutoMerge.enabled?(%{})
    assert :ok = AutoMerge.log_transition(%{}, %{state: "enabled", head_sha: "h"}, %{state: "enabled", head_sha: "h"})
    assert :ok = AutoMerge.log_transition(%{}, nil, %{state: nil, head_sha: "h"})

    assert {:fallback, %{reason: reason}} =
             AutoMerge.step(
               %{issue_id: "x"},
               activity_map(head: "h"),
               %{ci: %{merging_wait_timeout_ms: 1}},
               [github: __MODULE__.LongErrorGitHub],
               now
             )

    # GitHub hasn't computed the merge state yet.
    assert {:ok, %{state: "enabled", stalled_since: nil}} =
             AutoMerge.step(
               %{issue_id: "x"},
               %{activity_map(head: "h") | merge_state_status: nil},
               %{ci: %{merging_wait_timeout_ms: 1}},
               [github: __MODULE__.OkGitHub],
               now
             )

    assert String.length(reason) == 301
    assert String.ends_with?(reason, "…")
  end

  defmodule OkGitHub do
    @spec enable_auto_merge(String.t(), map(), keyword()) :: :ok
    def enable_auto_merge(_pr_url, _request, _opts), do: :ok
  end

  defmodule LongErrorGitHub do
    @spec enable_auto_merge(String.t(), map(), keyword()) :: {:error, term()}
    def enable_auto_merge(_pr_url, _request, _opts), do: {:error, String.duplicate("x", 400)}

    @spec fetch_ci_status(String.t(), keyword()) :: {:error, term()}
    def fetch_ci_status(_pr_url, _opts), do: {:error, :timeout}
  end

  defp poll(now, opts \\ []),
    do: PrReviewPoller.poll_once([tracker: FakeTracker, github: FakeGitHub, now: now, current_gh_user: "operator"] ++ opts)

  defp write_auto_merge_workflow!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [tracker_kind: "memory", pr_review_mode: "polling", pr_review_cooldown_minutes: 1, pr_review_stale_days: 7],
        overrides
      )
    )
  end

  defp put_run!(now) do
    :ok =
      RunStore.put_run(%{
        repo_key: @repo_key,
        run_id: "run-1780",
        issue_id: @issue_id,
        issue_identifier: "ACME-1780",
        status: "success",
        workspace_path: Path.join(System.tmp_dir!(), "auto-merge-missing-workspace"),
        worker_host: nil,
        started_at: DateTime.add(now, -600, :second),
        ended_at: DateTime.add(now, -300, :second)
      })
  end

  defp put_observed_ci!(conclusion) do
    RunStore.put_ci_check(%{
      repo_key: @repo_key,
      issue_id: @issue_id,
      last_observed_sha: "head-1",
      last_observed_conclusion: conclusion
    })
  end

  defp mailbox do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.each(messages, fn message -> receive do: (^message -> :ok) end)
    messages
  end

  defp audit_events(event_type) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: event_type)
    Enum.filter(events, &(&1["issue_id"] == @issue_id))
  end

  defp track(issues), do: Application.put_env(:symphony_elixir, :auto_merge_test_issues, issues)
  defp replies(replies), do: Application.put_env(:symphony_elixir, :auto_merge_test_replies, replies)

  defp issue(state) do
    %Issue{
      id: @issue_id,
      identifier: "ACME-1780",
      title: "Ship it",
      state: state,
      url: "https://linear.app/example/issue/ACME-1780",
      pr_urls: [@pr_url],
      updated_at: ~U[2026-10-03 11:00:00Z]
    }
  end

  defp ci_status({:error, _reason} = error), do: Application.put_env(:symphony_elixir, :auto_merge_test_ci_status, error)

  defp ci_status(opts) do
    Application.put_env(:symphony_elixir, :auto_merge_test_ci_status, %{
      pr_url: @pr_url,
      pr_title: "Ship it",
      state: Keyword.get(opts, :state, "OPEN"),
      commit_sha: Keyword.get(opts, :commit_sha, "head-1"),
      mergeable: "MERGEABLE",
      merge_state_status: Keyword.fetch!(opts, :merge_state),
      base_ref_name: "main",
      checks: Keyword.fetch!(opts, :checks)
    })
  end

  defp check(conclusion), do: %{name: "make-all-#{conclusion}", status: "COMPLETED", conclusion: conclusion}

  defp activity(opts), do: Application.put_env(:symphony_elixir, :auto_merge_test_activity, activity_map(opts))

  defp activity_map(opts) do
    %{
      pr_url: @pr_url,
      pr_number: 1780,
      pr_title: "Ship it",
      pr_description: "PR body",
      pr_node_id: "PR_node",
      state: Keyword.get(opts, :state, "OPEN"),
      review_decision: nil,
      mergeable: Keyword.get(opts, :mergeable, "MERGEABLE"),
      merge_state_status: Keyword.get(opts, :merge_state, "BLOCKED"),
      auto_merge_enabled: Keyword.get(opts, :auto_merge_enabled, false),
      head_ref_name: "auto/ACME-1780",
      head_ref_oid: Keyword.fetch!(opts, :head),
      base_ref_name: "main",
      base_ref_oid: "base-1",
      is_cross_repository: false,
      latest_activity_at: ~U[2026-10-03 11:00:00Z],
      latest_review_activity_at: ~U[2026-10-03 11:00:00Z],
      comments: []
    }
  end
end
