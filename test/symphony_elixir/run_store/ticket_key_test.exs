defmodule SymphonyElixir.RunStore.TicketKeyTest do
  # One record per ticket, keyed by its id alone (TP-1339): every reader and writer resolves the
  # record by ticket, the repository is a field on it, and the first start of this release moves a
  # store off the (repository, ticket) key the releases before kept, then deletes that key.
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.TicketState

  @pair_table :symphony_run_store_ticket_states
  @index_table :symphony_run_store_ticket_index
  @events_table :symphony_run_store_ticket_events
  @totals_table :symphony_run_store_totals
  @repo_key "repo-a"
  @other_repo_key "repo-b"
  @at ~U[2026-11-02 12:00:00Z]

  setup do
    :ok = RunStore.clear()
    on_exit(&drop_pair_table/0)
    %{issue_id: "issue-#{System.unique_integer([:positive])}"}
  end

  describe "the by-ticket key" do
    test "every writer writes the ticket's one record, under its id", %{issue_id: issue_id} do
      writers = [
        fn -> RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "Todo"})) end,
        fn -> RunStore.update_ticket_state(issue_id, %{phase: "In Progress"}) end,
        fn -> RunStore.put_ticket_pr_watch(@repo_key, issue_id, "ACME-1", %{pr_url: "https://github.com/acme/app/pull/1", head_sha: "abc"}) end,
        fn -> RunStore.mark_ticket_projection(@repo_key, issue_id, :phase, :linear_down) end,
        fn -> RunStore.record_ticket_self_heal(@repo_key, issue_id, %{retries: 1}) end,
        fn -> RunStore.record_ticket_decisions(@repo_key, issue_id, [decision()], []) end,
        fn -> RunStore.claim_path_unlocks(@repo_key, issue_id, ["grant-1"], "run-1") end,
        fn -> RunStore.clear_ticket_fix_ticket(@repo_key, issue_id) end,
        fn -> RunStore.record_ci_state(@repo_key, issue_id, "abc", "green", @at) end,
        fn -> RunStore.set_ci_fix_origin(@repo_key, issue_id, "Code Review") end,
        fn -> RunStore.append_ticket_event(event(issue_id, @repo_key)) end,
        fn -> RunStore.update_ticket_pause(@repo_key, issue_id, @at, fn _pause -> {:write, nil, [], :cleared} end) end,
        fn -> RunStore.update_ticket_question(@repo_key, issue_id, @at, &keep_question/2) end
      ]

      for writer <- writers do
        refute match?({:error, _reason}, writer.())
        assert {@repo_key, record} = index_row(issue_id)
        assert RunStore.get_ticket_state(issue_id) == record
      end

      refute @pair_table in :mnesia.system_info(:tables)

      assert %{phase: "In Progress", ci_fix_origin: "Code Review", event_seq: 1} =
               RunStore.get_ticket_state(issue_id)

      assert [%Event{seq: 1, repo_key: @repo_key}] = RunStore.list_ticket_events(issue_id, [])

      assert [{@events_table, ^issue_id, @repo_key, ^issue_id, _run, "phase.entered", 1, _record}] =
               :mnesia.dirty_read(@events_table, issue_id)
    end

    test "a writer naming another repository writes the same record, keeps its repository and logs the difference once",
         %{issue_id: issue_id} do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "QA"}))

      log =
        capture_log(fn ->
          assert :ok = RunStore.record_ticket_self_heal(@other_repo_key, issue_id, %{component: "observed"})
          appended = RunStore.append_ticket_events([event(issue_id, @other_repo_key)])
          assert {:ok, [%Event{repo_key: @repo_key, seq: 1}]} = appended
        end)

      assert count(log, "issue_id=#{issue_id} record_repo_key=#{@repo_key} repo_key=#{@other_repo_key}") == 1
      assert {@repo_key, %{phase: "QA", self_heal: %{component: "observed"}, event_seq: 1}} = index_row(issue_id)
      assert [%Event{repo_key: @repo_key}] = RunStore.list_ticket_events(issue_id, [])
    end

    test "the route observation writes moves the one record, its pause and its events to the new repository",
         %{issue_id: issue_id} do
      symphony = %{kind: :symphony, name: "Symphony"}
      reason = %{kind: :question, waits_on: %{question_id: "q-1"}, text: "Which layout?", set_by: symphony, set_at: @at}
      pause = %{subject: {:ticket, @repo_key, issue_id}, reasons: [reason], set_by: reason.set_by, since: @at}
      set = fn nil -> {:write, pause, [event(issue_id, @repo_key)], :set} end
      {:ok, :set, _events} = RunStore.update_ticket_pause(@repo_key, issue_id, @at, set)

      assert :ok = RunStore.update_ticket_state(issue_id, %{repo_key: @other_repo_key, project: %{name: "Hub"}})

      assert {@other_repo_key, %{pause: %{subject: {:ticket, @other_repo_key, ^issue_id}}, event_seq: 1}} =
               index_row(issue_id)

      assert [%Event{seq: 1}] = RunStore.list_ticket_events(issue_id, [])
      assert [%{repo_key: @other_repo_key}] = Enum.filter(RunStore.list_all_ticket_states(), &(&1.issue_id == issue_id))
      assert [%{issue_id: ^issue_id}] = RunStore.list_ticket_states(@other_repo_key)
      assert RunStore.list_ticket_states(@repo_key) == []

      # A write without a route keeps the repository the record has.
      assert :ok = RunStore.update_ticket_state(issue_id, %{phase: "Rework"})
      assert {@other_repo_key, %{phase: "Rework"}} = index_row(issue_id)
    end

    test "a read, an update or a delete names the ticket alone", %{issue_id: issue_id} do
      assert RunStore.get_ticket_state(issue_id) == nil
      assert RunStore.update_ticket_state(issue_id, %{phase: "QA"}) == {:error, :ticket_state_not_found}
      assert RunStore.get_ticket_state(nil) == {:error, :invalid_issue_id}
      assert RunStore.update_ticket_state(nil, %{}) == {:error, :invalid_ticket_state_record}
      assert RunStore.delete_ticket_state(nil) == {:error, :invalid_issue_id}
      assert RunStore.list_ticket_events(nil, []) == {:error, :invalid_issue_id}

      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "QA"}))
      assert RunStore.update_ticket_state(issue_id, %{repo_key: " "}) == {:error, :invalid_repo_key}
      assert {@repo_key, _record} = index_row(issue_id)
      assert :ok = RunStore.delete_ticket_state(issue_id)
      assert RunStore.get_ticket_state(issue_id) == nil
    end
  end

  describe "the start that drops the (repository, ticket) key" do
    test "a store the merge release left boots, moves every ticket off the old key and deletes it; every ticket reads as before" do
      # The merge release's store: TP-1074 merged into its route (the folded repository's copy of its
      # events left behind), a ticket indexed on a read, one never read since the index came, and the
      # events of all three still under the (repository, ticket) key.
      merged = TicketState.new("job-search-hub", "issue-1074", %{issue_identifier: "TP-1074", phase: "In Progress", event_seq: 2})
      folded = TicketState.new("symphony", "issue-1074", %{issue_identifier: "TP-1074", phase: "Todo", event_seq: 1})
      indexed = TicketState.new(@repo_key, "issue-indexed", %{issue_identifier: "ACME-1", phase: "QA", event_seq: 1})
      unindexed = TicketState.new(@other_repo_key, "issue-unindexed", %{issue_identifier: "ACME-2", phase: "Done", event_seq: 1})
      asked = old_event("evt-asked", "symphony", "issue-1074", 1, ~U[2026-10-20 00:00:00Z])

      merge_release_store!(
        [{"job-search-hub", merged}, {"symphony", folded}, {@repo_key, indexed}, {@other_repo_key, unindexed}],
        [merged, indexed],
        [
          %{asked | repo_key: "job-search-hub"},
          old_event("evt-moved", "job-search-hub", "issue-1074", 2, ~U[2026-11-02 00:00:00Z]),
          asked,
          old_event("evt-indexed", @repo_key, "issue-indexed", 1, @at),
          old_event("evt-unindexed", @other_repo_key, "issue-unindexed", 1, @at)
        ]
      )

      before = reads(["issue-1074", "issue-indexed", "issue-unindexed"], %{"issue-unindexed" => unindexed})
      restart_run_store()

      refute @pair_table in :mnesia.system_info(:tables)
      assert %DateTime{} = RunStore.get_marker("ticket_pair_key_dropped_v1")
      assert %DateTime{} = RunStore.get_marker(RunStore.ticket_index_marker())
      assert RunStore.ticket_index_marker() == "ticket_index_v2"
      assert reads(["issue-1074", "issue-indexed", "issue-unindexed"], %{}) == before
      assert :mnesia.dirty_match_object({@events_table, {:_, :_}, :_, :_, :_, :_, :_, :_}) == []

      # A start after it has nothing to move.
      restart_run_store()
      assert reads(["issue-1074", "issue-indexed", "issue-unindexed"], %{}) == before
    end

    test "an event only another repository's key held is kept once, numbered after the ticket's last" do
      record = TicketState.new(@repo_key, "issue-1", %{event_seq: 1})
      stray = old_event("evt-stray", @other_repo_key, "issue-1", 1, ~U[2026-11-02 13:00:00Z])
      own = old_event("evt-own", @repo_key, "issue-1", 1, @at)
      orphan = old_event("evt-orphan", @other_repo_key, "issue-orphan", 4, @at)

      merge_release_store!([{@repo_key, record}], [record], [own, stray, orphan])
      assert RunStore.contract_ticket_key() == :ok

      assert [%Event{id: "evt-own", seq: 1}, %Event{id: "evt-stray", seq: 2}] = RunStore.list_ticket_events("issue-1", [])
      assert %{event_seq: 2, repo_key: @repo_key} = RunStore.get_ticket_state("issue-1")
      assert [%Event{id: "evt-orphan", seq: 4}] = RunStore.list_ticket_events("issue-orphan", [])
    end

    test "a store from before the merge release is refused with the version to install first, and nothing is written" do
      record = TicketState.new(@repo_key, "issue-1", %{phase: "QA"})

      for markers <- [[], ["ticket_index_v1"]] do
        merge_release_store!([{@repo_key, record}], [], [], markers)

        log = capture_log(fn -> assert {:error, {:store_not_merged, _message}} = RunStore.contract_ticket_key() end)

        assert log =~ "Install Symphony 0.0.1.792 first"
        assert log =~ "records_merged_v1"
        assert @pair_table in :mnesia.system_info(:tables)
        assert index_row("issue-1") == nil
        assert RunStore.get_marker("ticket_pair_key_dropped_v1") == nil
        drop_pair_table()
      end
    end

    test "a start on a store the merge never ran on stops with the version to install first" do
      merge_release_store!([{@repo_key, TicketState.new(@repo_key, "issue-1")}], [], [], [])
      stop_run_store()

      log =
        capture_log(fn ->
          assert {:error, {:store_not_merged, message}} = GenServer.start(RunStore, [])
          assert message =~ "Install Symphony 0.0.1.792 first"
        end)

      assert log =~ "0.0.1.792"
      drop_pair_table()
      :ok = start_run_store()
    end

    test "a ticket the merge left under two repositories with none its one record refuses the start" do
      merge_release_store!([{@repo_key, TicketState.new(@repo_key, "issue-1")}, {@other_repo_key, TicketState.new(@other_repo_key, "issue-1")}], [], [])

      assert {:error, {:store_not_merged, message}} = RunStore.contract_ticket_key()
      assert message =~ "issue-1 still has records under several repositories"
      assert @pair_table in :mnesia.system_info(:tables)
    end

    test "a table that does not load in time, or fails to, stops the start" do
      merge_release_store!([{@repo_key, TicketState.new(@repo_key, "issue-1")}], [], [])

      answers = [{{:timeout, [@pair_table]}, {:mnesia_table_timeout, [@pair_table]}}, {{:error, :bad_disk}, :bad_disk}]

      for {answer, reason} <- answers do
        Application.put_env(:symphony_elixir, :run_store_wait_for_tables, fn [@pair_table], _timeout -> answer end)
        assert RunStore.contract_ticket_key() == {:error, reason}
      end
    after
      Application.delete_env(:symphony_elixir, :run_store_wait_for_tables)
    end
  end

  # The merge release's store: its (repository, ticket) rows, the records its index held, its events
  # under the (repository, ticket) key, and its markers.
  defp merge_release_store!(rows, indexed, events, markers \\ ["ticket_index_v1", "records_merged_v1"]) do
    {:atomic, :ok} =
      :mnesia.create_table(@pair_table,
        attributes: [:key, :repo_key, :issue_id, :record],
        disc_copies: [node()],
        index: [:repo_key, :issue_id]
      )

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        for {repo_key, record} <- rows, do: :mnesia.write({@pair_table, {repo_key, record.issue_id}, repo_key, record.issue_id, record})
        for record <- indexed, do: :mnesia.write({@index_table, record.issue_id, record.repo_key, record})

        for event <- events,
            do: :mnesia.write({@events_table, {event.repo_key, event.issue_id}, event.repo_key, event.issue_id, event.run_id, event.type, event.seq, Event.to_record(event)})

        for name <- markers, do: :mnesia.write({@totals_table, {:marker, name}, @at})
        :mnesia.delete({@totals_table, {:marker, RunStore.ticket_index_marker()}})
        :ok
      end)
  end

  # What a reader sees of each ticket: its record and its events. Before the start, the merge
  # release read an unindexed ticket through its (repository, ticket) row (`pair`), and its events
  # under the record's repository.
  defp reads(issue_ids, pair) do
    Map.new(issue_ids, fn issue_id ->
      record = Map.get(pair, issue_id) || RunStore.get_ticket_state(issue_id)
      {issue_id, {TicketState.normalize(record), old_or_new_events(record.repo_key, issue_id)}}
    end)
  end

  defp old_or_new_events(repo_key, issue_id) do
    case :mnesia.dirty_read(@events_table, {repo_key, issue_id}) do
      [] -> RunStore.list_ticket_events(issue_id, [])
      rows -> rows |> Enum.map(&Event.normalize(elem(&1, 7))) |> Enum.sort_by(&{DateTime.to_unix(&1.at), &1.seq})
    end
  end

  defp old_event(id, repo_key, issue_id, seq, at) do
    %Event{id: id, repo_key: repo_key, issue_id: issue_id, type: "phase.entered", at: at, seq: seq, payload: %{to: "QA"}}
  end

  defp drop_pair_table do
    _ = :mnesia.delete_table(@pair_table)
    :ok
  end

  defp index_row(issue_id) do
    case :mnesia.dirty_read(@index_table, issue_id) do
      [{@index_table, ^issue_id, repo_key, record}] -> {repo_key, record}
      [] -> nil
    end
  end

  defp keep_question(_questions, pause), do: {:write, %{}, pause, [], :kept}

  defp count(log, fragment), do: log |> String.split(fragment) |> length() |> Kernel.-(1)

  defp decision, do: %{key: "comment-1", date: ~D[2026-11-02], title: "Keep it", question: "Keep it?", answer: "Yes", scope: "As answered"}

  defp event(issue_id, repo_key) do
    %Event{repo_key: repo_key, issue_id: issue_id, type: "phase.entered", at: @at}
  end

  defp restart_run_store do
    stop_run_store()
    start_run_store()
  end

  defp stop_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok -> :ok
      {:error, :not_found} -> if pid = Process.whereis(RunStore), do: GenServer.stop(pid), else: :ok
    end
  end

  defp start_run_store do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore) do
      {:ok, _pid} -> :ok
      {:error, :not_found} -> with({:ok, _pid} <- GenServer.start(RunStore, [], name: RunStore), do: :ok)
    end
  end
end
