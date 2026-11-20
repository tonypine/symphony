defmodule SymphonyElixir.TicketChecksTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketPlan}

  @repo_key "checks-repo"
  @issue_id "checks-issue"
  @base ~U[2026-11-20 09:00:00.000000Z]

  @outcome %{id: "c1", kind: "outcome", statement: "The page shows the plan.", proof: "test"}
  @walk %{id: "c2", kind: "qa", statement: "The panel folds.", proof: "qa", state: "A groomed ticket", action: "Fold it", expect: "One line", size: "wide"}
  @attached %{id: "c3", kind: "evidence", statement: "The design was compared.", proof: "attached"}
  @plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["screen"],
    summary: "The ticket page shows the plan.",
    text: "Read the plan from the ledger and draw it.",
    checks: [@outcome, @walk, @attached],
    size: %{tokens: 200_000, runs: 2}
  }

  setup do
    :ok = RunStore.clear()
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "CHK-1"})
    :ok
  end

  defp at(minutes), do: DateTime.add(@base, minutes * 60)
  # Written before every proof these tests date (`at/1`).
  defp plan!(plan \\ @plan, opts \\ [at: at(0)]), do: TicketPlan.write(@repo_key, @issue_id, plan, opts) |> elem(1)
  defp states, do: Map.new(TicketChecks.list(@issue_id), &{&1.id, &1.state})

  test "a ticket that is not groomed has no checks, and none can be proved or waived" do
    assert TicketChecks.list(@issue_id) == []
    assert TicketChecks.open(@issue_id) == []
    assert TicketChecks.list([]) == []
    assert {:error, {:unknown_check, "c1"}} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test"})
    assert {:error, {:unknown_check, "c1"}} = TicketChecks.waive(@repo_key, @issue_id, "c1", "Nothing can test it.")
    assert RunStore.list_ticket_events(@issue_id, []) == []
  end

  test "the plan's checks, in its order, each open until it is proved or waived" do
    plan!()

    assert [
             %{id: "c1", kind: "outcome", statement: "The page shows the plan.", proof: "test", state: :open, proved_by: nil, waived: nil} = first,
             %{id: "c2", kind: "qa", state: :open, needs: "A groomed ticket", action: "Fold it", expect: "One line", size: "wide"},
             %{id: "c3", state: :open}
           ] = TicketChecks.list(@issue_id)

    refute Map.has_key?(first, :needs)

    agent = {:agent, "run-1", "implementation"}
    proof = %{"check_id" => "c1", "by" => "test", "test" => "plan_test.exs › shows the plan", "details" => "Green."}
    assert {:ok, proved} = TicketChecks.prove(@repo_key, @issue_id, proof, actor: agent, head_sha: "abc1234", at: at(1))
    assert proved.type == "check.proved" and proved.head_sha == "abc1234"

    assert {:ok, waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")
    assert waived.type == "check.waived"

    assert [first, %{id: "c2", state: :open}, third] = TicketChecks.list(@issue_id)
    assert %{id: "c1", state: :proved, proved_by: proved_by, waived: nil} = first
    assert %{id: "c3", state: :waived, proved_by: nil, waived: waiver} = third

    assert proved_by == %{
             by: "test",
             test: "plan_test.exs › shows the plan",
             evidence: nil,
             details: "Green.",
             event_id: proved.id,
             at: at(1),
             head: "abc1234",
             run_id: "run-1"
           }

    assert %{reason: "Nothing can be attached.", event_id: id} = waiver
    assert id == waived.id

    assert [%{id: "c2"}] = TicketChecks.open(@issue_id)
    assert [%{id: "c2"}] = TicketChecks.open(@issue_id, proof: ["qa", "design"])
    assert TicketChecks.open(@issue_id, proof: "test") == []

    # The same read from events a caller already holds.
    assert TicketChecks.list(RunStore.list_ticket_events(@issue_id, [])) == TicketChecks.list(@issue_id)
  end

  test "an id the plan does not hold is refused and nothing is written" do
    plan!()
    before = RunStore.list_ticket_events(@issue_id, [])

    assert {:error, {:unknown_check, "c9"}} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c9", by: "qa"})
    assert {:error, {:unknown_check, nil}} = TicketChecks.prove(@repo_key, @issue_id, %{by: "qa"})
    assert {:error, {:unknown_check, "c9"}} = TicketChecks.waive(@repo_key, @issue_id, "c9", "No.")
    assert {:error, {:invalid_payload, [:by]}} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "trust"})

    assert RunStore.list_ticket_events(@issue_id, []) == before
  end

  test "a proof is recorded once per check and head, and the newest proof is the one shown" do
    plan!()

    assert {:ok, first} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test"}, head_sha: "abc1234", at: at(1))
    assert {:ok, again} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test", details: "Again."}, head_sha: "abc1234", at: at(2))
    assert again.id == first.id

    assert {:ok, other_check} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c2", by: "qa"}, head_sha: "abc1234", at: at(3))
    assert other_check.id != first.id

    assert {:ok, later} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "qa"}, head_sha: "def5678", at: at(4))
    assert later.id != first.id

    # With no head, each proof is its own event.
    assert {:ok, headless} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c3", by: "attached"}, at: at(5))
    assert {:ok, headless_again} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c3", by: "attached"}, head_sha: "", at: at(6))
    assert headless.id != headless_again.id

    assert [%{proved_by: %{by: "qa", head: "def5678"}}, %{state: :proved}, %{proved_by: %{event_id: id}}] = TicketChecks.list(@issue_id)
    assert id == headless_again.id
  end

  test "a check keeps its state through a new plan version that keeps it as it reads, and a check the newest plan dropped is not listed" do
    plan!()
    {:ok, _proved} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test"}, head_sha: "abc1234", at: at(1))
    {:ok, _proved} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c2", by: "qa"}, head_sha: "abc1234", at: at(1))
    {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")

    added = %{kind: "outcome", statement: "The checks show their state.", proof: "test"}
    plan!(%{@plan | reason: "The ask changed.", by: "recalibration", checks: [@outcome, @attached, added]}, [])

    assert [
             %{id: "c1", statement: "The page shows the plan.", state: :proved},
             %{id: "c3", state: :waived},
             %{id: "c4", state: :open, proved_by: nil}
           ] = TicketChecks.list(@issue_id)

    assert states() == %{"c1" => :proved, "c3" => :waived, "c4" => :open}
    assert {:error, {:unknown_check, "c2"}} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c2", by: "qa"})

    # A proof wins over a waiver, whichever came first.
    {:ok, _proved} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c3", by: "attached"})
    assert %{state: :proved, waived: %{reason: "Nothing can be attached."}} = Enum.find(TicketChecks.list(@issue_id), &(&1.id == "c3"))
  end

  test "a new check never inherits the proof of a check that had its place, and a reworded check starts unproved" do
    plan!()
    {:ok, old} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test"}, head_sha: "abc1234", at: at(1))
    {:ok, _proved} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c2", by: "qa"}, head_sha: "abc1234", at: at(1))
    {:ok, _waived} = TicketChecks.waive(@repo_key, @issue_id, "c3", "Nothing can be attached.")

    # c1 is reworded, c2 is dropped for a new check that comes with no id, and c3 stands.
    reworded = %{@outcome | statement: "The page shows the plan and its summary."}
    new = %{kind: "outcome", statement: "The page shows the size.", proof: "test"}
    plan!(%{@plan | reason: "The ask changed.", by: "recalibration", checks: [reworded, new, @attached]}, [])
    assert states() == %{"c1" => :open, "c4" => :open, "c3" => :waived}

    # The reworded check is proved again, on the head its old wording was proved on too.
    {:ok, again} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: "c1", by: "test"}, head_sha: "abc1234")
    assert again.id != old.id
    assert again.idempotency == "check.proved:c1:v2:abc1234"
    assert states()["c1"] == :proved

    # A check a version dropped and a later one put back starts unproved too.
    plan!(%{@plan | reason: "Back.", by: "recalibration", checks: [reworded, @walk]}, [])
    assert states() == %{"c1" => :proved, "c2" => :open}
  end

  test "a stored proof whose payload kept string keys still reads" do
    plan = plan!()
    stored = %TicketEvents.Event{id: "evt-old", type: "check.proved", payload: %{"check_id" => "c1", "by" => "test"}, at: at(1)}

    assert [%{id: "c1", state: :proved, proved_by: %{by: "test", event_id: "evt-old"}} | _rest] = TicketChecks.list([plan, stored, {:error, :junk}])
  end
end
