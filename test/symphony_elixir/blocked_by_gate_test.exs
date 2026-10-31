defmodule SymphonyElixir.BlockedByGateTest do
  use SymphonyElixir.TestSupport

  @states ["Todo", "In Progress", "In Review", "Auto Review", "Merging", "Rework"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @states,
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
    )

    :ok = RunStore.clear()
    :ok
  end

  describe "a Todo ticket with a blocker" do
    for blocker_state <- ["Merging", "In Review", "Auto Review", "Rework", "In Progress", "Backlog"] do
      test "is held while the blocker is #{blocker_state}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        assert Issue.blocked?(issue, terminal_states())
        # The poll pauses it on its open blocker; the gate reads the pause.
        assert sweep(issue) == 1
        refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    for blocker_state <- ["Done", "Canceled", "Duplicate", " done "] do
      test "is dispatched once the blocker is #{inspect(blocker_state)}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        refute Issue.blocked?(issue, terminal_states())
        assert sweep(issue) == 0
        assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    test "is held by a blocker without a known state" do
      assert Issue.blocked?(todo_blocked_by(%{id: "b", identifier: "MT-2", state: nil}), terminal_states())
      assert Issue.blocked?(todo_blocked_by(:unreadable), terminal_states())
    end

    test "outside Todo, a run already under way is not held by its blockers" do
      issue = %{todo_blocked_by(blocker("MT-2", "Merging")) | state: "In Progress"}

      refute Issue.blocked?(issue, terminal_states())
      assert Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
    end

    test "non-issues are never blocked" do
      assert Issue.open_blockers(%{blocked_by: [blocker("MT-2", "Todo")]}, terminal_states()) == []
      refute Issue.blocked?(%Issue{state: nil, blocked_by: [blocker("MT-2", "Todo")]}, terminal_states())
    end
  end

  describe "a final verification waiting on its gaps" do
    test "stays in Todo, shows in the snapshot with its open blockers, and is dispatched once every gap is Done" do
      gap = blocker("MT-323", "In Progress")
      closed_gap = blocker("MT-314", "Done")

      verification = %Issue{
        todo_blocked_by(gap)
        | id: "verify",
          identifier: "MT-272",
          title: "Final verification: Update from the menu bar",
          blocked_by: [closed_gap, gap]
      }

      other = %Issue{id: "other", identifier: "MT-1", title: "Other", state: "Todo"}
      assert sweep(verification) == 1
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

      unreadable = %{verification | blocked_by: [:unreadable]}

      assert [%{blockers: [%{identifier: nil, state: nil}]}] =
               Orchestrator.put_blocked_for_test(state, [unreadable]).blocked

      gap_done = %{verification | blocked_by: [closed_gap, %{gap | state: "Done"}]}
      assert sweep(gap_done) == 1
      state = Orchestrator.put_blocked_for_test(state, [other, gap_done])

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(gap_done, state)
    end
  end

  describe "a Todo ticket blocked by a fix to Symphony itself" do
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

    test "stays held after the fix merges, until the running app includes its merge commit" do
      run_build(@old_build)
      issue = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | id: "verify", identifier: "TP-332", title: "Final verification: Pause"}
      fix = merged_fix("TP-419", @fix_pr)

      state = poll(orchestrator_state(), [issue], fix)

      refute Issue.blocked?(issue, terminal_states())
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
               SymphonyElixir.Pauses.get({:ticket, "default", "verify"})

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

      # Until the lookup answers, the snapshot names the blocker by the pull request the reason waits on.
      assert [%{kind: :app_update, reason: "Waiting for a Symphony update that includes TP-419's fix", blockers: [%{identifier: nil, state: "merged in PR #132"}]}] =
               restarted.blocked

      # The app updates to a build that includes the merge commit: the next poll clears the reason.
      run_build(@new_build)
      state = poll(restarted, [issue], fix)

      assert state.blocked == []
      assert SymphonyElixir.Pauses.get({:ticket, "default", "verify"}) == {:ok, nil}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "the skip-update-hold label clears the wait on the next poll" do
      run_build(@old_build)
      issue = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | id: "skipping"}
      fix = merged_fix("TP-419", @fix_pr)

      state = poll(orchestrator_state(), [issue], fix)
      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      labelled = %Issue{issue | labels: [SymphonyElixir.UpdateHold.skip_label()]}
      state = poll(state, [labelled], :no_lookup)

      assert state.blocked == []
      assert SymphonyElixir.Pauses.get({:ticket, "default", "skipping"}) == {:ok, nil}
      assert Orchestrator.should_dispatch_issue_for_test(labelled, state)
    end

    test "a blocker merged in another repository releases its dependent at Done, as before" do
      run_build(@old_build)
      issue = todo_blocked_by(blocker("APP-1", "Done"))
      fix = merged_fix("APP-1", "https://github.com/acme/web-app/pull/5")

      state = poll(orchestrator_state(), [issue], fix)

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "a build from a checkout holds nothing" do
      Application.put_env(:symphony_elixir, :build, sha: nil, repo: nil, number: nil)
      issue = todo_blocked_by(blocker("TP-419", "Done"))

      state = poll(orchestrator_state(), [issue], :no_lookup)

      assert state.blocked == []
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    defp run_build(sha), do: Application.put_env(:symphony_elixir, :build, sha: sha, repo: "https://github.com/acme/symphony", number: "168")

    # What a poll does: the poll task looks blockers up, then the poll result applies the holds.
    defp poll(state, issues, fix) do
      build = SymphonyElixir.BuildInfo.current()

      lookups =
        case fix do
          :no_lookup ->
            [fetch_issues: fn _ids -> flunk("nothing to look up") end, commit_included?: fn _url, _sha, _build -> flunk("cached") end]

          :lookup_down ->
            [fetch_issues: fn _ids -> {:error, :linear_down} end]

          %Issue{} ->
            [
              fetch_issues: fn _ids -> {:ok, [fix]} end,
              merge_commit_sha: fn @fix_pr -> {:ok, @merge_sha} end,
              commit_included?: fn @fix_pr, @merge_sha, build_sha -> {:ok, build_sha == @new_build} end
            ]
        end

      # The orchestrator resolves a repo's tickets under that repo's key.
      lookups = [repo_key: "default"] ++ lookups
      cache = SymphonyElixir.UpdateHold.resolve(issues, build, state.update_hold_cache, terminal_states(), lookups)
      Orchestrator.put_blocked_for_test(%{state | update_hold_cache: cache}, issues)
    end

    defp skip_reason(issue, state) do
      state = Orchestrator.dispatch_chosen_issues_for_test([issue], state)
      state.dispatch_skipped[issue.id].reason
    end
  end

  # A done blocker whose PR Symphony's record shows merged.
  defp merged_fix(identifier, pr_url) do
    fix = %Issue{id: "id-" <> identifier, identifier: identifier, state: "Done", repo_key: "default"}
    :ok = SymphonyElixir.TicketPullRequest.record_created("default", fix.id, pr_url, nil)
    :ok = SymphonyElixir.TicketPullRequest.mark_finished("default", pr_url, "merged")
    fix
  end

  defp todo_blocked_by(blocker) do
    %Issue{id: "issue", identifier: "MT-1", title: "Blocked", state: "Todo", blocked_by: [blocker]}
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  defp terminal_states, do: Config.settings!().tracker.terminal_states

  # The poll's dependency sweep over `issue`, as the orchestrator runs it: how many reasons changed.
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
