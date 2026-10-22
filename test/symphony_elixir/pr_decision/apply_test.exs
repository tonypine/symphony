defmodule SymphonyElixir.PrDecision.ApplyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiFix, Hold, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrDecision.{Action, Apply, Facts}
  alias SymphonyElixir.PrWatch.Attempts

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  @repo_key "default"
  @issue_id "issue-apply"
  @pr_url "https://github.com/acme/app/pull/7"
  @now ~U[2026-10-16 12:00:00Z]

  # Linear: every write is reported to the test; `:fail_move` and `:fail_comment` make them fail.
  defmodule Tracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:move, issue_id, state})
      Process.get(:move_result, :ok)
    end

    def create_comment(issue_id, body) do
      send(self(), {:comment, issue_id, body})
      Process.get(:comment_result, :ok)
    end

    def set_machine_label(issue_id, label), do: send(self(), {:label, issue_id, label}) && :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  # GitHub: every call is reported; each answers what the process dictionary says, `:ok` by default.
  defmodule GitHub do
    for {name, arity} <- [
          rerun_failed: 2,
          enable_auto_merge: 3,
          squash_merge: 3,
          disable_auto_merge: 3,
          update_branch: 3,
          change_base: 3
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        send(self(), {unquote(name), unquote_splicing(args)})
        Process.get(unquote(name), :ok)
      end
    end

    def fetch_failed_log(run_id, opts) do
      send(self(), {:fetch_failed_log, run_id, opts})
      Process.get(:fetch_failed_log, {:ok, "setup\nERROR: specs failed\nstack"})
    end
  end

  # The self-heal lane: reports the outcome it got and answers what the process dictionary says.
  defmodule SelfHeal do
    def heal(issue, opts) do
      send(self(), {:heal, issue.id, opts})
      Process.get(:heal_result, :filed)
    end
  end

  # Linear's blocked-by links: every call is reported; each answers what the process dictionary says.
  defmodule Linker do
    def add_blocked_by(blocker, issue_id) do
      send(self(), {:add_blocked_by, blocker, issue_id})
      Process.get(:add_blocked_by, :ok)
    end
  end

  # A store that refuses to set a hold.
  defmodule FailingHoldStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :store_down}
  end

  defmodule FailingOriginStore do
    def set_ci_fix_origin(_repo_key, _issue_id, _origin), do: {:error, :store_down}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 50}
    )

    :ok = TicketPullRequest.record_created(@repo_key, @issue_id, @pr_url, "auto/TP-7")
    :ok
  end

  defp settings, do: Config.settings!()

  defp read(attrs \\ %{}) do
    Map.merge(
      %{
        pr_url: @pr_url,
        pr_number: 7,
        pr_node_id: "PR_node",
        pr_title: "Add it",
        pr_description: "Body",
        head_sha: "head-1",
        head_ref: "auto/TP-7",
        base_ref: "main",
        base_sha: "base-1",
        failed_checks: [%{name: "specs", run_id: "11", workflow_name: "ci", conclusion: "FAILURE"}]
      },
      Map.new(attrs)
    )
  end

  defp ctx(phase, attrs \\ []) do
    facts = Facts.new(Map.merge(%{phase: phase, pr_number: 7, failing_check: "specs"}, Map.new(Keyword.get(attrs, :facts, %{}))))

    %{
      repo_key: @repo_key,
      settings: Keyword.get(attrs, :settings, settings()),
      issue: %Issue{
        id: @issue_id,
        identifier: "TP-7",
        title: "Add it",
        state: Keyword.get(attrs, :state, phase_name(phase)),
        url: "https://linear.app/i/TP-7",
        description: Keyword.get(attrs, :description),
        rulings: Keyword.get(attrs, :rulings, []),
        blocked_by: Keyword.get(attrs, :blocked_by, [])
      },
      read: Keyword.get(attrs, :read, read()),
      facts: facts,
      attempts: Keyword.get(attrs, :attempts, Attempts.new()),
      applied: Keyword.get(attrs, :applied, []),
      fix: %{ci_failure: nil, pr_conflict: nil},
      now: @now,
      links: Keyword.get(attrs, :links, []),
      opts: [tracker: Tracker, github: GitHub, self_heal: SelfHeal, linker: Linker] ++ Keyword.get(attrs, :opts, [])
    }
  end

  defp phase_name(phase), do: SymphonyElixir.PrDecision.phase_name(phase)

  defp action(rule, kind, attrs \\ []) do
    waiting = kind in Action.waiting_kinds()
    attrs = if waiting, do: Keyword.merge([owner: :symphony, clears_when: "it ends"], attrs), else: attrs
    Action.new!(rule, kind, Keyword.merge([reason: "the reason"], attrs))
  end

  defp origin, do: CiFix.origin(@repo_key, @issue_id)

  describe "rows another ticket applies, waits and repeats" do
    test "are recorded without an action" do
      cases = [
        {action("R23", :wait, owner: :ci), ctx(:qa)},
        {action("R4", :wait), ctx(:code_review)},
        {action("R8", :dispatch, args: %{phase: :rework}), ctx(:rework)},
        {action("R10", :wait), ctx(:qa, facts: %{auto_merge: :armed})},
        {action("R10", :wait), ctx(:merging)},
        {action("R27", :dispatch, args: %{phase: :qa}), ctx(:qa)}
      ]

      for {action, ctx} <- cases do
        assert %{outcome: :recorded, action: ^action, applied: []} = Apply.apply(action, ctx), inspect(action.rule)
      end

      refute_received {:move, _id, _state}
      refute_received {:comment, _id, _body}
    end

    test "CI rows wait for `pull_requests.checks`, and landing rows and a Merging conflict for auto-merge" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pr_review_mode: "polling",
        pr_review_auto_merge: false,
        ci: %{enabled: false}
      )

      competitors = %{prs: [%{issue_identifier: "TP-1", files: ["a.ex"]}], step_behind: true}

      for {action, phase} <- [
            {action("R17", :decision, args: %{question: "q", options: []}, owner: :person), :code_review},
            {action("R18", :decision, args: %{question: "q", options: []}, owner: :person), :qa},
            {action("R18", :decision, args: %{question: "q", options: []}, owner: :person), :merging},
            {action("R22", :rerun_failed), :code_review},
            {action("R21", :ci_fix, args: %{origin: :qa, cause: :red}), :qa},
            {action("R30", :arm), :merging},
            {action("R3", :disarm), :qa},
            {action("R14", :ci_fix, args: %{origin: :merging, cause: :conflict}), :merging},
            {action("R15", :wait_for_competitors, args: competitors), :merging},
            {action("R13", :to_in_progress), :merging}
          ] do
        assert %{outcome: :recorded} = Apply.apply(action, ctx(phase))
      end

      # A draft Merging PR keeps its auto-merge when the watcher doesn't land it.
      assert %{outcome: :recorded} = Apply.apply(action("R10", :wait), ctx(:merging, facts: %{auto_merge: :armed}))
      refute_received {:disable_auto_merge, _url, _node, _opts}

      # A conflict outside Merging is the watcher's whatever auto-merge says.
      assert %{outcome: :applied} = Apply.apply(action("R14", :ci_fix, args: %{origin: :qa, cause: :conflict}), ctx(:qa))
      refute_received {:rerun_failed, _run_id, _opts}
      refute_received {:enable_auto_merge, _url, _request, _opts}
    end

    test "an action already applied to the head in this stay is not applied again" do
      applied = [%{head_sha: "head-1", rule: "R22", kind: :rerun_failed, at: @now}]
      assert %{outcome: :recorded, applied: ^applied} = Apply.apply(action("R22", :rerun_failed), ctx(:code_review, applied: applied))
      refute_received {:rerun_failed, _run_id, _opts}

      assert Apply.applied?(applied, "R22", "head-1")
      refute Apply.applied?(applied, "R22", "head-2")
      refute Apply.applied?(applied, "R21", "head-1")
    end
  end

  describe "rerun_failed" do
    test "reruns the failed runs of the head once (R22), and records the checks it reran" do
      checks = [%{name: "specs", run_id: "11"}, %{name: "lint", run_id: "11"}, %{name: "dialyzer", run_id: "12"}, %{name: "x", run_id: nil}]

      assert %{outcome: :applied, attempts: attempts, applied: [%{rule: "R22", head_sha: "head-1"}]} =
               Apply.apply(action("R22", :rerun_failed), ctx(:code_review, read: read(failed_checks: checks)))

      assert_received {:rerun_failed, "11", [repo: "acme/app"]}
      assert_received {:rerun_failed, "12", [repo: "acme/app"]}
      assert attempts.reruns == %{"head-1" => ["specs", "lint", "dialyzer", "x"]}
    end

    test "`gh run rerun` names the PR's repository, on GitHub Enterprise too" do
      assert %{outcome: :applied} = Apply.apply(action("R22", :rerun_failed), ctx(:qa, read: read(pr_url: "https://ghe.acme.test/acme/app/pull/7")))
      assert_received {:rerun_failed, "11", [repo: "ghe.acme.test/acme/app"]}

      assert %{outcome: :applied} = Apply.apply(action("R22", :rerun_failed), ctx(:qa, read: read(pr_url: "not a url")))
      assert_received {:rerun_failed, "11", []}

      assert %{outcome: :applied} = Apply.apply(action("R22", :rerun_failed), ctx(:qa, read: read(pr_url: nil)))
      assert_received {:rerun_failed, "11", []}
    end

    test "a cancelled run's rerun (R19) spends nothing, and a head with no run id has nothing to rerun" do
      cancelled = read(failed_checks: [%{name: "specs", run_id: "11", job_id: 101, workflow_name: "ci", conclusion: "CANCELLED"}])
      assert %{outcome: :applied, attempts: attempts} = Apply.apply(action("R19", :rerun_failed), ctx(:qa, read: cancelled))
      assert_received {:rerun_failed, "11", [repo: "acme/app"]}
      assert %{attempts | cancels: nil} == Attempts.new()
      assert attempts.reruns == %{}

      assert %{outcome: :applied, attempts: %{reruns: %{"head-1" => ["specs"]}}} =
               Apply.apply(action("R22", :rerun_failed), ctx(:qa, read: read(failed_checks: [%{name: "specs", run_id: nil}])))

      refute_received {:rerun_failed, nil, _opts}
    end

    test "R19 reruns every new cancellation on the head: a second workflow's, and a rerun cancelled again" do
      e2e = %{name: "e2e", run_id: "21", job_id: 201, workflow_name: "macos-e2e", conclusion: "CANCELLED"}
      install = %{name: "install script", run_id: "22", job_id: 202, workflow_name: "macos", conclusion: "CANCELLED"}
      rerun = action("R19", :rerun_failed)

      # The first workflow's run is cancelled and rerun.
      assert %{outcome: :applied, attempts: attempts, applied: applied} = Apply.apply(rerun, ctx(:code_review, read: read(failed_checks: [e2e])))
      assert_received {:rerun_failed, "21", _opts}

      # Minutes later the other workflow's run is cancelled on the same head: rerun too, though R19 is in the ledger.
      ctx = ctx(:code_review, read: read(failed_checks: [install]), attempts: attempts, applied: applied)
      assert %{outcome: :applied, attempts: attempts, applied: applied} = Apply.apply(rerun, ctx)
      assert_received {:rerun_failed, "22", _opts}
      refute_received {:rerun_failed, "21", _opts}

      # The first rerun's attempt is cancelled again: new job ids, rerun once more.
      again = %{e2e | job_id: 211}
      ctx = ctx(:code_review, read: read(failed_checks: [again]), attempts: attempts, applied: applied)
      assert %{outcome: :applied, attempts: attempts} = Apply.apply(rerun, ctx)
      assert_received {:rerun_failed, "21", _opts}
      assert %{"21" => %{reruns: 2, jobs: ["201", "211"], checks: ["e2e"]}, "22" => %{reruns: 1}} = attempts.cancels.runs
      assert %{red: 0, reruns: reruns} = attempts
      assert reruns == %{}
    end

    test "R19 with no new cancellation waits on CI for the rerun it sent, without rerunning it again" do
      e2e = %{name: "e2e", run_id: "21", job_id: 201, workflow_name: "macos-e2e", conclusion: "CANCELLED"}
      lint = %{e2e | name: "lint", job_id: 202}
      attempts = Attempts.cancel_rerun(Attempts.new(), "head-1", [e2e, lint])

      assert %{outcome: :recorded, action: action, applied: []} = Apply.apply(action("R19", :rerun_failed), ctx(:qa, read: read(failed_checks: [e2e]), attempts: attempts))
      assert %Action{rule: "R19", kind: :wait, owner: :ci, clears_when: "the rerun reports"} = action
      assert action.reason == "Symphony reran the `e2e` check after GitHub cancelled it: waiting for the rerun to report"

      assert %{action: %{reason: reason}} = Apply.apply(action("R19", :rerun_failed), ctx(:qa, read: read(failed_checks: [e2e, lint]), attempts: attempts))
      assert reason == "Symphony reran the `e2e`, `lint` checks after GitHub cancelled it: waiting for the rerun to report"

      # A read with no cancelled check named left: the failing check names it.
      assert %{action: %{reason: "Symphony reran the `specs` check after GitHub cancelled it: waiting for the rerun to report"}} =
               Apply.apply(action("R19", :rerun_failed), ctx(:qa, read: read(failed_checks: []), attempts: attempts))

      # A run already at its bound is R19a's; R19 doesn't rerun it.
      capped = put_in(attempts.cancels.runs["21"].reruns, 2)
      assert %{outcome: :recorded} = Apply.apply(action("R19", :rerun_failed), ctx(:qa, read: read(failed_checks: [%{e2e | job_id: 299}]), attempts: capped))
      refute_received {:rerun_failed, _run_id, _opts}
    end

    test "a rerun GitHub refuses leaves the head to be decided again" do
      Process.put(:rerun_failed, {:error, :forbidden})

      log =
        capture_log(fn ->
          assert %{outcome: {:error, {:rerun_failed, "11", :forbidden}}, applied: [], attempts: attempts} = Apply.apply(action("R22", :rerun_failed), ctx(:qa))
          assert attempts == Attempts.new()
        end)

      assert log =~ "PR watch could not apply R22 rerun_failed"
    end
  end

  describe "ci_fix" do
    test "a red Code Review head goes to CI Fix with its origin, its failure and one red attempt spent" do
      action = action("R21", :ci_fix, args: %{origin: :code_review, cause: :red})

      assert %{outcome: :applied, attempts: attempts, fix: %{ci_failure: failure}} = Apply.apply(action, ctx(:code_review))

      assert_received {:fetch_failed_log, "11", [repo: "acme/app"]}
      assert_received {:move, @issue_id, "CI Fix"}
      assert origin() == "Code Review"
      assert %{red: 1, conflict: 0, fix_failures: [%{check: "specs", error: "ERROR: specs failed", head_sha: "head-1"}]} = attempts
      assert attempts.streak == attempts.fix_failures

      assert %{commit_sha: "head-1", head_ref_name: "auto/TP-7", failed_checks: [%{name: "specs"}], approved: false} = failure
      assert failure.earlier_failures == []
      assert failure.log_excerpt =~ "ERROR: specs failed"
      refute_received {:disable_auto_merge, _url, _node, _opts}
    end

    test "a red head's fix run reads the earlier runs' failures, and the head's failure and log as the read carries them" do
      earlier = [%{check: "specs", error: "ERROR: one", head_sha: "head-0"}]
      failure = %{check: "specs", error: "ERROR: the signature", head_sha: "head-1"}
      read = read(failure: failure, failed_log: %{excerpt: "the log read this tick", error: "ERROR: the log"})
      ctx = ctx(:qa, read: read, attempts: %{Attempts.new() | red: 1, fix_failures: earlier, streak: earlier})

      assert %{outcome: :applied, attempts: attempts, fix: %{ci_failure: fix}} = Apply.apply(action("R21", :ci_fix, args: %{origin: :qa, cause: :red}), ctx)

      refute_received {:fetch_failed_log, _run_id, _opts}
      assert %{log_excerpt: "the log read this tick", first_error: "ERROR: the log", earlier_failures: ^earlier} = fix
      assert attempts.fix_failures == earlier ++ [failure]
      assert attempts.streak == earlier ++ [failure]

      # A failure read for another head is not this one's.
      ctx = ctx(:qa, read: read(failure: %{failure | head_sha: "head-0"}))
      assert %{attempts: %{fix_failures: [%{error: "ERROR: specs failed", head_sha: "head-1"}]}} = Apply.apply(action("R21", :ci_fix, args: %{origin: :qa, cause: :red}), ctx)
    end

    test "a red Merging head has auto-merge turned off first, and is marked approved" do
      ctx = ctx(:merging, facts: %{auto_merge: :armed})

      assert %{outcome: :applied, fix: %{ci_failure: %{approved: true}}} =
               Apply.apply(action("R21", :ci_fix, args: %{origin: :merging, cause: :red}), ctx)

      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:comment, @issue_id, comment}
      assert comment =~ "because CI failed and a fix run may push new code"
      assert_received {:move, @issue_id, "CI Fix"}
      assert origin() == "Merging"
    end

    test "a conflicting Merging PR goes to CI Fix with the conflict, auto-merge off and one conflict attempt spent" do
      ctx = ctx(:merging, facts: %{auto_merge: :armed}, attempts: %{Attempts.new() | conflict: 1})

      assert %{outcome: :applied, attempts: %{conflict: 2, red: 0}, fix: %{pr_conflict: conflict}} =
               Apply.apply(action("R14", :ci_fix, args: %{origin: :merging, cause: :conflict}), ctx)

      assert_received {:comment, @issue_id, comment}
      assert comment =~ "because it conflicts with the base branch"
      assert %{head_sha: "head-1", base_sha: "base-1", conflict_key: "head-1|base-1", retry_count: 2, max_retries: 3, approved: true} = conflict
      refute_received {:fetch_failed_log, _run_id, _opts}
    end

    test "in CI Fix the ticket stays and the next run takes the fix" do
      ctx = ctx(:ci_fix, facts: %{origin: :qa})

      assert %{outcome: :applied, attempts: %{red: 1}, fix: %{ci_failure: %{approved: false}}} =
               Apply.apply(action("R21", :ci_fix, args: %{origin: :qa, cause: :red}), ctx)

      refute_received {:move, _id, _state}
    end

    test "a step that fails moves nothing and spends nothing" do
      red = action("R21", :ci_fix, args: %{origin: :merging, cause: :red})

      Process.put(:fetch_failed_log, {:error, :gone})
      capture_log(fn -> assert %{outcome: {:error, {:failed_log_unavailable, "11", :gone}}, attempts: %{red: 0}} = Apply.apply(red, ctx(:merging)) end)
      Process.delete(:fetch_failed_log)

      Process.put(:disable_auto_merge, {:error, :forbidden})
      capture_log(fn -> assert %{outcome: {:error, {:disable_auto_merge_failed, :forbidden}}} = Apply.apply(red, ctx(:merging, facts: %{auto_merge: :armed})) end)
      Process.delete(:disable_auto_merge)

      Process.put(:move_result, {:error, :linear_down})
      capture_log(fn -> assert %{outcome: {:error, {:move_failed, :ci_fix_enter_merging, :linear_down}}, attempts: %{red: 0}} = Apply.apply(red, ctx(:merging)) end)

      store = [run_store: FailingOriginStore]
      ctx = %{ctx(:merging) | opts: ctx(:merging).opts ++ store}
      capture_log(fn -> assert %{outcome: {:error, {:ci_fix_origin_failed, :store_down}}} = Apply.apply(red, ctx) end)
    end
  end

  test "return_to_origin moves a green CI Fix ticket back where it came from, approval carried" do
    :ok = CiFix.record_origin(@repo_key, @issue_id, "QA")
    action = action("R25", :return_to_origin, args: %{origin: :qa})

    assert %{outcome: :applied} = Apply.apply(action, ctx(:ci_fix, facts: %{origin: :qa}))
    assert_received {:move, @issue_id, "QA"}
    assert origin() == nil

    for origin <- [:code_review, :merging, :rework] do
      assert %{outcome: :applied} = Apply.apply(action("R25", :return_to_origin, args: %{origin: origin}), ctx(:ci_fix))
    end

    assert_received {:move, @issue_id, "Code Review"}
    assert_received {:move, @issue_id, "Merging"}
    assert_received {:move, @issue_id, "Rework"}
  end

  test "to_code_review turns auto-merge off and sends a person's push in Merging back to Code Review (D4)" do
    action = action("R11", :to_code_review, reason: "A person pushed to PR #7 while it was in Merging")

    assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))

    assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
    assert_received {:comment, @issue_id, disarmed}
    assert disarmed =~ "because a person pushed to it while it was in Merging"
    assert_received {:move, @issue_id, "Code Review"}
    assert_received {:comment, @issue_id, moved}
    assert moved =~ "A person pushed to PR #7 while it was in Merging: Symphony moved this ticket back to Code Review"
  end

  test "to_rework sends a conflict back after its fix runs, with nobody competing, to Rework (D16)" do
    reason = "The conflict with main came back after 3 fix runs and no open PR competes"

    assert %{outcome: :applied} = Apply.apply(action("R15a", :to_rework, reason: reason), ctx(:merging, facts: %{auto_merge: :armed}))

    assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
    assert_received {:move, @issue_id, "Rework"}
    assert_received {:comment, @issue_id, "Symphony moved this ticket to Rework: " <> rest}
    assert rest =~ reason
    refute Hold.held?(@repo_key, @issue_id, :needs_decision)
  end

  describe "landing" do
    test "update_branch merges the base in once and remembers the head it replaced" do
      assert %{outcome: :applied, attempts: %{updated_from: "head-1"}} = Apply.apply(action("R28", :update_branch), ctx(:merging))
      assert_received {:update_branch, @pr_url, "head-1", _opts}

      # A merge that conflicts is GitHub's answer: the next read shows the conflict.
      Process.put(:update_branch, {:error, :conflict})
      assert %{outcome: :applied, attempts: %{updated_from: nil}} = Apply.apply(action("R28", :update_branch), ctx(:merging))

      Process.put(:update_branch, {:error, :timeout})
      capture_log(fn -> assert %{outcome: {:error, :timeout}} = Apply.apply(action("R28", :update_branch), ctx(:merging)) end)
    end

    test "merge_now squash-merges a green, mergeable PR" do
      assert %{outcome: :applied} = Apply.apply(action("R29", :merge_now), ctx(:merging))
      assert_received {:squash_merge, @pr_url, %{pr_node_id: "PR_node", head_sha: "head-1", pr_title: "Add it"}, _opts}

      Process.put(:squash_merge, {:error, :not_mergeable})
      capture_log(fn -> assert %{outcome: {:error, :not_mergeable}} = Apply.apply(action("R29", :merge_now), ctx(:merging)) end)
    end

    test "arm turns auto-merge on once; a refusal lands it another way, a moved head is read again" do
      assert %{outcome: :applied} = Apply.apply(action("R30", :arm), ctx(:merging))
      assert_received {:enable_auto_merge, @pr_url, %{head_sha: "head-1"}, _opts}

      Process.put(:enable_auto_merge, {:error, :clean_status})
      capture_log(fn -> assert %{outcome: :applied} = Apply.apply(action("R30", :arm), ctx(:merging)) end)

      Process.put(:enable_auto_merge, {:error, :head_moved})
      capture_log(fn -> assert %{outcome: {:error, :head_moved}} = Apply.apply(action("R30", :arm), ctx(:merging)) end)
    end

    test "disarm turns auto-merge off once the ticket left Merging (R3), and says so" do
      assert %{outcome: :applied} = Apply.apply(action("R3", :disarm), ctx(:code_review))
      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:comment, @issue_id, comment}
      assert comment =~ "because this ticket left Merging for Code Review"

      Process.put(:disable_auto_merge, {:error, :forbidden})
      capture_log(fn -> assert %{outcome: {:error, {:disable_auto_merge_failed, :forbidden}}} = Apply.apply(action("R3", :disarm), ctx(:qa)) end)

      capture_log(fn -> assert %{outcome: {:error, {:disable_auto_merge_failed, :missing_pr_node_id}}} = Apply.apply(action("R3", :disarm), ctx(:qa, read: read(pr_node_id: nil))) end)
    end

    test "an audit event that can't be written is logged, and auto-merge is still off" do
      blocker = Path.join(System.tmp_dir!(), "apply-audit-#{System.unique_integer([:positive])}")
      File.write!(blocker, "")
      previous = Application.get_env(:symphony_elixir, :audit_log_dir)
      Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(blocker, "audit"))

      try do
        log = capture_log(fn -> assert %{outcome: :applied} = Apply.apply(action("R3", :disarm), ctx(:qa)) end)
        assert log =~ "Failed to record auto_merge_disabled audit event issue_id=#{@issue_id}"
        assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      after
        Application.put_env(:symphony_elixir, :audit_log_dir, previous)
        File.rm(blocker)
      end
    end

    test "land_agent says the landing agent takes the PR over; a comment Linear refuses is only logged" do
      assert %{outcome: :applied} = Apply.apply(action("R31", :land_agent, reason: "Branch protection kept PR #7 from merging"), ctx(:merging))
      assert_received {:comment, @issue_id, comment}
      assert comment =~ "so a landing agent will merge it instead"

      Process.put(:comment_result, {:error, :linear_down})
      log = capture_log(fn -> assert %{outcome: :applied} = Apply.apply(action("R31", :land_agent), ctx(:merging)) end)
      assert log =~ "PR watch could not comment on TP-7"
    end

    test "close_out moves a merged Merging ticket to Done and marks its PR finished" do
      assert %{outcome: :applied} = Apply.apply(action("R2", :close_out), ctx(:merging))
      assert_received {:move, @issue_id, "Done"}
      assert %{state: "merged"} = TicketPullRequest.get(@repo_key, @issue_id)

      :ok = TicketPullRequest.record_created(@repo_key, @issue_id, @pr_url, "auto/TP-7")
      Process.put(:move_result, {:error, :linear_down})
      capture_log(fn -> assert %{outcome: {:error, {:move_failed, :landing_done, :linear_down}}} = Apply.apply(action("R2", :close_out), ctx(:merging)) end)
      assert %{state: "open"} = TicketPullRequest.get(@repo_key, @issue_id)
    end

    test "close_out moves a merged ticket with started sub-tickets to the waiting state" do
      ctx = ctx(:merging)
      ctx = %{ctx | issue: %{ctx.issue | sub_issues: [%{id: "sub-1", identifier: "TP-8", state: "In Progress"}]}}

      assert %{outcome: :applied} = Apply.apply(action("R2", :close_out), ctx)
      assert_received {:move, @issue_id, "Waiting on sub-tickets"}
    end
  end

  describe "file_fix_ticket" do
    test "hands the red backstop to the self-heal lane, which files the fix ticket and holds the ticket on it" do
      :ok =
        RunStore.record_ticket_self_heal(@repo_key, @issue_id, %{
          component: "ci:specs",
          scope: @repo_key,
          signature: "s",
          fix_ticket: "TP-90",
          attempts: 10
        })

      failures = for n <- 1..10, do: %{check: "specs", error: "ERROR #{n}", head_sha: "head-#{n}abcdef"}
      action = action("R20", :file_fix_ticket, args: %{check: "specs", evidence: failures}, reason: "CI keeps failing: waiting on a fix ticket for the `specs` check")
      ctx = ctx(:code_review, facts: %{red_attempts: 10, max_red_attempts: 10, fix_failures: failures})

      {result, log} = with_log(fn -> Apply.apply(action, ctx) end)
      assert %{outcome: :applied, attempts: %{fix_ticket: "TP-90"}, action: recorded} = result
      assert log =~ "pr_watch.ci_fix_ticket issue_id=#{@issue_id}"
      assert log =~ "outcome=filed component=ci:specs fix_ticket=TP-90 red_attempts=10"
      assert recorded.reason == "CI keeps failing: waiting on TP-90, a fix ticket for the `specs` check"
      assert recorded.args.fix_ticket == "TP-90"

      assert_received {:heal, @issue_id, opts}
      # Without a failure for the head, the last fix run's is the cause.
      assert %{cause: {:ci_check_failed, "specs", "ERROR 10"}, pr_url: @pr_url, head_sha: "head-1"} = opts[:outcome]
      assert opts[:outcome].reason == "CI keeps failing: the `specs` check is still red on PR #7 after 10 of 10 CI Fix runs"
      assert length(opts[:outcome].findings) == 10
      assert hd(opts[:outcome].findings) == "specs at head-1a: ERROR 1"
      assert opts[:attempts] == 10
      assert opts[:repo_key] == @repo_key
      refute_received {:move, _id, _state}
      refute_received {:disable_auto_merge, _url, _node, _opts}
    end

    test "in Merging, auto-merge goes off before the hold is set" do
      ctx = ctx(:merging, facts: %{auto_merge: :armed, red_attempts: 10})
      assert %{outcome: :applied} = Apply.apply(action("R20", :file_fix_ticket, args: %{check: "specs"}), ctx)

      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:heal, @issue_id, _opts}

      Process.put(:disable_auto_merge, {:error, :forbidden})
      capture_log(fn -> assert %{outcome: {:error, _reason}} = Apply.apply(action("R20", :file_fix_ticket, args: %{check: "specs"}), ctx) end)
      refute_received {:heal, @issue_id, _opts}
    end

    test "the lane's other answers: a person decides, the count restarts, or nothing is recorded" do
      action = action("R20", :file_fix_ticket, args: %{})
      attempts = %{Attempts.new() | red: 10}

      Process.put(:heal_result, :escalated)
      {result, log} = with_log(fn -> Apply.apply(action, ctx(:qa, attempts: attempts)) end)
      assert %{outcome: :applied, action: %{owner: :person, reason: reason}} = result
      assert log =~ "pr_watch.ci_fix_ticket"
      assert log =~ "outcome=escalated component=ci:specs fix_ticket=none"
      assert reason =~ "after its fix ticket landed: a person decides"

      Process.put(:heal_result, :retry)
      assert %{outcome: :applied, attempts: %{red: 0}} = Apply.apply(action, ctx(:qa, attempts: attempts))

      Process.put(:heal_result, :held)
      assert %{outcome: :applied, attempts: %{red: 10}} = Apply.apply(action, ctx(:qa, attempts: attempts))

      Process.put(:heal_result, :filed)
      assert %{outcome: :applied, action: %{reason: "CI keeps failing: waiting on a fix ticket, a fix ticket for the `specs` check"}} = Apply.apply(action, ctx(:qa, attempts: attempts))

      Process.put(:heal_result, {:error, :linear_down})
      capture_log(fn -> assert %{outcome: {:error, :linear_down}} = Apply.apply(action, ctx(:qa, attempts: attempts)) end)
    end
  end

  describe "the same failure 3 runs in a row (D15 (c))" do
    test "the backstop's outcome names the streak, and its signature is the one the streak compares" do
      failure = %{check: "specs", error: "** (MatchError) no match of right hand side", head_sha: "head-1"}
      evidence = for n <- 1..3, do: %{failure | head_sha: "head-#{n - 1}"}
      facts = %{red_attempts: 3, max_red_attempts: 10, same_failure_streak: 3, fix_failures: evidence}
      ctx = ctx(:code_review, facts: facts, read: read(failure: failure))

      assert %{outcome: :applied} = Apply.apply(action("R20", :file_fix_ticket, args: %{check: "specs"}), ctx)
      assert_received {:heal, @issue_id, opts}
      outcome = opts[:outcome]

      assert outcome.reason == "CI keeps failing: the `specs` check is still red on PR #7 after 3 of 10 CI Fix runs, the last 3 in a row with the same failure"
      assert outcome.findings == for(n <- 0..2, do: "specs at head-#{n}: ** (MatchError) no match of right hand side")
      assert SymphonyElixir.SelfHeal.signature(outcome) == Attempts.signature(failure)
      assert SymphonyElixir.SelfHeal.signature(outcome) == "specs: ** (MatchError) no match of right hand side"
      assert SymphonyElixir.SelfHeal.component(outcome) == "ci:specs"
      assert Apply.backstop_outcome("specs", ctx) == outcome

      # Nothing to quote: an empty error, and evidence without heads.
      ctx = ctx(:code_review, facts: %{red_attempts: 10, fix_failures: [%{check: "specs", error: "boom"}]}, read: read())
      assert %{cause: {:ci_check_failed, "lint", "boom"}, findings: ["specs: boom"]} = Apply.backstop_outcome("lint", ctx)
      assert %{cause: {:ci_check_failed, "lint", ""}} = Apply.backstop_outcome("lint", ctx(:code_review, read: read()))
    end
  end

  describe "decisions a person makes, the ticket held in its phase" do
    test "a required check that never reported asks with three options, and records the question on the head (R17)" do
      action = action("R17", :decision, args: %{question: "q", options: []}, owner: :person)
      unreported = %{head_sha: "head-1", since: @now, asked: nil, answer: nil}
      decisions = [%{key: "c1", title: "Check build never reported on TP-7", answer: "1"}, %{key: "c2", title: "Other", answer: "x"}]
      ctx = ctx(:code_review, facts: %{missing_checks: ["build"]}, attempts: %{Attempts.new() | unreported: unreported}) |> Map.put(:decisions, decisions)

      assert %{outcome: :applied, attempts: attempts} = Apply.apply(action, ctx)
      assert %{asked: %{title: "Check build never reported on TP-7", prior: 1}} = attempts.unreported

      assert_received {:comment, @issue_id, "## Decision needed: Check build never reported on TP-7" <> body}
      assert body =~ "1. **Proceed without it for this PR**"
      assert body =~ "2. **Rerun the checks** (recommended)"
      assert body =~ "3. **Fix the workflow in Rework**"
      assert body =~ "within 30 minutes"

      assert %{decision: %{options: options, confirm: "Rework"}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Enum.map(options, & &1.label) == ["Proceed without it for this PR", "Rerun the checks", "Fix the workflow in Rework"]
      signals = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))
      assert [%{name: "decision requested", details: %{reason: "required_check_missing"}} | _] = signals
      refute_received {:disable_auto_merge, _url, _node, _opts}

      # No ticket record of decisions: none came before.
      Hold.clear(@repo_key, @issue_id, :needs_decision)
      assert %{attempts: %{unreported: %{asked: %{prior: 0}}}} = Apply.apply(action, Map.delete(ctx, :decisions))
    end

    test "a run GitHub cancelled again after its reruns asks to keep retrying or wait, naming the check and the cause (R19a)" do
      action = action("R19a", :decision, args: %{question: "q", options: []}, owner: :person)
      install = %{name: "install script", run_id: "22", job_id: 205, workflow_name: "macos", conclusion: "CANCELLED"}
      attempts = %{Attempts.new() | cancels: %{head_sha: "head-1", runs: %{"22" => %{reruns: 2, jobs: ["202", "204"], checks: ["install script"]}}, asked: nil, answer: nil}}
      decisions = [%{key: "c1", title: "Check install script keeps being cancelled on TP-7", answer: "2"}]
      ctx = ctx(:code_review, read: read(failed_checks: [install]), attempts: attempts) |> Map.put(:decisions, decisions)

      assert %{outcome: :applied, attempts: attempts} = Apply.apply(action, ctx)
      assert %{asked: %{title: "Check install script keeps being cancelled on TP-7", prior: 1}, answer: nil} = attempts.cancels

      assert_received {:comment, @issue_id, "## Decision needed: Check install script keeps being cancelled on TP-7" <> body}
      assert body =~ "GitHub cancelled the install script check on PR #7 of TP-7 3 times in a row without running it."
      assert body =~ "GitHub cancels a check it can't find a machine for"
      assert body =~ "1. **Keep retrying** (recommended)"
      assert body =~ "2. **Wait**"
      assert %{decision: %{options: options} = decision} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute decision[:confirm]
      assert Enum.map(options, & &1.label) == ["Keep retrying", "Wait"]
      signals = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))
      assert [%{name: "decision requested", details: %{reason: "check_cancelled"}} | _] = signals
      refute_received {:rerun_failed, _run_id, _opts}

      # A person chose to wait: nothing more is asked on the head, and the ticket waits on a person.
      waited = Attempts.cancel_answer(attempts, :wait)
      assert %{outcome: :recorded, action: wait} = Apply.apply(action, %{ctx | attempts: waited})
      assert %Action{rule: "R19a", kind: :wait, owner: :person, clears_when: "a person reruns the check or new changes are pushed"} = wait
      assert wait.reason == "A person chose to wait on the `install script` check, which GitHub keeps cancelling on PR #7"
    end

    test "an answer to R19a picks keep retrying or wait by number or label, or none" do
      assert Apply.cancelled_answer("1") == :rerun
      assert Apply.cancelled_answer("Keep retrying") == :rerun
      assert Apply.cancelled_answer("Wait") == :wait
      assert Apply.cancelled_answer("2") == :wait
      assert Apply.cancelled_answer("hmm") == :other
    end

    test "only protected paths red asks a person in any phase: allow the change, or Rework (R18, G10)" do
      action = action("R18", :decision, args: %{question: "q", options: []}, owner: :person)
      read = read(protected_paths: ["WORKFLOW.md", ".agents/skills"])

      assert %{outcome: :applied} = Apply.apply(action, ctx(:code_review, facts: %{failing_check: "protected paths"}, read: read))

      assert_received {:comment, @issue_id, "## Decision needed: Protected files changed on TP-7" <> body}
      files = "the workflow settings file, which runs commands on your Mac and the agents' instructions"
      assert body =~ "**Question:** PR #7 of TP-7 changes #{files}. Agents may change these only with a person's permission. Allow the change?"
      assert body =~ "Nothing on the ticket asks for this change."
      assert body =~ "**Allow the change**: TP-7 may change #{files}; PR #7 goes on through review and merges with the change, and the ticket continues in Code Review"
      assert body =~ "**Drop the change in Rework** (recommended): the ticket moves to Rework"
      assert body =~ "<!-- symphony:unlocks option=1 WORKFLOW.md .agents/skills -->"
      refute body =~ ~r/label/i
      assert %{decision: %{confirm: "Rework", unlocks: [["WORKFLOW.md", ".agents/skills"], []]}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute_received {:disable_auto_merge, _url, _node, _opts}
    end

    test "R18 recommends allowing the change the ticket's description or a person's ruling asks for" do
      action = action("R18", :decision, args: %{question: "q", options: []}, owner: :person)
      read = read(protected_paths: ["WORKFLOW.md"])

      for asked <- [[description: "Add the hook to `WORKFLOW.md`."], [rulings: [%{answer: "Change workflow.md too."}]]] do
        Hold.clear(@repo_key, @issue_id, :needs_decision)
        assert %{outcome: :applied} = Apply.apply(action, ctx(:qa, [read: read] ++ asked))

        assert_received {:comment, @issue_id, "## Decision needed: Protected files changed on TP-7" <> body}
        assert body =~ "**Allow the change** (recommended): TP-7 may change the workflow settings file"
        assert body =~ "The ticket itself asks for this change."
        assert body =~ "**Why recommended:** The ticket's description or a person's ruling asks for the change."
        assert body =~ "**Drop the change in Rework**: the ticket moves to Rework"
      end
    end

    test "R18 waits for the protected paths the PR changes before asking" do
      action = action("R18", :decision, args: %{question: "q", options: []}, owner: :person)

      capture_log(fn ->
        for read <- [read(), read(protected_paths: [])] do
          assert %{outcome: {:error, :protected_paths_unread}} = Apply.apply(action, ctx(:code_review, read: read))
        end
      end)

      refute_received {:comment, @issue_id, _body}
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
    end

    test "an answer to R17 picks an option by its number or label, or none" do
      assert Apply.unreported_answer("1") == :proceed
      assert Apply.unreported_answer("Proceed without it for this PR") == :proceed
      assert Apply.unreported_answer("2. once more please") == :rerun
      assert Apply.unreported_answer("Fix the workflow in Rework") == :rework
      assert Apply.unreported_answer("I'm not sure") == :other
      assert Apply.unreported_answer(nil) == :other

      assert Apply.same_title?(%{title: "Check build never reported on TP\\-7"}, "check  build never reported on TP-7")
      refute Apply.same_title?(%{title: "Check e2e never reported on TP-7"}, "Check build never reported on TP-7")
      refute Apply.same_title?(%{}, "Check build never reported on TP-7")
    end
  end

  describe "wait_for_competitors" do
    @leader %{issue_id: "issue-1", issue_identifier: "TP-1", pr_number: 1, pr_url: "https://github.com/acme/app/pull/1", title: "Lead", head_sha: "h1", files: ["SPEC.md"]}

    test "turns auto-merge off on a Merging PR only, then links each competitor and holds the ticket in place (R14a)" do
      action = action("R14a", :wait_for_competitors, args: %{prs: [@leader], step_behind: false})

      assert %{outcome: :applied, links: [link]} = Apply.apply(action, ctx(:qa, facts: %{auto_merge: :armed}))
      refute_received {:disable_auto_merge, _url, _node, _opts}
      assert_received {:add_blocked_by, "TP-1", @issue_id}
      assert %{issue_identifier: "TP-1", pr_number: 1, files: ["SPEC.md"], progress_at: @now} = link
      assert %{linked: true, step_behind: false, released: false} = link

      assert %{reason: "Waiting on TP-1 to land: they change the same files (SPEC.md)", waits_on: %{type: "landing", keys: ["TP-1"]}} =
               Hold.get(@repo_key, @issue_id, :blocked)

      assert_received {:label, @issue_id, "Blocked"}
      refute_received {:move, _id, _state}

      assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))
      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:comment, @issue_id, comment}
      assert comment =~ "because it conflicts with the base branch"
    end

    test "skips a link Linear already has, makes none for a PR without a ticket, and keeps the links a person released" do
      person = %{pr_number: 12, pr_url: "https://github.com/acme/app/pull/12", title: "Docs pass", files: ["SPEC.md", "README.md"]}

      released = %{
        issue_id: "issue-9",
        issue_identifier: "TP-9",
        pr_number: 9,
        files: ["SPEC.md"],
        linked: false,
        step_behind: false,
        released: true
      }

      action = action("R15", :wait_for_competitors, args: %{prs: [@leader, person], step_behind: true})
      ctx = ctx(:code_review, blocked_by: [%{id: "issue-1", identifier: "TP-1", state: "QA"}], links: [released])

      assert %{outcome: :applied, links: [^released, leader, other]} = Apply.apply(action, ctx)
      refute_received {:add_blocked_by, _blocker, _issue_id}
      assert %{linked: false, step_behind: true} = leader
      assert %{pr_number: 12, linked: false, title: "Docs pass"} = other

      assert Hold.get(@repo_key, @issue_id, :blocked).reason ==
               "Waiting on TP-1 and PR #12 (Docs pass) to land: they change the same files (SPEC.md, README.md)"
    end

    test "a link Symphony recorded is still its own; one Linear refuses is logged and the ticket waits without it" do
      recorded = Map.merge(@leader, %{linked: true, step_behind: false, released: false, progress_at: @now})
      ctx = ctx(:qa, blocked_by: [%{id: "issue-1", identifier: "TP-1", state: "QA"}], links: [recorded])
      action = action("R14a", :wait_for_competitors, args: %{prs: [@leader], step_behind: false})
      assert %{links: [%{linked: true}]} = Apply.apply(action, ctx)
      refute_received {:add_blocked_by, _blocker, _issue_id}

      Process.put(:add_blocked_by, {:error, :linear_down})
      log = capture_log(fn -> assert %{outcome: :applied, links: [%{linked: false}]} = Apply.apply(action, ctx(:qa)) end)
      assert log =~ "could not link TP-1 as a blocker"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "applies again on a head it waited on before, and fails when the hold can't be set" do
      action = action("R14a", :wait_for_competitors, args: %{prs: [@leader], step_behind: false})
      applied = [%{head_sha: "head-1", rule: "R14a", kind: :wait_for_competitors, at: @now}]
      assert %{outcome: :applied} = Apply.apply(action, ctx(:qa, applied: applied))

      ctx = ctx(:qa, opts: [run_store: FailingHoldStore])
      capture_log(fn -> assert %{outcome: {:error, :store_down}, links: []} = Apply.apply(action, ctx) end)
    end
  end

  test "a Merging PR whose only red check is one a person clears asks a person, auto-merge off first (R18)" do
    action = action("R18", :decision, args: %{question: "Only the `protected paths` check is red", options: []}, owner: :person)
    :ok = RunStore.clear()
    :ok = TicketPullRequest.record_created(@repo_key, @issue_id, @pr_url, "auto/TP-7")
    read = read(protected_paths: ["config/settings_ui_exempt.yml"])

    assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}, read: read))

    assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
    assert_received {:comment, @issue_id, "## Decision needed: Protected files changed on TP-7" <> _rest}
    assert %{decision: %{question: question}} = Hold.get(@repo_key, @issue_id, :needs_decision)
    assert question =~ "changes the list of settings that need no control in the Mac app. Agents may change these only with a person's permission."
    signals = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))
    assert [%{name: "decision requested", details: %{reason: "protected_paths"}} | _] = signals
    assert [{"decision.requested", %{title: "Protected files changed on TP-7"}}] = ticket_events(@repo_key, @issue_id, ["decision.requested", "hold.set"])

    Process.put(:comment_result, {:error, :linear_down})
    capture_log(fn -> assert %{outcome: {:error, {:decision_request_failed, :linear_down}}} = Apply.apply(action, ctx(:merging, read: read)) end)
  end

  describe "the PR's lifecycle (TP-944)" do
    test "close_out closes a PR merged outside Merging, whoever merged it (R2)" do
      for phase <- [:in_progress, :code_review, :qa, :rework, :ci_fix] do
        :ok = TicketPullRequest.record_created(@repo_key, @issue_id, @pr_url, "auto/TP-7")
        assert %{outcome: :applied} = Apply.apply(action("R2", :close_out, reason: "PR #7 was merged"), ctx(phase))
        assert_received {:move, @issue_id, "Done"}
        assert %{state: "merged"} = TicketPullRequest.get(@repo_key, @issue_id)
      end

      ctx = ctx(:qa)
      ctx = %{ctx | issue: %{ctx.issue | sub_issues: [%{id: "sub-1", identifier: "TP-8", state: "In Progress"}]}}
      assert %{outcome: :applied} = Apply.apply(action("R2", :close_out), ctx)
      assert_received {:move, @issue_id, "Waiting on sub-tickets"}
    end

    test "a closed PR sends the ticket to Rework with its reason, auto-merge off and no question (R8, D5)" do
      reason = "PR #7 was closed without merging"

      assert %{outcome: :applied, moved_to: :rework} = Apply.apply(action("R8", :to_rework, reason: reason), ctx(:code_review, facts: %{auto_merge: :armed}))

      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:move, @issue_id, "Rework"}
      assert_received {:comment, @issue_id, "Symphony moved this ticket to Rework: PR #7 was closed without merging. A rework run opens a new pull request from main."}
      refute_received {:comment, @issue_id, _other}
      assert %{state: "closed"} = TicketPullRequest.get(@repo_key, @issue_id)
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      signals = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))
      assert [%{name: "review verdict", details: %{outcome: "pr_closed", to: "Rework"}} | _] = signals

      # A closed PR can't merge: auto-merge GitHub won't turn off doesn't hold the move back.
      Process.put(:disable_auto_merge, {:error, :closed})
      log = capture_log(fn -> assert %{outcome: :applied} = Apply.apply(action("R8", :to_rework, reason: reason), ctx(:merging, facts: %{auto_merge: :armed})) end)
      assert log =~ "could not turn auto-merge off on the closed #{@pr_url}"
      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:move, @issue_id, "Rework"}

      # Without auto-merge there is nothing to turn off; a move Linear refuses is decided again.
      Process.put(:move_result, {:error, :linear_down})
      capture_log(fn -> assert %{outcome: {:error, {:move_failed, :pr_closed, :linear_down}}} = Apply.apply(action("R8", :to_rework, reason: reason), ctx(:qa)) end)
      refute_received {:disable_auto_merge, _url, _node, _opts}
    end

    test "a draft Merging PR has auto-merge turned off while a person holds it (R10)" do
      action = action("R10", :wait, reason: "A person marked PR #7 as a draft", owner: :person)

      assert %{outcome: :applied, applied: [%{rule: "R10"}] = applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))
      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:comment, @issue_id, comment}
      assert comment =~ "because a person marked it as a draft. Marking it ready for review turns auto-merge back on."

      assert %{outcome: :recorded} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}, applied: applied))
      assert %{outcome: :recorded} = Apply.apply(action, ctx(:merging))
      refute_received {:disable_auto_merge, _url, _node, _opts}

      Process.put(:disable_auto_merge, {:error, :boom})
      capture_log(fn -> assert %{outcome: {:error, {:disable_auto_merge_failed, :boom}}} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed})) end)
    end

    test "review comments send a reviewed ticket back to In Progress on the same PR (R13, D8)" do
      action = action("R13", :to_in_progress, reason: "PR #7 has review comments to address")

      assert %{outcome: :applied, moved_to: :in_progress} = Apply.apply(action, ctx(:qa))
      assert_received {:move, @issue_id, "In Progress"}
      assert_received {:comment, @issue_id, "Symphony moved this ticket back to In Progress: PR #7 has review comments to address. The run addresses them on the same pull request."}
      refute_received {:disable_auto_merge, _url, _node, _opts}

      assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))
      assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
      assert_received {:comment, @issue_id, disarmed}
      assert disarmed =~ "because it has review comments to address"
      assert_received {:move, @issue_id, "In Progress"}

      Process.put(:move_result, {:error, :linear_down})
      capture_log(fn -> assert %{outcome: {:error, {:move_failed, :review_rework, :linear_down}}} = Apply.apply(action, ctx(:code_review)) end)
    end

    test "a ticket past In Progress with no PR asks a person, and stays where it is (R6)" do
      action = action("R6", :decision, args: %{question: "q", options: []}, owner: :person)

      assert %{outcome: :applied} = Apply.apply(action, ctx(:code_review, read: nil, facts: %{pr: :missing}))

      assert_received {:comment, @issue_id, "## Decision needed: No pull request on TP-7" <> request}
      assert request =~ "TP-7 (Add it) is in Code Review, but Symphony finds no pull request for it"
      assert %{decision: %{options: options}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Enum.map(options, & &1.label) == ["Attach the PR", "Restart", "Cancel"]
      refute_received {:move, _id, _state}

      signals = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))
      assert [%{name: "decision requested", details: %{reason: "pr_missing"}} | _] = signals

      # A ticket read without its title is named by its identifier alone.
      Hold.clear(@repo_key, @issue_id, :needs_decision)
      untitled = ctx(:merging, read: nil, facts: %{pr: :missing})
      assert %{outcome: :applied} = Apply.apply(action, %{untitled | issue: %{untitled.issue | title: nil}})
      assert_received {:comment, @issue_id, "## Decision needed: No pull request on TP-7\n\n**Question:** TP-7 is in Merging, but" <> _rest}
    end

    test "a PR on another base asks a person, and retargets it once they say to put it back (R7)" do
      action = action("R7", :decision, args: %{question: "q", options: []}, owner: :person)
      read = read(base_ref: "release", base_branch: "main")

      assert %{outcome: :applied} = Apply.apply(action, ctx(:qa, read: read, facts: %{base: :changed}))
      assert_received {:comment, @issue_id, "## Decision needed: PR #7 of TP-7 merges into release, not main" <> request}
      assert request =~ "PR #7 of TP-7 (Add it) merges into the release branch, not into main"
      assert %{decision: %{options: [%{label: "Put the base back", recommended: true}, %{label: "Accept the new base"}]}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute_received {:change_base, _url, _base, _opts}

      put_back = ctx(:qa, read: Map.put(read, :base_answer, :put_back), facts: %{base: :changed})
      assert %{outcome: :applied} = Apply.apply(action, put_back)
      assert_received {:change_base, @pr_url, "main", opts}
      assert opts[:repo] == "acme/app"
      assert_received {:comment, @issue_id, "Symphony changed PR #7 to merge into main again, as a person decided."}

      Process.put(:change_base, {:error, :forbidden})
      capture_log(fn -> assert %{outcome: {:error, :forbidden}} = Apply.apply(action, put_back) end)
    end

    test "base_answer/3 reads a person's answer to R7's question from the recorded decisions" do
      issue = %Issue{id: @issue_id, identifier: "TP-7"}
      read = read(base_ref: "release", base_branch: "main")
      decision = fn title, answer -> %{key: "c-1", title: title, question: "", answer: answer} end

      assert Apply.base_answer([], issue, read) == nil
      assert Apply.base_answer([decision.("PR \\#7 of TP-7 merges into release, not main", "Put the base back")], issue, read) == :put_back
      assert Apply.base_answer([decision.("PR #7 of TP-7 merges into release, not main", "2")], issue, read) == :accept
      assert Apply.base_answer([decision.("PR #7 of TP-7 merges into release, not main", "Whatever you think")], issue, read) == nil
      assert Apply.base_answer([decision.("PR #7 of TP-7 merges into hotfix, not main", "Accept the new base")], issue, read) == nil
      assert Apply.base_answer([decision.("The pull request of TP-7 merges into release, not main", "1")], issue, %{read | pr_url: nil}) == :put_back
    end
  end
end
