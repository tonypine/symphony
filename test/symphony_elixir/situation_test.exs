defmodule SymphonyElixir.SituationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Inbox.{FromRecord, Item}
  alias SymphonyElixir.{Pauses, Questions, Situation, TicketEvents, TicketPullRequest, TicketState, TransitionGuard}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixir.TicketEvents.{Event, Types}

  @repo "default"
  @id "issue-1"
  @at ~U[2026-10-30 09:00:00Z]
  @later ~U[2026-10-30 10:00:00Z]

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp live(overrides \\ %{}) do
    Map.merge(
      %{
        running: %{},
        retrying: %{},
        slot_waiting: %{},
        skipped: %{},
        limit: 4,
        symphony_pause: nil,
        max_tries: 3,
        terminal_states: ["Done", "Canceled", "Duplicate"]
      },
      overrides
    )
  end

  defp record(overrides \\ %{}) do
    TicketState.normalize(Map.merge(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "In Progress", phase_at: @at}, overrides))
  end

  defp watch(facts, overrides \\ %{}) do
    Map.merge(%{facts: struct(Facts, Map.merge(%{phase: :qa, ci: :pending, pr: :open, pr_number: 741}, facts)), head_sha: "abc1234", read_at: @later}, overrides)
  end

  defp event(type, payload, overrides \\ %{}), do: struct(Event, Map.merge(%{type: type, payload: payload, at: @at}, overrides))

  defp pause(reasons) do
    %{subject: {:ticket, @repo, @id}, reasons: Enum.map(reasons, &Map.put_new(&1, :set_at, @at))}
  end

  defp question(overrides \\ %{}) do
    Map.merge(%{id: "q-1", state: :open, title: "How should the times read", asked_at: @at, asked_by: %{kind: :run, name: "Claude", run_id: "run-3"}}, overrides)
  end

  defp started(number \\ 2, kind \\ "rework"), do: event("run.started", %{run_id: "run-3", run_kind: kind, run_number: number})

  defp compute(record, events \\ [], live \\ live()), do: Situation.compute(record, events, live)

  # What makes each kind hold on the ticket in the store; what it arranges only in memory it returns.
  defp arrange("waiting_on_you") do
    {:ok, _question} = Questions.ask({:ticket, @repo, @id}, TransitionGuard.block_report_question("TP-1"), asked_by: %{kind: :run, name: "Claude", run_id: "run-1"}, at: @at)
    %{}
  end

  defp arrange("retrying"), do: %{retrying: %{@id => %{attempt: 1, error: "the agent hit its usage limit", delay_type: :usage_limit, due_at: @later}}}

  defp arrange("blocked_by_ticket") do
    {:ok, _pause} = Pauses.set({:ticket, @repo, @id}, Pauses.ticket_reason(:dependency, "TP-9"), at: @at)
    %{}
  end

  defp arrange("paused_by_rule") do
    reason = %{kind: :person, waits_on: %{action: "unblock"}, text: "Deploy freeze", releasable: true}
    {:ok, _pause} = Pauses.set({:ticket, @repo, @id}, reason, at: @at)
    %{}
  end

  defp arrange("waiting_for_ci") do
    :ok = RunStore.put_ticket_pr_watch(@repo, @id, "TP-1", watch(%{}))
    %{}
  end

  defp arrange("waiting_for_build") do
    reason = %{kind: :build, waits_on: %{commit: "cedfe01"}, text: "Holding for the build of cedfe01"}
    {:ok, _pause} = Pauses.set({:ticket, @repo, @id}, reason, at: @at)
    %{}
  end

  defp arrange("waiting_for_slot"), do: %{slot_waiting: %{@id => %{since: @at, reason: "work slots full"}}}
  defp arrange("working"), do: %{running: %{@id => %{run_kind: "implementation", started_at: @at}}}

  defp arrange("done") do
    :ok = RunStore.update_ticket_state(@id, %{phase: "Done", phase_at: @at})
    %{}
  end

  defp arrange("cancelled") do
    :ok = RunStore.update_ticket_state(@id, %{phase: "Canceled", phase_at: @at})
    %{}
  end

  defp stored_record, do: @id |> RunStore.get_ticket_state() |> TicketState.normalize()

  test "the catalog's kinds are the vocabulary's" do
    assert Types.catalog()["situation.changed"].required[:to] == {:enum, Situation.kinds()}
    assert Types.catalog()["situation.changed"].writers == [:machine]
    assert Types.agent_types("implementation") |> Enum.member?("situation.changed") == false
  end

  describe "the precedence" do
    test "each kind holds alone" do
      for kind <- Situation.kinds() do
        :ok = RunStore.clear()
        :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "In Progress"})
        facts = arrange(kind)

        assert Situation.read(stored_record(), live(facts)).kind == kind
      end
    end

    # `test/fixtures/api/situations.json` is what the Mac app's Situation line decodes: one ticket per
    # kind, each with the fields the API serves for that kind.
    test "the app's fixture holds every kind once, in the payload's shape" do
      fixture = Path.expand("../fixtures/api/situations.json", __DIR__) |> File.read!() |> Jason.decode!()
      samples = Map.new(fixture["issues"], &{&1["situation"]["kind"], &1["situation"]})

      assert Enum.sort(Map.keys(samples)) == Enum.sort(Situation.kinds())
      assert length(fixture["issues"]) == length(Situation.kinds())

      for kind <- Situation.kinds() do
        :ok = RunStore.clear()
        :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "In Progress"})
        facts = arrange(kind)
        served = Situation.read(stored_record(), live(facts)) |> Situation.payload() |> Jason.encode!() |> Jason.decode!()

        assert Enum.sort(Map.keys(samples[kind])) == Enum.sort(Map.keys(served)), kind
        assert served["kind"] == kind
      end
    end

    # One case per pair: the kind listed first wins, whichever was arranged last.
    for {first, index} <- Enum.with_index(~w(waiting_on_you retrying blocked_by_ticket paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled)),
        second <- Enum.drop(~w(waiting_on_you retrying blocked_by_ticket paused_by_rule waiting_for_ci waiting_for_build waiting_for_slot working done cancelled), index + 1) do
      test "#{first} goes before #{second}" do
        :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "In Progress"})
        low = arrange(unquote(second))
        high = arrange(unquote(first))

        assert Situation.read(stored_record(), live(Map.merge(low, high))).kind == unquote(first)
      end
    end

    test "a ticket paused on a Question and blocked by a ticket waits on you, and one more" do
      :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "In Progress"})
      arrange("blocked_by_ticket")
      arrange("waiting_on_you")

      assert %{kind: "waiting_on_you", and_more: 1} = Situation.read(stored_record(), live())
    end

    test "a reason the headline does not name is counted whole" do
      reasons = [%{kind: :ticket, waits_on: %{identifier: "TP-9"}}]
      retrying = live(arrange("retrying"))

      assert %{kind: "retrying", and_more: 1} = compute(record(%{pause: pause(reasons)}), [], retrying)
    end
  end

  describe "waiting_on_you" do
    test "says who asked what, by the run's name in the ledger" do
      assert %{
               word: "Waiting on you",
               cause: "Implementation run 3 asked: How should the times read.",
               next: "Answer below; the next run starts at once.",
               since: @at,
               waits_on: %{question_id: "q-1"}
             } = compute(record(%{questions: [question()]}), [started(3, "implementation")])
    end

    test "names any other asker" do
      assert compute(record(%{questions: [question()]})).cause =~ "A run asked:"
      assert compute(record(%{questions: [question(%{asked_by: %{kind: :person, name: "Director"}})]})).cause =~ "You asked:"
      assert compute(record(%{questions: [question(%{asked_by: %{kind: :rule, name: "The loop guard"}})]})).cause =~ "The loop guard asked:"
      assert compute(record(%{questions: [question(%{asked_by: nil, title: nil, question: nil})]})).cause == "Symphony asked: a question."
    end

    test "a question reason with no open question reads its line" do
      reasons = [%{kind: :question, waits_on: %{question_id: "q-9"}, text: "Waiting for your answer"}]

      situation = compute(record(%{pause: pause(reasons)}))

      assert %{kind: "waiting_on_you", cause: "Waiting for your answer.", waits_on: %{question_id: "q-9"}, and_more: 0} = situation
    end

    test "a plan in review waits on the person" do
      assert %{kind: "waiting_on_you", cause: "The plan is ready for your review.", waits_on: %{phase: "Plan Review"}} = compute(record(%{phase: "Plan Review"}))
    end
  end

  describe "retrying" do
    test "says why, which try and when" do
      due = @later
      facts = live(%{retrying: %{@id => %{attempt: 1, error: "the agent hit its usage limit\nmore", delay_type: :usage_limit, due_at: due}}})

      assert %{
               kind: "retrying",
               word: "Retrying",
               cause: "The run stopped: the agent hit its usage limit.",
               next: next,
               since: @later,
               retry: %{try: 2, of: 3, at: ^due}
             } = compute(record(), [event("run.ended", %{run_id: "run-3", exit: "failed"}, %{at: @later})], facts)

      assert next == "Try 2 of 3 starts at #{Situation.clock(due)}."
    end

    test "past the limit, with no time and no cause" do
      facts = live(%{retrying: %{@id => %{attempt: 3, error: nil, delay_type: nil, due_at: nil}}})

      assert %{cause: "The run stopped.", next: "Try 4 starts soon.", since: @at, retry: %{try: 4, of: nil, at: nil}} = compute(record(), [], facts)
    end

    test "a continuation or a wait is no retry" do
      for delay_type <- [:continuation, :linear_wait, :ci_wait] do
        facts = live(%{retrying: %{@id => %{attempt: 1, error: nil, delay_type: delay_type, due_at: nil}}})
        assert compute(record(), [], facts).kind == "waiting_for_slot"
      end
    end
  end

  describe "blocked_by_ticket" do
    @reasons [%{kind: :ticket, waits_on: %{identifier: "TP-1251"}, text: "Waiting for TP-1251 to finish"}]

    test "names the blocker's phase from its own record" do
      situation = Situation.compute(record(%{pause: pause(@reasons)}), [], live(), fn "TP-1251" -> "Code Review" end)

      assert %{word: "Blocked by TP-1251", cause: "It is in Code Review.", next: "Starts when TP-1251 lands.", since: @at, waits_on: %{ticket: "TP-1251"}, and_more: 0} = situation
    end

    test "falls back on the observed link, then the reason's line" do
      linked = record(%{pause: pause(@reasons), blockers: [%{id: "b", identifier: "TP-1251", state: "QA"}]})

      assert compute(linked).cause == "It is in QA."
      assert compute(record(%{pause: pause(@reasons)})).cause == "Waiting for TP-1251 to finish."
    end

    test "read takes the blocker's phase from the records given, else from the store" do
      paused = record(%{pause: pause(@reasons)})
      blocker = record(%{issue_id: "issue-2", issue_identifier: "TP-1251", phase: "Merging"})

      assert Situation.read(paused, live(), [blocker]).cause == "It is in Merging."

      :ok = RunStore.put_ticket_state(blocker)
      assert Situation.read(paused, live()).cause == "It is in Merging."
    end

    test "a parent waits on its first open sub-ticket" do
      parent = %{phase: "Waiting on sub-tickets", sub_issues: [%{id: "a", identifier: "TP-2", state: "Done"}, %{id: "b", identifier: "TP-3", state: "QA"}]}

      assert %{kind: "blocked_by_ticket", word: "Blocked by TP-3", cause: "It is in QA."} = compute(record(parent))
      assert compute(record(%{parent | sub_issues: [%{id: "b", identifier: "TP-3", state: nil}]})).cause == "It is waiting on its sub-tickets."
    end

    test "a parent whose sub-tickets all ended has its epic review next" do
      ended = %{phase: "Waiting on sub-tickets", sub_issues: [%{id: "a", identifier: "TP-2", state: "Done"}]}

      assert %{kind: "waiting_for_slot", word: "Starting", cause: "The epic review is next and a slot is free."} = compute(record(ended))
      assert %{word: "Starting", cause: "The epic review is next and a slot is free."} = compute(record(%{phase: "Epic Review"}))
    end
  end

  describe "paused_by_rule" do
    test "reads the reason and what lifts it" do
      reasons = [%{kind: :person, waits_on: %{action: "unblock"}, text: "Deploy freeze"}]

      situation = compute(record(%{pause: pause(reasons)}))

      assert %{word: "Paused", cause: "Deploy freeze.", next: "Starts when you unblock it.", since: @at, waits_on: %{action: "unblock"}} = situation
    end

    test "an environment's reason clears by itself" do
      reasons = [%{kind: :environment, waits_on: %{condition: "usage_limit"}, text: "The usage limit is reached."}]

      assert %{cause: "The usage limit is reached.", next: "Starts when that clears."} = compute(record(%{pause: pause(reasons)}))
    end

    test "Backlog waits for a person's move" do
      assert %{kind: "paused_by_rule", cause: "It is in Backlog.", next: "Starts when you move it to Todo."} = compute(record(%{phase: "Backlog"}))
    end

    defp skip(reason, rule \\ nil), do: live(%{skipped: %{@id => %{since: @later, reason: reason, rule: rule}}})

    test "a rule's skip says what passed it over and what lifts it" do
      assert %{kind: "paused_by_rule", cause: "Dispatch is paused: Deploy freeze.", next: "Starts when you resume dispatch.", since: @later} =
               compute(record(), [], skip("Dispatch is paused: Deploy freeze", :symphony_pause))

      assert compute(record(), [], skip("the repository is paused by you", :repository_pause)).next == "Starts when you resume the repository."

      budgets = [:usage_limit, :token_budget, :workspace_quota, :daily_budget]
      settings = [:priority, :reviewer_off, :no_repo_key, :not_assigned]

      for rule <- budgets ++ settings do
        assert %{kind: "paused_by_rule", next: "Starts when that clears."} = compute(record(), [], skip("a rule", rule))
      end

      assert compute(record(), [], live(%{skipped: %{@id => %{rule: :priority}}})).cause == "Dispatch passed over it."
    end

    test "a skip no rule is behind is told by what the ticket waits on" do
      running = %{running: %{@id => %{run_kind: "implementation", started_at: @at}}}

      assert compute(record(), [], Map.merge(skip("already running"), running)).kind == "working"
      assert compute(record(), [], skip("claimed by a retry or a Linear update in flight")).kind == "waiting_for_slot"

      pending = record(%{phase: "Code Review", pr_watch: watch(%{})})
      assert compute(pending, [], skip("the PR watcher (R27): The head is not green")).kind == "waiting_for_ci"
      assert compute(record(%{phase: "Done"}), [], skip("Done is a terminal state")).kind == "done"
      assert compute(record(%{phase: "Canceled"}), [], skip("Canceled is a terminal state")).kind == "cancelled"
    end

    test "a rule stops dispatch and nothing else: a ticket a run works on is working" do
      facts = Map.merge(skip("the repository is paused by you", :repository_pause), %{running: %{@id => %{run_kind: "implementation", started_at: @at}}})

      assert compute(record(), [], facts).kind == "working"
    end

    test "a rule's skip goes before the ticket's wait for a build, which it counts" do
      reasons = [%{kind: :build, waits_on: %{commit: "cedfe01"}, text: "Holding for a build"}]

      assert %{kind: "paused_by_rule", and_more: 1} = compute(record(%{pause: pause(reasons)}), [], skip("the repository is paused by you", :repository_pause))
      assert compute(record(%{pause: pause(reasons)}), [], skip("Holding for a build")).kind == "waiting_for_build"
    end

    test "a slot wait under Symphony's pause is paused: no slot starts it" do
      slot = %{slot_waiting: %{@id => %{since: @at, reason: "work slots full"}}}

      assert %{kind: "paused_by_rule", cause: "Dispatch is paused: Deploy freeze.", next: "Starts when you resume dispatch.", since: @later} =
               compute(record(), [], live(Map.put(slot, :symphony_pause, %{reason: "Deploy freeze", paused_at: @later})))

      assert compute(record(), [], live(Map.put(slot, :symphony_pause, %{}))).cause == "Dispatch is paused."
    end
  end

  describe "waiting_for_ci" do
    test "names the PR, the phase that starts and when the head was pushed" do
      pushed = event("attempt.pushed", %{head: "abc1234"}, %{at: @later})

      assert %{
               word: "Waiting for CI",
               cause: "Checks are running on PR #741.",
               next: "Code Review starts when they pass.",
               since: @later,
               waits_on: %{pr: 741, check: "Tests"}
             } = compute(record(%{phase: "Code Review", pr_watch: watch(%{missing_checks: ["Tests"]})}), [pushed])
    end

    test "TP-1196: a failed check in a run still going reads as waiting for CI" do
      still_going = watch(%{ci: :red, red_kind: :run_in_progress, failing_check: "coverage (4/4)", running_checks: ["coverage (1/4)"]})

      assert %{kind: "waiting_for_ci", waits_on: %{pr: 741, check: "coverage (1/4)"}} = compute(record(%{phase: "Code Review", pr_watch: still_going}))
    end

    test "reads from the watcher when no push names the head" do
      decided = watch(%{}, %{decision: %{since: @at}})

      assert compute(record(%{pr_watch: decided})).since == @at
      assert compute(record(%{pr_watch: watch(%{})})).since == @later
    end

    test "the phase that starts follows the ticket" do
      assert compute(record(%{phase: "QA", pr_watch: watch(%{phase: :qa})})).next == "QA starts when they pass."
      assert compute(record(%{phase: "CI Fix", ci_fix_origin: "Merging", pr_watch: watch(%{phase: :ci_fix})})).next == "Merging starts when they pass."
      assert compute(record(%{phase: "CI Fix", pr_watch: watch(%{phase: :ci_fix})})).next == "Code Review starts when they pass."
      assert compute(record(%{pr_watch: watch(%{phase: :in_progress})})).next == "Code Review starts when they pass."
    end

    test "a Merging hold until CI settles reads as it, from the hold when the watcher has no read" do
      own_hold = %{since: @later, reason: "waiting for CI on abc1234", ci_wait: true}
      hold = live(%{slot_waiting: %{@id => own_hold, "other" => %{since: @at, ci_wait: true}}})

      assert %{
               kind: "waiting_for_ci",
               cause: "Checks are running on its PR.",
               next: "Merging starts when they pass.",
               since: @later,
               waits_on: %{pr: nil, check: nil}
             } = compute(record(%{phase: "Merging"}), [], hold)

      pushed = event("attempt.pushed", %{head: "abc1234", pr_url: "https://github.com/o/r/pull/12"})
      assert %{cause: "Checks are running on PR #12.", waits_on: %{pr: 12}} = compute(record(%{phase: "Merging"}), [pushed], hold)

      read = record(%{phase: "Merging", pr_watch: watch(%{phase: :merging, ci: :green})})
      assert %{kind: "waiting_for_ci", next: "Merging starts when they pass.", since: @later} = compute(read, [], hold)

      paused = %{hold | symphony_pause: %{reason: "Deploy freeze"}}
      assert compute(record(%{phase: "Merging"}), [], paused).kind == "waiting_for_ci"
    end

    test "a PR with no number yet is its PR" do
      assert compute(record(%{pr_watch: watch(%{pr_number: nil})})).cause == "Checks are running on its PR."
    end

    test "a run writing the next head is working, not waiting" do
      facts = live(arrange("working"))

      assert compute(record(%{pr_watch: watch(%{phase: :in_progress})}), [], facts).kind == "working"
      assert compute(record(%{pr_watch: watch(%{phase: :qa})}), [], facts).kind == "waiting_for_ci"
    end

    test "TP-1204: a head Code Review has yet to judge waits for no check; an approved one waits, and QA comes next" do
      refute compute(record(%{pr_watch: watch(%{phase: :code_review})})).kind == "waiting_for_ci"
      red_in_a_run = watch(%{phase: :code_review, ci: :red, red_kind: :run_in_progress})
      refute compute(record(%{pr_watch: red_in_a_run})).kind == "waiting_for_ci"

      approved = compute(record(%{pr_watch: watch(%{phase: :code_review, review: :approved})}))
      assert approved.kind == "waiting_for_ci"
      assert approved.next == "QA starts when they pass."
    end

    test "TP-1204: a Rework head a changes verdict stands on waits for no check; one with none still waits" do
      refute compute(record(%{pr_watch: watch(%{phase: :rework, review: :changes_requested})})).kind == "waiting_for_ci"
      assert compute(record(%{pr_watch: watch(%{phase: :rework})})).kind == "waiting_for_ci"
    end

    test "a head that is not pending, or a PR that is not open, waits for nothing" do
      assert compute(record(%{pr_watch: watch(%{ci: :green})})).kind == "waiting_for_slot"
      assert compute(record(%{pr_watch: watch(%{pr: :closed})})).kind == "waiting_for_slot"
    end
  end

  describe "waiting_for_build" do
    @build [%{kind: :build, waits_on: %{commit: "cedfe01"}, text: "Holding for the build of cedfe01"}]

    test "in QA it follows the design's words" do
      assert %{
               word: "Waiting for a build",
               cause: "The app for this commit is being built for QA.",
               next: "QA starts when the build is ready.",
               since: @at,
               waits_on: %{commit: "cedfe01"}
             } = compute(record(%{phase: "QA", pause: pause(@build)}))
    end

    test "elsewhere it says what it holds for, since QA is not next" do
      assert %{cause: "Holding for the build of cedfe01.", next: "It starts when the build is ready."} = compute(record(%{phase: "Todo", pause: pause(@build)}))
    end
  end

  describe "waiting_for_slot" do
    defp slot_facts(overrides) do
      live(Map.merge(%{slot_waiting: %{@id => %{since: @later, reason: "work slots full"}}}, overrides))
    end

    test "counts the runs ahead in words" do
      running = Map.new(1..3, &{"run-#{&1}", %{}})

      assert %{
               word: "Waiting for a slot",
               cause: "The implementation run is next. Three runs are ahead of it; Symphony runs four at a time.",
               next: "Starts when a slot frees.",
               since: @later,
               waits_on: %{slot: "work slots full"}
             } = compute(record(), [], slot_facts(%{running: running}))
    end

    test "a Merging hold is no run ahead" do
      waiting = %{@id => %{since: @later}, "landing" => %{since: @at, ci_wait: true}}

      assert compute(record(), [], slot_facts(%{slot_waiting: waiting})).cause == "The implementation run is next. No runs are ahead of it; Symphony runs four at a time."
    end

    test "a ticket that waited longer is ahead" do
      waiting = %{@id => %{since: @later}, "other" => %{since: @at}, "newer" => %{since: DateTime.add(@later, 60)}, "unknown" => %{}}

      assert compute(record(), [], slot_facts(%{slot_waiting: waiting})).cause == "The implementation run is next. One run is ahead of it; Symphony runs four at a time."
    end

    test "says none, a large count and no limit" do
      assert compute(record(), [], slot_facts(%{})).cause == "The implementation run is next. No runs are ahead of it; Symphony runs four at a time."
      assert compute(record(), [], slot_facts(%{limit: nil})).cause == "The implementation run is next. No runs are ahead of it."
      assert compute(record(), [], slot_facts(%{limit: 20})).cause == "The implementation run is next. No runs are ahead of it; Symphony runs 20 at a time."

      # A decision that waits on something else names no run.
      wait = %{kind: :wait, rule: "R28", owner: :symphony, reason: "Behind main", clears_when: "it is updated"}
      waits = record(%{phase: "QA", pr_watch: watch(%{ci: :green}, %{decision: wait})})
      assert compute(waits, [], slot_facts(%{})).cause == "No runs are ahead of it; Symphony runs four at a time."
    end

    test "a ticket nothing holds names the run it waits for, which starts on the next pass while a slot is free" do
      assert %{kind: "waiting_for_slot", word: "Starting", cause: "The implementation run is next and a slot is free.", next: "It starts on the next dispatch pass.", since: @at} =
               compute(record())

      dispatch = %{kind: :dispatch, rule: "R27", args: %{phase: :qa}, reason: "The head is green", since: @later}
      decided = record(%{phase: "QA", pr_watch: watch(%{ci: :green}, %{decision: dispatch})})
      assert %{word: "Starting", cause: "The QA run is next and a slot is free: The head is green.", since: @later} = compute(decided)
    end
  end

  describe "TP-1518: the status is always true" do
    @conflict_fix %{kind: :ci_fix, rule: "R14", args: %{origin: :qa, cause: :conflict}, reason: "PR #915 conflicts with main: conflict fix run 1 of 3", outcome: :recorded}
    @silent %{since: @at, ticks: 2, bound: nil, reason: "R14 decided `ci_fix`, but no run started and no wait is recorded"}
    @stalled_reason %{
      kind: :environment,
      waits_on: %{condition: "run_not_started", head: "abc1234"},
      text: "No run started: R14 decided a conflict fix run (PR #915 conflicts with main: conflict fix run 1 of 3), and no run started on it for two poll cycles",
      releasable: true
    }

    defp conflicted(phase, decision, overrides \\ %{}) do
      phase_key = phase |> String.downcase() |> String.replace(" ", "_") |> String.to_atom()
      facts = %{phase: phase_key, ci: :green, mergeable: :dirty, pr_number: 915}
      record(%{phase: phase, pr_watch: watch(facts, Map.merge(%{decision: Map.put(decision, :since, @later)}, overrides))})
    end

    test "TP-1508, 05:44 and 18:02: a conflict fix decided while dispatch is paused names the pause and the run, never a run sent" do
      paused = live(%{symphony_pause: %{reason: "close to limit", paused_at: @at}})
      situation = compute(conflicted("CI Fix", @conflict_fix), [], paused)

      assert %{kind: "paused_by_rule", word: "Paused", next: "Starts when you resume dispatch.", since: @at} = situation
      assert situation.cause == "Dispatch is paused: close to limit. The conflict fix run is next: PR #915 conflicts with main: conflict fix run 1 of 3."
      refute situation.cause =~ "sent"

      assert compute(conflicted("CI Fix", @conflict_fix), [], live(%{symphony_pause: %{}})).cause =~ "Dispatch is paused. The conflict fix run is next"
    end

    test "TP-1508, 19:11: the decision made while a run worked never says a run works once it ended" do
      decision = %{kind: :wait, rule: "R9", owner: :agent, reason: "A run is working on the ticket", clears_when: "the run ends"}
      ended = event("run.ended", %{run_id: "run-3", exit: "blocked"}, %{at: @later})

      situation = compute(conflicted("QA", decision), [started(2, "qa"), ended])
      assert %{kind: "waiting_for_ci", word: "Reading the PR", next: "The next step follows that read.", since: @later} = situation
      assert situation.cause == "The last run ended at #{Situation.clock(@later)}; Symphony reads the PR again next."

      assert compute(conflicted("QA", decision)).cause == "No run is working on it; Symphony reads the PR again next."
    end

    test "TP-1508, 19:11 onward: a conflict fix decided with two slots free is never Waiting for a slot" do
      two_free = live(%{limit: 2})
      situation = compute(conflicted("CI Fix", @conflict_fix), [], two_free)
      assert %{kind: "waiting_for_slot", word: "Starting", next: "It starts on the next dispatch pass."} = situation
      assert situation.cause == "The conflict fix run is next and a slot is free: PR #915 conflicts with main: conflict fix run 1 of 3."

      # The watcher found it never started: it says so, and that Symphony tries again. No Inbox row
      # stands yet, so the words claim none.
      silent = conflicted("CI Fix", @conflict_fix, %{silent: @silent})
      stalled = compute(silent, [], two_free)
      assert %{kind: "waiting_for_slot", word: "Not started", next: "Symphony tries to start it again on its next poll."} = stalled
      assert stalled.cause == "The conflict fix run is due and a slot is free, but no run started yet: PR #915 conflicts with main: conflict fix run 1 of 3."
      assert FromRecord.items([silent], %{}) == []

      # The dispatch pass paused it for that: the words come from that pause, and the Inbox lists it
      # from the same pause.
      held = %{silent | pause: pause([@stalled_reason, %{kind: :person, text: "Held by hand", releasable: true}])}
      assert %{kind: "waiting_on_you", word: "Not started", next: "It is listed in the Inbox; Unblock starts the run.", and_more: 1, since: @at} = compute(held, [], two_free)
      assert compute(held, [], two_free).cause == @stalled_reason.text <> "."
      assert [%{kind: :blocked, issue_id: @id, ask: "No run started: R14" <> _rest}] = FromRecord.items([held], %{})

      # Every slot in use: the slot is what it waits for, and the status names the run.
      full = live(%{limit: 2, running: %{"a" => %{}, "b" => %{}}})
      assert %{kind: "waiting_for_slot", word: "Waiting for a slot", cause: cause} = compute(conflicted("CI Fix", @conflict_fix), [], full)
      assert cause == "The conflict fix run is next: PR #915 conflicts with main: conflict fix run 1 of 3. Two runs are ahead of it; Symphony runs two at a time."
    end

    test "each run a decision needs is named, and a decision that waits says on what in its own words" do
      runs = [
        {%{kind: :ci_fix, args: %{cause: :red}, reason: "The `test` check failed"}, "The CI Fix run"},
        {%{kind: :land_agent, reason: "Branch protection held it"}, "The landing run"},
        {%{kind: :dispatch, args: %{phase: :code_review}, reason: "The reviewer reads it"}, "The review"},
        {%{kind: :dispatch, args: %{phase: :rework}, reason: "The rework run continues"}, "The rework run"},
        {%{kind: :dispatch, args: %{phase: :in_progress}, reason: "The agent continues"}, "The implementation run"},
        {%{kind: :dispatch, args: %{phase: :merging}, reason: "x"}, "The next run"},
        {%{kind: :dispatch, reason: "The head is green"}, "The QA run"}
      ]

      for {decision, label} <- runs do
        assert compute(conflicted("QA", Map.put(decision, :rule, "R")), [], live(%{limit: 1, running: %{"a" => %{}}})).cause =~ "#{label} is next", label
      end

      waits = [
        {%{owner: :ci, reason: "Checks are running", clears_when: "the checks finish"}, "waiting_for_ci", "Waiting for CI", "It moves on when the checks finish."},
        {%{owner: :github, reason: "GitHub is still computing whether PR #915 can merge", clears_when: "GitHub reports whether the PR can merge"}, "waiting_for_ci", "Waiting on GitHub",
         "It moves on when GitHub reports whether the PR can merge."},
        {%{owner: :person, reason: "A person marked PR #915 as a draft", clears_when: "the PR is marked ready for review."}, "waiting_on_you", "Waiting on you",
         "It moves on when the PR is marked ready for review."},
        {%{owner: :symphony, reason: "PR #915 is behind main", clears_when: nil}, "waiting_for_ci", "Waiting on Symphony", nil}
      ]

      for {wait, kind, word, next} <- waits do
        decision = Map.merge(%{kind: :wait, rule: "R"}, wait)
        assert %{kind: ^kind, word: ^word, cause: cause, next: ^next, since: @later} = compute(conflicted("QA", decision))
        assert cause == wait.reason <> "."
      end
    end

    test "when Symphony can't tell what the ticket waits on, it says exactly that, and the Inbox lists it" do
      to_rework = conflicted("QA", %{kind: :to_rework, rule: "R15a", reason: "x"})
      unknowns = [to_rework, record(%{phase: "Human Review"})]

      for record <- unknowns do
        assert %{kind: "waiting_on_you", word: "Not known", cause: "Symphony can't tell what it waits on.", next: "It is listed in the Inbox; check it now from its page.", since: @at} =
                 compute(record)

        assert Situation.not_known?(record, live())
        assert [%{kind: :blocked, ask: "Symphony can't tell what it waits on", waiting_since: @at, review: %{clearing_condition: clears}}] = FromRecord.items([record], %{})
        assert clears =~ "when Symphony can tell what it waits on"
      end

      # A record of no phase is no ticket Symphony tracks: it lists nothing and claims no row.
      assert %{word: "Not known", next: "Check it now from its page."} = compute(record(%{phase: nil}))
      refute Situation.not_known?(record(%{phase: nil}), live())

      # A run working on it, or a known wait, is no unknown.
      refute Situation.not_known?(to_rework, live(%{running: %{@id => %{run_kind: "qa"}}}))
      assert FromRecord.items([to_rework], %{running: [%{issue_id: @id, run_kind: "qa"}]}) == []
      refute Situation.not_known?(record(), live())
    end

    test "a ticket in a phase whose run waits on the watcher, which has not decided on its PR yet, reads the PR next" do
      merging = record(%{phase: "Merging", pr_watch: watch(%{phase: :merging, ci: :green}, %{decision: nil})})
      unread = [record(%{phase: "QA"}), record(%{phase: "Code Review"}), merging]

      for record <- unread do
        assert %{kind: "waiting_for_ci", word: "Reading the PR", cause: "The PR watcher reads its PR next.", next: "The next step follows that read.", since: @at} = compute(record)
        refute Situation.not_known?(record, live())
        assert FromRecord.items([record], %{}) == []
      end

      # A decision made in the phase the ticket has left (R25 moved it from CI Fix to QA) is done: the
      # watcher reads the PR in its new phase next, and the Inbox lists nothing.
      returned = %{conflicted("CI Fix", %{kind: :return_to_origin, rule: "R25", args: %{origin: :qa}, reason: "x"}) | phase: "QA"}
      assert %{word: "Reading the PR", cause: "The PR watcher reads its PR next."} = compute(returned)
      refute Situation.not_known?(returned, live())
      assert FromRecord.items([returned], %{}) == []

      # CI Fix runs with no decision: its run is next.
      assert %{word: "Starting", cause: "The CI Fix run is next and a slot is free."} = compute(record(%{phase: "CI Fix"}))
    end

    test "a decision that waits says what it waits on with or without what clears it" do
      decision = %{kind: :wait, rule: "R", owner: :person, reason: "A person marked PR #915 as a draft"}
      assert %{word: "Waiting on you", next: nil} = compute(conflicted("QA", decision))
    end

    # Each status the Director can show, and the states where its words would be false: none of them shows it.
    test "no status is shown in a state where its words are false" do
      decisions = [
        nil,
        @conflict_fix,
        %{kind: :dispatch, rule: "R27", args: %{phase: :qa}, reason: "The head is green"},
        %{kind: :wait, rule: "R9", owner: :agent, reason: "A run is working on the ticket", clears_when: "the run ends"},
        %{kind: :wait, rule: "R16", owner: :github, reason: "GitHub is still computing", clears_when: "GitHub reports"},
        %{kind: :wait, rule: "R24", owner: :ci, reason: "Checks are running", clears_when: "the checks finish"}
      ]

      lives = [
        live(%{limit: 2}),
        live(%{limit: 2, running: %{"a" => %{}, "b" => %{}}}),
        live(%{limit: 2, symphony_pause: %{reason: "close to limit"}}),
        live(%{limit: 2, slot_waiting: %{@id => %{since: @at}}, running: %{"a" => %{}, "b" => %{}}}),
        live(%{limit: 2, running: %{@id => %{run_kind: "ci_fix", started_at: @at}}})
      ]

      pauses = [nil, pause([@stalled_reason])]

      phases = ["Todo", "In Progress", "QA", "CI Fix", "Merging", "Human Review"]

      for phase <- phases, decision <- decisions, silent <- [nil, @silent], live <- lives, held <- pauses do
        # The silence is the watcher's record of its decision: a ticket with no decision has none.
        silent = if decision, do: silent
        record = if decision, do: conflicted(phase, decision, %{silent: silent}), else: record(%{phase: phase})
        record = %{record | pause: held}
        situation = compute(record, [], live)
        state = inspect({phase, decision && decision.rule, silent != nil, live})
        free? = map_size(live.running) < live.limit
        running? = Map.has_key?(live.running, @id)

        if situation.word == "Waiting for a slot", do: assert(not free? or Map.has_key?(live.slot_waiting, @id), state)
        if situation.kind == "working", do: assert(running?, state)
        if situation.word == "Paused", do: assert(live.symphony_pause != nil, state)
        if situation.word == "Starting", do: assert(free? and live.symphony_pause == nil and silent == nil, state)
        if situation.word == "Not started", do: assert((free? and silent != nil) or held != nil, state)
        if situation.word == "Not known", do: assert(Situation.not_known?(record, live), state)
        if situation.word == "Reading the PR", do: assert(match?(%{owner: :agent}, decision) or is_nil(decision), state)

        # A status that says the Inbox lists the ticket is shown only where the Inbox has its row.
        if situation.next =~ "listed in the Inbox",
          do: assert(Situation.not_known?(record, live) or Item.from_pause(record, record.pause) != nil, state)

        if situation.word == "Waiting for CI", do: assert(match?(%{owner: :ci}, decision), state)
        refute situation.cause =~ "already sent", state
        refute situation.cause =~ "A run is working" and not running?, state
        if running?, do: assert(situation.kind == "working", state)
      end
    end
  end

  describe "working" do
    test "names the step, the run and what hands it off" do
      events = [
        started(),
        event("step.started", %{step_id: "code", title: "Write the code", mode: "delegated"}, %{run_id: "run-3"}),
        event("step.completed", %{step_id: "code", title: "Write the code", mode: "delegated", outcome: "passed"}, %{run_id: "run-3"}),
        event("step.started", %{step_id: "tests", title: "Tests and coverage", mode: "machine"}, %{run_id: "run-3", at: @later})
      ]

      assert %{
               kind: "working",
               word: "Working on the tests step",
               cause: "Rework run 2 is answering the review's findings.",
               next: "It hands off to Code Review when it pushes.",
               since: @later,
               waits_on: %{step: "tests", run_id: "run-3"},
               step: %{id: "tests", title: "Tests and coverage"},
               run: %{id: "run-3", kind: "rework", number: 2, label: "Rework run 2"}
             } = compute(record(), events, live(%{running: %{@id => %{run_kind: "rework", started_at: @at}}}))
    end

    test "with no step open it reads the run" do
      running = live(%{running: %{@id => %{run_kind: :qa, started_at: @at}}})

      assert %{word: "Working", cause: "QA run is walking the user journeys.", next: "It hands off to Merging when it passes.", since: @at, step: nil, waits_on: nil} = compute(record(), [], running)

      completed = event("step.completed", %{step_id: "code", title: "Write", mode: "delegated", outcome: "passed"}, %{run_id: "run-3"})
      assert compute(record(), [started(), completed], running).step == nil
    end

    test "takes the step the orchestrator holds when the ledger names none" do
      step = %{id: "build", title: "Build", started_at: @later}
      running = live(%{running: %{@id => %{run_kind: "implementation", started_at: @at, step: step}}})

      assert %{word: "Working on the build step", since: @later, step: %{id: "build", title: "Build"}} = compute(record(), [], running)
    end

    test "a run the ledger ended is not the run now" do
      ended = event("run.ended", %{run_id: "run-3", exit: "normal"})
      running = live(%{running: %{@id => %{run_kind: nil, started_at: @at}}})

      situation = compute(record(), [started(), ended], running)

      assert %{cause: "Run is working on it.", next: "It hands off when it ends.", run: %{id: nil, number: nil, label: "Run"}} = situation
    end

    test "a CI Fix hands back where it came from" do
      running = live(%{running: %{@id => %{run_kind: "ci_fix", started_at: @at}}})

      assert compute(record(), [], running).next == "It hands back to Code Review when it pushes."
      assert compute(record(%{ci_fix_origin: "QA"}), [], running).next == "It hands back to QA when it pushes."
    end
  end

  describe "done" do
    test "says the PR and the time" do
      expected = "Merged as PR #741 at #{Situation.clock(@at)}."

      done = record(%{phase: "Done", pr_watch: watch(%{pr: :merged})})

      assert %{word: "Shipped", cause: ^expected, next: nil, since: @at} = compute(done)
    end

    test "a merged PR is done before the phase says so" do
      assert compute(record(%{phase: "Merging", pr_watch: watch(%{pr: :merged})})).kind == "done"
    end

    test "before the phase says so, the merge's time is the watcher's read of it, not when it entered Merging" do
      expected = "Merged as PR #741 at #{Situation.clock(@later)}."

      merging = %{phase: "Merging", phase_at: @at}

      assert %{cause: ^expected, since: @later} = compute(record(Map.put(merging, :pr_watch, watch(%{pr: :merged}))))
      assert %{since: @at} = compute(record(Map.put(merging, :pr_watch, watch(%{pr: :merged}, %{read_at: nil}))))
    end

    test "reads the PR from the ledger, else from the ticket's pull request" do
      pushed = event("attempt.pushed", %{head: "abc1234", pr_url: "https://github.com/o/r/pull/12"})
      done = record(%{phase: "Done"})

      assert compute(done, [pushed]).cause =~ "PR #12 "

      :ok = TicketPullRequest.put(@repo, @id, %{pr_url: "https://github.com/o/r/pull/13", branch: "auto/TP-1", source: "created"})
      assert compute(done).cause =~ "PR #13 "
    end

    test "without a PR or a time it says what it knows" do
      assert compute(record(%{phase: "Done"})).cause == "It is done."
      assert compute(record(%{phase: "Done"}), [event("attempt.pushed", %{head: "abc1234"})]).cause == "It is done."
      assert compute(record(%{phase: "Done", phase_at: nil, pr_watch: watch(%{pr: :merged})})).cause == "Merged as PR #741."
      assert compute(record(%{phase: "Done", issue_id: nil})).cause == "It is done."
    end
  end

  describe "cancelled" do
    test "says who cancelled it and the PR it closed" do
      payload = %{from: "QA", to: "Canceled", pull_requests_closed: ["https://github.com/o/r/pull/812"]}
      cancel = event("ticket.cancelled", payload, %{actor: %{kind: :person, name: "Director"}, at: @later})

      assert %{word: "Cancelled", cause: "You cancelled it; PR #812 was closed.", next: nil, since: @later} = compute(record(%{phase: "Canceled"}), [cancel])
    end

    test "without a person's move or a PR" do
      plain = event("ticket.cancelled", %{from: "QA", to: "Canceled"}, %{actor: %{kind: :machine}})

      assert compute(record(%{phase: "Canceled"}), [plain]).cause == "It was cancelled."
      assert %{cause: "It was cancelled.", since: @at} = compute(record(%{phase: "Duplicate"}))
    end

    test "a closed PR with no number in its link names none" do
      odd = event("ticket.cancelled", %{from: "QA", to: "Canceled", pull_requests_closed: ["not a link"]}, %{actor: %{kind: :person, name: "Director"}})

      assert compute(record(%{phase: "Canceled"}), [odd]).cause == "You cancelled it."
    end
  end

  test "a cause stays within what the event keeps" do
    long = String.duplicate("a", 400)
    facts = live(%{retrying: %{@id => %{attempt: 0, error: long, delay_type: nil, due_at: nil}}})

    cause = compute(record(), [], facts).cause

    assert String.length(cause) == 300
    assert String.ends_with?(cause, "…")
  end

  test "the payload gives the times in ISO 8601" do
    facts = live(%{retrying: %{@id => %{attempt: 0, error: nil, delay_type: nil, due_at: @later}}})

    assert %{since: "2026-10-30T09:00:00Z", retry: %{at: "2026-10-30T10:00:00Z"}} = record() |> compute([], facts) |> Situation.payload()
    assert %{since: nil, retry: nil} = record(%{phase_at: nil}) |> compute() |> Situation.payload()
    no_time = live(%{retrying: %{@id => %{attempt: 0, error: nil, delay_type: nil, due_at: nil}}})
    assert %{retry: %{at: nil}} = record() |> compute([], no_time) |> Situation.payload()
  end

  test "clock says the hour and minute on this host's clock" do
    {_date, {hour, minute, _second}} = :calendar.universal_time_to_local_time({{2026, 10, 30}, {9, 5, 0}})
    expected = :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()

    assert Situation.clock(~U[2026-10-30 09:05:00Z]) == expected
  end

  describe "live_facts/2" do
    test "keeps what situations read of a snapshot" do
      snapshot = %{
        running: [%{issue_id: "a", run_kind: "qa", started_at: @at, step: nil, transcript_buffer: ["large"]}],
        retrying: [%{issue_id: "b", attempt: 2, due_in_ms: 60_000, error: "boom", delay_type: nil}, %{issue_id: "c"}],
        slot_waiting: [%{issue_id: "d", since: @at, reason: "work slots full"}],
        dispatch_skipped: [%{issue_id: "e", since: @at, reason: "gate", rule: :priority, repo_key: @repo}],
        concurrency: %{max_total: 4},
        pause: %{paused: true, reason: "Deploy freeze", paused_at: @at, reasons: []}
      }

      facts = Situation.live_facts(snapshot, @at)

      assert facts.running == %{"a" => %{run_kind: "qa", started_at: @at, step: nil}}
      assert facts.retrying["b"] == %{attempt: 2, error: "boom", delay_type: nil, due_at: ~U[2026-10-30 09:01:00.000Z]}
      assert facts.retrying["c"].due_at == nil
      assert facts.slot_waiting["d"].reason == "work slots full"
      assert facts.skipped["e"] == %{since: @at, reason: "gate", rule: :priority}
      assert %{limit: 4, symphony_pause: %{reason: "Deploy freeze", paused_at: @at}} = facts
      assert facts.max_tries == 4
      assert "Done" in facts.terminal_states
    end

    test "a snapshot with the lists left out reads as nothing" do
      assert %{running: map, limit: nil, symphony_pause: nil} = Situation.live_facts(%{})
      assert map == %{}
      assert %{symphony_pause: nil} = Situation.live_facts(%{pause: %{paused: false, reason: nil}})
    end

    test "the signature says what decides a kind" do
      retrying = %{"b" => %{delay_type: :continuation}, "c" => %{delay_type: nil}}
      slots = %{"d" => %{}, "f" => %{ci_wait: true}}
      skipped = %{"e" => %{rule: :priority}, "g" => %{rule: nil}}
      facts = live(%{running: %{"a" => %{}}, retrying: retrying, slot_waiting: slots, skipped: skipped})

      assert Situation.live_signature(facts) == %{
               "a" => {true, false, nil, nil},
               "b" => {false, false, nil, nil},
               "c" => {false, true, nil, nil},
               "d" => {false, false, :slot, nil},
               "e" => {false, false, nil, :priority},
               "f" => {false, false, :ci, nil},
               "g" => {false, false, nil, nil}
             }

      assert Situation.live_signature(%{facts | symphony_pause: %{}})["d"] == {false, false, :paused, nil}
    end
  end

  describe "sync/3" do
    setup do
      :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: @id, issue_identifier: "TP-1", phase: "Todo"})
    end

    defp changes, do: TicketEvents.query(@id, types: ["situation.changed"], limit: :all)

    test "writes one event per change, with the old and the new kind and the cause" do
      assert {:ok, %Event{payload: first}} = Situation.sync(stored_record(), live(arrange("waiting_for_slot")))

      assert first == %{
               to: "waiting_for_slot",
               word: "Waiting for a slot",
               cause: "The implementation run is next. No runs are ahead of it; Symphony runs four at a time.",
               since: "2026-10-30T09:00:00Z"
             }

      assert Situation.sync(stored_record(), live(arrange("waiting_for_slot"))) == :unchanged

      assert {:ok, %Event{payload: second, phase: "Todo"} = event} = Situation.sync(stored_record(), live(arrange("working")))
      assert %{from: "waiting_for_slot", to: "working", cause: "Implementation run is writing the code."} = second
      assert event.actor == %{kind: :machine}
      assert %{title: "Working", detail: "Implementation run is writing the code."} = event.summary

      assert [_first, _second] = changes()
    end

    test "a read never writes" do
      for _read <- 1..3, do: Situation.read(stored_record(), live(arrange("working")))

      assert changes() == []
    end

    test "a record with no ticket writes nothing" do
      assert Situation.sync(%{}, live()) == {:error, :invalid_issue_id}
    end
  end

  test "a read of a record with no ticket reads an empty ledger" do
    assert %{kind: "waiting_on_you", word: "Not known"} = Situation.read(nil, live())
  end
end
