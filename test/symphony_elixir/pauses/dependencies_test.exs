defmodule SymphonyElixir.Pauses.DependenciesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{Pauses, RunStore, TicketPullRequest, TicketState, UpdateHold, Workflow}
  alias SymphonyElixir.Pauses.Dependencies

  @repo_key "repo-a"
  @issue_id "issue-1"
  @terminal ["Done", "Canceled"]
  @active_states ["Todo", "In Progress", "In Review", "Merging", "Rework"]
  @ticket {:ticket, "repo-a", "issue-1"}
  @fix_line "Waiting for TP-900 to finish: it fixes what stopped this ticket"
  @run %{kind: :run, name: "The run"}
  @retired %{kind: :rule, name: "Blocked-by links"}

  @build_sha "bbbbbbb0123456789abcdef0123456789abcdef0"
  @next_build_sha "ccccccc0123456789abcdef0123456789abcdef0"
  @merge_sha "aaaaaaa0123456789abcdef0123456789abcdef0"
  @symphony_pr "https://github.com/acme/symphony/pull/12"

  # The tracker the fix tickets and the tickets depended on are read from by identifier.
  defmodule ReadTracker do
    def fetch_issue_by_identifier(identifier), do: Process.get({:read, identifier}, {:error, :not_found})
  end

  # Reads go through the real store, but the stale fix-ticket pointer can't be dropped.
  defmodule UnforgettableStore do
    def get_ticket_state(issue_id), do: RunStore.get_ticket_state(issue_id)
    def clear_ticket_fix_ticket(_repo_key, _issue_id), do: {:error, :boom}
  end

  defmodule UnreadableStore do
    def get_ticket_state(_issue_id), do: {:error, :boom}
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

  describe "the retired hold on Linear's blocker links" do
    test "nothing sets a reason for a blocker link: a sweep over a record with old observed blockers sets none" do
      # A record an older build stored with the blockers it observed from Linear.
      :ok = RunStore.put_ticket_state(Map.put(TicketState.new(@repo_key, @issue_id, %{phase: "Todo"}), :blockers, [blocker("TP-1", "In Progress")]))

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue()], @terminal) == 0
      refute Pauses.paused?(@ticket)
      assert Orchestrator.should_dispatch_issue_for_test(issue(), orchestrator_state())

      # The rule has no setter any more.
      assert_raise KeyError, fn -> Dependencies.setter(:dependency) end
    end

    for phase <- ["Todo", "In Progress", "Rework", "Merging"] do
      test "in #{phase}, a reason the old hold set is cleared by the next sweep, and the ticket is not held by it" do
        {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-1"), set_by: @retired)
        old = RunStore.get_ticket_state(@issue_id) |> Map.put(:blockers, [blocker("TP-1", "In Progress")])
        :ok = RunStore.put_ticket_state(old)
        assert Pauses.why(@ticket) == ["Waiting for TP-1 to finish"]
        issue = issue(%{state: unquote(phase)})

        assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue], @terminal) == 1
        refute Pauses.paused?(@ticket)
        assert labels() == []
        if unquote(phase) == "Todo", do: assert(Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state()))

        assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue], @terminal) == 0
      end
    end

    test "a pause on anything else holds dispatch on its own, and the sweep leaves it" do
      :ok = Pauses.stop(@ticket, ~U[2026-10-31 09:00:00Z])
      {:ok, _pause} = Pauses.set(@ticket, Map.put(Pauses.ticket_reason(:landing, "TP-5"), :releasable, true))
      issue = issue()

      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())

      assert Orchestrator.sweep_dependencies_for_test(@repo_key, [issue], @terminal) == 0
      assert length(reasons()) == 2
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end
  end

  describe "sweep/3" do
    test "skips what is not an issue, an issue with no id and a ticket with no record, and counts the reasons it cleared" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-1"), set_by: @retired)
      unrecorded = issue(%{id: "issue-2"})

      assert {1, _cache} = Dependencies.sweep([issue(%{repo_key: nil}), unrecorded, issue(%{id: nil}), :not_an_issue], @terminal, repo_key: @repo_key)
      refute Pauses.paused?(@ticket)
      assert RunStore.get_ticket_state("issue-2") == nil
    end

    test "a record the store can't read is skipped with a warning" do
      log =
        capture_log(fn ->
          assert {0, _cache} = Dependencies.sweep([issue()], @terminal, repo_key: @repo_key, store: UnreadableStore)
        end)

      assert log =~ "Failed to read the record of issue_id=#{@issue_id}"
      refute Pauses.paused?(@ticket)
    end

    test "names who sets each source's reasons" do
      assert Dependencies.setter(:fix_ticket) == %{kind: :rule, name: "Self-heal"}
      assert Dependencies.setter(:landing) == %{kind: :rule, name: "Competing pull requests"}
    end
  end

  describe "a run's block report on its stored dependencies" do
    setup do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-997"), set_by: @run)
      depends_on("TP-997", "In Progress")
      :ok
    end

    test "stays in the ticket's phase while the dependency is unmet" do
      for state <- ["Todo", "In Progress", "Rework"] do
        assert {0, _cache} = sweep(issue(%{state: state}), build(), UpdateHold.empty_cache())
        assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]
      end

      refute_received :merge_commit_sha
    end

    test "lifts once the dependency is met, with no person's Unblock" do
      merged_blocker("https://github.com/acme/web-app/pull/5")
      depends_on("TP-997", "Done")

      assert {1, _cache} = sweep(issue(%{state: "In Progress"}), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      refute Pauses.paused?(@ticket)
    end

    test "lifts once the dependency is removed" do
      :ok = RunStore.remove_dependency(@issue_id, "blocker-TP-997")

      assert {1, _cache} = sweep(issue(%{state: "Rework"}), build(), UpdateHold.empty_cache())
      refute Pauses.paused?(@ticket)
    end

    test "waits for the running app to include a dependency that fixed Symphony itself, then lifts" do
      merged_blocker()
      depends_on("TP-997", "Done")

      assert {0, cache} = sweep(issue(%{state: "Rework"}), build(), UpdateHold.empty_cache())
      assert_received :merge_commit_sha
      assert_received {:commit_included?, @build_sha}
      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish"]

      # The next poll on the same build changes nothing and looks nothing up again.
      assert {0, ^cache} = sweep(issue(%{state: "Rework"}), build(), cache)
      refute_received :merge_commit_sha
      refute_received {:commit_included?, _sha}

      # The app updates to a build that includes the merge: the reason lifts, the ticket stays in Rework.
      assert {1, _cache} = sweep(issue(%{state: "Rework"}), build(@next_build_sha), cache)
      assert_received {:commit_included?, @next_build_sha}
      refute Pauses.paused?(@ticket)
    end

    test "lifts at once when the build has no sha, the dependency can't be read, or a skip label opts out" do
      depends_on("TP-997", "Done")

      for {issue, build, readable?} <- [
            {issue(%{state: "In Progress"}), build(nil), true},
            {issue(%{state: "In Progress"}), build(), false},
            {issue(%{state: "In Progress", labels: [UpdateHold.skip_label()]}), build(), true}
          ] do
        {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-997"), set_by: @run)
        if readable?, do: merged_blocker(), else: Process.delete({:read, "TP-997"})

        assert {1, _cache} = sweep(issue, build, UpdateHold.empty_cache())
        refute Pauses.paused?(@ticket)
      end

      refute_received :merge_commit_sha
    end

    test "a Todo ticket's reason lifts at once once met: its dispatch gate waits for the app update" do
      merged_blocker()
      depends_on("TP-997", "Done")

      assert {1, _cache} = sweep(issue(), build(), UpdateHold.empty_cache())
      refute_received :merge_commit_sha
      refute Pauses.paused?(@ticket)
    end

    test "a dependency is named by its entry, else by its ticket's record; one named by neither holds no reason" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-998"), set_by: @run)
      by_record = {%{issue_id: "b-998", identifier: nil, kind: :done}, %{issue_identifier: "TP-998"}}
      unnamed = {%{issue_id: "b-999", identifier: nil, kind: :done}, nil}
      by_entry = {%{issue_id: "b-997", identifier: "TP-997", kind: :done}, nil}

      open = fn @issue_id -> [by_entry, by_record, unnamed] end
      assert {0, _cache} = sweep(issue(), build(), UpdateHold.empty_cache(), open_dependencies: open)
      assert Pauses.why(@ticket) == ["Waiting for TP-997 to finish", "Waiting for TP-998 to finish"]

      open = fn @issue_id -> [unnamed] end
      assert {2, _cache} = sweep(issue(), build(), UpdateHold.empty_cache(), open_dependencies: open)
      refute Pauses.paused?(@ticket)
    end
  end

  describe "a ticket the Conductor filed as blocking" do
    test "holds the ticket through the self-heal hold, which lifts once the filed ticket is Done, with no answer from anyone" do
      assert :ok = SymphonyElixir.SelfHeal.hold(@repo_key, issue(%{state: "QA"}), "TP-900")
      assert Pauses.why(@ticket) == [@fix_line]

      Process.put({:read, "TP-900"}, {:ok, %Issue{id: "filed-id", identifier: "TP-900", state: "In Progress"}})
      assert {0, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      assert Pauses.paused?(@ticket)

      Process.put({:read, "TP-900"}, {:ok, %Issue{id: "filed-id", identifier: "TP-900", state: "Done"}})
      assert {1, _cache} = sweep(issue(%{state: "QA"}), build(), UpdateHold.empty_cache())
      refute Pauses.paused?(@ticket)
    end
  end

  describe "a fix ticket self-heal filed" do
    setup do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:fix_ticket, "TP-900"), set_by: Dependencies.setter(:fix_ticket))

      :ok =
        RunStore.record_ticket_self_heal(@repo_key, @issue_id, %{
          component: "dev_server",
          scope: @repo_key,
          signature: "s",
          fix_ticket: "TP-900",
          attempts: 2
        })

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
               RunStore.get_ticket_state(@issue_id) |> TicketState.self_heal()
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
      skipping = issue(%{state: "QA", labels: [UpdateHold.skip_label()]})
      assert {1, _cache} = sweep(skipping, build(), UpdateHold.empty_cache())
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

  defp sweep(issue, build, cache, opts \\ []) do
    Dependencies.sweep([issue], @terminal, [repo_key: @repo_key, tracker: ReadTracker, build: build, update_hold_cache: cache] ++ opts ++ lookups())
  end

  # The ticket depends (`:done`) on `identifier`, whose record is in `phase`.
  defp depends_on(identifier, phase) do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "blocker-" <> identifier, %{issue_identifier: identifier, phase: phase}))

    case RunStore.dependencies(@issue_id) do
      [_ | _] -> :ok
      _none -> :ok = RunStore.add_dependency(@issue_id, "blocker-" <> identifier, :done)
    end
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
