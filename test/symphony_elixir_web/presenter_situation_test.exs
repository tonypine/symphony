defmodule SymphonyElixirWeb.PresenterSituationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.TicketEvents
  alias SymphonyElixirWeb.Presenter

  @pushed ~U[2026-10-30 09:00:00Z]

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
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp orchestrator(snapshot \\ %{}) do
    {:ok, pid} = SnapshotOrchestrator.start_link(Map.merge(%{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: [], watching: []}, snapshot))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp waiting_for_ci(issue_id \\ "ci", identifier \\ "MT-1") do
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: issue_id, issue_identifier: identifier, phase: "Code Review"})
    facts = %Facts{phase: :code_review, ci: :pending, pr: :open, pr_number: 741}
    :ok = RunStore.put_ticket_pr_watch("default", issue_id, identifier, %{facts: facts, head_sha: "abc1234"})
    {:ok, _event} = TicketEvents.record("default", issue_id, "attempt.pushed", %{head: "abc1234"}, at: @pushed)
  end

  test "reading a ticket that waits for CI says the PR, the phase that starts and when the checks started" do
    waiting_for_ci()

    assert {:ok, payload} = Presenter.issue_payload("MT-1", orchestrator(), 1_000)

    assert payload.situation == %{
             kind: "waiting_for_ci",
             word: "Waiting for CI",
             cause: "Checks are running on PR #741.",
             next: "Code Review starts when they pass.",
             since: "2026-10-30T09:00:00Z",
             waits_on: %{pr: 741, check: nil},
             and_more: 0,
             step: nil,
             run: nil,
             retry: nil
           }

    assert %{status: "untracked", pause: nil, watch: %{summary: "PR #741 open · CI running" <> _}} = payload
  end

  test "reading a ticket does not write its event" do
    waiting_for_ci()

    assert {:ok, _payload} = Presenter.issue_payload("MT-1", orchestrator(), 1_000)
    assert TicketEvents.query("ci", types: ["situation.changed"], limit: :all) == []
  end

  test "a tracked ticket with no record yet reads what the orchestrator holds of it" do
    entry = %{
      issue_id: "fresh",
      identifier: "MT-2",
      repo_key: "default",
      state: "In Progress",
      run_kind: "implementation",
      session_id: "s",
      started_at: @pushed,
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    assert {:ok, payload} = Presenter.issue_payload("MT-2", orchestrator(%{running: [entry]}), 1_000)
    assert %{kind: "working", cause: "Implementation run is writing the code."} = payload.situation
  end

  test "each of the state's issues carries its situation, with the watch block" do
    waiting_for_ci()
    waiting_for_ci("other", "MT-3")

    payload = Presenter.state_payload(orchestrator(), 1_000)

    assert [%{identifier: "MT-1", situation: %{kind: "waiting_for_ci"}, watch: %{}}, %{identifier: "MT-3", situation: %{kind: "waiting_for_ci"}}] = payload.issues
  end
end
