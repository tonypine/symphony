defmodule SymphonyElixirWeb.TicketPlanReadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketChecks, TicketPlan}
  alias SymphonyElixirWeb.Presenter

  @repo "default"
  @id "plan-read-ticket"
  @identifier "PLR-1"
  @at ~U[2026-11-20 04:00:00.000000Z]

  @plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["screen", "api"],
    summary: "The ticket page shows the plan.",
    text: "Read the plan from the ledger and draw it.",
    checks: [
      %{id: "c1", kind: "outcome", statement: "The page shows the plan.", proof: "test"},
      %{id: "c2", kind: "qa", statement: "The panel folds.", proof: "qa", state: "A groomed ticket", action: "Fold it", expect: "One line"},
      %{id: "c3", kind: "evidence", statement: "The design was compared.", proof: "attached"}
    ],
    size: %{tokens: 200_000, runs: 2}
  }

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: @identifier, phase: "In Progress"})
    :ok
  end

  defp orchestrator do
    snapshot = %{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: [], watching: []}
    start_supervised!({SnapshotOrchestrator, snapshot}, id: make_ref())
  end

  defp read, do: Presenter.issue_payload(@identifier, orchestrator(), 1_000) |> elem(1)
  defp at(minutes), do: DateTime.add(@at, minutes * 60)

  test "a ticket with no plan reads a null plan, no checks and no asks" do
    assert %{plan: nil, checks: [], asks: []} = read()
    assert %{"plan" => nil, "checks" => [], "asks" => []} = read() |> Jason.encode!() |> Jason.decode!()
  end

  test "a groomed ticket reads its plan without the checks, each check with its state, and every ask" do
    {:ok, ask} = TicketPlan.record_ask(@repo, @id, "Show the plan on the ticket page.", at: at(0))
    {:ok, plan} = TicketPlan.write(@repo, @id, @plan, at: at(1))
    {:ok, proof} = TicketChecks.prove(@repo, @id, %{check_id: "c1", by: "test", test: "plan_test.exs › shows it"}, actor: {:agent, "run-1", "implementation"}, head_sha: "abc1234", at: at(2))
    {:ok, waiver} = TicketChecks.waive(@repo, @id, "c3", "Nothing can be attached.")

    payload = read()

    assert payload.asks == [%{text: "Show the plan on the ticket page.", source: "linear", from: nil, at: DateTime.to_iso8601(at(0)), event_id: ask.id}]

    assert payload.plan == %{
             version: 1,
             reason: "Grooming",
             by: "grooming",
             shape: "single",
             layers: ["screen", "api"],
             summary: "The ticket page shows the plan.",
             text: "Read the plan from the ledger and draw it.",
             size: %{tokens: 200_000, runs: 2},
             event_id: plan.id,
             at: DateTime.to_iso8601(at(1))
           }

    assert [first, second, third] = payload.checks

    assert first == %{
             id: "c1",
             kind: "outcome",
             statement: "The page shows the plan.",
             proof: "test",
             state: "proved",
             proved_by: %{
               by: "test",
               test: "plan_test.exs › shows it",
               evidence: nil,
               details: nil,
               event_id: proof.id,
               at: DateTime.to_iso8601(at(2)),
               head: "abc1234",
               run_id: "run-1"
             },
             waived: nil
           }

    assert %{id: "c2", kind: "qa", state: "open", needs: "A groomed ticket", action: "Fold it", expect: "One line", proved_by: nil, waived: nil} = second
    assert %{id: "c3", state: "waived", proved_by: nil, waived: %{reason: "Nothing can be attached.", event_id: waiver_id, at: waived_at}} = third
    assert waiver_id == waiver.id and waived_at == DateTime.to_iso8601(waiver.at)

    assert %{"plan" => %{"version" => 1, "at" => _at}, "checks" => [%{"state" => "proved"}, %{"state" => "open"}, %{"state" => "waived"}], "asks" => [%{"source" => "linear"}]} =
             payload |> Jason.encode!() |> Jason.decode!()
  end
end
