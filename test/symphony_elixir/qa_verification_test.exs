defmodule SymphonyElixir.QaVerificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BlockedHold
  alias SymphonyElixir.CiFix
  alias SymphonyElixir.CiWait
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaVerification
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketSignals

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"
  @other_issue_id "issue-qa-verification-other"
  @symphony_repo_key "repo-symphony"
  @fix_ticket "TP-900"
  @pr_url "https://github.com/acme/repo/pull/816"

  @playbook %{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}

  defmodule FakeQaAgent do
    def run(job, settings, _opts) do
      send(self(), {:qa_agent_run, job, settings})
      Process.get(:qa_agent_result, pass_result())
    end

    defp pass_result do
      {:ok, %{result: %{verdict: :pass, summary: "Every journey worked.", steps: [], findings: []}, tokens: %{input: 10, output: 5}}}
    end
  end

  # Drives the real dev server, so a failing command injected through the settings is what blocks
  # the run — the QA environment block the self-heal lane exists for, not a hand-made verdict.
  defmodule DevServerQaAgent do
    def run(job, settings, _opts) do
      send(self(), {:qa_agent_run, job, settings})

      start_opts = [settings: settings, repo_key: job.repo_key]

      case SymphonyElixir.Verification.start_qa_dev_server(job.issue, job.run_id, job.workspace_path, start_opts) do
        {:ok, dev_server} ->
          SymphonyElixir.Verification.stop_qa_dev_server(dev_server)

          {:ok, %{result: %{verdict: :pass, summary: "The dev server started.", steps: [], findings: []}, tokens: %{}}}

        {:error, reason} ->
          {:error, {:qa_dev_server_failed, reason}, %{}}
      end
    end
  end

  # The fix-ticket filer, standing in for the Linear-backed one so no test reaches the network.
  defmodule FakeFixer do
    def create(attrs, _opts) do
      send(self(), {:fixer_create, attrs})
      {:ok, %{identifier: Process.get(:fix_ticket, "TP-900"), url: "https://linear.app/acme/issue/TP-900"}}
    end

    def attach(identifier, body, _opts) do
      send(self(), {:fixer_attach, identifier, body})
      :ok
    end

    def block(_issue, ticket, _opts) do
      send(self(), {:fixer_block, ticket.identifier})
      :ok
    end
  end

  # The skip rule, driven from the test rather than from git: what the verdict says is the
  # behaviour under test here (`QaPolicy` itself is tested directly).
  defmodule RunPolicy do
    def decide(_issue, _settings, _opts) do
      {:run, [%{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}], "the change delivers or updates a user journey"}
    end
  end

  defmodule UnusedStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :disk_full}
    def get_ticket_state(_repo_key, _issue_id), do: nil
    def list_all_ticket_states, do: []
    def record_ticket_self_heal(_repo_key, _issue_id, _attrs), do: :ok
  end

  defmodule FailingTracker do
    def update_issue_state(_issue_id, _state), do: {:error, :rate_limited}
  end

  defmodule SkipPolicy do
    def decide(_issue, _settings, _opts), do: {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"}
  end

  defmodule NothingToVerifyPolicy do
    def decide(_issue, _settings, _opts), do: {:nothing_to_verify, "the head changes no files against its base branch"}
  end

  defmodule NoPlaybookPolicy do
    def decide(_issue, _settings, _opts), do: {:run, [], "the change delivers or updates a user journey"}
  end

  # The tracker the BlockedHold sweep reads the fix ticket's state from.
  defmodule FixTicketTracker do
    def fetch_issue_by_identifier(_identifier), do: Process.get(:fix_ticket_issue, {:error, :not_found})
    def set_machine_label(_issue_id, _label), do: :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    RunStore.delete_ticket_state(@repo_key, @issue_id)
    RunStore.delete_ticket_state(@repo_key, @other_issue_id)

    # Every QA ticket here has its open pull request; the tests that close it say so.
    :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})
    :ok = TicketPullRequest.put(@repo_key, @other_issue_id, %{pr_url: "https://github.com/acme/repo/pull/817"})

    on_exit(fn ->
      RunStore.delete_ticket_state(@repo_key, @issue_id)
      RunStore.delete_ticket_state(@repo_key, @other_issue_id)
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end)

    :ok
  end

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))

    settings
  end

  defp custom_qa_settings, do: settings!(%{"tracker" => %{"kind" => "memory", "qa_state" => "Verification"}})

  defp issue(state \\ "QA", attrs \\ %{}) do
    struct!(
      %Issue{
        id: @issue_id,
        identifier: "TP-816",
        title: "Land the QA state",
        description: "## User walkthrough\n\n1. Run `symphony check`.\n",
        state: state,
        repo_key: @repo_key
      },
      attrs
    )
  end

  # A real checkout, so the verdict really binds to the head the run judged.
  defp git_workspace! do
    dir = Path.join(System.tmp_dir!(), "qa-verification-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "first"], cd: dir)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, String.trim(head)}
  end

  defp run(workspace, opts, state \\ "QA") do
    QaVerification.run(
      issue(state),
      workspace,
      opts ++
        [
          settings: settings!(),
          repo_key: @repo_key,
          qa_policy: RunPolicy,
          qa_agent: FakeQaAgent,
          fixer: FakeFixer,
          symphony_repo_key: @symphony_repo_key
        ]
    )
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp verdicts, do: Handoff.verdicts(@repo_key, @issue_id, "qa")

  defp blocked_result(blocked_steps, reason) do
    steps = for name <- blocked_steps, do: %{name: name, status: "blocked", details: reason, evidence: []}
    {:ok, %{result: %{verdict: :blocked, summary: "Blocked.", steps: steps, findings: [], reason: reason}, tokens: %{}}}
  end

  # The fix ticket lands: it goes terminal, so the Blocked hold on it lifts.
  defp lift_fix_ticket_hold do
    Process.put(:fix_ticket_issue, {:ok, %Issue{id: "fix-ticket-id", identifier: @fix_ticket, state: "Done"}})
    assert :clear = BlockedHold.sync(issue(), ["Done", "Canceled"], settings: settings!(), tracker: FixTicketTracker)
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

  describe "journey/1" do
    test "is the ticket's `## User walkthrough` when it has one" do
      assert %{source: "the ticket's `## User walkthrough`", text: "1. Run `symphony check`."} =
               QaVerification.journey(issue())
    end

    test "carries the walkthrough's steps with the proof each names" do
      description = """
      ## User walkthrough

      1. Run `symphony check` → it passes. Proved by: `make-all` › `test/mix/tasks/check_test.exs`
      2. Read the output → it reads well.

      ## Acceptance criteria

      - It works.
      """

      assert %{
               steps: [
                 %{number: 1, proof: %{by: :test, check: "make-all", test: "test/mix/tasks/check_test.exs"}},
                 %{number: 2, proof: %{by: :qa}}
               ]
             } = QaVerification.journey(issue("QA", %{description: description}))

      assert %{steps: []} = QaVerification.journey(issue("QA", %{description: "## Acceptance criteria\n\n- It works.\n"}))
      assert %{steps: []} = QaVerification.journey(issue("QA", %{description: nil}))
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

      assert %{decision: %{confirm: "Merging"}} = hold = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Hold.held_any?(@repo_key, @issue_id)
      assert MergeConfirmation.confirm_target(hold) == "Merging"

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
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      assert [%{name: "qa", details: %{signal: "merge_confirmation"}} | _] = Handoff.signals(@repo_key, @issue_id)

      # A rework verdict never waits on a person, in either mode.
      RunStore.delete_ticket_state(@repo_key, @issue_id)
      {other_workspace, _head} = git_workspace!()

      Process.put(
        :qa_agent_result,
        {:ok, %{result: %{verdict: :fail, summary: "The walkthrough fails.", steps: [], findings: []}, tokens: %{}}}
      )

      assert :ok = run(other_workspace, settings: settings!(%{"manual_review" => "on"}))
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      refute Hold.held_any?(@repo_key, @issue_id)
      assert [%{name: "qa", details: %{signal: "qa_fail"}} | _] = Handoff.signals(@repo_key, @issue_id)
      assert head != nil
    end

    test "a pass the CI Fix lane re-bound to this head carries the ticket on without a second run" do
      {workspace, head} = git_workspace!()

      # A mechanical repair pushed this head; the lane re-binds the pass it carries to it.
      :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "qa", "the-repaired-head", "pass")
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

      assert %{decision: %{title: "Reopen the pull request of TP-816", options: options}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Enum.map(options, & &1.label) == ["Reopen", "Restart", "Cancel"]
    end

    test "a ticket with no pull request recorded is held the same way" do
      {workspace, _head} = git_workspace!()
      on_exit(fn -> RunStore.delete_ticket_state(@repo_key, "issue-qa-no-pr") end)

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
      assert %{reason: reason} = Hold.get(@repo_key, "issue-qa-no-pr", :needs_decision)
      assert reason =~ "has no open pull request"
      assert Handoff.verdicts(@repo_key, "issue-qa-no-pr", "qa") == []
    end

    test "a head with nothing to verify is held instead of skipped into Merging" do
      {workspace, _head} = git_workspace!()

      assert :ok = run(workspace, qa_policy: NothingToVerifyPolicy)

      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_state_update, _, _}
      assert verdicts() == []

      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "Restart or cancel TP-816"
      assert request =~ "(PR #816) that changes nothing"
      assert %{decision: %{options: [%{label: "Restart"}, %{label: "Cancel"}]}} = Hold.get(@repo_key, @issue_id, :needs_decision)
    end

    test "a hold that cannot be set for a closed pull request is reported" do
      {workspace, _head} = git_workspace!()
      TicketPullRequest.mark_finished(@repo_key, @pr_url, "closed")

      assert {:error, {:qa_hold_failed, {:decision_hold_failed, :disk_full}}} = run(workspace, store: UnusedStore)
      refute_received {:memory_tracker_comment, _, _}
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
    test "retry boundedly on the same head, then file the fix ticket and hold the ticket on it" do
      {workspace, head} = git_workspace!()

      Process.put(:qa_agent_result, {:error, :environment_unreachable, %{}})

      # The first attempt retries in place, so the next tick picks it up again.
      assert :ok = run(workspace, [])

      refute_received {:memory_tracker_state_update, _, _}
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      refute_received {:fixer_create, _}

      # The second attempt has used its attempts up: the self-heal lane files the fix ticket for the
      # broken component and pauses the ticket on a Blocked hold waiting for it.
      assert :ok = run(workspace, [])

      assert Hold.held?(@repo_key, @issue_id, :blocked)

      assert %{reason: reason, waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}} =
               Hold.get(@repo_key, @issue_id, :blocked)

      assert reason =~ "waiting on fix ticket TP-900 for the qa_environment block"

      assert_received {:fixer_create, attrs}
      assert attrs.scope == @symphony_repo_key
      assert attrs.component == "qa_environment"
      assert attrs.title == "Self-heal: repair the qa_environment block"
      assert attrs.description =~ ":environment_unreachable"
      assert_received {:fixer_block, @fix_ticket}

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
               "QA blocked for TP-816 head=#{head} model=default needs_person=false playbooks=cli (attempt 1/2); " <>
                 "retrying: the model could not drive the QA tools"

      assert [%{outcome: "blocked", details: details}] = verdicts()
      assert details == %{reason: "the model could not drive the QA tools", needs_person: false, model: "default", playbooks: ["cli"]}

      profile = %{kind: :qa, model: "~deepseek/deepseek-flash-latest", effort: nil, provider: "openrouter"}
      log = capture_log(fn -> assert :ok = run(workspace, run_profile: profile) end)

      assert log =~
               "QA blocked for TP-816 head=#{head} model=~deepseek/deepseek-flash-latest needs_person=false playbooks=cli (attempt 2/2); " <>
                 "self-healing: the model could not drive the QA tools"

      assert [%{details: %{model: "~deepseek/deepseek-flash-latest"}}, %{details: %{model: "default"}}] = verdicts()
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
      refute Hold.held?(@repo_key, @issue_id, :blocked)
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
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      refute_received {:fixer_create, _}
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
      assert_received {:fixer_block, "TP-716"}
      assert_received {:fixer_attach, "TP-716", evidence}
      assert evidence =~ "the QA host has no fake gh"

      assert %{waits_on: %{type: "fix_ticket", keys: ["TP-716"]}} = Hold.get(@repo_key, @issue_id, :blocked)
    end

    test "a second ticket hitting the same break reuses the one fix ticket" do
      {workspace, _head} = git_workspace!()

      # Self-heal reuses a fix ticket only while it is open, so the tracker must read it.
      fix = %Issue{id: "fix-id", identifier: @fix_ticket, title: "Self-heal: repair the qa_environment block", state: "Todo"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [fix])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      Process.put(:qa_agent_result, {:error, :environment_unreachable, %{}})

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

      assert %{waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}} =
               Hold.get(@repo_key, @other_issue_id, :blocked)

      assert_received {:fixer_attach, @fix_ticket, evidence}
      assert evidence =~ ":environment_unreachable"
    end

    test "a QA agent that rewords the same block on every run is escalated once the fix lands, not retried" do
      {workspace, _head} = git_workspace!()
      steps = ["Watch the update banner"]

      # The first two runs retry and then file the fix ticket, worded differently each time.
      Process.put(:qa_agent_result, blocked_result(steps, "qa_launch_app cannot set the update feed"))
      assert :ok = run(workspace, [])
      Process.put(:qa_agent_result, blocked_result(steps, "The app cannot be pointed at a fake update feed"))
      assert :ok = run(workspace, [])
      assert_received {:fixer_create, _attrs}

      # The fix lands and the hold lifts.
      lift_fix_ticket_hold()

      # The same blocked step with a third wording is the same failure: no new information.
      Process.put(:qa_agent_result, blocked_result(steps, "Blocked: no way to set the update URL for the launched app"))
      assert :ok = run(workspace, [])

      refute_received {:fixer_create, _attrs}
      assert %{reason: stuck} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert stuck =~ "blocked steps: Watch the update banner"
    end

    test "a block whose blocked steps keep changing retries, until the head runs out of attempts" do
      {workspace, _head} = git_workspace!()

      Process.put(:qa_agent_result, blocked_result(["Open the window"], "the window would not open"))
      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])
      lift_fix_ticket_hold()

      # Each run blocks on another step: real progress, so each earns a retry while the head has
      # attempts left.
      for step <- ["Watch the update banner", "Restart into the new build"] do
        Process.put(:qa_agent_result, blocked_result([step], "blocked on #{step}"))
        assert :ok = run(workspace, [])
        refute Hold.held?(@repo_key, @issue_id, :needs_decision)
      end

      # The fifth blocked run on the same head escalates however the failure changed.
      Process.put(:qa_agent_result, blocked_result(["Read the release notes"], "blocked on the notes"))
      assert :ok = run(workspace, [])

      assert %{decision: decision} = Hold.get(@repo_key, @issue_id, :needs_decision)
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
      refute Hold.held?(@repo_key, @issue_id, :blocked)

      assert :ok = run(workspace, opts)
      assert_received {:fixer_create, attrs}
      assert attrs.component == "dev_server"

      # The dev server's own setup belongs to the repo that hit the block, not to Symphony.
      assert attrs.scope == @repo_key
      assert attrs.description =~ "dev_server_build_failed"

      assert %{waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}} =
               Hold.get(@repo_key, @issue_id, :blocked)

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]

      # The fix lands: the fix ticket goes terminal, so the hold lifts and the ticket resumes with
      # nothing asked of a person. Only the stale fix-ticket pointer goes; the failure signature
      # stays, so the same break coming back is compared against it.
      Process.put(:fix_ticket_issue, {:ok, %Issue{id: "fix-ticket-id", identifier: @fix_ticket, state: "Done"}})

      assert :clear = BlockedHold.sync(issue(), ["Done", "Canceled"], settings: settings, tracker: FixTicketTracker)

      refute Hold.held?(@repo_key, @issue_id, :blocked)

      assert %{component: "dev_server", fix_ticket: nil, signature: signature} =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> SymphonyElixir.TicketState.self_heal()

      assert signature =~ "dev_server_build_failed"

      # The break comes back unchanged: no new information means no next step to try, so the machine
      # asks a person with a Needs Decision hold instead of filing another fix ticket.
      assert :ok = run(workspace, opts)

      refute_received {:fixer_create, _}
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)

      assert %{reason: stuck} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert stuck =~ "self-heal is stuck on the dev_server block"
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

      assert :ok = run(workspace, [])

      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{reason: reason} = Hold.get(@repo_key, @issue_id, :blocked)
      assert reason =~ "the Android emulator is not set up"

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
      # ticket retries boundedly and then self-heals rather than parking on an unreadable head.
      assert :ok = run(workspace, worker_host: "worker-1")
      refute_received {:qa_agent_run, _, _}
      refute Hold.held?(@repo_key, @issue_id, :blocked)

      assert :ok = run(workspace, worker_host: "worker-1")

      assert_received {:fixer_create, attrs}
      assert attrs.component == "worker_host"
      assert attrs.scope == @symphony_repo_key

      assert %{waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}} =
               Hold.get(@repo_key, @issue_id, :blocked)
    end

    test "a hold that cannot be set is reported" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, :nope, %{}})

      # Both attempts are used on the same call, so the third records "blocked" and takes the hold.
      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])

      assert {:error, {:qa_self_heal_failed, {:self_heal_hold_failed, :disk_full}}} = run(workspace, store: UnusedStore)
    end
  end

  # The QA pre-check (`SymphonyElixir.QaPreCheck`) on a ticket whose walkthrough steps name tests.
  describe "the QA pre-check of named tests" do
    @run_url "https://github.com/acme/repo/actions/runs/555/job/1"

    @named_walkthrough """
    ## User walkthrough

    1. Run `symphony check` → it passes. Proved by: `make-all`
    2. Open the dashboard → it looks right. Proved by: QA
    """

    defp run_named(workspace, description, opts) do
      QaVerification.run(
        issue("QA", %{description: description}),
        workspace,
        opts ++
          [
            settings: settings!(),
            repo_key: @repo_key,
            qa_policy: RunPolicy,
            qa_agent: FakeQaAgent,
            fixer: FakeFixer,
            symphony_repo_key: @symphony_repo_key
          ]
      )
    end

    # Answers `gh pr view` with the head `head` and its `checks`, and the head's workflow runs with none.
    defp gh(head, checks) do
      fn
        ["pr", "view", @pr_url, "--json", _fields], _opts ->
          {Jason.encode!(%{"url" => @pr_url, "headRefOid" => head, "statusCheckRollup" => checks}), 0}

        ["api" | _endpoint], _opts ->
          {Jason.encode!(%{"workflow_runs" => []}), 0}
      end
    end

    defp make_all(status, conclusion) do
      %{"name" => "make-all", "workflowName" => "make-all", "status" => status, "conclusion" => conclusion, "detailsUrl" => @run_url}
    end

    test "a passed check is confirmed before the agent: the prompt says not to walk it and the report links it" do
      {workspace, head} = git_workspace!()

      assert :ok = run_named(workspace, @named_walkthrough, gh_runner: gh(head, [make_all("COMPLETED", "SUCCESS")]))

      assert_received {:qa_agent_run, job, %Schema{}}
      assert [%{status: :pass, url: @run_url}] = job.proofs

      prompt = QaAgent.prompt(job, nil)
      assert prompt =~ "Symphony confirmed every step a named\nautomated test proves before you started"
      assert prompt =~ "Do not walk those steps and do not read their checks again."
      assert prompt =~ "- 1. Run `symphony check` → it passes. Proved by: `make-all`: pass, `make-all` passed on `#{String.slice(head, 0, 12)}` (#{@run_url})\n"
      assert prompt =~ "Steps to walk (`Proved by: QA`, or no proof named):\n- 2. Open the dashboard → it looks right.\n"
      refute prompt =~ "gh run list --commit"

      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "### Pre-checks"
      assert report =~ "- **pass** step 1 (Proved by: `make-all`): `make-all` passed on `#{String.slice(head, 0, 12)}` (#{@run_url})"
      assert [%{outcome: "pass", head_sha: ^head}] = verdicts()
    end

    test "a ticket without Proved by: lines reads no check and gets today's prompt" do
      {workspace, _head} = git_workspace!()
      unused = fn args, _opts -> flunk("gh should not run: #{inspect(args)}") end

      assert :ok = run_named(workspace, "## User walkthrough\n\n1. Run `symphony check`.\n", gh_runner: unused)

      assert_received {:qa_agent_run, job, %Schema{}}
      assert job.proofs == []
      assert QaAgent.prompt(job, nil) =~ "gh run list --commit"

      assert_received {:memory_tracker_comment, @issue_id, report}
      refute report =~ "### Pre-checks"
    end

    test "a failed check, a check that never ran, or a missing test fails to Rework naming the step, with no agent run" do
      for {checks, description, expected} <- [
            {[make_all("COMPLETED", "FAILURE")], @named_walkthrough, "`make-all` failed on"},
            {[], @named_walkthrough, "`make-all` did not run on"},
            {[make_all("COMPLETED", "SUCCESS")], "## User walkthrough\n\n1. Run it. Proved by: `make-all` › the QA pre-check's test file\n", "`the QA pre-check's test file` is not in the checkout"}
          ] do
        RunStore.delete_ticket_state(@repo_key, @issue_id)
        {workspace, head} = git_workspace!()

        assert :ok = run_named(workspace, description, gh_runner: gh(head, checks))

        refute_received {:qa_agent_run, _, _}
        assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
        assert_received {:memory_tracker_comment, @issue_id, report}
        assert report =~ "**Verdict:** fail → Rework"
        assert report =~ "### Pre-checks\n\n- **fail** step 1 (Proved by: `make-all`"
        assert report =~ "### Findings\n\n- Step 1 (Proved by: `make-all`"
        assert report =~ expected
        assert [%{outcome: "fail", head_sha: ^head}] = verdicts()
      end
    end

    test "a check still running waits for CI, then reports blocked past the wait's limit" do
      {workspace, head} = git_workspace!()
      runner = gh(head, [make_all("IN_PROGRESS", nil)])

      log =
        capture_log(fn ->
          assert {:error, {:ci_pending, _info}} = run_named(workspace, @named_walkthrough, gh_runner: runner)
        end)

      assert log =~ "waits for the named checks on #{String.slice(head, 0, 12)}: make-all"
      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_comment, _, _}
      assert verdicts() == []

      # The orchestrator records when the wait on this head started; a minute in, the run still waits.
      TicketSignals.record(@repo_key, @issue_id, CiWait.start_signal(), %{sha: head})
      soon = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:error, {:ci_pending, %{sha: ^head, run: "the QA pass", runs: [%{workflow_name: "make-all", url: @run_url}]}}} =
               run_named(workspace, @named_walkthrough, gh_runner: runner, now: soon)

      # Past the limit, the pass is blocked with the reason, and retried like any blocked pass.
      later = DateTime.add(DateTime.utc_now(), div(CiWait.limit_ms(), 1000) + 60, :second)
      assert :ok = run_named(workspace, @named_walkthrough, gh_runner: runner, now: later)

      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked, retrying)"
      assert report =~ "Reason: the named checks were still running after 61 minutes of waiting: step 1: `make-all` is still running on"
      assert report =~ "- **pending** step 1 (Proved by: `make-all`)"
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()
    end

    test "CI the pre-check cannot read blocks the pass" do
      {workspace, head} = git_workspace!()
      refused = fn _args, _opts -> {"HTTP 502", 1} end

      assert :ok = run_named(workspace, @named_walkthrough, gh_runner: refused)

      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "Reason: the QA pre-check could not read CI on the PR head:"
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()
    end

    test "a pass with no playbook that applies is blocked and keeps the pre-check lines" do
      {workspace, head} = git_workspace!()

      runner = gh(head, [make_all("COMPLETED", "SUCCESS")])
      assert :ok = run_named(workspace, @named_walkthrough, gh_runner: runner, qa_policy: NoPlaybookPolicy)

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "Reason: no QA playbook applies to this change"
      assert report =~ "- **pass** step 1"
    end
  end

  describe "carry_verdict/3" do
    test "re-binds the newest pass to the new head, and carries nothing otherwise" do
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, "new-head")

      :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "qa", "old-head", "fail")
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, "new-head")
      assert [%{head_sha: "old-head", outcome: "fail"}] = verdicts()

      :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "qa", "old-head", "pass")
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, nil)
      assert [%{head_sha: "old-head", outcome: "pass"} | _] = verdicts()
    end
  end
end
