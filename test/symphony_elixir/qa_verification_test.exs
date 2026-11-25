defmodule SymphonyElixir.QaVerificationTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.QaVerificationSupport

  alias SymphonyElixir.CiFix
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.Pauses.Dependencies
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaVerification
  alias SymphonyElixir.QaVerificationSupport.AppPolicy
  alias SymphonyElixir.QaVerificationSupport.DevServerQaAgent
  alias SymphonyElixir.QaVerificationSupport.FailingTracker
  alias SymphonyElixir.QaVerificationSupport.FakeFixer
  alias SymphonyElixir.QaVerificationSupport.FakeQaAgent
  alias SymphonyElixir.QaVerificationSupport.FixTicketTracker
  alias SymphonyElixir.QaVerificationSupport.LivePolicy
  alias SymphonyElixir.QaVerificationSupport.NoPlaybookPolicy
  alias SymphonyElixir.QaVerificationSupport.NothingToVerifyPolicy
  alias SymphonyElixir.QaVerificationSupport.RunPolicy
  alias SymphonyElixir.QaVerificationSupport.SkipPolicy
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.SelfHeal
  alias SymphonyElixir.TicketPullRequest

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"
  @other_issue_id "issue-qa-verification-other"
  @symphony_repo_key "repo-symphony"
  @fix_ticket "TP-900"
  @pr_url "https://github.com/acme/repo/pull/816"
  @base_head "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

  @playbook %{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    RunStore.delete_ticket_state(@issue_id)
    RunStore.delete_ticket_state(@other_issue_id)

    # Every QA ticket here has its open pull request; the tests that close it say so.
    :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})
    :ok = TicketPullRequest.put(@repo_key, @other_issue_id, %{pr_url: "https://github.com/acme/repo/pull/817"})

    on_exit(fn ->
      RunStore.delete_ticket_state(@issue_id)
      RunStore.delete_ticket_state(@other_issue_id)
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end)

    :ok
  end

  defp custom_qa_settings, do: settings!(%{"tracker" => %{"kind" => "memory", "qa_state" => "Verification"}})

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # The fix ticket lands: it goes terminal, so the pause on it lifts.
  defp lift_fix_ticket_hold do
    Process.put(:fix_ticket_issue, {:ok, %Issue{id: "fix-ticket-id", identifier: @fix_ticket, state: "Done"}})
    assert {1, _cache} = Dependencies.sweep([issue()], ["Done", "Canceled"], repo_key: @repo_key, tracker: FixTicketTracker, build: %{sha: nil})
  end

  describe "qa_run?/2" do
    test "is true only for the configured QA state" do
      assert QaVerification.qa_run?(issue(), settings!())
      assert QaVerification.qa_run?(issue(" qa "), settings!())
      assert QaVerification.qa_run?(issue("Verification"), custom_qa_settings())
      refute QaVerification.qa_run?(issue("Code Review"), settings!())
      refute QaVerification.qa_run?(issue("Verification"), settings!())
      refute QaVerification.qa_run?(%Issue{id: "x", state: nil}, settings!())
    end
  end

  describe "journey/2" do
    test "is the ticket's `## User walkthrough` when it has one" do
      assert %{source: "the ticket's `## User walkthrough`", text: "1. Run `symphony check`."} =
               QaVerification.journey(issue())
    end

    test "carries the walkthrough's steps, each QA's while no event proves it: a description's `Proved by:` line proves nothing" do
      :ok = RunStore.clear()

      description = """
      ## User walkthrough

      1. Run `symphony check` → it passes. Proved by: `make-all` › `test/mix/tasks/check_test.exs`
      2. Read the output → it reads well. Proved by: `test/mix/tasks/check_test.exs`

      ## Acceptance criteria

      - It works.
      """

      assert %{steps: [%{number: 1, proof: %{by: :qa}, text: first}, %{number: 2, proof: %{by: :qa}}]} =
               QaVerification.journey(issue("QA", %{description: description}))

      assert first == "Run `symphony check` → it passes. Proved by: `make-all` › `test/mix/tasks/check_test.exs`"

      assert %{steps: []} = QaVerification.journey(issue("QA", %{description: "## Acceptance criteria\n\n- It works.\n"}))
      assert %{steps: []} = QaVerification.journey(issue("QA", %{description: nil}))
    end

    test "a recorded proof proves its step in a repo with no proof check" do
      :ok = RunStore.clear()
      record_proof!(1, "test/x_test.exs")
      description = "## User walkthrough\n\n1. Run it.\n2. Read it.\n"

      assert %{steps: [%{number: 1, proof: %{by: :test, test: "test/x_test.exs"}}, %{number: 2, proof: %{by: :qa}}]} =
               QaVerification.journey(issue("QA", %{description: description}))
    end

    test "reads the proofs recorded as evidence events, the latest a step's" do
      :ok = RunStore.clear()
      description = "## User walkthrough\n\n1. Run it.\n2. Read it.\n3. Look at it.\n"
      implementation = [actor: {:agent, "run-1", "implementation"}]

      for payload <- [
            %{caption: "step 2", proof: %{step: 2, test: "test/b_test.exs"}},
            %{caption: "a screenshot"},
            %{caption: "step 1", proof: %{step: 1, test: "test/c_test.exs"}},
            %{caption: "step 2 again", proof: %{step: 2, test: "test/d_test.exs"}}
          ] do
        {:ok, _event} = SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "evidence", payload, implementation)
      end

      assert %{
               steps: [
                 %{number: 1, proof: %{by: :test, test: "test/c_test.exs"}},
                 %{number: 2, proof: %{by: :test, test: "test/d_test.exs"}},
                 %{number: 3, proof: %{by: :qa}}
               ]
             } = QaVerification.journey(issue("QA", %{description: description}))

      journey = QaVerification.journey(issue("QA", %{id: nil, description: description}))
      assert %{steps: [%{proof: %{by: :qa}} | _rest]} = journey
    end

    test "a step that quotes a proof line in its prose is QA's to walk, its text whole" do
      description = """
      ## User walkthrough

      1. Let Symphony pick it up. Expected: two steps now end with `Proved by: <test path>` and the third is unchanged.
      2. Write a step ending with `Proved by: ci › test/x_test.exs` in the Symphony repo. Expected: the pre-check fails it.
      """

      :ok = RunStore.clear()

      assert %{steps: [%{number: 1, text: first, proof: %{by: :qa}}, %{number: 2, text: second, proof: %{by: :qa}}]} =
               QaVerification.journey(issue("QA", %{description: description}))

      assert first =~ "and the third is unchanged."
      assert second =~ "Expected: the pre-check fails it."
    end

    test "falls back to the acceptance criteria" do
      description = "Some context.\n\n## Acceptance criteria\n\n- It works.\n- It is fast.\n"

      assert %{source: "the ticket's acceptance criteria", text: "- It works.\n- It is fast."} =
               QaVerification.journey(issue("QA", %{description: description}))
    end

    test "asks the run to derive the journeys when the ticket names none" do
      assert %{source: "the ticket's walkthrough and acceptance criteria", text: nil} =
               QaVerification.journey(issue("QA", %{description: "Just context."}))
    end

    test "handles a heading with no body and a ticket with no description" do
      empty = issue("QA", %{description: "## User walkthrough\n\n## Acceptance criteria\n\n- It works.\n"})

      assert %{source: "the ticket's acceptance criteria", text: "- It works."} = QaVerification.journey(empty)

      assert %{text: nil} = QaVerification.journey(issue("QA", %{description: nil}))
    end
  end

  defp environment_paused! do
    ticket = {:ticket, @repo_key, @issue_id}
    {:ok, _pause} = Pauses.set(ticket, SelfHeal.environment_reason("worker_host"))
    {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "TP-9"))
    assert Pauses.why(ticket) == ["The QA machine is not reachable", "Waiting for TP-9 to finish"]
  end

  describe "run/3" do
    test "skips every ticket that is not a QA ticket" do
      assert :skip = run("/tmp/workspace", [], "Code Review")
      refute_received {:qa_agent_run, _, _}
      assert verdicts() == []
    end

    test "skips a non-issue or a workspace-less call" do
      opts = [settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent]

      assert :skip = QaVerification.run(%{}, "/tmp/workspace", opts)
      assert :skip = QaVerification.run(issue(), nil, opts)
    end

    test "a workspace head that cannot be read parks the ticket and records it once" do
      missing = Path.join(System.tmp_dir!(), "qa-verification-missing-#{System.unique_integer([:positive])}")

      assert :ok = run(missing, [])
      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_state_update, _, _}

      assert [%{name: "qa_head_unreadable"}] = Handoff.signals(@repo_key, @issue_id)

      # The next tick tries again but does not record the same fact twice.
      assert :ok = run(missing, [])
      assert [%{name: "qa_head_unreadable"}] = Handoff.signals(@repo_key, @issue_id)
    end

    test "a pass verdict binds to the head, publishes the report and moves to Merging" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, [])

      assert_received {:qa_agent_run, job, %Schema{}}
      assert job.sha == head
      assert job.playbooks == [@playbook]
      assert job.journey.source == "the ticket's `## User walkthrough`"
      assert job.issue.id == @issue_id

      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "## Symphony QA Report"
      assert report =~ "**Verdict:** pass → Merging"

      assert [%{kind: "qa", head_sha: ^head, outcome: "pass"}] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_pass", target: "Merging", reason: "every journey verified"}}] =
               Handoff.signals(@repo_key, @issue_id)
    end

    test "manual review on pauses a pass on a merge confirmation instead of moving to Merging" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, settings: settings!(%{"manual_review" => "on"}))

      # The run still happened, and its report is still published: only the step into Merging waits.
      assert_received {:qa_agent_run, job, %Schema{}}
      assert job.sha == head
      refute_received {:memory_tracker_state_update, @issue_id, _state}

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "## Symphony QA Report"

      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "## Decision needed:"
      assert request =~ "Merge TP-816 (Land the QA state) into its base branch?"
      assert request =~ "Recommendation: every journey verified; ready to merge"
      assert request =~ "the ticket stays in QA until the decision is recorded"

      assert [%{kind: "qa", head_sha: ^head, outcome: "pass"}] = verdicts()

      assert %{confirm: "Merging"} = question = deciding()
      assert MergeConfirmation.confirm_target(question) == "Merging"

      assert [%{name: "qa", details: %{signal: "merge_confirmation", target: "Merging", reason: reason}}] =
               Handoff.signals(@repo_key, @issue_id)

      assert reason == "every journey verified; ready to merge"
    end

    test "a pass with no summary of its own carries its first finding instead" do
      {workspace, _head} = git_workspace!()

      Process.put(
        :qa_agent_result,
        {:ok, %{result: %{verdict: :pass, summary: nil, steps: [], findings: ["a deprecation warning shows"]}, tokens: %{}}}
      )

      assert :ok = run(workspace, settings: settings!(%{"manual_review" => "on"}))

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** pass"

      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "## Decision needed:"
      assert request =~ "QA: a deprecation warning shows"
    end

    test "a merge confirmation that cannot be posted is reported" do
      {workspace, _head} = git_workspace!()
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})

      assert {:error, {:qa_merge_confirmation_failed, {:merge_confirmation_request_failed, :linear_down}}} =
               run(workspace, settings: settings!(%{"manual_review" => "on"}))
    end

    test "manual review on pauses a skip the same way, and a fail still moves to Rework" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, qa_policy: SkipPolicy, settings: settings!(%{"manual_review" => "on"}))

      refute_received {:memory_tracker_state_update, @issue_id, _state}
      assert deciding()
      assert [%{name: "qa", details: %{signal: "merge_confirmation"}} | _] = Handoff.signals(@repo_key, @issue_id)

      # A rework verdict never waits on a person, in either mode.
      RunStore.delete_ticket_state(@issue_id)
      {other_workspace, _head} = git_workspace!()

      Process.put(
        :qa_agent_result,
        {:ok, %{result: %{verdict: :fail, summary: "The walkthrough fails.", steps: [], findings: []}, tokens: %{}}}
      )

      assert :ok = run(other_workspace, settings: settings!(%{"manual_review" => "on"}))
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      refute deciding()
      assert [%{name: "qa", details: %{signal: "qa_fail"}} | _] = Handoff.signals(@repo_key, @issue_id)
      assert head != nil
    end

    test "a pass the CI Fix lane re-bound to this head carries the ticket on without a second run" do
      {workspace, head} = git_workspace!()

      # A mechanical repair pushed this head; the lane re-binds the pass it carries to it.
      :ok = put_verdict(@repo_key, @issue_id, "qa", "the-repaired-head", "pass")
      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "QA", head, settings!())

      assert :ok = run(workspace, [])

      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** pass → Merging"

      assert [%{kind: "qa", head_sha: ^head, outcome: "pass"} | _] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_pass", target: "Merging", carried: true}} | _] =
               Handoff.signals(@repo_key, @issue_id)
    end

    # TP-834: the retired Auto Review decided from a snapshot taken at the start of a CI poll, so a
    # verdict that landed inside the window started a second full pass on the same head. A dispatch
    # whose issue snapshot still reads `QA` after the pass was stored must not run the agent again:
    # the run reads the head's verdicts itself, just before it would start one.
    test "a dispatch whose snapshot predates the pass on its head starts no second QA run" do
      {workspace, head} = git_workspace!()
      stale_snapshot = issue("QA")

      assert :ok = run(workspace, [])
      assert_received {:qa_agent_run, %{sha: ^head}, _settings}
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}

      assert :ok =
               QaVerification.run(stale_snapshot, workspace,
                 settings: settings!(),
                 repo_key: @repo_key,
                 qa_policy: RunPolicy,
                 qa_agent: FakeQaAgent
               )

      refute_received {:qa_agent_run, _, _}
      assert [%{kind: "qa", head_sha: ^head, outcome: "pass"}] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_pass", carried: true}} | _] =
               Handoff.signals(@repo_key, @issue_id)
    end

    test "a fail verdict carries the report and the ticket to Rework" do
      {workspace, head} = git_workspace!()

      Process.put(
        :qa_agent_result,
        {:ok,
         %{
           result: %{verdict: :fail, summary: "The walkthrough fails.", steps: [], findings: ["`symphony check` exits 1"]},
           tokens: %{input: 1, output: 1}
         }}
      )

      assert :ok = run(workspace, [])

      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** fail → Rework"

      assert [%{head_sha: ^head, outcome: "fail"}] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_fail", reason: "`symphony check` exits 1"}}] =
               Handoff.signals(@repo_key, @issue_id)
    end

    test "a pre-build that failed carries the build command and its output to Rework, with no agent run" do
      head = @base_head
      build = %{command: "make app", exit_status: 65, output: "error: no such module 'Foo'\n"}

      assert :ok = QaVerification.build_failed(issue(), head, build, settings: settings!(), repo_key: @repo_key)

      refute_received {:qa_agent_run, _job, _settings}
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** fail → Rework"
      assert report =~ "Symphony ran the build command `make app` on the QA host and it exited with status 65."
      assert report =~ "```\nerror: no such module 'Foo'\n```"
      assert report =~ "- The app does not build on this commit: `make app` exits with status 65."

      assert [%{head_sha: ^head, outcome: "fail"}] = verdicts()
      assert [%{name: "qa", details: %{signal: "qa_fail", reason: "The app does not build on this commit" <> _rest}}] = Handoff.signals(@repo_key, @issue_id)
    end

    test "a pass verdict ran on a working QA environment: the pause reason self-heal set for it clears (TP-1250)" do
      {workspace, _head} = git_workspace!()
      environment_paused!()

      assert :ok = run(workspace, [])
      assert Pauses.why({:ticket, @repo_key, @issue_id}) == ["Waiting for TP-9 to finish"]
    end

    test "a fail verdict ran on a working QA environment too (TP-1250)" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:ok, %{result: %{verdict: :fail, summary: "No.", steps: [], findings: []}, tokens: %{}}})
      environment_paused!()

      assert :ok = run(workspace, [])
      assert Pauses.why({:ticket, @repo_key, @issue_id}) == ["Waiting for TP-9 to finish"]
    end

    test "a fail with nothing recorded falls back to a default reason" do
      {workspace, _head} = git_workspace!()

      Process.put(:qa_agent_result, {:ok, %{result: %{verdict: :fail, summary: "No.", steps: [], findings: []}, tokens: %{}}})

      assert :ok = run(workspace, [])

      assert [%{name: "qa", details: %{reason: "the run could not verify the change"}}] =
               Handoff.signals(@repo_key, @issue_id)
    end

    test "a fail with a reason of its own records that reason" do
      {workspace, _head} = git_workspace!()

      Process.put(:qa_agent_result, {:ok, %{result: %{verdict: :fail, summary: "No.", steps: [], findings: [], reason: "the walkthrough regressed"}, tokens: %{}}})

      assert :ok = run(workspace, [])

      assert [%{name: "qa", details: %{reason: "the walkthrough regressed"}}] = Handoff.signals(@repo_key, @issue_id)
    end

    test "a skip verdict lands the ticket in Merging with no agent run" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, qa_policy: SkipPolicy)

      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** skipped → Merging"

      assert [%{head_sha: ^head, outcome: "skip"}] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_skip", reason: reason}}] = Handoff.signals(@repo_key, @issue_id)
      assert reason =~ "only changes docs, tests"
    end

    # TP-983 and TP-972: moved back to QA after a Backlog move closed their pull requests, they were
    # skipped on the base branch's head and sent to Merging.
    test "a ticket whose pull request is closed is held, with no verdict and no move" do
      {workspace, _head} = git_workspace!()
      TicketPullRequest.mark_finished(@repo_key, @pr_url, "closed")

      assert :ok = run(workspace, qa_policy: SkipPolicy)

      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_state_update, _, _}
      assert verdicts() == []
      assert Handoff.signals(@repo_key, @issue_id) == []

      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "Reopen the pull request of TP-816"
      assert request =~ "PR #816 closed"
      assert request =~ "the ticket stays in QA"

      assert %{title: "Reopen the pull request of TP-816", options: options} = deciding()
      assert Enum.map(options, & &1.label) == ["Reopen", "Restart", "Cancel"]
    end

    test "a ticket with no pull request recorded is held the same way" do
      {workspace, _head} = git_workspace!()
      on_exit(fn -> RunStore.delete_ticket_state("issue-qa-no-pr") end)

      assert :ok =
               QaVerification.run(issue("QA", %{id: "issue-qa-no-pr"}), workspace,
                 settings: settings!(),
                 repo_key: @repo_key,
                 qa_policy: SkipPolicy,
                 qa_agent: FakeQaAgent
               )

      refute_received {:memory_tracker_state_update, _, _}
      assert_received {:memory_tracker_comment, "issue-qa-no-pr", request}
      assert request =~ "has no open pull request"
      assert %{question: reason} = deciding("issue-qa-no-pr")
      assert reason =~ "has no open pull request"
      assert Handoff.verdicts(@repo_key, "issue-qa-no-pr", "qa") == []
    end

    test "a PR whose diff GitHub reports empty is held instead of skipped into Merging" do
      {workspace, head} = git_workspace!()

      capture_log(fn -> assert :ok = run(workspace, nothing_opts(github_diff(head, 0))) end)

      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_state_update, _, _}
      assert verdicts() == []

      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "Restart or cancel TP-816"
      assert request =~ "(PR #816) that changes nothing"
      assert request =~ "GitHub compared the latest commit of the pull request with the latest commit of the main branch and found no changed file."
      assert request =~ "Symphony's copy of the work stood on that same commit."
      assert %{options: [%{label: "Restart", recommended?: true}, %{label: "Cancel"}]} = deciding()

      assert %{details: details} = Enum.find(Handoff.signals(@repo_key, @issue_id), &(&1.name == "empty_change_checked"))
      assert Map.take(details, [:workspace, :pr, :base, :changed_files]) == %{workspace: head, pr: head, base: @base_head, changed_files: 0}
    end

    test "a diff GitHub cannot answer blocks the run and asks nothing" do
      {workspace, head} = git_workspace!()
      refused = fn _args, _opts -> {"HTTP 502", 1} end

      capture_log(fn -> assert :ok = run(workspace, qa_policy: NothingToVerifyPolicy, gh_runner: refused) end)

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "GitHub's diff of the pull request could not be read"
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()
      assert deciding() == nil
    end

    test "a request that cannot be posted for a closed pull request is reported, its question left open" do
      {workspace, _head} = git_workspace!()
      TicketPullRequest.mark_finished(@repo_key, @pr_url, "closed")
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :disk_full})

      capture_log(fn ->
        assert {:error, {:qa_hold_failed, {:decision_request_failed, :disk_full}}} = run(workspace, [])
      end)

      assert %{title: "Reopen the pull request of TP-816"} = deciding()
    end

    test "an unknown verdict is refused without a move" do
      {workspace, _head} = git_workspace!()

      Process.put(:qa_agent_result, {:ok, %{result: %{verdict: :shrug, summary: "?", steps: [], findings: []}, tokens: %{}}})

      assert {:error, {:qa_unknown_verdict, :shrug}} = run(workspace, [])
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "a pass still moves on when the report cannot be published" do
      {workspace, _head} = git_workspace!()
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :linear_down})

      assert :ok = run(workspace, [])
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      refute_received {:memory_tracker_comment, _, _}
    end

    test "a tracker failure surfaces as a move failure" do
      {workspace, _head} = git_workspace!()

      assert {:error, {:qa_move_failed, :qa_pass, :rate_limited}} = run(workspace, tracker: FailingTracker)
    end

    test "an issue with no identifier is labelled by its id" do
      {workspace, _head} = git_workspace!()

      assert :ok = QaVerification.run(%Issue{id: @issue_id, state: "QA", repo_key: @repo_key}, workspace, settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent)
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
    end

    test "takes the repo key from the issue when none is given" do
      {workspace, _head} = git_workspace!()

      assert :ok = QaVerification.run(issue(), workspace, settings: settings!(), qa_policy: RunPolicy, qa_agent: FakeQaAgent)

      assert [%{outcome: "pass"}] = verdicts()
    end
  end

  describe "blocked runs" do
    test "retry boundedly on the same change, then file the fix ticket and hold the ticket on it" do
      {workspace, head} = git_workspace!()

      Process.put(:qa_agent_result, {:error, {:qa_host_tunnel_failed, "ssh exited with status 255"}, %{}})

      # The first attempt retries in place, so the next tick picks it up again.
      assert :ok = run(workspace, [])

      refute_received {:memory_tracker_state_update, _, _}
      refute blocked?(@issue_id)
      refute_received {:fixer_create, _}

      # The second attempt has used its attempts up: the self-heal lane files the fix ticket for the
      # broken component and pauses the ticket on it.
      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert fix_waits(@issue_id) == [@fix_ticket]
      assert log =~ "Self-heal holds TP-816 on TP-900 for its qa_environment block"

      assert_received {:fixer_create, attrs}
      assert attrs.scope == @symphony_repo_key
      assert attrs.component == "qa_environment"
      assert attrs.title == "Self-heal: repair the qa_environment block"
      assert attrs.description =~ ":qa_host_tunnel_failed"
      refute_received {:fixer_block, _identifier}

      refute_received {:memory_tracker_state_update, _, _}

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]
      assert Enum.all?(verdicts(), &(&1.head_sha == head))

      assert_received {:memory_tracker_comment, @issue_id, retrying}
      assert retrying =~ "**Verdict:** blocked → QA (blocked, retrying)"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked)"
    end

    test "a block logs and records its reason, the model and the playbooks it ran" do
      {workspace, head} = git_workspace!()

      Process.put(:qa_agent_result, blocked_result(["Open the window"], "the model could not drive the QA tools"))

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~
               "QA blocked for TP-816 head=#{head} model=claude-test needs_person=false playbooks=cli (attempt 1/2); " <>
                 "retrying: the model could not drive the QA tools"

      assert [%{outcome: "blocked", details: details}] = verdicts()
      assert details == %{reason: "the model could not drive the QA tools", needs_person: false, model: "claude-test", playbooks: ["cli"]}

      profile = %{kind: :qa, model: "~deepseek/deepseek-flash-latest", effort: nil, provider: "openrouter"}
      log = capture_log(fn -> assert :ok = run(workspace, run_profile: profile) end)

      assert log =~
               "QA blocked for TP-816 head=#{head} model=~deepseek/deepseek-flash-latest needs_person=false playbooks=cli (attempt 2/2); " <>
                 "asking a person: the model could not drive the QA tools"

      assert [%{details: %{model: "~deepseek/deepseek-flash-latest"}}, %{details: %{model: "claude-test"}}] = verdicts()
    end

    test "a block that needs a person logs it" do
      {workspace, _head} = git_workspace!()

      result = %{verdict: :blocked, summary: "No key.", steps: [], findings: [], needs_person: true, reason: "the QA host has no signing key"}
      Process.put(:qa_agent_result, {:ok, %{result: result, tokens: %{}}})

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "needs_person=true playbooks=cli (attempt 1/2); self-healing: the QA host has no signing key"
      assert [%{details: %{needs_person: true, reason: "the QA host has no signing key"}}] = verdicts()
    end

    test "a usage limit holds the run instead of recording a blocked verdict" do
      {workspace, _head} = git_workspace!()

      info = %{
        provider: "anthropic",
        scope: :all,
        source: :rate_limit_event,
        window: "seven_day",
        resets_at: ~U[2026-10-19 16:00:00Z],
        utilization: nil,
        overage: "rejected"
      }

      Process.put(:qa_agent_result, {:error, {:qa_agent_failed, {:usage_limited, info}}, %{input: 10}})

      # SPEC §8.4.1: no verdict, no report, no self-heal — the orchestrator holds the run and starts
      # it again once the limit resets.
      assert {:error, {:usage_limited, ^info}} = run(workspace, [])

      assert verdicts() == []
      refute_received {:memory_tracker_comment, _issue_id, _body}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      refute blocked?(@issue_id)
      refute_received {:fixer_create, _}
    end

    test "an unreachable model API holds the run instead of self-healing a QA environment block" do
      {workspace, _head} = git_workspace!()

      info = %{
        provider: "anthropic",
        scope: :all,
        source: :api_unreachable,
        error: "ENOTFOUND",
        window: nil,
        resets_at: nil,
        utilization: nil
      }

      Process.put(:qa_agent_result, {:error, {:qa_agent_failed, {:model_api_unreachable, info}}, %{}})

      assert {:error, {:usage_limited, ^info}} = run(workspace, [])

      assert verdicts() == []
      refute blocked?(@issue_id)
      refute_received {:fixer_create, _}
    end

    test "an agent that could not sign in holds the run: no verdict, no question, no attempt" do
      {workspace, _head} = git_workspace!()

      info = %{
        provider: "anthropic",
        scope: :all,
        source: :api_unreachable,
        cause: :sign_in,
        error: "Failed to authenticate. API Error: 403 Attention Required! | Cloudflare",
        window: nil,
        resets_at: nil,
        utilization: nil
      }

      Process.put(:qa_agent_result, {:error, {:qa_agent_failed, {:model_api_unreachable, info}}, %{}})

      capture_log(fn ->
        assert {:error, {:usage_limited, ^info}} = run(workspace, [])
        assert {:error, {:usage_limited, ^info}} = run(workspace, [])
        assert {:error, {:usage_limited, ^info}} = run(workspace, [])
      end)

      assert verdicts() == []
      refute deciding()
      refute blocked?(@issue_id)
    end

    test "a real answer without a verdict still asks, and says why in words" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, {:malformed_qa_response, :no_verdict_object}, %{}})

      capture_log(fn ->
        assert :ok = run(workspace, [])
        assert :ok = run(workspace, [])
      end)

      assert %{title: "QA could not finish its check of TP-816", why: why} = deciding()
      assert why =~ "the QA agent ended its run without saying whether the change passed or failed"
      refute why =~ "malformed"
      refute why =~ "{:"
    end

    test "an answer whose verdict cannot be read asks, and says why in words" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, {:malformed_qa_response, :invalid_verdict}, %{}})

      capture_log(fn ->
        assert :ok = run(workspace, [])
        assert :ok = run(workspace, [])
      end)

      assert %{why: why} = deciding()
      assert why =~ "the QA agent gave a pass or fail answer Symphony could not read"
      refute why =~ "{:"
    end

    test "a block a QA answer says an open ticket already covers holds on that ticket and files nothing" do
      {workspace, _head} = git_workspace!()

      covering = %Issue{id: "covering-id", identifier: "TP-716", title: "Fake gh on the QA host", state: "Merging"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [covering])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      blocked = %{verdict: :blocked, summary: "", steps: [], findings: [], reason: "the QA host has no fake gh", covered_by: "TP-716"}
      Process.put(:qa_agent_result, {:ok, %{result: blocked, tokens: %{input: 1, output: 1}}})

      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])

      refute_received {:fixer_create, _}
      refute_received {:fixer_block, _identifier}
      assert_received {:fixer_attach, "TP-716", evidence}
      assert evidence =~ "the QA host has no fake gh"

      assert fix_waits(@issue_id) == ["TP-716"]
    end

    test "a block on the project's own missing server files its fix ticket in the project's repo" do
      {workspace, _head} = git_workspace!()

      steps = [%{name: "Open the Pipeline board", status: "blocked", details: "no hub", evidence: []}]
      blocked = %{verdict: :blocked, summary: "", steps: steps, findings: [], reason: "the app has no hub to talk to", needs_dev_server: true}
      Process.put(:qa_agent_result, {:ok, %{result: blocked, tokens: %{input: 1, output: 1}}})

      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])

      assert_received {:fixer_create, %{scope: @repo_key, component: "dev_server", description: description}}
      assert description =~ "set `dev_server: true` on the playbook"
    end

    test "a QA-host dev server that fails is reported with its log and files its fix ticket in the project's repo" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, {:qa_dev_server_failed, {:dev_server_exit, 1}, "FATAL: could not create shared memory"}, %{}})

      assert :ok = run(workspace, [])
      assert_received {:memory_tracker_comment, @issue_id, report}

      assert report =~
               "Reason: qa_dev_server_failed: the dev server on the QA host exited (status 1) before its health check answered 200; " <>
                 "its last log lines:\nFATAL: could not create shared memory"

      # The log differs from run to run; the second attempt is the same failure, and files the fix.
      Process.put(:qa_agent_result, {:error, {:qa_dev_server_failed, {:dev_server_exit, 1}, "FATAL: shared memory again"}, %{}})
      assert :ok = run(workspace, [])
      assert_received {:fixer_create, %{scope: @repo_key, component: "dev_server"}}
    end

    test "a second ticket hitting the same break reuses the one fix ticket" do
      {workspace, _head} = git_workspace!()

      # Self-heal reuses a fix ticket only while it is open, so the tracker must read it.
      fix = %Issue{id: "fix-id", identifier: @fix_ticket, title: "Self-heal: repair the qa_environment block", state: "Todo"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [fix])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      Process.put(:qa_agent_result, {:error, {:qa_host_tunnel_failed, "ssh exited with status 255"}, %{}})

      # Two attempts on the first ticket file the fix ticket and hold it.
      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])
      assert_received {:fixer_create, _}

      # The same break on another ticket reuses it rather than filing a second one.
      other = issue("QA", %{id: @other_issue_id, identifier: "TP-817"})

      assert :ok =
               QaVerification.run(other, workspace, settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent, fixer: FakeFixer, symphony_repo_key: @symphony_repo_key)

      assert :ok =
               QaVerification.run(other, workspace, settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent, fixer: FakeFixer, symphony_repo_key: @symphony_repo_key)

      refute_received {:fixer_create, _}

      assert fix_waits(@other_issue_id) == [@fix_ticket]

      assert_received {:fixer_attach, @fix_ticket, evidence}
      assert evidence =~ ":qa_host_tunnel_failed"
    end

    test "a QA agent's own account of a block files no fix ticket: it retries once, then asks a person" do
      {workspace, head} = git_workspace!()
      steps = ["Watch the update banner"]

      Process.put(:qa_agent_result, blocked_result(steps, "qa_launch_app cannot set the update feed"))
      assert :ok = run(workspace, [])
      refute deciding()

      Process.put(:qa_agent_result, blocked_result(steps, "The app cannot be pointed at a fake update feed"))
      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA for TP-816 could not reach a verdict after 2 run(s); asking a person: The app cannot be pointed at a fake update feed"
      refute_received {:fixer_create, _attrs}
      refute_received {:fixer_block, _identifier}
      refute blocked?(@issue_id)
      assert SymphonyElixir.TicketState.self_heal(RunStore.get_ticket_state(@issue_id)) == nil

      assert %{} = decision = deciding()
      assert decision.title == "QA could not finish its check of TP-816"
      assert decision.question == "QA ran TP-816 (Land the QA state) 2 times on the same change without a pass or a fail. How should it continue?"
      assert decision.why =~ "The last run ended with: The app cannot be pointed at a fake update list."
      assert [again, %{label: "Send it back to Rework", move: %{to: "Rework"}}, %{label: "Merge without a QA result", effect: merge, move: merge_move}] = decision.options
      assert %{label: "Run QA again", recommended?: true} = again
      refute Map.has_key?(again, :move)
      # The pick is Symphony's move, never the person's: no option asks them to move the ticket.
      assert merge == "Symphony moves TP-816 to Merging, and it merges on its review and CI alone"
      refute Enum.any?(decision.options, &(&1.effect =~ "you move"))
      assert merge_move == %{to: "Merging", verdict: %{kind: "qa", outcome: "skip", head_sha: head, reason: "skipped by decision"}}
      assert decision.asked_in == "QA"

      assert_received {:memory_tracker_comment, @issue_id, _retrying_report}
      assert_received {:memory_tracker_comment, @issue_id, _report}
      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "QA could not finish its check of TP-816"
      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]
      assert Enum.all?(verdicts(), &(&1.head_sha == head))
    end

    test "a QA host block that keeps changing retries, until the change runs out of attempts" do
      {workspace, _head} = git_workspace!()

      Process.put(:qa_agent_result, {:error, {:qa_host_missing_tool, ["go"]}, %{}})
      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])
      assert_received {:fixer_create, %{component: "worker_host"}}
      lift_fix_ticket_hold()

      # Each run misses another tool: real progress, so each earns a retry while the change has
      # attempts left.
      for tool <- ["pg_ctl", "node"] do
        Process.put(:qa_agent_result, {:error, {:qa_host_missing_tool, [tool]}, %{}})
        assert :ok = run(workspace, [])
        refute deciding()
      end

      # The fifth blocked run on the same change escalates however the failure changed.
      Process.put(:qa_agent_result, {:error, {:qa_host_missing_tool, ["swift"]}, %{}})
      assert :ok = run(workspace, [])

      assert %{} = decision = deciding()
      assert decision.question =~ "over 5 blocked runs of the same change"
      assert Enum.count(verdicts(), &(&1.outcome == "blocked")) == 5
    end

    test "an injected failing dev-server command retries, files one fix ticket, holds the ticket, and resumes when the fix lands" do
      {workspace, _head} = git_workspace!()
      port = free_tcp_port()

      settings =
        settings!(%{
          "verification" => %{
            "enabled" => true,
            "port_allocation" => %{"range" => [port, port]},
            "dev_server" => %{
              "build_cmd" => "exit 3",
              "start_cmd" => "exec sleep 30",
              "health_check_url" => "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/",
              "health_timeout_ms" => 100
            }
          }
        })

      opts = [settings: settings, qa_agent: DevServerQaAgent]

      # The dev server's build command fails, so the run is blocked by its environment: the first
      # attempt retries, the second files the fix ticket and holds the ticket on it.
      assert :ok = run(workspace, opts)
      refute blocked?(@issue_id)

      assert :ok = run(workspace, opts)
      assert_received {:fixer_create, attrs}
      assert attrs.component == "dev_server"

      # The dev server's own setup belongs to the repo that hit the block, not to Symphony.
      assert attrs.scope == @repo_key
      assert attrs.description =~ "dev_server_build_failed"

      assert fix_waits(@issue_id) == [@fix_ticket]

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]

      # The fix lands: the fix ticket goes terminal, so the hold lifts and the ticket resumes with
      # nothing asked of a person. Only the stale fix-ticket pointer goes; the failure signature
      # stays, so the same break coming back is compared against it.
      Process.put(:fix_ticket_issue, {:ok, %Issue{id: "fix-ticket-id", identifier: @fix_ticket, state: "Done"}})

      assert {1, _cache} = Dependencies.sweep([issue()], ["Done", "Canceled"], repo_key: @repo_key, tracker: FixTicketTracker, build: %{sha: nil})

      refute blocked?(@issue_id)

      assert %{component: "dev_server", fix_ticket: nil, signature: signature} =
               RunStore.get_ticket_state(@issue_id) |> SymphonyElixir.TicketState.self_heal()

      assert signature =~ "dev_server_build_failed"

      # The break comes back unchanged: no new information means no next step to try, so the machine
      # asks a person with a Needs Decision hold instead of filing another fix ticket.
      assert :ok = run(workspace, opts)

      refute_received {:fixer_create, _}
      assert deciding()

      assert %{question: stuck} = deciding()
      assert stuck =~ "The dev server block on"
    after
      stop_verification_port_pool()
    end

    test "a block only a person can clear takes the hold immediately" do
      {workspace, _head} = git_workspace!()

      Process.put(
        :qa_agent_result,
        {:ok,
         %{
           result: %{verdict: :blocked, summary: "No emulator.", steps: [], findings: [], needs_person: true, reason: "the Android emulator is not set up"},
           tokens: %{}
         }}
      )

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert blocked?(@issue_id)
      assert log =~ "the Android emulator is not set up"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked)"
    end

    test "a change no playbook applies to is blocked until it runs out of attempts" do
      {workspace, _head} = git_workspace!()

      assert :ok = run(workspace, qa_policy: NoPlaybookPolicy)

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "QA (blocked, retrying)"
    end

    test "a QA agent that fails with its own reason records that reason" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, "the sandbox could not start", %{}})

      assert :ok = run(workspace, [])

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "the sandbox could not start"
    end

    test "a QA run on an SSH worker is blocked with the reason instead of parking" do
      {workspace, _head} = git_workspace!()

      # The agent is never reached: the worker host blocks the run before the head is read, so the
      # ticket retries boundedly and then asks a person rather than parking on an unreadable head.
      # Running QA on a worker is not a QA tool's block, so it files no fix ticket.
      assert :ok = run(workspace, worker_host: "worker-1")
      refute_received {:qa_agent_run, _, _}
      refute blocked?(@issue_id)

      capture_log(fn -> assert :ok = run(workspace, worker_host: "worker-1") end)

      refute_received {:fixer_create, _attrs}
      assert %{why: why} = deciding()
      assert why =~ "QA cannot run on the remote worker"
    end

    test "a fix ticket that cannot be filed is reported" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, {:qa_host_tunnel_failed, "ssh exited with status 255"}, %{}})

      # The first attempt retries; the second, its attempts used up, goes to the self-heal lane.
      assert :ok = run(workspace, [])

      Process.put(:fix_ticket_create, {:error, :linear_down})
      assert {:error, {:qa_self_heal_failed, {:self_heal_fix_ticket_failed, :linear_down}}} = run(workspace, [])
      Process.delete(:fix_ticket_create)

      # A block that goes to a person reports a decision request it could not post the same way.
      Process.put(:qa_agent_result, {:error, :nope, %{}})
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :disk_full})

      {result, _log} = with_log(fn -> run(workspace, []) end)
      assert {:error, {:qa_escalation_failed, {:decision_request_failed, :disk_full}}} = result
    end
  end

  # Steps a pass cannot prove here (TP-1284).
  describe "steps QA cannot prove here" do
    defp run_hub(workspace, result, settings \\ hub_settings()) do
      Process.put(:qa_agent_result, {:ok, %{result: result, tokens: %{input: 1, output: 1}}})
      run(workspace, settings: settings)
    end

    defp step(name, status, details \\ "what QA saw"), do: %{name: name, status: status, details: details, evidence: []}

    test "a server-only fix with an app step on a repo whose dev server is off by design passes on its server steps, naming the app step unprovable here" do
      {workspace, head} = git_workspace!()

      result = needs_dev_server([step("Start a run with the stand-in model route", "pass"), step("Watch the run in the Mac app", "blocked", "no hub dev server")])
      assert :ok = run_hub(workspace, result)

      refute_received {:fixer_create, _attrs}
      refute_received {:fixer_block, _identifier}
      refute blocked?(@issue_id)
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert [%{outcome: "pass", head_sha: ^head}] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** pass → Merging"
      assert report =~ "- **unprovable here** Watch the run in the Mac app"
      assert report =~ "Unprovable here: Watch the run in the Mac app (this repo runs its own server only beside the app on the QA host"

      # The agent was told which steps fall there, and why.
      assert_received {:qa_agent_run, job, _settings}
      assert job.unprovable.unselected == ["macos_app"]
      assert job.unprovable.dev_server_ruled_out =~ "keeps its dev server switched off on the Symphony host"
      prompt = QaAgent.prompt(job, nil)
      assert prompt =~ "Some steps cannot be proved in this pass:"
      assert prompt =~ ~s("status": "pass" | "fail" | "blocked" | "skipped" | "unprovable")
    end

    test "a failing step on such a repo fails the pass to Rework, the failing step its finding" do
      {workspace, _head} = git_workspace!()

      result = needs_dev_server([step("Start a run", "fail", "the run never started"), step("Watch the run in the Mac app", "blocked")])
      assert :ok = run_hub(workspace, result)

      refute_received {:fixer_create, _attrs}
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "- Start a run: the run never started"
    end

    test "a failing step's own finding is kept when the agent wrote one" do
      {workspace, _head} = git_workspace!()

      result = %{needs_dev_server([step("Start a run", "fail"), step("Watch the run in the Mac app", "blocked")]) | findings: ["Start a run: the button is gone"]}
      assert :ok = run_hub(workspace, result)

      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "- Start a run: the button is gone"
      refute report =~ "- Start a run: what QA saw"
    end

    test "with nothing provable left the ticket asks a person at once, recommending a merge without a QA result" do
      {workspace, head} = git_workspace!()

      # A block that named no step: what the server would have shown is the one unprovable step.
      assert :ok = run_hub(workspace, needs_dev_server([]))

      refute_received {:fixer_create, _attrs}
      refute blocked?(@issue_id)
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()

      assert %{} = decision = deciding()
      assert decision.title == "QA could not finish its check of TP-816"
      assert decision.question =~ "QA could not prove any step of TP-816 (Land the QA state) here"
      assert decision.why =~ "The steps that need the project's own server"

      assert [%{label: "Run QA again"} = again, %{label: "Send it back to Rework"}, %{label: "Merge without a QA result", recommended?: true}] = decision.options
      refute again.recommended?

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked)"
    end

    test "the Mac app's pass, which runs the server, is never told it is ruled out, and its server block takes the repair as before" do
      {workspace, _head} = git_workspace!()

      result = needs_dev_server([step("Start a run", "pass"), step("Watch the run in the Mac app", "blocked", "no hub dev server")])
      Process.put(:qa_agent_result, {:ok, %{result: result, tokens: %{input: 1, output: 1}}})
      assert :ok = run(workspace, settings: hub_settings(), qa_policy: AppPolicy)
      assert :ok = run(workspace, settings: hub_settings(), qa_policy: AppPolicy)

      assert_received {:fixer_create, %{scope: @repo_key, component: "dev_server"}}
      refute_received {:memory_tracker_state_update, @issue_id, "Merging"}

      assert_received {:qa_agent_run, job, _settings}
      assert [%{kind: "macos_app", dev_server: true}] = job.playbooks
      assert job.unprovable.dev_server_ruled_out == nil
      refute QaAgent.prompt(job, nil) =~ "The project's own server and its database"
    end

    test "a block that names its own cause stays blocked, whatever its unprovable steps" do
      steps = [step("Start a run", "pass"), step("Watch the run on Android", "unprovable", "the Android playbook is not in this pass")]

      # A wide pass a small QA screen limited, the ticket that already covers the gap, a QA tool's own
      # failure, and the project's server on a repo that has not ruled it out.
      causes = [
        %{needs_person: true, reason: "the QA screen is too small for the wide pass"},
        %{covered_by: "TP-716"},
        %{cause: {:qa_worker, "qa_worker_unsafe"}},
        %{needs_dev_server: true}
      ]

      for cause <- causes do
        RunStore.delete_ticket_state(@issue_id)
        {workspace, _head} = git_workspace!()
        result = Map.merge(%{verdict: :blocked, summary: "The run started.", steps: steps, findings: [], reason: "blocked"}, cause)

        capture_log(fn -> assert :ok = run_hub(workspace, result, app_repo_settings()) end)

        refute_received {:memory_tracker_state_update, @issue_id, "Merging"}
        assert [%{outcome: "blocked"} | _] = verdicts()
      end
    end

    test "a repo without the opt-out keeps the dev-server repair, whatever playbooks it has" do
      {workspace, _head} = git_workspace!()
      settings = app_repo_settings()

      result = needs_dev_server([step("Start a run", "pass"), step("Watch the run in the Mac app", "blocked")])
      assert :ok = run_hub(workspace, result, settings)
      assert :ok = run_hub(workspace, result, settings)

      assert_received {:fixer_create, %{scope: @repo_key, component: "dev_server"}}
    end

    test "a step the agent marks unprovable is decided by the rest, unless another step is still blocked" do
      {workspace, _head} = git_workspace!()

      blocked = %{verdict: :blocked, summary: "", steps: [step("Run it", "blocked"), step("Open the Mac app", "unprovable", "no app playbook")], findings: [], reason: "the app is not in this pass"}
      assert :ok = run_hub(workspace, blocked, app_repo_settings())
      refute_received {:memory_tracker_state_update, @issue_id, _state}
      refute deciding()

      assert :ok = run_hub(workspace, %{blocked | steps: [step("Run it", "pass"), step("Open the Mac app", "unprovable", "no app playbook")]}, app_repo_settings())
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
    end

    test "an unprovable step on a pass that offered no such case is the agent's own block, retried as before" do
      {workspace, head} = git_workspace!()

      steps = [step("Run it", "pass"), step("Open the Mac app", "unprovable", "no app playbook")]
      blocked = %{verdict: :blocked, summary: "", steps: steps, findings: [], reason: "the app is not in this pass"}
      assert :ok = run_hub(workspace, blocked, settings!())

      assert_received {:qa_agent_run, job, _settings}
      assert job.unprovable == %{unselected: [], dev_server_ruled_out: nil}
      refute QaAgent.prompt(job, nil) =~ "unprovable"

      refute_received {:memory_tracker_state_update, @issue_id, _state}
      refute deciding()
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked, retrying)"
      assert report =~ "- **blocked** Open the Mac app"
      refute report =~ "unprovable here"
    end

    test "a pass the agent gave with an unprovable step passes, naming that step" do
      {workspace, _head} = git_workspace!()

      passed = %{verdict: :pass, summary: "It ran.", steps: [step("Run it", "pass"), step("Open the Mac app", "unprovable", "no app playbook")], findings: []}
      assert :ok = run_hub(workspace, passed, app_repo_settings())

      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "It ran. Unprovable here: Open the Mac app (no app playbook)."
    end

    test "a pass with no unprovable step, and a fail, are left as the agent gave them" do
      {workspace, _head} = git_workspace!()

      fail = %{verdict: :fail, summary: "", steps: [step("Run it", "fail"), step("Open the Mac app", "unprovable")], findings: ["Run it: broke"], reason: nil}
      assert :ok = run_hub(workspace, fail)
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}

      assert :ok = run_hub(workspace, %{verdict: :pass, summary: "Fine.", steps: [step("Run it", "pass")], findings: []})
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
    end
  end

  describe "the app's environments in the report's header" do
    test "names the live server and the label that forced it, or fixtures only and the label that kept it off" do
      for {playbook, line} <- [
            {%{live: true, live_reason: "the issue has the `qa:live` label"}, "**App environments:** fixtures and a live server (the issue has the `qa:live` label)"},
            {%{live_reason: "the issue has the `qa:fixture` label"}, "**App environments:** fixtures only (the issue has the `qa:fixture` label)"}
          ] do
        RunStore.delete_ticket_state(@issue_id)
        {workspace, _head} = git_workspace!()
        Process.put(:qa_live_playbook, Map.merge(%{kind: "macos_app", paths: ["macos/**"], prompt: "Use the app."}, playbook))

        assert :ok = run(workspace, qa_policy: LivePolicy)

        assert_received {:memory_tracker_comment, @issue_id, report}
        assert report =~ line
      end
    end

    test "a pass with no live server says nothing about environments, and a blocked live pass still does" do
      {workspace, _head} = git_workspace!()
      assert :ok = run(workspace, [])
      assert_received {:memory_tracker_comment, @issue_id, report}
      refute report =~ "App environments"

      RunStore.delete_ticket_state(@issue_id)
      Process.put(:qa_live_playbook, %{kind: "macos_app", paths: ["macos/**"], prompt: "Use the app.", live: true, live_reason: "the issue has the `qa:live` label"})
      Process.put(:qa_agent_result, {:error, {:qa_host_tunnel_failed, "ssh exited with status 255"}, %{}})

      capture_log(fn -> assert :ok = run(workspace, qa_policy: LivePolicy) end)
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**App environments:** fixtures and a live server (the issue has the `qa:live` label)"
    end
  end

  describe "a pass with nothing on screen to judge" do
    defp scope_none_result(app_check) do
      result = %{
        verdict: :pass,
        summary: "Nothing to judge.",
        steps: [],
        findings: [],
        scope: :none,
        reason: "the change touches no screen; the app built and launched; nothing to judge by sight"
      }

      result = if app_check, do: Map.put(result, :app_check, app_check), else: result
      {:ok, %{result: result, tokens: %{}}}
    end

    test "is a pass once the app built, launched and checked healthy, with the reason in the report" do
      {workspace, head} = git_workspace!()
      Process.put(:qa_agent_result, scope_none_result(%{built: true, launched: true, checked: true}))

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA passed for TP-816 head=#{head} with nothing on screen to judge: the change touches no screen"
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert [%{outcome: "pass", head_sha: ^head, details: %{scope: "none", reason: reason}}] = verdicts()
      assert reason =~ "nothing to judge by sight"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** pass (nothing on screen to judge; the app built and launched) → Merging"
      assert report =~ "Why nothing was judged on screen: the change touches no screen; the app built and launched; nothing to judge by sight"
      assert report =~ "Nothing to judge."
      refute_received {:fixer_create, _attrs}
    end

    test "carries the reason into the merge confirmation with manual review on" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, scope_none_result(%{built: true, launched: true, checked: true}))

      assert :ok = run(workspace, settings: settings!(%{"manual_review" => "on"}))

      refute_received {:memory_tracker_state_update, _, _}
      assert %{} = decision = deciding()
      assert decision.why =~ "nothing on screen to judge: the change touches no screen"
    end

    # One test for each case: the ledger outlives the deleted record, so a loop would read the
    # earlier cases' verdicts.
    for {app_check, missing} <- [
          {%{built: true, launched: false, checked: false}, "qa_launch_app, a healthy qa_check_app did not run"},
          {%{built: true, launched: true, checked: false}, "a healthy qa_check_app did not run"},
          {nil, "qa_build, qa_launch_app, a healthy qa_check_app did not run"}
        ] do
      @app_check app_check
      @missing missing

      test "is inconclusive without the launch, the build or a healthy check, naming what did not run: #{missing}" do
        app_check = @app_check
        missing = @missing
        {workspace, head} = git_workspace!()
        Process.put(:qa_agent_result, scope_none_result(app_check))

        capture_log(fn -> assert :ok = run(workspace, []) end)

        refute_received {:memory_tracker_state_update, _, _}
        assert [%{outcome: "inconclusive", head_sha: ^head, details: %{reason: reason}}] = verdicts()
        assert reason =~ "the pass answered `scope: none` (nothing on screen to judge), but #{missing}"

        assert_received {:memory_tracker_comment, @issue_id, report}
        assert report =~ "**Verdict:** inconclusive → QA (inconclusive, rerunning)"
        assert report =~ "Reason: the pass answered `scope: none`"
      end
    end
  end
end
