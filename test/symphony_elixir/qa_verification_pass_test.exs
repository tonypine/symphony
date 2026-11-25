defmodule SymphonyElixir.QaVerificationPassTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.QaVerificationSupport

  alias SymphonyElixir.Conductor
  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaVerification
  alias SymphonyElixir.QaVerificationSupport.FakeFixer
  alias SymphonyElixir.QaVerificationSupport.FakeQaAgent
  alias SymphonyElixir.QaVerificationSupport.NoPlaybookPolicy
  alias SymphonyElixir.QaVerificationSupport.OnceEmptyPolicy
  alias SymphonyElixir.QaVerificationSupport.RunPolicy
  alias SymphonyElixir.QaVerificationSupport.WalkthroughSession
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketPullRequest

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"
  @other_issue_id "issue-qa-verification-other"
  @symphony_repo_key "repo-symphony"
  @pr_url "https://github.com/acme/repo/pull/816"
  @base_head "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

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

  # A workspace whose head tracks `test/check_test.exs`, the test the pre-check tests' proofs name.
  defp named_workspace! do
    {dir, _head} = git_workspace!()
    File.mkdir_p!(Path.join(dir, "test"))
    File.write!(Path.join(dir, "test/check_test.exs"), "test \"it checks\" do\nend\n")
    {_out, 0} = System.cmd("git", ["add", "."], cd: dir)
    {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "-m", "test"], cd: dir)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    {dir, String.trim(head)}
  end

  # A plan on the ticket: an outcome a test proves and two QA checks, one of them a design check.
  @groomed_plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["engine"],
    summary: "The check command passes and the dashboard shows it.",
    text: "Make `symphony check` pass and show its result.",
    checks: [
      %{id: "c1", kind: "outcome", statement: "`symphony check` passes.", proof: "test"},
      %{id: "c2", kind: "qa", statement: "The dashboard shows the result.", proof: "qa", state: "A run that passed", action: "Open the dashboard", expect: "It says passed"},
      %{id: "c3", kind: "qa", statement: "The result matches the design.", proof: "design", action: "Compare it", expect: "It matches"}
    ],
    size: %{tokens: 100_000, runs: 1}
  }

  defp groom!(plan \\ @groomed_plan) do
    {:ok, _ask} = SymphonyElixir.TicketPlan.record_ask(@repo_key, @issue_id, "Make the check pass and show it.")
    {:ok, _plan} = SymphonyElixir.TicketPlan.write(@repo_key, @issue_id, plan)
    :ok
  end

  defp prove_check!(check_id, test) do
    proof = %{check_id: check_id, by: "test", test: test}
    {:ok, _event} = SymphonyElixir.TicketChecks.prove(@repo_key, @issue_id, proof, actor: {:agent, "run-1", "implementation"})
  end

  # An empty store, but for the open pull request every QA ticket here has.
  defp clear_store! do
    :ok = RunStore.clear()
    :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})
  end

  describe "inconclusive runs" do
    defp target_missing do
      reason = "the app was not judged at the QA target: no `qa_resize_window` call set its window to the target size, so the screens were not checked at the size QA judges them"
      result = %{verdict: :inconclusive, summary: "Every journey worked.", steps: [], findings: [], reason: reason}
      {:ok, %{result: result, tokens: %{}}}
    end

    test "a missing target resize reruns once, then asks a person, and never reaches the self-heal lane" do
      {workspace, head} = git_workspace!()
      Process.put(:qa_agent_result, target_missing())

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA inconclusive for TP-816 head=#{head} model=claude-test playbooks=cli (attempt 1/2); rerunning: the app was not judged at the QA target"
      refute deciding()
      assert_received {:memory_tracker_comment, @issue_id, rerunning}
      assert rerunning =~ "**Verdict:** inconclusive → QA (inconclusive, rerunning)"
      assert rerunning =~ "Reason: the app was not judged at the QA target"

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "(attempt 2/2); asking a person: the app was not judged at the QA target"
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** inconclusive → QA (inconclusive; a person decides)"

      # The self-heal lane was never asked: no fix ticket, no Blocked hold, no self-heal record.
      refute_received {:fixer_create, _attrs}
      refute_received {:fixer_block, _identifier}
      refute_received {:fixer_attach, _identifier, _body}
      refute blocked?(@issue_id)
      assert SymphonyElixir.TicketState.self_heal(RunStore.get_ticket_state(@issue_id)) == nil
      refute_received {:memory_tracker_state_update, _, _}

      assert %{} = decision = deciding()
      assert decision.why =~ "The last run ended with: the app was not judged at the QA target: no qa_resize_window call set its window"
      assert_received {:memory_tracker_comment, @issue_id, request}
      assert request =~ "QA could not finish its check of TP-816"
      assert Enum.map(verdicts(), & &1.outcome) == ["inconclusive", "inconclusive"]
    end

    test "an inconclusive pass on a head CI rejects is the PR watcher's" do
      {workspace, head} = git_workspace!()
      watch = [phase: :qa, head_sha: head, facts: %{ci: :red}, decision: :wait]
      SymphonyElixir.PrWatchSupport.put_watch!(@repo_key, @issue_id, watch)
      Process.put(:qa_agent_result, target_missing())

      capture_log(fn -> assert :ok = run(workspace, []) end)

      assert [%{outcome: "blocked", details: %{component: "ci", reason: "CI is red on this head"}}] = verdicts()
      refute deciding()
    end
  end

  describe "the Conductor after a pass that could not judge the change (TP-1550)" do
    @own_block "QA cannot make the app's own Symphony fail its state request"
    @finding "Add a flag QA can set to make the state request fail, and name it in walkthrough step 3."

    # The Conductor's turn, standing in for the real one: it says it ran and answers what the test gives.
    defp conductor(route) do
      test = self()

      fn issue, repo_key ->
        send(test, {:conductor, issue.id, repo_key})
        route
      end
    end

    defp own_block, do: Process.put(:qa_agent_result, blocked_result(["Watch the state error"], @own_block))

    defp new_head!(workspace) do
      {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "merge main"], cd: workspace)
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
      String.trim(head)
    end

    defp rework_ended! do
      {:ok, _event} = SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "run.ended", %{run_id: "rework-1", run_kind: "rework", exit: "handoff"}, run_id: "rework-1")
    end

    test "a Conductor that routes nothing leaves the pass as it was: a retry, then Symphony's own question" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, conductor: conductor(:none))
      assert_received {:conductor, @issue_id, @repo_key}
      refute deciding()

      assert :ok = run(workspace, conductor: conductor(:none))
      assert_received {:conductor, @issue_id, @repo_key}
      assert %{title: "QA could not finish its check of TP-816"} = deciding()
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "with the Conductor off, the default turn runs nothing and the pass goes on as before" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, [])
      assert :ok = run(workspace, [])
      assert %{title: "QA could not finish its check of TP-816"} = deciding()
      assert RunStore.list_ticket_events(@issue_id, types: ["run.started", "conductor.instructions"]) == []
    end

    test "a rework route records the Conductor's finding in the QA run and moves the ticket to Rework under its own signal" do
      {workspace, head} = git_workspace!()
      own_block()

      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor({:rework, @finding})) end)

      assert log =~ "QA for TP-816 goes back to Rework on the Conductor's route head=#{head}"
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      refute deciding()
      refute_received {:fixer_create, _attrs}
      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()

      assert [%{name: "qa", details: %{signal: "qa_blocked_rework", target: "Rework", reason: @finding}} | _] =
               Handoff.signals(@repo_key, @issue_id)

      run_id = "qa-TP-816-" <> String.slice(head, 0, 12)

      assert [%{run_id: ^run_id, actor: %{kind: :agent}, payload: finding}] =
               RunStore.list_ticket_events(@issue_id, types: ["finding.recorded"])

      assert finding == %{class: "unclassified", severity: "unrated", description: @finding}
      assert [%{payload: %{to: "Rework", via: "qa_blocked_rework"}}] = RunStore.list_ticket_events(@issue_id, types: ["phase.entered"])
    end

    test "a rerun route leaves the ticket in QA for one more pass where Symphony would have asked" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, conductor: conductor(:none))
      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor(:rerun)) end)

      assert log =~ "QA for TP-816 runs again on the Conductor's route"
      refute deciding()
      refute_received {:memory_tracker_state_update, _, _}
      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]

      # The passes this module records are what bounds the Conductor's next rerun.
      assert Conductor.open_routes(Facts.events(@issue_id)) == ["rerun", "rework"]
      new_head!(workspace)
      assert :ok = run(workspace, conductor: conductor(:rerun))
      assert Conductor.open_routes(Facts.events(@issue_id)) == ["rework"]
    end

    test "a ticket the Conductor moved itself is left where it moved it, and Symphony asks none of its own (TP-1656)" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, conductor: conductor(:none))
      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor(:moved)) end)

      assert log =~ "QA for TP-816 leaves the ticket where the Conductor moved it; Symphony asks none of its own"
      refute deciding()
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "a question the Conductor asked holds the ticket, and Symphony asks none of its own" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, conductor: conductor(:none))
      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor(:held)) end)

      assert log =~ "QA for TP-816 waits on the Conductor's question; Symphony asks none of its own"
      refute deciding()
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "with the Conductor's question open in QA, a blocked pass asks none of its own: the ticket holds one question" do
      {workspace, _head} = git_workspace!()
      own_block()

      request = %{
        title: "QA cannot set up a failing state request",
        question: "How should TP-816 get past this QA check?",
        why: "QA stopped at the same step twice.",
        if_unanswered: "TP-816 stays in QA.",
        recommendation_reason: "The unit tests prove the step.",
        options: [%{label: "Run QA again", effect: "QA runs once more.", recommended: true}, %{label: "Leave it", effect: "Nothing moves."}]
      }

      {:ok, conductor} =
        SymphonyElixir.Questions.ask({:ticket, @repo_key, @issue_id}, request, request: true, asked_in: "QA", asked_by: %{kind: :run, name: "Conductor", run_id: "conductor-1"})

      assert :ok = run(workspace, conductor: conductor(:none))
      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor(:none)) end)

      assert log =~ ~s{QA for TP-816 could not reach a verdict after 2 run(s); it already waits on "QA cannot set up a failing state request", so it asks nothing more}
      assert [%{id: id}] = SymphonyElixir.Questions.open({:ticket, @repo_key, @issue_id})
      assert id == conductor.id

      # Answering the one question lets the ticket continue.
      {:ok, _answered} = SymphonyElixir.Questions.answer({:ticket, @repo_key, @issue_id}, id, "Run QA again")
      refute SymphonyElixir.Pauses.paused?({:ticket, @repo_key, @issue_id})
    end

    test "an inconclusive pass takes the Conductor's turn too" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, target_missing())

      capture_log(fn -> assert :ok = run(workspace, conductor: conductor({:rework, @finding})) end)

      assert_received {:conductor, @issue_id, @repo_key}
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert [%{outcome: "inconclusive"}] = verdicts()

      clear_store!()
      assert :ok = run(workspace, conductor: conductor(:none))
      log = capture_log(fn -> assert :ok = run(workspace, conductor: conductor(:none)) end)
      assert log =~ "(attempt 2/2); asking a person"
      assert %{} = deciding()
    end

    test "a block for the self-heal lane, one nothing here can prove, or one on CI never takes the Conductor's turn" do
      {workspace, head} = git_workspace!()

      Process.put(:qa_agent_result, {:error, {:qa_host_tunnel_failed, "ssh exited with status 255"}, %{}})
      assert :ok = run(workspace, conductor: conductor({:rework, @finding}))

      result = %{verdict: :blocked, summary: "No key.", steps: [], findings: [], needs_person: true, reason: "the QA host has no signing key"}
      Process.put(:qa_agent_result, {:ok, %{result: result, tokens: %{}}})
      capture_log(fn -> assert :ok = run(workspace, conductor: conductor({:rework, @finding})) end)

      clear_store!()
      Process.put(:qa_agent_result, {:ok, %{result: needs_dev_server([]), tokens: %{}}})
      assert :ok = run(workspace, settings: hub_settings(), conductor: conductor({:rework, @finding}))

      clear_store!()
      watch = [phase: :qa, head_sha: head, facts: %{ci: :red}, decision: :wait]
      SymphonyElixir.PrWatchSupport.put_watch!(@repo_key, @issue_id, watch)
      own_block()
      capture_log(fn -> assert :ok = run(workspace, conductor: conductor({:rework, @finding})) end)

      refute_received {:conductor, _issue_id, _repo_key}
      refute_received {:memory_tracker_state_update, _, "Rework"}
    end

    test "a new head with no change of the PR's own counts on: main merged into the PR earns no fresh retries" do
      {workspace, first} = git_workspace!()
      own_block()

      assert :ok = run(workspace, [])
      refute deciding()

      second = new_head!(workspace)
      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA blocked for TP-816 head=#{second} model=claude-test needs_person=false playbooks=cli (attempt 2/2); asking a person"
      assert %{question: question} = deciding()
      assert question == "QA ran TP-816 (Land the QA state) 2 times on the same change without a pass or a fail. How should it continue?"
      assert Enum.map(verdicts(), & &1.head_sha) == [second, first]

      # A rework run ended: its change is new, and so is the count.
      rework_ended!()
      new_head!(workspace)
      log = capture_log(fn -> assert :ok = run(workspace, []) end)
      assert log =~ "(attempt 1/2); retrying"
    end

    test "once the person picked Run QA again and QA ended the same way, the question recommends sending it back to Rework" do
      {workspace, _head} = git_workspace!()
      own_block()

      assert :ok = run(workspace, [])
      capture_log(fn -> assert :ok = run(workspace, []) end)
      assert %{id: first_id, options: [%{label: "Run QA again", recommended?: true}, rework, _merge]} = deciding()
      refute rework.recommended?
      assert {:ok, _answered} = SymphonyElixir.Questions.answer({:ticket, @repo_key, @issue_id}, first_id, "Run QA again")
      refute deciding()

      new_head!(workspace)
      capture_log(fn -> assert :ok = run(workspace, []) end)

      assert %{id: second_id} = decision = deciding()
      assert second_id != first_id
      assert decision.question =~ "3 times on the same change"
      assert [%{label: "Run QA again"} = again, %{label: "Send it back to Rework", recommended?: true, move: %{to: "Rework"}}, merge] = decision.options
      refute again.recommended?
      refute merge.recommended?
      assert decision.recommendation_reason == "QA ended the same way after the last rerun you asked for, so one more run would likely end the same way. A rework can change what stops QA."

      # The rework ran: its change is new, and one more run is worth it again.
      assert {:ok, _answered} = SymphonyElixir.Questions.answer({:ticket, @repo_key, @issue_id}, second_id, "Send it back to Rework")
      rework_ended!()
      assert :ok = run(workspace, [])
      capture_log(fn -> assert :ok = run(workspace, []) end)
      assert %{options: [%{label: "Run QA again", recommended?: true} | _rest]} = deciding()
    end
  end

  describe "the self-heal lane's input" do
    defp blocked_cause(cause), do: {:ok, %{result: %{verdict: :blocked, summary: "", steps: [], findings: [], reason: "the QA host failed", cause: cause}, tokens: %{}}}

    test "every other QA reason files no fix ticket: it asks a person once its retries are spent" do
      reasons = [
        {"the agent's own account", [], blocked_result(["Open the window"], "the QA host has no fake gh")},
        {"a crashed agent", [], {:error, :environment_unreachable, %{}}},
        {"the token limit", [], {:error, {:qa_token_limit, 900, 800}, %{}}},
        {"an unreadable answer", [], {:error, {:malformed_qa_response, :no_verdict_object}, %{}}},
        {"a worktree that would not check out", [], {:error, {:qa_worktree_failed, 128, "fatal: bad object"}, %{}}},
        {"a missing target resize", [], target_missing()},
        {"a change no playbook applies to", [qa_policy: NoPlaybookPolicy], nil},
        {"a remote worker", [worker_host: "worker-1"], nil}
      ]

      for {name, opts, result} <- reasons do
        RunStore.delete_ticket_state(@issue_id)
        {workspace, _head} = git_workspace!()
        if result, do: Process.put(:qa_agent_result, result), else: Process.delete(:qa_agent_result)

        capture_log(fn ->
          assert :ok = run(workspace, opts)
          assert :ok = run(workspace, opts)
        end)

        refute_received {:fixer_create, _attrs}, "#{name} filed a fix ticket"
        refute_received {:fixer_block, _identifier}, "#{name} held the ticket on a fix ticket"
        refute blocked?(@issue_id), "#{name} took a Blocked hold"
        assert deciding(), "#{name} did not ask a person"
      end
    end

    test "names a ticket with no title by its identifier alone when it asks a person" do
      {workspace, _head} = git_workspace!()
      Process.put(:qa_agent_result, {:error, :environment_unreachable, %{}})
      untitled = issue("QA", %{title: nil})
      opts = [settings: settings!(), repo_key: @repo_key, qa_policy: RunPolicy, qa_agent: FakeQaAgent, fixer: FakeFixer]

      capture_log(fn ->
        assert :ok = QaVerification.run(untitled, workspace, opts)
        assert :ok = QaVerification.run(untitled, workspace, opts)
      end)

      assert %{question: "QA ran TP-816 2 times on the same change without a pass or a fail. How should it continue?"} = deciding()
    end

    # One test for each cause: the ledger outlives the deleted record, so a loop would count the
    # earlier causes' attempts.
    for {cause, component} <- [
          {{:qa_worker, "qa_worker_unsafe"}, "worker_host"},
          {{:qa_host_missing_tool, ["go"]}, "worker_host"},
          {{:qa_host_tool_check_failed, "exit status 2"}, "worker_host"},
          {{:qa_host_tunnel_failed, "ssh exited with status 255"}, "qa_environment"},
          {{:qa_dev_server_failed, :health_timeout}, "dev_server"},
          {{:qa_dev_server_failed, {:dev_server_exit, 1}, "FATAL"}, "dev_server"}
        ] do
      @cause cause
      @component component

      test "a block the QA tools raise themselves goes to the self-heal lane: #{inspect(cause)}" do
        cause = @cause
        component = @component
        {workspace, _head} = git_workspace!()
        Process.put(:qa_agent_result, blocked_cause(cause))

        capture_log(fn ->
          assert :ok = run(workspace, [])
          assert :ok = run(workspace, [])
        end)

        assert_received {:fixer_create, %{component: ^component}}
        assert [_fix_ticket] = fix_waits(@issue_id)
        refute deciding()
      end
    end
  end

  describe "a head CI rejects" do
    # The PR and CI watcher's record of the head while the QA run is under way (R9 waits on it).
    defp watch_head!(head, facts) do
      attrs = [phase: :qa, head_sha: head, facts: facts, decision: :wait]
      SymphonyElixir.PrWatchSupport.put_watch!(@repo_key, @issue_id, attrs)
    end

    defp fail_result do
      {:ok, %{result: %{verdict: :fail, summary: "CI did not run.", steps: [], findings: ["the make-all workflow never ran on this head"]}, tokens: %{}}}
    end

    test "a fail on a red head is blocked on CI and handed to the PR watcher, never Rework" do
      {workspace, head} = git_workspace!()
      watch_head!(head, %{ci: :red, failing_check: "coverage (2/4)"})
      Process.put(:qa_agent_result, fail_result())

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA blocked on CI for TP-816 head=#{head} model=claude-test; handing the head to the PR watcher: CI is red on this head: coverage (2/4) failed"
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:fixer_create, _}
      refute blocked?(@issue_id)

      assert [%{outcome: "blocked", head_sha: ^head, details: details}] = verdicts()
      assert %{component: "ci", reason: "CI is red on this head: coverage (2/4) failed", needs_person: false} = details

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → QA (blocked on CI; the PR watcher routes the head)"
      assert report =~ "Reason: CI is red on this head: coverage (2/4) failed"
      assert report =~ "- the make-all workflow never ran on this head"
      assert Handoff.signals(@repo_key, @issue_id) == []
    end

    test "a conflict, a red head with no failing check named, or a required check missing reads as CI" do
      for {facts, reason} <- [
            {%{mergeable: :dirty}, "the PR conflicts with its base branch, so CI cannot run on this head"},
            {%{ci: :red}, "CI is red on this head"},
            {%{ci: :required_missing}, "a required check never reported on this head"}
          ] do
        RunStore.delete_ticket_state(@issue_id)
        {workspace, head} = git_workspace!()
        watch_head!(head, facts)
        Process.put(:qa_agent_result, fail_result())

        capture_log(fn -> assert :ok = run(workspace, []) end)

        refute_received {:memory_tracker_state_update, _, _}
        assert [%{outcome: "blocked", details: %{component: "ci", reason: ^reason}} | _] = verdicts()
      end
    end

    test "an environment block on a red head is handed to the watcher and spends no attempt" do
      {workspace, head} = git_workspace!()
      watch_head!(head, %{ci: :red})
      Process.put(:qa_agent_result, {:error, :environment_unreachable, %{}})

      capture_log(fn -> assert :ok = run(workspace, []) end)

      refute_received {:fixer_create, _}
      assert [%{outcome: "blocked", details: %{component: "ci"}}] = verdicts()

      # The rerun turned the same head green: a real environment block is its first attempt.
      watch_head!(head, %{ci: :green})
      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "(attempt 1/2); retrying"
      refute_received {:fixer_create, _}
    end

    test "a fail on a green head, on another head, or with no watcher record still goes to Rework" do
      for watch <- [{:same, %{ci: :green}}, {:other, %{ci: :red}}, :none] do
        RunStore.delete_ticket_state(@issue_id)
        {workspace, head} = git_workspace!()

        case watch do
          {:same, facts} -> watch_head!(head, facts)
          {:other, facts} -> watch_head!("another-head", facts)
          :none -> :ok
        end

        Process.put(:qa_agent_result, fail_result())

        capture_log(fn -> assert :ok = run(workspace, []) end)

        assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
        assert [%{outcome: "fail", head_sha: ^head} | _] = verdicts()
      end
    end
  end

  describe "a groomed ticket" do
    setup do
      clear_store!()
      groom!()
      :ok
    end

    test "QA's journey is the plan's QA checks, and the prompt carries the plan and its scope" do
      {workspace, _head} = git_workspace!()
      assert :ok = run(workspace, [])

      assert_received {:qa_agent_run, job, %Schema{}}
      assert %{source: "the QA checks of the ticket's plan", groomed: true, steps: [%{number: 2, check_id: "c2"}, %{number: 3, check_id: "c3"}]} = job.journey

      prompt = QaAgent.prompt(job, nil)
      assert prompt =~ "Journeys to verify, from the QA checks of the ticket's plan:\n2. [c2] The dashboard shows the result.\nState: A run that passed"
      assert prompt =~ "This ticket has a plan, and the steps above are its QA checks: judge them and nothing else."
      assert prompt =~ "Anything else you notice is a `note` you record with `ticket_record`, never a finding"
      assert prompt =~ "Ask, plan and checks:\n<linear_ticket_plan>\n## Ask\n\nMake the check pass and show it."
      assert prompt =~ "- [c3] qa, proof: design, open: The result matches the design."
      refute prompt =~ "Run `symphony check`."
      refute prompt =~ "Description (walkthrough and acceptance criteria):"

      parts = QaAgent.prompt_parts(job, nil, [:issue])
      assert parts =~ "Ask, plan and checks:\n<linear_ticket_plan>"

      # A ticket with no plan keeps its prompt.
      clear_store!()
      assert :ok = run(workspace, [])
      assert_received {:qa_agent_run, plain, %Schema{}}
      refute Map.has_key?(plain.journey, :groomed)
      plain_prompt = QaAgent.prompt(plain, nil)
      assert plain_prompt =~ "Description (walkthrough and acceptance criteria):\n<linear_issue_body>\n## User walkthrough"
      refute plain_prompt =~ "This ticket has a plan"
    end

    test "a pass that leaves checks of the plan open does not merge: the ticket goes to Rework with them named (TP-1589)" do
      {workspace, _head} = git_workspace!()

      log = capture_log(fn -> assert :ok = run(workspace, []) end)

      assert log =~ "QA passed, but the plan's checks c1, c2, c3 are still open"
      refute_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
    end

    test "each check QA saw pass is proved by QA on the head it judged, a design check by design" do
      {workspace, head} = git_workspace!()

      steps = [
        %{name: "[c2] The dashboard shows the result", status: "pass", details: "It says passed.", evidence: []},
        %{name: "[c3] The result matches the design", status: "pass", details: "It matches.", evidence: []}
      ]

      Process.put(:qa_agent_result, {:ok, %{result: %{verdict: :pass, summary: "Both checks passed.", steps: steps, findings: []}, tokens: %{}}})
      assert :ok = run(workspace, [])

      assert [%{id: "c1", state: :open}, second, third] = SymphonyElixir.TicketChecks.list(@issue_id)
      assert %{id: "c2", state: :proved, proved_by: walked} = second
      assert %{id: "c3", state: :proved, proved_by: design} = third

      assert %{by: "qa", details: "It says passed.", head: ^head} = walked
      assert %{by: "design", head: ^head} = design
    end

    test "a check that failed stays open, and the one that passed beside it is proved" do
      {workspace, _head} = git_workspace!()

      steps = [
        %{name: "[c2] The dashboard shows the result", status: "pass", details: "It says passed.", evidence: []},
        %{name: "[c3] The result matches the design", status: "fail", details: "The colour is off.", evidence: []}
      ]

      failed = %{verdict: :fail, summary: "One check failed.", steps: steps, findings: ["[c3] The colour is off."]}
      Process.put(:qa_agent_result, {:ok, %{result: failed, tokens: %{}}})
      assert :ok = run(workspace, [])

      assert [%{id: "c1", state: :open}, %{id: "c2", state: :proved}, %{id: "c3", state: :open}] = SymphonyElixir.TicketChecks.list(@issue_id)
    end
  end

  describe "the seed and fixtures check before a pass (TP-1671)" do
    setup do
      clear_store!()
      :ok
    end

    # The test's own small seed on the head, never the repository's.
    defp seeded_workspace! do
      {dir, _head} = git_workspace!()
      File.mkdir_p!(Path.join(dir, "priv/qa_seed/demo"))
      File.write!(Path.join(dir, "priv/qa_seed/demo/seed.json"), ~s({"tickets": 1}))
      {_out, 0} = System.cmd("git", ["add", "."], cd: dir)
      {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "-m", "seed"], cd: dir)
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
      {dir, String.trim(head)}
    end

    defp groom_walked_on!(paths) do
      walked_on = Enum.map(paths, &%{path: &1, holds: "present"})
      [outcome, walk, design] = @groomed_plan.checks
      groom!(%{@groomed_plan | checks: [outcome, Map.put(walk, :walked_on, walked_on), design]})
    end

    defp qa_state_steps(head) do
      for %{type: "step.completed", payload: %{step_id: "qa_state"} = payload, head_sha: ^head} <- RunStore.list_ticket_events(@issue_id, []), do: payload
    end

    test "a head that misses a QA check's seed state goes to Rework with no QA session, told what is missing" do
      {workspace, head} = seeded_workspace!()
      groom_walked_on!(["priv/qa_seed/demo/split.json"])

      log = capture_log(fn -> assert :ok = run(workspace, run_id: "run-qa-1") end)

      assert log =~ "QA for TP-816 head=#{head} goes back to Rework without a QA session"
      refute_received {:qa_agent_run, _job, _settings}
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}
      assert verdicts() == []

      assert [%{outcome: "failed", qa_state: [%{check_id: "c2", status: "missing", paths: [%{path: "priv/qa_seed/demo/split.json", why: "absent"}]}, %{check_id: "c3", status: "unjudged"}]}] =
               qa_state_steps(head)

      assert [%{state: :open, finding: %{run_id: "run-qa-1", payload: %{class: "qa_state", description: description}}}] =
               @issue_id |> RunStore.list_ticket_events([]) |> SymphonyElixir.TicketEvents.findings()

      assert description =~ "QA check c2 (The dashboard shows the result.)"
      assert description =~ "priv/qa_seed/demo/split.json (the plan says the seed or fixtures hold it already; the head does not hold it)"
    end

    test "a head that holds every QA check's seed state goes on to the QA session" do
      {workspace, head} = seeded_workspace!()
      groom_walked_on!(["priv/qa_seed/demo/seed.json"])

      capture_log(fn -> assert :ok = run(workspace, run_id: "run-qa-1") end)

      assert_received {:qa_agent_run, _job, _settings}
      assert [%{outcome: "passed", qa_state: [%{check_id: "c2", status: "held"}, %{check_id: "c3", status: "unjudged"}]}] = qa_state_steps(head)
    end
  end

  describe "a recorded test proof" do
    @named_walkthrough """
    ## User walkthrough

    1. Run `symphony check` → it passes.
    2. Open the dashboard → it looks right. Proved by: QA
    """

    # Step 1's proof is an event, as the implementer records it; the description names none.
    setup do
      clear_store!()
      record_proof!(1, "test/check_test.exs")
      :ok
    end

    # The repo's settings carry no proof check: none exists.
    defp run_named(workspace, description, opts) do
      QaVerification.run(
        issue("QA", %{description: description}),
        workspace,
        Keyword.merge(
          [
            settings: settings!(),
            repo_key: @repo_key,
            qa_policy: RunPolicy,
            qa_agent: FakeQaAgent,
            fixer: FakeFixer,
            symphony_repo_key: @symphony_repo_key,
            gh_runner: unread_gh()
          ],
          opts
        )
      )
    end

    # A `gh` that answers the pull request's checks as `checks` say, and tells the test it was asked.
    defp ci_gh(head, checks) do
      recipient = self()

      fn args, _opts ->
        send(recipient, {:gh_read, args})
        {Jason.encode!(%{"url" => @pr_url, "headRefOid" => head, "statusCheckRollup" => checks}), 0}
      end
    end

    defp unread_gh, do: fn args, _opts -> flunk("the pass read CI: gh #{inspect(args)}") end

    defp make_all(status, conclusion), do: %{"name" => "make-all", "workflowName" => "make-all", "status" => status, "conclusion" => conclusion}

    test "starts the agent with the step proved, reading no CI, whether the checks passed, run, failed or are absent" do
      for checks <- [[make_all("COMPLETED", "SUCCESS")], [make_all("IN_PROGRESS", nil)], [make_all("COMPLETED", "FAILURE")], []] do
        RunStore.delete_ticket_state(@issue_id)
        clear_store!()
        record_proof!(1, "test/check_test.exs")
        {workspace, head} = named_workspace!()

        assert :ok = run_named(workspace, @named_walkthrough, gh_runner: ci_gh(head, checks), run_id: "run-proof-#{System.unique_integer([:positive])}")

        refute_received {:gh_read, _args}
        assert_received {:qa_agent_run, job, %Schema{}}
        assert [%{number: 1, proof: %{by: :test, test: "test/check_test.exs"}}] = job.proofs
        assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
        assert [%{outcome: "pass", head_sha: ^head} | _] = verdicts()
      end
    end

    test "the prompt says the step is proved and not to read CI for it, and the report names its test, never a passed check" do
      {workspace, head} = named_workspace!()

      assert :ok = run_named(workspace, @named_walkthrough, [])

      assert_received {:qa_agent_run, job, %Schema{}}
      prompt = QaAgent.prompt(job, nil)
      assert prompt =~ "Do not walk those steps and do not read CI for them."
      assert prompt =~ "Steps a named test proves (proved, do not walk them):\n- 1. Run `symphony check` → it passes. Proved by: `test/check_test.exs`\n"
      assert prompt =~ "Steps to walk (`Proved by: QA`, or no proof named):\n- 2. Open the dashboard → it looks right. Proved by: QA\n"
      refute prompt =~ "gh run list --commit"
      refute prompt =~ "is in the checkout"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "### Pre-checks\n\n- **proved** step 1: proved by `test/check_test.exs`, recorded on the ticket"
      refute report =~ "passed on"
      refute report =~ "is in the checkout"
      assert [%{outcome: "pass", head_sha: ^head}] = verdicts()
    end

    test "a proof recorded in the older form naming a check is proved by its test, whatever the check" do
      proofs =
        for check <- ["make-all", "ci", "macos-e2e"] do
          RunStore.delete_ticket_state(@issue_id)
          clear_store!()
          record_proof!(1, "#{check} › test/check_test.exs")
          {workspace, _head} = named_workspace!()

          assert :ok = run_named(workspace, @named_walkthrough, run_id: "run-old-form-#{check}")
          assert_received {:qa_agent_run, job, %Schema{}}
          {job.proofs, Enum.map(job.journey.steps, & &1.proof)}
        end

      assert [{[%{number: 1, proof: %{by: :test, test: "test/check_test.exs"}}], [%{by: :test, test: "test/check_test.exs"}, %{by: :qa}]}] = Enum.uniq(proofs)
    end

    test "a recorded proof decides a pass whose only walked step is unprovable here" do
      {workspace, head} = named_workspace!()

      steps = [%{name: "Open the dashboard", status: "unprovable", details: "the app's playbook is not in this pass", evidence: []}]
      blocked = %{verdict: :blocked, summary: "", steps: steps, findings: [], reason: "the app is not in this pass"}
      Process.put(:qa_agent_result, {:ok, %{result: blocked, tokens: %{}}})

      assert :ok = run_named(workspace, @named_walkthrough, settings: app_repo_settings())

      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert [%{outcome: "pass", head_sha: ^head}] = verdicts()
    end

    test "a groomed ticket's check a test proves is proved and not walked, in a repo with no proof check" do
      {workspace, _head} = named_workspace!()
      # Its one check: the pass leaves nothing open, so the ticket merges.
      groom!(%{@groomed_plan | checks: Enum.take(@groomed_plan.checks, 1)})
      prove_check!("c1", "test/check_test.exs")

      assert :ok = run_named(workspace, "No walkthrough.", [])

      assert_received {:qa_agent_run, job, %Schema{}}
      assert [%{number: 1, check_id: "c1", text: "[c1] `symphony check` passes.", proof: %{by: :test, test: "test/check_test.exs"}}] = job.proofs
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
    end

    test "a ticket whose steps no event proves hands nothing on and QA walks every step" do
      clear_store!()
      {workspace, _head} = named_workspace!()

      assert :ok = run_named(workspace, "## User walkthrough\n\n1. Run `symphony check`. Proved by: `test/check_test.exs`\n", [])

      assert_received {:qa_agent_run, job, %Schema{}}
      assert job.proofs == []
      assert QaAgent.prompt(job, nil) =~ "walk every step, whatever its `Proved by:` line says"

      assert_received {:memory_tracker_comment, @issue_id, report}
      refute report =~ "### Pre-checks"
    end

    test "a description's `Proved by:` line naming another repo's check proves nothing: only the events do" do
      clear_store!()
      {workspace, _head} = named_workspace!()
      description = "## User walkthrough\n\n1. Run it. Proved by: ci › test/x_test.exs\n2. Open the dashboard → it looks right.\n"

      assert :ok = run_named(workspace, description, [])

      assert_received {:qa_agent_run, job, %Schema{}}
      assert job.proofs == []
      assert Enum.map(job.journey.steps, & &1.proof) == [%{by: :qa}, %{by: :qa}]
    end

    test "a pass with no playbook that applies is blocked and keeps the proved steps' lines" do
      {workspace, _head} = named_workspace!()

      assert :ok = run_named(workspace, @named_walkthrough, qa_policy: NoPlaybookPolicy)

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "Reason: no QA playbook applies to this change"
      assert report =~ "- **proved** step 1"
    end
  end

  # A reused workspace still holds the head of its last run, while branch upkeep merged the base
  # branch into the PR after the approve. `origin` is a bare repo holding the PR head where GitHub
  # keeps it, `refs/pull/816/head`.
  describe "the workspace synced to the PR head" do
    # The walkthrough's step 1 is proved by an event.
    setup do
      clear_store!()
      record_proof!(1, "test/check_test.exs")
      :ok
    end

    defp git!(args, dir) do
      {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      String.trim(output)
    end

    defp commit!(dir, message), do: git!(["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message], dir)

    # A workspace at `head` whose PR head on `origin` is one commit ahead of it, `pr_head`.
    defp behind_pr_workspace! do
      {workspace, head} = named_workspace!()
      origin = workspace <> "-origin.git"
      git!(["init", "-q", "--bare", origin], workspace)
      on_exit(fn -> File.rm_rf(origin) end)
      git!(["remote", "add", "origin", origin], workspace)
      git!(["push", "-q", "origin", "HEAD:refs/heads/auto/TP-816"], workspace)

      commit!(workspace, "Merge origin/main into auto/TP-816")
      pr_head = git!(["rev-parse", "HEAD"], workspace)
      git!(["push", "-q", "origin", "HEAD:refs/heads/auto/TP-816", "HEAD:refs/pull/816/head"], workspace)
      git!(["reset", "-q", "--hard", head], workspace)

      {workspace, head, pr_head, origin}
    end

    # GitHub's PR diff is not empty, so a workspace that finds nothing to verify is out of sync, never
    # an empty change: the walkthrough's "press Update branch, the ticket lands, no restart question".
    test "a local nothing to verify with a non-empty GitHub diff re-syncs, runs QA and asks no question" do
      {workspace, _head, pr_head, _origin} = behind_pr_workspace!()

      opts = [qa_policy: OnceEmptyPolicy, gh_runner: github_diff(pr_head, 3)]
      log = capture_log(fn -> assert :ok = run(workspace, opts) end)

      assert log =~ "found nothing to verify while GitHub's PR head #{String.slice(pr_head, 0, 12)} changes 3 files; re-synced its workspace"
      assert git!(["rev-parse", "HEAD"], workspace) == pr_head
      assert_received {:qa_agent_run, %{sha: ^pr_head}, %Schema{}}
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      refute_received {:memory_tracker_comment, @issue_id, "## Decision needed" <> _rest}
      assert deciding() == nil
      assert {:ok, nil} = Pauses.get({:ticket, @repo_key, @issue_id})
    end

    test "a workspace that still finds nothing after the re-sync pauses on a reason Unblock releases" do
      {workspace, _head, pr_head, _origin} = behind_pr_workspace!()

      capture_log(fn -> assert :ok = run(workspace, nothing_opts(github_diff(pr_head, 3))) end)

      refute_received {:qa_agent_run, _, _}
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:memory_tracker_comment, @issue_id, "## Decision needed" <> _rest}
      assert deciding() == nil
      assert verdicts() == []

      short = String.slice(pr_head, 0, 12)
      assert {:ok, %{reasons: [%{text: text, releasable: true, waits_on: %{condition: "empty_change:" <> ^short}}]}} = Pauses.get({:ticket, @repo_key, @issue_id})

      assert text ==
               "QA found no change in its workspace at #{short}, but GitHub's PR head #{short} changes 3 files against main at #{String.slice(@base_head, 0, 12)}. Unblock runs it again."
    end

    test "a workspace the re-sync cannot bring to the PR head pauses on the Unblock reason" do
      {workspace, head} = git_workspace!()
      pr_head = "9999999999999999999999999999999999999999"

      capture_log(fn -> assert :ok = run(workspace, nothing_opts(github_diff(pr_head, 2))) end)

      assert deciding() == nil
      assert {:ok, %{reasons: [%{text: text, releasable: true}]}} = Pauses.get({:ticket, @repo_key, @issue_id})
      assert text =~ "QA found no change in its workspace at #{String.slice(head, 0, 12)}, but GitHub's PR head 999999999999 changes 2 files"
    end

    test "a workspace behind the PR head is reset to it, and the verdict binds to the PR head" do
      {workspace, _head, pr_head, _origin} = behind_pr_workspace!()

      assert :ok = run_named(workspace, @named_walkthrough, [])

      assert git!(["rev-parse", "HEAD"], workspace) == pr_head
      assert_received {:qa_agent_run, %{sha: ^pr_head}, %Schema{}}
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert [%{outcome: "pass", head_sha: ^pr_head}] = verdicts()
      refute_received {:memory_tracker_comment, @issue_id, "## Decision needed" <> _rest}
    end

    test "a workspace with local changes is never reset: the run is blocked naming them" do
      {workspace, head, pr_head, _origin} = behind_pr_workspace!()
      for n <- 1..6, do: File.write!(Path.join(workspace, "notes-#{n}.txt"), "draft")

      assert :ok = run_named(workspace, @named_walkthrough, [])

      assert git!(["rev-parse", "HEAD"], workspace) == head
      assert File.exists?(Path.join(workspace, "notes-6.txt"))
      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_comment, @issue_id, report}

      assert report =~
               "Reason: the workspace at #{String.slice(head, 0, 12)} is behind the PR head #{String.slice(pr_head, 0, 12)} and was not reset to it, " <>
                 "because it has local changes (?? notes-1.txt, ?? notes-2.txt, ?? notes-3.txt, ?? notes-4.txt, ?? notes-5.txt and 1 more)"

      assert [%{outcome: "blocked", head_sha: ^head}] = verdicts()
    end

    test "a workspace with a commit nothing on origin has is never reset" do
      {workspace, _head, _pr_head, _origin} = behind_pr_workspace!()
      commit!(workspace, "work in progress")
      local = git!(["rev-parse", "HEAD"], workspace)

      assert :ok = run(workspace, [])

      assert git!(["rev-parse", "HEAD"], workspace) == local
      refute_received {:qa_agent_run, _, _}
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "because it has 1 unpushed commit(s) (#{String.slice(local, 0, 12)})"
    end

    test "a git read or reset that fails leaves the workspace as it is" do
      {workspace, head, pr_head, _origin} = behind_pr_workspace!()

      failing_status = fn
        ["status" | _rest], _dir -> {"fatal: index locked", 128}
        args, dir -> System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      end

      assert :ok = run(workspace, git: failing_status)
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "because it has a state git could not read (git status exited 128: fatal: index locked)"

      failing_reset = fn
        ["reset" | _rest], _dir -> {"fatal: cannot lock ref", 128}
        args, dir -> System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      end

      RunStore.delete_ticket_state(@issue_id)
      :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})

      log = capture_log(fn -> assert :ok = run(workspace, git: failing_reset) end)

      assert log =~ "QA for TP-816 runs on its workspace head: the PR head could not be synced: {:pr_head_reset_failed, 128"
      assert_received {:qa_agent_run, %{sha: ^head}, %Schema{}}
      refute head == pr_head
    end
  end

  describe "the pass's ledger events" do
    @home String.duplicate("a", 64)
    @detail String.duplicate("b", 64)
    @row String.duplicate("c", 64)
    @transcript String.duplicate("d", 64)

    setup do
      :ok = RunStore.clear()
      :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})
      :ok
    end

    defp artifacts do
      files = %{"qa-evidence/home.png" => @home, "qa-evidence/detail.png" => @detail, "https://uploads.linear.app/qa/row.png" => @row}
      %{files: files, transcript: @transcript}
    end

    defp events, do: SymphonyElixir.TicketEvents.query(@issue_id, limit: 200)

    defp agent_result(result), do: Process.put(:qa_agent_result, {:ok, %{result: result, tokens: %{}}})

    test "a fail records each step's evidence and each finding, then the verdict, once however often it is handled" do
      {workspace, head} = git_workspace!()

      steps = [
        %{name: "Step 1", status: "fail", details: "blank", environment: "live", evidence: ["qa-evidence/home.png", "qa-evidence/detail.png"]},
        %{name: "Step 2", status: "fail", details: "clipped", evidence: ["https://uploads.linear.app/qa/row.png", "https://ci.test/run/1"]},
        %{name: "Step 3", status: "pass", details: "fine", evidence: []}
      ]

      details = [
        %{line: "Step 1: The home screen is blank. Evidence: qa-evidence/home.png.", step: "Step 1", viewport: "1400×900 pt", evidence: ["qa-evidence/home.png"]},
        %{line: "step 2: The row is clipped.", step: "step 2", viewport: nil, evidence: []}
      ]

      agent_result(%{
        verdict: :fail,
        summary: "Two defects.",
        steps: steps,
        findings: Enum.map(details, & &1.line),
        finding_details: details,
        artifacts: artifacts()
      })

      assert :ok = run(workspace, run_id: "run-qa-1")
      assert :ok = run(workspace, run_id: "run-qa-1")

      [step_1, step_2, step_3, transcript, finding_1, finding_2, verdict, second_verdict] =
        Enum.filter(events(), &(&1.type in ["evidence", "finding.recorded", "verdict.recorded"]))

      assert %{type: "evidence", payload: %{caption: "Step 1: fail", artifacts: [@home, @detail]}, artifacts: [@home, @detail]} = step_1
      assert %{step: "Step 1", status: "fail", details: "blank", environment: "live"} = step_1.payload
      refute Map.has_key?(step_1.payload, :links)
      assert %{type: "evidence", payload: %{caption: "Step 2: fail", artifacts: [@row]}, idempotency: "evidence:run-qa-1:2"} = step_2
      assert %{step: "Step 2", links: ["https://ci.test/run/1"]} = step_2.payload
      refute Map.has_key?(step_2.payload, :environment)
      assert %{type: "evidence", artifacts: [], payload: %{caption: "Step 3: pass", step: "Step 3", status: "pass", details: "fine"}} = step_3
      assert %{type: "evidence", payload: %{caption: "QA session transcript"}, artifacts: [@transcript]} = transcript
      refute Map.has_key?(transcript.payload, :step)

      # The report renders the pass's events: each step with its environment and evidence, each
      # finding with its state and its files (none uploaded here: the tracker is not Linear).
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "- **fail** Step 1 (proved on the live server; evidence: artifact `#{@home}`, artifact `#{@detail}`)"
      assert report =~ "- **fail** Step 2 (evidence: artifact `#{@row}`, https://ci.test/run/1)"
      assert report =~ "- **pass** Step 3\n"
      assert report =~ "### Findings\n\n- #{hd(details).line} · **open** · evidence: artifact `#{@home}`"
      assert report =~ "- step 2: The row is clipped. · **open** · evidence: artifact `#{@row}`"

      assert %{
               type: "finding.recorded",
               actor: %{kind: :agent, run_id: "run-qa-1", run_kind: "qa"},
               run_id: "run-qa-1",
               idempotency: "finding:run-qa-1:1",
               artifacts: [@home],
               payload: %{class: "unclassified", severity: "unrated", step: "Step 1", viewport: "1400×900 pt", evidence: ["qa-evidence/home.png"]} = payload
             } = finding_1

      assert payload.description == hd(details).line
      assert finding_1.summary.title == "QA found a defect at 1400×900 pt: Step 1"
      assert %{artifacts: [@row], payload: %{step: "step 2"} = second} = finding_2
      refute Map.has_key?(second, :evidence)
      assert %{type: "verdict.recorded", run_id: "run-qa-1", actor: %{kind: :machine}, payload: %{outcome: "fail"}} = verdict
      assert %{type: "verdict.recorded", run_id: "run-qa-1"} = second_verdict
      assert [%{outcome: "fail"}, %{outcome: "fail"}] = Enum.filter(verdicts(), &(&1.head_sha == head))
    end

    test "a fail with no findings records its failing steps as findings, its text cut to the schema" do
      {workspace, _head} = git_workspace!()
      long = String.duplicate("x", 2_100)

      agent_result(%{
        verdict: :fail,
        summary: "No.",
        steps: [%{name: String.duplicate("s", 600), status: "fail", details: long, evidence: ["qa-evidence/home.png"]}],
        findings: [],
        artifacts: artifacts()
      })

      assert :ok = run(workspace, run_id: "run-qa-2")

      assert [
               %{type: "evidence", payload: %{caption: caption}},
               %{type: "evidence", artifacts: [@transcript]},
               %{type: "finding.recorded", artifacts: [@home], payload: payload},
               %{type: "verdict.recorded"}
             ] =
               Enum.filter(events(), &(&1.type in ["evidence", "finding.recorded", "verdict.recorded"]))

      assert String.length(caption) == 500
      assert String.length(payload.description) == 2_000
      assert String.length(payload.step) == 200
    end

    test "findings given only as lines are recorded with no step or evidence" do
      {workspace, _head} = git_workspace!()
      agent_result(%{verdict: :fail, summary: "No.", steps: [], findings: ["The header is clipped."]})

      assert :ok = run(workspace, run_id: "run-qa-3")

      assert [%{type: "finding.recorded", artifacts: [], payload: %{description: "The header is clipped."} = payload}, %{type: "verdict.recorded"}] =
               Enum.filter(events(), &(&1.type in ["evidence", "finding.recorded", "verdict.recorded"]))

      refute Map.has_key?(payload, :step)
    end

    # A finding QA recorded, resolved by a rework run on `head`.
    defp resolved_finding!(fields, head) do
      payload = Map.merge(%{class: "unclassified", severity: "unrated", description: "The row is clipped."}, fields)
      {:ok, finding} = SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "finding.recorded", payload, actor: {:agent, "run-qa-0", "qa"})

      {:ok, resolution} =
        SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "finding.resolved", %{finding_id: finding.id, how: "Let the row wrap"}, actor: {:agent, "run-rw", "rework"}, head_sha: head)

      {finding, resolution}
    end

    defp finding_states do
      @issue_id |> RunStore.list_ticket_events([]) |> SymphonyElixir.TicketEvents.findings() |> Map.new(&{&1.finding.id, &1})
    end

    test "a fail on the same step reopens the resolved finding, pointing at the resolution it supersedes" do
      {workspace, head} = git_workspace!()
      {finding, resolution} = resolved_finding!(%{step: "Step 2", viewport: "1400×900 pt"}, head)
      {elsewhere, _other} = resolved_finding!(%{step: "Step 3"}, head)

      details = [
        %{line: "step 2: The row is still clipped.", step: "step 2", viewport: "1400×900 pt", evidence: []},
        %{line: "Step 2: The row is clipped again.", step: "Step 2", viewport: "1400×900 pt", evidence: []},
        %{line: "The header is clipped.", step: nil, viewport: nil, evidence: []}
      ]

      agent_result(%{verdict: :fail, summary: "Still clipped.", steps: [], findings: Enum.map(details, & &1.line), finding_details: details})

      assert :ok = run(workspace, run_id: "run-qa-9")
      assert :ok = run(workspace, run_id: "run-qa-9")

      assert [_found, _elsewhere_found, reopen, second, header] = Enum.filter(events(), &(&1.type == "finding.recorded"))
      assert reopen.supersedes == resolution.id
      assert reopen.summary.title == "QA reopened a defect at 1400×900 pt: step 2"
      # One report finding supersedes a resolution at most; a finding with no step matches none.
      assert second.supersedes == nil
      assert header.supersedes == nil

      states = finding_states()
      assert %{state: :reopened, reopened_by: %{id: reopen_id}, superseded: %{id: superseded}} = states[finding.id]
      assert {reopen_id, superseded} == {reopen.id, resolution.id}
      assert %{state: :resolved} = states[elsewhere.id]
      assert [] == Enum.filter(events(), &(&1.type == "finding.confirmed"))
    end

    test "a fail matches the viewport too: the same step at another viewport is a new finding" do
      {workspace, head} = git_workspace!()
      {finding, _resolution} = resolved_finding!(%{step: "Step 2", viewport: "1400×900 pt"}, head)

      details = [%{line: "Step 2: clipped.", step: "Step 2", viewport: "2560×1440 pt", evidence: []}]
      agent_result(%{verdict: :fail, summary: "Clipped.", steps: [], findings: Enum.map(details, & &1.line), finding_details: details})

      assert :ok = run(workspace, run_id: "run-qa-10")

      assert %{state: :resolved} = finding_states()[finding.id]
      assert [%{supersedes: nil}] = Enum.filter(events(), &(&1.type == "finding.recorded" and &1.run_id == "run-qa-10"))
    end

    test "a pass confirms every finding resolved and awaiting QA, by that verdict, once however often it is handled" do
      {workspace, head} = git_workspace!()
      {finding, resolution} = resolved_finding!(%{step: "Step 2"}, "0ld0ld0ld")
      {on_head, on_head_resolution} = resolved_finding!(%{step: "Step 3"}, head)
      {:ok, open} = SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "finding.recorded", %{class: "unclassified", severity: "unrated", description: "Open."}, actor: {:agent, "run-qa-0", "qa"})

      agent_result(%{verdict: :pass, summary: "Fine.", steps: [], findings: []})
      assert :ok = run(workspace, run_id: "run-qa-11")
      assert :ok = run(workspace, run_id: "run-qa-11")

      assert [first, second] = Enum.filter(events(), &(&1.type == "finding.confirmed"))
      assert %{actor: %{kind: :machine}, run_id: "run-qa-11", head_sha: ^head, payload: payload} = first
      assert %{finding_id: finding_id, resolution: resolution_id, head: ^head} = payload
      assert {finding_id, resolution_id} == {finding.id, resolution.id}
      assert second.payload.resolution == on_head_resolution.id
      assert first.summary.title == "QA confirmed a finding fixed"

      states = finding_states()
      assert %{state: :confirmed, resolution: ^resolution} = states[finding.id]
      assert %{state: :confirmed} = states[on_head.id]
      assert %{state: :open} = states[open.id]
    end

    test "a pass records its steps' evidence and the transcript, and no finding" do
      {workspace, _head} = git_workspace!()

      agent_result(%{
        verdict: :pass,
        summary: "Fine.",
        steps: [%{name: "Step 1", status: "pass", details: "ok", evidence: ["qa-evidence/home.png", "https://ci.test/run/1"]}],
        findings: [],
        artifacts: artifacts()
      })

      assert :ok = run(workspace, run_id: "run-qa-4")

      assert [
               %{type: "evidence", payload: %{caption: "Step 1: pass"}, artifacts: [@home], actor: %{kind: :agent, run_kind: "qa"}},
               %{type: "evidence", payload: %{caption: "QA session transcript"}, artifacts: [@transcript], idempotency: "evidence:run-qa-4:2"},
               %{type: "verdict.recorded", run_id: "run-qa-4", payload: %{outcome: "pass"}}
             ] = Enum.filter(events(), &(&1.type in ["evidence", "finding.recorded", "verdict.recorded"]))
    end

    test "a blocked verdict names the QA run that gave it" do
      {workspace, _head} = git_workspace!()
      agent_result(%{verdict: :blocked, summary: "No emulator.", steps: [], findings: [], reason: "the QA host failed", artifacts: artifacts()})

      assert :ok = run(workspace, run_id: "run-qa-5")

      assert [%{type: "evidence", run_id: "run-qa-5"}, %{type: "verdict.recorded", run_id: "run-qa-5", payload: %{outcome: "blocked"}}] =
               Enum.filter(events(), &(&1.type in ["evidence", "verdict.recorded"]))
    end

    test "a verdict from a run given no id names the id its evidence carries" do
      {workspace, head} = git_workspace!()
      agent_result(%{verdict: :pass, summary: "Fine.", steps: [], findings: [], artifacts: artifacts()})

      assert :ok = run(workspace, [])

      run_id = "qa-TP-816-#{String.slice(head, 0, 12)}"
      assert [%{type: "evidence", run_id: ^run_id}, %{type: "verdict.recorded", run_id: ^run_id}] = Enum.filter(events(), &(&1.type in ["evidence", "verdict.recorded"]))
    end
  end

  describe "the operator's walkthrough" do
    @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>

    setup do
      :ok = RunStore.clear()
      :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})
      root = Path.join(System.tmp_dir!(), "qa-walkthrough-#{System.unique_integer([:positive])}")
      projects = Path.join(root, "projects")
      Application.put_env(:symphony_elixir, :claude_projects_dir, projects)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :claude_projects_dir)
        File.rm_rf(root)
        File.rm_rf(SymphonyElixir.Paths.artifacts_dir())
      end)

      %{settings: settings!(%{"workspace" => %{"root" => Path.join(root, "workspaces")}, "auto_review" => %{"kind" => "claude"}}), projects: projects}
    end

    defp walk(workspace, settings, session) do
      Process.put(:walkthrough_session, session)

      QaVerification.run(issue(), workspace,
        settings: settings,
        repo_key: @repo_key,
        run_id: "run-walkthrough",
        qa_policy: RunPolicy,
        qa_agent_module: WalkthroughSession,
        leftover_processes: [table: fn -> {:ok, []} end]
      )
    end

    defp ledger, do: Enum.filter(SymphonyElixir.TicketEvents.query(@issue_id, limit: 200), &(&1.type in ["evidence", "finding.recorded", "verdict.recorded"]))

    defp stored!(id) do
      assert {:ok, path} = SymphonyElixir.Artifacts.path(id)
      File.read!(path)
    end

    test "a fail with two findings and three screenshots leaves the findings, pointing at the screenshots, then the verdict", %{settings: settings} do
      {workspace, head} = git_workspace!()
      shots = for n <- 1..3, do: {"qa-evidence/shot-#{n}.png", @png <> <<n>>}

      findings = [
        %{"step" => "Step 1", "summary" => "The list is empty", "evidence" => ["qa-evidence/shot-1.png", "qa-evidence/shot-2.png"]},
        %{"step" => "Step 2", "viewport" => "1400×900 pt", "summary" => "The row is clipped", "evidence" => ["qa-evidence/shot-3.png"]}
      ]

      assert :ok = walk(workspace, settings, %{files: shots, uploads: [], verdict: %{"verdict" => "fail", "findings" => findings}})

      refute File.exists?(QaAgent.worktree_path(settings, @repo_key, "TP-816", head))
      assert_received {:memory_tracker_state_update, @issue_id, "Rework"}

      assert [%{type: "finding.recorded"} = first, %{type: "finding.recorded"} = second, %{type: "verdict.recorded", payload: %{outcome: "fail"}}] = ledger()
      assert %{actor: %{kind: :agent, run_kind: "qa", run_id: "run-walkthrough"}, payload: %{step: "Step 1"}} = first
      assert %{payload: %{step: "Step 2", viewport: "1400×900 pt"}} = second
      assert Enum.map(first.artifacts ++ second.artifacts, &stored!/1) == Enum.map(shots, &elem(&1, 1))
    end

    test "a finding citing its Linear upload points at the stored screenshot, and the upload is made as before", %{settings: settings} do
      {workspace, _head} = git_workspace!()
      shot = @png <> <<7>>
      finding = %{"step" => "Step 1", "summary" => "The badge is missing", "evidence" => ["https://uploads.linear.app/qa/badge.png"]}

      assert :ok =
               walk(workspace, settings, %{
                 files: [{"qa-evidence/badge.png", shot}],
                 uploads: ["qa-evidence/badge.png"],
                 verdict: %{"verdict" => "fail", "findings" => [finding]}
               })

      assert_received {:walkthrough_upload, "badge.png"}
      assert [%{type: "finding.recorded", artifacts: [id]}, %{type: "verdict.recorded"}] = ledger()
      assert stored!(id) == shot
      assert {:ok, %{projections: %{linear_url: "https://uploads.linear.app/qa/badge.png"}}} = SymphonyElixir.Artifacts.get(id)

      # The report's finding links the screenshot the agent already uploaded.
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "· **open** · evidence: [badge.png](https://uploads.linear.app/qa/badge.png)"
    end

    test "a pass shows each step's evidence and keeps the QA session's transcript", %{settings: settings, projects: projects} do
      {workspace, head} = git_workspace!()
      worktree = QaAgent.worktree_path(settings, @repo_key, "TP-816", head)
      transcript = Path.join([projects, String.replace(worktree, ~r/[^A-Za-z0-9]/, "-"), "walkthrough-session.jsonl"])
      File.mkdir_p!(Path.dirname(transcript))
      File.write!(transcript, ~s({"type":"system"}\n))

      steps = [
        %{"name" => "Step 1", "status" => "pass", "evidence" => ["qa-evidence/home.png"]},
        %{"name" => "Step 2", "status" => "pass", "evidence" => ["https://ci.test/run/1"]}
      ]

      assert :ok = walk(workspace, settings, %{files: [{"qa-evidence/home.png", @png}], uploads: [], verdict: %{"verdict" => "pass", "steps" => steps}})

      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}

      assert [
               %{type: "evidence", payload: %{caption: "Step 1: pass"}, artifacts: [home]},
               %{type: "evidence", payload: %{caption: "Step 2: pass"}, artifacts: []},
               %{type: "evidence", payload: %{caption: "QA session transcript"}, artifacts: [session]},
               %{type: "verdict.recorded", payload: %{outcome: "pass"}}
             ] = ledger()

      assert stored!(home) == @png
      assert stored!(session) == ~s({"type":"system"}\n)
    end
  end

  describe "carry_verdict/3" do
    test "re-binds the newest pass to the new head, and carries nothing otherwise" do
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, "new-head")

      :ok = put_verdict(@repo_key, @issue_id, "qa", "old-head", "fail")
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, "new-head")
      assert [%{head_sha: "old-head", outcome: "fail"}] = verdicts()

      :ok = put_verdict(@repo_key, @issue_id, "qa", "old-head", "pass")
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, nil)
      assert [%{head_sha: "old-head", outcome: "pass"} | _] = verdicts()
    end

    test "a carried pass names no run: no run gave it" do
      :ok = put_verdict(@repo_key, @issue_id, "qa", "old-head", "pass")
      assert :ok = QaVerification.carry_verdict(@repo_key, @issue_id, "new-head")

      assert [_old, %{type: "verdict.recorded", run_id: nil, head_sha: "new-head", payload: %{outcome: "pass"}}] =
               SymphonyElixir.TicketEvents.query(@issue_id, types: ["verdict.recorded"])
    end
  end
end
