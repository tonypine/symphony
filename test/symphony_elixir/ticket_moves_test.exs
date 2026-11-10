defmodule SymphonyElixir.TicketMovesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    DirectorMoves,
    IdlePark,
    Pauses,
    Questions,
    StartNow,
    SubIssueWait,
    TicketMoves,
    TicketSignals,
    TicketState,
    TransitionGuard
  }

  @waiting "Waiting on sub-tickets"

  defmodule MissingStateTracker do
    def workflow_state_exists?(_state, _teams), do: {:ok, false}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    SubIssueWait.reset_for_test(@waiting)
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        identifier: "MT-1",
        repo_key: "default",
        phase: "In Progress",
        recorded?: true,
        tracked?: true,
        labels: [],
        symphony_pause: nil,
        repository_pause: nil,
        open_question?: false,
        running?: false,
        unblockable?: false
      },
      overrides
    )
  end

  defp live, do: %{identifier: "MT-1", repo_key: "default", symphony_pause: nil, repository_pause: nil, running?: false}

  defp record_of(issue_id) do
    RunStore.get_ticket_state(issue_id) |> TicketState.normalize()
  end

  defp allowed(move, overrides), do: assert(TicketMoves.check(move, facts(overrides)) == :ok)
  defp refused(move, overrides, reason), do: assert(TicketMoves.check(move, facts(overrides)) == {:error, reason})

  test "answer needs an open question" do
    allowed(:answer, %{open_question?: true})
    refused(:answer, %{}, "MT-1 is not waiting on a decision")
  end

  test "start answers as Start now does, and needs a repository" do
    allowed(:start, %{})
    refused(:start, %{running?: true}, "A run is already working on it.")
    refused(:start, %{open_question?: true}, "It waits on your answer first.")
    refused(:start, %{phase: "Done"}, "The ticket is done.")
    refused(:start, %{symphony_pause: "dispatch is paused by the operator"}, "dispatch is paused by the operator")
    refused(:start, %{repo_key: nil}, StartNow.no_repository_reason())
  end

  test "stop needs a run" do
    allowed(:stop, %{running?: true})
    refused(:stop, %{}, "No run is working.")
  end

  test "restart and cancel need an open ticket Symphony holds" do
    for move <- [:restart, :cancel] do
      allowed(move, %{})
      refused(move, %{phase: "Done"}, "The ticket is done.")
      refused(move, %{phase: "Canceled"}, "The ticket is cancelled.")
      refused(move, %{phase: "Cancelled"}, "The ticket is cancelled.")
      refused(move, %{phase: "Duplicate"}, "The ticket is duplicate.")
      refused(move, %{phase: nil, recorded?: false}, "The ticket is not one Symphony tracks.")
      allowed(move, %{phase: nil})
    end
  end

  test "move_to needs a repository and a phase, and lists the phases but the one it is in" do
    allowed(:move_to, %{})
    refused(:move_to, %{repo_key: nil}, TicketMoves.no_repository_reason("MT-1"))
    refused(:move_to, %{phase: nil}, "The ticket is not one Symphony tracks.")

    assert %{allowed: true, reason: nil, states: states} = TicketMoves.read(facts()).move_to
    assert states == DirectorMoves.phases(Config.settings!()) -- ["In Progress"]
    assert %{allowed: false, states: []} = TicketMoves.read(facts(%{phase: nil})).move_to
  end

  test "force needs an open ticket that isn't forced; unforce one that is" do
    force_label = Config.settings!().agent.force_label

    allowed(:force, %{})
    refused(:force, %{labels: [String.upcase(force_label)]}, "It is already forced.")
    refused(:force, %{phase: "Done"}, "The ticket is done.")
    refused(:force, %{phase: nil, recorded?: false}, "The ticket is not one Symphony tracks.")
    allowed(:force, %{phase: nil})

    allowed(:unforce, %{labels: [force_label]})
    refused(:unforce, %{}, "It isn't forced.")
    refused(:unforce, %{phase: nil}, "The ticket is not one Symphony tracks.")
  end

  test "unblock needs something to release" do
    allowed(:unblock, %{unblockable?: true})
    refused(:unblock, %{}, "MT-1 has nothing a person can unblock")
  end

  test "note needs a record; it takes one removed in Linear" do
    allowed(:note, %{tracked?: false})
    refused(:note, %{recorded?: false}, "No ticket MT-1 in default")
    refused(:note, %{recorded?: false, repo_key: nil}, "No ticket MT-1 in any repository")
  end

  test "blocker, priority, labels and ruling need a ticket Symphony tracks" do
    for {move, reason} <- [
          {:blocker, "Symphony doesn't track MT-1, so it can't be linked as a blocker or be given one."},
          {:priority, "Symphony doesn't track MT-1, so it can't set its priority."},
          {:labels, "Symphony doesn't track MT-1, so it can't change its labels."},
          {:ruling, "Symphony doesn't track MT-1, so it can't record a decision on it."}
        ] do
      allowed(move, %{})
      refused(move, %{tracked?: false}, reason)
    end
  end

  test "approve_plan, decisions and changes need a plan in Plan Review; rework a ticket there" do
    plan = %{labels: ["plan"], phase: "Plan Review"}

    for move <- [:approve_plan, :decisions, :changes] do
      allowed(move, plan)
      refused(move, %{plan | labels: []}, "MT-1 is not a plan; #{move} is for a plan")
      refused(move, %{plan | phase: "In Progress"}, "MT-1 is In Progress; the Director answers it only from Plan Review")
      refused(move, %{plan | phase: nil}, "MT-1 is in no state; the Director answers it only from Plan Review")
    end

    allowed(:approve_plan, %{plan | labels: ["breakdown"]})
    allowed(:rework, %{phase: "Plan Review"})
    refused(:rework, %{}, "MT-1 is In Progress; the Director answers it only from Plan Review")
  end

  test "approve_plan is refused while the waiting state is turned off" do
    capture_log(fn ->
      :disabled = SubIssueWait.check_tracker_state(Config.settings!(), [], tracker: MissingStateTracker)
    end)

    refused(:approve_plan, %{labels: ["plan"], phase: "Plan Review"}, "the waiting state is turned off, so a plan can't be approved from the app")
  end

  test "the plan moves are refused while the Plan Review state is turned off" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_plan_review_state: nil)

    refused(:rework, %{phase: "Plan Review"}, "the Plan Review state is turned off, so the Director can't answer MT-1 from the app")
  end

  test "backlog needs an open ticket not there yet" do
    allowed(:backlog, %{})
    refused(:backlog, %{phase: " backlog "}, "MT-1 is already in Backlog")
    refused(:backlog, %{phase: "Done"}, "The ticket is done.")
    refused(:backlog, %{phase: nil, recorded?: false}, "The ticket is not one Symphony tracks.")
    allowed(:backlog, %{phase: nil})
  end

  test "read carries every move, its reason when refused, and start in the shape the app reads" do
    moves = TicketMoves.read(facts(%{running?: true}))

    assert Enum.sort(Map.keys(moves)) == Enum.sort(TicketMoves.moves())
    assert moves.start == %{allowed: false, reason: "A run is already working on it."}
    assert moves.stop == %{allowed: true, reason: nil}
  end

  # `test/fixtures/api/ticket_moves.json` is what the Mac app's Action rail decodes: the `moves` of a
  # few tickets, each with the facts it was read on. Each move is the read's, word for word; only the
  # phases `move_to` lists depend on the workflow, so they are checked as a list.
  test "the app's fixture holds the moves the read serves for its facts" do
    fixture = Path.expand("../fixtures/api/ticket_moves.json", __DIR__) |> File.read!() |> Jason.decode!()

    for %{"name" => name, "facts" => given, "moves" => moves} <- fixture["tickets"] do
      served =
        facts(%{
          identifier: fixture["identifier"],
          phase: given["phase"],
          running?: given["running"],
          open_question?: given["open_question"],
          unblockable?: given["unblockable"]
        })
        |> TicketMoves.read()
        |> Jason.encode!()
        |> Jason.decode!()

      assert Map.keys(moves) -- Map.keys(served) == [], name

      for {move, entry} <- moves do
        assert Map.drop(entry, ["states"]) == Map.drop(served[move], ["states"]), "#{name} #{move}"
      end

      assert is_list(moves["move_to"]["states"]), name
    end
  end

  describe "facts/2" do
    test "no record: nothing is known of the ticket but what the caller knows" do
      facts = TicketMoves.facts(nil, %{live() | running?: true})

      assert %{phase: nil, recorded?: false, tracked?: false, labels: [], identifier: "MT-1"} = facts
      assert %{open_question?: false, unblockable?: false, running?: true} = facts
    end

    test "a record says its phase and labels, and a removed one is no longer tracked" do
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "one", issue_identifier: "MT-1", phase: "Todo", labels: ["plan"]})
      assert %{phase: "Todo", labels: ["plan"], recorded?: true, tracked?: true, unblockable?: false} = TicketMoves.facts(record_of("one"), live())

      :ok = RunStore.update_ticket_state("one", %{removed_at: DateTime.utc_now()})
      assert %{recorded?: true, tracked?: false} = TicketMoves.facts(record_of("one"), live())
    end

    test "a record with no phase has nothing to release" do
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "none", issue_identifier: "MT-1"})
      assert %{phase: nil, recorded?: true, unblockable?: false} = TicketMoves.facts(record_of("none"), live())
    end

    test "a question Unblock answers is open and makes it unblockable; one it doesn't is only open" do
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "held", issue_identifier: "MT-1", phase: "In Progress"})
      {:ok, _question} = Questions.ask({:ticket, "default", "held"}, TransitionGuard.block_report_question("MT-1"))
      assert %{open_question?: true, unblockable?: true} = TicketMoves.facts(record_of("held"), live())

      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "asked", issue_identifier: "MT-2", phase: "In Progress"})

      {:ok, _question} =
        Questions.ask({:ticket, "default", "asked"}, %{
          title: "Add it",
          question: "Add it?",
          why: "Only you can decide.",
          if_unanswered: "It waits.",
          recommendation_reason: "It is safe.",
          options: [%{label: "Add it", effect: "It is added.", recommended: true}, %{label: "Leave it", effect: "Nothing changes."}]
        })

      assert %{open_question?: true, unblockable?: false} = TicketMoves.facts(record_of("asked"), live())
    end

    test "a stop is released by Unblock; a wait on a blocker is not" do
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "stopped", issue_identifier: "MT-1", phase: "In Progress"})
      reason = %{kind: :environment, waits_on: %{condition: "stop"}, text: "Stopped", releasable: true}
      {:ok, _pause} = Pauses.set({:ticket, "default", "stopped"}, reason)
      assert %{unblockable?: true} = TicketMoves.facts(record_of("stopped"), live())

      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "waiting", issue_identifier: "MT-2", phase: "In Progress"})
      {:ok, _pause} = Pauses.set({:ticket, "default", "waiting"}, Pauses.ticket_reason(:dependency, "MT-3"))
      assert %{unblockable?: false} = TicketMoves.facts(record_of("waiting"), live())

      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "landing", issue_identifier: "MT-4", phase: "In Progress"})
      {:ok, _pause} = Pauses.set({:ticket, "default", "landing"}, Pauses.ticket_reason(:landing, "MT-5"))
      assert %{unblockable?: true} = TicketMoves.facts(record_of("landing"), live())
    end

    test "a ticket an idle run parked in Backlog is unblockable; one that is just in Backlog is not" do
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "just", issue_identifier: "MT-1", phase: "Backlog"})
      assert %{unblockable?: false} = TicketMoves.facts(record_of("just"), live())

      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "parked", issue_identifier: "MT-2", phase: "Backlog"})
      :ok = TicketSignals.record("default", "parked", "blocked", %{to: "Backlog", reason: IdlePark.signal_reason(), from: "In Progress"})
      assert %{unblockable?: true} = TicketMoves.facts(record_of("parked"), live())
    end
  end

  test "issue_facts/1 reads a ticket a call read" do
    issue = %Issue{id: "i", identifier: "MT-1", state: "Plan Review", labels: nil, repo_key: "default"}

    facts = TicketMoves.issue_facts(issue)

    assert %{identifier: "MT-1", phase: "Plan Review", labels: [], repo_key: "default"} = facts
    assert %{recorded?: true, tracked?: true} = facts
  end
end
