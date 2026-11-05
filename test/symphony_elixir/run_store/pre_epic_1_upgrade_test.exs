defmodule SymphonyElixir.RunStore.PreEpic1UpgradeTest do
  # TP-1423: a Symphony from before epic 1 upgrades straight to this release. The store on disk is
  # the one its own writers left (`test/fixtures/run_store/write_pre_epic_1_store.exs`), with no
  # marker and no event: it starts, moves off the (repository, ticket) key, and backfills, and every
  # ticket's verdicts, signals and dispatches read as the old fields held them.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TicketEvents.Backfill
  alias SymphonyElixir.TicketState

  @fixture "test/fixtures/run_store/pre_epic_1"
  @pair_table :symphony_run_store_ticket_states

  test "a store its own writers left before epic 1 starts, backfills and reads as it did" do
    original_run_store_dir = Application.fetch_env!(:symphony_elixir, :run_store_dir)
    dir = Path.join(System.tmp_dir!(), "symphony-pre-epic-1-#{System.unique_integer([:positive])}")
    trap_exit? = Process.flag(:trap_exit, true)
    File.cp_r!(@fixture, dir)

    try do
      :ok = Application.stop(:symphony_elixir)
      stop_store()

      assert {:ok, _pid} = RunStore.start_link(dir: dir)

      refute @pair_table in :mnesia.system_info(:tables)
      assert %DateTime{} = RunStore.get_marker("ticket_pair_key_dropped_v1")
      assert %DateTime{} = RunStore.get_marker(RunStore.ticket_index_marker())

      # The ticket that moved between projects is one record, under the repository that saw it last.
      assert %{checked: 5, merged: 1, withdrawn: 0, merges: [%{issue_id: "issue-5", repo_key: "other-repo", folded: ["symphony"]}]} =
               RunStore.get_report(RunStore.records_merged_marker())

      assert {:ok, %{tickets: 5}} = Backfill.run(audit_log: [dir: Path.join(dir, "no-audit-log")])
      assert %DateTime{} = RunStore.get_marker(Backfill.marker())

      for {issue_id, phase} <- [{"issue-1", "Done"}, {"issue-2", "QA"}, {"issue-3", "In Progress"}, {"issue-4", "Rework"}] do
        record = RunStore.get_ticket_state(issue_id)
        head = "abc" <> issue_id

        assert %{phase: ^phase, repo_key: "symphony"} = record
        assert %{signals: [], verdicts: [], dispatches: []} = TicketState.legacy_history(record)
        assert [%{name: "handoff", details: %{head: ^head}}] = TicketState.signals(record)
        assert [%{kind: "code_review", head_sha: ^head, outcome: "approve"}] = TicketState.verdicts(record)
        assert [%{run_id: run_id}] = TicketState.dispatches(record)
        assert run_id == "run-" <> issue_id
      end

      moved = RunStore.get_ticket_state("issue-5")
      assert %{phase: "QA", repo_key: "other-repo", issue_identifier: "ACME-5"} = moved
      assert [%{details: %{head: "new"}}, %{details: %{head: "old"}}] = TicketState.signals(moved)
      assert [%{kind: "code_review", head_sha: "new", outcome: "approve"}] = TicketState.verdicts(moved)

      # A second start finds nothing to move, and every ticket still reads the same.
      stop_store()
      assert {:ok, _pid} = RunStore.start_link(dir: dir)
      assert %{phase: "QA"} = RunStore.get_ticket_state("issue-5")
      assert length(RunStore.list_all_ticket_states()) == 5
    after
      stop_store()
      File.rm_rf(dir)
      Application.put_env(:symphony_elixir, :run_store_dir, original_run_store_dir)
      ensure_symphony_started!()
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  defp stop_store do
    if pid = Process.whereis(RunStore) do
      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    _ = :mnesia.stop()
  end
end
