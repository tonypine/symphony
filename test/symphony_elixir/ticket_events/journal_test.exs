defmodule SymphonyElixir.TicketEvents.JournalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, RuleActions, TicketEvents}
  alias SymphonyElixir.TicketEvents.{Event, Journal}

  @repo "fixture"
  @other_repo "other"
  @morning ~U[2026-11-09 06:00:00.000000Z]
  @now ~U[2026-11-09 20:00:00.000000Z]

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "epic", issue_identifier: "FIX-1", title: "The epic", phase: "Waiting on sub-tickets"})

    :ok =
      RunStore.put_ticket_state(%{
        repo_key: @repo,
        issue_id: "child",
        issue_identifier: "FIX-2",
        title: "A sub-ticket",
        phase: "In Progress",
        parent: %{identifier: "FIX-1", title: "The epic"}
      })

    :ok = RunStore.put_ticket_state(%{repo_key: @other_repo, issue_id: "elsewhere", issue_identifier: "OTH-1", title: "Another repo's", phase: "Todo"})
    :ok
  end

  defp at(hour, minute \\ 0), do: %{@morning | hour: hour, minute: minute}

  defp record!(issue_id, type, payload, opts) do
    {:ok, event} = TicketEvents.record(if(issue_id == "elsewhere", do: @other_repo, else: @repo), issue_id, type, payload, opts)
    event
  end

  # A day on the fixture repo: a run, its verdict, the moves, a question asked and answered, a rule's
  # actions and a short pause, with one event the night before and one on another repository.
  defp fixture_day do
    record!("child", "phase.entered", %{to: "In Progress", from: "Todo"}, at: ~U[2026-11-08 23:00:00.000000Z])
    record!("child", "run.started", %{run_id: "run-1", run_kind: "implementation"}, at: at(8))
    record!("child", "phase.entered", %{to: "Code Review", from: "In Progress"}, at: at(9))
    record!("child", "verdict.recorded", %{kind: "code_review", outcome: "approve"}, at: at(10), run_id: "run-2")
    record!("child", "question.asked", %{question_id: "q-1", title: "Merge it?", question: "Merge it?", asked_by: %{kind: :rule, name: "Quality gate"}}, at: at(11))
    record!("child", "question.answered", %{question_id: "q-1", answer: "Yes", by: %{kind: :person, name: "Director"}}, at: at(12))
    RuleActions.record(@repo, "child", "PR watcher R22", "rerun", "A check failed: Symphony reran it", at: at(13))
    record!("child", "pause.set", %{reason: "ticket", text: "Waiting for FIX-1", set_by: %{kind: :symphony, name: "Symphony"}}, at: at(14))
    record!("child", "pause.cleared", %{cleared: []}, at: at(14, 2))
    record!("epic", "ticket.moved", %{from: "Todo", to: "In Progress"}, at: at(15), actor: {:person, "Director"})
    record!("epic", "note", %{text: "A note"}, at: at(16), actor: {:agent, "run-3", "implementation"})
    record!("elsewhere", "verdict.recorded", %{kind: "qa", outcome: "pass"}, at: at(12, 30))
  end

  defp read!(opts) do
    {:ok, page} = Journal.read(Keyword.put_new(opts, :now, @now))
    page
  end

  defp types(page), do: Enum.map(page.entries, &{&1.ticket.identifier, &1.event.type})

  test "a day's notable events for the fixture repo list every verdict, move, question and rule action once, newest first" do
    fixture_day()

    page = read!(since: @morning, repo: @repo, notable: true)

    assert types(page) == [
             {"FIX-1", "ticket.moved"},
             {"FIX-2", "rule.action"},
             {"FIX-2", "question.answered"},
             {"FIX-2", "question.asked"},
             {"FIX-2", "verdict.recorded"},
             {"FIX-2", "phase.entered"}
           ]

    assert page.next_until == nil
    assert Enum.all?(page.entries, & &1.notable)

    # Each line names the ticket and who did it.
    assert [moved, rule, answered, asked, verdict, entered] = page.entries
    assert moved.ticket == %{repo_key: @repo, identifier: "FIX-1", title: "The epic"}
    assert moved.by == %{kind: "person", name: "Director"}
    assert rule.by == %{kind: "rule", name: "PR watcher R22"}
    assert rule.event.summary.title == "PR watcher R22 reran the failed checks"
    assert answered.by == %{kind: "person", name: "Director"}
    assert asked.by == %{kind: "rule", name: "Quality gate"}
    assert verdict.by == %{kind: "run", name: nil, run_id: "run-2"}
    assert entered.by == %{kind: "symphony", name: "Symphony"}
    assert Enum.map(page.entries, & &1.class) == ["move", "rule", "question", "question", "verdict", "move"]
  end

  test "notable false returns everything, across repositories without a repo" do
    fixture_day()

    all = read!(since: @morning, notable: false)
    assert length(all.entries) == 11
    assert {"OTH-1", "verdict.recorded"} in types(all)
    assert {"FIX-1", "note"} in types(all)
    assert Enum.find(all.entries, &(&1.event.type == "note")).by == %{kind: "run", name: "implementation", run_id: "run-3"}
    refute Enum.find(all.entries, &(&1.event.type == "run.started")).notable
    refute Enum.find(all.entries, &(&1.event.type == "pause.set")).notable

    assert length(read!([]).entries) == 12
  end

  test "since and until bound the window, epic keeps the epic and its sub-tickets, classes keep those classes" do
    fixture_day()

    assert types(read!(since: at(11), until: at(13), notable: false)) == [{"OTH-1", "verdict.recorded"}, {"FIX-2", "question.answered"}]
    assert read!(epic: "FIX-1", since: @morning) |> types() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == ["FIX-1", "FIX-2"]
    assert read!(epic: "FIX-2", since: @morning) |> types() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == ["FIX-2"]
    assert read!(epic: "OTH-9") |> types() == []
    assert read!(classes: ["verdict"], notable: false) |> types() == [{"OTH-1", "verdict.recorded"}, {"FIX-2", "verdict.recorded"}]
    assert read!(repo: @other_repo) |> types() == [{"OTH-1", "verdict.recorded"}]
  end

  test "a page holds limit events, never ends inside one at, and next_until pages to the older ones" do
    for {minute, n} <- [{1, 1}, {2, 2}, {2, 3}, {3, 4}], do: record!("child", "note", %{text: "note #{n}"}, at: at(9, minute))

    first = read!(notable: false, limit: 2)
    assert Enum.map(first.entries, & &1.event.payload.text) == ["note 4", "note 3", "note 2"]
    assert first.next_until == at(9, 2)

    second = read!(notable: false, limit: 2, until: first.next_until)
    assert Enum.map(second.entries, & &1.event.payload.text) == ["note 1"]
    assert second.next_until == nil

    assert length(read!(notable: false, limit: 0).entries) == 4
  end

  test "Symphony's own pause is the factory pausing and an installed release, in every repository but no epic" do
    {:ok, _pause} = Pauses.set(:symphony, Pauses.dispatch_reason("updating to v0.0.1.900"), set_by: %{kind: :symphony, name: "Symphony"}, at: at(7))
    {:ok, nil} = Pauses.clear_reasons(:symphony, &(&1.kind == :build), at: at(7, 5))

    page = read!(repo: @repo)
    assert Enum.map(page.entries, &{&1.event.type, &1.ticket}) == [{"pause.cleared", %{repo_key: nil, identifier: nil, title: nil}}, {"pause.set", %{repo_key: nil, identifier: nil, title: nil}}]
    assert Enum.all?(page.entries, &(&1.by == %{kind: "symphony", name: "Symphony"}))
    assert read!(epic: "FIX-1").entries == []
  end

  test "an event of a ticket with no record names no identifier, and a type no class names is other" do
    {:ok, _event} = TicketEvents.record(@repo, "ghost", "note", %{text: "no record"}, at: at(9))
    :ok = RunStore.delete_ticket_state("ghost")

    assert [%{ticket: %{repo_key: @repo, identifier: nil, title: nil}}] = read!(notable: false).entries
    assert Journal.class("legacy.signal") == "other"
    assert "rule" in Journal.classes()
    refute "other" in Journal.classes()
  end

  test "who did it: a setter's kind as a string, a run's setter, and Symphony's own setter" do
    event = %Event{type: "pause.set", payload: %{set_by: %{"kind" => "rule", "name" => "CI wait"}}}
    assert Journal.by(event) == %{kind: "rule", name: "CI wait"}
    assert Journal.by(%{event | payload: %{set_by: %{kind: :run, name: 7}}}) == %{kind: "run", name: nil}
    assert Journal.by(%{event | payload: %{set_by: %{kind: :symphony, name: "Symphony"}}}) == %{kind: "symphony", name: "Symphony"}
    assert Journal.by(%Event{type: "rule.action", payload: %{rule: :ci_wait}}) == %{kind: "rule", name: "ci_wait"}
  end
end
