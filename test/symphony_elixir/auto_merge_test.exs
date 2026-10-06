defmodule SymphonyElixir.AutoMergeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AutoMerge, AutoReview, CiPoller, PrReviewPoller, SubIssueWait}
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

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
    def fetch_issue_states_by_ids(issue_ids) do
      send(recipient(), {:fetch_issue_states_by_ids, issue_ids})

      case Application.get_env(:symphony_elixir, :auto_merge_test_fetch_result) do
        nil -> {:ok, Enum.filter(Application.get_env(:symphony_elixir, :auto_merge_test_issues, []), &(&1.id in issue_ids))}
        result -> result
      end
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name) do
      send(recipient(), {:issue_state_update, issue_id, state_name})

      case Application.get_env(:symphony_elixir, :auto_merge_test_state_result, :ok) do
        %{} = results -> Map.get(results, issue_id, :ok)
        result -> result
      end
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

    @spec rerun_failed(String.t(), keyword()) :: :ok | {:error, term()}
    def rerun_failed(run_id, _opts), do: reply(:rerun_failed, {:rerun_failed, run_id})

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

  defmodule FakeGateRunner do
    @spec request(map(), keyword()) :: :started
    def request(job, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :auto_merge_test_recipient), {:gate_request, job.sha})
      :started
    end
  end

  @spec fake_fingerprint(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fake_fingerprint(_record, head) do
    send(Application.fetch_env!(:symphony_elixir, :auto_merge_test_recipient), {:fingerprint, head})

    case :symphony_elixir |> Application.get_env(:auto_merge_test_fingerprints, %{}) |> Map.fetch(head) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, fingerprint} -> {:ok, fingerprint}
      :error -> {:error, :unknown_head}
    end
  end

  setup do
    on_exit(fn ->
      for key <- [
            :auto_merge_test_fingerprints,
            :auto_merge_test_issues,
            :auto_merge_test_activity,
            :auto_merge_test_ci_status,
            :auto_merge_test_recipient,
            :auto_merge_test_replies,
            :auto_merge_test_state_result,
            :auto_merge_test_fetch_result,
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

  test "an issue the acceptance gate approved in enforce mode gets auto-merge on the next poll" do
    write_auto_merge_workflow!(ci: %{enabled: true}, auto_review: %{enabled: true, acceptance_gate: %{mode: "enforce"}})
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)

    record = %{repo_key: @repo_key, issue_id: @issue_id, pr_url: @pr_url, qa_sha: "head-1", qa_verdict: "pass"}
    record = Map.merge(record, %{qa_target_state: "In Review", gate_sha: "head-1", gate_verdict: "approve"})
    :ok = RunStore.put_ci_check(record)

    assert {:auto_review_gate, @issue_id, "approve", "Merging"} =
             AutoReview.on_green(issue("Auto Review"), record, %{commit_sha: "head-1"}, Config.settings!(), tracker: FakeTracker)

    assert_received {:issue_state_update, @issue_id, "Merging"}

    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")

    capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now) end)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
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

  test "a refused PR that is UNSTABLE only for a stale check is squash-merged directly" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "UNSTABLE")
    # `server-test` still read in progress in a workflow run that completed; the CI read counts it finished.
    stale = %{name: "server-test", status: "COMPLETED", conclusion: "SUCCESS", stale: true}
    ci_status(merge_state: "UNSTABLE", checks: [check("SUCCESS"), stale])
    replies(%{enable_auto_merge: {:error, {:gh_failed, ["api", "graphql"], 1, "gh: Protected branch rules not configured for this branch"}}})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "merging"}]}} = poll(now) end)

    assert_received {:squash_merge, @pr_url, %{head_sha: "head-1"}}
    assert log =~ "squash-merging the clean PR directly"
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
          [merge_state: "UNSTABLE", checks: [check("SUCCESS")]],
          [merge_state: "UNSTABLE", checks: [%{name: "server-test", status: "COMPLETED", conclusion: "FAILURE", stale: true}]],
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

  test "a head that moved under the enable call is retried with the new head, not handed to the landing agent" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    merging = issue("Merging")
    track([merging])
    activity(head: "head-1", merge_state: "BEHIND")
    # The re-read in the refused path would see the new head and fall back: it must not run.
    ci_status(merge_state: "BLOCKED", commit_sha: "head-2", checks: [])
    replies(%{enable_auto_merge: {:error, :head_moved}})

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "waiting"}]}} = poll(now) end)

    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
    # Nothing else acts on the stale head this poll.
    refute_received {:update_branch, _url, _head}
    assert log =~ "Auto-merge ACME-1780: the PR head moved from `head-1` before auto-merge could be enabled; retrying on the next poll commit_sha=head-1"

    assert %{state: "waiting", enabled_head_sha: nil, head_moved_retries: 1, reason: "the PR head moved from `head-1` before auto-merge could be enabled"} =
             PrReviewPoller.auto_merge(@issue_id)

    assert AutoMerge.owns_issue?(merging)

    replies(%{})
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 30))
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}
    assert %{state: "enabled", enabled_head_sha: "head-2", head_moved_retries: 0, reason: nil} = PrReviewPoller.auto_merge(@issue_id)
    assert AutoMerge.owns_issue?(merging)
    refute_received {:issue_comment, @issue_id, _body}
  end

  test "a head that keeps moving under the enable call falls back after three tries in a row" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    replies(%{enable_auto_merge: {:error, :head_moved}})

    for {head, offset} <- [{"head-1", 0}, {"head-2", 30}] do
      activity(head: head, merge_state: "BLOCKED")
      capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "waiting"}]}} = poll(DateTime.add(now, offset)) end)
    end

    activity(head: "head-3", merge_state: "BLOCKED")
    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = poll(DateTime.add(now, 60)) end)

    assert log =~ "fell back to the landing agent: the PR head moved 3 times in a row before auto-merge could be enabled"
    assert_received {:issue_comment, @issue_id, comment}
    assert comment =~ "the PR head moved 3 times in a row"
    assert %{state: "fallback", head_moved_retries: 3} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "a PR GitHub already shows auto-merge on for is recorded as enabled without an enable call" do
    now = ~U[2026-10-03 12:00:00Z]
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED", auto_merge_enabled: true)

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)

    refute_received {:enable_auto_merge, _url, _request}
    assert %{state: "enabled", enabled_head_sha: "head-1", head_moved_retries: 0} = PrReviewPoller.auto_merge(@issue_id)
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

  test "a red head has auto-merge turned off before the CI-fix run, and lands only after a fresh approval" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    red_ci_status(auto_merge_enabled: true)

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} = ci_poll(DateTime.add(now, 10))
      end)

    # Auto-merge goes off, and the ticket hears why, before the move to In Progress dispatches the fix run.
    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert comment =~ "turned off GitHub auto-merge on #{@pr_url} because CI failed and a fix run may push new code"
    assert comment =~ "moving this ticket to Merging again turns auto-merge back on"
    assert log =~ "Auto-merge ACME-1780: turned GitHub auto-merge off because CI failed; the fix goes back through review"
    assert log =~ "Auto-merge ACME-1780: auto-merge off: CI failed on `head-1`; the fix goes back through review"

    assert %{state: "ci_failure", head_sha: "head-1", enabled_head_sha: nil, disabled_at: disabled_at} =
             PrReviewPoller.auto_merge(@issue_id)

    assert DateTime.compare(disabled_at, DateTime.add(now, 10)) == :eq

    assert [%{"reason" => "ci_failure", "head_sha" => "head-1", "pr_url" => @pr_url, "issue_identifier" => "ACME-1780"}] =
             audit_events("auto_merge_disabled")

    # A PR poll that still sees the issue in Merging, even at the fix's new head, leaves auto-merge off.
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "ci_failure"}]}} = poll(DateTime.add(now, 20))
    assert mailbox() == []

    # The fix run pushed head-2, CI goes green and the ticket is back in review: nothing turns auto-merge on.
    track([issue("In Review")])
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 60))
    assert mailbox() == []
    assert PrReviewPoller.auto_merge(@issue_id) == nil

    # A fresh approval into Merging turns it on again for the reviewed head, and it lands.
    track([issue("Merging")])
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 90))
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}

    activity(head: "head-2", state: "MERGED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 120))
    assert_received {:issue_state_update, @issue_id, "Done"}
  end

  test "a CI fix on an approved PR is marked approved, and dropping its hold turns auto-merge on again at the same head" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    # Dropping the hold leaves auto-merge that is not held alone.
    PrReviewPoller.release_auto_merge_hold(@issue_id)
    assert %{state: "enabled"} = PrReviewPoller.auto_merge(@issue_id)

    red_ci_status(auto_merge_enabled: true)

    capture_log(fn ->
      assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} = ci_poll(DateTime.add(now, 10))
    end)

    mailbox()
    assert %{approved: true, commit_sha: "head-1"} = CiPoller.pending_ci_failure(@issue_id)

    # The fix run found a flake and pushed nothing. Back in Merging before the PR poller saw it
    # leave, the hold would keep auto-merge off.
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "ci_failure"}]}} = poll(DateTime.add(now, 20))
    assert mailbox() == []

    # The run drops the hold as it moves the issue back, so the next poll turns auto-merge on.
    PrReviewPoller.release_auto_merge_hold(@issue_id)
    assert PrReviewPoller.auto_merge(@issue_id) == nil
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 60))
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    # An issue with no PR review record has no hold to drop.
    assert :ok = PrReviewPoller.release_auto_merge_hold("issue-without-review")
  end

  test "a CI-fix hold that can't be dropped is logged, and auto-merge stays off" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    red_ci_status(auto_merge_enabled: false)
    assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} = ci_poll(DateTime.add(now, 10))

    failing_store = [run_store: __MODULE__.HoldFailingRunStore]
    log = capture_log(fn -> assert :ok = PrReviewPoller.release_auto_merge_hold(@issue_id, failing_store) end)

    assert log =~ "Failed to drop the CI-fix auto-merge hold issue_id=#{@issue_id}: :write_failed"
    assert %{state: "ci_failure"} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "a flaky rerun of the same commit keeps auto-merge on" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: true})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    red_ci_status(auto_merge_enabled: true, run_id: "987")

    assert {:ok, %{actions: [{:rerun_requested, @issue_id, "987"}]}} = ci_poll(DateTime.add(now, 10))
    assert [{:rerun_failed, "987"}] = mailbox()
    assert %{state: "enabled", enabled_head_sha: "head-1", disabled_at: nil} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("auto_merge_disabled") == []
  end

  test "with auto-merge already off the CI fix still holds it off until a fresh approval, even at the same head" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    # Someone turned it off on GitHub: no disable call or comment, but the hold is recorded.
    red_ci_status(auto_merge_enabled: false)
    assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} = ci_poll(DateTime.add(now, 10))
    assert [{:issue_state_update, @issue_id, "In Progress"}] = mailbox()
    assert %{state: "ci_failure", enabled_head_sha: nil, disabled_at: nil} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("auto_merge_disabled") == []

    # The fix run found nothing to push; the ticket goes back through review at the same head.
    track([issue("In Review")])
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = poll(DateTime.add(now, 60))
    track([issue("Merging")])
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 90))
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}
  end

  test "while the hold can't be stored the CI-fix run waits" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(now)
    assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}

    red_ci_status(auto_merge_enabled: false)

    assert {:ok, %{actions: [{:poll_error, @issue_id, {:auto_merge_hold_failed, :write_failed}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, run_store: __MODULE__.HoldFailingRunStore, now: DateTime.add(now, 10))

    assert mailbox() == []
    assert %{state: "enabled"} = PrReviewPoller.auto_merge(@issue_id)
    assert CiPoller.pending_ci_failure(@issue_id) == nil
  end

  test "while auto-merge can't be turned off the CI-fix run waits, and a failed comment doesn't hold it" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true, flaky_retry: false})
    put_run!(now)
    track([issue("Merging")])
    red_ci_status(auto_merge_enabled: true)
    replies(%{disable_auto_merge: {:error, :forbidden}})

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:poll_error, @issue_id, {:disable_auto_merge_failed, :forbidden}}]}} = ci_poll(now)
      end)

    assert [{:disable_auto_merge, @pr_url, "PR_node"}] = mailbox()
    assert log =~ "turning GitHub auto-merge off for the CI fix failed; the fix waits until it is off"
    assert CiPoller.pending_ci_failure(@issue_id) == nil

    replies(%{})
    Application.put_env(:symphony_elixir, :auto_merge_test_comment_result, {:error, :linear_down})

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} =
                 ci_poll(DateTime.add(now, 600))
      end)

    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, _comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert log =~ "Failed to comment that auto-merge was turned off for a CI fix"
  end

  test "in enforce mode a push that changes the approved diff turns auto-merge off and goes back through the gate before it lands" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")

    # The first poll in Merging records what was approved.
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)
    assert [{:fingerprint, "head-1"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}] = mailbox()
    assert %{approved_head_sha: "head-1", approved_fingerprint: "diff-a"} = PrReviewPoller.auto_merge(@issue_id)

    # The same head needs no new fingerprint.
    activity(head: "head-1", merge_state: "BLOCKED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 30))
    assert mailbox() == []

    # A CI fix (or a landing agent's or a human's commit) changes the diff while auto-merge is on.
    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 60))
      end)

    assert [
             {:fingerprint, "head-2"},
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_state_update, @issue_id, "Auto Review"},
             {:issue_comment, @issue_id, comment}
           ] = mailbox()

    assert comment =~ "turned off GitHub auto-merge on #{@pr_url} and moved this ticket back to Auto Review: `head-2` changes the diff approved at `head-1`"
    assert comment =~ "the gate's approve moves this ticket back to Merging"
    assert log =~ "Auto-merge ACME-1780: turned GitHub auto-merge off because `head-2` changes the diff approved at `head-1`"
    assert log =~ "Acceptance gate re-review for ACME-1780: `head-2` changes the diff approved at `head-1`; moved to Auto Review"

    assert %{state: "rereview", head_sha: "head-2", approved_head_sha: "head-1", enabled_head_sha: nil, disabled_at: %DateTime{}} =
             PrReviewPoller.auto_merge(@issue_id)

    assert AutoMerge.describe(PrReviewPoller.auto_merge(@issue_id)) ==
             "auto-merge off: `head-2` changed the approved diff; back in Auto Review for the acceptance gate"

    assert [%{"old_head_sha" => "head-1", "new_head_sha" => "head-2", "auto_merge_disabled" => true, "pr_url" => @pr_url, "issue_identifier" => "ACME-1780"}] =
             audit_events("acceptance_gate_rereview")

    # In Auto Review nothing turns auto-merge on, and the approval of the last stay is dropped.
    track([issue("Auto Review")])
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = enforce_poll(DateTime.add(now, 90))
    assert mailbox() == []
    assert %{state: "rereview", approved_head_sha: nil, approved_fingerprint: nil} = PrReviewPoller.auto_merge(@issue_id)

    # Green CI on the new head (QA passed) asks the gate to judge it.
    record = qa_passed("head-2")
    :ok = RunStore.put_ci_check(record)

    assert {:gate_started, @issue_id, "head-2"} =
             green_in_auto_review(record, "head-2", gate_runner: FakeGateRunner)

    assert [{:gate_request, "head-2"}] = mailbox()

    # The gate approves: back to Merging with no human move, and auto-merge comes back on for the judged head.
    record = Map.merge(record, %{gate_sha: "head-2", gate_verdict: "approve"})
    :ok = RunStore.put_ci_check(record)

    assert {:auto_review_gate, @issue_id, "approve", "Merging"} = green_in_auto_review(record, "head-2")

    assert [{:issue_state_update, @issue_id, "Merging"}] = mailbox()

    track([issue("Merging")])
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 120))
    assert [{:fingerprint, "head-2"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}] = mailbox()

    assert %{state: "enabled", approved_head_sha: "head-2", approved_fingerprint: "diff-b", reason: nil} =
             PrReviewPoller.auto_merge(@issue_id)

    activity(head: "head-2", state: "MERGED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = enforce_poll(DateTime.add(now, 150))
    assert_received {:issue_state_update, @issue_id, "Done"}
    assert length(audit_events("acceptance_gate_rereview")) == 1
  end

  test "in enforce mode Symphony's own update-branch merge of the base keeps the approval and auto-merge" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "merge-1" => "diff-a"})
    activity(head: "head-1", merge_state: "BEHIND")

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "updating_branch"}]}} = enforce_poll(now)
    assert [{:fingerprint, "head-1"}, {:enable_auto_merge, @pr_url, _request}, {:update_branch, @pr_url, "head-1"}] = mailbox()

    # GitHub merged the base in: a new head with the same PR diff.
    activity(head: "merge-1", merge_state: "BLOCKED", auto_merge_enabled: true)

    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 30)) end)

    assert [{:fingerprint, "merge-1"}] = mailbox()
    assert log =~ "Auto-merge ACME-1780: `merge-1` keeps the approved diff of `head-1`; auto-merge stays on"
    assert %{state: "enabled", approved_head_sha: "merge-1", approved_fingerprint: "diff-a"} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("acceptance_gate_rereview") == []
  end

  test "in enforce mode a red head's CI fix goes through the gate before it can merge" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)
    mailbox()

    red_ci_status(auto_merge_enabled: true)
    capture_log(fn -> assert {:ok, %{actions: [{:state_transitioned, @issue_id, :ci_failure, "In Progress"}]}} = ci_poll(DateTime.add(now, 10)) end)

    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert comment =~ "the acceptance gate judges it in Auto Review, and its approve moves this ticket back to Merging and turns auto-merge back on"
    refute comment =~ "moving this ticket to Merging again"

    # The fix run pushed head-2 and ended in Auto Review: green CI asks the gate, nothing turns auto-merge on.
    track([issue("Auto Review")])
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:watching, @issue_id}]}} = enforce_poll(DateTime.add(now, 60))
    assert mailbox() == []

    record = qa_passed("head-2")

    assert {:gate_started, @issue_id, "head-2"} =
             green_in_auto_review(record, "head-2", gate_runner: FakeGateRunner)

    assert [{:gate_request, "head-2"}] = mailbox()

    # The gate's approve moved it to Merging: auto-merge comes back on for the judged head, with no re-review.
    track([issue("Merging")])
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 90))
    assert [{:fingerprint, "head-2"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}] = mailbox()
    assert audit_events("acceptance_gate_rereview") == []
  end

  test "in enforce mode a conflict fix returns to Merging on the gate's approve, with no human move" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)
    mailbox()

    activity(head: "head-1", mergeable: "CONFLICTING", merge_state: "DIRTY", auto_merge_enabled: true)
    capture_log(fn -> assert {:ok, %{actions: [{:state_transitioned, @issue_id, :conflict, "In Progress"}]}} = enforce_poll(DateTime.add(now, 30)) end)

    assert [
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_comment, @issue_id, comment},
             {:issue_state_update, @issue_id, "In Progress"}
           ] = mailbox()

    assert comment =~ "the acceptance gate judges it in Auto Review, and its approve moves this ticket back to Merging"
    assert %{state: "conflict", approved_head_sha: nil} = PrReviewPoller.auto_merge(@issue_id)

    # The fix run pushed head-2 and the gate approved it in Auto Review, which moved it to Merging.
    record = qa_passed("head-2")
    record = Map.merge(record, %{gate_sha: "head-2", gate_verdict: "approve"})
    :ok = RunStore.put_ci_check(record)

    assert {:auto_review_gate, @issue_id, "approve", "Merging"} = green_in_auto_review(record, "head-2")

    assert [{:issue_state_update, @issue_id, "Merging"}] = mailbox()

    # Straight back to Merging, even though no poll saw it outside: the fix is the approved diff now.
    track([issue("Merging")])
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 60))
    assert [{:fingerprint, "head-2"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-2"}}] = mailbox()
    assert %{approved_head_sha: "head-2", approved_fingerprint: "diff-b"} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("acceptance_gate_rereview") == []
  end

  test "in enforce mode a conflict that leaves the issue in Merging keeps the approval, so the fix pushed there is re-reviewed" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b", "head-3" => "diff-c"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)
    mailbox()

    # An agent run is active, so the conflict path doesn't move the issue out of Merging.
    agent_run!("running", now)
    activity(head: "head-1", mergeable: "CONFLICTING", merge_state: "DIRTY", auto_merge_enabled: true)
    capture_log(fn -> assert {:ok, %{actions: [{:active_run, @issue_id, :conflict}]}} = enforce_poll(DateTime.add(now, 30)) end)
    assert [{:disable_auto_merge, @pr_url, "PR_node"}, {:issue_comment, @issue_id, _comment}] = mailbox()
    assert %{state: "conflict", approved_head_sha: "head-1", approved_fingerprint: "diff-a"} = PrReviewPoller.auto_merge(@issue_id)

    # The fix lands while the issue is still in Merging: it goes back to Auto Review, auto-merge stays off.
    activity(head: "head-2", merge_state: "BLOCKED")
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 60)) end)
    assert [{:fingerprint, "head-2"}, {:issue_state_update, @issue_id, "Auto Review"}, {:issue_comment, @issue_id, _comment}] = mailbox()
    assert [%{"old_head_sha" => "head-1", "new_head_sha" => "head-2"}] = audit_events("acceptance_gate_rereview")

    # Past the retry limit the issue stays in Merging too.
    track([issue("Merging")])
    agent_run!("success", now)
    activity(head: "head-2", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 90))
    mailbox()
    :ok = RunStore.update_pr_review(@repo_key, @issue_id, %{conflict_retry_count: 3})

    activity(head: "head-2", mergeable: "CONFLICTING", merge_state: "DIRTY", auto_merge_enabled: true)
    capture_log(fn -> assert {:ok, %{actions: [{:conflict_escalated, @issue_id, 3}]}} = enforce_poll(DateTime.add(now, 120)) end)
    assert %{state: "conflict", approved_head_sha: "head-2", approved_fingerprint: "diff-b"} = PrReviewPoller.auto_merge(@issue_id)
    mailbox()

    activity(head: "head-3", merge_state: "BLOCKED")
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-3"}]}} = enforce_poll(DateTime.add(now, 150)) end)
    refute_received {:enable_auto_merge, _pr_url, _request}
  end

  test "in enforce mode a push between the gate's approve and the first Merging poll is re-reviewed" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    fingerprints(%{"head-2" => "diff-b", "head-3" => "diff-c"})

    # The gate approved head-2 and moved the issue to Merging.
    record = Map.merge(qa_passed("head-2"), %{gate_sha: "head-2", gate_verdict: "approve"})
    :ok = RunStore.put_ci_check(record)
    assert {:auto_review_gate, @issue_id, "approve", "Merging"} = green_in_auto_review(record, "head-2")
    mailbox()

    # head-3 landed before the PR poller saw the issue in Merging.
    track([issue("Merging")])
    activity(head: "head-3", merge_state: "BLOCKED")
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-3"}]}} = enforce_poll(DateTime.add(now, 30)) end)

    assert [
             {:fingerprint, "head-2"},
             {:fingerprint, "head-3"},
             {:issue_state_update, @issue_id, "Auto Review"},
             {:issue_comment, @issue_id, comment}
           ] = mailbox()

    assert comment =~ "`head-3` changes the diff approved at `head-2`"
    assert %{state: "rereview", approved_head_sha: "head-2", approved_fingerprint: "diff-b"} = PrReviewPoller.auto_merge(@issue_id)

    # The gate's verdict can't be read: the current head is approved, as for a person's move.
    track([issue("Merging")])
    activity(head: "head-3", merge_state: "BLOCKED")

    log =
      capture_log(fn ->
        opts = [fingerprint: &__MODULE__.fake_fingerprint/2, run_store: __MODULE__.CiChecksFailingRunStore]
        assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = poll(DateTime.add(now, 60), opts)
      end)

    assert log =~ "could not read the acceptance gate's verdict; the current head is approved: :mnesia_down"
    assert [{:fingerprint, "head-3"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-3"}}] = mailbox()
  end

  test "in enforce mode a head whose diff can't be compared is re-reviewed, but a record without a workspace is not" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])

    # The approved diff couldn't be read: any new head is re-reviewed.
    fingerprints(%{"head-1" => {:error, :fetch_failed}, "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now) end)

    assert log =~
             "Auto-merge ACME-1780: could not fingerprint the approved diff; it is read again when a new head comes, and that head is re-reviewed if it still can't be commit_sha=head-1: :fetch_failed"

    assert %{approved_head_sha: "head-1", approved_fingerprint: nil} = PrReviewPoller.auto_merge(@issue_id)

    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)
    mailbox()
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 30)) end)

    # The approved diff is read again first, and still can't be.
    assert [
             {:fingerprint, "head-2"},
             {:fingerprint, "head-1"},
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_state_update, @issue_id, "Auto Review"},
             {:issue_comment, @issue_id, comment}
           ] = mailbox()

    assert comment =~ "the diff approved at `head-1` could not be read to compare with `head-2`"

    # Back in Merging after the gate, a head whose own diff can't be read is re-reviewed again.
    track([issue("Merging")])
    fingerprints(%{"head-2" => "diff-b", "head-3" => {:error, {:git_failed, "merge-base", 1, "fatal"}}})
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 60))
    activity(head: "head-3", merge_state: "BLOCKED", auto_merge_enabled: true)
    mailbox()

    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-3"}]}} = enforce_poll(DateTime.add(now, 90)) end)

    assert [
             {:fingerprint, "head-3"},
             {:disable_auto_merge, @pr_url, "PR_node"},
             {:issue_state_update, @issue_id, "Auto Review"},
             {:issue_comment, @issue_id, comment}
           ] = mailbox()

    assert comment =~ "the diff of `head-3` could not be compared with the approved one"

    # With no workspace to read diffs in, a new head keeps today's behaviour.
    track([issue("Merging")])
    fingerprints(%{"head-3" => {:error, :no_workspace}, "head-4" => {:error, :no_workspace}})
    activity(head: "head-3", merge_state: "BLOCKED")
    log = capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 120)) end)
    refute log =~ "could not fingerprint"
    activity(head: "head-4", merge_state: "BLOCKED", auto_merge_enabled: true)
    mailbox()

    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 150))
    assert [{:fingerprint, "head-4"}] = mailbox()
    assert %{approved_head_sha: "head-3"} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "in enforce mode an approved diff that couldn't be read at first is read again, so the update-branch merge keeps the approval" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => {:error, :fetch_failed}})
    activity(head: "head-1", merge_state: "BLOCKED")
    capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now) end)
    assert %{approved_head_sha: "head-1", approved_fingerprint: nil} = PrReviewPoller.auto_merge(@issue_id)

    # The fetch works again by the time GitHub merges the base in.
    fingerprints(%{"head-1" => "diff-a", "merge-1" => "diff-a"})
    activity(head: "merge-1", merge_state: "BLOCKED", auto_merge_enabled: true)
    mailbox()

    capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 30)) end)
    assert [{:fingerprint, "merge-1"}, {:fingerprint, "head-1"}] = mailbox()
    assert %{state: "enabled", approved_head_sha: "merge-1", approved_fingerprint: "diff-a"} = PrReviewPoller.auto_merge(@issue_id)
    assert audit_events("acceptance_gate_rereview") == []
  end

  test "in enforce mode a re-review on a head GitHub already shows without auto-merge turns it on again when that head is approved back" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)

    # GitHub dropped auto-merge on its own before the push was seen: nothing to turn off.
    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: false)
    mailbox()
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 30)) end)
    assert [{:fingerprint, "head-2"}, {:issue_state_update, @issue_id, "Auto Review"}, {:issue_comment, @issue_id, _comment}] = mailbox()
    assert %{state: "rereview", enabled_head_sha: nil} = PrReviewPoller.auto_merge(@issue_id)

    # head-2 was force-pushed away and the gate approved head-1 again: auto-merge goes back on for it.
    record = Map.merge(qa_passed("head-1"), %{gate_sha: "head-1", gate_verdict: "approve"})
    :ok = RunStore.put_ci_check(record)
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 60))
    assert [{:fingerprint, "head-1"}, {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}] = mailbox()
  end

  test "in enforce mode a landing agent's commit that changes the diff is re-reviewed too" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    replies(%{enable_auto_merge: {:error, :forbidden}})

    capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = enforce_poll(now) end)
    capture_log(fn -> assert {:ok, %{actions: [{:auto_merge, @issue_id, "fallback"}]}} = enforce_poll(DateTime.add(now, 30)) end)
    mailbox()

    activity(head: "head-2", merge_state: "BLOCKED")
    capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 60)) end)

    # Auto-merge was never on, so there is nothing to turn off.
    assert [{:fingerprint, "head-2"}, {:issue_state_update, @issue_id, "Auto Review"}, {:issue_comment, @issue_id, _comment}] = mailbox()
    assert [%{"auto_merge_disabled" => false}] = audit_events("acceptance_gate_rereview")
    assert %{state: "rereview"} = PrReviewPoller.auto_merge(@issue_id)
  end

  test "in enforce mode a re-review whose disable or move fails is tried again on the next poll" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)

    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)
    replies(%{disable_auto_merge: {:error, :forbidden}})
    mailbox()

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:poll_error, @issue_id, {:disable_auto_merge_failed, :forbidden}}]}} = enforce_poll(DateTime.add(now, 30))
      end)

    assert [{:fingerprint, "head-2"}, {:disable_auto_merge, @pr_url, "PR_node"}] = mailbox()
    assert log =~ "turning GitHub auto-merge off for the re-review failed; the issue stays in Merging until it is off"
    assert %{state: "enabled", approved_head_sha: "head-1"} = PrReviewPoller.auto_merge(@issue_id)

    # Auto-merge goes off, but the move fails: the issue stays put and the move is tried again.
    replies(%{})
    Application.put_env(:symphony_elixir, :auto_merge_test_state_result, {:error, :linear_down})

    log =
      capture_log(fn ->
        assert {:ok, %{actions: [{:poll_error, @issue_id, {:rereview_transition_failed, :linear_down}}]}} = enforce_poll(DateTime.add(now, 60))
      end)

    assert [{:fingerprint, "head-2"}, {:disable_auto_merge, @pr_url, "PR_node"}, {:issue_state_update, @issue_id, "Auto Review"}] = mailbox()
    assert log =~ "Failed to move ACME-1780 to Auto Review for the acceptance gate re-review; auto-merge stays off"
    assert audit_events("acceptance_gate_rereview") == []

    # GitHub shows auto-merge off now; the move goes through, and a failed comment doesn't hold it.
    Application.put_env(:symphony_elixir, :auto_merge_test_state_result, :ok)
    Application.put_env(:symphony_elixir, :auto_merge_test_comment_result, {:error, :linear_down})
    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: false)

    log = capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 90)) end)
    assert [{:fingerprint, "head-2"}, {:issue_state_update, @issue_id, "Auto Review"}, {:issue_comment, @issue_id, _comment}] = mailbox()
    assert log =~ "Failed to comment on the acceptance gate re-review"
    assert [%{"old_head_sha" => "head-1", "new_head_sha" => "head-2"}] = audit_events("acceptance_gate_rereview")
  end

  test "a re-review whose audit event can't be written still goes back to Auto Review" do
    now = ~U[2026-10-03 12:00:00Z]
    write_enforce_workflow!()
    put_run!(now)
    track([issue("Merging")])
    fingerprints(%{"head-1" => "diff-a", "head-2" => "diff-b"})
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)

    blocker = Path.join(System.tmp_dir!(), "symphony-auto-merge-audit-blocker-#{System.unique_integer([:positive])}")
    File.write!(blocker, "")
    on_exit(fn -> File.rm_rf(blocker) end)
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(blocker, "audit"))

    activity(head: "head-2", merge_state: "BLOCKED")
    log = capture_log(fn -> assert {:ok, %{actions: [{:acceptance_gate_rereview, @issue_id, "head-2"}]}} = enforce_poll(DateTime.add(now, 30)) end)
    assert log =~ "Failed to record acceptance_gate_rereview audit event issue_id=#{@issue_id}"
  end

  test "in shadow mode a push in Merging is not re-reviewed" do
    now = ~U[2026-10-03 12:00:00Z]
    write_auto_merge_workflow!(ci: %{enabled: true}, auto_review: %{enabled: true, acceptance_gate: %{mode: "shadow"}})
    put_run!(now)
    track([issue("Merging")])
    activity(head: "head-1", merge_state: "BLOCKED")
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(now)

    activity(head: "head-2", merge_state: "BLOCKED", auto_merge_enabled: true)
    assert {:ok, %{actions: [{:auto_merge, @issue_id, "enabled"}]}} = enforce_poll(DateTime.add(now, 30))
    assert [{:enable_auto_merge, @pr_url, %{head_sha: "head-1"}}] = mailbox()
    assert %{approved_head_sha: nil} = PrReviewPoller.auto_merge(@issue_id)
    refute AutoMerge.rereview?(Config.settings!())
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

  describe "a merged PR whose issue has sub-tickets" do
    @waiting "Waiting on sub-tickets"

    setup do
      SubIssueWait.reset_for_test(@waiting)
      on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)
    end

    test "with one still open moves the issue to the waiting state instead of Done and its Backlog sub-tickets to Todo" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)

      track([
        with_sub_issues(issue("Merging"), [
          {"child-1", "ACME-1781", "Backlog"},
          {"child-2", "ACME-1782", "Todo"},
          {"child-3", "ACME-1783", "Done"}
        ])
      ])

      activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)

      log = capture_log([level: :info], fn -> assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(now) end)

      assert_received {:issue_state_update, @issue_id, @waiting}
      assert_received {:issue_state_update, "child-1", "Todo"}
      refute_received {:issue_state_update, _issue_id, _state}
      assert_received {:issue_comment, @issue_id, body}

      assert body ==
               "Waiting on sub-tickets: the PR merged with sub-tickets still open (ACME-1781, ACME-1782), so this ticket " <>
                 "moves to Done once every sub-ticket is finished. Canceling one counts as finishing it.\n\nPromoted to Todo: ACME-1781"

      assert log =~ "Moved issue to Waiting on sub-tickets after its PR merged with sub-issues open; promoted to Todo: ACME-1781"
      assert log =~ "Auto-merge ACME-1780: merged"
      assert RunStore.list_pr_reviews(@repo_key) == []
      # The merge put it there, so it moves to Done once its sub-tickets finish.
      assert RunStore.merged_wait?(@issue_id)
    end

    test "waits even when Linear already moved the issue to Done, and a failed read retries on the next poll" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)
      discover_review!(now)
      track([with_sub_issues(issue("Done"), [{"child-1", "ACME-1781", "Todo"}])])
      activity(head: "head-1", state: "MERGED")
      Application.put_env(:symphony_elixir, :auto_merge_test_fetch_result, {:error, :linear_down})

      assert {:ok, %{actions: [{:state_transition_error, @issue_id, :wait, :linear_down}]}} = poll(now)
      assert_received {:fetch_issue_states_by_ids, [@issue_id]}
      refute_received {:issue_state_update, _issue_id, _state}
      assert [%{status: "state_transition_error"}] = RunStore.list_pr_reviews(@repo_key)

      Application.delete_env(:symphony_elixir, :auto_merge_test_fetch_result)

      capture_log(fn -> assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 60)) end)
      assert_received {:issue_state_update, @issue_id, @waiting}
      refute_received {:issue_state_update, _issue_id, _state}
      assert_received {:issue_comment, @issue_id, body}
      refute body =~ "Promoted"
    end

    test "keeps the record when a sub-ticket can't be promoted, and promotes only what is left next poll" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)
      sub_issues = [{"child-1", "ACME-1781", "Backlog"}, {"child-2", "ACME-1782", "Backlog"}]
      track([with_sub_issues(issue("Merging"), sub_issues)])
      activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)
      Application.put_env(:symphony_elixir, :auto_merge_test_state_result, %{"child-2" => {:error, :linear_down}})

      log =
        capture_log(fn ->
          assert {:ok, %{actions: [{:state_transition_error, @issue_id, :wait, reason}]}} = poll(now)
          assert reason == {:sub_issue_promotion_failed, ["ACME-1782"]}
        end)

      assert log =~ "Failed to move sub-issue ACME-1782 to Todo after its parent's PR merged"
      assert_received {:issue_state_update, @issue_id, @waiting}
      assert_received {:issue_state_update, "child-1", "Todo"}
      assert_received {:issue_state_update, "child-2", "Todo"}
      assert_received {:issue_comment, @issue_id, _first}

      # Linear now shows it waiting with one sub-ticket left in Backlog: only that one moves.
      Application.delete_env(:symphony_elixir, :auto_merge_test_state_result)
      track([with_sub_issues(issue(@waiting), [{"child-1", "ACME-1781", "Todo"}, {"child-2", "ACME-1782", "Backlog"}])])

      capture_log(fn -> assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(DateTime.add(now, 60)) end)
      assert_received {:issue_state_update, "child-2", "Todo"}
      refute_received {:issue_state_update, _issue_id, _state}
      assert_received {:issue_comment, @issue_id, "Promoted to Todo: ACME-1782"}
    end

    test "an issue already waiting with nothing left in Backlog is neither moved nor commented on again" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)
      discover_review!(now)
      track([with_sub_issues(issue(@waiting), [{"child-1", "ACME-1781", "In Progress"}])])
      activity(head: "head-1", state: "MERGED")

      assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(now)
      assert_received {:fetch_issue_states_by_ids, [@issue_id]}
      refute_received {:issue_state_update, _issue_id, _state}
      refute_received {:issue_comment, _issue_id, _body}
    end

    test "a failed move to the waiting state keeps the record for the next poll" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)
      track([with_sub_issues(issue("Merging"), [{"child-1", "ACME-1781", "Backlog"}])])
      activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)
      Application.put_env(:symphony_elixir, :auto_merge_test_state_result, {:error, :linear_down})

      assert {:ok, %{actions: [{:state_transition_error, @issue_id, :wait, :linear_down}]}} = poll(now)
      assert_received {:issue_state_update, @issue_id, @waiting}
      refute_received {:issue_state_update, _issue_id, _state}
      refute_received {:issue_comment, _issue_id, _body}
    end

    test "all finished, a breakdown parent, or the waiting state off: Done on merge as before" do
      now = ~U[2026-10-03 12:00:00Z]
      finished = [{"child-1", "ACME-1781", "Done"}, {"child-2", "ACME-1782", "Canceled"}, {"child-3", "ACME-1783", "Duplicate"}]
      open = [{"child-1", "ACME-1781", "Backlog"}]

      for {merging, disabled?} <- [
            {with_sub_issues(issue("Merging"), finished), false},
            {%{with_sub_issues(issue("Merging"), open) | labels: ["breakdown"]}, false},
            {with_sub_issues(issue("Merging"), open), true}
          ] do
        if disabled?, do: disable_waiting_state!()
        put_run!(now)
        track([merging])
        activity(head: "head-1", state: "MERGED", auto_merge_enabled: true)

        capture_log(fn -> assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(now) end)
        assert_received {:issue_state_update, @issue_id, "Done"}
        refute_received {:issue_state_update, _issue_id, _state}
        refute_received {:issue_comment, _issue_id, _body}
        refute RunStore.merged_wait?(@issue_id)
      end

      # With the state off the issue is not even read.
      refute_received {:fetch_issue_states_by_ids, _issue_ids}
    end

    test "an issue gone from Linear keeps the plain cleanup" do
      now = ~U[2026-10-03 12:00:00Z]
      put_run!(now)
      discover_review!(now)
      track([])
      activity(head: "head-1", state: "MERGED")

      assert {:ok, %{actions: [{:cleanup, @issue_id, "merged"}]}} = poll(now)
      assert_received {:fetch_issue_states_by_ids, [@issue_id]}
      refute_received {:issue_state_update, _issue_id, _state}
    end
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
    assert AutoMerge.ci_fix_comment(nil) =~ "turned off GitHub auto-merge on this PR because CI failed"
    assert AutoMerge.describe(%{state: "ci_failure", head_sha: nil}) == "auto-merge off: CI failed on an unknown head; the fix goes back through review"
    assert AutoMerge.held?(%{state: "ci_failure"})
    refute AutoMerge.held?(nil)

    # A CI fix with no earlier auto-merge state: GitHub shows it on, but there's no PR node id to turn it off with.
    assert {:error, :missing_pr_node_id} =
             AutoMerge.disable_for_ci_fix(%{}, %{commit_sha: "h", auto_merge_enabled: true}, nil, [], now)

    enabled_state = %{state: "enabled", head_sha: "h", enabled_head_sha: "h"}

    assert {:ok, %{state: "ci_failure", head_sha: "h", enabled_head_sha: nil, disabled_at: nil}} =
             AutoMerge.disable_for_ci_fix(%{}, %{commit_sha: "h"}, enabled_state, [], now)

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

  defmodule HoldFailingRunStore do
    alias SymphonyElixir.RunStore

    defdelegate list_issue_runs(repo_key, issue_id), to: RunStore
    defdelegate list_all_runs(limit), to: RunStore
    defdelegate list_ci_checks(repo_key), to: RunStore
    defdelegate list_pr_reviews(repo_key), to: RunStore
    defdelegate put_ci_check(record), to: RunStore
    defdelegate update_ci_check(repo_key, issue_id, attrs), to: RunStore
    defdelegate delete_ci_check(repo_key, issue_id), to: RunStore

    @spec update_pr_review(String.t(), String.t(), map()) :: {:error, term()}
    def update_pr_review(_repo_key, _issue_id, _attrs), do: {:error, :write_failed}
  end

  defmodule CiChecksFailingRunStore do
    @spec list_ci_checks(String.t()) :: {:error, :mnesia_down}
    def list_ci_checks(_repo_key), do: {:error, :mnesia_down}

    @spec list_pr_reviews(String.t()) :: [map()] | {:error, term()}
    def list_pr_reviews(repo_key), do: RunStore.list_pr_reviews(repo_key)

    @spec list_issue_runs(String.t(), String.t()) :: [map()] | {:error, term()}
    def list_issue_runs(repo_key, issue_id), do: RunStore.list_issue_runs(repo_key, issue_id)

    @spec put_pr_review(map()) :: :ok | {:error, term()}
    def put_pr_review(record), do: RunStore.put_pr_review(record)

    @spec update_pr_review(String.t(), String.t(), map()) :: :ok | {:error, term()}
    def update_pr_review(repo_key, issue_id, attrs), do: RunStore.update_pr_review(repo_key, issue_id, attrs)
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

  defp ci_poll(now), do: CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

  defp enforce_poll(now), do: poll(now, fingerprint: &__MODULE__.fake_fingerprint/2)

  defp write_enforce_workflow! do
    write_auto_merge_workflow!(
      ci: %{enabled: true, flaky_retry: false},
      auto_review: %{enabled: true, acceptance_gate: %{mode: "enforce"}}
    )
  end

  defp agent_run!(status, now) do
    :ok =
      RunStore.put_run(%{
        repo_key: @repo_key,
        run_id: "run-1781",
        issue_id: @issue_id,
        issue_identifier: "ACME-1780",
        status: status,
        started_at: now
      })
  end

  defp qa_passed(sha) do
    %{repo_key: @repo_key, issue_id: @issue_id, pr_url: @pr_url, qa_sha: sha, qa_verdict: "pass", qa_target_state: "In Review"}
  end

  defp green_in_auto_review(record, sha, opts \\ []) do
    AutoReview.on_green(issue("Auto Review"), record, %{commit_sha: sha}, Config.settings!(), [tracker: FakeTracker] ++ opts)
  end

  defp fingerprints(fingerprints), do: Application.put_env(:symphony_elixir, :auto_merge_test_fingerprints, fingerprints)

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

  # The poller watches the PR from its issue's review; the issue then leaves the watched states.
  defp discover_review!(now) do
    track([issue("In Review")])
    activity(head: "head-1")
    capture_log(fn -> assert {:ok, %{discovered: 1}} = poll(DateTime.add(now, -60)) end)
  end

  defp with_sub_issues(issue, sub_issues) do
    sub_issues = for {id, identifier, state} <- sub_issues, do: %{id: id, identifier: identifier, state: state}
    %{issue | sub_issues: sub_issues}
  end

  defmodule MissingStateTracker do
    @spec workflow_state_exists?(String.t(), [String.t()]) :: {:ok, false}
    def workflow_state_exists?(_state_name, _teams), do: {:ok, false}
  end

  defp disable_waiting_state! do
    opts = [tracker: MissingStateTracker]
    settings = Config.settings!()
    log = capture_log(fn -> send(self(), SubIssueWait.check_tracker_state(settings, [], opts)) end)
    assert_received :disabled
    assert log =~ "Waiting on sub-issues state disabled"
  end

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

  defp red_ci_status(opts) do
    Application.put_env(:symphony_elixir, :auto_merge_test_ci_status, %{
      pr_url: @pr_url,
      pr_node_id: "PR_node",
      state: "OPEN",
      commit_sha: "head-1",
      auto_merge_enabled: Keyword.fetch!(opts, :auto_merge_enabled),
      checks: [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE", run_id: Keyword.get(opts, :run_id)}]
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
