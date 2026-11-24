defmodule SymphonyElixir.BlockedByGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.IssueNormalizer
  alias SymphonyElixir.{Pauses, TicketState}

  @states ["Todo", "In Progress", "In Review", "Auto Review", "Merging", "Rework"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @states,
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
    )

    :ok = RunStore.clear()
    :ok
  end

  describe "a Todo ticket with a stored dependency" do
    for on_phase <- ["Merging", "In Review", "Auto Review", "Rework", "In Progress", "Backlog", "Canceled"] do
      test "is held while the ticket it depends on is #{on_phase}, with no pause" do
        issue = todo_depending_on("MT-2", unquote(on_phase))

        # The gate decides from the records alone: the poll's sweep sets no reason.
        assert sweep(issue) == 0
        assert Pauses.get(ticket(issue)) == {:ok, nil}
        refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    for on_phase <- ["Done", " done "] do
      test "is dispatched once the ticket it depends on is #{inspect(on_phase)}" do
        issue = todo_depending_on("MT-2", unquote(on_phase))

        assert sweep(issue) == 0
        assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    test "is held by a dependency on a ticket Symphony holds no record of" do
      issue = todo_depending_on("MT-2", nil)

      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end

    test "in a later active phase, its next dispatch is held by its dependency too" do
      issue = %{todo_depending_on("MT-2", "Merging") | state: "In Progress"}

      assert sweep(issue) == 0
      refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end
  end

  describe "a ticket whose Linear issue has a blocker link" do
    test "is not affected by it: no reason, no wait in the snapshot, and it dispatches" do
      :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), "id-MT-2", %{issue_identifier: "MT-2", phase: "In Progress"}))

      node = %{
        "id" => "issue",
        "identifier" => "MT-1",
        "title" => "Linked",
        "state" => %{"name" => "Todo"},
        "inverseRelations" => %{"nodes" => [%{"type" => "blocks", "issue" => %{"id" => "id-MT-2", "identifier" => "MT-2", "state" => %{"name" => "In Progress"}}}]}
      }

      issue = IssueNormalizer.from_graphql_node(node, nil)
      refute Map.has_key?(issue, :blocked_by)

      assert sweep(issue) == 0
      assert Pauses.get(ticket(issue)) == {:ok, nil}
      assert Orchestrator.put_blocked_for_test(orchestrator_state(), [issue]).blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end
  end

  describe "a final verification waiting on its gaps" do
    test "stays in Todo, shows in the snapshot with its open dependencies, and is dispatched once every gap is Done" do
      record!("id-MT-323", "MT-323", "In Progress")
      record!("id-MT-314", "MT-314", "Done")
      depend!("verify", "MT-272", ["id-MT-314", "id-MT-323"])

      verification = %Issue{id: "verify", identifier: "MT-272", title: "Final verification: Update from the menu bar", state: "Todo"}
      other = %Issue{id: "other", identifier: "MT-1", title: "Other", state: "Todo"}

      assert sweep(verification) == 0
      state = Orchestrator.put_blocked_for_test(orchestrator_state(), [other, verification])

      refute Orchestrator.should_dispatch_issue_for_test(verification, state)

      assert state.blocked == [
               %{
                 issue_id: "verify",
                 identifier: "MT-272",
                 title: "Final verification: Update from the menu bar",
                 state: "Todo",
                 blockers: [%{identifier: "MT-323", state: "In Progress"}]
               }
             ]

      assert snapshot_of(state).blocked == state.blocked

      # A dependency on a ticket Symphony holds no record of is named by nothing it knows.
      depend!("unknown", "MT-273", ["ghost"])
      unknown = %Issue{verification | id: "unknown", identifier: "MT-273"}

      assert [%{blockers: [%{identifier: nil, state: nil}]}] =
               Orchestrator.put_blocked_for_test(state, [unknown]).blocked

      record!("id-MT-323", "MT-323", "Done")
      state = Orchestrator.put_blocked_for_test(state, [other, verification])

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(verification, state)
    end
  end

  describe "a Todo ticket depending on a fix to Symphony itself" do
    @old_build "d3d301b0123456789abcdef0123456789abcdef0"
    @new_build "53b1e370123456789abcdef0123456789abcdef0"
    @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
    @fix_pr "https://github.com/acme/symphony/pull/132"

    setup do
      previous = Application.fetch_env(:symphony_elixir, :build)
      :ok = RunStore.clear()

      on_exit(fn ->
        :ok = RunStore.clear()

        case previous do
          {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
          :error -> Application.delete_env(:symphony_elixir, :build)
        end
      end)
    end

    test "stays held after the fix merges, until the running app includes its merge commit, with no read of Linear" do
      run_build(@old_build)
      merged_fix("TP-419", @fix_pr)
      depend!("verify", "TP-332", ["id-TP-419"])
      issue = %Issue{id: "verify", identifier: "TP-332", title: "Final verification: Pause", state: "Todo"}

      state = poll(orchestrator_state(), [issue], :fix)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      assert state.blocked == [
               %{
                 issue_id: "verify",
                 identifier: "TP-332",
                 title: "Final verification: Pause",
                 state: "Todo",
                 kind: :app_update,
                 reason: "Waiting for a Symphony update that includes TP-419's fix",
                 build_line: nil,
                 blockers: [%{identifier: "TP-419", state: "merged in 9f54098"}]
               }
             ]

      assert snapshot_of(state).blocked == state.blocked
      assert skip_reason(issue, state) == "Waiting for a Symphony update that includes TP-419's fix"

      # The wait is on the ticket's pause, set by the update hold.
      assert {:ok, %{reasons: [%{kind: :build, waits_on: %{pull_request: 132}, set_by: %{name: "App update hold"}}]}} =
               Pauses.get({:ticket, "default", "verify"})

      # The same build on the next poll: nothing new to look up, still held.
      assert poll(state, [issue], :no_lookup).blocked == state.blocked

      # While the fix's release build runs on GitHub, the ticket and the snapshot say so (TP-1307).
      record = %{sha: @merge_sha, state: :running, number: 750, reruns: 1}
      :ok = RunStore.put_github_updates({:release_build, @merge_sha}, record)
      building = poll(state, [issue], :no_lookup)
      version = SymphonyElixir.BuildInfo.release_version(750)
      line = "Waiting for the v#{version} build with TP-419's fix: building on GitHub; cancelled for lack of a machine, rerun 1 of 2"
      assert skip_reason(issue, building) == line
      assert [%{reason: ^line, build_line: "Waiting for the v" <> _rest}] = building.blocked
      :ok = RunStore.put_github_updates({:release_build, @merge_sha}, %{record | state: :built})

      # Symphony restarts on the same build: nothing in memory, and the merge commit's lookup fails.
      # The pause still holds the ticket, and the gate says what it waits for.
      restarted = poll(orchestrator_state(), [issue], :lookup_down)
      refute Orchestrator.should_dispatch_issue_for_test(issue, restarted)
      assert skip_reason(issue, restarted) == "Waiting for a Symphony update that includes TP-419's fix"

      # Until the lookup answers, the snapshot names the fix by the pull request the reason waits on.
      assert [%{kind: :app_update, reason: "Waiting for a Symphony update that includes TP-419's fix", blockers: [%{identifier: nil, state: "merged in PR #132"}]}] =
               restarted.blocked

      # The app updates to a build that includes the merge commit: the next poll clears the reason.
      run_build(@new_build)
      state = poll(restarted, [issue], :fix)

      assert state.blocked == []
      assert Pauses.get({:ticket, "default", "verify"}) == {:ok, nil}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "the skip-update-hold label clears the wait on the next poll" do
      run_build(@old_build)
      merged_fix("TP-419", @fix_pr)
      depend!("skipping", "TP-333", ["id-TP-419"])
      issue = %Issue{id: "skipping", identifier: "TP-333", title: "Skipping", state: "Todo"}

      state = poll(orchestrator_state(), [issue], :fix)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      labelled = %Issue{issue | labels: [SymphonyElixir.UpdateHold.skip_label()]}
      state = poll(state, [labelled], :no_lookup)

      assert state.blocked == []
      assert Pauses.get({:ticket, "default", "skipping"}) == {:ok, nil}
      assert Orchestrator.should_dispatch_issue_for_test(labelled, state)
    end

    test "a dependency merged in another repository releases its dependent at Done, as before" do
      run_build(@old_build)
      merged_fix("APP-1", "https://github.com/acme/web-app/pull/5")
      depend!("issue", "MT-1", ["id-APP-1"])
      issue = %Issue{id: "issue", identifier: "MT-1", title: "Waiting", state: "Todo"}

      state = poll(orchestrator_state(), [issue], :fix)

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "a build from a checkout holds nothing" do
      Application.put_env(:symphony_elixir, :build, sha: nil, repo: nil, number: nil)
      merged_fix("TP-419", @fix_pr)
      depend!("issue", "MT-1", ["id-TP-419"])
      issue = %Issue{id: "issue", identifier: "MT-1", title: "Waiting", state: "Todo"}

      state = poll(orchestrator_state(), [issue], :no_lookup)

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    defp run_build(sha), do: Application.put_env(:symphony_elixir, :build, sha: sha, repo: "https://github.com/acme/symphony", number: "168")

    # What a poll does: the poll task looks the dependencies' merges up, then the poll result applies
    # the holds. Linear is never read for them: a read of an issue fails the test.
    defp poll(state, issues, lookup) do
      build = SymphonyElixir.BuildInfo.current()
      no_linear = [fetch_issues: fn _ids -> flunk("Linear is not read") end, fetch_issue_by_identifier: fn _id -> flunk("Linear is not read") end]

      lookups =
        case lookup do
          :no_lookup ->
            [merge_commit_sha: fn _url -> flunk("cached") end, commit_included?: fn _url, _sha, _build -> flunk("cached") end]

          :lookup_down ->
            [merge_commit_sha: fn _url -> {:error, :github_down} end]

          :fix ->
            [
              merge_commit_sha: fn
                @fix_pr -> {:ok, @merge_sha}
                _other -> {:ok, nil}
              end,
              commit_included?: fn @fix_pr, @merge_sha, build_sha -> {:ok, build_sha == @new_build} end
            ]
        end

      # The orchestrator resolves a repo's tickets under that repo's key.
      lookups = [repo_key: "default"] ++ no_linear ++ lookups
      cache = SymphonyElixir.UpdateHold.resolve(issues, build, state.update_hold_cache, terminal_states(), lookups)
      Orchestrator.put_blocked_for_test(%{state | update_hold_cache: cache}, issues)
    end

    defp skip_reason(issue, state) do
      state = Orchestrator.dispatch_chosen_issues_for_test([issue], state)
      state.dispatch_skipped[issue.id].reason
    end
  end

  # A done ticket whose PR Symphony's record shows merged.
  defp merged_fix(identifier, pr_url) do
    id = "id-" <> identifier
    record!(id, identifier, "Done")
    :ok = SymphonyElixir.TicketPullRequest.record_created("default", id, pr_url, nil)
    :ok = SymphonyElixir.TicketPullRequest.mark_finished("default", pr_url, "merged")
  end

  # A Todo ticket `MT-1` depending (`:done`) on `identifier`, whose record is in `phase`, or which has
  # no record when `phase` is nil.
  defp todo_depending_on(identifier, phase) do
    if phase, do: record!("id-" <> identifier, identifier, phase)
    depend!("issue", "MT-1", ["id-" <> identifier])
    %Issue{id: "issue", identifier: "MT-1", title: "Waiting", state: "Todo"}
  end

  defp record!(issue_id, identifier, phase) do
    :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), issue_id, %{issue_identifier: identifier, phase: phase}))
  end

  # The Todo ticket `issue_id` with a stored `:done` dependency on each of `on_ids`.
  defp depend!(issue_id, identifier, on_ids) do
    depends_on = for id <- on_ids, do: %{issue_id: id, identifier: nil, kind: :done}
    :ok = RunStore.put_ticket_state(TicketState.new(Config.repo_key!(), issue_id, %{issue_identifier: identifier, phase: "Todo", depends_on: depends_on}))
  end

  defp ticket(%Issue{id: issue_id}), do: {:ticket, Config.repo_key!(), issue_id}

  defp terminal_states, do: Config.settings!().tracker.terminal_states

  # The poll's sweep over `issue`, as the orchestrator runs it: how many reasons changed.
  defp sweep(issue), do: Orchestrator.sweep_dependencies_for_test(Config.repo_key!(), [issue], terminal_states())

  defp snapshot_of(state) do
    {:reply, snapshot, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
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
