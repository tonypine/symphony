defmodule SymphonyElixirWeb.LifecycleReadTest do
  # The ticket read's `lifecycle` and `phase_path`, through the control API.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.TicketEvents

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"

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
    on_exit(fn -> RunStore.clear() end)
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

  defp moved(issue_id, time, from, to), do: {:ok, _event} = TicketEvents.record(@repo, issue_id, "phase.entered", %{to: to, from: from}, at: time)

  defp ran(issue_id, run_id, run_kind, started_at, ended_at, tokens) do
    {:ok, _event} = TicketEvents.record(@repo, issue_id, "run.started", %{run_id: run_id, run_kind: run_kind}, at: started_at, run_id: run_id)
    {:ok, _event} = TicketEvents.record(@repo, issue_id, "run.ended", %{run_id: run_id, exit: "success", tokens: tokens}, at: ended_at, run_id: run_id)
  end

  defp merged_ticket do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "merged", issue_identifier: "MT-1", phase: "Done"})

    moved("merged", ~U[2026-10-30 10:00:00Z], "Todo", "In Progress")
    ran("merged", "r1", "implementation", ~U[2026-10-30 10:01:00Z], ~U[2026-10-30 10:30:00Z], 2_000)
    moved("merged", ~U[2026-10-30 10:30:00Z], "In Progress", "Code Review")
    ran("merged", "r2", "code_review", ~U[2026-10-30 10:31:00Z], ~U[2026-10-30 10:40:00Z], 500)
    moved("merged", ~U[2026-10-30 10:40:00Z], "Code Review", "Rework")
    ran("merged", "r3", "rework", ~U[2026-10-30 10:41:00Z], ~U[2026-10-30 10:50:00Z], 700)
    moved("merged", ~U[2026-10-30 10:50:00Z], "Rework", "Code Review")
    moved("merged", ~U[2026-10-30 11:00:00Z], "Code Review", "QA")
    ran("merged", "r4", "qa", ~U[2026-10-30 11:01:00Z], ~U[2026-10-30 11:20:00Z], 300)
    moved("merged", ~U[2026-10-30 11:20:00Z], "QA", "Merging")
    moved("merged", ~U[2026-10-30 12:20:00Z], "Merging", "Done")
  end

  defp read(identifier), do: build_conn() |> get("/api/v1/#{identifier}") |> json_response(200)

  test "a merged ticket's lifecycle lists five stages, and its tokens add up to the run tokens on its timeline" do
    merged_ticket()

    assert %{"lifecycle" => lifecycle, "phase_path" => phase_path} = read("MT-1")

    assert [
             %{"id" => "coding", "state" => "passed", "visits" => 1, "time_ms" => 1_800_000, "tokens" => 2_000},
             %{"id" => "code_review", "state" => "passed", "visits" => 2, "time_ms" => 1_800_000, "tokens" => 1_200},
             %{"id" => "qa", "state" => "passed", "visits" => 1, "time_ms" => 1_200_000, "tokens" => 300},
             %{"id" => "merging", "state" => "passed", "visits" => 1, "time_ms" => 3_600_000, "tokens" => 0},
             %{"id" => "done", "state" => "passed", "visits" => 1, "time_ms" => 0, "tokens" => 0}
           ] = lifecycle["stages"]

    on_timeline = "merged" |> TicketEvents.query(types: ["run.ended"], limit: :all) |> Enum.map(& &1.payload.tokens) |> Enum.sum()
    split = lifecycle["stages"] |> Enum.map(& &1["tokens"]) |> Enum.sum()

    assert on_timeline == 3_500
    assert split == on_timeline
    assert lifecycle["tokens"] == %{"total" => on_timeline, "cap" => Config.settings!().agent.max_tokens_per_issue}

    assert phase_path["current"] == "Done"
    assert Enum.map(phase_path["phases"], &{&1["phase"], &1["count"]}) == [{"In Progress", 1}, {"Code Review", 2}, {"Rework", 1}, {"QA", 1}, {"Merging", 1}, {"Done", 1}]
    assert %{"from" => "Todo", "to" => "In Progress", "at" => "2026-10-30T10:00:00Z"} = List.first(phase_path["moves"])
  end

  test "the read goes by the phase names the repository configures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_phase_names: %{code_review: "In Review", qa: "Testing", ci_fix: "Repair"})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "renamed", issue_identifier: "MT-3", phase: "Repair"})

    moved("renamed", ~U[2026-10-30 10:00:00Z], "Todo", "In Progress")
    moved("renamed", ~U[2026-10-30 10:30:00Z], "In Progress", "In Review")
    ran("renamed", "r1", "code_review", ~U[2026-10-30 10:31:00Z], ~U[2026-10-30 10:40:00Z], 500)
    moved("renamed", ~U[2026-10-30 10:40:00Z], "In Review", "Testing")
    ran("renamed", "r2", "qa", ~U[2026-10-30 10:41:00Z], ~U[2026-10-30 10:50:00Z], 300)
    moved("renamed", ~U[2026-10-30 10:50:00Z], "Testing", "Repair")

    assert %{"lifecycle" => %{"current" => "qa"} = lifecycle, "phase_path" => %{"current" => "Repair"}} = read("MT-3")

    assert [
             %{"id" => "coding", "visits" => 1, "tokens" => 0},
             %{"id" => "code_review", "state" => "passed", "visits" => 1, "time_ms" => 600_000, "tokens" => 500},
             %{"id" => "qa", "state" => "current", "visits" => 2, "tokens" => 300},
             %{"id" => "merging", "visits" => 0},
             %{"id" => "done", "visits" => 0}
           ] = lifecycle["stages"]
  end

  test "each of the state's issues carries the same lifecycle and phase path" do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "watched", issue_identifier: "MT-2", phase: "Rework"})
    facts = %Facts{phase: :rework, ci: :pending, pr: :open, pr_number: 741}
    :ok = RunStore.put_ticket_pr_watch(@repo, "watched", "MT-2", %{facts: facts, head_sha: "abc1234"})
    moved("watched", ~U[2026-10-30 10:00:00Z], "In Progress", "Code Review")
    moved("watched", ~U[2026-10-30 10:30:00Z], "Code Review", "Rework")

    assert %{"issues" => [issue]} = build_conn() |> get("/api/v1/state") |> json_response(200)

    assert %{"identifier" => "MT-2", "lifecycle" => %{"current" => "code_review"} = lifecycle, "phase_path" => %{"current" => "Rework"}} = issue
    assert %{"state" => "current", "visits" => 2} = Enum.find(lifecycle["stages"], &(&1["id"] == "code_review"))
  end
end
