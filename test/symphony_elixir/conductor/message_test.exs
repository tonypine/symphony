defmodule SymphonyElixir.Conductor.MessageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, Messages, TicketChecks, TicketEvents, TicketPlan}
  alias SymphonyElixir.Conductor.{Facts, Message, Steer}
  alias SymphonyElixir.Config.{Cache, Schema}

  @on %Schema.Conductor{enabled: true}

  # A tracker that refuses the related link, and is the memory tracker for the rest.
  defmodule NoLink do
    @moduledoc false
    defdelegate create_issue(attrs), to: SymphonyElixir.Tracker.Memory
    def add_related(_related, _issue_id), do: {:error, :linear_down}
  end

  setup do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    n = System.unique_integer([:positive])
    record = ticket!("MSG-#{n}", "msg-#{n}", %{phase: "In Progress"})
    plan!(record.issue_id)
    %{record: record, issue_id: record.issue_id, n: n}
  end

  defp ticket!(identifier, issue_id, attrs) do
    record = Map.merge(%{repo_key: "default", issue_id: issue_id, issue_identifier: identifier, phase: "Todo", title: "Filters"}, attrs)
    :ok = RunStore.put_ticket_state(record)
    record
  end

  defp plan(attrs) do
    Map.merge(
      %{
        shape: "single",
        layers: ["engine"],
        summary: "The list keeps its filter.",
        text: "Approach: store the filter.",
        checks: [%{id: "c1", kind: "evidence", statement: "The filter survives a reload.", proof: "test"}],
        size: %{tokens: 1, runs: 1},
        reason: "Grooming",
        by: "grooming"
      },
      attrs
    )
  end

  defp plan!(issue_id, attrs \\ %{}) do
    {:ok, _asked} = TicketPlan.record_ask("default", issue_id, "Keep my filter.")
    {:ok, _event} = TicketPlan.write("default", issue_id, plan(attrs))
  end

  defp say!(issue_id, text \\ "Use the store the sort order uses.") do
    {:ok, message} = Messages.send_message("default", issue_id, text)
    message
  end

  defp answered_plan(attrs \\ %{}) do
    Map.merge(
      %{
        "reason" => "The person also wants the search text kept.",
        "shape" => "single",
        "layers" => ["engine"],
        "summary" => "The list keeps its filter and its search text.",
        "text" => "Approach: store both.",
        "checks" => [
          %{"id" => "c1", "kind" => "outcome", "statement" => "The filter survives a reload.", "proof" => "test"},
          %{"kind" => "outcome", "statement" => "The search text survives a reload.", "proof" => "test"}
        ],
        "size" => %{"tokens" => 2, "runs" => 2}
      },
      attrs
    )
  end

  defp reply(attrs \\ %{}), do: {:ok, [Jason.encode!(Map.merge(%{"update" => "I read it as a hint and passed it on."}, attrs))], 900}

  # Each junction's turn answers what the test scripts for it, and reports its prompt.
  defp turns(replies) do
    test = self()

    fn plan, _issue, _run_id, prompt ->
      send(test, {:turn, plan.junction, prompt})
      Map.fetch!(replies, plan.junction)
    end
  end

  defp opts(replies, more \\ []), do: Keyword.merge([settings: @on, turn: turns(replies), start: fn task -> task.() end, running: fn _id -> nil end], more)

  # What the ticket is owed is run now, as the orchestrator's task does.
  defp answer(record, _message, opts), do: with(_left <- Message.tend(record.issue_id, opts), do: :ok)

  defp status_notes(issue_id), do: for(%{type: "note", payload: %{status: true, text: text}} <- Facts.events(issue_id), do: text)

  defp events(issue_id, type), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == type))

  defp conductor_on! do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "conductor:\n  enabled: true\n  watch:\n    enabled: true\n")
    Cache.clear()
  end

  describe "whose a message is" do
    test "the Conductor's on a groomed ticket with the junction on, a run's otherwise", ctx do
      assert Message.due?(ctx.issue_id, settings: @on)
      refute Message.due?(ctx.issue_id, settings: %Schema.Conductor{enabled: false})
      refute Message.due?(ctx.issue_id, settings: %{@on | junctions: ["after_coding"]})
      refute Message.due?(ctx.issue_id)
      refute Message.due?(nil)

      ungroomed = ticket!("MSG-U#{ctx.n}", "msg-u-#{ctx.n}", %{})
      refute Message.due?(ungroomed.issue_id, settings: @on)

      message = say!(ungroomed.issue_id)
      assert Message.start(ungroomed, message, opts(%{})) == :ok
      refute_received {:turn, _junction, _prompt}
      assert events(ungroomed.issue_id, "run.started") == []
    end

    test "a run is given a groomed ticket's message only while the Conductor does not answer it", ctx do
      say!(ctx.issue_id, "Mind the empty list.")
      run_id = "run-#{ctx.n}"

      prompt = Messages.prepend_unread("The prompt.", "default", ctx.issue_id, run_id)
      assert prompt =~ "## Messages from the person"
      assert [_read] = events(ctx.issue_id, "message.read")

      later = say!(ctx.issue_id, "And the long list.")
      conductor_on!()
      assert Messages.prepend_unread("The prompt.", "default", ctx.issue_id, "run-b-#{ctx.n}") == "The prompt."
      assert [_only] = events(ctx.issue_id, "message.read")
      assert Messages.read_event(later, Facts.events(ctx.issue_id)) == nil
    end
  end

  describe "the message turn" do
    test "starts at once and replies under the message, with the conversation in its facts", ctx do
      earlier = say!(ctx.issue_id, "Is it started?")
      {:ok, _reply} = TicketEvents.record("default", ctx.issue_id, "conductor.update", %{junction: "message", text: "Yes."}, parent: earlier.id)
      {:ok, _started} = TicketEvents.record("default", ctx.issue_id, "run.started", %{run_id: "run-1", run_kind: "implementation"}, run_id: "run-1")
      {:ok, _ended} = TicketEvents.record("default", ctx.issue_id, "run.ended", %{run_id: "run-1", run_kind: "implementation", exit: "normal", tokens: 5_000}, run_id: "run-1")
      message = say!(ctx.issue_id)

      assert Message.start(ctx.record, message, opts(%{"message" => reply(%{"blocks" => [%{"type" => "budget"}]})})) == :ok

      assert_received {:turn, "message", prompt}
      assert prompt =~ "you are the medium between the person and the runs"
      assert prompt =~ "a person sent a message on the ticket; you answer it"
      facts = prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()
      assert facts["message"] == %{"event_id" => message.id, "by" => "the Director", "text" => "Use the store the sort order uses."}
      refute Map.has_key?(facts, "rules")

      assert [%{"kind" => "ask", "source" => "linear", "text" => "Keep my filter."}, %{"kind" => "message", "reply" => %{"text" => "Yes."}}, %{"kind" => "message", "reply" => nil}] =
               facts["conversation"]

      assert %{"summary" => "The list keeps its filter."} = facts["plan"]
      assert [%{"id" => "c1", "state" => "open"}] = facts["checks"]
      assert facts["sub_tickets"] == []

      text = "I read it as a hint and passed it on."

      assert [_earlier, %{parent: parent, payload: payload}] = events(ctx.issue_id, "conductor.update")
      assert %{junction: "message", text: ^text, blocks: [%{type: "budget", tokens_used: 5_000}]} = payload

      assert parent == message.id
      assert [_run, %{payload: %{run_kind: "conductor", exit: "answered"}}] = events(ctx.issue_id, "run.ended")
      assert length(TicketPlan.versions(ctx.issue_id)) == 1
      assert events(ctx.issue_id, "message.read") == []
    end

    test "a message that changes the ask records the new plan, then the message as an ask", ctx do
      {:ok, _proof} = TicketChecks.prove("default", ctx.issue_id, %{check_id: "c1", by: "test", test: "list_test › keeps the filter"})
      message = say!(ctx.issue_id, "Keep the search text too.")
      answer = reply(%{"ask" => true, "plan" => answered_plan(%{"shape" => "split", "sub_tickets" => [%{"title" => "x", "ask" => "y"}]})})

      assert answer(ctx.record, message, opts(%{"message" => answer})) == :ok

      assert [_first, %{version: 2, by: "recalibration", reason: "The person also wants the search text kept.", shape: "single"} = plan] = TicketPlan.versions(ctx.issue_id)
      refute Map.has_key?(plan, :sub_tickets)
      assert [%{id: "c1", state: :proved}, %{id: "c2", state: :open}] = TicketChecks.list(ctx.issue_id)
      assert [_linear, %{source: "message", from: from, text: "Keep the search text too."}] = TicketPlan.ask(ctx.issue_id)
      assert from == message.id
      assert [%{parent: ^from}] = events(ctx.issue_id, "conductor.update")
    end

    test "a plan the ledger refuses is said in plain words, and nothing is written", ctx do
      turn = %{issue_id: ctx.issue_id, repo_key: "default", junction: "message", message: %{event: say!(ctx.issue_id)}}
      refused = Message.write_plan(turn, issue(ctx.record), %{plan: %{summary: "No checks."}, ask: true}, "run-x")
      assert {:error, "its plan could not be recorded: " <> _why} = refused
      assert length(TicketPlan.ask(ctx.issue_id)) == 1
    end

    test "a plan with no reason of its own is recorded with Symphony's", ctx do
      message = say!(ctx.issue_id, "Keep the search text too.")
      answer = reply(%{"ask" => true, "plan" => Map.delete(answered_plan(), "reason")})

      assert answer(ctx.record, message, opts(%{"message" => answer})) == :ok
      assert %{version: 2, reason: "A message changed what is asked."} = TicketPlan.current(ctx.issue_id)
    end

    test "a changed ask with no plan, or with a plan Symphony refuses, is an unreadable answer and gets Symphony's reply once", ctx do
      message = say!(ctx.issue_id, "Keep the search text too.")

      log =
        capture_log(fn ->
          assert answer(ctx.record, message, opts(%{"message" => reply(%{"ask" => true})})) == :ok

          twice =
            answered_plan(%{
              "checks" => [
                %{"id" => "c1", "kind" => "outcome", "statement" => "a", "proof" => "test"},
                %{"id" => "c1", "kind" => "qa", "statement" => "b", "proof" => "qa", "action" => "c", "expect" => "d"}
              ]
            })

          assert answer(ctx.record, message, opts(%{"message" => reply(%{"ask" => true, "plan" => twice})})) == :ok

          # Two tries failed: the message is still owed its turn, and nothing answers it yet.
          assert events(ctx.issue_id, "conductor.update") == []
          assert %{messages: [%{id: owed}]} = Message.owed(ctx.issue_id)
          assert owed == message.id
          assert Message.tend(ctx.issue_id, opts(%{"message" => reply(%{"ask" => true})})) == :done
        end)

      assert log =~ "`ask` is true, so the answer must hold the new `plan`"
      assert log =~ "its plan was refused: check id c1 is used twice"

      assert [first, second] = status_notes(ctx.issue_id)
      assert first == "The Conductor could not answer a message (its answer could not be read). Symphony tries again."
      assert second =~ "(its plan was refused: check id c1 is used twice)"
      assert [%{parent: parent, payload: %{junction: "message", text: text}}] = events(ctx.issue_id, "conductor.update")
      assert parent == message.id

      assert text ==
               "The Conductor could not read this message (its answer could not be read), 3 times, so nothing was done with it. " <>
                 "It stays in the ticket's history. Send it again to have it read."

      assert Message.owed(ctx.issue_id) == %{messages: [], asks: [], children: []}
      assert length(TicketPlan.versions(ctx.issue_id)) == 1
      assert length(TicketPlan.ask(ctx.issue_id)) == 1
      assert [%{payload: %{exit: "unreadable answer: " <> _}}, %{payload: %{exit: "its plan was refused: " <> _}}, _third] = events(ctx.issue_id, "run.ended")
    end

    test "a turn that fails, runs over or crashes is counted on its message, which stays owed", ctx do
      for {turn, why} <- [
            {fn _plan, _issue, _run_id, _prompt -> {:error, :boom, 0} end, "the turn failed"},
            {fn _plan, _issue, _run_id, _prompt -> Process.sleep(:infinity) end, "the turn ran past its time limit"}
          ] do
        message = say!(ctx.issue_id)

        capture_log(fn ->
          assert Conductor.message(issue(ctx.record), message, "default", settings: %{@on | timeout_ms: 50}, turn: turn) == :ok
        end)

        assert List.last(status_notes(ctx.issue_id)) == "The Conductor could not answer a message (#{why}). Symphony tries again."
        assert message.id in Enum.map(Message.owed(ctx.issue_id).messages, & &1.id)
      end

      message = say!(ctx.issue_id)

      log = capture_log(fn -> assert Conductor.message(issue(ctx.record), message, "default", settings: @on, facts: fn -> raise "no facts" end, turn: turns(%{})) == :ok end)
      assert log =~ "Conductor turn failed"
      assert events(ctx.issue_id, "conductor.update") == []
      assert %{run_id: nil, payload: %{text: text}, idempotency: key} = ctx.issue_id |> events("note") |> List.last()
      assert text =~ "(the turn failed)"
      assert key == "message.try:#{message.id}:1"
    end

    test "a message a run already read, or one written before the plan, is owed as the rule says", ctx do
      early = ticket!("MSG-E#{ctx.n}", "msg-e-#{ctx.n}", %{})
      before = say!(early.issue_id, "Mind the empty list.")
      assert Message.owed(early.issue_id) == %{messages: [], asks: [], children: []}
      assert Message.plan_written(early.issue_id, opts(%{})) == :ok
      refute_received {:turn, _junction, _prompt}

      # The plan is written: the message that waited is answered, with no new message to start it.
      plan!(early.issue_id)
      assert [%{id: owed}] = Message.owed(early.issue_id).messages
      assert owed == before.id
      assert Message.owed_tickets(settings: @on) |> Enum.member?(early.issue_id)
      assert Message.owed_tickets() == []
      assert Message.plan_written(early.issue_id, opts(%{"message" => reply()})) == :ok
      assert_received {:turn, "message", _prompt}
      assert [%{parent: parent}] = events(early.issue_id, "conductor.update")
      assert parent == before.id
      assert Message.plan_written(early.issue_id, opts(%{})) == :ok
      assert Message.tend(early.issue_id, opts(%{})) == :done

      # One a run read while the junction was off is that run's.
      read = say!(ctx.issue_id)
      {:ok, _read} = TicketEvents.record("default", ctx.issue_id, "message.read", %{message_id: read.id, run_id: "run-#{ctx.n}"})
      assert Message.owed(ctx.issue_id).messages == []

      # With no orchestrator to take it, starting what is owed is still fine.
      assert Message.start(ctx.record, say!(ctx.issue_id), settings: @on) == :ok
      assert Message.tend("no-such-ticket", settings: @on) == :done
      # With the Conductor off, as the settings file has it here, nothing is owed and nothing starts.
      assert Message.tend(ctx.issue_id) == :done
      assert Message.plan_written(ctx.issue_id) == :ok
    end

    test "nothing runs for a ticket with no plan, and a crash before any plan is only logged", ctx do
      ungroomed = ticket!("MSG-V#{ctx.n}", "msg-v-#{ctx.n}", %{})
      message = say!(ungroomed.issue_id)
      assert Conductor.message(issue(ungroomed), message, "default", settings: @on, turn: turns(%{})) == :ok
      assert events(ungroomed.issue_id, "run.started") == []
    end

    test "information for a run is queued for the working run, or kept as instructions for the next", ctx do
      steer = %{"steer" => %{"message" => "Keep the filter in the view state store.", "when" => "now"}}
      message = say!(ctx.issue_id)

      assert answer(ctx.record, message, opts(%{"message" => reply(steer)})) == :ok
      assert [%{payload: %{junction: "message", text: "Keep the filter in the view state store."}}] = events(ctx.issue_id, "conductor.instructions")

      conductor_on!()
      Steer.create_table()
      test = self()
      working = fn kind -> fn _id -> %{run_id: "run-w-#{kind}-#{ctx.n}", issue_id: ctx.issue_id, run_profile: %{harness: kind}} end end

      Steer.during_turn("run-w-claude-#{ctx.n}", fn ->
        assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(steer)}, running: working.("claude"))) == :ok
        assert_received {:conductor_interrupt, _run_id, _sent_ms}
        send(test, :turned)
      end)

      assert_received :turned
      assert Steer.turn_prompt("run-w-claude-#{ctx.n}", true, fn -> "own" end) =~ "Keep the filter in the view state store."
      assert [%{payload: %{trigger: "message", when: "now"}}] = events(ctx.issue_id, "conductor.steer")

      later = %{"steer" => %{"message" => "And test it.", "when" => "now"}}
      assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(later)}, running: fn _id -> %{run_id: "run-w-codex-#{ctx.n}", issue_id: ctx.issue_id} end)) == :ok
      assert Steer.interrupt("run-w-codex-#{ctx.n}") == :no_turn
      assert Steer.turn_prompt("run-w-codex-#{ctx.n}", false, fn -> "own" end) =~ "And test it."
      assert length(events(ctx.issue_id, "conductor.instructions")) == 1
    end

    test "a stop ends the working run and says why; one that stops nothing is only logged", ctx do
      stop = %{"stop" => %{"reason" => "The person no longer wants the filter stored."}}
      test = self()
      stopped = fn name -> send(test, {:stopped, name}) && {:ok, %{stopped: true}} end

      assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(stop)}, stop: stopped)) == :ok
      identifier = ctx.record.issue_identifier
      assert_received {:stopped, ^identifier}

      assert [%{payload: %{action: "stopped", reason: "The person no longer wants the filter stored.", by: ^identifier, target: ^identifier}}] =
               events(ctx.issue_id, "conductor.intervention")

      assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(stop)}, stop: fn _name -> {:ok, %{stopped: false}} end)) == :ok
      assert length(events(ctx.issue_id, "conductor.intervention")) == 1

      # A record the ledger refuses is logged, and the reply is still written.
      long = %{ctx.record | issue_identifier: String.duplicate("X", 300)}
      :ok = RunStore.put_ticket_state(long)
      refused = opts(%{"message" => reply(stop)}, stop: stopped)
      log = capture_log(fn -> assert answer(long, say!(ctx.issue_id), refused) == :ok end)
      assert log =~ "Conductor could not record conductor.intervention"
      assert length(events(ctx.issue_id, "conductor.update")) == 3
    end

    test "the answer may waive a check nobody can prove; an id the plan does not hold is dropped", ctx do
      waive = %{"waive" => [%{"check_id" => "c1", "reason" => "No test can reach a reload."}, %{"check_id" => "c9", "reason" => "x"}, %{"check_id" => "c1"}]}

      log = capture_log(fn -> assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(waive)})) == :ok end)

      assert log =~ "Conductor's waiver of c9 was dropped"
      assert log =~ "`waive[3]` was dropped"
      assert [%{id: "c1", state: :waived, waived: %{reason: "No test can reach a reload."}}] = TicketChecks.list(ctx.issue_id)
    end
  end

  test "a message that changes what is asked may change an outcome, and no other answer may", ctx do
    changed = answered_plan(%{"checks" => [%{"id" => "c1", "kind" => "outcome", "statement" => "The filter survives a restart of the app.", "proof" => "test"}]})
    say!(ctx.issue_id, "It must survive a restart of the app, not only a reload.")

    assert Message.tend(ctx.issue_id, opts(%{"message" => reply(%{"ask" => true, "plan" => changed})})) == :done
    assert %{version: 2, checks: [%{statement: "The filter survives a restart of the app."}]} = TicketPlan.current(ctx.issue_id)
    assert length(TicketPlan.ask(ctx.issue_id)) == 2
  end

  test "a turn before the merge may waive a check that is not an outcome", ctx do
    checks = [
      %{id: "c1", kind: "outcome", statement: "The filter survives a reload.", proof: "test"},
      %{id: "c2", kind: "evidence", statement: "A screenshot of the list.", proof: "attached"}
    ]

    {:ok, _event} = TicketPlan.write("default", ctx.issue_id, plan(%{checks: checks, reason: "More checks", by: "recalibration"}))
    waive = %{"instructions" => "Merge.", "waive" => [%{"check_id" => "c2", "reason" => "No screen changed."}, %{"check_id" => "c1", "reason" => "Hard."}]}
    turn = fn _plan, _issue, _run_id, _prompt -> {:ok, [Jason.encode!(waive)], 1} end
    run_profile = %{model: "m", effort: nil, provider: "p"}
    plan = %{junction: "before_merge", issue_id: ctx.issue_id, repo_key: "default", timeout_ms: 5_000, run_profile: run_profile}

    log = capture_log(fn -> assert Conductor.run(plan, issue(ctx.record), turn: turn) == :ok end)

    assert log =~ "Conductor's waiver of c1 was dropped"
    assert [%{id: "c1", state: :open}, %{id: "c2", state: :waived}] = TicketChecks.list(ctx.issue_id)
  end

  describe "one turn at a time" do
    defp facts_of(prompt), do: prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()

    # Another process holds the ticket's lock, as a turn in flight does, until it is told to let go.
    defp held!(issue_id) do
      test = self()

      holder =
        spawn_link(fn ->
          Conductor.exclusive(issue_id, :wait, fn ->
            send(test, :held)
            receive(do: (:release -> :ok))
          end)
        end)

      assert_receive :held
      holder
    end

    test "one turn answers every message that waits: the reply under the newest, a pointer under each earlier", ctx do
      first = say!(ctx.issue_id, "Keep the search text too.")
      second = say!(ctx.issue_id, "And the sort order.")
      answer = reply(%{"ask" => true, "plan" => answered_plan()})

      assert Message.tend(ctx.issue_id, opts(%{"message" => answer})) == :done

      assert_received {:turn, "message", prompt}
      refute_received {:turn, _junction, _prompt}
      facts = facts_of(prompt)
      assert %{"event_id" => newest, "text" => "And the sort order."} = facts["message"]
      assert newest == second.id
      assert [%{"event_id" => earlier, "text" => "Keep the search text too."}] = facts["earlier_messages"]
      assert earlier == first.id

      assert [pointer, reply] = events(ctx.issue_id, "conductor.update")
      assert %{parent: ^earlier, payload: %{text: "Answered together with your later message, below.", refs: [^newest]}} = pointer
      assert %{parent: ^newest, payload: %{text: "I read it as a hint and passed it on."}} = reply
      # Both messages are what is asked now, in the order they were written.
      assert [_linear, %{from: ^earlier, text: "Keep the search text too."}, %{from: ^newest}] = TicketPlan.ask(ctx.issue_id)
      assert Message.owed(ctx.issue_id) == %{messages: [], asks: [], children: []}
    end

    test "a failed turn is counted on every message it was to answer", ctx do
      first = say!(ctx.issue_id)
      second = say!(ctx.issue_id)

      capture_log(fn -> assert Message.tend(ctx.issue_id, opts(%{"message" => {:error, :boom, 0}})) == :owed end)

      keys = for %{type: "note", idempotency: "message.try:" <> key} <- Facts.events(ctx.issue_id), do: key
      assert keys == ["#{first.id}:1", "#{second.id}:1"]
    end

    test "nothing runs while another turn works on the ticket, and everything stays owed", ctx do
      say!(ctx.issue_id)
      holder = held!(ctx.issue_id)
      no_turn = fn _plan, _issue, _run_id, _prompt -> flunk("no turn runs") end

      assert Conductor.exclusive(ctx.issue_id, :skip, fn -> :ran end) == :busy
      assert Message.tend(ctx.issue_id, opts(%{}, turn: no_turn)) == :owed
      # A tree turn skips too, and asks again at the next poll.
      assert Conductor.tend(issue(ctx.record), "final_check", "default", settings: @on, turn: no_turn) == :ok
      assert events(ctx.issue_id, "run.started") == []

      # A turn that belongs to a dispatch waits for the lock.
      test = self()
      turn = fn _plan, _issue, _run_id, _prompt -> send(test, :dispatch_turn) && {:ok, [~s({"instructions": "Go on."})], 1} end
      run_profile = %{model: "m", effort: nil, provider: "p"}
      plan = %{junction: "after_coding", issue_id: ctx.issue_id, repo_key: "default", timeout_ms: 5_000, run_profile: run_profile}
      waiting = Task.async(fn -> Conductor.run(plan, issue(ctx.record), turn: turn) end)
      refute_receive :dispatch_turn, 100

      send(holder, :release)
      assert Task.await(waiting) == :ok
      assert_received :dispatch_turn
      assert Message.tend(ctx.issue_id, opts(%{"message" => reply()})) == :done
    end

    test "a turn no provider can take, or that a pause stops, waits and is not a failed try", ctx do
      message = say!(ctx.issue_id)
      no_turn = fn _plan, _issue, _run_id, _prompt -> flunk("no turn runs") end

      assert Message.tend(ctx.issue_id, opts(%{}, turn: no_turn, available?: fn _profile -> false end)) == :owed
      assert Message.tend(ctx.issue_id, opts(%{}, turn: no_turn, paused?: &(&1 == :symphony))) == :owed
      assert Conductor.message(issue(ctx.record), message, "default", settings: @on, turn: no_turn, paused?: &(&1 == {:repository, "default"})) == :waiting
      assert status_notes(ctx.issue_id) == []
      assert [%{id: owed}] = Message.owed(ctx.issue_id).messages
      assert owed == message.id
    end

    test "the turn is given every ask and the newest 20 messages", ctx do
      for n <- 1..22 do
        message = say!(ctx.issue_id, "Message #{n}.")
        {:ok, _reply} = TicketEvents.record("default", ctx.issue_id, "conductor.update", %{junction: "message", text: "Reply #{n}.", refs: []}, parent: message.id)
      end

      {:ok, _ask} = TicketPlan.record_ask("default", ctx.issue_id, "And one more thing.", source: "message")
      say!(ctx.issue_id, "The newest.")
      assert Message.tend(ctx.issue_id, opts(%{"message" => reply()})) == :done

      assert_received {:turn, "message", prompt}
      said = facts_of(prompt)["conversation"]
      assert [%{"text" => "Keep my filter."}, %{"text" => "And one more thing."}] = Enum.filter(said, &(&1["kind"] == "ask"))
      messages = Enum.filter(said, &(&1["kind"] == "message"))
      assert length(messages) == 20
      assert %{"text" => "Message 4.", "reply" => %{"text" => "Reply 4."}} = hd(messages)
      assert %{"text" => "The newest."} = List.last(messages)
      # Facts that hold no conversation are left as they are.
      assert Message.facts(%{ticket: %{}}, %{}) == %{ticket: %{}}
    end
  end

  describe "the orchestrator" do
    defp state(attrs) do
      struct!(%Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new(), retry_attempts: %{}}, attrs)
    end

    # No provider can take the Conductor's turn, so what is owed stays owed and no harness starts.
    defp paused(attrs \\ %{}) do
      providers = for profile <- Config.runs(Config.settings!(), :conductor), into: MapSet.new(), do: profile.provider
      state(Map.put(attrs, :paused_providers, providers))
    end

    test "reads the tickets owed a turn on its first poll, and keeps one still owed for the next", ctx do
      conductor_on!()
      message = say!(ctx.issue_id)

      state = Orchestrator.tend_owed_turns_for_test(paused())
      assert state.conductor_owed_read
      assert state.tracker_tasks == %{}
      assert MapSet.member?(state.conductor_owed, ctx.issue_id)
      assert events(ctx.issue_id, "run.started") == []

      # The next poll asks again, and a ticket that is owed nothing any more leaves the list.
      assert Orchestrator.tend_owed_turns_for_test(state).conductor_owed == state.conductor_owed
      {:ok, _reply} = TicketEvents.record("default", ctx.issue_id, "conductor.update", %{junction: "message", text: "Read.", refs: []}, parent: message.id)
      assert Orchestrator.tend_owed_turns_for_test(state).conductor_owed == MapSet.new()
    end

    test "starts what a message owes at once, or once the turn in flight on the ticket ended", ctx do
      conductor_on!()
      say!(ctx.issue_id)
      assert Orchestrator.conductor_owed(self(), ctx.issue_id) == :ok
      assert_received {:"$gen_cast", {:conductor_owed, issue_id}}
      assert issue_id == ctx.issue_id
      assert Orchestrator.conductor_owed(:no_such_orchestrator, ctx.issue_id) == :unavailable

      read = %{conductor_owed_read: true}
      {:noreply, started} = Orchestrator.handle_cast({:conductor_owed, ctx.issue_id}, paused(read))
      assert [%{kind: :tree_turn, issue_ids: [^issue_id]}] = Map.values(started.tracker_tasks)
      assert MapSet.member?(Orchestrator.tend_owed_turns_for_test(started).conductor_owed, ctx.issue_id)

      # A turn works on the ticket: the message waits for it, then its own turn starts.
      in_flight = make_ref()
      busy = paused(Map.put(read, :tracker_tasks, %{in_flight => %{kind: :tree_turn, issue_ids: [ctx.issue_id]}}))
      {:noreply, waiting} = Orchestrator.handle_cast({:conductor_owed, ctx.issue_id}, busy)
      assert Map.keys(waiting.tracker_tasks) == [in_flight]
      assert MapSet.member?(waiting.conductor_owed, ctx.issue_id)

      {:noreply, next} = Orchestrator.handle_info({in_flight, {:tracker_task_result, :ok}}, waiting)
      assert [%{kind: :tree_turn}] = Map.values(next.tracker_tasks)
      assert next.conductor_owed == MapSet.new()

      # A turn that ends with nothing asked for meanwhile starts nothing.
      {:noreply, idle} = Orchestrator.handle_info({in_flight, {:tracker_task_result, :ok}}, busy)
      assert idle.tracker_tasks == %{}
      assert Orchestrator.tend_owed_turns_for_test(next).tracker_tasks == %{}
    end
  end

  describe "a finished ticket" do
    setup ctx do
      record = ticket!(ctx.record.issue_identifier, ctx.issue_id, %{phase: "Done", team: %{key: "MT", name: "Team"}, project: %{id: "p1", name: "App"}, assignee: "user-1"})
      %{record: record}
    end

    test "only the reply and a new ticket are read: the ticket is created on its own, linked and asked", ctx do
      assert Message.finished?(ctx.record)
      refute Message.finished?(%{ctx.record | phase: "In Progress"})
      refute Message.finished?(%{ctx.record | repo_key: "no-such-repo"})
      refute Message.finished?(%{phase: nil})

      message = say!(ctx.issue_id, "Also keep the search text.")

      answer =
        reply(%{
          "ask" => true,
          "plan" => answered_plan(),
          "stop" => %{"reason" => "x"},
          "steer" => %{"message" => "x", "when" => "now"},
          "waive" => [%{"check_id" => "c1", "reason" => "x"}],
          "instructions" => "x",
          "new_ticket" => %{"title" => "Keep the search text", "ask" => "Also keep the search text."}
        })

      assert answer(ctx.record, message, opts(%{"message" => answer}, stop: fn _name -> flunk("a finished ticket has no run") end)) == :ok

      assert_received {:turn, "message", prompt}
      assert prompt =~ "This ticket is finished, so nothing on it changes any more."
      assert_received {:memory_tracker_issue_created, new_id, created}
      assert %{title: "Keep the search text", description: "Also keep the search text.", priority: 1, state: "Todo", team: "MT", project: "p1", assignee_id: "user-1"} = created
      refute Map.has_key?(created, :parent_id)
      identifier = ctx.record.issue_identifier
      assert_received {:memory_tracker_related_added, ^identifier, ^new_id}

      assert [%{source: "message", from: from, text: "Also keep the search text."}] = TicketPlan.ask(new_id)
      assert from == message.id
      assert [%{payload: %{from: ^identifier, by: "conductor", kind: "follow_up"}}] = events(new_id, "ticket.filed_from")

      assert [%{parent: ^from, payload: %{text: text}}] = events(ctx.issue_id, "conductor.update")
      assert text =~ ~r/\AI read it as a hint and passed it on\.\n\nNew ticket: MT-\d+\.\z/
      assert length(TicketPlan.versions(ctx.issue_id)) == 1
      assert length(TicketPlan.ask(ctx.issue_id)) == 1
      assert events(ctx.issue_id, "conductor.instructions") == []
      assert [%{state: :open}] = TicketChecks.list(ctx.issue_id)
    end

    test "a ticket that can't be created or linked is said in the reply or the log, and a malformed one is dropped", ctx do
      new = %{"new_ticket" => %{"title" => "Keep the search text", "ask" => "Also keep the search text.", "repo" => "no-such-repo"}}

      log =
        capture_log(fn ->
          assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(new)})) == :ok
          assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(%{"new_ticket" => %{"title" => "No ask"}})})) == :ok
          assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(%{"new_ticket" => "x"})})) == :ok
          linked = %{"new_ticket" => %{"title" => "Keep the search text", "ask" => "Also keep the search text."}}
          assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(linked)}, tracker: NoLink)) == :ok
        end)

      assert log =~ "Conductor's new ticket was not created"
      assert log =~ "`new_ticket` was dropped"
      assert log =~ "as related to #{ctx.record.issue_identifier}: :linear_down"

      assert [refused, plain, plain, filed] = ctx.issue_id |> events("conductor.update") |> Enum.map(& &1.payload.text)
      assert refused =~ "Symphony could not create the new ticket: the repo \"no-such-repo\" has no team Symphony can file in."
      assert plain == "I read it as a hint and passed it on."
      assert filed =~ "New ticket: MT-"
    end
  end

  describe "a message on a sub-ticket" do
    setup ctx do
      parent = ticket!("MSG-P#{ctx.n}", "msg-p-#{ctx.n}", %{phase: "Waiting on sub-tickets", sub_issues: [%{id: ctx.issue_id, identifier: ctx.record.issue_identifier, state: "In Progress"}]})
      plan!(parent.issue_id)
      record = ticket!(ctx.record.issue_identifier, ctx.issue_id, %{phase: "In Progress", parent: %{id: parent.issue_id, identifier: parent.issue_identifier}})
      %{record: record, parent: parent}
    end

    test "also reaches the parent's Conductor, which records nothing unless it acts", ctx do
      message = say!(ctx.issue_id)
      silent = {:ok, [Jason.encode!(%{"update" => "Noted.", "tree" => []})], 100}

      assert answer(ctx.record, message, opts(%{"message" => reply(), "child_message" => silent})) == :ok

      assert_received {:turn, "message", _prompt}
      assert_received {:turn, "child_message", prompt}
      facts = prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()

      assert facts["child"] == %{
               "identifier" => ctx.record.issue_identifier,
               "event_id" => message.id,
               "message" => "Use the store the sort order uses.",
               "reply" => "I read it as a hint and passed it on."
             }

      assert facts["rules"] =~ "You owe no reply."
      assert [%{"identifier" => _child, "plan" => "The list keeps its filter."}] = facts["sub_tickets"]
      assert events(ctx.parent.issue_id, "conductor.update") == []
      assert [%{payload: %{exit: "answered"}}] = events(ctx.parent.issue_id, "run.ended")
    end

    test "one turn of the parent reads every unread message of its sub-tickets, once each", ctx do
      other = ticket!("MSG-O#{ctx.n}", "msg-o-#{ctx.n}", %{phase: "In Progress", parent: %{id: ctx.parent.issue_id, identifier: ctx.parent.issue_identifier}})
      plan!(other.issue_id)
      subs = for record <- [ctx.record, other], do: %{id: record.issue_id, identifier: record.issue_identifier, state: "In Progress"}
      :ok = RunStore.update_ticket_state(ctx.parent.issue_id, %{sub_issues: subs})
      silent = {:ok, [Jason.encode!(%{"update" => nil, "tree" => []})], 100}
      replies = %{"message" => reply(), "child_message" => silent}

      # Neither is the parent's while its own Conductor has not replied, or with the junction off.
      first = say!(ctx.issue_id, "Use the store.")
      assert Message.owed(ctx.parent.issue_id, settings: @on).children == []
      second = say!(other.issue_id, "Mind the empty list.")
      parent_only = fn task -> if Process.get(:parent_turns), do: task.() end
      assert Message.tend(ctx.issue_id, opts(replies, start: parent_only)) == :done
      assert Message.tend(other.issue_id, opts(replies, start: parent_only)) == :done
      assert Message.owed(ctx.parent.issue_id, settings: %{@on | junctions: ["message"]}).children == []
      identifiers = [ctx.record.issue_identifier, other.issue_identifier]
      assert Enum.map(Message.owed(ctx.parent.issue_id, settings: @on).children, & &1.child) == identifiers
      assert ctx.parent.issue_id in Message.owed_tickets(settings: @on)
      for _child <- identifiers, do: assert_received({:turn, "message", _prompt})

      # The parent waits while no provider can take its turn, and reads nothing.
      assert Message.tend(ctx.parent.issue_id, opts(replies, available?: fn _profile -> false end)) == :owed
      refute_received {:turn, _junction, _prompt}

      assert Message.tend(ctx.parent.issue_id, opts(replies)) == :done
      assert_received {:turn, "child_message", prompt}
      refute_received {:turn, _junction, _prompt}
      facts = prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()
      assert %{"identifier" => newest, "event_id" => newest_id, "message" => "Mind the empty list."} = facts["child"]
      assert [%{"identifier" => older, "event_id" => older_id, "message" => "Use the store.", "reply" => _reply}] = facts["other_children"]
      assert {[older, newest], [older_id, newest_id]} == {identifiers, [first.id, second.id]}

      assert status_notes(ctx.parent.issue_id) == Enum.map(identifiers, &"The Conductor read a message a person wrote on #{&1}.")
      assert Message.owed(ctx.parent.issue_id, settings: @on).children == []
      assert Message.tend(ctx.parent.issue_id, opts(replies)) == :done
      refute_received {:turn, _junction, _prompt}
    end

    test "the parent's answer may change the tree and its plan, and then it says so", ctx do
      test = self()
      identifier = ctx.record.issue_identifier
      acts = %{"update" => "I stopped the sub-ticket.", "tree" => [%{"op" => "stop", "ticket" => identifier, "reason" => "The person changed course."}], "plan" => answered_plan(%{"reason" => nil})}
      stop = fn name -> send(test, {:stopped, name}) && {:ok, %{stopped: true}} end

      assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(), "child_message" => {:ok, [Jason.encode!(acts)], 100}}, stop: stop)) == :ok

      assert_received {:stopped, ^identifier}
      assert [%{parent: nil, payload: %{junction: "child_message", text: "I stopped the sub-ticket."}}] = events(ctx.parent.issue_id, "conductor.update")
      assert [%{payload: %{action: "stopped", by: by}}] = events(ctx.issue_id, "conductor.intervention")
      assert by == ctx.parent.issue_identifier
      assert [_first, %{by: "recalibration", reason: reason}, %{by: "recalibration", reason: "Recalibration: The person changed course."}] = TicketPlan.versions(ctx.parent.issue_id)
      assert reason == "A message on #{identifier} changed the plan."
    end

    test "a parent's turn that fails leaves no reply, since none is owed", ctx do
      capture_log(fn ->
        assert answer(ctx.record, say!(ctx.issue_id), opts(%{"message" => reply(), "child_message" => {:error, :boom, 0}})) == :ok
      end)

      assert events(ctx.parent.issue_id, "conductor.update") == []
    end

    test "a new ask from the parent makes a ticket with a plan write it again", ctx do
      {:ok, ask} = TicketPlan.record_ask("default", ctx.issue_id, "Read the renamed field.", source: "parent", from: ctx.parent.issue_identifier)
      written = {:ok, [Jason.encode!(%{"plan" => Map.delete(answered_plan(), "reason"), "update" => nil})], 100}

      assert Message.recalibrate(ctx.issue_id, ask, opts(%{"message" => written})) == :ok

      assert_received {:turn, "message", prompt}
      facts = prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()
      assert %{"event_id" => _id, "source" => "parent", "from" => _from, "text" => "Read the renamed field."} = facts["new_ask"]
      assert facts["rules"] =~ "Write the plan again"
      refute Map.has_key?(facts, "message")
      assert %{version: 2, by: "recalibration", reason: reason} = TicketPlan.current(ctx.issue_id)
      assert reason == "The ask changed: #{ctx.parent.issue_identifier} asked for something else."
      assert events(ctx.issue_id, "conductor.update") == []
      assert length(TicketPlan.ask(ctx.issue_id)) == 2

      # The plan answers the ask now: it is owed no turn.
      assert Message.recalibrate(ctx.issue_id, ask, opts(%{})) == :ok
      refute_received {:turn, _junction, _prompt}

      # A turn that fails is tried again, 3 times in all, and then the plan stays as it is.
      {:ok, again} = TicketPlan.record_ask("default", ctx.issue_id, "Read the other field.", source: "parent", from: ctx.parent.issue_identifier)
      failing = opts(%{"message" => {:error, :boom, 0}})

      capture_log(fn ->
        assert Message.recalibrate(ctx.issue_id, again, failing) == :ok
        assert Message.tend(ctx.issue_id, failing) == :owed
        assert Message.tend(ctx.issue_id, failing) == :done
        assert Message.tend(ctx.issue_id, failing) == :done
      end)

      assert events(ctx.issue_id, "conductor.update") == []
      assert [_first, _second, third] = status_notes(ctx.issue_id)
      assert third == "The Conductor could not write the plan again for the new ask (the turn failed), 3 times. The plan stays as it is."
      assert %{version: 2} = TicketPlan.current(ctx.issue_id)
      for _try <- 1..3, do: assert_received({:turn, "message", _failed})

      ungroomed = ticket!("MSG-W#{ctx.n}", "msg-w-#{ctx.n}", %{})
      assert Message.recalibrate(ungroomed.issue_id, ask, opts(%{})) == :ok
      assert Message.recalibrate("no-such-ticket", ask, opts(%{})) == :ok
      refute_received {:turn, _junction, _prompt}
    end
  end

  defp issue(record), do: %Issue{id: record.issue_id, identifier: record.issue_identifier, title: record.title, state: record.phase, repo_key: "default"}
end
