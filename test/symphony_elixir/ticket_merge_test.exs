defmodule SymphonyElixir.TicketMergeTest do
  # The one-time merge of a ticket's records left under more than one repository (TP-1338).
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Inbox, TicketMerge, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @pair_table :symphony_run_store_ticket_states
  @index_table :symphony_run_store_ticket_index
  @now ~U[2026-11-03 09:00:00.000000Z]
  @asked_old ~U[2026-10-20 10:00:00.000000Z]
  @asked_new ~U[2026-11-02 10:00:00.000000Z]
  @symphony %{kind: :symphony, name: "Symphony"}

  # A store whose answers a test sets in the process dictionary; the rest is the real store's.
  defmodule StubStore do
    alias SymphonyElixir.RunStore

    def get_marker(name), do: stub(:stub_marker, fn -> RunStore.get_marker(name) end)
    def get_report(name), do: stub(:stub_report, fn -> RunStore.get_report(name) end)
    def ticket_record_repositories, do: stub(:stub_repositories, &RunStore.ticket_record_repositories/0)
    def merge_ticket_records(issue_id, fun), do: stub(:stub_merge, fn -> RunStore.merge_ticket_records(issue_id, fun) end)
    def put_marker_with_report(name, at, report), do: stub(:stub_put, fn -> RunStore.put_marker_with_report(name, at, report) end)

    defp stub(key, real), do: if(Process.get(key) == nil, do: real.(), else: Process.get(key))
  end

  setup do
    :ok = RunStore.clear()
    TicketMerge.reset()
    on_exit(fn -> TicketMerge.reset() end)
    %{issue_id: "issue-#{System.unique_integer([:positive])}"}
  end

  describe "TP-1074, left under symphony and job-search-hub" do
    setup %{issue_id: issue_id} do
      old = question("q-old", "Move TP-1074 to Job Search Hub?", @asked_old)
      new = question("q-new", "Ship the QA fixtures?", @asked_new)

      write_pair_row("symphony", issue_id, %{
        issue_identifier: "TP-1074",
        phase: "In Progress",
        phase_at: @asked_old,
        observed_at: @asked_old,
        linear_updated_at: @asked_old,
        project: %{id: "p-symphony", name: "Symphony", slug_id: "symphony"},
        updated_at: @asked_old,
        questions: [old],
        pause: pause("symphony", issue_id, ["q-old"], @asked_old)
      })

      write_pair_row("job-search-hub", issue_id, %{
        issue_identifier: "TP-1074",
        phase: "Rework",
        phase_at: @asked_new,
        observed_at: @asked_new,
        linear_updated_at: @asked_new,
        project: %{id: "p-hub", name: "Job Search Hub", slug_id: "hub"},
        updated_at: @asked_new,
        questions: [new],
        pause: pause("job-search-hub", issue_id, ["q-new"], @asked_new)
      })

      append("symphony", issue_id, ~U[2026-10-20 09:00:00Z])
      append("symphony", issue_id, ~U[2026-10-20 10:00:00Z])
      append("job-search-hub", issue_id, ~U[2026-11-02 10:00:00Z])
      :ok
    end

    test "the first boot leaves one record under job-search-hub with both questions, the old one withdrawn", %{issue_id: issue_id} do
      projected = self()
      assert {:ok, report} = run(project: &send(projected, {:projected, &1}))

      assert %{name: "records.merged", at: @now, checked: 1, merged: 1, withdrawn: 1} = report
      assert report.merges == [%{issue_id: issue_id, issue_identifier: "TP-1074", repo_key: "job-search-hub", folded: ["symphony"]}]
      assert_received {:projected, {:ticket, "job-search-hub", ^issue_id}}

      record = RunStore.get_ticket_state("job-search-hub", issue_id)
      assert %{repo_key: "job-search-hub", phase: "Rework", project: %{slug_id: "hub"}, event_seq: 4} = record
      assert [%{id: "q-old", state: :withdrawn, withdrawn: %{at: @now}}, %{id: "q-new", state: :open}] = record.questions
      assert [%{waits_on: %{question_id: "q-new"}}] = record.pause.reasons

      # Every reader reaches the merged record, whichever repository it names.
      assert capture_log(fn -> assert RunStore.get_ticket_state("symphony", issue_id) == record end) =~ "record_repo_key=job-search-hub"
      assert [^record] = Enum.filter(RunStore.list_all_ticket_states(), &(&1.issue_id == issue_id))
      assert RunStore.list_ticket_states("symphony") == []

      events = RunStore.list_ticket_events("job-search-hub", issue_id, [])
      assert Enum.map(events, & &1.seq) == [1, 2, 3, 4]
      assert %Event{type: "question.withdrawn", phase: "Rework", payload: %{question_id: "q-old", cause: "superseded_by_move"}} = List.last(events)

      # The Inbox shows the ticket once: its open question.
      settings_fun = fn _repo_key -> {:ok, %Schema{}} end
      assert [%{issue_id: ^issue_id}] = Enum.filter(Inbox.rows(settings_fun: settings_fun), &(&1.issue_id == issue_id))

      # The record left under symphony stays where it was.
      assert %{questions: [%{id: "q-old", state: :open}]} = pair_record("symphony", issue_id)
    end

    test "a second boot changes nothing", %{issue_id: issue_id} do
      assert {:ok, report} = run()
      merged = RunStore.get_ticket_state("job-search-hub", issue_id)
      events = RunStore.list_ticket_events("job-search-hub", issue_id, [])

      assert run() == {:ok, :already_merged}
      assert RunStore.get_ticket_state("job-search-hub", issue_id) == merged
      assert RunStore.list_ticket_events("job-search-hub", issue_id, []) == events
      assert TicketMerge.report() == report
    end

    test "a merge run again, before the marker was set, writes the same record and events", %{issue_id: issue_id} do
      assert {:ok, _report} = run()
      merged = RunStore.get_ticket_state("job-search-hub", issue_id)
      events = RunStore.list_ticket_events("job-search-hub", issue_id, [])

      assert {:ok, %{withdrawn: []}} = RunStore.merge_ticket_records(issue_id, &TicketMerge.merge(issue_id, &1, @now))
      assert RunStore.get_ticket_state("job-search-hub", issue_id) == merged
      assert RunStore.list_ticket_events("job-search-hub", issue_id, []) == events
    end
  end

  test "a store with no duplicates reports zero merges and changes nothing", %{issue_id: issue_id} do
    :ok = RunStore.put_ticket_state(TicketState.new("repo-a", issue_id, %{phase: "QA"}))
    :ok = RunStore.put_ticket_state(TicketState.new("repo-b", "#{issue_id}-other", %{phase: "Todo"}))
    before = RunStore.list_all_ticket_states()

    assert {:ok, %{checked: 2, merged: 0, merges: [], withdrawn: 0}} = run()
    assert RunStore.list_all_ticket_states() == before
    assert %DateTime{} = RunStore.get_marker(TicketMerge.marker())
  end

  test "three records of one ticket merge to one, every event once and in order", %{issue_id: issue_id} do
    for {repo_key, at} <- [{"repo-a", ~U[2026-10-01 00:00:00Z]}, {"repo-b", ~U[2026-10-10 00:00:00Z]}, {"repo-c", ~U[2026-10-05 00:00:00Z]}] do
      attrs = %{
        issue_identifier: "ACME-3",
        observed_at: at,
        updated_at: at,
        decisions: [decision(repo_key)],
        path_unlocks: [%{id: "grant-1", run_id: "run-1", at: at}],
        pending_projection: [%{type: :phase, error: "linear down", at: at}]
      }

      write_pair_row(repo_key, issue_id, attrs)
    end

    times = %{
      "repo-a" => [~U[2026-10-01 01:00:00Z], ~U[2026-10-06 01:00:00Z]],
      "repo-b" => [~U[2026-10-02 01:00:00Z], ~U[2026-10-08 01:00:00Z], ~U[2026-10-11 01:00:00Z]],
      "repo-c" => [~U[2026-10-04 01:00:00Z]]
    }

    for {repo_key, ats} <- times, at <- ats, do: append(repo_key, issue_id, at)
    stored = Enum.flat_map(times, fn {repo_key, _ats} -> RunStore.list_ticket_events(repo_key, issue_id, []) end)

    assert {:ok, %{merged: 1, merges: [%{repo_key: "repo-b", folded: ["repo-a", "repo-c"]}]}} = run()

    events = RunStore.list_ticket_events("repo-b", issue_id, [])
    assert length(events) == length(stored)
    assert Enum.map(events, & &1.id) == stored |> Enum.sort_by(&DateTime.to_unix(&1.at)) |> Enum.map(& &1.id)
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..6)
    assert Enum.all?(events, &(&1.repo_key == "repo-b"))

    assert %{event_seq: 6, decisions: decisions, path_unlocks: [%{id: "grant-1"}], pending_projection: [_one, _two, _three]} =
             RunStore.get_ticket_state("repo-b", issue_id)

    assert Enum.map(decisions, & &1.key) == ["d-repo-a", "d-repo-c", "d-repo-b"]
  end

  test "an indexed record is the route, and same-text open questions collapse to the route's", %{issue_id: issue_id} do
    same = question("q-a", "Same ask?", @asked_old)
    pause_a = pause("repo-a", issue_id, ["q-a"], @asked_old)
    write_pair_row("repo-a", issue_id, %{observed_at: @asked_new, updated_at: @asked_old, questions: [same], pause: pause_a})

    write_pair_row("repo-b", issue_id, %{
      observed_at: @asked_old,
      updated_at: @asked_new,
      questions: [%{same | id: "q-b", asked_at: @asked_new}, question("q-done", "Done?", @asked_old, :answered)],
      pause: pause("repo-b", issue_id, ["q-b"], @asked_new)
    })

    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({@index_table, issue_id, "repo-b", pair_record("repo-b", issue_id)}) end)

    assert {:ok, %{merges: [%{repo_key: "repo-b", folded: ["repo-a"]}], withdrawn: 0}} = run()

    assert %{questions: [%{id: "q-done"}, %{id: "q-b", state: :open}], pause: %{reasons: [_q_b]}} =
             RunStore.get_ticket_state("repo-b", issue_id)
  end

  test "the artifacts of a folded record's events list the merged ticket", %{issue_id: issue_id} do
    write_pair_row("repo-a", issue_id, %{observed_at: @asked_old})
    write_pair_row("repo-b", issue_id, %{observed_at: @asked_new})
    artifact = %{id: "art-1", repo_key: "repo-a", issue_id: issue_id, tickets: [%{repo_key: "repo-a", issue_id: issue_id}]}
    :ok = RunStore.put_artifact(artifact)
    # An event written without an id is still kept once.
    {:ok, _event} = RunStore.append_ticket_event(%{event("repo-a", issue_id, @asked_old) | id: nil, artifacts: ["art-1", "art-gone"]})

    assert {:ok, %{merged: 1}} = run()
    assert %{tickets: [%{repo_key: "repo-a"}, %{repo_key: "repo-b", issue_id: ^issue_id}]} = RunStore.get_artifact("art-1")
    assert [%{id: nil, seq: 1}] = RunStore.list_ticket_events("repo-b", issue_id, [])
    assert {:ok, %{events: [_once]}} = RunStore.merge_ticket_records(issue_id, &TicketMerge.merge(issue_id, &1, @now))
  end

  test "a ticket that no longer has two records at its merge is skipped", %{issue_id: issue_id} do
    assert RunStore.merge_ticket_records(issue_id, &TicketMerge.merge(issue_id, &1, @now)) == {:ok, :skip}
    Process.put(:stub_repositories, %{issue_id => ["repo-a", "repo-b"]})
    assert {:ok, %{checked: 1, merged: 0}} = run(store: StubStore)
  end

  describe "a failure leaves the marker unset for the next start" do
    test "a failed read of the records is reported and retried" do
      Process.put(:stub_repositories, {:error, :unreadable})
      log = capture_log(fn -> assert run(store: StubStore) == {:error, :unreadable} end)

      assert log =~ "the next start retries"
      assert RunStore.get_marker(TicketMerge.marker()) == nil
      assert %{name: "records.merged", at: @now, error: ":unreadable"} = TicketMerge.report()

      assert {:ok, %{checked: 0}} = run()
      assert %{checked: 0, merged: 0} = TicketMerge.report()
    end

    test "a failed merge or marker write, and an unreadable marker, are returned", %{issue_id: issue_id} do
      Process.put(:stub_repositories, %{issue_id => ["repo-a", "repo-b"]})
      Process.put(:stub_merge, {:error, :aborted})
      capture_log(fn -> assert run(store: StubStore) == {:error, {:merge_failed, issue_id, :aborted}} end)

      Process.delete(:stub_merge)
      Process.put(:stub_repositories, %{})
      Process.put(:stub_put, {:error, :disk_full})
      capture_log(fn -> assert run(store: StubStore) == {:error, :disk_full} end)

      Process.put(:stub_marker, {:error, :no_store})
      capture_log(fn -> assert run(store: StubStore) == {:error, :no_store} end)
      assert RunStore.get_marker(TicketMerge.marker()) == nil
    end
  end

  test "the boot starts the merge in a task, unless it is turned off" do
    assert TicketMerge.start(enabled: false) == :disabled

    capture_log(fn ->
      assert {:ok, pid} = TicketMerge.start(enabled: true, now: @now)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end)

    assert %DateTime{} = RunStore.get_marker(TicketMerge.marker())
    assert capture_log(fn -> assert {:error, _reason} = TicketMerge.start(enabled: true, supervisor: :no_such_supervisor) end) =~ "Failed to start"
  end

  test "merge/3 skips a ticket with one record" do
    assert TicketMerge.merge("issue-1", [%{repo_key: "repo-a", record: TicketState.new("repo-a", "issue-1"), events: [], indexed: false}], @now) == :skip
  end

  defp run(opts \\ []) do
    {result, _log} = with_log(fn -> TicketMerge.run(Keyword.merge([now: @now, project: fn _ticket -> :ok end], opts)) end)
    result
  end

  defp question(id, title, asked_at, state \\ :open) do
    asked_by = %{kind: :symphony, name: "Symphony", run_id: nil}
    %{id: id, title: title, question: title, state: state, asked_at: asked_at, asked_by: asked_by, options: []}
  end

  defp pause(repo_key, issue_id, question_ids, at) do
    reasons =
      for id <- question_ids do
        %{kind: :question, waits_on: %{question_id: id}, text: "Waiting", set_by: @symphony, set_at: at, releasable: false}
      end

    %{subject: {:ticket, repo_key, issue_id}, reasons: reasons, set_by: @symphony, since: at}
  end

  defp decision(repo_key), do: %{key: "d-#{repo_key}", date: ~D[2026-10-01], title: "Keep it", question: "Keep it?", answer: "Yes", scope: "As answered"}

  defp write_pair_row(repo_key, issue_id, attrs) do
    record = TicketState.new(repo_key, issue_id, attrs)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({@pair_table, {repo_key, issue_id}, repo_key, issue_id, record}) end)
  end

  defp pair_record(repo_key, issue_id) do
    [{@pair_table, _key, ^repo_key, ^issue_id, record}] = :mnesia.dirty_read(@pair_table, {repo_key, issue_id})
    record
  end

  defp append(repo_key, issue_id, at) do
    {:ok, _event} = RunStore.append_ticket_event(event(repo_key, issue_id, at))
  end

  defp event(repo_key, issue_id, at), do: %Event{id: Event.ulid(at), repo_key: repo_key, issue_id: issue_id, type: "phase.entered", at: at}
end
