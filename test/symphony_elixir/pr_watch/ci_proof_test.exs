defmodule SymphonyElixir.PrWatch.CiProofTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrWatch.CiProof
  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketPlan}

  @repo_key "ci-proof-repo"
  @issue_id "ci-proof-issue"
  @head "abcdef1234567890"

  @named %{id: "c1", kind: "outcome", statement: "The make-all check passes on the pull request.", proof: "ci", ci_check: "make-all"}
  @timed %{id: "c2", kind: "outcome", statement: "The test step runs faster\non the pull request than on main.", proof: "ci"}
  @tested %{id: "c3", kind: "outcome", statement: "It works.", proof: "test"}
  @plan %{
    reason: "Grooming",
    by: "grooming",
    shape: "single",
    layers: ["tooling"],
    summary: "CI runs faster.",
    text: "Run the steps in parallel.",
    checks: [@named, @timed, @tested],
    size: %{tokens: 1_000, runs: 1}
  }

  setup do
    :ok = RunStore.clear()
    {:ok, _plan} = TicketPlan.write(@repo_key, @issue_id, @plan)
    :ok
  end

  # A finished head: make-all passed, nothing runs.
  defp read(attrs \\ %{}) do
    Map.merge(%{head_sha: @head, ci: :green, check_names: ["make-all", "macos"], running_checks: [], failed_checks: []}, Map.new(attrs))
  end

  defp prove!(check_id), do: {:ok, _event} = TicketChecks.prove(@repo_key, @issue_id, %{check_id: check_id, by: "ci", details: "Proved."})

  describe "fact/2" do
    test "a check that names a CI check that passed on the head is provable, whatever else still runs" do
      assert CiProof.fact(@issue_id, read()) == :provable
      assert CiProof.fact(@issue_id, read(ci: :pending, running_checks: ["macos"])) == :provable
    end

    test "nothing provable and checks still running, or none reported, waits" do
      # The named check failed, or still runs: not provable.
      assert CiProof.fact(@issue_id, read(ci: :pending, running_checks: ["make-all"])) == :running
      assert CiProof.fact(@issue_id, read(ci: :pending, check_names: [])) == :running
      assert CiProof.fact(@issue_id, nil) == :running

      prove!("c1")
      assert CiProof.fact(@issue_id, read(running_checks: ["macos"])) == :running
    end

    test "finished checks with a check left that a run reads give the turn once per head" do
      prove!("c1")
      assert CiProof.fact(@issue_id, read()) == :turn
      assert CiProof.fact(@issue_id, read(ci: :none, check_names: [])) == :turn
      put_dispatch(@repo_key, @issue_id, kind: :landing, state: "Merging", head: @head, run_id: "landing-1")
      assert CiProof.fact(@issue_id, read()) == :spent
      # Another head is a new turn; a landing run on another head, or another kind of run, is no turn on this one.
      assert CiProof.fact(@issue_id, read(head_sha: "fedcba9876543210")) == :turn
      put_dispatch(@repo_key, @issue_id, kind: :qa, head: "fedcba9876543210")
      assert CiProof.fact(@issue_id, read(head_sha: "fedcba9876543210")) == :turn
    end

    test "a named check that failed on a finished head is left to the run" do
      prove!("c2")
      assert CiProof.fact(@issue_id, read(failed_checks: [%{name: "make-all"}])) == :turn
    end

    test "with no open CI check there is nothing to prove" do
      prove!("c1")
      prove!("c2")
      assert CiProof.fact(@issue_id, read()) == :none
      assert CiProof.fact("unplanned", read()) == :none
    end
  end

  test "prove/3 records each provable check as proved by CI, once per check and head" do
    assert {:ok, 1} = CiProof.prove(@repo_key, @issue_id, read())
    assert [%{id: "c1", state: :proved, proved_by: %{by: "ci", details: "The CI check `make-all` passed on the head abcdef12.", head: @head}}] = TicketChecks.list(@issue_id) |> Enum.take(1)
    assert {:ok, 0} = CiProof.prove(@repo_key, @issue_id, read())
    assert length(RunStore.list_ticket_events(@issue_id, types: ["check.proved"])) == 1

    assert {:ok, 0} = CiProof.prove(@repo_key, @issue_id, nil)
  end

  test "provable/2 keeps the checks that name a CI check that passed on the head" do
    checks = [%{@named | id: "c9"}]
    assert CiProof.provable(checks, read()) == checks
    assert CiProof.provable(checks, nil) == []
    assert CiProof.provable([@timed], read()) == []
  end

  test "turn_run/2 and reason/2 name the run that had the turn and what it said" do
    assert CiProof.turn_run(@issue_id, nil) == nil
    assert CiProof.turn_run(@issue_id, @head) == nil

    assert CiProof.reason(@issue_id, @head) =~
             "did not prove these checks of the plan: [c1] The make-all check passes on the pull request.; [c2] The test step runs faster on the pull request than on main."

    refute CiProof.reason(@issue_id, nil) =~ "The run said"
    assert CiProof.reason(@issue_id, nil) =~ "on the head did not prove"

    put_dispatch(@repo_key, @issue_id, kind: :landing, head: @head, run_id: "landing-1")
    assert CiProof.turn_run(@issue_id, @head) == "landing-1"
    assert CiProof.reason(@issue_id, @head) =~ "on the head abcdef12 did not prove"
    refute CiProof.reason(@issue_id, @head) =~ "The run said"

    {:ok, _note} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "Earlier note."}, run_id: "other-run")
    {:ok, _note} = TicketEvents.record(@repo_key, @issue_id, "note", %{text: "The test step\ntook 4 minutes, as on main."}, run_id: "landing-1")
    assert CiProof.reason(@issue_id, @head) =~ "The run said: The test step took 4 minutes, as on main."
  end
end
