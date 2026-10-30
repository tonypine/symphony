defmodule SymphonyElixir.CodeReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CiFix
  alias SymphonyElixir.CodeReview
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Hold
  alias SymphonyElixir.HumanActions.PlainWords
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.NeedsDecisionHold
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.Questions
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketSignals

  @repo_key "repo-code-review"
  @issue_id "issue-code-review"

  # The real reviewer runs the escalation rules' check on the diff context it built, before it
  # starts, and returns the reasons with its verdict (`ReviewAgent.evaluate/4`); the fake does the
  # same with the diff context its result carries.
  defmodule FakeReviewAgent do
    def evaluate(issue, _workspace, _settings, opts) do
      send(self(), {:reviewed, issue.id, issue.state})

      case Process.get(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: "looks good"}}) do
        {:ok, result} -> {:ok, Map.put(result, :escalation_reasons, Keyword.fetch!(opts, :escalation_rules).(Map.get(result, :source, %{})))}
        error -> error
      end
    end
  end

  defmodule FakeTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state})
      Process.get(:fake_tracker_result, :ok)
    end

    def create_comment(issue_id, body) do
      send(self(), {:commented, issue_id, body})
      Process.get(:fake_tracker_comment_result, :ok)
    end
  end

  # The QA run/skip decision an approve carries. Driven from the test rather than from git; the rule
  # itself is tested in `QaPolicyTest`.
  defmodule FakeQaPolicy do
    @playbook %{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}

    def decide(_issue, _settings, _opts) do
      Process.get(:fake_qa_policy_result, {:run, [@playbook], "the change delivers or updates a user journey"})
    end
  end

  defmodule OptsReviewAgent do
    def evaluate(_issue, _workspace, _settings, opts) do
      send(self(), {:review_opts, opts})
      {:ok, %{verdict: :approve, comments: [], reason: nil}}
    end
  end

  setup do
    RunStore.delete_ticket_state(@repo_key, @issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@repo_key, @issue_id) end)
    :ok
  end

  defp settings!(attrs) do
    assert {:ok, settings} = Schema.parse(attrs)
    settings
  end

  # A designed repo with the reviewer on, which is what a Code Review state needs to have a reviewer
  # run at all; `reviewer_disabled_settings/0` is the config this module must refuse to review under.
  defp designed_settings(extra \\ %{}) do
    settings!(
      Map.merge(
        %{
          "tracker" => %{"kind" => "memory"},
          "review_agent" => %{"enabled" => true, "kind" => "codex", "command" => "codex app-server"}
        },
        extra
      )
    )
  end

  defp own_ticket_patterns do
    %{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"ticket_patterns_builtin" => false, "ticket_patterns" => ["(?i)do not ship"]}}}}
  end

  defp reviewer_disabled_settings do
    settings!(%{"tracker" => %{"kind" => "memory"}})
  end

  defp issue(state \\ "Code Review") do
    %Issue{
      id: @issue_id,
      identifier: "TP-815",
      title: "Land the Code Review state",
      state: state,
      repo_key: @repo_key
    }
  end

  # A real checkout, so the verdict really binds to the head the reviewer judged.
  defp git_workspace! do
    dir = Path.join(System.tmp_dir!(), "code-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "first"], cd: dir)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, String.trim(head)}
  end

  defp run(workspace, opts, state \\ "Code Review") do
    CodeReview.run(
      issue(state),
      workspace,
      [review_agent: FakeReviewAgent, tracker: FakeTracker, qa_policy: FakeQaPolicy] ++ opts
    )
  end

  defp run_with(agent, workspace, opts, state \\ "Code Review") do
    CodeReview.run(issue(state), workspace, [review_agent: agent, tracker: FakeTracker] ++ opts)
  end

  defp verdicts, do: SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")
  defp signals, do: SymphonyElixir.Handoff.signals(@repo_key, @issue_id)

  # A reviewer result carrying the diff it judged, the way `ReviewAgent.evaluate/4` returns one.
  defp approve_from(range, inventory) do
    source = %{git_range: range, changed_file_inventory: inventory}
    {:ok, %{verdict: :approve, comments: [], reason: "ok", source: source}}
  end

  defp approve_result(inventory) do
    {:ok, %{verdict: :approve, comments: [], reason: "looks good", source: %{changed_file_inventory: inventory}}}
  end

  # `lib/app/secret_store.ex` matches the built-in sensitive-area glob `**/*secret*`, so a repo with
  # no escalation config of its own still tells the reviewer about a change to it.
  defp risky_file do
    %{
      path: "lib/app/secret_store.ex",
      additions: 2,
      deletions: 0,
      patch: "+++ b/lib/app/secret_store.ex\n@@ -1 +1,2 @@\n def read, do: :ok\n+def token, do: read()\n"
    }
  end

  defp plain_file do
    %{
      path: "lib/app/widget.ex",
      additions: 3,
      deletions: 1,
      patch: "+++ b/lib/app/widget.ex\n@@ -1 +1,3 @@\n-def widget, do: :old\n+def widget, do: :ok\n"
    }
  end

  # An escalation pauses the ticket in Code Review on a Needs Decision hold whose confirmation
  # continues into QA: it posts the decision request and moves nothing.
  defp assert_escalated(recommended) do
    assert_received {:commented, @issue_id, body}
    assert body =~ "## Decision needed: Code Review escalated TP-815"
    assert body =~ "the ticket stays in Code Review until the decision is recorded"
    assert body =~ "#{recommended}** (recommended)"
    assert body =~ "Code Review could not settle TP-815 (Land the Code Review state) on its own."
    assert body =~ "**If unanswered:** TP-815 stays in Code Review and goes no further."
    assert PlainWords.tokens(body) == []
    refute_received {:moved, @issue_id, _state}

    hold = Hold.get(@repo_key, @issue_id, :needs_decision)
    assert MergeConfirmation.confirm_target(hold) == "QA"
    body
  end

  describe "reviewer_run?/2" do
    test "is true only for the configured Code Review state" do
      assert CodeReview.reviewer_run?(issue(), designed_settings())
      assert CodeReview.reviewer_run?(issue(" code review "), designed_settings())
      refute CodeReview.reviewer_run?(issue("In Progress"), designed_settings())
      refute CodeReview.reviewer_run?(%Issue{id: "x", state: nil}, designed_settings())
    end
  end

  describe "run/3" do
    test "skips every ticket that is not a Code Review ticket" do
      assert :skip = run("/tmp/workspace", [settings: designed_settings()], "In Progress")
      refute_received {:reviewed, _, _}
    end

    test "skips a non-issue or a workspace-less call" do
      assert :skip = CodeReview.run(%{}, "/tmp/workspace", settings: designed_settings())
      assert :skip = CodeReview.run(issue(), nil, settings: designed_settings())
    end

    test "a repo with the reviewer off is never reviewed and never approved" do
      disabled = reviewer_disabled_settings()

      assert :ok = run("/tmp/workspace", settings: disabled)
      refute_received {:reviewed, _, _}
      refute_received {:moved, _, _}

      assert [%{name: "code_review_reviewer_disabled"}] = SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
      assert SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review") == []

      # The reason is recorded once, not again on the next dispatch of the parked ticket.
      assert :ok = run("/tmp/workspace", settings: disabled)
      assert [%{name: "code_review_reviewer_disabled"}] = SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "an approve verdict binds the head and carries the ticket on to QA" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{kind: "code_review", head_sha: ^head, outcome: "approve"}] =
               SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [
               %{
                 name: "code_review",
                 details: %{signal: "code_review_approve", target: "QA", qa_decision: "run", reason: reason}
               }
             ] = SymphonyElixir.Handoff.signals(@repo_key, @issue_id)

      assert reason == "the change delivers or updates a user journey"
    end

    test "an approve the CI Fix lane re-bound to this head carries the ticket on without a second review" do
      {workspace, head} = git_workspace!()

      # A mechanical repair pushed this head; the lane re-binds the approval it carries to it.
      :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "the-repaired-head", "approve")
      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "Code Review", head, designed_settings())

      assert :ok = run(workspace, settings: designed_settings())

      # No reviewer ran: the ticket keeps the approval it already earned and QA is re-decided.
      refute_received {:reviewed, _, _}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{kind: "code_review", head_sha: ^head, outcome: "approve"} | _] =
               SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_approve", target: "QA", carried: true}} | _] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "an approve whose QA decision is skip lands the ticket in Merging, with the decision recorded" do
      {workspace, _head} = git_workspace!()
      Process.put(:fake_qa_policy_result, {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"})

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:moved, @issue_id, "Merging"}

      assert [
               %{
                 name: "code_review",
                 details: %{
                   signal: "code_review_approve_skip",
                   target: "Merging",
                   qa_decision: "skip",
                   reason: "the PR only changes docs, tests or `auto_review.skip_globs` paths"
                 }
               }
             ] = SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    # A workspace built from the base branch (the ticket's pull request closed) diffs empty: that is
    # no change at all, so the approve neither skips QA into Merging nor hands the ticket to QA.
    test "an approve whose head changes nothing holds the ticket in Code Review" do
      {workspace, _head} = git_workspace!()
      Process.put(:fake_qa_policy_result, {:nothing_to_verify, "the head changes no files against its base branch"})

      assert :ok = run(workspace, settings: designed_settings())

      refute_received {:moved, @issue_id, _state}
      assert_received {:commented, @issue_id, request}
      assert request =~ "## Decision needed: Restart or cancel TP-815"
      assert request =~ "has a pull request that changes nothing against the main branch"
      assert request =~ "the ticket stays in Code Review until the decision is recorded"
      assert %{decision: %{options: [%{label: "Restart", recommended: true}, %{label: "Cancel"}]}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute Enum.any?(signals(), &(&1.details[:signal] == "code_review_approve_skip"))
    end

    test "an empty-change hold that cannot be posted is reported" do
      {workspace, _head} = git_workspace!()
      Process.put(:fake_qa_policy_result, {:nothing_to_verify, "the head changes no files against its base branch"})
      Process.put(:fake_tracker_comment_result, {:error, :linear_down})

      capture_log(fn ->
        assert {:error, {:code_review_hold_failed, {:decision_request_failed, :linear_down}}} =
                 run(workspace, settings: designed_settings())
      end)

      # The question stays asked and held; its comment waits for the Inbox's sweep.
      assert [%{id: id}] = Questions.open({:ticket, @repo_key, @issue_id})
      assert %{decision: %{question_id: ^id}} = Hold.get(@repo_key, @issue_id, :needs_decision)
    end

    test "manual review on pauses an approve-skip on a merge confirmation instead of moving to Merging" do
      :ok = RunStore.clear()
      {workspace, _head} = git_workspace!()
      Process.put(:fake_qa_policy_result, {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"})

      assert :ok = run(workspace, settings: designed_settings(%{"manual_review" => "on"}))

      refute_received {:moved, @issue_id, _state}
      assert_received {:commented, @issue_id, request}
      assert request =~ "## Decision needed:"
      assert request =~ "Merge TP-815 (Land the Code Review state) into its base branch?"
      assert request =~ "Code Review: looks good"
      assert request =~ "QA: QA skipped: the PR only changes docs, tests or auto_review.skip_globs paths"
      assert request =~ "the ticket stays in Code Review until the decision is recorded"

      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert MergeConfirmation.confirm_target(Hold.get(@repo_key, @issue_id, :needs_decision)) == "Merging"

      assert [%{name: "code_review", details: %{signal: "merge_confirmation", target: "Merging", qa_decision: "skip"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)

      # The ticket did not move: the confirmation is its request, and no phase was entered.
      assert [{"question.asked", %{confirm: "Merging"}}] =
               ticket_events(@repo_key, @issue_id, ["decision.requested", "question.asked", "phase.entered", "hold.set"])
    end

    test "a merge confirmation that cannot be posted is reported" do
      {workspace, _head} = git_workspace!()
      Process.put(:fake_qa_policy_result, {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"})
      Process.put(:fake_tracker_comment_result, {:error, :rate_limited})

      assert {:error, {:code_review_merge_confirmation_failed, {:merge_confirmation_request_failed, :rate_limited}}} =
               run(workspace, settings: designed_settings(%{"manual_review" => "on"}))
    end

    test "an approve that runs QA still moves to QA with manual review on: only the merge waits" do
      {workspace, _head} = git_workspace!()

      assert :ok = run(workspace, settings: designed_settings(%{"manual_review" => "on"}))
      assert_received {:moved, @issue_id, "QA"}
      refute Hold.held_any?(@repo_key, @issue_id)
    end

    test "with no policy override the repo's own skip rule decides" do
      {workspace, _head} = git_workspace!()

      # The real `QaPolicy` cannot read this scratch checkout's diff, and a change whose paths
      # cannot be read runs QA rather than skipping it.
      assert :ok =
               CodeReview.run(issue(), workspace,
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:moved, @issue_id, "QA"}
    end

    test "a request_changes verdict posts its findings on the ticket, then moves to Rework" do
      {workspace, head} = git_workspace!()
      findings = ["Rename this (lib/a.ex:1-2) Suggested fix: call it b", "Test the error path (lib/a.ex:9-9) Suggested fix: add a test"]
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: findings, reason: "the error path is untested"}})

      assert :ok = run(workspace, settings: designed_settings())

      assert_received {:commented, @issue_id, body}

      assert body ==
               "## Symphony Code Review\n\nCode Review requested changes on head `#{String.slice(head, 0, 12)}`. The ticket moves to Rework, " <>
                 "and the rework run addresses these on the same pull request.\n\n**Reason:** the error path is untested\n\n**Findings:**\n\n" <>
                 "- Rename this (lib/a.ex:1-2) Suggested fix: call it b\n- Test the error path (lib/a.ex:9-9) Suggested fix: add a test"

      assert_received {:moved, @issue_id, "Rework"}
      assert [%{outcome: "request_changes"}] = SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_rework", reason: "the error path is untested"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    # TP-892: the person deferred the legacy partials to TP-891, and the reviewer flagged them again.
    test "a finding against a decision the person recorded ends in approval, not Rework or a new decision request" do
      {workspace, _head} = git_workspace!()

      decision =
        SymphonyElixir.Decisions.entry(
          "comment-1",
          ~D[2026-10-13],
          "Keep the legacy prompt partials",
          "Remove the legacy prompt partials here, or leave them for TP-891?",
          "Defer to TP-891: don't make that change."
        )

      {:ok, description} = SymphonyElixir.Decisions.put("Remove the Final verification flow.", [decision])

      partials = %{
        summary: "The legacy prompt partials are still here.",
        file: "priv/playbook/legacy.liquid",
        line_range: {1, 3},
        quoted_snippet: "legacy",
        suggested_fix: "Remove them.",
        decision: "D1"
      }

      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, findings: [partials], comments: ["The legacy prompt partials are still here."], reason: nil}})

      assert :ok =
               CodeReview.run(%{issue() | description: description}, workspace,
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy,
                 settings: designed_settings()
               )

      assert_received {:moved, @issue_id, "QA"}
      refute_received {:moved, @issue_id, "Rework"}
      refute_received {:commented, @issue_id, _body}
      refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert [%{outcome: "approve"}] = verdicts()
    end

    test "a request_changes verdict with no findings and no readable head still says why" do
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: [], reason: "out of scope"}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert_received {:commented, @issue_id, body}

      assert body ==
               "## Symphony Code Review\n\nCode Review requested changes. The ticket moves to Rework, and the rework run addresses these on the same pull request." <>
                 "\n\n**Reason:** out of scope"

      assert_received {:moved, @issue_id, "Rework"}
    end

    test "findings Linear refuses are logged, and the verdict still routes to Rework" do
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: ["Rename this"], reason: nil}})
      Process.put(:fake_tracker_comment_result, {:error, :rate_limited})

      log = capture_log(fn -> assert :ok = run("/tmp/workspace", settings: designed_settings()) end)

      assert log =~ "Failed to post the Code Review findings for TP-815: :rate_limited"
      assert log =~ ~s(findings=["Rename this"])
      assert_received {:moved, @issue_id, "Rework"}
    end

    test "a block verdict pauses the ticket on a Needs Decision hold, recommending Rework" do
      :ok = RunStore.clear()
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "touches protected files"}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert assert_escalated("Send to Rework") =~ "**Why:** touches protected files"

      assert [%{outcome: "block"}] = SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_escalate", reason: "touches protected files"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)

      # The verdict, then the escalation's request: the escalation signal is no phase move.
      assert [
               {"verdict.recorded", %{kind: "code_review", outcome: "block"}},
               {"question.asked", %{title: "Code Review escalated TP-815"}},
               {"pause.set", %{reason: "question"}}
             ] = ticket_events(@repo_key, @issue_id)
    end

    test "a reviewer block error pauses the ticket on a Needs Decision hold" do
      Process.put(
        :fake_review_result,
        {:error, {:review_agent_blocked, %{reason: "touches protected files", findings: [], comments: []}}}
      )

      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert_escalated("Send to Rework")

      assert [%{outcome: "block"}] = SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_escalate", reason: "touches protected files"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "an unknown verdict is refused without a move" do
      Process.put(:fake_review_result, {:ok, %{verdict: :shrug, comments: []}})

      assert {:error, {:code_review_unknown_verdict, :shrug}} = run("/tmp/workspace", settings: designed_settings())
      refute_received {:moved, _, _}
    end

    test "a reviewer failure is reported, not retried here" do
      Process.put(:fake_review_result, {:error, :model_unreachable})

      assert {:error, {:code_review_failed, :model_unreachable}} =
               run("/tmp/workspace", settings: designed_settings())
    end

    test "a tracker failure surfaces as a move failure" do
      Process.put(:fake_tracker_result, {:error, :rate_limited})

      assert {:error, {:code_review_move_failed, :code_review_approve, :rate_limited}} =
               run("/tmp/workspace", settings: designed_settings())
    end

    test "moves through the configured tracker when no tracker override is given" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 qa_policy: FakeQaPolicy
               )

      assert_received {:memory_tracker_state_update, @issue_id, "QA"}
    end

    test "an issue with no identifier is labelled by its id" do
      no_identifier = %Issue{id: @issue_id, state: "Code Review", repo_key: @repo_key}

      assert :ok =
               CodeReview.run(no_identifier, "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy
               )

      assert_received {:moved, @issue_id, "QA"}
    end

    test "a block verdict with only comments uses the first comment as the reason" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: ["Say why this is blocked."]}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert [%{name: "code_review", details: %{reason: "Say why this is blocked."}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "a block verdict with nothing recorded falls back to a default reason" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert [%{name: "code_review", details: %{reason: "reviewer blocked the change"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end
  end

  describe "the reviewer's options" do
    test "passes the repo's configured base branch to the reviewer" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: "reviewed-repo", workflow: Workflow.workflow_file_path(), team: "Test", base_branch: "develop"]]
      )

      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 repo_key: "reviewed-repo",
                 review_agent: OptsReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:review_opts, opts}
      assert opts[:base_branch] == "develop"
    end

    test "passes the run's event hook to the reviewer, so its session reaches the orchestrator" do
      on_message = fn _message -> :ok end

      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: OptsReviewAgent,
                 tracker: FakeTracker,
                 on_message: on_message
               )

      assert_received {:review_opts, opts}
      assert opts[:on_message] == on_message
    end

    test "an unknown repo key gives no base branch" do
      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 repo_key: "missing-repo",
                 review_agent: OptsReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:review_opts, opts}
      refute Keyword.has_key?(opts, :base_branch)
    end
  end

  describe "inconclusive reviews" do
    test "retry boundedly on the same head, then escalate" do
      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, :no_grounding}})

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      refute_received {:moved, _, _}

      # The third attempt has run out of retries, so it escalates instead of failing again.
      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert_escalated("Send to Rework")

      outcomes = @repo_key |> SymphonyElixir.Handoff.verdicts(@issue_id, "code_review") |> Enum.map(& &1.outcome)

      assert Enum.sort(outcomes) == ["inconclusive", "inconclusive", "inconclusive_escalated"]
    end

    test "record their cause on the verdict and on the run, so the run history counts it" do
      run_id = "run-inconclusive-#{System.unique_integer([:positive])}"

      :ok =
        RunStore.put_run(%{
          repo_key: @repo_key,
          run_id: run_id,
          issue_id: @issue_id,
          status: "running",
          started_at: DateTime.utc_now()
        })

      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, {:malformed_review_agent_response, :invalid_verdict}}})

      assert {:error, {:code_review_inconclusive, _cause}} = run("/tmp/workspace", settings: designed_settings(), run_id: run_id)

      assert [%{outcome: "inconclusive", details: %{cause: "invalid_verdict"}}] = verdicts()
      assert %{review_inconclusive_cause: "invalid_verdict"} = @repo_key |> RunStore.list_issue_runs(@issue_id) |> Enum.find(&(&1.run_id == run_id))

      # A run with no record, or no run at all, still retries and escalates as before.
      assert {:error, {:code_review_inconclusive, _cause}} = run("/tmp/workspace", settings: designed_settings(), run_id: "run-without-a-record")
      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert ["inconclusive_escalated", "invalid_verdict"] ==
               verdicts() |> Enum.find(&(&1.outcome == "inconclusive_escalated")) |> then(&[&1.outcome, &1.details.cause])
    end

    test "a retry on a different head starts its own count" do
      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, :no_grounding}})

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      {other_workspace, _head} = git_workspace!()

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run(other_workspace, settings: designed_settings())
    end
  end

  describe "risk rules inform the one review" do
    test "a change matching a risk rule is reviewed once, and its approval routes to QA" do
      {workspace, head} = git_workspace!()
      Process.put(:fake_review_result, approve_result([risky_file()]))

      assert :ok = run(workspace, settings: designed_settings())

      assert_received {:reviewed, @issue_id, "Code Review"}
      refute_received {:reviewed, _, _}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{kind: "code_review", head_sha: ^head, outcome: "approve"}] = verdicts()
      refute Enum.any?(signals(), &(&1.name in ["code_review_deepened", "code_review_deepening_applied"]))
    end

    test "a large change that mostly deletes goes to QA after one review, its verdict's summary opening with the three numbers" do
      {workspace, head} = git_workspace!()
      # A new module of 300 lines, and a legacy one that loses 2,150 lines and has 50 rewritten: 300
      # added, 50 changed and 2,100 removed. The test of the removed module is not counted.
      added = %{path: "lib/app/replacement.ex", additions: 300, deletions: 0, patch: ""}
      cleanup = %{path: "lib/app/legacy.ex", additions: 50, deletions: 2150, patch: ""}
      removed_test = %{path: "test/app/legacy_test.exs", additions: 0, deletions: 900, patch: ""}
      Process.put(:fake_review_result, approve_result([added, cleanup, removed_test]))

      assert :ok = run(workspace, settings: designed_settings())

      assert_received {:reviewed, @issue_id, "Code Review"}
      refute_received {:reviewed, _, _}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{payload: %{kind: "code_review", outcome: "approve", head: ^head, reason: reason}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"])

      assert reason ==
               "adds 300, changes 50, removes 2,100 lines outside docs and tests: 2,450 in all, over the limit of 1,500. looks good"
    end

    test "with the size rule counting added lines, a large deletion is no finding" do
      {workspace, _head} = git_workspace!()
      cleanup = %{path: "lib/app/legacy.ex", additions: 100, deletions: 2000, patch: ""}
      Process.put(:fake_review_result, approve_result([cleanup]))
      settings = designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"size_counts" => "added"}}}})

      assert :ok = run(workspace, settings: settings)

      assert_received {:moved, @issue_id, "QA"}
      assert [%{payload: payload}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"])
      assert payload.reason == "looks good"
    end

    test "the reviewer is handed the rule check, which reads the diff it builds" do
      Process.put(:fake_review_result, approve_result([plain_file()]))

      assert :ok = run_with(OptsReviewAgent, "/tmp/workspace", settings: designed_settings(), qa_policy: FakeQaPolicy)

      assert_received {:review_opts, opts}
      check = Keyword.fetch!(opts, :escalation_rules)
      assert [] = check.(%{changed_file_inventory: [plain_file()]})
      assert [%{rule: :path, detail: "lib/app/secret_store.ex matches `**/*secret*`"}] = check.(%{changed_file_inventory: [risky_file()]})
    end

    test "a risk rule set to ask pauses the approved ticket for a person, with the approval recommended and the reviewer's reasons" do
      {workspace, head} = git_workspace!()
      busy = %{path: "lib/app/orchestrator.ex", additions: 400, deletions: 0, patch: ""}
      git = fn ["log" | _args] -> {:ok, "lib/app/orchestrator.ex\n"} end
      Process.put(:fake_review_result, approve_from("base123..HEAD", [busy]))

      settings =
        designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"on_match" => %{"busy_files" => "ask"}}}}})

      assert :ok = run(workspace, settings: settings, git: git)

      assert_received {:reviewed, @issue_id, "Code Review"}
      refute_received {:reviewed, _, _}

      body = assert_escalated("Continue to QA")
      assert body =~ "**Why:** The reviewer approved the change: ok. It changes many lines of one of the repository's busiest files, and you asked to see those."

      assert [%{head_sha: ^head, outcome: "approve"}] = verdicts()
      assert [%{details: %{signal: "code_review_escalate", head: ^head}}] = signals() |> Enum.filter(&(&1.name == "code_review"))
    end

    test "a risk rule set to ask says the size in its question" do
      oversized = %{path: "lib/app/widget.ex", additions: 1600, deletions: 0, patch: ""}
      Process.put(:fake_review_result, approve_result([oversized]))

      settings =
        designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"on_match" => %{"max_changed_lines" => "ask"}}}}})

      assert :ok = run("/tmp/workspace", settings: settings)

      assert assert_escalated("Continue to QA") =~
               "It is a large change (it adds 1,600, changes 0, removes 0 lines outside docs and tests: 1,600 in all, over the limit of 1,500), and you asked to see those."
    end

    test "each risk rule set to ask says in plain words what it found" do
      lock = fn version -> ~s(%{"jason": {:hex, :jason, "#{version}", "abc", [:mix], [], "hexpm", "def"}}\n) end

      git = fn
        ["show", "base123:mix.lock"] -> {:ok, lock.("1.4.4")}
        ["show", "HEAD:mix.lock"] -> {:ok, lock.("2.0.0")}
        ["log" | _args] -> {:ok, ""}
      end

      files = [
        %{risky_file() | patch: "+++ b/lib/app/secret_store.ex\n+rm -rf build\n"},
        %{path: "mix.lock", additions: 1, deletions: 1, patch: ""}
      ]

      source = %{git_range: "base123..HEAD", changed_file_inventory: files}
      Process.put(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: nil, source: source}})
      ask = Map.new(~w(paths diff_patterns dependencies max_changed_lines busy_files), &{&1, "ask"})
      settings = designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"on_match" => ask}}}})

      assert :ok = run("/tmp/workspace", settings: settings, git: git)

      body = assert_escalated("Continue to QA")
      assert body =~ "**Why:** The reviewer approved the change. It touches a sensitive part of the code"
      assert body =~ "It adds a line that can delete data, and you asked to see those."
      assert body =~ "It adds a dependency or moves one to a new major version, and you asked to see those."
    end

    test "the reviewer's own reason keeps its full stop in the question" do
      Process.put(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: "Looks right.", source: %{changed_file_inventory: [risky_file()]}}})
      settings = designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"on_match" => %{"paths" => "ask"}}}}})

      assert :ok = run("/tmp/workspace", settings: settings)

      assert assert_escalated("Continue to QA") =~ "**Why:** The reviewer approved the change: Looks right. It touches a sensitive part"
    end

    test "a risk rule set to ask leaves a request for changes to go to Rework" do
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: ["Rename this"], reason: "Rename this", source: %{changed_file_inventory: [risky_file()]}}})
      settings = designed_settings(%{"auto_review" => %{"acceptance_gate" => %{"escalate" => %{"on_match" => %{"paths" => "ask"}}}}})

      assert :ok = run("/tmp/workspace", settings: settings)

      assert_received {:commented, @issue_id, body}
      assert body =~ "## Symphony Code Review"
      assert_received {:moved, @issue_id, "Rework"}
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
    end

    test "a risky change is not reviewed when the reviewer is off" do
      Process.put(:fake_review_result, approve_result([risky_file()]))

      assert :ok = run("/tmp/workspace", settings: reviewer_disabled_settings())

      refute_received {:reviewed, _, _}
      refute_received {:moved, _, _}
    end
  end

  describe "a deepened verdict recorded before the upgrade" do
    defp record_deepening(head, verdict, extra \\ %{}) do
      TicketSignals.record(@repo_key, @issue_id, "code_review_deepened", Map.merge(%{head: head, verdict: verdict, reason: "looks good", findings: []}, extra))
    end

    test "is routed once on the next dispatch, without reviewing, and the head is reviewed afresh after that" do
      {workspace, head} = git_workspace!()
      record_deepening(head, "approve")

      assert :ok = run(workspace, settings: designed_settings())

      # The deepening routes through the same approve edge a fresh verdict takes, so the QA
      # decision is made here exactly as it is for a fresh approval.
      assert_received {:moved, @issue_id, "QA"}
      refute_received {:reviewed, _, _}

      assert [%{name: "code_review", details: %{signal: "code_review_approve", qa_decision: "run", review_reason: "looks good"}}] =
               signals() |> Enum.filter(&(&1.name == "code_review"))

      # Routed once: a further dispatch on the head reviews it.
      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
    end

    test "a deepened request_changes routes to Rework with its findings" do
      {workspace, head} = git_workspace!()
      record_deepening(head, "request_changes", %{reason: "Rename this", findings: ["Rename this"]})

      assert :ok = run(workspace, settings: designed_settings())

      assert_received {:commented, @issue_id, body}
      assert body =~ "**Reason:** Rename this"
      assert body =~ "**Findings:**\n\n- Rename this"
      assert_received {:moved, @issue_id, "Rework"}
      refute_received {:reviewed, _, _}
    end

    test "a deepening recorded before it carried findings still routes its request_changes" do
      {workspace, head} = git_workspace!()
      TicketSignals.record(@repo_key, @issue_id, "code_review_deepened", %{head: head, verdict: "request_changes", reason: "Rename this"})

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:commented, @issue_id, body}
      refute body =~ "**Findings:**"
      assert_received {:moved, @issue_id, "Rework"}
      refute_received {:reviewed, _, _}
    end

    test "a deepened block escalates with the reason the second pass gave" do
      {workspace, head} = git_workspace!()
      record_deepening(head, "block", %{reason: "touches protected files"})

      assert :ok = run(workspace, settings: designed_settings())
      assert_escalated("Send to Rework")

      assert [%{details: %{signal: "code_review_escalate", reason: "touches protected files"}}] =
               signals() |> Enum.filter(&(&1.name == "code_review"))
    end

    test "a deepening whose move fails stays pending, and the retry routes it" do
      {workspace, head} = git_workspace!()
      record_deepening(head, "approve")
      Process.put(:fake_tracker_result, {:error, :rate_limited})

      assert {:error, {:code_review_move_failed, :code_review_approve, :rate_limited}} =
               run(workspace, settings: designed_settings())

      Process.put(:fake_tracker_result, :ok)
      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:moved, @issue_id, "QA"}
      refute_received {:reviewed, _, _}
    end

    test "a deepening an earlier version already performed is not replayed" do
      {workspace, head} = git_workspace!()
      record_deepening(head, "approve")
      TicketSignals.record(@repo_key, @issue_id, "code_review_deepening_applied", %{head: head})

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
    end

    test "a deepening recorded for another head is not routed on this one" do
      {workspace, _head} = git_workspace!()
      record_deepening("0000000000000000000000000000000000000000", "approve")
      Process.put(:fake_review_result, approve_result([plain_file()]))

      assert :ok = run(workspace, settings: designed_settings())

      # The stale deepening is ignored: the reviewer ran and the verdict routed as usual.
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "QA"}
    end

    test "a deepening is not routed when the head can't be read" do
      record_deepening("0000000000000000000000000000000000000000", "approve")

      assert :ok = run("/tmp/no-such-workspace-#{System.unique_integer([:positive])}", settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
    end
  end

  describe "the escalation rules (D12)" do
    test "a person rule on an approved ticket pauses it for a person, recommending QA" do
      Process.put(:fake_review_result, approve_result([plain_file()]))
      labelled = %{issue() | labels: ["needs-human"], description: "Adds a widget."}

      assert :ok =
               CodeReview.run(labelled, "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy
               )

      body = assert_escalated("Continue to QA")
      assert body =~ "**Why:** The reviewer approved the change: looks good. The ticket carries a label that asks for a person to review it before it goes on."
      assert [%{outcome: "approve"}] = verdicts()
      assert [%{details: %{signal: "code_review_escalate"}}] = signals() |> Enum.filter(&(&1.name == "code_review"))
    end

    test "a decided escalation continues into QA on the next dispatch without a second review of its head" do
      {workspace, head} = git_workspace!()
      Process.put(:fake_review_result, approve_result([plain_file()]))
      labelled = %{issue() | labels: ["needs-human"], description: "Adds a widget."}

      opts = [
        settings: designed_settings(),
        review_agent: FakeReviewAgent,
        tracker: FakeTracker,
        qa_policy: FakeQaPolicy
      ]

      assert :ok = CodeReview.run(labelled, workspace, opts)
      assert_escalated("Continue to QA")
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert [%{details: %{signal: "code_review_escalate", head: ^head}}] = signals() |> Enum.filter(&(&1.name == "code_review"))

      # The person's decision clears the hold, but its move into QA did not land: the ticket is
      # dispatched again on the same head, and performs the decision instead of reviewing.
      :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      TicketSignals.record(@repo_key, @issue_id, "decision returned", %{move: "decide", from: "Code Review", to: "Code Review"})
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: ["A second opinion"], reason: "a second opinion"}})

      assert :ok = CodeReview.run(labelled, workspace, opts)
      assert_received {:moved, @issue_id, "QA"}
      refute_received {:reviewed, _, _}
      refute_received {:commented, _, _}

      assert [%{details: %{signal: "code_review_approve", target: "QA", carried: true, reason: "a person decided its Code Review escalation"}} | _] =
               signals() |> Enum.filter(&(&1.name == "code_review"))

      # Performed once: a ticket brought back to Code Review on that head is reviewed again.
      assert :ok = CodeReview.run(%{labelled | labels: []}, workspace, opts)
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "Rework"}
    end

    test "an escalation whose decision moved the ticket elsewhere is reviewed afresh when it returns on that head" do
      {workspace, _head} = git_workspace!()
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "touches protected files"}})

      assert :ok = run(workspace, settings: designed_settings())
      assert_escalated("Send to Rework")

      :ok = Hold.clear(@repo_key, @issue_id, :needs_decision)
      TicketSignals.record(@repo_key, @issue_id, "decision returned", %{move: "decide", from: "Code Review", to: "Rework"})
      Process.put(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: "looks good"}})

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "QA"}
    end

    test "an escalation on another head does not stand in for a review of this one" do
      {workspace, _head} = git_workspace!()
      TicketSignals.record(@repo_key, @issue_id, "code_review", %{signal: "code_review_escalate", reason: "earlier", head: "0000000"})

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "QA"}
    end

    test "a ticket pattern is a person rule too, and asks along with a risk rule that informs" do
      Process.put(:fake_review_result, approve_result([risky_file()]))
      asked = %{issue() | description: "This must not auto-merge."}

      assert :ok = CodeReview.run(asked, "/tmp/workspace", settings: designed_settings(), review_agent: FakeReviewAgent, tracker: FakeTracker)

      body = assert_escalated("Continue to QA")
      assert body =~ "The ticket's own words ask for a person to review it"
      refute body =~ "sensitive part of the code"
    end

    test "with the built-in ticket patterns off, a ticket matching only a built-in one goes on to QA" do
      Process.put(:fake_review_result, approve_result([plain_file()]))
      asked = %{issue() | description: "This must not auto-merge."}

      assert :ok =
               CodeReview.run(asked, "/tmp/workspace",
                 settings: designed_settings(own_ticket_patterns()),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy
               )

      assert_received {:moved, @issue_id, "QA"}
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
    end

    test "a ticket without a title is named by its identifier alone" do
      Process.put(:fake_review_result, approve_result([plain_file()]))
      untitled = %{issue() | title: nil, labels: ["needs-human"], description: "Adds a widget."}

      assert :ok =
               CodeReview.run(untitled, "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy
               )

      assert_received {:commented, @issue_id, body}
      assert body =~ "**Question:** Code Review could not settle TP-815 on its own. How should it continue?"
    end

    test "with the built-in ticket patterns off, a configured one still pauses the ticket for a person" do
      Process.put(:fake_review_result, approve_result([plain_file()]))
      asked = %{issue() | description: "Do not ship this before the launch."}

      assert :ok =
               CodeReview.run(asked, "/tmp/workspace",
                 settings: designed_settings(own_ticket_patterns()),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy
               )

      assert assert_escalated("Continue to QA") =~ "The ticket's own words ask for a person to review it"
    end

    test "a ticket that only names the human review state isn't escalated" do
      Process.put(:fake_review_result, approve_result([plain_file()]))
      named = %{issue() | title: "Remove In Review and Human Review", description: "Tickets wait in `Human Review` until a person moves them out of the Human Review state."}

      assert :ok = CodeReview.run(named, "/tmp/workspace", settings: designed_settings(), review_agent: FakeReviewAgent, tracker: FakeTracker, qa_policy: FakeQaPolicy)

      assert_received {:moved, @issue_id, "QA"}
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil
    end

    test "a failed decision request is reported and nothing moves" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "no"}})
      Process.put(:fake_tracker_comment_result, {:error, :rate_limited})

      capture_log(fn ->
        assert {:error, {:code_review_escalation_failed, {:decision_request_failed, :rate_limited}}} =
                 run("/tmp/workspace", settings: designed_settings())
      end)

      refute_received {:moved, _, _}
      assert_received {:commented, @issue_id, _refused}
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
    end

    test "with Linear down the escalation is a question on the record, and its comment is posted once Linear is back" do
      :ok = RunStore.clear()
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "touches protected files"}})
      Process.put(:fake_tracker_comment_result, {:error, :linear_down})

      capture_log(fn ->
        assert {:error, {:code_review_escalation_failed, _down}} = run("/tmp/workspace", settings: designed_settings())
      end)

      assert_received {:commented, @issue_id, refused}

      # The Director's ticket page reads the question from the record.
      assert [%{id: id, title: "Code Review escalated TP-815", confirm: "QA"}] = Questions.open({:ticket, @repo_key, @issue_id})
      assert {:ok, %{reasons: [%{kind: :question, text: "Waiting for your answer: Code Review escalated TP-815"}]}} = Pauses.get({:ticket, @repo_key, @issue_id})

      # Linear is back: the Inbox's sweep reads the ticket with no request on it and posts the comment.
      Process.delete(:fake_tracker_comment_result)
      node = %{"id" => @issue_id, "state" => %{"name" => "Code Review"}, "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]}, "comments" => %{"nodes" => []}}
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings(), tracker: FakeTracker) == :none
      assert_received {:commented, @issue_id, ^refused}
      assert refused =~ "<!-- symphony:question #{id} -->"
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert [%{id: ^id}] = Questions.open({:ticket, @repo_key, @issue_id})
    end

    test "a dependency manifest's major bump informs the review, read from git in the workspace" do
      lock = fn version -> ~s(%{"jason": {:hex, :jason, "#{version}", "abc", [:mix], [], "hexpm", "def"}}\n) end
      manifest = %{path: "mix.lock", additions: 1, deletions: 1, patch: ""}

      git = fn
        ["show", "base123:mix.lock"] -> {:ok, lock.("1.4.4")}
        ["show", "HEAD:mix.lock"] -> {:ok, lock.("2.0.0")}
        ["log" | _args] -> {:ok, ""}
      end

      Process.put(:fake_review_result, approve_from("base123..HEAD", [manifest]))

      assert :ok = run("/tmp/workspace", settings: designed_settings(), git: git)

      assert_received {:reviewed, @issue_id, "Code Review"}
      refute_received {:reviewed, _, _}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{payload: %{reason: "mix.lock: jason 1.4.4 -> 2.0.0. ok"}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"])
    end

    test "a large change to one of the base branch's busy files informs the review" do
      busy = %{path: "lib/app/router.ex", additions: 400, deletions: 0, patch: ""}

      git = fn ["log", "--since=14.days.ago", "--no-renames", "--name-only", "--format=", "base123"] ->
        {:ok, "lib/app/router.ex\nlib/app/router.ex\nREADME.md\n"}
      end

      Process.put(:fake_review_result, approve_from("base123..HEAD", [busy]))

      assert :ok = run("/tmp/workspace", settings: designed_settings(), git: git)

      assert_received {:reviewed, @issue_id, "Code Review"}
      refute_received {:reviewed, _, _}
      assert_received {:moved, @issue_id, "QA"}

      assert [%{payload: %{reason: reason}}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"])
      assert reason =~ "lib/app/router.ex is one of the repository's busiest files, and this change adds 400, changes 0, removes 0 of its lines"
    end

    test "git that cannot be read, or an unreadable range, adds no manifest content and no busy files" do
      manifest = %{path: "package.json", additions: 1, deletions: 0, patch: ""}
      Process.put(:fake_review_result, approve_from("base123..HEAD", [manifest]))

      assert :ok = run("/tmp/workspace", settings: designed_settings(), git: fn _args -> :error end)
      assert_received {:moved, @issue_id, "QA"}

      Process.put(:fake_review_result, approve_from("no-range", [manifest]))
      # Without a base only the head's manifest is read, and no busy files are.
      git = fn
        ["show", "HEAD:package.json"] -> :error
        args -> flunk("git runs without a base: #{inspect(args)}")
      end

      assert :ok = run("/tmp/workspace", settings: designed_settings(), git: git)
      assert_received {:moved, @issue_id, "QA"}
    end

    test "a run on an SSH worker reads no git, and a local run reads the real workspace" do
      manifest = %{path: "mix.lock", additions: 1, deletions: 0, patch: ""}
      Process.put(:fake_review_result, approve_from("base123..HEAD", [manifest]))

      assert :ok = run("/tmp/workspace", settings: designed_settings(), worker_host: "worker-1")
      assert_received {:moved, @issue_id, "QA"}

      {workspace, head} = git_workspace!()
      Process.put(:fake_review_result, approve_from("#{head}..HEAD", [plain_file()]))

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:moved, @issue_id, "QA"}

      # A manifest that git can't show in the workspace (it isn't in the commit) is read as absent.
      Process.put(:fake_review_result, approve_from("#{head}..HEAD", [manifest]))

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:moved, @issue_id, "QA"}
    end
  end

  describe "the verdict's run" do
    defp verdict_runs do
      for event <- RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"]) do
        {event.payload.outcome, event.run_id}
      end
    end

    test "each review verdict names the review run that gave it" do
      Process.put(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: "looks good"}})
      assert :ok = run("/tmp/workspace", settings: designed_settings(), run_id: "run-cr-approve")

      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: ["Rename this"], reason: nil}})
      assert :ok = run("/tmp/workspace", settings: designed_settings(), run_id: "run-cr-changes")

      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "touches protected files"}})
      assert :ok = run("/tmp/workspace", settings: designed_settings(), run_id: "run-cr-block")

      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, :no_grounding}})
      assert {:error, _inconclusive} = run("/tmp/workspace", settings: designed_settings(), run_id: "run-cr-inconclusive")

      assert verdict_runs() == [
               {"approve", "run-cr-approve"},
               {"request_changes", "run-cr-changes"},
               {"block", "run-cr-block"},
               {"inconclusive", "run-cr-inconclusive"}
             ]
    end

    test "a verdict from a run given no id names none, and a carried approve names no run" do
      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert :ok = CodeReview.carry_verdict(@repo_key, @issue_id, "the-repaired-head")

      assert verdict_runs() == [{"approve", nil}, {"approve", nil}]
      assert [%{head_sha: "the-repaired-head"} | _] = verdicts()
    end
  end
end
