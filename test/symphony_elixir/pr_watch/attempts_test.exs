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

    assert %{
             red: 2,
             conflict: 0,
             reruns: %{"head-1" => ["specs"]},
             fix_failures: [%{check: "specs", error: ""}],
             fix_ticket: "TP-1",
             head_origin: :person
           } =
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
      observed = Attempts.observe(attempts, read(ci: ci, mergeable: mergeable), ticket(), @now)
      assert %{red: 0, conflict: 0, fix_failures: []} = observed
    end
  end

  test "the red count restarts once the backstop's fix ticket hold clears, and not while it is set" do
    attempts = Attempts.new() |> red(10) |> Attempts.spend(:conflict) |> Attempts.filed("TP-9")

    assert %{red: 10, fix_ticket: "TP-9"} = Attempts.observe(attempts, read(), ticket(hold: :blocked), @now)
    observed = Attempts.observe(attempts, read(), ticket(), @now)
    assert %{red: 0, conflict: 1, fix_ticket: nil, fix_failures: []} = observed
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
    observed = Attempts.observe(attempts, %{blocked | head_sha: "head-2"}, merging, later)
    assert %{blocked: %{head_sha: "head-2", since: ^later}} = observed
    assert %{blocked: nil} = Attempts.observe(attempts, %{blocked | ci: :pending}, merging, later)
    assert %{blocked: nil} = Attempts.observe(attempts, blocked, ticket(), later)
  end

  test "a Merging head Symphony didn't put there is a person's push" do
    merging = ticket(phase: :merging)

    attempts = Attempts.observe(Attempts.new(), read(), Map.put(merging, :new_stay, true), @now)
    assert %{trusted_head: "head-1", head_origin: :symphony} = attempts
    assert %{head_origin: :symphony} = Attempts.observe(attempts, read(), merging, @now)

    # A head pushed while a run worked on the ticket, or one a run left, is Symphony's.
    observed = Attempts.observe(attempts, read(head_sha: "head-2"), %{merging | run: :active}, @now)
    assert %{trusted_head: "head-2", head_origin: :symphony} = observed
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

  describe "the same failure again (D15 (c))" do
    defp failure(head, error \\ "ERROR: boom"), do: %{check: "test", error: error, head_sha: head}

    # Each fix run sent for `head`'s failure, then the read of the head it pushed.
    defp runs(failures), do: Enum.reduce(failures, Attempts.new(), &Attempts.spend(&2, :red, &1))

    defp streak(attempts, head, error \\ "ERROR: boom") do
      read = read(head_sha: head, failure: failure(head, error))
      attempts |> Attempts.observe(read, ticket(), @now) |> Attempts.facts(read, @settings, @now) |> Map.fetch!(:same_failure_streak)
    end

    test "counts the fix runs before the head that failed the same way, on earlier heads, in a row" do
      assert streak(Attempts.new(), "h1") == 0
      assert streak(runs([failure("h1")]), "h2") == 1
      assert streak(runs([failure("h1"), failure("h2")]), "h3") == 2
      assert streak(runs([failure("h1"), failure("h2"), failure("h3")]), "h4") == 3

      # A different failure in between, or now, breaks it.
      assert streak(runs([failure("h1"), failure("h2", "ERROR: other"), failure("h3")]), "h4") == 1
      assert streak(runs([failure("h1"), failure("h2")]), "h3", "ERROR: other") == 0

      # A run that pushed nothing: its own head's failure doesn't count.
      assert streak(runs([failure("h1"), failure("h2")]), "h2") == 1

      # No failure read for the head, or no head.
      attempts = runs([failure("h1")])
      assert %{same_failure_streak: 0} = Attempts.facts(Attempts.observe(attempts, read(head_sha: "h2"), ticket(), @now), read(head_sha: "h2"), @settings, @now)
      assert %{same_failure_streak: 0} = Attempts.facts(attempts, nil, @settings, @now)
    end

    test "a green head, a green and conflict-free PR or a cleared fix ticket resets it; the evidence stays on a conflicting green head" do
      attempts = runs([failure("h1"), failure("h2")])

      conflicting_green = read(ci: :green, mergeable: :dirty)
      assert %{streak: [], fix_failures: [_, _]} = Attempts.observe(attempts, conflicting_green, ticket(), @now)
      assert %{streak: [], fix_failures: []} = Attempts.observe(attempts, read(ci: :green), ticket(), @now)
      assert %{streak: [_, _]} = Attempts.observe(attempts, read(ci: :pending), ticket(), @now)
      assert %{streak: []} = attempts |> Attempts.filed("TP-9") |> Attempts.observe(read(), ticket(), @now)
      assert %{streak: []} = Attempts.restart_red(attempts)
    end

    test "keeps the head's failure until the head moves or its checks are rerun" do
      kept = Attempts.observe(Attempts.new(), read(head_sha: "h1", failure: failure("h1")), ticket(), @now)
      assert %{failure: %{head_sha: "h1"}} = kept
      assert %{failure: %{head_sha: "h1"}} = Attempts.observe(kept, read(head_sha: "h1"), ticket(), @now)
      assert %{failure: nil} = Attempts.observe(kept, read(head_sha: "h2"), ticket(), @now)
      assert %{failure: nil} = Attempts.observe(kept, nil, ticket(), @now)
      assert %{failure: nil} = Attempts.rerun(kept, "h1", ["test"])
      assert %{failure: %{check: "test", head_sha: "h1"}} = Attempts.normalize(%{failure: failure("h1")})
      assert %{failure: nil} = Attempts.normalize(%{failure: :bad})
    end

    test "the signature is the self-heal lane's for the outcome the backstop builds" do
      assert Attempts.cause(failure("h1")) == {:ci_check_failed, "test", "ERROR: boom"}
      assert Attempts.cause(%{check: "test"}) == {:ci_check_failed, "test", ""}
      assert Attempts.signature(failure("h1")) == SymphonyElixir.SelfHeal.signature(%{cause: {:ci_check_failed, "test", "ERROR: boom"}})
      assert Attempts.signature(failure("h1")) == Attempts.signature(failure("h2"))
      refute Attempts.signature(failure("h1")) == Attempts.signature(failure("h1", "ERROR: other"))
    end
  end

  describe "a check that never reports (D3)" do
    @timeout 30 * 60_000

    defp missing(attrs \\ %{}), do: read(Map.merge(%{ci: :required_missing, missing_checks: ["build"]}, Map.new(attrs)))
    defp settle(attempts, read, minutes), do: Attempts.settle(read, attempts, @timeout, DateTime.add(@now, minutes, :minute))

    test "a required check reads as running until the wait passes, per head, in any phase" do
      attempts = Attempts.observe(Attempts.new(), missing(), ticket(phase: :qa), @now)
      assert %{unreported: %{head_sha: "head-1", since: @now, asked: nil, answer: nil}} = attempts

      assert %{ci: :pending} = settle(attempts, missing(), 29)
      assert %{ci: :required_missing} = settle(attempts, missing(), 30)

      # The same head keeps its clock; a new head starts again; a head that reported stops it.
      later = DateTime.add(@now, 10, :minute)
      assert %{unreported: %{since: @now}} = Attempts.observe(attempts, missing(), ticket(), later)
      moved = Attempts.observe(attempts, missing(head_sha: "head-2"), ticket(), later)
      assert %{unreported: %{head_sha: "head-2", since: ^later}} = moved
      assert %{unreported: nil} = Attempts.observe(attempts, missing(ci: :green), ticket(), later)
      assert %{unreported: nil} = Attempts.observe(attempts, nil, ticket(), later)

      # A clock for another head, or none, keeps it running.
      assert %{ci: :pending} = settle(attempts, missing(head_sha: "head-2"), 60)
      assert %{ci: :pending} = settle(Attempts.new(), missing(), 60)
    end

    test "a head with no check at all while the base has workflows reads as having no CI once the wait passed" do
      awaiting = read(ci: :pending, awaiting_checks: true, check_names: [])
      attempts = Attempts.observe(Attempts.new(), awaiting, ticket(), @now)

      assert %{ci: :pending} = settle(attempts, awaiting, 29)
      assert %{ci: :none, no_ci: :not_reported} = settle(attempts, awaiting, 30)
      assert %{ci: :pending} = settle(Attempts.new(), awaiting, 60)
      assert settle(attempts, read(ci: :green), 60) == read(ci: :green)
      assert settle(attempts, nil, 60) == nil
    end

    test "the person's answer: proceed waives the head, Rework asks nothing more, a rerun restarts the wait" do
      attempts = Attempts.new() |> Attempts.observe(missing(), ticket(), @now) |> Attempts.asked("head-1", "Check build never reported on TP-1", 2)
      assert Attempts.open_question(attempts) == %{title: "Check build never reported on TP-1", prior: 2}

      proceed = Attempts.answer(attempts, :proceed, @now)
      assert Attempts.open_question(proceed) == nil
      assert %{ci: :green} = settle(proceed, missing(), 60)
      # Only for that head.
      next = Attempts.observe(proceed, missing(head_sha: "head-2"), ticket(), DateTime.add(@now, 60, :minute))
      assert %{ci: :pending} = Attempts.settle(missing(head_sha: "head-2"), next, @timeout, DateTime.add(@now, 61, :minute))

      assert %{ci: :pending} = settle(Attempts.answer(attempts, :rework, @now), missing(), 60)

      later = DateTime.add(@now, 45, :minute)
      rerun = Attempts.answer(attempts, :rerun, later)
      assert %{unreported: %{since: ^later, asked: nil, answer: nil}} = rerun
      assert %{ci: :pending} = settle(rerun, missing(), 60)
      assert %{unreported: %{asked: nil}} = Attempts.answer(attempts, :other, later)

      # Nothing to ask about or answer without a clock on the head.
      assert Attempts.asked(Attempts.new(), "head-1", "t", 0) == Attempts.new()
      assert Attempts.asked(attempts, "head-9", "t", 0) == attempts
      assert Attempts.answer(Attempts.new(), :proceed, @now) == Attempts.new()
      assert Attempts.open_question(Attempts.new()) == nil
    end

    test "normalize keeps a well-formed clock and drops the rest" do
      clock = %{head_sha: "h", since: @now, asked: %{title: "t", prior: -1}, answer: :proceed}

      assert %{unreported: %{head_sha: "h", asked: %{title: "t", prior: 0}, answer: :proceed}} =
               Attempts.normalize(%{unreported: clock})

      malformed = %{clock | asked: :bad, answer: :bad}
      assert %{unreported: %{asked: nil, answer: nil}} = Attempts.normalize(%{unreported: malformed})
      assert %{unreported: nil} = Attempts.normalize(%{unreported: %{since: :bad}})
    end
  end
end
