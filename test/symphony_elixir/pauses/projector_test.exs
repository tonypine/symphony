defmodule SymphonyElixir.Pauses.ProjectorTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Decisions, Pauses, Questions, TicketState, Workflow}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses.Projector

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}
  @at ~U[2026-10-30 04:00:00Z]
  @description "Ship the release notes.\n\n## Acceptance criteria\n\n* Notes ship."

  @request %{
    title: "Ship TP-12 before the release",
    question: "Should TP-12 ship today, before the release goes out?",
    why: "TP-12 is ready. The release goes out tomorrow.",
    if_unanswered: "TP-12 waits and does not ship.",
    recommendation_reason: "Shipping today gives the release a day of use.",
    options: [
      %{label: "Ship today", effect: "TP-12 merges today.", recommended: true},
      %{label: "Wait for the release", effect: "TP-12 merges with the release."}
    ]
  }

  defmodule RaisingTracker do
    def set_machine_label(_issue_id, _name), do: raise("Linear is down")
    def clear_machine_label(_issue_id, _name), do: raise("Linear is down")
    def fetch_issue_description(_issue_id), do: raise("Linear is down")
  end

  defmodule FailingStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  # Reads the record, refuses to write what was projected.
  defmodule UnwritableStore do
    def get_ticket_state(repo_key, issue_id), do: SymphonyElixir.RunStore.get_ticket_state(repo_key, issue_id)
    def update_ticket_state(_repo_key, _issue_id, _attrs), do: {:error, :boom}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :pause_projector, true)
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :pause_projector, false)

      for key <- [
            :memory_tracker_recipient,
            :memory_tracker_add_issue_label_result,
            :memory_tracker_remove_issue_label_result,
            :memory_tracker_update_issue_description_result
          ],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    :ok
  end

  describe "desired/1" do
    test "Needs Decision while a question is open, Blocked while any other reason but an update's wait pauses it" do
      assert %{labels: [], entries: [], section: nil} = Projector.desired(%{})

      assert Projector.desired(record(pause([reason(:ticket, %{identifier: "TP-12"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:person, %{action: "unblock"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:environment, %{condition: "self_heal:qa"})]))).labels == ["Blocked"]
      assert Projector.desired(record(pause([reason(:build, %{pull_request: 448})]))).labels == []

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      paused = pause([reason(:question, %{question_id: "q-1"}), reason(:ticket, %{identifier: "TP-12"})])
      assert Projector.desired(record(paused, [question])).labels == ["Blocked", "Needs Decision"]
      assert Projector.desired(record(pause([reason(:question, %{question_id: "q-1"})]), [question])).labels == ["Needs Decision"]
      assert Projector.desired(record(nil, [%{question | state: :answered}])).labels == []
    end

    test "until the holds are retired, a hold shows its label, but a Blocked hold beside a question shows Needs Decision alone" do
      access = %{kind: :blocked, reason: "needs the deploy key", waits_on: %{type: "access", keys: []}}
      assert Projector.desired(%{holds: [access]}).labels == ["Blocked"]
      assert Projector.desired(%{holds: [%{kind: :needs_decision}]}).labels == ["Needs Decision"]

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      beside = %{kind: :blocked, reason: "loop", waits_on: %{type: "dispatch_loop", keys: [], question_id: question.id}}
      assert Projector.desired(Map.put(record(pause([reason(:question, %{question_id: question.id})]), [question]), :holds, [beside])).labels == ["Needs Decision"]
    end

    test "the section's entries are the record's decisions, hashed; the same decisions hash the same" do
      decision = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      desired = Projector.desired(%{decisions: [decision]})

      assert [%{key: "comment-1", scope: "Deferred to TP-891"}] = desired.entries
      assert desired.section =~ ~r/\A[0-9a-f]{16}\z/
      assert Projector.desired(%{decisions: [decision]}).section == desired.section
      refute Projector.desired(%{decisions: [%{decision | answer: "Do it here."}]}).section == desired.section
    end
  end

  describe "each write projects the labels that differ" do
    test "a question and a dependency, the answer, then the dependency clearing write exactly the label calls that differ" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      {:ok, question} = Questions.ask(@ticket, @request, at: @at)
      assert_received {:memory_tracker_label_added, @issue_id, "Needs Decision"}
      assert Projector.desired(stored()).labels == ["Blocked", "Needs Decision"]
      assert stored().projected == %{labels: ["Blocked", "Needs Decision"], section: nil}

      {:ok, _answered} = Questions.answer(@ticket, question.id, "Ship today")
      assert_received {:memory_tracker_label_removed, @issue_id, "Needs Decision"}
      assert Projector.desired(stored()).labels == ["Blocked"]

      {:ok, nil} = Pauses.clear_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_removed, @issue_id, "Blocked"}
      assert stored().projected.labels == []

      refute_received {:memory_tracker_label_added, _issue_id, _name}
      refute_received {:memory_tracker_label_removed, _issue_id, _name}
      assert labels() == []
    end

    test "a second apply of the same record writes nothing, and a reason that changes no label writes none" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      assert Projector.apply(stored()) == :ok
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-13"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
    end

    test "an update's wait shows no label" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      refute_received {:memory_tracker_label_added, _issue_id, _name}
      assert stored().projected == %{labels: [], section: nil}
    end

    test "a record never projected compares with the labels Linear was last seen with" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{labels: ["blocked", "bug"]}))

      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
      assert stored().projected == %{labels: ["Blocked"], section: nil}
    end

    test "force compares with the labels Linear was last seen with, so a label removed by hand comes back" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}

      assert Projector.apply(stored()) == :ok
      refute_received {:memory_tracker_label_added, _issue_id, _name}

      assert Projector.project_now(@ticket, force: true) == :ok
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}
    end
  end

  describe "the Decisions section" do
    test "a recorded decision is written into the description once, as the decision store wrote it" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      {:ok, expected} = Decisions.put(@description, [entry])

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key) == :ok
      assert_received {:memory_tracker_description_update, @issue_id, ^expected}
      assert %{section: section} = stored().projected
      assert section == Projector.desired(stored()).section

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key) == :ok
      assert Projector.apply(stored()) == :ok
      refute_received {:memory_tracker_description_update, _issue_id, _description}
    end

    test "a section already in the description is not written again" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      {:ok, written} = Decisions.put(@description, [entry])
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | description: written}])

      assert Decisions.record(@issue_id, [entry], repo_key: @repo_key, description: written) == :ok
      refute_received {:memory_tracker_description_update, _issue_id, _description}
      assert stored().projected.section == Projector.desired(stored()).section
    end
  end

  describe "a write Linear refuses" do
    test "leaves the record right and the projection pending, and the next apply writes it" do
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, [{:error, :linear_down}])

      log = capture_log(fn -> {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12")) end)
      assert log =~ "Failed to project the pause"
      assert [%{kind: :ticket}] = stored().pause.reasons
      assert [%{type: :pause, error: ":linear_down"}] = stored().pending_projection
      assert stored().projected == %{labels: [], section: nil}

      assert Projector.project_now(@ticket) == :ok
      assert_received {:memory_tracker_label_added, @issue_id, "Blocked"}
      assert stored().projected.labels == ["Blocked"]
    end

    test "a label cleared while Linear refuses stays applied until it is cleared" do
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, [{:error, :linear_down}])

      capture_log(fn -> {:ok, nil} = Pauses.clear_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12")) end)
      assert stored().projected.labels == ["Blocked"]
      assert [%{type: :pause}] = stored().pending_projection
    end

    test "a description Linear can't read, write or hold a section in is pending" do
      entry = Decisions.entry("comment-1", ~D[2026-10-13], "Keep the legacy partials", "Remove them here?", "Defer to TP-891.")
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{decisions: [entry]}))

      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_description_result, [{:error, :linear_down}])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :linear_down} end)
      assert stored().projected.section == nil

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue() | description: "<!-- symphony:decisions:start -->\nunterminated"}])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :decisions_block_unterminated} end)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      capture_log(fn -> assert Projector.apply(stored()) == {:error, :issue_not_found} end)
      assert [%{type: :pause, error: ":issue_not_found"}] = stored().pending_projection
    end

    test "a tracker that raises is a write that failed" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{projected: nil, decisions: [Decisions.entry("c-1", ~D[2026-10-13], "T", "Q?", "A.")]})

      capture_log(fn -> assert {:error, {:error, %RuntimeError{}}} = Projector.apply(stored(), tracker: RaisingTracker) end)
      assert stored().projected == %{labels: [], section: nil}
    end

    test "a projection the store can't record is logged" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{pull_request: 448}})
      {:ok, _pause} = Pauses.add_reason(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      :ok = RunStore.update_ticket_state(@repo_key, @issue_id, %{projected: nil})

      log = capture_log(fn -> assert Projector.apply(stored(), store: UnwritableStore) == :ok end)
      assert log =~ "Failed to record the pause projection"
    end
  end

  describe "project_now/2" do
    test "projects nothing for a ticket with no record, returns a store that can't be read, and writes nothing while the holds own the labels" do
      assert Projector.project_now(@ticket) == :ok
      assert Projector.project_now(@ticket, store: FailingStore) == {:error, :boom}

      Application.put_env(:symphony_elixir, :pause_projector, false)
      refute Projector.owns?()
      assert Projector.project_now(@ticket, store: FailingStore) == :ok
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-12"))
      refute_received {:memory_tracker_label_added, _issue_id, _name}
    end

    test "names the labels it writes" do
      assert Projector.labels() == ["Blocked", "Needs Decision"]
      assert Projector.owns?()
    end
  end

  defp issue, do: %Issue{id: @issue_id, identifier: "TP-817", title: "T", state: "In Progress", labels: [], description: @description}

  defp stored, do: TicketState.normalize(RunStore.get_ticket_state(@repo_key, @issue_id))

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp record(pause, questions \\ []), do: %{pause: pause, questions: questions}

  defp pause(reasons), do: %{subject: @ticket, reasons: reasons}

  defp reason(kind, waits_on), do: %{kind: kind, waits_on: waits_on}
end
