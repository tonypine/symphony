defmodule SymphonyElixir.OrchestratorBootTest do
  # Startup is a trigger (TP-1303): boot runs every cycle once instead of leaving the first pass to
  # timers, and a ticket released from the app update hold is dispatched at once. Writes the store
  # and reads the app's config: not async.
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Pauses, UpdateHold}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @build_sha "d3d301b0123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @build %{version: "0.0.1.746", sha: @build_sha, repo: "https://github.com/acme/symphony"}
  @fix_pr "https://github.com/acme/symphony/pull/132"
  @hold_setter %{kind: :rule, name: "App update hold"}

  setup do
    :ok = RunStore.clear()
    :ok = ObservabilityPubSub.subscribe_ticket_records()
    on_exit(fn -> :ok = RunStore.clear() end)
  end

  defp repos, do: [%{name: "web", team: "ACME", labels: ["web"]}, %{name: "api", team: "ACME", labels: ["api"]}]

  defp held_issue do
    %Issue{
      id: "held",
      identifier: "ACME-1238",
      title: "Pause this repository",
      state: "Todo",
      repo_key: "web",
      blocked_by: [%{id: "fix", identifier: "ACME-1235", state: "Done"}]
    }
  end

  defp watched_issue, do: %Issue{id: "watched", identifier: "ACME-7", title: "Green and reviewed", state: "Code Review", repo_key: "api"}

  defp fetcher do
    test_pid = self()

    fn %{name: name} ->
      send(test_pid, {:polled, name})
      {:ok, if(name == "web", do: [held_issue()], else: [watched_issue()])}
    end
  end

  defp hold_for_update! do
    reason = %{kind: :build, waits_on: %{pull_request: 132}, text: "Waiting for a Symphony update that includes ACME-1235's fix"}
    {:ok, _pause} = Pauses.set({:ticket, "web", "held"}, reason, set_by: @hold_setter)
    assert [_reason] = UpdateHold.reasons("web", "held")
  end

  # The cache after the update: the blocker's merge commit is in the running build.
  defp installed_cache, do: %{blockers: %{"fix" => {:merged, @fix_pr, @merge_sha}}, included: %{{@merge_sha, @build_sha} => true}}

  test "a boot with a held ticket and a watched PR acts on both with no timer advanced" do
    hold_for_update!()
    flush_records()
    state = %Orchestrator.State{poll_interval_ms: 60_000}

    # The boot's first cycle polls web; its update-hold check releases the ticket, and the release
    # asks for a dispatch cycle while this one is in flight.
    {:ok, %{dispatchable: []}, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos(), fetcher(), 0)
    assert_received {:polled, "web"}

    log = capture_log(fn -> UpdateHold.resolve([held_issue()], @build, installed_cache(), ["Done"], repo_key: "web") end)
    assert log =~ "Released from the app update hold: issue_id=held issue_identifier=ACME-1238"
    assert UpdateHold.reasons("web", "held") == []
    assert_receive {:ticket_record, "web", "held", :changed, [:pause]} = released

    in_flight = %{state | poll_check_in_progress: true}
    assert {:noreply, %{cycle_requested: true} = state} = Orchestrator.handle_info(released, in_flight)

    # Every repo was due at boot, so the second cycle runs at the same instant: api is polled, every
    # cache is warm, and both the released ticket and the watched PR's ticket are candidates.
    assert {:ok, %{dispatchable: dispatchable}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos(), fetcher(), 0)

    assert_received {:polled, "api"}
    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [{"ACME-1238", "web"}, {"ACME-7", "api"}]

    # The timed polls stay spread: web's next one interval on, api's on its stagger slot.
    assert state.repo_poll_due_at_ms == %{"web" => 60_000, "api" => 90_000}
  end

  test "a lifted pause runs a cycle at once; one in flight is followed by another, never dropped" do
    released = {:ticket_record, "web", "held", :changed, [:pause]}

    # Nothing in flight: the tick is sent at once.
    {:noreply, state} = Orchestrator.handle_info(released, %Orchestrator.State{poll_interval_ms: 60_000})
    assert_receive {:tick, token}
    assert state.tick_token == token
    refute state.cycle_requested

    # A cycle in flight: it is followed by another as soon as it finishes.
    in_flight = %Orchestrator.State{
      poll_interval_ms: 60_000,
      poll_check_in_progress: true,
      repo_poll_task_ref: make_ref(),
      repo_poll_due_at_ms: %{"web" => 3_600_000_000}
    }

    {:noreply, state} = Orchestrator.handle_info(released, in_flight)
    assert state.cycle_requested
    {:noreply, state} = Orchestrator.handle_info(:run_poll_cycle, state)
    assert_receive {:tick, token}
    assert %{tick_token: ^token, cycle_requested: false, poll_check_in_progress: false} = state

    # Without a request the finished cycle waits for the next due repo.
    {:noreply, _state} = Orchestrator.handle_info(:run_poll_cycle, in_flight)
    refute_receive {:tick, _token}, 50

    # A new decision of the PR watcher that a run starts asks for a cycle the same way.
    decided = {:ticket_record, "api", "watched", :changed, [:pr_watch]}
    {:noreply, _state} = Orchestrator.handle_info(decided, %Orchestrator.State{poll_interval_ms: 60_000})
    assert_receive {:tick, _token}
  end

  test "a ticket's pause announces each change, never a write that changes nothing" do
    ticket = {:ticket, "web", "held"}
    reason = %{kind: :build, waits_on: %{pull_request: 132}}

    {:ok, _pause} = Pauses.set(ticket, reason, set_by: @hold_setter)
    assert_received {:ticket_record, "web", "held", :changed, [:pause]}
    {:ok, _pause} = Pauses.set(ticket, reason, set_by: @hold_setter)
    refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}
    {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:dependency, "ACME-9"))
    assert_received {:ticket_record, "web", "held", :changed, [:pause]}

    {:ok, _pause} = Pauses.clear_reason(ticket, reason, by: @hold_setter)
    assert_received {:ticket_record, "web", "held", :changed, [:pause]}

    {:ok, _pause} = Pauses.clear_reason(ticket, reason, by: @hold_setter)
    refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}

    {:ok, nil} = Pauses.clear(ticket, by: @hold_setter)
    assert_received {:ticket_record, "web", "held", :changed, [:pause]}
  end

  defp flush_records do
    receive do
      {:ticket_record, _repo_key, _issue_id, :changed, _fields} -> flush_records()
    after
      0 -> :ok
    end
  end
end
