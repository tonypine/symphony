defmodule SymphonyElixirWeb.ProvidersStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Providers
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
    :ok
  end

  defp orchestrator(snapshot) do
    start_supervised!({SnapshotOrchestrator, Map.merge(%{running: [], retrying: [], rate_limits: nil}, snapshot)})
  end

  test "the state payload lists the providers with their times in ISO 8601, in use first" do
    providers =
      Providers.list(%{
        runs: [%{kind: :implementation, provider: "anthropic", fallback: nil}],
        pauses: %{"anthropic" => %{since: ~U[2026-11-18 09:00:00.123456Z]}},
        usage_limits: [%{provider: "anthropic", resume_at: ~U[2026-11-18 14:05:00Z]}],
        usage_windows: %{{"anthropic", "five_hour"} => %{resets_at: ~U[2026-11-18 14:00:00Z], utilization: 0.91}},
        working: ["anthropic"],
        tokens_today: %{"anthropic" => 1_200}
      })

    payload = Presenter.state_payload(orchestrator(%{providers: providers}), 1_000)

    assert [
             %{
               provider: "anthropic",
               name: "Anthropic",
               in_use: true,
               paused: true,
               paused_since: "2026-11-18T09:00:00Z",
               held: true,
               held_until: "2026-11-18T14:05:00Z",
               usage_windows: [%{name: "five_hour", utilization: 0.91, resets_at: "2026-11-18T14:00:00Z"}],
               harnesses: ["claude"],
               kinds: ["implementation"],
               fallback_for: [],
               working: 1,
               tokens_today: 1_200,
               reserve: nil
             },
             %{provider: "openrouter", in_use: false, paused_since: nil, held_until: nil, usage_windows: []} | _rest
           ] = payload.providers

    assert payload |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("providers") |> hd() |> Map.fetch!("reserve") == nil
  end

  test "a snapshot without providers gives an empty list" do
    assert Presenter.state_payload(orchestrator(%{}), 1_000).providers == []
  end
end
