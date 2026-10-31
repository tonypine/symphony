defmodule SymphonyElixir.Pauses.BackfillTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{DecisionRequest, DispatchLoop, Pauses, Questions, TicketEvents, TicketState}
  alias SymphonyElixir.Pauses.Backfill

  @repo_key "repo-a"
  @set_at ~U[2026-10-28 09:00:00.000000Z]
  @now ~U[2026-10-30 07:00:00.000000Z]
  @later ~U[2026-10-30 08:00:00.000000Z]
  @symphony %{kind: :symphony, name: "Symphony"}
  @director %{kind: :person, name: "Director"}

  # The run store, with the failures a test asks for in its process.
  defmodule Store do
    @moduledoc false
    alias SymphonyElixir.RunStore

    def get_marker(name), do: fail(:get_marker) || RunStore.get_marker(name)
    def put_marker(name, at), do: fail(:put_marker) || RunStore.put_marker(name, at)
    def list_all_ticket_states, do: fail(:list_all_ticket_states) || RunStore.list_all_ticket_states()
    def list_ticket_events(repo_key, issue_id, opts), do: fail(:list_ticket_events) || RunStore.list_ticket_events(repo_key, issue_id, opts)
    def update_ticket_state(repo_key, issue_id, attrs), do: fail(:update_ticket_state) || RunStore.update_ticket_state(repo_key, issue_id, attrs)
    def get_paused, do: fail(:get_paused) || RunStore.get_paused()

    defp fail(name), do: if(name in Process.get(:fail, []), do: {:error, {:failed, name}})
  end

  setup do
    :ok = RunStore.clear()
    :ok = RunStore.put_marker(TicketEvents.Backfill.marker(), @set_at)
    on_exit(fn -> Backfill.reset() end)
    :ok
  end

  defp blocked(type, keys, reason \\ "held"), do: %{kind: :blocked, reason: reason, clearing_condition: "when it clears", waits_on: %{type: type, keys: keys}, set_at: @set_at}

  # A record as one stored before the holds were retired: the holds sit on it as they were written,
  # which the record's normalization no longer reads.
  defp put_record(issue_id, attrs) do
    record = raw_record(issue_id, Map.merge(%{issue_identifier: "TP-#{String.replace(issue_id, ~r/\D/, "")}"}, attrs))
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_ticket_states, {@repo_key, issue_id}, @repo_key, issue_id, record}) end)
    record
  end

  # Puts `holds` on the stored record as they were stored, after a write that normalized it.
  defp put_holds(issue_id, holds) do
    stored = Map.put(RunStore.get_ticket_state(@repo_key, issue_id), :holds, holds)
    {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write({:symphony_run_store_ticket_states, {@repo_key, issue_id}, @repo_key, issue_id, stored}) end)
  end

  defp raw_record(issue_id, attrs) do
    {holds, attrs} = Map.pop(attrs, :holds)
    record = TicketState.new(@repo_key, issue_id, attrs)
    if holds, do: Map.put(record, :holds, holds), else: record
  end

  defp record(issue_id), do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, issue_id))
  defp ticket(issue_id), do: {:ticket, @repo_key, issue_id}
  defp reasons(issue_id), do: Enum.map(TicketState.pause_reasons(record(issue_id)), &{&1.kind, &1.waits_on, &1.text})
  defp events(issue_id), do: RunStore.list_ticket_events(@repo_key, issue_id, [])
  defp run!(opts \\ []), do: {:ok, _summary} = Backfill.run(Keyword.merge([now: @now, store: Store], opts))

  # One record per hold type the table covers.
  defp put_hold_records do
    put_record("issue-1", %{holds: [blocked("dependency", ["TP-11", "TP-12"], "waiting on TP-11, TP-12")]})
    put_record("issue-2", %{holds: [blocked("fix_ticket", ["TP-21"])]})
    put_record("issue-3", %{holds: [blocked("landing", ["TP-31"], "Waiting on TP-31 to land: they change the same files (a.ex)")]})
    put_record("issue-4", %{holds: [blocked("operator_stop", [], "Stopped by you at 09:00 UTC. Unblock runs it again where it stopped.")]})
    put_record("issue-5", %{holds: [blocked("access", [], "the run reported a block")]})
    put_record("issue-6", %{holds: [blocked("ci_wait", ["abc1234def"], "ci_wait: CI on abc1234def was still running after 30 minutes")]})
    put_record("issue-7", %{holds: [blocked("dispatch_loop", ["implementation"], "dispatch_loop: 3 implementation runs in 1h without a state change")]})
    put_record("issue-8", %{holds: [blocked("handoff_missing", ["aaa1111"], "handoff_missing: 3 runs went quiet on the PR without handing it off")]})
  end

  describe "run/1" do
    test "every Blocked hold ends as a pause whose reasons match its kind, the hold stays, and a second run changes nothing" do
      put_hold_records()

      assert {:ok, summary} = Backfill.run(now: @now, store: Store)

      assert reasons("issue-1") == [
               {:ticket, %{identifier: "TP-11"}, "Waiting for TP-11 to finish"},
               {:ticket, %{identifier: "TP-12"}, "Waiting for TP-12 to finish"}
             ]

      assert reasons("issue-2") == [{:ticket, %{identifier: "TP-21"}, "Waiting for TP-21 to finish: it fixes what stopped this ticket"}]
      assert reasons("issue-3") == [{:ticket, %{identifier: "TP-31"}, "Waiting for TP-31 to land: it changes the same files"}]
      stopped = "Stopped by you at 09:00 UTC. Unblock runs it again where it stopped."
      assert reasons("issue-4") == [{:person, %{action: "unblock"}, stopped}]
      assert reasons("issue-5") == [{:environment, %{condition: "the run reported a block"}, "the run reported a block"}]
      ci = "ci_wait: CI on abc1234def was still running after 30 minutes"
      assert reasons("issue-6") == [{:environment, %{condition: ci}, ci}]

      for issue_id <- ["issue-7", "issue-8"] do
        assert [%{id: id, state: :open, asked_by: %{kind: :symphony}} = question] = Questions.open(ticket(issue_id))
        assert reasons(issue_id) == [{:question, %{question_id: id}, "Waiting for your answer: #{question.title}"}]
        assert Enum.map(question.options, & &1.label) == ["Run it again", "Start it over from main", "Keep it paused"]
      end

      assert [%{title: "Two runs made no progress on TP-7"}] = Questions.open(ticket("issue-7"))
      assert [%{title: "TP-8's run ended without a handoff"}] = Questions.open(ticket("issue-8"))

      # The pause is set by Symphony at the hold's time, an operator stop by the Director, and the
      # Director may release the stop and the environment's reasons.
      assert %{set_by: @symphony, since: @set_at, reasons: [%{releasable: false} | _]} = record("issue-1").pause
      assert %{set_by: @director, reasons: [%{releasable: true}]} = record("issue-4").pause
      assert %{reasons: [%{releasable: true}]} = record("issue-6").pause

      for issue_id <- Enum.map(1..8, &"issue-#{&1}") do
        refute Map.has_key?(record(issue_id), :holds)
        assert record(issue_id).pause_backfilled_at == @now
      end

      assert [%{type: "pause.set", payload: %{source: "backfill"}, idempotency: "backfill:pause.set:ticket:" <> _}, %{type: "pause.reason_added"}] =
               events("issue-1")

      assert [%{type: "question.asked", payload: %{source: "backfill"}}, %{type: "pause.set", payload: %{reason: "question", source: "backfill"}}] =
               events("issue-7")

      assert %{records_read: 8, records_converted: 8, already_converted: 0, at: @now} = summary
      assert %{pauses_created: 8, questions_created: 2, skipped_count: 0, skipped: []} = summary

      before = Map.new(1..8, &{&1, {record("issue-#{&1}"), events("issue-#{&1}")}})

      assert {:ok, again} = Backfill.run(now: @later, store: Store)
      assert %{records_read: 8, records_converted: 0, already_converted: 8} = again
      assert %{pauses_created: 0, questions_created: 0} = again

      assert Map.new(1..8, &{&1, {record("issue-#{&1}"), events("issue-#{&1}")}}) == before
    end

    test "three stored decisions end as three answered questions in the same order, each with its answer, day and decision event" do
      put_record("issue-1", %{
        decisions: [
          %{key: "c-1", date: ~D[2026-10-20], title: "Ship it", question: "Should it ship?", answer: "Yes", scope: "Ships today"},
          %{key: "c-2", date: "2026-10-21", title: "Wait", question: "", answer: "2", scope: ""},
          %{key: "c-3", date: "", title: "", question: "Which layout?", answer: "The wide one", scope: ""}
        ]
      })

      {:ok, recorded} =
        TicketEvents.record(@repo_key, "issue-1", "decision.recorded", %{answer: "Yes", key: "c-1"},
          actor: {:person, "the Director"},
          at: ~U[2026-10-20 00:00:00Z]
        )

      assert {:ok, %{questions_created: 3, pauses_created: 0}} = Backfill.run(now: @now, store: Store)

      assert [first, second, third] = Questions.answered(ticket("issue-1"))
      assert %{title: "Ship it", question: "Should it ship?", legacy_event: legacy, answer: answer} = first
      assert %{text: "Yes", at: ~U[2026-10-20 00:00:00Z], scope: :ticket, by: @director} = answer
      assert legacy == recorded.id
      assert %{title: "Wait", question: "Wait", legacy_event: nil, answer: %{text: "2", option: nil, at: ~U[2026-10-21 00:00:00Z]}} = second
      assert %{title: "Which layout?", question: "Which layout?", asked_at: @now, answer: %{text: "The wide one", at: @now}} = third

      # Answered questions don't pause the ticket and record their asking only: the answer is the
      # decision event's.
      assert record("issue-1").pause == nil
      assert ["decision.recorded", "question.asked", "question.asked", "question.asked"] = Enum.map(events("issue-1"), & &1.type)
    end

    test "an open Needs Decision request ends as one open question with its question reason" do
      decision = %{
        "title" => "Pick a layout",
        question: "Which layout should the pane use?",
        why: "Two layouts fit.",
        options: [
          %{label: "Wide", effect: "The pane is wide.", recommended: true, tradeoffs: [%{kind: "good", text: "Room."}], unlocks: ["WORKFLOW.md"]},
          "**Narrow** (recommended): The pane is narrow.",
          "Plain line",
          42
        ],
        unlocks: [[], ["symphony.yml"]],
        confirm: "Merging",
        asked_at: "2026-10-27T10:00:00Z"
      }

      put_record("issue-1", %{holds: [%{kind: :needs_decision, reason: "Which layout should the pane use?", decision: decision, set_at: @set_at}]})

      assert {:ok, %{questions_created: 1, pauses_created: 1}} = Backfill.run(now: @now, store: Store)

      assert [%{id: id, title: "Pick a layout", why: "Two layouts fit.", confirm: "Merging", asked_at: ~U[2026-10-27 10:00:00Z], options: options}] =
               Questions.open(ticket("issue-1"))

      assert [
               %{label: "Wide", effect: "The pane is wide.", recommended?: true, good: ["Room."], unlocks: ["WORKFLOW.md"]},
               %{label: "Narrow", effect: "The pane is narrow.", recommended?: true, unlocks: ["symphony.yml"]},
               %{label: "Plain line", effect: "", recommended?: false},
               %{label: nil, effect: ""}
             ] = options

      assert [{:question, %{question_id: ^id}, _text}] = reasons("issue-1")
    end

    test "a Needs Decision hold that projects a Question asked through the service has its question already" do
      decision = %{title: "Pick a layout", question: "Which layout?", question_id: "q-asked"}
      put_record("issue-1", %{holds: [%{kind: :needs_decision, reason: "Which layout?", decision: decision, set_at: @set_at}]})

      assert {:ok, %{questions_created: 0, pauses_created: 0, skipped_count: 0}} = Backfill.run(now: @now, store: Store)
      assert Questions.open(ticket("issue-1")) == []
    end

    test "a record whose write fails is skipped and left unmarked; the next run converts it without asking twice" do
      put_record("issue-7", %{holds: [blocked("dispatch_loop", ["implementation"])]})

      Process.put(:fail, [:update_ticket_state])
      assert {:ok, %{records_converted: 0, skipped_count: 1, skipped: [skip]}} = Backfill.run(now: @now, store: Store)
      assert %{issue_id: "issue-7", issue_identifier: "TP-7", reason: "could not write it: {:failed, :update_ticket_state}"} = skip
      assert record("issue-7").pause_backfilled_at == nil
      written = events("issue-7")

      Process.put(:fail, [])
      assert {:ok, %{records_converted: 1, questions_created: 0, pauses_created: 0}} = Backfill.run(now: @later, store: Store)
      assert [_question] = record("issue-7").questions
      assert events("issue-7") == written
      assert record("issue-7").pause_backfilled_at == @later
    end

    test "a hold set beside a question asked live is left to it: the ticket keeps one open question and one question reason" do
      loop = %{kind: "implementation", count: 4, window_ms: 600_000, runs: []}
      stops = [{"issue-7", "TP-7", "dispatch_loop", loop}, {"issue-8", "TP-8", "handoff_missing", {:quiet_handoff, 2}}]

      for {issue_id, name, type, stop} <- stops do
        put_record(issue_id, %{})
        assert {:ok, question} = Questions.ask(ticket(issue_id), DispatchLoop.question_attrs(stop, name))
        hold = put_in(blocked(type, ["implementation"]), [:waits_on, :question_id], question.id)
        put_holds(issue_id, [hold])
        assert record(issue_id).pause_backfilled_at == nil
      end

      assert {:ok, %{records_converted: 2, questions_created: 0, pauses_created: 0, skipped_count: 0}} = Backfill.run(now: @now, store: Store)

      for {issue_id, _name, _type, _stop} <- stops do
        assert [%{id: id}] = Questions.open(ticket(issue_id))
        assert [{:question, %{question_id: ^id}, _text}] = reasons(issue_id)
        assert record(issue_id).pause_backfilled_at == @now
      end
    end

    test "a record whose decision events can't be read is skipped" do
      put_record("issue-1", %{decisions: [%{key: "c-1", date: ~D[2026-10-20], title: "Ship it", question: "Q?", answer: "Yes"}]})
      Process.put(:fail, [:list_ticket_events])

      assert {:ok, %{skipped: [%{reason: "could not write it: {:failed, :list_ticket_events}"}]}} = Backfill.run(now: @now, store: Store)
      assert record("issue-1").questions == []
    end

    test "what no pause reason covers is skipped with why, and the rest of the record converts" do
      put_record("issue-1", %{
        holds: [
          blocked("landing", ["TP-31", "https://github.com/acme/app/pull/12"]),
          %{kind: :needs_decision, reason: nil, decision: nil, set_at: nil}
        ],
        decisions: [
          %{key: "c-1", date: "", title: "", question: "", answer: "Yes"},
          %{key: "c-2", date: "", title: "T", question: "", answer: ""}
        ]
      })

      put_record("issue-2", %{holds: [blocked("dependency", [])]})
      put_record("issue-3", %{holds: [blocked("mystery", ["x"])]})
      put_record("issue-4", %{holds: [%{kind: :blocked, reason: "old", waits_on: nil, set_at: nil}]})

      assert {:ok, summary} = Backfill.run(now: @now, store: Store)

      assert summary.skipped |> Enum.map(&{&1.issue_identifier, &1.reason}) |> Enum.sort() == [
               {"TP-1", "a Needs Decision hold with no question"},
               {"TP-1", "decision c-1 has no title or question"},
               {"TP-1", "decision c-2 has no answer"},
               {"TP-1", "landing key https://github.com/acme/app/pull/12 names no ticket"},
               {"TP-2", "a dependency hold that names no ticket"},
               {"TP-3", "a Blocked hold waiting on mystery, which no pause reason covers"},
               {"TP-4", "a Blocked hold waiting on nothing named, which no pause reason covers"}
             ]

      assert %{records_converted: 4, pauses_created: 1, skipped_count: 7} = summary
      assert reasons("issue-1") == [{:ticket, %{identifier: "TP-31"}, "Waiting for TP-31 to land: it changes the same files"}]
      assert record("issue-3").pause == nil and record("issue-3").pause_backfilled_at == @now
    end

    test "the summary lists the first twenty skips and counts them all" do
      for n <- 1..21, do: put_record("issue-#{n}", %{holds: [blocked("mystery", [])]})

      assert {:ok, %{skipped_count: 21, skipped: skipped}} = Backfill.run(now: @now, store: Store)
      assert length(skipped) == 20
    end

    test "a record that is already paused gains the reasons without counting a new pause" do
      put_record("issue-1", %{})
      {:ok, _pause} = Pauses.set(ticket("issue-1"), %{kind: :ticket, waits_on: %{identifier: "TP-99"}})
      put_holds("issue-1", [blocked("dependency", ["TP-11"])])

      assert {:ok, %{pauses_created: 0, records_converted: 1}} = Backfill.run(now: @now, store: Store)
      assert [{:ticket, %{identifier: "TP-99"}, _}, {:ticket, %{identifier: "TP-11"}, _}] = reasons("issue-1")
    end

    test "the operator's pause of all dispatch becomes a pause on Symphony, once" do
      :ok = RunStore.set_paused(true, "Away for the  weekend")
      assert {:ok, %{pauses_created: 1}} = run!()

      assert {:ok, %{set_by: @director, reasons: [reason]}} = Pauses.get(:symphony)
      assert %{kind: :person, waits_on: %{action: "unblock"}, text: "Away for the weekend", releasable: true} = reason

      {:ok, nil} = Pauses.clear(:symphony)
      assert {:ok, %{pauses_created: 0}} = run!(now: @later)
      assert Pauses.get(:symphony) == {:ok, nil}
    end

    test "an operator pause without a reason reads that the Director paused Symphony" do
      :ok = RunStore.set_paused(true, nil)
      assert {:ok, %{pauses_created: 1}} = run!()
      assert Pauses.why(:symphony) == ["You paused Symphony"]
    end

    test "no operator pause creates none, and is not read again" do
      assert {:ok, %{pauses_created: 0}} = run!()
      assert Pauses.get(:symphony) == {:ok, nil}
      assert %DateTime{} = RunStore.get_marker("pause_backfill_symphony_v1")
    end

    test "an operator pause that can't be read is skipped, and read again on the next run" do
      :ok = RunStore.set_paused(true, "Away")
      Process.put(:fail, [:get_paused])

      assert {:ok, %{skipped: [%{issue_identifier: "Symphony", reason: "could not write the pause of all dispatch: {:failed, :get_paused}"}]}} = run!()

      Process.put(:fail, [])
      assert {:ok, %{pauses_created: 1}} = run!()
    end

    test "refuses to run before the ledger's backfill is done, and passes a store error on" do
      :ok = RunStore.clear()
      put_hold_records()
      assert Backfill.run(now: @now) == {:error, :ledger_backfill_pending}
      assert record("issue-1").pause == nil

      Process.put(:fail, [:get_marker])
      assert Backfill.run(store: Store) == {:error, {:failed, :get_marker}}

      :ok = RunStore.put_marker(TicketEvents.Backfill.marker(), @set_at)
      Process.put(:fail, [:list_all_ticket_states])
      assert Backfill.run(store: Store) == {:error, {:failed, :list_all_ticket_states}}
    end
  end

  describe "backfill_record/1" do
    test "a stuck run's question is in plain words and recommends a restart only when the hold says so" do
      record = raw_record("issue-7", %{holds: [blocked("dispatch_loop", ["qa"], "Restart it from main")]})

      assert %{items: [{:question, request, opts}], skipped: []} = Backfill.backfill_record(record)
      assert DecisionRequest.check(request) == :ok
      assert request.title == "Two runs made no progress on this ticket"
      assert Enum.map(request.options, & &1.recommended) == [false, true, false]
      assert request.recommendation_reason =~ "start it over"
      assert %{backfilled: true, id: "backfill-" <> _, at: @set_at} = Map.new(opts)

      plain = raw_record("issue-8", %{issue_identifier: "TP-8", holds: [blocked("handoff_missing", [], nil)]})
      assert %{items: [{:question, request, _opts}]} = Backfill.backfill_record(plain)
      assert DecisionRequest.check(request) == :ok
      assert Enum.map(request.options, & &1.recommended) == [true, false, false]
    end

    test "the same record maps to the same writes, and holds convert oldest first after the decisions" do
      asked = %{kind: :needs_decision, reason: "Ship it?", decision: nil, set_at: ~U[2026-10-01 00:00:00Z]}

      record =
        raw_record("issue-1", %{
          holds: [blocked("operator_stop", [], nil), asked],
          decisions: [%{key: "c-1", date: ~D[2026-10-20], title: "T", question: "Q", answer: "A"}]
        })

      assert Backfill.backfill_record(record) == Backfill.backfill_record(record)

      assert %{items: [{:question, %{title: "T"}, _decision}, {:question, asked, _asked}, {:reason, stop, _stop}]} =
               Backfill.backfill_record(record)

      assert %{title: "Ship it?", question: "Ship it?"} = asked

      assert stop == %{kind: :person, waits_on: %{action: "unblock"}}
    end

    test "a request is asked when its decision says, else when the hold was set" do
      asked_at = fn asked ->
        hold = %{kind: :needs_decision, reason: "Ship it?", decision: %{asked_at: asked}, set_at: @set_at}
        %{items: [{:question, _request, opts}]} = Backfill.backfill_record(raw_record("issue-1", %{holds: [hold]}))
        opts[:at]
      end

      assert asked_at.(@now) == @now
      assert asked_at.("2026-10-27T10:00:00Z") == ~U[2026-10-27 10:00:00Z]
      assert asked_at.("yesterday") == @set_at
      assert asked_at.(nil) == @set_at
    end

    test "the holds are read as they were stored: anything not a hold is dropped, one hold per kind, keys trimmed" do
      dependency = %{blocked("dependency", [" TP-11 ", "", 7, "TP-12"]) | set_at: "2026-10-28T09:00:00Z"}
      later = blocked("dependency", ["TP-13"])
      odd = [dependency, later, %{kind: nil}, %{kind: "blocked"}, %{reason: "no kind"}, "a line"]

      assert %{items: [{:reason, %{waits_on: %{identifier: "TP-11"}}, opts}, {:reason, second, _second}], skipped: []} =
               Backfill.backfill_record(raw_record("issue-1", %{holds: odd}))

      assert second.waits_on == %{identifier: "TP-12"}

      assert DateTime.compare(opts[:at], @set_at) == :eq
      assert %{items: [], skipped: []} = Backfill.backfill_record(raw_record("issue-1", %{holds: :none}))
      assert %{items: [], skipped: []} = Backfill.backfill_record(TicketState.new(@repo_key, "issue-1"))

      unnamed = %{kind: :blocked, reason: "old", waits_on: %{type: "", keys: []}, set_at: nil}
      assert %{skipped: ["a Blocked hold waiting on nothing named, which no pause reason covers"]} = Backfill.backfill_record(raw_record("issue-1", %{holds: [unnamed]}))
    end

    test "an environment hold without a reason waits on a condition named after its kind" do
      record = raw_record("issue-5", %{holds: [%{blocked("access", [], "  ") | set_at: nil}]})

      assert %{items: [{:reason, environment, [backfilled: true]}]} = Backfill.backfill_record(record)
      assert environment == %{kind: :environment, waits_on: %{condition: "access"}, text: "access", releasable: true}
    end
  end

  describe "run_after_ledger/1" do
    test "runs the ledger's backfill, then this one, keeps the summary and returns the ledger's result" do
      put_hold_records()
      ledger = fn opts -> send(self(), {:ledger, opts[:now]}) && {:ok, %{tickets: 0, events: 0}} end

      log = capture_log(fn -> assert {:ok, %{tickets: 0}} = Backfill.run_after_ledger(ledger: ledger, now: @now) end)

      assert_received {:ledger, @now}
      assert log =~ "Pause backfill: read 8 record(s), converted 8, created 8 pause(s) and 2 question(s), skipped 0"
      assert %{records_read: 8, pauses_created: 8, at: @now} = Backfill.summary()
    end

    test "a run that fails is logged and its error kept as the summary" do
      :ok = RunStore.clear()
      ledger = fn _opts -> {:error, :boom} end

      log = capture_log(fn -> assert Backfill.run_after_ledger(ledger: ledger) == {:error, :boom} end)

      assert log =~ "Failed to backfill pauses and questions: :ledger_backfill_pending"
      assert %{error: ":ledger_backfill_pending", at: %DateTime{}} = Backfill.summary()
    end
  end

  describe "reset/0" do
    test "forgets the summary until the next run" do
      ledger = fn _opts -> {:ok, %{tickets: 0, events: 0}} end
      capture_log(fn -> Backfill.run_after_ledger(ledger: ledger, now: @now) end)
      assert %{at: @now} = Backfill.summary()

      assert Backfill.reset() == :ok
      assert Backfill.summary() == nil
      assert Backfill.reset() == :ok
    end
  end
end
