defmodule SymphonyElixirWeb.RepositoryPauseStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pauses
  alias SymphonyElixirWeb.Presenter

  @at ~U[2026-10-30 12:00:00Z]
  @focus "focusing on Symphony this week"

  # Answers the snapshot it is given.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    on_exit(fn -> Pauses.clear({:repository, "hub"}) end)
    {:ok, pause} = Pauses.set({:repository, "hub"}, Pauses.repository_reason(@focus), set_by: %{kind: :person, name: "Director"}, at: @at)
    %{pause: pause}
  end

  defp orchestrator(repositories) do
    skipped = [
      %{issue_id: "hub-1", identifier: "HUB-1", title: "Hub", state: "Todo", repo_key: "hub", reason: "the repository is paused by you since 2026-10-30 12:00 UTC: #{@focus}", since: @at},
      %{issue_id: "own-1", identifier: "MT-1", title: "Own", state: "Todo", repo_key: "default", reason: "blocked by MT-2", since: @at}
    ]

    snapshot = %{running: [], retrying: [], rate_limits: nil, repositories: repositories, dispatch_skipped: skipped}
    {:ok, pid} = SnapshotOrchestrator.start_link(snapshot)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "the state payload shows the pause on the paused repository only, and not every repository is paused", %{pause: pause} do
    payload = Presenter.state_payload(orchestrator([%{repo_key: "hub", pause: pause}, %{repo_key: "default", pause: nil}]), 1_000)

    assert [
             %{repo_key: "hub", paused: true, pause: %{since: "2026-10-30T12:00:00Z", set_by: %{kind: :person, name: "Director"}, reasons: [reason]}},
             %{repo_key: "default", paused: false, pause: nil}
           ] = payload.repositories

    assert %{kind: :person, text: @focus, releasable: true, set_at: "2026-10-30T12:00:00Z"} = reason
    refute payload.all_repositories_paused
    # Pausing repositories is not pausing Symphony.
    refute payload.pause.paused
  end

  test "with every repository paused the payload says so, derived from theirs", %{pause: pause} do
    assert Presenter.state_payload(orchestrator([%{repo_key: "hub", pause: pause}]), 1_000).all_repositories_paused
    refute Presenter.state_payload(orchestrator([]), 1_000).all_repositories_paused
  end

  test "a paused repository's ticket says its repository is paused; another repository's does not", %{pause: pause} do
    pid = orchestrator([%{repo_key: "hub", pause: pause}, %{repo_key: "default", pause: nil}])

    assert {:ok, %{repository_paused: true, dispatch_skipped: %{reason: "the repository is paused by you since 2026-10-30 12:00 UTC: " <> @focus}}} =
             Presenter.issue_payload("HUB-1", pid, 1_000)

    assert {:ok, %{repository_paused: false}} = Presenter.issue_payload("MT-1", pid, 1_000)
  end
end
