defmodule SymphonyElixir.Pauses.DependenciesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, RunStore, TicketPullRequest, TicketState, UpdateHold, Workflow}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Dependencies

  @repo_key "repo-a"
  @issue_id "issue-1"
  @terminal ["Done", "Canceled"]
  @active_states ["Todo", "In Progress", "In Review", "Merging", "Rework"]
  @ticket {:ticket, "repo-a", "issue-1"}
  @fix_line "Waiting for TP-900 to finish: it fixes what stopped this ticket"
  @run %{kind: :run, name: "The run"}

  @build_sha "bbbbbbb0123456789abcdef0123456789abcdef0"
  @next_build_sha "ccccccc0123456789abcdef0123456789abcdef0"
  @merge_sha "aaaaaaa0123456789abcdef0123456789abcdef0"
  @symphony_pr "https://github.com/acme/symphony/pull/12"

  # The tracker the fix tickets and the blockers are read from by identifier.
  defmodule ReadTracker do
    def fetch_issue_by_identifier(identifier), do: Process.get({:read, identifier}, {:error, :not_found})
  end

  # Reads go through the real store, but the stale fix-ticket pointer can't be dropped.
  defmodule UnforgettableStore do
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def clear_ticket_fix_ticket(_repo_key, _issue_id), do: {:error, :boom}
  end

  defmodule UnreadableStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @active_states,
      tracker_terminal_states: @terminal,
      repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test"]]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    # The `Blocked` label is the pause projector's alone.
    Application.put_env(:symphony_elixir, :pause_projector, true)
    on_exit(fn -> Application.put_env(:symphony_elixir, :pause_projector, false) end)
    :ok = RunStore.clear()
    :ok
  end

  describe "a Todo ticket and its blockers" do
    test "is paused until its blocker is terminal, and the Blocked label follows the pause" do
      open = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [open], @terminal) == 1
      assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish"]
      assert [%{set_by: %{kind: :rule, name: "Blocked-by links"}}] = reasons()
      assert labels() == ["Blocked"]
      refute Orchestrator.should_dispatch_issue_for_test(open, orchestrator_state())

      # The next poll with the same blocker open changes nothing.
      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [open], @terminal) == 0

      unblocked = %{open | blocked_by: [blocker("TP-1", "Done")]}

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [unblocked], @terminal) == 1
      refute Pauses.paused?(@ticket)
      assert labels() == []
      assert Orchestrator.should_dispatch_issue_for_test(unblocked, orchestrator_state())
    end

    test "blocked by two others, is paused on both, then on the one left, and runs once both are done" do
      both = issue(%{blocked_by: [blocker("TP-1", "In Progress"), blocker("TP-2", "Todo")]})

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [both], @terminal) == 2
      assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish", "Waiting for TP-2 to finish"]
      refute Orchestrator.should_dispatch_issue_for_test(both, orchestrator_state())

      one_left = %{both | blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Todo")]}
      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [one_left], @terminal) == 1
      assert Pauses.why(@ticket) == ["Waiting for TP-2 to finish"]
      refute Orchestrator.should_dispatch_issue_for_test(one_left, orchestrator_state())

      done = %{both | blocked_by: [blocker("TP-1", "Done"), blocker("TP-2", "Done")]}
      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [done], @terminal) == 1
      refute Pauses.paused?(@ticket)
      assert Orchestrator.should_dispatch_issue_for_test(done, orchestrator_state())
    end

    test "a blocker already done, or one with no identifier, pauses nothing" do
      done = issue(%{blocked_by: [blocker("TP-1", "Done"), %{id: "blocker-x", identifier: nil, state: "Todo"}]})

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [done], @terminal) == 0
      refute Pauses.paused?(@ticket)
    end

    test "a pause on anything else holds dispatch on its own, and the sweep leaves it" do
      :ok = Pauses.stop(@ticket, ~U[2026-10-31 09:00:00Z])
      {:ok, _pause} = Pauses.set(@ticket, Map.put(Pauses.ticket_reason(:landing, "TP-5"), :releasable, true))
      issue = issue()

      refute Issue.blocked?(issue, @terminal)
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue], @terminal) == 0
      assert length(reasons()) == 2
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end

    test "a blocker removed from the ticket while open lifts its reason" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-1"), set_by: Dependencies.setter(:dependency))

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue()], @terminal) == 1
      refute Pauses.paused?(@ticket)
    end

    test "a repo that can't be resolved is not swept" do
      open = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      assert Orchestrator.sweep_dependencies_for_test("unknown-repo", [open], @terminal) == 0
    end
  end

  describe "sweep/3" do
    test "reads each polled ticket under the repo it was polled for, and counts the reasons it set and cleared" do
      open = issue(%{repo_key: nil, blocked_by: [blocker("TP-1", "In Progress")]})
      other = %{open | id: "issue-2", blocked_by: []}

      assert {1, _cache} = Dependencies.sweep([open, other, :not_an_issue], @terminal, repo_key: @repo_key)
      assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish"]

      assert {1, _cache} = Dependencies.sweep([%{open | blocked_by: [blocker("TP-1", "Done")]}, other], @terminal, repo_key: @repo_key)
      refute Pauses.paused?(@ticket)
    end

    test "a record the store can't read is skipped with a warning" do
      open = issue(%{blocked_by: [blocker("TP-1", "In Progress")]})

      log =
        capture_log(fn ->
          assert {0, _cache} = Dependencies.sweep([open], @terminal, repo_key: @repo_key, store: UnreadableStore)
        end)

      assert log =~ "Failed to read the record of issue_id=#{@issue_id}"
      refute Pauses.paused?(@ticket)
    end

    test "names who sets each source's reasons" do
      assert Dependencies.setter(:dependency) == %{kind: :rule, name: "Blocked-by links"}
      assert Dependencies.setter(:fix_ticket) == %{kind: :rule, name: "Self-heal"}
      assert Dependencies.setter(:landing) == %{kind: :rule, name: "Competing pull requests"}
    end
  end

  describe "a run's block report outside Todo" do
    setup do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-997"), set_by: @run)
      :ok
    end

    test "stays in the ticket's phase while its blocker is open" do
      for state <- ["In Progress", "Rework"] do
        assert {0, _cache} = sweep(held(state, "Merging"), build(), UpdateHold.empty_cache())
        assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]
      end

      refute_received :merge_commit_sha
    end

    test "a ticket out of Todo gains no reason for a blocker the run did not report" do
      assert {0, _cache} = sweep(issue(%{state: "In Progress", blocked_by: [blocker("TP-997", "Todo"), blocker("TP-998", "Todo")]}), build(), UpdateHold.empty_cache())
      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]
    end

    test "lifts once its blocker is terminal, with no person's Unblock" do
      merged_blocker("https://github.com/acme/web-app/pull/5")

      assert {1, _cache} = sweep(held("In Progress", "Done"), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      refute Pauses.paused?(@ticket)
    end

    test "waits for the running app to include a blocker that fixed Symphony itself, then lifts" do
      merged_blocker()

      assert {0, cache} = sweep(held("Rework", "Done"), build(), UpdateHold.empty_cache())
      assert_received :merge_commit_sha
      assert_received {:commit_included?, @build_sha}
      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]

      # The next poll on the same build changes nothing and reads nothing again, not even the
      # blocker: an unreadable blocker would have lifted the reason.
      Process.delete({:read, "TP-997"})
      assert {0, ^cache} = sweep(held("Rework", "Done"), build(), cache)
      refute_received :merge_commit_sha
      refute_received {:commit_included?, _sha}

      # The app updates to a build that includes the merge: the reason lifts, the ticket stays in Rework.
      assert {1, _cache} = sweep(held("Rework", "Done"), build(@next_build_sha), cache)
      assert_received {:commit_included?, @next_build_sha}
      refute Pauses.paused?(@ticket)
    end

    test "lifts at once when the build has no sha, the blocker can't be read, or a skip label opts out" do
      for {issue, build, readable?} <- [
            {held("In Progress", "Done"), build(nil), true},
            {held("In Progress", "Done"), build(), false},
            {held("In Progress", "Done", [UpdateHold.skip_label()]), build(), true}
          ] do
        {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-997"), set_by: @run)
        if readable?, do: merged_blocker(), else: Process.delete({:read, "TP-997"})

        assert {1, _cache} = sweep(issue, build, UpdateHold.empty_cache())
        refute Pauses.paused?(@ticket)
      end

      refute_received :merge_commit_sha
    end

    test "a Todo ticket's reason lifts at once: its dispatch gate waits for the app update" do
      merged_blocker()

      assert {1, _cache} = sweep(held("Todo", "Done"), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      refute Pauses.paused?(@ticket)
    end
  end

  describe "a fix ticket self-heal filed" do
    setup do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:fix_ticket, "TP-900"), set_by: Dependencies.setter(:fix_ticket))

      :ok =
        RunStore.record_ticket_self_heal(@repo_key, @issue_id, %{component: "dev_server", scope: @repo_key, signature: "s", fix_ticket: "TP-900", attempts: 2})

      :ok
    end

    test "lifts its reason once the fix ticket is terminal, keeping the failure signature" do
      Process.put({:read, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "Done"}})

      assert {1, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      refute Pauses.paused?(@ticket)
      assert labels() == []

      # Only the stale fix-ticket pointer goes: the component, the signature and the retry count
      # stay, so a break that comes back after the repair is compared against this failure.
      assert %{component: "dev_server", signature: "s", fix_ticket: nil, attempts: 2} =
               RunStore.get_ticket_state(@repo_key, @issue_id) |> TicketState.self_heal()
    end

    test "stays while the fix ticket is open, or can't be read" do
      Process.put({:read, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "In Progress"}})
      assert {0, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      assert Pauses.why(@ticket) == [@fix_line]

      Process.delete({:read, "TP-900"})
      assert {0, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      assert Pauses.why(@ticket) == [@fix_line]
    end

    test "a stale fix-ticket pointer that can't be dropped is logged, and the reason still lifts" do
      Process.put({:read, "TP-900"}, {:ok, %Issue{id: "fix-id", identifier: "TP-900", state: "Done"}})

      log =
        capture_log(fn ->
          assert {1, _cache} = Dependencies.sweep([issue(%{state: "QA"})], @terminal, repo_key: @repo_key, store: UnforgettableStore, tracker: ReadTracker, build: build())
        end)

      assert log =~ "Failed to drop the stale fix ticket"
      refute Pauses.paused?(@ticket)
    end

    test "a fix to Symphony itself waits until the running build includes its merge commit" do
      merged_fix()

      assert {0, cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      assert_received :merge_commit_sha
      assert_received {:commit_included?, @build_sha}
      assert Pauses.why(@ticket) == [@fix_line]

      assert {1, _cache} = sweep(issue(%{state: "QA"}), build(@next_build_sha), cache)
      refute Pauses.paused?(@ticket)
    end

    test "a skip label, or a fix merged in another repository, lifts it as soon as it is terminal" do
      merged_fix()
      assert {1, _cache} = sweep(issue(%{state: "QA", labels: [UpdateHold.skip_label()]}), build(), UpdateHold.empty_cache())
      refute Pauses.paused?(@ticket)

      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:fix_ticket, "TP-900"), set_by: Dependencies.setter(:fix_ticket))
      merged_fix("https://github.com/acme/web-app/pull/5")
      assert {1, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      refute Pauses.paused?(@ticket)
    end
  end

  test "a landing reason is the PR watcher's, in any phase" do
    {:ok, _pause} = Pauses.set(@ticket, Map.put(Pauses.ticket_reason(:landing, "TP-5"), :releasable, true))

    assert {0, _cache} = sweep(issue(%{state: "Merging"}), build(), UpdateHold.empty_cache())
    assert {0, _cache} = sweep(issue(), build(), UpdateHold.empty_cache())
    assert Pauses.why(@ticket) == ["Waiting for TP-5 to land: it changes the same files"]
  end

  defp sweep(issue, build, cache) do
    Dependencies.sweep([issue], @terminal, [repo_key: @repo_key, tracker: ReadTracker, build: build, update_hold_cache: cache] ++ lookups())
  end

  defp build(sha \\ @build_sha), do: %{version: "0.0.1.200", sha: sha, repo: "https://github.com/acme/symphony"}

  # The GitHub lookups `UpdateHold` makes: each call is reported, and the running build includes
  # the merge commit only from `@next_build_sha` on.
  defp lookups do
    test_pid = self()

    [
      merge_commit_sha: fn @symphony_pr ->
        send(test_pid, :merge_commit_sha)
        {:ok, @merge_sha}
      end,
      commit_included?: fn @symphony_pr, @merge_sha, build_sha ->
        send(test_pid, {:commit_included?, build_sha})
        {:ok, build_sha == @next_build_sha}
      end
    ]
  end

  defp merged_blocker(pr_url \\ @symphony_pr), do: merged("blocker-TP-997", "TP-997", pr_url)
  defp merged_fix(pr_url \\ @symphony_pr), do: merged("fix-id", "TP-900", pr_url)

  defp merged(id, identifier, pr_url) do
    ticket = %Issue{id: id, identifier: identifier, state: "Done", repo_key: @repo_key}
    :ok = TicketPullRequest.record_created(@repo_key, id, pr_url, nil)
    :ok = TicketPullRequest.mark_finished(@repo_key, pr_url, "merged")
    Process.put({:read, identifier}, {:ok, ticket})
  end

  defp held(state, blocker_state, labels \\ []) do
    issue(%{state: state, labels: labels, blocked_by: [blocker("TP-997", blocker_state)]})
  end

  defp issue(attrs \\ %{}) do
    struct!(%Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "Todo", repo_key: @repo_key, labels: []}, attrs)
  end

  defp blocker(identifier, state), do: %{id: "blocker-" <> identifier, identifier: identifier, state: state}

  defp reasons do
    case Pauses.get(@ticket) do
      {:ok, %{reasons: reasons}} -> reasons
      {:ok, nil} -> []
    end
  end

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp orchestrator_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end
end
