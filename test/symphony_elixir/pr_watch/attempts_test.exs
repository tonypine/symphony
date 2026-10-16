defmodule SymphonyElixir.PrWatch.AttemptsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrWatch.Attempts

  @now ~U[2026-10-16 12:00:00Z]
  @settings %{flaky_retry: true, merging_wait_timeout_ms: 30 * 60_000}

  defp read(attrs \\ %{}), do: Map.merge(%{pr: :open, head_sha: "head-1", ci: :red, mergeable: :clean, check_names: ["make all"]}, Map.new(attrs))
  defp ticket(attrs \\ %{}), do: Map.merge(%{phase: :code_review, hold: :none, run: :none}, Map.new(attrs))
  defp red(attempts, n), do: Enum.reduce(1..n, attempts, fn _n, acc -> Attempts.spend(acc, :red, %{check: "make all", error: "boom"}) end)

  test "new/0 and normalize/1 read a record's attempts, filling what it lacks" do
    assert Attempts.normalize(nil) == Attempts.new()

    assert %{red: 2, conflict: 0, reruns: %{"head-1" => ["specs"]}, fix_failures: [%{check: "specs", error: ""}], fix_ticket: "TP-1", head_origin: :person} =
             Attempts.normalize(%{
               red: 2,
               conflict: -1,
               reruns: %{"head-1" => ["specs", nil], nil => ["x"], "head-2" => :bad},
               fix_failures: [%{check: "specs"}, %{error: "no check"}, :bad],
               fix_ticket: "TP-1",
               blocked: %{since: :bad},
               updated_from: "",
               head_origin: :person
             })
  end

  test "red and conflict runs keep separate counts: 2 red + 1 conflict is red 2 and conflict 1" do
    attempts = Attempts.new() |> red(2) |> Attempts.spend(:conflict)

    assert %{red_attempts: 2, conflict_attempts: 1, fix_failures: [%{check: "make all"}, %{check: "make all"}]} =
             Attempts.facts(attempts, read(), @settings, @now)
  end

  test "both counts reset only when the PR is green and conflict-free" do
    attempts = Attempts.new() |> red(2) |> Attempts.spend(:conflict)

    # A conflicting PR keeps its last green checks: GitHub runs no workflow while it conflicts.
    for mergeable <- [:dirty, :unknown] do
      assert %{red: 2, conflict: 1} = Attempts.observe(attempts, read(ci: :green, mergeable: mergeable), ticket(), @now)
    end

    assert %{red: 2, conflict: 1} = Attempts.observe(attempts, read(ci: :pending), ticket(), @now)
    assert %{red: 2, conflict: 1} = Attempts.observe(attempts, read(ci: :green, pr: :closed), ticket(), @now)
    assert %{red: 2, conflict: 1} = Attempts.observe(attempts, nil, ticket(), @now)

    for ci <- [:green, :none], mergeable <- [:clean, :behind, :unstable, :blocked] do
      assert %{red: 0, conflict: 0, fix_failures: []} = Attempts.observe(attempts, read(ci: ci, mergeable: mergeable), ticket(), @now)
    end
  end

  test "the red count restarts once the backstop's fix ticket hold clears, and not while it is set" do
    attempts = Attempts.new() |> red(10) |> Attempts.spend(:conflict) |> Attempts.filed("TP-9")

    assert %{red: 10, fix_ticket: "TP-9"} = Attempts.observe(attempts, read(), ticket(hold: :blocked), @now)
    assert %{red: 0, conflict: 1, fix_ticket: nil, fix_failures: []} = Attempts.observe(attempts, read(), ticket(), @now)
    assert %{red: 0, fix_ticket: nil} = Attempts.restart_red(attempts)
    assert %{fix_ticket: nil} = Attempts.filed(attempts, nil)
  end

  test "a head's failed checks are rerun once, and a rerun whose checks left the rollup is still pending" do
    attempts = Attempts.rerun(Attempts.new(), "head-1", ["specs", nil])

    assert %{rerun_done: true} = Attempts.facts(attempts, read(), @settings, @now)
    assert %{rerun_done: false} = Attempts.facts(attempts, read(head_sha: "head-2"), @settings, @now)
    assert %{rerun_done: false} = Attempts.facts(attempts, nil, @settings, @now)
    # With `flaky_retry` off, every head counts as rerun.
    assert %{rerun_done: true} = Attempts.facts(Attempts.new(), read(), %{@settings | flaky_retry: false}, @now)

    assert Attempts.rerun_pending?(attempts, read(check_names: ["make all"]))
    refute Attempts.rerun_pending?(attempts, read(check_names: ["make all", "specs"]))
    refute Attempts.rerun_pending?(attempts, read(head_sha: "head-2"))
    refute Attempts.rerun_pending?(attempts, nil)
    refute Attempts.rerun_pending?(Attempts.new(), read())

    # A new head drops the old head's rerun; no head drops them all.
    assert %{reruns: %{}} = Attempts.observe(attempts, read(head_sha: "head-2"), ticket(), @now)
    assert %{reruns: %{"head-1" => ["specs"]}} = Attempts.observe(attempts, read(), ticket(), @now)
    assert %{reruns: %{}} = Attempts.observe(attempts, nil, ticket(), @now)
    assert Attempts.rerun(Attempts.new(), nil, ["specs"]) == Attempts.new()
  end

  test "the merge wait runs while a Merging head is blocked on green checks, per head" do
    blocked = read(ci: :green, mergeable: :blocked)
    merging = ticket(phase: :merging)

    attempts = Attempts.observe(Attempts.new(), blocked, merging, @now)
    assert %{blocked: %{head_sha: "head-1", since: @now}} = attempts
    assert %{landing_timed_out: false} = Attempts.facts(attempts, blocked, @settings, DateTime.add(@now, 29, :minute))
    assert %{landing_timed_out: true} = Attempts.facts(attempts, blocked, @settings, DateTime.add(@now, 30, :minute))

    # The same head keeps its clock; a new head, a red head or another phase stops it.
    later = DateTime.add(@now, 10, :minute)
    assert %{blocked: %{since: @now}} = Attempts.observe(attempts, blocked, merging, later)
    assert %{blocked: %{head_sha: "head-2", since: ^later}} = Attempts.observe(attempts, %{blocked | head_sha: "head-2"}, merging, later)
    assert %{blocked: nil} = Attempts.observe(attempts, %{blocked | ci: :pending}, merging, later)
    assert %{blocked: nil} = Attempts.observe(attempts, blocked, ticket(), later)
  end

  test "a Merging head Symphony didn't put there is a person's push" do
    merging = ticket(phase: :merging)

    attempts = Attempts.observe(Attempts.new(), read(), Map.put(merging, :new_stay, true), @now)
    assert %{trusted_head: "head-1", head_origin: :symphony} = attempts
    assert %{head_origin: :symphony} = Attempts.observe(attempts, read(), merging, @now)

    # A head pushed while a run worked on the ticket, or one a run left, is Symphony's.
    assert %{trusted_head: "head-2", head_origin: :symphony} = Attempts.observe(attempts, read(head_sha: "head-2"), %{merging | run: :active}, @now)
    assert %{trusted_head: "head-2"} = Attempts.observe(attempts, read(head_sha: "head-2"), Map.put(merging, :run_heads, ["head-2"]), @now)

    # So is the head an update-branch made from the trusted one.
    updated = Attempts.updated_from(attempts, "head-1")
    assert %{trusted_head: "head-2", head_origin: :symphony} = Attempts.observe(updated, read(head_sha: "head-2"), merging, @now)

    # Any other head is a person's, and stays one until a new stay trusts a head again.
    pushed = Attempts.observe(attempts, read(head_sha: "head-3"), merging, @now)
    assert %{trusted_head: "head-1", head_origin: :person} = pushed
    assert %{red_attempts: 0, head_origin: :person} = Attempts.facts(pushed, read(head_sha: "head-3"), @settings, @now)

    # Outside Merging, or with no head, nothing is a person's.
    assert %{trusted_head: nil, head_origin: :symphony} = Attempts.observe(pushed, read(head_sha: "head-3"), ticket(), @now)
    assert %{trusted_head: nil, head_origin: :symphony} = Attempts.observe(pushed, nil, merging, @now)
    assert %{trusted_head: "head-5"} = Attempts.observe(%{Attempts.new() | head_origin: :person}, read(head_sha: "head-5"), merging, @now)
  end
end
