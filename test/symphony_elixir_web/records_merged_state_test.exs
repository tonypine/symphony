defmodule SymphonyElixirWeb.RecordsMergedStateTest do
  # The state payload's `records_merged`: the report of the one-time merge of duplicate ticket
  # records (`SymphonyElixir.TicketMerge`, TP-1338).
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.{TicketMerge, TicketState}

  @endpoint SymphonyElixirWeb.Endpoint
  @now ~U[2026-11-03 09:00:00.000000Z]

  defmodule IdleOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, %{running: [], retrying: [], rate_limits: nil}, state}
  end

  defmodule UnreadableStore do
    def get_marker(_name), do: nil
    def ticket_record_repositories, do: {:error, :unreadable}
  end

  setup do
    :ok = RunStore.clear()
    write_workflow_file!(Workflow.workflow_file_path())
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: IdleOrchestrator, start: {IdleOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    TicketMerge.reset()
    on_exit(fn -> TicketMerge.reset() end)
    :ok
  end

  defp state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("records_merged")

  test "the state shows nothing before the merge ran, its failure while the marker is unset, then its report" do
    assert state() == nil

    capture_log(fn -> {:error, :unreadable} = TicketMerge.run(store: UnreadableStore, now: @now) end)
    assert %{"name" => "records.merged", "at" => "2026-11-03T09:00:00Z", "error" => ":unreadable"} = state()

    for repo_key <- ["symphony", "job-search-hub"] do
      record = TicketState.new(repo_key, "issue-1074", %{issue_identifier: "TP-1074", observed_at: if(repo_key == "symphony", do: ~U[2026-10-20 00:00:00Z], else: @now)})
      {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_ticket_states, {repo_key, "issue-1074"}, repo_key, "issue-1074", record}) end)
    end

    capture_log(fn -> {:ok, _report} = TicketMerge.run(now: @now, project: fn _ticket -> :ok end) end)

    assert state() == %{
             "name" => "records.merged",
             "at" => "2026-11-03T09:00:00Z",
             "checked" => 1,
             "merged" => 1,
             "withdrawn" => 0,
             "merges" => [%{"issue_id" => "issue-1074", "issue_identifier" => "TP-1074", "repo_key" => "job-search-hub", "folded" => ["symphony"]}]
           }
  end
end
