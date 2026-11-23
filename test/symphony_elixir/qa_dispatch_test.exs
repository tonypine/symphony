defmodule SymphonyElixir.QaDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.RunStore

  @designed_repo "qa-repo"
  @issue_id "issue-qa-dispatch"

  defp repos do
    [
      [key: @designed_repo, workflow: Workflow.workflow_file_path(), team: "Test", labels: ["qa"]]
    ]
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), repos: repos())

    RunStore.delete_ticket_state(@issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@issue_id) end)

    :ok
  end

  defp state, do: %Orchestrator.State{}

  defp retry_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(repo_key, issue_state) do
    %Issue{id: @issue_id, identifier: "TP-816", title: "QA", state: issue_state, repo_key: repo_key}
  end

  # The head's CI as the PR and CI watcher leaves it: the CI attribute, and the decision the dispatch
  # gate reads, to run on a green head (R27) and wait otherwise.
  defp record_ci!(repo_key, head, status) do
    assert {:ok, :changed} = RunStore.record_ci_state(repo_key, @issue_id, head, status, DateTime.utc_now())
    decision = if status == "green", do: :dispatch, else: %{rule: "R24", kind: :wait, reason: "Checks are running"}
    SymphonyElixir.PrWatchSupport.put_watch!(repo_key, @issue_id, head_sha: head, decision: decision)
  end

  defp head_signals(_repo_key) do
    case RunStore.get_ticket_state(@issue_id) do
      %{} = record ->
        record
        |> SymphonyElixir.TicketState.recent_signals(10)
        |> Enum.filter(&(&1.name == "qa_head_not_green"))

      _none ->
        []
    end
  end

  describe "the QA dispatch gate" do
    test "a designed QA ticket dispatches on a green head" do
      record_ci!(@designed_repo, "abc123", "green")

      assert Orchestrator.should_dispatch_issue_for_test(issue(@designed_repo, "QA"), state())
    end

    test "a designed QA ticket is parked while the head is not green" do
      for status <- ["red", "running", "unknown"] do
        RunStore.delete_ticket_state(@issue_id)
        record_ci!(@designed_repo, "head-#{status}", status)
        qa_ticket = issue(@designed_repo, "QA")

        refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())

        next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state())
        refute Map.has_key?(next.running, @issue_id)
      end
    end

    test "a designed QA ticket with no recorded CI state is parked" do
      qa_ticket = issue(@designed_repo, "QA")

      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)
    end

    test "the no-dispatch event is recorded once per head" do
      record_ci!(@designed_repo, "abc123", "red")
      qa_ticket = issue(@designed_repo, "QA")

      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)

      assert [%{details: %{head: "abc123", status: "red"}}] = head_signals(@designed_repo)

      # A new head is a new event.
      record_ci!(@designed_repo, "def456", "red")
      refute Map.has_key?(Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()).running, @issue_id)

      heads = head_signals(@designed_repo) |> Enum.map(& &1.details.head)
      assert Enum.sort(heads) == ["abc123", "def456"]
    end

    test "a Code Review ticket is not held by the QA gate" do
      # The two gates are per-state: a Code Review ticket with no CI state is parked by its own gate
      # (tested in `CodeReviewDispatchTest`) and never records a QA no-dispatch signal.
      issue = issue(@designed_repo, "Code Review")

      refute Orchestrator.should_dispatch_issue_for_test(issue, state())
      assert head_signals(@designed_repo) == []
    end

    test "the continuation of an approve on a red head leaves the ticket in QA with no run" do
      # The reviewer approved and moved the ticket to QA; its run ended and the continuation retry
      # reads the ticket again, now in QA. The head is red, so QA must not start on it: the PR
      # watcher routes the red head to CI Fix.
      record_ci!(@designed_repo, "abc123", "red")
      qa_ticket = issue(@designed_repo, "QA")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [qa_ticket])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      retrying = %{retry_state() | claimed: MapSet.new([@issue_id])}
      metadata = %{identifier: "TP-816", continuation: true, repo_key: @designed_repo}

      log =
        capture_log(fn ->
          fetcher = fn _ids -> {:ok, [qa_ticket]} end
          assert {:noreply, next} = Orchestrator.handle_retry_issue_for_test(retrying, @issue_id, 1, metadata, fetcher)
          send(self(), {:state, next})
        end)

      assert_received {:state, next}
      refute Map.has_key?(next.running, @issue_id)
      assert next.claimed == MapSet.new()
      assert log =~ "Not dispatching QA for"
      assert [%{details: %{head: "abc123", status: "red"}}] = head_signals(@designed_repo)
    end

    test "a green head the watcher still holds back shows the watcher's reason, never the head's status" do
      # The reviewer's run is just ending: the head is green, and the watcher's last decision is R9.
      assert {:ok, :changed} = RunStore.record_ci_state(@designed_repo, @issue_id, "abc123", "green", DateTime.utc_now())
      working = %{rule: "R9", kind: :wait, reason: "A run is working on the ticket"}
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: working)
      qa_ticket = issue(@designed_repo, "QA")

      log = capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()) end)

      assert log =~ "Not dispatching QA for"
      assert log =~ ": the PR watcher (R9): A run is working on the ticket"
      refute log =~ "its head is"
      assert [%{details: %{head: "abc123", status: "green", reason: "the PR watcher (R9): A run is working on the ticket"}}] = head_signals(@designed_repo)

      # The same reason on the same head is not recorded again; a new reason is.
      capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()) end)
      assert length(head_signals(@designed_repo)) == 1

      checks = %{rule: "R24", kind: :wait, reason: "Checks are running"}
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: checks)
      capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state()) end)
      assert length(head_signals(@designed_repo)) == 2
    end

    test "a ticket the watcher hasn't read shows that, with no signal, as it has no head to record" do
      log = capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([issue(@designed_repo, "QA")], state()) end)

      assert log =~ ": the PR watcher hasn't read its PR yet"
      assert head_signals(@designed_repo) == []
    end

    test "a retry the watcher's stale decision refuses names the check and asks for the next cycle, and the new decision dispatches" do
      working = %{rule: "R9", kind: :wait, reason: "A run is working on the ticket"}
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: working)
      qa_ticket = issue(@designed_repo, "QA")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [qa_ticket])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      retrying = %{retry_state() | claimed: MapSet.new([@issue_id])}
      metadata = %{identifier: "TP-816", continuation: true, repo_key: @designed_repo}

      log =
        capture_log(fn ->
          fetcher = fn _ids -> {:ok, [qa_ticket]} end
          assert {:noreply, next} = Orchestrator.handle_retry_issue_for_test(retrying, @issue_id, 1, metadata, fetcher)
          send(self(), {:state, next})
        end)

      assert_received {:state, next}
      assert next.claimed == MapSet.new()
      assert is_integer(next.next_poll_due_at_ms)
      assert_receive {:tick, _token}
      assert log =~ ~s|refused_by="flow_gated?: the PR watcher (R9): A run is working on the ticket"|

      # The watcher's read turns the decision; the next cycle dispatches QA with nothing else to wait on.
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: :dispatch)
      assert Orchestrator.should_dispatch_issue_for_test(qa_ticket, next)
    end

    test "a refusal outside a retry asks for no further cycle, so a refused cycle never loops" do
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: :dispatch)
      qa_ticket = issue(@designed_repo, "QA")
      refresh = %{ids: MapSet.new([@issue_id]), result: {:ok, [%{qa_ticket | state: "Backlog"}]}}

      log =
        capture_log(fn ->
          state = %{retry_state() | dispatch_refresh: refresh}
          send(self(), {:state, Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], state)})
        end)

      assert log =~ ~s(refused_by="candidate_issue?")
      assert_received {:state, next}
      assert next.next_poll_due_at_ms == nil
      refute_receive {:tick, _token}, 50
    end

    test "a refused dispatch names the check that refused it" do
      refusal = &Orchestrator.dispatch_refusal_for_test/1
      ticket = issue(@designed_repo, "QA")

      assert refusal.(%{ticket | state: "Backlog"}) == "candidate_issue?"
      assert refusal.(%{ticket | assigned_to_worker: false}) == "candidate_issue?"
      assert refusal.(ticket) == "flow_gated?: the PR watcher hasn't read its PR yet"

      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, head_sha: "abc123", decision: :dispatch)
      assert refusal.(ticket) == "unmoved_since?"

      {:ok, _pause} = SymphonyElixir.Pauses.set({:ticket, @designed_repo, @issue_id}, SymphonyElixir.Pauses.ticket_reason(:dependency, "TP-9"))
      assert refusal.(ticket) == "issue_held?"
    end

    test "a run Symphony stops has its PR read at once, once its end is written" do
      {:ok, _owner} = Registry.register(SymphonyElixir.Repo.Registry, {:pr_watch, @designed_repo}, nil)
      agent = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(agent, :kill) end)

      running = %{
        @issue_id => %{
          pid: agent,
          ref: nil,
          identifier: "TP-816",
          repo_key: @designed_repo,
          issue: issue(@designed_repo, "QA"),
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        }
      }

      stopping = %{retry_state() | running: running, claimed: MapSet.new([@issue_id])}
      next = Orchestrator.reconcile_issue_states_for_test([issue(@designed_repo, "Backlog")], stopping)

      refute Map.has_key?(next.running, @issue_id)
      assert_receive {:"$gen_cast", {:read_ticket, @issue_id}}
    end

    test "the continuation into QA on a green head is not held by the gate" do
      record_ci!(@designed_repo, "abc123", "green")
      qa_ticket = issue(@designed_repo, "QA")

      assert Orchestrator.dispatch_revalidated_issue_for_test(qa_ticket, true)
      assert Orchestrator.dispatch_revalidated_issue_for_test(qa_ticket, false)

      record_ci!(@designed_repo, "def456", "red")

      refute Orchestrator.dispatch_revalidated_issue_for_test(qa_ticket, true)
      refute Orchestrator.dispatch_revalidated_issue_for_test(qa_ticket, false)
    end
  end

  describe "the QA build hold" do
    @tree "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    # The QA pre-build for a repository whose `macos_app` playbook builds an app on a QA host, with
    # its boundaries faked: a build tells the test it started and waits for the test to end it. The
    # ticket's workspace holds a repository whose head changes `change` (a Swift file by default, so
    # its QA pass selects the app), and each read of the paths a head changes tells the test.
    # Returns the workspace and the head.
    defp start_builder!(change \\ "macos/App.swift") do
      test = self()
      auto_review = %{worker_host: "qa-vm", playbooks: %{macos_app: %{build: "make app", app: "build/Demo.app"}}}
      write_workflow_file!(Workflow.workflow_file_path(), repos: repos(), auto_review: auto_review)
      :ok = RunStore.clear()
      on_exit(fn -> RunStore.clear() end)

      {workspace, head} = head_workspace!(change)

      build = fn job, [] ->
        send(test, {:building, job, self()})
        receive(do: ({:outcome, outcome} -> outcome))
      end

      tree = @tree
      workspace_of = fn _repo_key, _identifier -> {:ok, workspace} end
      tree_of = fn _workspace, ^head -> {:ok, tree} end

      paths = fn workspace, repo_key, sha ->
        send(test, {:paths_read, sha})
        SymphonyElixir.QaBuild.paths(workspace, repo_key, sha)
      end

      start_supervised!({SymphonyElixir.QaBuild, workspace: workspace_of, tree: tree_of, paths: paths, build: build})

      {workspace, head}
    end

    # The ticket's workspace: a repository whose head adds `change` over `origin/main`.
    defp head_workspace!(change) do
      {:ok, workspace} = SymphonyElixir.Workspace.local_path_for_issue("TP-816", @designed_repo)
      File.rm_rf!(workspace)
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)

      git = fn args ->
        {output, 0} = System.cmd("git", ["-C", workspace, "-c", "user.name=Test", "-c", "user.email=test@example.com" | args], stderr_to_stdout: true)
        String.trim(output)
      end

      git.(["init", "--quiet", "--initial-branch=main"])
      File.write!(Path.join(workspace, "a.txt"), "one\n")
      git.(["add", "--all"])
      git.(["commit", "--quiet", "-m", "one"])
      git.(["update-ref", "refs/remotes/origin/main", "HEAD"])
      File.mkdir_p!(Path.dirname(Path.join(workspace, change)))
      File.write!(Path.join(workspace, change), "change\n")
      git.(["add", "--all"])
      git.(["commit", "--quiet", "-m", change])
      {workspace, git.(["rev-parse", "HEAD"])}
    end

    defp held, do: SymphonyElixir.QaBuildHold.reasons(@designed_repo, @issue_id)

    # The ticket holds a slot: a build is asked for only for a ticket that holds one.
    defp slot_state(state \\ %Orchestrator.State{}) do
      holder = %{identifier: "TP-816", state: "QA", repo_key: @designed_repo, since: DateTime.utc_now()}
      %{state | slot_holders: %{@issue_id => holder}}
    end

    test "a QA ticket on a green head waits for its app's build, and dispatches when the build is ready" do
      {workspace, head} = start_builder!()
      record_ci!(@designed_repo, head, "green")
      qa_ticket = issue(@designed_repo, "QA")
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()
      waiting = "Waiting for the QA build of #{String.slice(head, 0, 7)}"

      # The pass asks for the build and holds the ticket: nothing runs.
      next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state())
      refute Map.has_key?(next.running, @issue_id)
      assert %{reason: ^waiting} = next.dispatch_skipped[@issue_id]
      assert_receive {:building, %{sha: ^head, tree: @tree, workspace: ^workspace}, builder}
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}
      assert [%{waits_on: %{commit: ^head}}] = held()
      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())
      assert Orchestrator.dispatch_refusal_for_test(qa_ticket) == "flow_gated?: " <> waiting

      # A pass while it builds starts no second build.
      next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state())
      refute Map.has_key?(next.running, @issue_id)
      refute_receive {:building, _job, _builder}, 20

      # The build's end releases the hold, and the pause's change is what runs the next cycle.
      send(builder, {:outcome, {:ready, "/qa/store/builds/#{@tree}/Demo.app"}})
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}
      assert held() == []
      assert Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())
    end

    test "a build that could not run keeps QA held, with its reason, until something asks again" do
      {_workspace, head} = start_builder!()
      record_ci!(@designed_repo, head, "green")
      qa_ticket = issue(@designed_repo, "QA")
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state()) end)
      assert_receive {:building, _job, builder}
      # The pass's own hold, while it builds.
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}

      # The builder writes the build's record before it lets go of that hold, so the release's change
      # says the next pass reads the build that could not run.
      capture_log(fn -> send(builder, {:outcome, {:unavailable, "qa_worker_unreachable: ssh: timeout"}}) end)
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}
      assert held() == []

      next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state())
      refute Map.has_key?(next.running, @issue_id)
      assert %{reason: "The QA build could not run: qa_worker_unreachable: ssh: timeout"} = next.dispatch_skipped[@issue_id]
      assert [%{kind: :environment, releasable: true}] = held()
      refute_receive {:building, _job, _builder}, 20
    end

    test "a QA ticket whose head changes no Mac app file is released without a build, and its change is read once" do
      {_workspace, head} = start_builder!("app/Main.kt")
      record_ci!(@designed_repo, head, "green")
      qa_ticket = issue(@designed_repo, "QA")
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      # The builder has not read the head yet: the pass holds the ticket while it reads, off the
      # orchestrator, and it lets go as soon as it finds the pass selects no Mac app.
      capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state()) end)
      assert_receive {:paths_read, ^head}
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}
      assert_receive {:ticket_record, @designed_repo, @issue_id, :changed, [:pause]}
      assert held() == []
      refute_receive {:building, _job, _builder}, 20

      # Later passes read the stored answer: QA dispatches, with no hold, no build and no git.
      assert Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())
      assert SymphonyElixir.QaBuildHold.resolve(@designed_repo, qa_ticket, head) == :dispatch
      assert held() == []
      refute_receive {:paths_read, _sha}, 20
      refute_received {:building, _job, _builder}
    end

    test "the hold counts in QA only, and a ticket already claimed is left alone" do
      {_workspace, head} = start_builder!()
      record_ci!(@designed_repo, head, "green")
      qa_ticket = issue(@designed_repo, "QA")

      claimed = slot_state(%Orchestrator.State{claimed: MapSet.new([@issue_id])})
      Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], claimed)
      assert held() == []
      refute_receive {:building, _job, _builder}, 20

      Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], slot_state())
      assert [_reason] = held()
      assert Orchestrator.dispatch_refusal_for_test(%{qa_ticket | state: "In Progress"}) == "unmoved_since?"

      # The next pass finds it out of QA and drops the hold.
      capture_log(fn -> Orchestrator.dispatch_chosen_issues_for_test([%{qa_ticket | state: "Backlog"}], slot_state()) end)
      assert held() == []
    end

    test "a QA ticket without a slot asks for no build, and takes a free slot when the watcher waits for one" do
      {_workspace, head} = start_builder!()
      record_ci!(@designed_repo, head, "green")
      qa_ticket = issue(@designed_repo, "QA")

      # Its decision to run QA is held back for a slot, as the watcher records it for a ticket without one.
      decision = %{
        rule: "R27",
        kind: :wait,
        reason: "Waits for a slot before R27 acts (a run starts on the ticket): QA",
        args: %{withheld: :dispatch}
      }

      watch = [phase: :qa, head_sha: head, decision: decision]
      SymphonyElixir.PrWatchSupport.put_watch!(@designed_repo, @issue_id, watch)

      # Every slot taken: no build, no slot, no run.
      other = %{identifier: "TP-1", state: "QA", repo_key: @designed_repo, since: DateTime.utc_now()}
      full = %Orchestrator.State{max_concurrent_agents: 1, slot_holders: %{"other" => other}}
      next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], full)
      refute Map.has_key?(next.slot_holders, @issue_id)
      refute Map.has_key?(next.running, @issue_id)
      assert held() == []
      refute_receive {:building, _job, _builder}, 20

      # A free slot: the ticket takes it with no run, and its build waits for the next pass.
      next = Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], %Orchestrator.State{max_concurrent_agents: 1})
      assert %{identifier: "TP-816"} = next.slot_holders[@issue_id]
      refute Map.has_key?(next.running, @issue_id)
      assert %DateTime{} = RunStore.get_ticket_state(@issue_id).slot_held_since
      assert held() == []
      refute_receive {:building, _job, _builder}, 20

      # The pass after, holding it, asks for the build.
      Orchestrator.dispatch_chosen_issues_for_test([qa_ticket], next)
      assert_receive {:building, %{sha: ^head}, _builder}
    end

    test "a QA ticket whose run is missing is dispatched exactly once" do
      record_ci!(@designed_repo, "abc123", "green")
      qa_ticket = issue(@designed_repo, "QA")

      # No run under way (say, after a restart): the poll tick picks the QA run up again.
      assert Orchestrator.should_dispatch_issue_for_test(qa_ticket, state())

      # While the dispatch's claim or run is live, the next tick does not dispatch a second one.
      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, %Orchestrator.State{claimed: MapSet.new([@issue_id])})
      refute Orchestrator.should_dispatch_issue_for_test(qa_ticket, %Orchestrator.State{running: %{@issue_id => %{}}})
    end
  end
end
