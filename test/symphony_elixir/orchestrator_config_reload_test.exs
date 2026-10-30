defmodule SymphonyElixir.OrchestratorConfigReloadTest do
  # A config reload is a trigger (TP-1306): a reload that changes what dispatch reads runs a cycle at
  # once, and one that changes nothing dispatch reads runs none. Rewrites the app's config: not async.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Dispatch.Settings

  @waiting %{"waiting" => %{identifier: "MT-2", reason: "work slots full", since: ~U[2026-10-30 12:00:00Z]}}

  defp write_config!(overrides) do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.merge([poll_interval_ms: 60_000], overrides))
  end

  defp reload_handlers, do: :telemetry.list_handlers(Cache.reloaded_event())

  defp handler_ids(name), do: for(%{id: {Orchestrator, :config_reloaded, ^name} = id} <- reload_handlers(), do: id)

  test "raising the slot limit while a ticket waits for a slot ticks at once, with no timer advanced" do
    write_config!(max_concurrent_agents: 1)
    state = %Orchestrator.State{poll_interval_ms: 60_000, slot_waiting: @waiting, dispatch_settings: Settings.read()}

    # The reload the file watcher announces reaches the orchestrator as a message.
    handler = {__MODULE__, :reloaded}
    :ok = :telemetry.attach(handler, Cache.reloaded_event(), &Orchestrator.handle_config_reloaded/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    write_config!(max_concurrent_agents: 2)
    symphony_path = Workflow.symphony_file_path()
    _ = Config.settings!()
    :ok = Cache.invalidate(symphony_path)
    assert_receive {:config_reloaded, ^symphony_path} = reloaded

    {:noreply, state} = Orchestrator.handle_info(reloaded, state)
    assert_receive {:tick, token}
    assert state.tick_token == token
    assert state.dispatch_settings == Settings.read()

    # A cycle in flight is followed by another once it finishes, never dropped.
    write_config!(max_concurrent_agents: 3)
    {:noreply, state} = Orchestrator.handle_info(reloaded, %{state | poll_check_in_progress: true, tick_token: nil})
    assert state.cycle_requested
  end

  test "a reload that leaves the dispatch settings as they were sends no tick" do
    write_config!(max_concurrent_agents: 1)
    state = %Orchestrator.State{poll_interval_ms: 60_000, slot_waiting: @waiting, dispatch_settings: Settings.read()}

    # A setting dispatch does not read.
    write_config!(max_concurrent_agents: 1, max_turns: 7)
    {:noreply, ^state} = Orchestrator.handle_info({:config_reloaded, Workflow.symphony_file_path()}, state)
    refute_receive {:tick, _token}, 50
  end

  test "dispatch settings change with a priority, an active state, the slot limits or a repo's settings" do
    write_config!(max_concurrent_agents: 1)
    before = Settings.read()

    for overrides <- [
          [max_concurrent_agents: 1, tickets: %{priorities: ["urgent"]}],
          [max_concurrent_agents: 1, tracker_active_states: ["Todo", "In Progress", "Rework"]],
          [max_concurrent_agents: 1, max_concurrent_agents_by_state: %{"todo" => 1}]
        ] do
      write_config!(overrides)
      refute Settings.read() == before, "#{inspect(overrides)} left the dispatch settings unchanged"
    end

    # Config that can't be read reads as its error, so fixing it is a change too.
    File.write!(Workflow.symphony_file_path(), "repositories: [unclosed\n")
    :ok = Cache.clear()
    assert {_source, %{nil => {:error, _reason}}} = Settings.read()
  end

  test "the orchestrator attaches once per name, a restart replaces its handler, and a stop detaches it" do
    write_config!(max_concurrent_agents: 1)
    name = Module.concat(__MODULE__, :Orchestrator)

    {:ok, pid} = Orchestrator.start_link(name: name)
    assert handler_ids(name) == [{Orchestrator, :config_reloaded, name}]
    assert :sys.get_state(pid).dispatch_settings == Settings.read()

    # Killed with no terminate, as a supervisor's shutdown does: the restart attaches no second one.
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    {:ok, pid} = Orchestrator.start_link(name: name)
    assert [%{config: ^pid}] = Enum.filter(reload_handlers(), &match?(%{id: {Orchestrator, :config_reloaded, ^name}}, &1))

    :ok = GenServer.stop(pid)
    assert handler_ids(name) == []
    assert :ok == Orchestrator.terminate(:normal, %Orchestrator.State{})
  end
end
