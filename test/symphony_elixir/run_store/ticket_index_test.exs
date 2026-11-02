defmodule SymphonyElixir.RunStore.TicketIndexTest do
  # The by-ticket index beside the (repository, ticket) pair key (TP-1337): every write writes both,
  # every read tries the ticket first, and the previous release's reader keeps reading the pair key.
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.TicketEvents.Event
  alias SymphonyElixir.TicketState

  @pair_table :symphony_run_store_ticket_states
  @index_table :symphony_run_store_ticket_index
  @totals_table :symphony_run_store_totals
  @repo_key "repo-a"
  @other_repo_key "repo-b"
  @at ~U[2026-11-02 12:00:00Z]

  setup do
    :ok = RunStore.clear()
    %{issue_id: "issue-#{System.unique_integer([:positive])}"}
  end

  test "a record the previous release wrote is filled into the index on its next read, and the two agree", %{issue_id: issue_id} do
    record = TicketState.new(@repo_key, issue_id, %{issue_identifier: "ACME-1", phase: "QA"})
    write_pair_row(@repo_key, issue_id, record)
    assert index_row(issue_id) == nil

    assert %{phase: "QA", issue_identifier: "ACME-1"} = RunStore.get_ticket_state(@repo_key, issue_id)
    assert {@repo_key, ^record} = index_row(issue_id)
    assert pair_record(@repo_key, issue_id) == record

    # A record nobody has: nothing is filled.
    assert RunStore.get_ticket_state(@repo_key, "issue-none") == nil
    assert index_row("issue-none") == nil
  end

  test "every writer leaves the pair key and the index holding the same record", %{issue_id: issue_id} do
    writers = [
      fn -> RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "Todo"})) end,
      fn -> RunStore.update_ticket_state(@repo_key, issue_id, %{phase: "In Progress"}) end,
      fn -> RunStore.record_ticket_signal(@repo_key, issue_id, "handoff", %{}) end,
      fn -> RunStore.put_ticket_pr_watch(@repo_key, issue_id, "ACME-1", %{pr_url: "https://github.com/acme/app/pull/1", head_sha: "abc"}) end,
      fn -> RunStore.record_ticket_verdict(@repo_key, issue_id, "qa", "abc", "pass") end,
      fn -> RunStore.mark_ticket_projection(@repo_key, issue_id, :phase, :linear_down) end,
      fn -> RunStore.record_ticket_self_heal(@repo_key, issue_id, %{retries: 1}) end,
      fn -> RunStore.record_ticket_decisions(@repo_key, issue_id, [decision()], []) end,
      fn -> RunStore.record_ticket_dispatch(@repo_key, issue_id, %{kind: :rework, run_id: "run-1", state: "Rework", head: "a"}) end,
      fn -> RunStore.record_ticket_dispatch_outcome(@repo_key, issue_id, "run-1", %{exit: "ended normally", head: "a"}) end,
      fn -> RunStore.claim_path_unlocks(@repo_key, issue_id, ["grant-1"], "run-1") end,
      fn -> RunStore.clear_ticket_fix_ticket(@repo_key, issue_id) end,
      fn -> RunStore.record_ci_state(@repo_key, issue_id, "abc", "green", @at) end,
      fn -> RunStore.set_ci_fix_origin(@repo_key, issue_id, "Code Review") end,
      fn -> RunStore.append_ticket_event(event(issue_id)) end,
      fn -> RunStore.update_ticket_pause(@repo_key, issue_id, @at, fn _pause -> {:write, nil, [], :cleared} end) end,
      fn -> RunStore.update_ticket_question(@repo_key, issue_id, @at, &keep_question/2) end
    ]

    for writer <- writers do
      refute match?({:error, _reason}, writer.())
      assert {@repo_key, record} = index_row(issue_id)
      assert pair_record(@repo_key, issue_id) == record
    end

    assert %{phase: "In Progress", signals: [%{name: "handoff"}], ci_fix_origin: "Code Review", event_seq: 1} =
             RunStore.get_ticket_state(@repo_key, issue_id)
  end

  test "a ticket read under another repository keeps its one record and logs the difference once per change",
       %{issue_id: issue_id} do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "QA"}))

    log =
      capture_log(fn ->
        assert %{phase: "QA", repo_key: @repo_key} = RunStore.get_ticket_state(@other_repo_key, issue_id)
        assert %{phase: "QA"} = RunStore.get_ticket_state(@other_repo_key, issue_id)
      end)

    assert count(log, "issue_id=#{issue_id} record_repo_key=#{@repo_key} repo_key=#{@other_repo_key}") == 1

    # An observation routed through the other repository writes the same record, now its field.
    assert :ok = RunStore.record_ticket_signal(@other_repo_key, issue_id, "observed", %{})
    assert {@other_repo_key, record} = index_row(issue_id)
    assert %{phase: "QA", repo_key: @other_repo_key, signals: [%{name: "observed"}]} = record
    assert pair_record(@other_repo_key, issue_id) == record

    log =
      capture_log(fn ->
        assert %{phase: "QA", repo_key: @other_repo_key} = RunStore.get_ticket_state(@repo_key, issue_id)
        assert %{phase: "QA"} = RunStore.get_ticket_state(@repo_key, issue_id)
      end)

    assert count(log, "issue_id=#{issue_id} record_repo_key=#{@other_repo_key} repo_key=#{@repo_key}") == 1
  end

  test "a ticket that moved lists once, through the index, in every listing", %{issue_id: issue_id} do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "QA"}))
    capture_log(fn -> assert :ok = RunStore.record_ticket_signal(@other_repo_key, issue_id, "observed", %{}) end)
    assert %{phase: "QA"} = pair_record(@repo_key, issue_id)

    assert [%{repo_key: @other_repo_key}] = Enum.filter(RunStore.list_all_ticket_states(), &(&1.issue_id == issue_id))
    assert [%{repo_key: @other_repo_key, signals: [%{name: "observed"}]}] = RunStore.list_ticket_states(@other_repo_key)
    assert RunStore.list_ticket_states(@repo_key) == []
    assert RunStore.ticket_record_repositories() == %{issue_id => [@repo_key, @other_repo_key]}
  end

  test "a ticket the store already holds under two repositories is left to the pair key", %{issue_id: issue_id} do
    write_pair_row(@repo_key, issue_id, TicketState.new(@repo_key, issue_id, %{phase: "Done"}))
    write_pair_row(@other_repo_key, issue_id, TicketState.new(@other_repo_key, issue_id, %{phase: "QA"}))

    assert %{phase: "Done"} = RunStore.get_ticket_state(@repo_key, issue_id)
    assert %{phase: "QA"} = RunStore.get_ticket_state(@other_repo_key, issue_id)
    assert :ok = RunStore.record_ticket_signal(@repo_key, issue_id, "stranded", %{})
    assert index_row(issue_id) == nil
    assert %{phase: "Done", signals: [%{name: "stranded"}]} = pair_record(@repo_key, issue_id)

    assert :ok = RunStore.delete_ticket_state(@repo_key, issue_id)
    assert pair_record(@repo_key, issue_id) == nil
    assert %{phase: "QA"} = RunStore.get_ticket_state(@other_repo_key, issue_id)
  end

  test "the previous release's store boots and reads unchanged, and the marker records the index", %{issue_id: issue_id} do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, issue_id, %{phase: "QA"}))

    # The previous release's store: no index table and no marker.
    {:atomic, :ok} = :mnesia.delete_table(@index_table)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.delete({@totals_table, {:marker, RunStore.ticket_index_marker()}}) end)

    restart_run_store()

    assert %DateTime{} = marked = RunStore.get_marker(RunStore.ticket_index_marker())
    assert RunStore.ticket_index_marker() == "ticket_index_v1"
    assert index_row(issue_id) == nil
    assert %{phase: "QA"} = RunStore.get_ticket_state(@repo_key, issue_id)
    assert {@repo_key, %{phase: "QA"}} = index_row(issue_id)

    # The previous release's reader reads the pair row this release wrote, in its own shape.
    :ok = RunStore.update_ticket_state(@repo_key, issue_id, %{phase: "Merging"})

    assert [{@pair_table, {@repo_key, ^issue_id}, @repo_key, ^issue_id, %{phase: "Merging"}}] =
             :mnesia.dirty_read(@pair_table, {@repo_key, issue_id})

    restart_run_store()
    assert RunStore.get_marker(RunStore.ticket_index_marker()) == marked
  end

  defp write_pair_row(repo_key, issue_id, record) do
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({@pair_table, {repo_key, issue_id}, repo_key, issue_id, record}) end)
  end

  defp pair_record(repo_key, issue_id) do
    case :mnesia.dirty_read(@pair_table, {repo_key, issue_id}) do
      [{@pair_table, _key, ^repo_key, ^issue_id, record}] -> record
      [] -> nil
    end
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

  defp event(issue_id) do
    %Event{repo_key: @repo_key, issue_id: issue_id, type: "phase.entered", at: @at}
  end

  defp restart_run_store do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, RunStore) do
      :ok ->
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, RunStore)
        :ok

      {:error, :not_found} ->
        if pid = Process.whereis(RunStore), do: GenServer.stop(pid)
        {:ok, _pid} = GenServer.start(RunStore, [], name: RunStore)
        :ok
    end
  end
end
