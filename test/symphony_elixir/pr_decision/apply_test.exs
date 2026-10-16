defmodule SymphonyElixir.PrDecision.ApplyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiFix, Hold, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrDecision.{Action, Apply, Facts}
  alias SymphonyElixir.PrWatch.Attempts

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
    for {name, arity} <- [rerun_failed: 2, enable_auto_merge: 3, squash_merge: 3, disable_auto_merge: 3, update_branch: 3] do
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

  defmodule FailingOriginStore do
    def set_ci_fix_origin(_repo_key, _issue_id, _origin), do: {:error, :store_down}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", pr_review_mode: "polling", ci: %{enabled: true, log_excerpt_lines: 50})
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
      issue: %Issue{id: @issue_id, identifier: "TP-7", title: "Add it", state: Keyword.get(attrs, :state, phase_name(phase)), url: "https://linear.app/i/TP-7"},
      read: Keyword.get(attrs, :read, read()),
      facts: facts,
      attempts: Keyword.get(attrs, :attempts, Attempts.new()),
      applied: Keyword.get(attrs, :applied, []),
      fix: %{ci_failure: nil, pr_conflict: nil},
      now: @now,
      opts: [tracker: Tracker, github: GitHub, self_heal: SelfHeal]
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
        {action("R8", :to_rework), ctx(:code_review)},
        {action("R13", :to_in_progress), ctx(:qa)},
        {action("R6", :decision, args: %{question: "q", options: []}, owner: :person), ctx(:merging)},
        {action("R18", :decision, args: %{question: "q", options: []}, owner: :person), ctx(:code_review)},
        {action("R15", :wait_for_competitors, args: %{prs: [], step_behind: true}), ctx(:merging)},
        {action("R2", :close_out), ctx(:code_review)},
        {action("R4", :wait), ctx(:code_review)},
        {action("R27", :dispatch, args: %{phase: :qa}), ctx(:qa)}
      ]

      for {action, ctx} <- cases do
        assert %{outcome: :recorded, action: ^action, applied: []} = Apply.apply(action, ctx), inspect(action.rule)
      end

      refute_received {:move, _id, _state}
      refute_received {:comment, _id, _body}
    end

    test "CI rows wait for `pull_requests.checks`, and landing rows and a Merging conflict for auto-merge" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", pr_review_mode: "polling", pr_review_auto_merge: false, ci: %{enabled: false})

      for {action, phase} <- [
            {action("R22", :rerun_failed), :code_review},
            {action("R21", :ci_fix, args: %{origin: :qa, cause: :red}), :qa},
            {action("R30", :arm), :merging},
            {action("R3", :disarm), :qa},
            {action("R14", :ci_fix, args: %{origin: :merging, cause: :conflict}), :merging}
          ] do
        assert %{outcome: :recorded} = Apply.apply(action, ctx(phase))
      end

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

    test "a cancelled run's rerun (R19) spends nothing, and a head with no run id has nothing to rerun" do
      assert %{outcome: :applied, attempts: attempts} = Apply.apply(action("R19", :rerun_failed), ctx(:qa))
      assert attempts == Attempts.new()

      assert %{outcome: :applied, attempts: %{reruns: %{"head-1" => ["specs"]}}} =
               Apply.apply(action("R22", :rerun_failed), ctx(:qa, read: read(failed_checks: [%{name: "specs", run_id: nil}])))

      refute_received {:rerun_failed, nil, _opts}
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
      assert %{red: 1, conflict: 0, fix_failures: [%{check: "specs", error: "ERROR: specs failed"}]} = attempts

      assert %{commit_sha: "head-1", head_ref_name: "auto/TP-7", failed_checks: [%{name: "specs"}], approved: false} = failure
      assert failure.log_excerpt =~ "ERROR: specs failed"
      refute_received {:disable_auto_merge, _url, _node, _opts}
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
      :ok = RunStore.record_ticket_self_heal(@repo_key, @issue_id, %{component: "ci:specs", scope: @repo_key, signature: "s", fix_ticket: "TP-90", attempts: 10})
      failures = for n <- 1..10, do: %{check: "specs", error: "ERROR #{n}"}
      action = action("R20", :file_fix_ticket, args: %{check: "specs", evidence: failures}, reason: "CI keeps failing: waiting on a fix ticket for the `specs` check")
      ctx = ctx(:code_review, facts: %{red_attempts: 10, fix_failures: failures})

      assert %{outcome: :applied, attempts: %{fix_ticket: "TP-90"}, action: recorded} = Apply.apply(action, ctx)
      assert recorded.reason == "CI keeps failing: waiting on TP-90, a fix ticket for the `specs` check"
      assert recorded.args.fix_ticket == "TP-90"

      assert_received {:heal, @issue_id, opts}
      assert %{cause: {:ci_check_failed, "specs"}, pr_url: @pr_url, head_sha: "head-1"} = opts[:outcome]
      assert opts[:outcome].reason =~ "the `specs` check is still red on PR #7 after 10 CI Fix runs"
      assert length(opts[:outcome].findings) == 10
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
      assert %{outcome: :applied, action: %{owner: :person, reason: reason}} = Apply.apply(action, ctx(:qa, attempts: attempts))
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

  test "wait_for_competitors turns auto-merge off on a Merging PR that conflicts, and does nothing elsewhere (R14a)" do
    action = action("R14a", :wait_for_competitors, args: %{prs: [%{issue_identifier: "TP-1", files: ["a.ex"]}], step_behind: false})

    assert %{outcome: :applied} = Apply.apply(action, ctx(:qa, facts: %{auto_merge: :armed}))
    refute_received {:disable_auto_merge, _url, _node, _opts}

    assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))
    assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
    assert_received {:comment, @issue_id, comment}
    assert comment =~ "because it conflicts with the base branch"
  end

  test "a Merging PR whose only red check is one a person clears asks a person, auto-merge off first (R18)" do
    action = action("R18", :decision, args: %{question: "Only the `protected paths` check is red", options: []}, owner: :person)

    assert %{outcome: :applied} = Apply.apply(action, ctx(:merging, facts: %{auto_merge: :armed}))

    assert_received {:disable_auto_merge, @pr_url, "PR_node", _opts}
    assert_received {:comment, @issue_id, "## Decision needed: Protected files changed on TP-7" <> _rest}
    assert %{decision: %{question: question}} = Hold.get(@repo_key, @issue_id, :needs_decision)
    assert question =~ "changes files that agents may only change with a person's permission"
    assert [%{name: "decision requested", details: %{reason: "protected_paths"}} | _] = TicketState.recent_signals(RunStore.get_ticket_state(@repo_key, @issue_id))

    Process.put(:comment_result, {:error, :linear_down})
    capture_log(fn -> assert %{outcome: {:error, {:decision_request_failed, :linear_down}}} = Apply.apply(action, ctx(:merging)) end)
  end
end
