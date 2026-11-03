defmodule SymphonyElixirWeb.RecordsMergedStateTest do
  # The state payload's `records_merged`: the report the one-time merge of duplicate ticket records
  # (Symphony 0.0.1.792, TP-1338) left in the store, beside its marker.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

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
    :ok
  end

  defp state, do: build_conn() |> get("/api/v1/state") |> json_response(200) |> Map.fetch!("records_merged")

  test "the state shows nothing on a store the merge never ran on, then the report the merge kept" do
    assert state() == nil

    report = %{
      name: "records.merged",
      at: @now,
      checked: 536,
      merged: 1,
      withdrawn: 1,
      merges: [%{issue_id: "issue-1074", issue_identifier: "TP-1074", repo_key: "job-search-hub", folded: ["symphony"]}]
    }

    :ok = RunStore.put_marker_with_report(RunStore.records_merged_marker(), @now, report)

    assert state() == %{
             "name" => "records.merged",
             "at" => "2026-11-03T09:00:00Z",
             "checked" => 536,
             "merged" => 1,
             "withdrawn" => 1,
             "merges" => [%{"issue_id" => "issue-1074", "issue_identifier" => "TP-1074", "repo_key" => "job-search-hub", "folded" => ["symphony"]}]
           }
  end
end
