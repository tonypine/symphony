defmodule SymphonyElixir.BlockedByGateTest do
  use SymphonyElixir.TestSupport

  @states ["Todo", "In Progress", "In Review", "Auto Review", "Merging", "Rework"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: @states,
      tracker_terminal_states: ["Done", "Canceled", "Duplicate"]
    )

    :ok
  end

  describe "a Todo ticket with a blocker" do
    for blocker_state <- ["Merging", "In Review", "Auto Review", "Rework", "In Progress", "Backlog"] do
      test "is held while the blocker is #{blocker_state}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        assert Issue.blocked?(issue, terminal_states())
        refute Orchestrator.should_dispatch_issue_for_test(issue, orchestrator_state())
      end
    end

    for blocker_state <- ["Done", "Canceled", "Duplicate", " done "] do
      test "is dispatched once the blocker is #{inspect(blocker_state)}" do
        issue = todo_blocked_by(blocker("MT-2", unquote(blocker_state)))

        refute Issue.blocked?(issue, terminal_states())
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

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
          :error -> Application.delete_env(:symphony_elixir, :build)
        end
      end)
    end

    test "stays held after the fix merges, until the running app includes its merge commit" do
      run_build(@old_build)
      issue = %Issue{todo_blocked_by(blocker("TP-419", "Done")) | id: "verify", identifier: "TP-332", title: "Final verification: Pause"}
      fix = %Issue{id: "id-TP-419", identifier: "TP-419", state: "Done", pr_urls: [@fix_pr]}

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
                 reason: "waiting for an app update: TP-419 merged in `9f54098`, running `d3d301b`",
                 blockers: [%{identifier: "TP-419", state: "merged in 9f54098"}]
               }
             ]

      assert snapshot_of(state).blocked == state.blocked

      # The same build on the next poll: nothing new to look up, still held.
      assert poll(state, [issue], :no_lookup).blocked == state.blocked

      # The app updates to a build that includes the merge commit.
      run_build(@new_build)
      state = poll(state, [issue], fix)

      assert state.blocked == []
      assert state.update_holds == %{}
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "a blocker merged in another repository releases its dependent at Done, as before" do
      run_build(@old_build)
      issue = todo_blocked_by(blocker("APP-1", "Done"))
      fix = %Issue{id: "id-APP-1", identifier: "APP-1", state: "Done", pr_urls: ["https://github.com/acme/web-app/pull/5"]}

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

          %Issue{} ->
            [
              fetch_issues: fn _ids -> {:ok, [fix]} end,
              merge_commit_sha: fn @fix_pr -> {:ok, @merge_sha} end,
              commit_included?: fn @fix_pr, @merge_sha, build_sha -> {:ok, build_sha == @new_build} end
            ]
        end

      cache = SymphonyElixir.UpdateHold.resolve(issues, build, state.update_hold_cache, terminal_states(), lookups)
      Orchestrator.put_blocked_for_test(%{state | update_hold_cache: cache}, issues)
    end
  end

  defp todo_blocked_by(blocker) do
    %Issue{id: "issue", identifier: "MT-1", title: "Blocked", state: "Todo", blocked_by: [blocker]}
  end

  defp blocker(identifier, state), do: %{id: "id-" <> identifier, identifier: identifier, state: state}

  defp terminal_states, do: Config.settings!().tracker.terminal_states

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
