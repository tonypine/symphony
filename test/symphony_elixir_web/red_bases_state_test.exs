defmodule SymphonyElixirWeb.RedBasesStateTest do
  @moduledoc """
  `red_bases` in the app's state lists the red release gate with the tickets it holds, and the row
  leaves once the gate is green (TP-1583).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReleaseGate
  alias SymphonyElixirWeb.Presenter

  # Answers the snapshot it is given.
  defmodule SnapshotOrchestrator do
    use GenServer, restart: :temporary

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
    {:ok, repo_key} = Config.repo_key()
    {:ok, repo_key: repo_key}
  end

  defp orchestrator(snapshot) do
    start_supervised!({SnapshotOrchestrator, Map.merge(%{running: [], retrying: [], rate_limits: nil}, snapshot)})
  end

  defp held(identifier, repo_key, rule) do
    %{
      issue_id: "id-" <> identifier,
      identifier: identifier,
      repo_key: repo_key,
      state: "Todo",
      rule: rule,
      reason: "Holding while the release gate on main is red: TP-1520 is fixing it"
    }
  end

  defp put_fix(repo_key, red) do
    fix = %{identifier: "TP-1520", sha: "9f54098b", number: 950, attempt: 1, red: red}
    :ok = RunStore.put_github_updates({:release_gate_fix, repo_key}, fix)
  end

  test "the state payload lists a red release gate with the tickets it holds, until it is green (TP-1583)", %{repo_key: repo_key} do
    skipped = [held("TP-2", repo_key, :release_gate), held("TP-1", repo_key, :release_gate), held("TP-4", repo_key, :priority)]
    orchestrator = orchestrator(%{dispatch_skipped: skipped})

    # No gate failure: no row.
    assert Presenter.state_payload(orchestrator, 1_000).red_bases == []

    # The gate is red: one row, with the tickets the gate holds.
    put_fix(repo_key, true)
    payload = Presenter.state_payload(orchestrator, 1_000)
    assert payload.red_bases == [%{base: "main", check: ReleaseGate.job(), issue_identifiers: ["TP-1", "TP-2"]}]
    assert Enum.map(payload.dispatch_skipped, & &1.issue_identifier) == ["TP-2", "TP-1", "TP-4"]

    assert payload |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("red_bases") ==
             [%{"base" => "main", "check" => "release gate", "issue_identifiers" => ["TP-1", "TP-2"]}]

    # The gate is green, the fix ticket still recorded: the row is gone.
    put_fix(repo_key, false)
    assert Presenter.state_payload(orchestrator, 1_000).red_bases == []
  end
end
