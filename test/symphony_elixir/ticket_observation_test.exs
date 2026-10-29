defmodule SymphonyElixir.TicketObservationTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{TicketObservation, TicketState}

  @linear_at ~U[2026-10-29 09:00:00Z]
  @now ~U[2026-10-29 09:05:00Z]

  setup do
    TicketObservation.reset()
    on_exit(&TicketObservation.reset/0)
    %{repo_key: Config.repo_key!()}
  end

  defp linear_issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-observed",
        identifier: "ACME-7",
        title: "Observe every poll",
        state: "Todo",
        labels: ["backend"],
        priority: 2,
        assignee_id: "user-1",
        blocked_by: [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}, %{id: "issue-b", identifier: "ACME-6", state: "Done"}],
        url: "https://linear.app/acme/issue/ACME-7",
        updated_at: @linear_at
      },
      attrs
    )
  end

  test "a ticket without a record gets one holding what Linear says, with no ledger event", %{repo_key: repo_key} do
    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    record = RunStore.get_ticket_state(repo_key, "issue-observed")

    assert %{
             issue_identifier: "ACME-7",
             phase: "Todo",
             title: "Observe every poll",
             labels: ["backend"],
             priority: 2,
             assignee: "user-1",
             blockers: ["ACME-5"],
             url: "https://linear.app/acme/issue/ACME-7",
             linear_updated_at: @linear_at,
             observed_at: @now
           } = record

    assert ticket_events(repo_key, "issue-observed") == []
  end

  test "the same issue again writes nothing", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    stored = RunStore.get_ticket_state(repo_key, "issue-observed")

    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed") == stored
  end

  test "a newer title reaches an existing record and leaves its other fields", %{repo_key: repo_key} do
    held = repo_key |> TicketState.new("issue-observed") |> TicketState.set_hold(:needs_decision, %{reason: "asked"}, @now)
    :ok = RunStore.put_ticket_state(held)
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    renamed = linear_issue(%{title: "Observe every poll, renamed", updated_at: DateTime.add(@linear_at, 300)})
    assert {:ok, :updated} = TicketObservation.observe(repo_key, renamed, now: DateTime.add(@now, 300))

    record = RunStore.get_ticket_state(repo_key, "issue-observed")
    assert record.title == "Observe every poll, renamed"
    assert record.linear_updated_at == DateTime.add(@linear_at, 300)
    assert [%{kind: :needs_decision, reason: "asked"}] = record.holds
  end

  test "an older issue is dropped, counted as stale, and the record untouched", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    stored = RunStore.get_ticket_state(repo_key, "issue-observed")

    older = linear_issue(%{title: "Before the rename", state: "Backlog", updated_at: DateTime.add(@linear_at, -60)})
    assert {:ok, :stale} = TicketObservation.observe(repo_key, older, now: DateTime.add(@now, 60))

    assert RunStore.get_ticket_state(repo_key, "issue-observed") == stored
    assert TicketObservation.summary() == %{updated: 1, unchanged: 0, stale: 1, errors: 0}
  end

  test "blockers keep the open ones: the given terminal states, else the repo's", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, terminal_states: ["In Progress"])
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == ["ACME-6"]

    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{updated_at: DateTime.add(@linear_at, 1)}), now: @now)
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == ["ACME-5"]
  end

  test "an unknown blocker list keeps the known blockers", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(%{blocked_by: :unknown}), now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == ["ACME-5"]
  end

  test "a repo Symphony has no settings for keeps every blocker" do
    assert {:ok, :updated} = TicketObservation.observe("observation-other-repo", linear_issue())

    record = RunStore.get_ticket_state("observation-other-repo", "issue-observed")
    assert record.blockers == ["ACME-5", "ACME-6"]
    assert %DateTime{} = record.observed_at
  end

  test "a store refusal is returned and counted" do
    assert {:error, :invalid_repo_key} = TicketObservation.observe("  ", linear_issue(), now: @now, terminal_states: [])
    assert TicketObservation.summary().errors == 1
  end

  test "observe_all observes each issue and logs the ones it could not", %{repo_key: repo_key} do
    other = linear_issue(%{id: "issue-observed-2", identifier: "ACME-8"})

    log =
      capture_log(fn ->
        issues = [linear_issue(), other, %Issue{id: nil, identifier: "ACME-9"}, :junk]

        assert TicketObservation.observe_all(repo_key, issues, now: @now) ==
                 %{updated: 2, unchanged: 0, stale: 0, errors: 2}
      end)

    assert log =~ "Ticket observation failed for issue_id= issue_identifier=ACME-9 repo_key=#{repo_key}: :invalid_issue"
    assert log =~ "issue_id= issue_identifier= repo_key=#{repo_key}"
    assert RunStore.get_ticket_state(repo_key, "issue-observed-2").issue_identifier == "ACME-8"
    assert TicketObservation.summary() == %{updated: 2, unchanged: 0, stale: 0, errors: 2}
  end

  test "without the server, observing still writes and the summary is all zeros", %{repo_key: repo_key} do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, TicketObservation)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, TicketObservation) end)

    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    assert TicketObservation.summary() == %{updated: 0, unchanged: 0, stale: 0, errors: 0}
    assert :ok = TicketObservation.reset()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, TicketObservation)
  end
end
