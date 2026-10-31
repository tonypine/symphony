defmodule SymphonyElixir.TicketEvents.BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AuditLog, TicketEvents}
  alias SymphonyElixir.TicketEvents.Backfill

  @repo_key "repo-a"
  @issue_id "issue-1"
  @base ~U[2026-10-18 10:00:00.000000Z]
  @now ~U[2026-10-20 12:00:00.000000Z]
  @director {:person, "the Director"}

  # The run store, with the failures and the marker reads a test asks for in its process.
  defmodule Store do
    @moduledoc false
    alias SymphonyElixir.RunStore

    def get_marker(name), do: fail(:get_marker) || if(Process.get(:ignore_marker), do: nil, else: RunStore.get_marker(name))
    def put_marker(name, at), do: fail(:put_marker) || RunStore.put_marker(name, at)
    def list_all_ticket_states, do: fail(:list_all_ticket_states) || RunStore.list_all_ticket_states()
    def list_ticket_events(repo_key, issue_id, opts), do: fail(:list_ticket_events) || RunStore.list_ticket_events(repo_key, issue_id, opts)
    def append_ticket_events(events), do: fail(:append_ticket_events) || RunStore.append_ticket_events(events)

    defp fail(name), do: if(name in Process.get(:fail, []), do: {:error, {:failed, name}})
  end

  setup do
    :ok = RunStore.clear()
    dir = Path.join(System.tmp_dir!(), "backfill-audit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{audit: [dir: dir]}
  end

  describe "run/1" do
    test "converts a ticket's history oldest first, ends it with the backfill note, and runs once", %{audit: audit} do
      put_ticket(%{
        phase: "QA",
        signals: [
          signal(10, "decision requested", %{hold: "needs_decision", reason: 42}),
          signal(1, "claim", %{from: "Todo", to: "In Progress"}),
          signal(2, "handoff", %{head: "aaa1111", pr_url: "https://github.com/acme/app/pull/1"}),
          signal(3, "handoff", %{head: "aaa1111"}),
          signal(4, "blocked", %{reason: "waiting on TP-1", held: true}),
          signal(5, "unblocked", %{by: :operator}),
          signal(6, "dispatch_loop", %{kind: "implementation", count: 3, window_ms: 1_000}),
          signal(7, "ci_wait_started", %{sha: "aaa1111"}),
          signal(8, "code_review", %{signal: "merge_confirmation", reason: "ready to merge"}),
          signal(9, "decision returned", %{move: "decide", from: "QA", to: "QA"}),
          %{name: "claim", details: %{to: "QA"}, at: nil}
        ],
        verdicts: [
          %{kind: "qa", head_sha: "aaa1111", outcome: "pass", recorded_at: at(11)},
          %{kind: "bogus", head_sha: nil, outcome: "pass", recorded_at: at(12)}
        ],
        dispatches: [
          %{kind: "implementation", run_id: "run-1", state: "In Progress", at: at(13), outcome: %{exit: "handoff", head: "aaa1111", at: at(14)}},
          %{kind: "implementation", run_id: "run-2", state: "In Progress", at: at(15), outcome: %{exit: "", at: at(16)}},
          %{kind: "code_review", run_id: nil, at: at(15)},
          %{kind: "qa", run_id: "run-3", at: nil, outcome: %{exit: "ended normally", at: at(17)}},
          %{kind: "qa", run_id: "run-4", state: "QA", at: at(17)}
        ]
      })

      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key, issue_id: @issue_id}, at(18))
      audit!(audit, move("rework", %{from_state: "QA", to_state: "Rework"}), at(19))
      audit!(audit, move("unblock", %{from_state: "QA", to_state: "QA"}), at(20))
      audit!(audit, move("decide", %{}), at(21))
      audit!(audit, %{event_type: "director_move", move: "rework", repo_key: "repo-b", issue_id: @issue_id}, at(22))
      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key, issue_id: @issue_id}, DateTime.add(@now, -20, :day))
      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key, issue_id: "issue-unknown"}, at(18))
      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key}, at(18))

      log = capture_log(fn -> assert {:ok, %{tickets: 1, events: 14}} = Backfill.run(now: @now, audit_log: audit) end)
      assert log =~ "Skipped a backfilled verdict.recorded event"

      events = events()

      assert Enum.map(events, & &1.type) == [
               "phase.entered",
               "attempt.pushed",
               "note",
               "verdict.recorded",
               "run.started",
               "run.ended",
               "run.started",
               "run.ended",
               "run.ended",
               "run.started",
               "person.action",
               "person.action",
               "person.action",
               "note"
             ]

      assert events |> Enum.map(& &1.at) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) != :gt end)
      assert Enum.all?(events, &String.starts_with?(&1.idempotency, "backfill:"))
      assert Enum.all?(events, &is_binary(&1.summary.title))
      assert Enum.map(events, & &1.seq) == Enum.to_list(1..14)

      [entered, pushed, waiting, verdict | runs] = events
      [started, ended, started2, ended2, ended3, started4, stop, rework, unblock, note] = runs

      assert %{at: at1, phase: "In Progress", payload: %{to: "In Progress", from: "Todo", signal: "claim"}} = entered
      assert at1 == at(1)
      assert %{payload: %{head: "aaa1111", attempt: 1, pr_url: "https://github.com/acme/app/pull/1"}, head_sha: "aaa1111"} = pushed
      assert waiting.payload.text =~ "Waiting for CI"
      assert %{phase: "QA", payload: %{kind: "qa", outcome: "pass", head: "aaa1111"}} = verdict
      assert %{run_id: "run-1", phase: "In Progress", payload: %{run_kind: "implementation", run_number: 1, state: "In Progress"}} = started
      assert %{run_id: "run-1", payload: %{exit: "handoff", run_number: 1, duration_ms: 60_000, head: "aaa1111"}} = ended
      assert %{payload: %{run_id: "run-2", run_number: 2}} = started2
      assert %{payload: %{run_id: "run-2", run_number: 2, exit: "ended"}} = ended2
      assert ended3.payload == %{run_id: "run-3", run_kind: "qa", exit: "ended normally"}
      assert %{payload: %{run_id: "run-4", run_kind: "qa", run_number: 1}} = started4
      assert %{actor: %{kind: :person, name: "the Director"}, payload: %{action: "stop"}, at: at18} = stop
      assert at18 == at(18)
      assert rework.payload == %{action: "move", move: "rework", from: "QA", to: "Rework"}
      assert unblock.payload == %{action: "unblock", from: "QA", to: "QA"}
      assert %{at: @now, idempotency: "backfill:note:history", payload: %{text: "History before 2026-10-20 12:00 UTC was backfilled from the ticket's snapshot"}} = note

      assert {:ok, %{tickets: 0, events: 0}} = Backfill.run(now: @now, audit_log: audit)
      assert RunStore.get_marker(Backfill.marker()) == @now

      Process.put(:ignore_marker, true)
      assert {:ok, %{tickets: 0, events: 0}} = Backfill.run(now: DateTime.add(@now, 1, :day), audit_log: audit, store: Store)
      assert events() == events
    end

    test "a ticket without a record yields nothing", %{audit: audit} do
      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key, issue_id: @issue_id}, at(1))

      assert {:ok, %{tickets: 0, events: 0}} = Backfill.run(now: @now, audit_log: audit)
      assert events() == []
    end

    test "a ticket with live events backfills only what came before its first live event", %{audit: audit} do
      put_ticket(%{signals: [signal(1, "claim", %{to: "In Progress"}), signal(3, "claim", %{to: "QA"})]})
      {:ok, live} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "live"}, at: at(2))
      audit!(audit, %{event_type: "run_stopped", repo_key: @repo_key, issue_id: @issue_id}, at(4))

      assert {:ok, %{tickets: 1, events: 2}} = Backfill.run(now: @now, audit_log: audit)

      assert [%{type: "phase.entered", payload: %{to: "In Progress"}}, note, ^live] = events()
      assert note.at == DateTime.add(at(2), -1, :microsecond)
      assert note.payload.text == "History before 2026-10-18 10:02 UTC was backfilled from the ticket's snapshot"
    end

    test "recorded decisions are the Director's answers, and an answer recorded live is not recorded again", %{audit: audit} do
      put_ticket(%{
        updated_at: at(30),
        decisions: [
          decision("c-1", ~D[2026-10-10], "Ship it"),
          decision("c-2", ~D[2026-10-11], "Wait"),
          decision("c-3", "sometime", "Defer to TP-9")
        ]
      })

      {:ok, _live} =
        TicketEvents.record(@repo_key, @issue_id, "decision.recorded", %{answer: "Ship it", key: "c-1", title: "c-1"}, actor: @director, at: at(5))

      assert {:ok, %{tickets: 1, events: 3}} = Backfill.run(now: @now, audit_log: audit)

      recorded = events(types: ["decision.recorded"])
      assert Enum.map(recorded, & &1.payload.key) == ["c-2", "c-1", "c-3"]
      assert Enum.map(recorded, & &1.idempotency) == ["decision.recorded:c-2", "decision.recorded:c-1", "decision.recorded:c-3"]
      assert Enum.all?(recorded, &(&1.actor == %{kind: :person, name: "the Director"}))
      assert [%{at: c2_at, summary: %{title: "The Director ruled"}} = c2, _c1, %{at: c3_at}] = recorded
      refute Map.has_key?(c2.payload, :request)
      assert c2_at == ~U[2026-10-11 00:00:00Z]
      assert c3_at == at(30)
    end

    test "a hold's or a decision request's signal is no event, and the record's decisions are still the Director's answers", %{audit: audit} do
      put_ticket(%{
        signals: [
          signal(1, "decision requested", %{question: true, reason: :dependency_source_requires_approval}),
          signal(2, "blocked", %{reason: "waits on TP-1", held: true}),
          signal(3, "unblocked", %{by: :operator}),
          signal(4, "qa", %{signal: "code_review_escalate", reason: "needs a person"})
        ],
        decisions: [decision("c-1", ~D[2026-10-17], "Keep the old copy")]
      })

      assert {:ok, %{tickets: 1, events: 2}} = Backfill.run(now: @now, audit_log: audit)

      assert Enum.map(events(), & &1.type) == ["decision.recorded", "note"]
      assert events(types: ["hold.set", "hold.cleared", "decision.requested"]) == []
      assert [%{payload: %{text: "History before " <> _}}] = events(types: ["note"])
      assert TicketEvents.query(@repo_key, @issue_id, open_decisions: true) == []
    end

    test "a ticket that can't be read or written leaves the marker unset for the next run", %{audit: audit} do
      put_ticket(%{signals: [signal(1, "claim", %{to: "In Progress"})]})

      for failing <- [:list_ticket_events, :append_ticket_events] do
        Process.put(:fail, [failing])

        log = capture_log(fn -> assert {:error, {:tickets_failed, 1}} = Backfill.run(now: @now, audit_log: audit, store: Store) end)
        assert log =~ "Failed to backfill the ticket events of issue_id=#{@issue_id}"
        assert RunStore.get_marker(Backfill.marker()) == nil
      end

      Process.put(:fail, [:put_marker])
      assert {:error, {:failed, :put_marker}} = Backfill.run(now: @now, audit_log: audit, store: Store)

      Process.put(:fail, [])
      assert {:ok, %{tickets: 0, events: 0}} = Backfill.run(now: @now, audit_log: audit, store: Store)
      assert RunStore.get_marker(Backfill.marker()) == @now
      assert length(events()) == 2
    end

    test "a store or audit log that can't be read fails the run", %{audit: audit} do
      Process.put(:fail, [:get_marker])
      assert {:error, {:failed, :get_marker}} = Backfill.run(store: Store)

      Process.put(:fail, [:list_all_ticket_states])
      assert {:error, {:failed, :list_all_ticket_states}} = Backfill.run(store: Store)

      Process.put(:fail, [])
      assert {:error, :invalid_limit} = Backfill.run(now: @now, audit_log: audit ++ [limit: 0], store: Store)
    end
  end

  describe "start/1" do
    test "does nothing when the backfill is turned off" do
      assert Backfill.start() == :disabled
    end

    test "runs the backfill in a task, so the caller does not wait for it", %{audit: audit} do
      put_ticket(%{signals: [signal(1, "claim", %{to: "In Progress"})]})
      test = self()

      run = fn opts ->
        send(test, {:running, self()})

        receive do
          :go -> Backfill.run(opts)
        end
      end

      log =
        capture_log(fn ->
          assert {:ok, pid} = Backfill.start(enabled: true, run: run, now: @now, audit_log: audit)
          assert_receive {:running, ^pid}
          assert events() == []

          ref = Process.monitor(pid)
          send(pid, :go)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~ "Backfilled 2 ticket event(s) on 1 ticket(s) from their snapshots"
      assert length(events()) == 2

      start_held([enabled: true, now: @now, audit_log: audit], &Backfill.run/1)
      assert length(events()) == 2
    end

    test "logs a run that fails, and a task that can't start" do
      log =
        capture_log(fn ->
          start_held([enabled: true], fn _opts -> {:error, :boom} end)
        end)

      assert log =~ "Failed to backfill ticket events: :boom"

      log = capture_log(fn -> assert {:error, _reason} = Backfill.start(enabled: true, supervisor: :missing_task_supervisor) end)
      assert log =~ "Failed to start the ticket events backfill"
    end
  end

  # Starts the backfill with its run held until the task is monitored: a run that returns at once
  # would otherwise exit before `Process.monitor/1`, and the DOWN would carry `:noproc`.
  defp start_held(opts, run) do
    held = fn run_opts ->
      receive do
        :go -> run.(run_opts)
      end
    end

    assert {:ok, pid} = Backfill.start(Keyword.put(opts, :run, held))
    ref = Process.monitor(pid)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp put_ticket(attrs) do
    issue_id = Map.get(attrs, :issue_id, @issue_id)
    :ok = RunStore.put_ticket_state(Map.merge(%{repo_key: @repo_key, issue_id: issue_id, issue_identifier: "TP-#{issue_id}"}, attrs))
  end

  defp events(issue_id \\ @issue_id, opts \\ [])
  defp events(opts, []) when is_list(opts), do: events(@issue_id, opts)
  defp events(issue_id, opts), do: TicketEvents.query(@repo_key, issue_id, Keyword.put(opts, :limit, 200))

  defp move(name, attrs), do: Map.merge(%{event_type: "director_move", move: name, repo_key: @repo_key, issue_id: @issue_id}, attrs)

  defp signal(minute, name, details), do: %{name: name, details: details, at: at(minute)}

  defp decision(key, date, answer), do: %{key: key, date: date, title: key, question: "#{key}?", answer: answer, scope: "In scope"}

  defp at(minute), do: DateTime.add(@base, minute * 60, :second)

  defp audit!(audit, attrs, at), do: :ok = AuditLog.record(Map.put(attrs, :timestamp, at), audit)
end
