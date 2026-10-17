defmodule SymphonyElixir.PrDecisionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision
  alias SymphonyElixir.PrDecision.{Action, Facts, NoRuleError}

  @ids Enum.map(PrDecision.rules(), & &1.id)
  @conflict_rules ["R14a", "R14", "R15", "R15a"]
  @tp948 %{issue_identifier: "TP-948", pr_number: 948, files: ["SPEC.md"]}
  @tp951 %{issue_identifier: "TP-951", pr_number: 951, files: ["SPEC.md", "lib/a.ex"]}

  # An open PR #42 with nothing going on: green, mergeable, no run, no hold.
  defp facts(attrs) do
    Facts.new(Keyword.merge([pr_number: 42, ci: :green, mergeable: :clean], attrs))
  end

  defp decide(attrs), do: attrs |> facts() |> PrDecision.decide()

  # Code Review, red on the `test` check after a rerun.
  defp red(attrs), do: decide(Keyword.merge([phase: :code_review, ci: :red, rerun_done: true, failing_check: "test", max_red_attempts: 10], attrs))

  # Each of `combinations` decided once: how many, the ones no rule matches, the waits
  # without an owner or a clearing condition, and the first facts each rule fired for.
  defp check_table(combinations) do
    Enum.reduce(combinations, %{combinations: 0, unmatched: [], bad_waits: [], fired: %{}}, fn facts, report ->
      report = %{report | combinations: report.combinations + 1}

      try do
        action = PrDecision.decide(facts)
        report = if well_formed?(action), do: report, else: %{report | bad_waits: [action | report.bad_waits]}
        %{report | fired: Map.put_new(report.fired, action.rule, facts)}
      rescue
        error in NoRuleError -> %{report | unmatched: [error.facts | report.unmatched]}
      end
    end)
  end

  # The table's domains with `field`'s values passed through `fun`.
  defp domains(field, fun) do
    Enum.map(Facts.domains(), fn
      {^field, values} -> {field, fun.(values)}
      {^field, values, condition} -> {field, fun.(values), condition}
      domain -> domain
    end)
  end

  defp well_formed?(%Action{rule: rule, kind: kind, reason: reason} = action) do
    rule in @ids and kind in Action.kinds() and is_binary(reason) and
      (not Action.waiting?(action) or (action.owner in Action.owners() and is_binary(action.clears_when)))
  end

  describe "the whole table" do
    test "every combination of fact values gets exactly one rule, every wait has an owner and a clearing condition, and every rule fires" do
      report = check_table(Facts.combinations())
      IO.puts("\nPrDecision: #{report.combinations} fact combinations checked against #{length(@ids)} rules")

      assert report.combinations > 100_000
      assert report.unmatched == []
      assert report.bad_waits == []
      assert @ids -- Map.keys(report.fired) == []

      # The rule that built each action is the first one that matches its facts.
      for {id, facts} <- report.fired do
        assert Enum.find(PrDecision.rules(), &PrDecision.matches?(&1, facts)).id == id
      end
    end

    test "a fact value no rule handles fails the table check" do
      for {field, fake} <- [mergeable: :merge_queue, ci: :skipped, phase: :triage] do
        report = field |> domains(&(&1 ++ [fake])) |> Facts.combinations() |> check_table()
        assert report.unmatched != [], "#{field}: #{inspect(fake)} should have no rule"
        assert Enum.all?(report.unmatched, &(Map.fetch!(&1, field) == fake))
      end
    end

    test "a gap raises NoRuleError naming the facts" do
      error = assert_raise NoRuleError, fn -> decide(phase: :code_review, mergeable: :merge_queue) end
      assert Exception.message(error) =~ "no PR decision rule matches phase: :code_review"
      assert Exception.message(error) =~ "mergeable: :merge_queue"
    end

    test "rule ids are unique and each rule names its phases and a line for the docs" do
      assert Enum.uniq(@ids) == @ids
      assert length(@ids) == 35

      for rule <- PrDecision.rules() do
        assert rule.phases != [] and rule.phases -- Facts.phases() == []
        assert rule.when != "" and rule.then != ""
      end
    end

    test "deciding is pure: no GitHub, Linear, store, clock, config or process calls" do
      forbidden = [DateTime, NaiveDateTime, System, File, Process, Application, Logger]
      forbidden = forbidden ++ [:os, :ets, :persistent_term, :logger, :rand]
      impure_erlang = [:system_time, :monotonic_time, :now, :timestamp, :send, :get, :put, :whereis]

      for module <- [PrDecision, Facts, Action] do
        # The .beam on disk, which a cover-compiled module still has.
        {^module, beam, _path} = :code.get_object_code(module)
        {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

        for {callee, function, _arity} <- imports do
          name = inspect(callee)
          refute callee in forbidden, "#{inspect(module)} calls #{name}.#{function}"
          refute String.starts_with?(name, "SymphonyElixir.") and not String.starts_with?(name, "SymphonyElixir.PrDecision"), "#{inspect(module)} calls #{name}"
          refute callee == :erlang and function in impure_erlang
        end
      end
    end

    test "the same facts give the same action" do
      facts = facts(phase: :merging, mergeable: :dirty, ahead: [@tp948])
      assert PrDecision.decide(facts) == PrDecision.decide(facts)
    end
  end

  describe "Discovery gaps the table closes" do
    test "G1: no CI configured counts as green, so Code Review dispatches the reviewer (R27, D2)" do
      action = decide(phase: :code_review, ci: :none)
      assert %Action{rule: "R27", kind: :dispatch, args: %{phase: :code_review}} = action
      assert action.reason == "No CI configured on the base: counts as green, so the reviewer runs"
      assert decide(phase: :code_review, ci: :none, base_ref: "main").reason == "No CI configured on main: counts as green, so the reviewer runs"

      assert decide(phase: :qa, ci: :none, no_ci: :not_reported).reason ==
               "No check reported on the head within the wait: counts as green, so the QA agent runs"

      assert %Action{rule: "R27", reason: "The head is green, so the QA agent runs"} = decide(phase: :qa)
    end

    test "G2: a required check that never reports asks a person (R17, D3)" do
      action = decide(phase: :merging, ci: :required_missing, missing_checks: ["build"])
      assert %Action{rule: "R17", kind: :decision, owner: :person} = action
      assert action.args.question == "Required check build never reported on PR #42"
      assert action.args.options == ["Proceed without it for this PR", "Rerun the checks", "Fix the workflow in Rework"]
    end

    test "G3: a conflict back after 3 fix runs never parks silently: it waits on its competitors or goes to Rework" do
      competed = decide(phase: :merging, mergeable: :dirty, conflict_attempts: 3, competing: [@tp951])
      assert %Action{rule: "R15", kind: :wait_for_competitors} = competed
      assert %Action{rule: "R15a", kind: :to_rework} = decide(phase: :merging, mergeable: :dirty, conflict_attempts: 3)
    end

    test "G4: a PR closed without merging leaves no active phase without a run (R8, D5)" do
      for phase <- [:code_review, :qa, :ci_fix, :merging] do
        assert %Action{rule: "R8", kind: :to_rework, reason: "PR #42 was closed without merging"} = decide(phase: phase, pr: :closed)
      end
    end

    test "G5: a PR merged outside Symphony closes the ticket out in any phase (R2)" do
      for phase <- Facts.phases() do
        assert %Action{rule: "R2", kind: :close_out, reason: "PR #42 was merged"} = decide(phase: phase, pr: :merged, run: :active)
      end
    end

    test "G6: in Merging a red head or a conflict goes to CI Fix with origin Merging, auto-merge armed or not" do
      for auto_merge <- [:off, :armed] do
        red = decide(phase: :merging, auto_merge: auto_merge, ci: :red, rerun_done: true, failing_check: "test")
        assert %Action{rule: "R21", kind: :ci_fix, args: %{origin: :merging, cause: :red}} = red
        assert red.reason == "The `test` check failed on PR #42: CI Fix run 1 of 10"

        conflict = decide(phase: :merging, auto_merge: auto_merge, mergeable: :dirty)
        assert %Action{rule: "R14", kind: :ci_fix, args: %{origin: :merging, cause: :conflict}} = conflict
        assert conflict.reason == "PR #42 conflicts with main: conflict fix run 1 of 3"
      end
    end

    test "G7: Rework with a red head and no run goes to CI Fix (R21)" do
      action = decide(phase: :rework, ci: :red, rerun_done: true)
      assert %Action{rule: "R21", kind: :ci_fix, args: %{origin: :rework, cause: :red}} = action
      assert %Action{rule: "R26", kind: :dispatch} = decide(phase: :rework)
    end

    test "G8: a hold pauses the ticket whatever its PR does (R4)" do
      needs_decision = decide(phase: :code_review, hold: :needs_decision, ci: :red, rerun_done: true)
      assert %Action{rule: "R4", kind: :wait, owner: :person, clears_when: "a person answers and the hold clears"} = needs_decision

      blocked = decide(phase: :merging, hold: :blocked, mergeable: :dirty)
      assert %Action{rule: "R4", kind: :wait, owner: :symphony} = blocked
    end

    test "G10: only protected paths red asks a person instead of waiting silently (R18)" do
      action = decide(phase: :code_review, ci: :red, red_kind: :human_only, failing_check: "protected paths")
      assert %Action{rule: "R18", kind: :decision, owner: :person} = action
      assert action.args.options == ["Add the waiver label", "Drop the change in Rework"]
    end

    test "G11: a draft waits on a person, a changed base asks one, a deleted branch counts as closed" do
      assert %Action{rule: "R10", kind: :wait, owner: :person, clears_when: "the PR is marked ready for review"} = decide(phase: :merging, pr: :draft)
      assert %Action{rule: "R7", kind: :decision} = decide(phase: :qa, base: :changed)
      assert %Action{rule: "R8", kind: :to_rework} = decide(phase: :qa, pr: :closed)
    end

    test "G12: review comments send the ticket to In Progress on the same PR (R13, D8)" do
      for phase <- [:code_review, :qa, :merging] do
        assert %Action{rule: "R13", kind: :to_in_progress} = decide(phase: phase, review_comments: :unaddressed)
      end
    end

    test "G14: a ticket out of Merging never keeps auto-merge armed (R3)" do
      for phase <- Facts.phases() -- [:merging] do
        assert %Action{rule: "R3", kind: :disarm} = decide(phase: phase, auto_merge: :armed, hold: :blocked)
      end

      assert %Action{rule: "R29", kind: :merge_now} = decide(phase: :merging, auto_merge: :armed)
    end
  end

  describe "a closed PR (R8, D5)" do
    test "in QA with no run goes to Rework" do
      assert %Action{rule: "R8", kind: :to_rework, reason: "PR #42 was closed without merging"} = decide(phase: :qa, pr: :closed)
    end

    test "in Rework or In Progress with no run dispatches the run that opens a new PR" do
      for phase <- [:rework, :in_progress] do
        assert %Action{rule: "R8", kind: :dispatch, args: %{phase: ^phase}} = decide(phase: phase, pr: :closed)
      end
    end

    test "with a run active waits on the agent" do
      action = decide(phase: :qa, pr: :closed, run: :active)
      assert %Action{rule: "R8", kind: :wait, owner: :agent, clears_when: "the run ends"} = action
    end

    test "never builds a decision" do
      for phase <- Facts.phases(), run <- [:none, :active] do
        refute decide(phase: phase, pr: :closed, run: run).kind == :decision
      end
    end
  end

  describe "a conflict waits on who competes, never a question (D14, D16)" do
    test "R14a: in Merging with TP-948 ahead it waits on TP-948 and spends no CI Fix run" do
      action = decide(phase: :merging, mergeable: :dirty, ahead: [@tp948])

      assert %Action{rule: "R14a", kind: :wait_for_competitors, owner: :symphony} = action
      assert action.args == %{prs: [@tp948], step_behind: false}
      assert action.reason == "Lands after TP-948: they change the same files (SPEC.md)"
      refute action.kind == :ci_fix
    end

    test "R14: nobody ahead and no conflict fix run yet goes to CI Fix for the conflict" do
      action = decide(phase: :merging, mergeable: :dirty, conflict_attempts: 0)
      assert %Action{rule: "R14", kind: :ci_fix, args: %{cause: :conflict}} = action
    end

    test "R15: back after 3 fix runs with TP-951 competing waits on it, stepping behind" do
      action = decide(phase: :merging, mergeable: :dirty, conflict_attempts: 3, competing: [@tp951])

      assert %Action{rule: "R15", kind: :wait_for_competitors, args: %{prs: [@tp951], step_behind: true}} = action
      assert action.reason =~ "waiting on TP-951 to land, they change the same files (SPEC.md, lib/a.ex)"
      assert action.clears_when == "every competing PR lands or leaves the race"
    end

    test "R15a: back after 3 fix runs with nobody competing goes to Rework" do
      action = decide(phase: :merging, mergeable: :dirty, conflict_attempts: 3, competing: [])
      assert %Action{rule: "R15a", kind: :to_rework} = action
      assert action.reason == "The conflict with main came back after 3 fix runs and no open PR competes"

      in_rework = decide(phase: :rework, mergeable: :dirty, conflict_attempts: 3)
      assert %Action{rule: "R15a", kind: :dispatch, args: %{phase: :rework}} = in_rework
    end

    test "competitors without a ticket are named by their PR" do
      action = decide(phase: :qa, mergeable: :dirty, ahead: [%{pr_number: 7, files: ["a.ex"]}, %{files: ["b.ex"]}])
      assert action.reason == "Lands after PR #7 and an open PR: they change the same files (a.ex, b.ex)"
    end

    test "no conflict rule ever builds a decision" do
      kinds =
        for facts <- Facts.combinations(domains(:mergeable, fn _values -> [:dirty] end)), action = PrDecision.decide(facts), action.rule in @conflict_rules, uniq: true, do: {action.rule, action.kind}

      assert Enum.sort(kinds) == Enum.sort([{"R14a", :wait_for_competitors}, {"R14", :ci_fix}, {"R15", :wait_for_competitors}, {"R15a", :to_rework}, {"R15a", :dispatch}])
    end
  end

  describe "failed checks: a backstop that files a fix ticket, never a question (D15 (c))" do
    test "R21 below the backstop, R20 at it" do
      assert %Action{rule: "R21", kind: :ci_fix} = red(red_attempts: 3)
      assert %Action{rule: "R20", kind: :file_fix_ticket} = red(red_attempts: 10)
      assert %Action{rule: "R21", kind: :ci_fix} = red(same_failure_streak: 2)
      assert %Action{rule: "R20", kind: :file_fix_ticket} = red(same_failure_streak: 3)
    end

    test "R20 names the failing check and each fix run's failure as evidence, owned by symphony" do
      evidence = [%{check: "test", error: "** (MatchError) no match"}, %{check: "test", error: "** (MatchError) no match"}]
      action = red(same_failure_streak: 3, fix_failures: evidence)

      assert action.args == %{check: "test", evidence: evidence, red_attempts: 0, max_red_attempts: 10, same_failure_streak: 3}
      assert action.owner == :symphony
      assert action.reason == "CI keeps failing: waiting on a fix ticket for the `test` check"
      assert action.clears_when == "the fix ticket is terminal"
    end

    test "R20 never builds a decision" do
      kinds = for facts <- Facts.combinations(domains(:ci, fn _values -> [:red] end)), action = PrDecision.decide(facts), action.rule == "R20", uniq: true, do: action.kind

      assert kinds == [:file_fix_ticket]
    end

    test "a first red is rerun once, a cancelled run is rerun, a base that is red too is waited on" do
      assert %Action{rule: "R22", kind: :rerun_failed} = red(rerun_done: false)
      assert %Action{rule: "R19", kind: :rerun_failed} = red(red_kind: :cancelled)
      assert %Action{rule: "R23", kind: :wait, owner: :ci} = red(red_kind: :also_red_on_base)
    end

    test "R23 names the base's run and commit it compared the check with, and how" do
      base_red = %{check: "test", sha: "c1c4ae62d2b0d1f6", run_id: "38988095659", basis: :tests}

      assert red(red_kind: :also_red_on_base, base_ref: "main", base_red: base_red).reason ==
               "The `test` check is red on the base branch too: it failed the same tests on main at c1c4ae62 (run 38988095659)"

      assert red(red_kind: :also_red_on_base, base_red: %{base_red | basis: :name, sha: nil}).reason ==
               "The `test` check is red on the base branch too: the check of that name failed on the base branch (run 38988095659), compared by name only"

      assert red(red_kind: :also_red_on_base).reason == "The `test` check is red on the base branch too"
    end

    test "TP-920: a red head in Code Review goes to CI Fix instead of waiting for green" do
      assert %Action{rule: "R21", kind: :ci_fix, args: %{origin: :code_review}} = red([])
    end
  end

  describe "CI Fix and Merging" do
    test "a green CI Fix head returns to its origin, and to Code Review when the origin is unknown" do
      action = decide(phase: :ci_fix, origin: :merging)
      assert %Action{rule: "R25", kind: :return_to_origin, args: %{origin: :merging}} = action
      assert %Action{rule: "R25", args: %{origin: :code_review}} = decide(phase: :ci_fix)
      assert %Action{rule: "R21", args: %{origin: :qa}} = decide(phase: :ci_fix, origin: :qa, ci: :red, rerun_done: true)
    end

    test "a person's push in Merging goes back to Code Review (D4)" do
      assert %Action{rule: "R11", kind: :to_code_review} = decide(phase: :merging, head_origin: :person)
    end

    test "BEHIND updates the branch, or waits on the PR ahead (R28)" do
      assert %Action{rule: "R28", kind: :update_branch} = decide(phase: :merging, mergeable: :behind)

      action = decide(phase: :merging, mergeable: :behind, ahead: [@tp948])
      assert %Action{rule: "R28", kind: :wait, owner: :symphony, args: %{prs: [@tp948]}} = action
    end

    test "landing: arm, wait on the armed merge, then the landing agent past the merge wait" do
      assert %Action{rule: "R30", kind: :arm} = decide(phase: :merging, ci: :pending)
      assert %Action{rule: "R32", kind: :wait, owner: :ci} = decide(phase: :merging, ci: :pending, auto_merge: :armed)
      blocked = [phase: :merging, mergeable: :blocked]
      assert %Action{rule: "R33", kind: :wait, owner: :github} = decide([auto_merge: :armed] ++ blocked)
      assert %Action{rule: "R31", kind: :land_agent} = decide([landing_timed_out: true] ++ blocked)
      assert %Action{rule: "R16", kind: :wait, owner: :github} = decide(phase: :merging, mergeable: :unknown)
    end

    test "GitHub's rate limit and an In Progress ticket" do
      assert %Action{rule: "R1", kind: :wait, owner: :github} = decide(phase: :merging, github: :rate_limited)
      assert %Action{rule: "R5", kind: :wait, owner: :agent} = decide(pr: :missing)
      assert %Action{rule: "R12", kind: :dispatch} = decide(phase: :in_progress)
      assert %Action{rule: "R6", kind: :decision} = decide(phase: :qa, pr: :missing)
      assert %Action{rule: "R9", kind: :wait, owner: :agent} = decide(phase: :code_review, run: :active)
      assert %Action{rule: "R24", kind: :wait, owner: :ci} = decide(phase: :qa, ci: :pending)
    end
  end

  describe "user walkthrough" do
    test "step 3: Code Review, red after a rerun, 3 of 10 attempts → R21 CI Fix from Code Review" do
      action = PrDecision.decide(%Facts{phase: :code_review, ci: :red, rerun_done: true, red_attempts: 3, max_red_attempts: 10})
      assert %Action{rule: "R21", kind: :ci_fix, args: %{origin: :code_review}} = action
    end

    test "step 4: Merging, dirty, TP-948 ahead sharing SPEC.md → R14a naming TP-948" do
      action = PrDecision.decide(%Facts{phase: :merging, mergeable: :dirty, ahead: [@tp948]})
      assert %Action{rule: "R14a", kind: :wait_for_competitors} = action
      assert action.reason =~ "TP-948"
    end

    test "step 5: Merging, dirty, 3 conflict runs, nobody competing → R15a to Rework" do
      action = PrDecision.decide(%Facts{phase: :merging, mergeable: :dirty, ahead: [], conflict_attempts: 3, competing: []})
      assert %Action{rule: "R15a", kind: :to_rework} = action
    end

    test "step 6: Code Review, red after a rerun, same failure 3 times → R20 fix ticket owned by symphony" do
      action = PrDecision.decide(%Facts{phase: :code_review, ci: :red, rerun_done: true, same_failure_streak: 3, failing_check: "test"})
      assert %Action{rule: "R20", kind: :file_fix_ticket, owner: :symphony, args: %{check: "test"}} = action
    end

    test "step 7: QA, closed PR, no run → R8 to Rework" do
      action = PrDecision.decide(%Facts{phase: :qa, pr: :closed, run: :none, pr_number: 77})
      assert %Action{rule: "R8", kind: :to_rework, reason: "PR #77 was closed without merging"} = action
    end
  end
end
