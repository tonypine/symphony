defmodule SymphonyElixir.PrDecision do
  @moduledoc """
  The PR and CI decision table: for a ticket's phase and its PR facts, the one action the watcher
  takes.

  `rules/0` is the table as data, in precedence order: each rule names its id, the phases it acts
  in, a `when` and `then` line for `docs/pr-ci-decisions.md`, a guard and an action builder.
  `decide/1` returns the action of the first rule whose phase and guard match.

  Deciding is pure: it reads only `SymphonyElixir.PrDecision.Facts`, never GitHub, Linear, the run
  store, the clock or config. Limits and timeouts arrive as facts. A guard names the values it
  matches rather than falling through, so a fact value no rule handles raises `NoRuleError` and
  fails the table test instead of parking a ticket.
  """

  alias SymphonyElixir.PrDecision.{Action, Facts}

  defmodule NoRuleError do
    @moduledoc "Raised when no rule matches the facts: a gap in the decision table."
    defexception [:facts]

    @impl true
    def message(%__MODULE__{facts: facts}) do
      values = Enum.map_join(Facts.domains(), ", ", fn domain -> "#{elem(domain, 0)}: #{inspect(Map.get(facts, elem(domain, 0)))}" end)
      "no PR decision rule matches #{values}"
    end
  end

  @type rule :: %{
          id: String.t(),
          phases: [Facts.phase()],
          when: String.t(),
          then: String.t(),
          guard: (Facts.t() -> boolean()),
          build: (Facts.t() -> Action.t())
        }

  # Conflicts stop at a fixed 3 fix runs (D7 (b), D16); there is no setting for it.
  @max_conflict_attempts 3
  # The same failure this many CI Fix runs in a row reaches the red backstop (D15 (c)).
  @max_same_failures 3

  @all Facts.phases()
  @pr_phases [:code_review, :qa, :rework, :ci_fix, :merging]
  @reviewed [:code_review, :qa, :merging]
  @with_pr [:open, :draft]
  @green [:green, :none]
  @mergeable_now [:clean, :unstable]

  @phase_names %{
    in_progress: "In Progress",
    code_review: "Code Review",
    qa: "QA",
    rework: "Rework",
    ci_fix: "CI Fix",
    merging: "Merging"
  }

  @doc "The fixed number of CI Fix runs a conflict gets before it waits on its competitors or goes to Rework."
  @spec max_conflict_attempts() :: pos_integer()
  def max_conflict_attempts, do: @max_conflict_attempts

  @doc "A phase's Linear state name."
  @spec phase_name(Facts.phase()) :: String.t()
  def phase_name(phase), do: Map.fetch!(@phase_names, phase)

  @doc "The action for `facts`: the first matching rule's. Raises `NoRuleError` when none matches."
  @spec decide(Facts.t()) :: Action.t()
  def decide(%Facts{} = facts) do
    case Enum.find(rules(), &matches?(&1, facts)) do
      nil -> raise NoRuleError, facts: facts
      rule -> rule.build.(facts)
    end
  end

  @doc "Whether `rule` acts on `facts`: the phase is one of its phases and its guard holds."
  @spec matches?(rule(), Facts.t()) :: boolean()
  def matches?(rule, %Facts{phase: phase} = facts), do: phase in rule.phases and rule.guard.(facts)

  @doc "The decision table, in precedence order."
  @spec rules() :: [rule()]
  def rules do
    [
      %{
        id: "R1",
        phases: @all,
        when: "GitHub's rate limit is spent, so the facts can't be read",
        then: "`wait` on `github` until the limit resets",
        guard: &rate_limited?/1,
        build: &wait_for_rate_limit/1
      },
      %{id: "R2", phases: @all, when: "The PR is merged, by Symphony or anyone else", then: "`close_out`", guard: &merged?/1, build: &close_out/1},
      %{
        id: "R3",
        phases: @all -- [:merging],
        when: "Auto-merge is armed and the ticket is not in Merging",
        then: "`disarm`",
        guard: &armed?/1,
        build: &disarm/1
      },
      %{
        id: "R4",
        phases: @all,
        when: "A Needs Decision or Blocked hold is set",
        then: "`wait` on `person` (Needs Decision) or `symphony` (Blocked) until the hold clears",
        guard: &held?/1,
        build: &wait_for_hold/1
      },
      %{id: "R5", phases: [:in_progress], when: "No PR yet", then: "`wait` on `agent` until it opens one", guard: &pr_missing?/1, build: &wait_for_first_pr/1},
      %{
        id: "R6",
        phases: @pr_phases,
        when: "No PR on the ticket and no run",
        then: "`decision`: attach the PR, Restart, or cancel the ticket",
        guard: &pr_missing_idle?/1,
        build: &ask_about_missing_pr/1
      },
      %{
        id: "R7",
        phases: @all,
        when: "The PR's base is not the repo's base branch, and no run",
        then: "`decision`: put the base back, or accept the new base",
        guard: &base_changed_idle?/1,
        build: &ask_about_base/1
      },
      %{
        id: "R8",
        phases: @all,
        when: "The PR was closed without merging (or its branch deleted)",
        then: "run active: `wait` on `agent`; In Progress or Rework: `dispatch`; otherwise `to_rework`",
        guard: &closed?/1,
        build: &closed_pr/1
      },
      %{id: "R9", phases: @all, when: "A run is active", then: "`wait` on `agent` until the run ends", guard: &run_active?/1, build: &wait_for_run/1},
      %{
        id: "R10",
        phases: @reviewed,
        when: "The PR is a draft",
        then: "`wait` on `person` until it is marked ready for review",
        guard: &draft?/1,
        build: &wait_for_ready/1
      },
      %{
        id: "R11",
        phases: [:merging],
        when: "A person pushed the PR's head",
        then: "`to_code_review` (auto-merge goes off by R3)",
        guard: &person_head?/1,
        build: &back_to_code_review/1
      },
      %{id: "R12", phases: [:in_progress], when: "The PR is open and no run", then: "`dispatch` the agent", guard: &with_pr?/1, build: &dispatch/1},
      %{
        id: "R13",
        phases: @reviewed,
        when: "Review comments or requested changes are unaddressed",
        then: "`to_in_progress` on the same PR",
        guard: &review_comments?/1,
        build: &to_in_progress/1
      },
      %{
        id: "R14a",
        phases: @pr_phases,
        when: "The PR conflicts with main and a PR sharing its files is ahead in the landing order",
        then: "`wait_for_competitors` on the PRs ahead",
        guard: &conflict_behind?/1,
        build: &wait_for_ahead/1
      },
      %{
        id: "R14",
        phases: @pr_phases,
        when: "The PR conflicts with main, fewer than #{@max_conflict_attempts} conflict fix runs",
        then: "`ci_fix` for the conflict",
        guard: &conflict_fixable?/1,
        build: &ci_fix_conflict/1
      },
      %{
        id: "R15",
        phases: @pr_phases,
        when: "The conflict is back after #{@max_conflict_attempts} fix runs and open PRs share its files",
        then: "`wait_for_competitors` on every competing PR, stepping behind them",
        guard: &conflict_competed?/1,
        build: &wait_for_competing/1
      },
      %{
        id: "R15a",
        phases: @pr_phases,
        when: "The conflict is back after #{@max_conflict_attempts} fix runs and no open PR competes",
        then: "`to_rework` (Rework: `dispatch`)",
        guard: &conflict_alone?/1,
        build: &conflict_to_rework/1
      },
      %{
        id: "R16",
        phases: [:merging],
        when: "GitHub has not computed whether the PR can merge",
        then: "`wait` on `github`",
        guard: &mergeable_unknown?/1,
        build: &wait_for_mergeability/1
      },
      %{
        id: "R17",
        phases: @pr_phases,
        when: "A required check never reported within `landing_wait_timeout_ms`",
        then: "`decision`: proceed without it for this PR (this head only), rerun, or fix the workflow in Rework",
        guard: &required_missing?/1,
        build: &ask_about_missing_check/1
      },
      %{
        id: "R18",
        phases: @pr_phases,
        when: "Only a check a person must clear is red (`protected paths`)",
        then: "`decision`: add the waiver label, or drop the change in Rework",
        guard: &human_only_red?/1,
        build: &ask_about_human_only/1
      },
      %{
        id: "R19",
        phases: @pr_phases,
        when: "Red only because every run of a workflow was cancelled, its newest attempt with nothing queued or running",
        then: "`rerun_failed`, no attempt spent",
        guard: &cancelled_red?/1,
        build: &rerun_cancelled/1
      },
      %{
        id: "R20",
        phases: @pr_phases,
        when: "Red, and the same failure #{@max_same_failures} fix runs in a row or `red_attempts` at `max_red_attempts`",
        then: "`file_fix_ticket` for the failing check, waiting on `symphony` until it is terminal",
        guard: &red_backstop?/1,
        build: &file_fix_ticket/1
      },
      %{
        id: "R21",
        phases: @pr_phases,
        when: "Red after a rerun",
        then: "`ci_fix` for the red head, back to the phase it came from",
        guard: &red_after_rerun?/1,
        build: &ci_fix_red/1
      },
      %{id: "R22", phases: @pr_phases, when: "Red, not rerun yet", then: "`rerun_failed` once", guard: &red_first?/1, build: &rerun_red/1},
      %{
        id: "R23",
        phases: @pr_phases,
        when: "Red, and the same check is red on the base branch",
        then: "`wait` on `ci` until the base goes green",
        guard: &red_on_base?/1,
        build: &wait_for_base/1
      },
      %{
        id: "R24",
        phases: [:code_review, :qa, :ci_fix],
        when: "Checks are running on the head",
        then: "`wait` on `ci`",
        guard: &pending?/1,
        build: &wait_for_checks/1
      },
      %{
        id: "R25",
        phases: [:ci_fix],
        when: "Green (or no CI) and conflict-free",
        then: "`return_to_origin`, approvals carried forward",
        guard: &green?/1,
        build: &return_to_origin/1
      },
      %{
        id: "R26",
        phases: [:rework],
        when: "Not red, not conflicting, no run",
        then: "`dispatch` the rework run",
        guard: &not_red?/1,
        build: &dispatch/1
      },
      %{
        id: "R27",
        phases: [:code_review, :qa],
        when: "Green, or no CI configured (counts as green)",
        then: "`dispatch` the reviewer or the QA agent",
        guard: &green?/1,
        build: &dispatch/1
      },
      %{
        id: "R28",
        phases: [:merging],
        when: "The PR is behind main",
        then: "a PR ahead shares its files: `wait` on `symphony`; otherwise `update_branch`",
        guard: &behind?/1,
        build: &behind/1
      },
      %{id: "R29", phases: [:merging], when: "Green (or no CI) and mergeable now", then: "`merge_now`", guard: &mergeable_now?/1, build: &merge_now/1},
      %{
        id: "R30",
        phases: [:merging],
        when: "Auto-merge off, and checks running or branch protection still blocking",
        then: "`arm` auto-merge",
        guard: &armable?/1,
        build: &arm/1
      },
      %{
        id: "R31",
        phases: [:merging],
        when: "Branch protection blocked the merge past the merge wait",
        then: "`land_agent`",
        guard: &blocked_too_long?/1,
        build: &land_agent/1
      },
      %{
        id: "R32",
        phases: [:merging],
        when: "Auto-merge armed and checks running",
        then: "`wait` on `ci`; auto-merge lands it",
        guard: &armed_pending?/1,
        build: &wait_for_auto_merge_checks/1
      },
      %{
        id: "R33",
        phases: [:merging],
        when: "Auto-merge armed and branch protection still blocking",
        then: "`wait` on `github` until it is satisfied or the merge wait passes",
        guard: &armed_blocked?/1,
        build: &wait_for_branch_protection/1
      }
    ]
  end

  # Guards. Each names the values it matches, so an unknown value matches nothing.

  defp rate_limited?(facts), do: facts.github == :rate_limited
  defp merged?(facts), do: fresh?(facts) and facts.pr == :merged
  defp armed?(facts), do: fresh?(facts) and facts.auto_merge == :armed
  defp held?(facts), do: fresh?(facts) and facts.hold in [:needs_decision, :blocked]
  defp pr_missing?(facts), do: free?(facts) and facts.pr == :missing
  defp pr_missing_idle?(facts), do: pr_missing?(facts) and facts.run == :none
  defp base_changed_idle?(facts), do: with_pr?(facts) and facts.base == :changed and facts.run == :none
  defp closed?(facts), do: free?(facts) and facts.pr == :closed and facts.run in [:none, :active]
  defp run_active?(facts), do: free?(facts) and facts.run == :active
  defp draft?(facts), do: idle_pr?(facts) and facts.pr == :draft
  defp person_head?(facts), do: idle_pr?(facts) and facts.head_origin == :person
  defp with_pr?(facts), do: idle_pr?(facts) and facts.base in [:ok, :changed]
  defp review_comments?(facts), do: idle_pr?(facts) and facts.review_comments == :unaddressed
  defp conflict_behind?(facts), do: conflicting?(facts) and facts.ahead != []
  defp conflict_fixable?(facts), do: conflicting?(facts) and facts.conflict_attempts < @max_conflict_attempts
  defp conflict_competed?(facts), do: conflict_exhausted?(facts) and facts.competing != []
  defp conflict_alone?(facts), do: conflict_exhausted?(facts) and facts.competing == []
  defp mergeable_unknown?(facts), do: not_red?(facts) and facts.mergeable == :unknown
  defp required_missing?(facts), do: clean_pr?(facts) and facts.ci == :required_missing
  defp human_only_red?(facts), do: red?(facts, :human_only)
  defp cancelled_red?(facts), do: red?(facts, :cancelled)

  defp red_backstop?(facts) do
    repeating? = facts.same_failure_streak >= @max_same_failures
    red?(facts, :failure) and (repeating? or facts.red_attempts >= facts.max_red_attempts)
  end

  defp red_after_rerun?(facts), do: red?(facts, :failure) and facts.rerun_done == true
  defp red_first?(facts), do: red?(facts, :failure) and facts.rerun_done == false
  defp red_on_base?(facts), do: red?(facts, :also_red_on_base)
  defp pending?(facts), do: clean_pr?(facts) and facts.ci == :pending
  defp green?(facts), do: clean_pr?(facts) and facts.ci in @green
  defp not_red?(facts), do: clean_pr?(facts) and facts.ci in [:pending | @green]
  defp behind?(facts), do: not_red?(facts) and facts.mergeable == :behind
  defp mergeable_now?(facts), do: green?(facts) and facts.mergeable in @mergeable_now

  defp armable?(facts) do
    facts.auto_merge == :off and (pending_mergeable?(facts) or blocked_in_time?(facts))
  end

  defp blocked_too_long?(facts), do: blocked?(facts) and facts.landing_timed_out == true
  defp armed_pending?(facts), do: facts.auto_merge == :armed and pending_mergeable?(facts)
  defp armed_blocked?(facts), do: facts.auto_merge == :armed and blocked_in_time?(facts)

  # The facts are fresh (R1) and no hold claimed the ticket (R4).
  defp fresh?(facts), do: facts.github == :ok
  defp free?(facts), do: fresh?(facts) and facts.hold == :none

  # The PR is open and nothing earlier in the table claimed it: no hold, no run.
  defp idle_pr?(facts), do: free?(facts) and facts.run == :none and facts.pr in @with_pr
  defp conflicting?(facts), do: idle_pr?(facts) and facts.mergeable == :dirty
  defp conflict_exhausted?(facts), do: conflicting?(facts) and facts.ahead == [] and facts.conflict_attempts >= @max_conflict_attempts

  # Not conflicting: from here on a rule reads the checks, and the mergeability only in Merging.
  defp clean_pr?(facts) do
    idle_pr?(facts) and facts.mergeable in [:clean, :behind, :unstable, :blocked, :unknown]
  end

  defp red?(facts, kind), do: clean_pr?(facts) and facts.ci == :red and facts.red_kind == kind
  defp pending_mergeable?(facts), do: pending?(facts) and facts.mergeable in @mergeable_now
  defp blocked?(facts), do: not_red?(facts) and facts.mergeable == :blocked
  defp blocked_in_time?(facts), do: blocked?(facts) and facts.landing_timed_out == false

  # Action builders.

  defp wait_for_rate_limit(_facts) do
    wait("R1", "GitHub's rate limit is spent: the PR can't be read until it resets", :github, "GitHub's rate limit resets")
  end

  defp close_out(facts), do: Action.new!("R2", :close_out, reason: "#{subject(pr(facts))} was merged")
  defp disarm(facts), do: Action.new!("R3", :disarm, reason: "Auto-merge is armed on #{pr(facts)} but the ticket is in #{phase_name(facts.phase)}")

  defp wait_for_hold(%{hold: :needs_decision}), do: wait("R4", "A Needs Decision hold pauses the ticket", :person, "a person answers and the hold clears")
  defp wait_for_hold(%{hold: :blocked}), do: wait("R4", "A Blocked hold pauses the ticket", :symphony, "what it waits on is done and the hold clears")

  defp wait_for_first_pr(_facts), do: wait("R5", "No PR yet: the agent opens one", :agent, "the agent opens the PR")

  defp ask_about_missing_pr(facts) do
    decision("R6", "The ticket is in #{phase_name(facts.phase)} with no PR", [
      "Attach the PR to the ticket",
      "Restart the ticket from main",
      "Cancel the ticket"
    ])
  end

  defp ask_about_base(facts) do
    decision("R7", "#{subject(pr(facts))} targets another base than the repo's base branch", [
      "Put the base back to the repo's base branch",
      "Accept the new base for this PR"
    ])
  end

  defp closed_pr(%{run: :active} = facts) do
    wait("R8", "#{subject(pr(facts))} was closed without merging: waiting for the run to end", :agent, "the run ends")
  end

  defp closed_pr(%{phase: phase} = facts) when phase in [:in_progress, :rework] do
    Action.new!("R8", :dispatch, args: %{phase: phase}, reason: "#{subject(pr(facts))} was closed without merging: the next run opens a new PR from main")
  end

  defp closed_pr(facts), do: Action.new!("R8", :to_rework, reason: "#{subject(pr(facts))} was closed without merging")

  defp wait_for_run(_facts), do: wait("R9", "A run is working on the ticket", :agent, "the run ends")
  defp wait_for_ready(facts), do: wait("R10", "A person marked #{pr(facts)} as a draft", :person, "the PR is marked ready for review")
  defp back_to_code_review(facts), do: Action.new!("R11", :to_code_review, reason: "A person pushed to #{pr(facts)} while it was in Merging")
  defp to_in_progress(facts), do: Action.new!("R13", :to_in_progress, reason: "#{subject(pr(facts))} has review comments to address")

  defp dispatch(facts) do
    {rule, reason} = dispatch_reason(facts)
    Action.new!(rule, :dispatch, args: %{phase: facts.phase}, reason: reason)
  end

  defp dispatch_reason(%{phase: :in_progress}), do: {"R12", "The agent continues the PR"}
  defp dispatch_reason(%{phase: :rework}), do: {"R26", "The rework run continues the PR"}
  defp dispatch_reason(%{ci: :none} = facts), do: {"R27", "#{no_ci(facts)}: counts as green, so #{reviewer(facts)} runs"}
  defp dispatch_reason(facts), do: {"R27", "The head is green, so #{reviewer(facts)} runs"}

  defp wait_for_ahead(facts) do
    Action.new!("R14a", :wait_for_competitors,
      args: %{prs: facts.ahead, step_behind: false},
      reason: "Lands after #{names(facts.ahead)}: they change the same files (#{files(facts.ahead)})",
      owner: :symphony,
      clears_when: "every PR ahead lands or leaves the race"
    )
  end

  defp ci_fix_conflict(facts) do
    Action.new!("R14", :ci_fix,
      args: %{origin: origin(facts), cause: :conflict},
      reason: "#{subject(pr(facts))} conflicts with main: conflict fix run #{facts.conflict_attempts + 1} of #{@max_conflict_attempts}"
    )
  end

  defp wait_for_competing(facts) do
    Action.new!("R15", :wait_for_competitors,
      args: %{prs: facts.competing, step_behind: true},
      reason:
        "The conflict with main came back after #{@max_conflict_attempts} fix runs: waiting on #{names(facts.competing)} to land, " <>
          "they change the same files (#{files(facts.competing)})",
      owner: :symphony,
      clears_when: "every competing PR lands or leaves the race"
    )
  end

  defp conflict_to_rework(facts) do
    reason = "The conflict with main came back after #{@max_conflict_attempts} fix runs and no open PR competes"

    case facts.phase do
      :rework -> Action.new!("R15a", :dispatch, args: %{phase: :rework}, reason: reason)
      _phase -> Action.new!("R15a", :to_rework, reason: reason)
    end
  end

  defp wait_for_mergeability(facts) do
    wait("R16", "GitHub is still computing whether #{pr(facts)} can merge", :github, "GitHub reports whether the PR can merge")
  end

  defp ask_about_missing_check(facts) do
    decision("R17", "Required check #{Enum.join(facts.missing_checks, ", ")} never reported on #{pr(facts)}", [
      "Proceed without it for this PR",
      "Rerun the checks",
      "Fix the workflow in Rework"
    ])
  end

  defp ask_about_human_only(facts) do
    decision("R18", "Only #{check(facts)} is red on #{pr(facts)}, and only a person can clear it", [
      "Add the waiver label",
      "Drop the change in Rework"
    ])
  end

  defp rerun_cancelled(facts), do: Action.new!("R19", :rerun_failed, reason: "Every run of #{check(facts)} was cancelled: rerunning it, no attempt spent")

  defp file_fix_ticket(facts) do
    Action.new!("R20", :file_fix_ticket,
      args: %{
        check: facts.failing_check,
        evidence: facts.fix_failures,
        red_attempts: facts.red_attempts,
        max_red_attempts: facts.max_red_attempts,
        same_failure_streak: facts.same_failure_streak
      },
      reason: "CI keeps failing: waiting on a fix ticket for #{check(facts)}",
      owner: :symphony,
      clears_when: "the fix ticket is terminal"
    )
  end

  defp ci_fix_red(facts) do
    Action.new!("R21", :ci_fix,
      args: %{origin: origin(facts), cause: :red},
      reason: "#{subject(check(facts))} failed on #{pr(facts)}: CI Fix run #{facts.red_attempts + 1} of #{facts.max_red_attempts}"
    )
  end

  defp rerun_red(facts), do: Action.new!("R22", :rerun_failed, reason: "#{subject(check(facts))} failed on #{pr(facts)}: rerunning it once before CI Fix")
  defp wait_for_base(facts), do: wait("R23", "#{subject(check(facts))} is red on the base branch too#{base_compared(facts)}", :ci, "the check goes green on the base branch")
  defp wait_for_checks(facts), do: wait("R24", "Checks are running on #{pr(facts)}'s head", :ci, "the checks finish")

  defp return_to_origin(facts) do
    destination = origin(facts)
    Action.new!("R25", :return_to_origin, args: %{origin: destination}, reason: "The head is green and conflict-free: back to #{phase_name(destination)} with its approvals")
  end

  defp behind(%{ahead: []} = facts), do: Action.new!("R28", :update_branch, reason: "#{subject(pr(facts))} is behind main")

  defp behind(facts) do
    Action.new!("R28", :wait,
      args: %{prs: facts.ahead},
      reason: "#{subject(pr(facts))} is behind main and lands after #{names(facts.ahead)}: they change the same files (#{files(facts.ahead)})",
      owner: :symphony,
      clears_when: "every PR ahead lands or leaves the race"
    )
  end

  defp merge_now(facts), do: Action.new!("R29", :merge_now, reason: "#{subject(pr(facts))} is green and can merge")
  defp arm(facts), do: Action.new!("R30", :arm, reason: "#{subject(pr(facts))} is waiting on checks or branch protection: GitHub auto-merge lands it")
  defp land_agent(facts), do: Action.new!("R31", :land_agent, reason: "Branch protection kept #{pr(facts)} from merging past the merge wait")
  defp wait_for_auto_merge_checks(facts), do: wait("R32", "Checks are running on #{pr(facts)}: auto-merge lands it when they pass", :ci, "the checks finish")

  defp wait_for_branch_protection(facts) do
    wait("R33", "Branch protection holds #{pr(facts)}: auto-merge lands it once it is satisfied", :github, "branch protection is satisfied or the merge wait passes")
  end

  defp wait(rule, reason, owner, clears_when), do: Action.new!(rule, :wait, reason: reason, owner: owner, clears_when: clears_when)

  defp decision(rule, question, options) do
    Action.new!(rule, :decision, args: %{question: question, options: options}, reason: question, owner: :person, clears_when: "a person answers")
  end

  # A CI Fix ticket whose origin was not recorded goes back through review.
  defp origin(%{phase: :ci_fix, origin: nil}), do: :code_review
  defp origin(%{phase: :ci_fix, origin: origin}), do: origin
  defp origin(%{phase: phase}), do: phase

  defp no_ci(%{no_ci: :not_reported}), do: "No check reported on the head within the wait"
  defp no_ci(%{base_ref: base}) when is_binary(base), do: "No CI configured on #{base}"
  defp no_ci(_facts), do: "No CI configured on the base"

  defp reviewer(%{phase: :code_review}), do: "the reviewer"
  defp reviewer(%{phase: :qa}), do: "the QA agent"

  defp pr(%{pr_number: number}) when is_integer(number), do: "PR ##{number}"
  defp pr(_facts), do: "the PR"

  # What R23 compared on the base: the base's run and commit, and the failing tests or the name alone.
  defp base_compared(%{base_red: %{run_id: run_id, basis: basis} = red} = facts) do
    on = "#{facts.base_ref || "the base branch"}#{short_sha(red[:sha])} (run #{run_id})"

    case basis do
      :tests -> ": it failed the same tests on #{on}"
      :name -> ": the check of that name failed on #{on}, compared by name only"
    end
  end

  defp base_compared(_facts), do: ""

  defp short_sha(sha) when is_binary(sha), do: " at #{String.slice(sha, 0, 8)}"
  defp short_sha(_sha), do: ""

  defp check(%{failing_check: check}) when is_binary(check), do: "the `#{check}` check"
  defp check(_facts), do: "a check"

  # A phrase opening a sentence.
  defp subject(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp names(competitors), do: Enum.map_join(competitors, " and ", &name/1)

  defp name(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp name(%{pr_number: number}) when is_integer(number), do: "PR ##{number}"
  defp name(_competitor), do: "an open PR"

  defp files(competitors), do: competitors |> Enum.flat_map(& &1.files) |> Enum.uniq() |> Enum.join(", ")
end
