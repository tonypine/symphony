defmodule SymphonyElixir.QaVerificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaVerification
  alias SymphonyElixir.RunStore

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"

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

  # The skip rule, driven from the test rather than from git: what the verdict says is the
  # behaviour under test here (`QaPolicy` itself is tested directly).
  defmodule RunPolicy do
    def decide(_issue, _settings, _opts) do
      {:run, [%{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}], "the change delivers or updates a user journey"}
    end
  end

  defmodule UnusedStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :disk_full}
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

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    RunStore.delete_ticket_state(@repo_key, @issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@repo_key, @issue_id) end)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end)

    :ok
  end

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"}, extra))

    settings
  end

  defp legacy_settings, do: settings!(%{"state_machine" => "legacy"})
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
      opts ++ [settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent]
    )
  end

  defp verdicts, do: Handoff.verdicts(@repo_key, @issue_id, "qa")

  describe "qa_run?/2" do
    test "is true only for a designed repo's configured QA state" do
      assert QaVerification.qa_run?(issue(), settings!())
      assert QaVerification.qa_run?(issue(" qa "), settings!())
      assert QaVerification.qa_run?(issue("Verification"), custom_qa_settings())
      refute QaVerification.qa_run?(issue("Code Review"), settings!())
      refute QaVerification.qa_run?(issue("QA"), legacy_settings())
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
    test "skips every ticket that is not a designed repo's QA ticket" do
      assert :skip = run("/tmp/workspace", [], "Code Review")
      assert :skip = run("/tmp/workspace", settings: legacy_settings())
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
    test "retry boundedly on the same head, then take a Blocked hold" do
      {workspace, head} = git_workspace!()

      Process.put(:qa_agent_result, {:error, :environment_unreachable, %{}})

      # The first attempt retries in place, so the next tick picks it up again.
      assert :ok = run(workspace, [])

      refute_received {:memory_tracker_state_update, _, _}
      refute Hold.held?(@repo_key, @issue_id, :blocked)

      # The second attempt has used its attempts up: the ticket pauses in QA with the reason recorded.
      assert :ok = run(workspace, [])

      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert %{reason: reason, waits_on: %{type: "access"}} = Hold.get(@repo_key, @issue_id, :blocked)
      assert reason == "QA blocked after 2 attempt(s): :environment_unreachable"

      refute_received {:memory_tracker_state_update, _, _}

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]
      assert Enum.all?(verdicts(), &(&1.head_sha == head))

      assert_received {:memory_tracker_comment, @issue_id, retrying}
      assert retrying =~ "**Verdict:** blocked → QA (blocked, retrying)"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked)"
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

    test "a QA agent that cannot run on an SSH worker records why" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, {:remote_worker_unsupported, "worker-1"}, %{}})

      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])

      assert %{reason: reason} = Hold.get(@repo_key, @issue_id, :blocked)
      assert reason =~ "QA cannot run on the remote worker \"worker-1\""
    end

    test "a hold that cannot be set is reported" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, :nope, %{}})

      # Both attempts are used on the same call, so the third records "blocked" and takes the hold.
      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])

      assert {:error, {:qa_blocked_hold_failed, :disk_full}} = run(workspace, store: UnusedStore)
    end
  end
end
