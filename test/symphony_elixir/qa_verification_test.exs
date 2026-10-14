defmodule SymphonyElixir.QaVerificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BlockedHold
  alias SymphonyElixir.CiFix
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.QaVerification
  alias SymphonyElixir.RunStore

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"
  @other_issue_id "issue-qa-verification-other"
  @symphony_repo_key "repo-symphony"
  @fix_ticket "TP-900"

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
