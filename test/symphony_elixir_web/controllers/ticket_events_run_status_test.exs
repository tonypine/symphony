defmodule SymphonyElixirWeb.TicketEventsRunStatusTest do
  # The events feed's run status (`?group=run`) from what the orchestrator holds: a run reads
  # running only while the orchestrator holds a run with its id.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketEvents.RunEnds

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "repo-a"
  @issue_id "issue-run-status"
  @path "/api/v1/repos/repo-a/tickets/TP-1463/events?group=run"
  @base ~U[2026-11-12 09:38:40.000000Z]

  # Answers the snapshot a test gives it.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, %{running: [], retrying: []}}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call({:hold, run_ids}, _from, snapshot), do: {:reply, :ok, %{snapshot | running: Enum.map(run_ids, &%{run_id: &1, issue_id: "issue"})}}
  end

  setup do
    :ok = RunStore.clear()
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-1463"})

    # Implementation run 1 lost its end when Symphony quit for an update; run 2 handed off; the
    # Code Review run started after it and has no end yet.
    record!("run.started", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, model: "claude-opus-5-5"}, 0)
    record!("step.started", %{step_id: "code", title: "Write the code", mode: "delegated"}, 1, actor: {:agent, "run-impl-1", "implementation"})
    record!("step.completed", %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "passed"}, 20, actor: {:agent, "run-impl-1", "implementation"})
    record!("run.started", %{run_id: "run-impl-2", run_kind: "implementation", run_number: 2}, 22)
    record!("run.ended", %{run_id: "run-impl-2", run_kind: "implementation", run_number: 2, exit: "handoff"}, 25)
    record!("run.started", %{run_id: "run-review-1", run_kind: "code_review", run_number: 1}, 26)
    record!("step.started", %{step_id: "review", title: "Review the PR", mode: "delegated"}, 27, actor: {:agent, "run-review-1", "code_review"})

    %{orchestrator: orchestrator}
  end

  test "a run with no end the orchestrator doesn't hold reads as ended, at the next run's start, and the run it holds reads as running",
       %{orchestrator: orchestrator} do
    :ok = GenServer.call(orchestrator, {:hold, ["run-review-1"]})
    timeline = json_response(get(build_conn(), @path), 200)["timeline"]

    assert %{
             "status" => "ended",
             "ended_at" => ended_at,
             "exit" => "ended; no end was recorded",
             "summary" => %{"title" => "Implementation run 1 ended: ended; no end was recorded", "detail" => detail}
           } = run(timeline, "run-impl-1")

    assert ended_at == DateTime.to_iso8601(at(22))
    assert detail =~ "22 min"
    assert %{"status" => "ended", "exit" => "handoff"} = run(timeline, "run-impl-2")
    assert %{"status" => "running", "ended_at" => nil, "exit" => nil} = run(timeline, "run-review-1")
  end

  test "once the orchestrator holds none, the newest run reads as ended at its last event", %{orchestrator: _orchestrator} do
    timeline = json_response(get(build_conn(), @path), 200)["timeline"]

    assert %{"status" => "ended", "ended_at" => ended_at, "exit" => "ended; no end was recorded"} = run(timeline, "run-review-1")
    assert ended_at == DateTime.to_iso8601(at(27))
    refute Enum.any?(timeline, &(&1["kind"] == "run" and &1["status"] == "running"))
  end

  test "a run the boot closed reads its recorded end", %{orchestrator: _orchestrator} do
    capture_log(fn -> RunEnds.close_unended(at(60)) end)
    timeline = json_response(get(build_conn(), @path), 200)["timeline"]

    assert %{"status" => "ended", "ended_at" => impl_end} = run(timeline, "run-impl-1")
    assert impl_end == DateTime.to_iso8601(at(22))
    assert %{"status" => "ended", "ended_at" => review_end, "exit" => "ended; no end was recorded"} = run(timeline, "run-review-1")
    assert review_end == DateTime.to_iso8601(at(60))
  end

  defp run(timeline, run_id), do: Enum.find(timeline, &(&1["kind"] == "run" and &1["run_id"] == run_id))

  defp at(minute), do: DateTime.add(@base, minute * 60, :second)

  defp record!(type, payload, minute, opts \\ []) do
    opts = if Keyword.has_key?(opts, :actor), do: opts, else: Keyword.put(opts, :run_id, payload.run_id)
    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
    event
  end
end
