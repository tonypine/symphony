defmodule SymphonyElixir.PrDecision.Facts do
  @moduledoc """
  What the PR and CI watcher knows about one ticket's pull request, in normalised values only: no
  GitHub or Linear shapes. `SymphonyElixir.PrDecision.decide/1` reads nothing else.

  Two kinds of field:

  - **Decided on.** Each takes one value from `domains/0`. A fact that only means something under
    another one (the kind of red, the conflict count) names that condition there and keeps its
    default otherwise. `combinations/1` enumerates every combination, which is how the table test
    proves that every situation has exactly one rule.
  - **Carried.** Names and numbers the action quotes back (the PR number, the base branch, why a
    head reads as having no CI, the phase a CI Fix run returns to, the failing check, the evidence
    of each fix run, what a check red on the base too was compared with, the cancelled checks the
    base doesn't require that were set aside past their reruns). They never choose a rule.
    `ahead` and `competing` are both: a rule reads them only as empty or not, and the action names
    the PRs in them.

  A red head is a plain failure (`red_kind: :failure`) unless the facts classify it otherwise.
  `base_held` says that this head was read red on the base branch too (R23 held it) and its branch
  has not been updated from the base since: a failure on it now is the base's fix still to take in.
  Limits and timeouts arrive as facts (`max_red_attempts`, `landing_timed_out`), so deciding reads
  no config and no clock.

  `review` says whether Code Review approved the head (`:approved`) or still has to judge it
  (`:pending`, the default). A review reads the code whatever CI says, so CI's state is decided on in
  Code Review only once the head is approved. In Rework it says whether Code Review's changes verdict
  stands on the head (`:changes_requested`): that code is about to change, so CI's state decides nothing
  there either.

  `merge_guard` says whether the ticket's plan lets its pull request go on to the merge (`:clear`,
  the default). `:open_checks`: a check of the current plan the next step owes is open (in Merging,
  or in CI Fix on the way back to it, any check, unless every open one is a `:ci_checks` one; before
  it, a check a test or an attachment proves). `:rewritten`: a plan version was written after the newest
  coding run started, so the code and any approval of it are for an older plan. `:held`: the
  Conductor held the merge since that run (`SymphonyElixir.TicketJourney.outdated/1`).
  `:ci_checks`: in Merging, the only open checks are ones the pull request's own CI run proves
  (`proof: ci`), so the merge waits on their proof instead of sending the ticket to Rework.

  `ci_proof` says, for `:ci_checks`, where that proof stands on the head
  (`SymphonyElixir.PrWatch.CiProof`): `:provable`, a check names a CI check that passed on the
  head, so Symphony records the proof itself; `:running`, nothing provable yet and checks still
  run; `:turn`, the checks finished and a check is left that a run must read the results for, and
  no run had that turn on the head; `:spent`, that run had its turn on the head and the check is
  still open. `:none` (the default) everywhere else.
  """

  @typedoc "The ticket's phase: one of the watched Linear states."
  @type phase :: :in_progress | :code_review | :qa | :rework | :ci_fix | :merging

  @typedoc "A PR that changes some of the same files, with its ticket when Symphony tracks it."
  @type competitor :: %{
          required(:files) => [String.t()],
          optional(:issue_id) => String.t() | nil,
          optional(:issue_identifier) => String.t() | nil,
          optional(:pr_number) => pos_integer() | nil,
          optional(:pr_url) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:head_sha) => String.t() | nil
        }

  @typedoc """
  One CI Fix run's failure: the check that failed, the first line of its error, and the head it
  failed on. The check and the error are its signature (`SymphonyElixir.PrWatch.Attempts.signature/1`).
  """
  @type failure :: %{
          required(:check) => String.t(),
          required(:error) => String.t(),
          optional(:head_sha) => String.t() | nil
        }

  @typedoc "How a check red on the base too was compared: by its failing tests, or by its name only."
  @type base_basis :: :tests | :name

  @typedoc """
  What a check red on the base too was compared with: the check, the base's workflow run and the
  commit it ran on, and how they were compared.
  """
  @type base_red :: %{check: String.t() | nil, sha: String.t() | nil, run_id: String.t(), basis: base_basis()}

  @type t :: %__MODULE__{
          phase: phase(),
          origin: :code_review | :qa | :rework | :merging | nil,
          github: :ok | :rate_limited,
          hold: :none | :question | :blocked,
          run: :none | :active,
          auto_merge: :off | :armed,
          pr: :missing | :open | :draft | :closed | :merged,
          pr_number: pos_integer() | nil,
          base: :ok | :changed,
          base_ref: String.t() | nil,
          head_origin: :symphony | :person,
          review_comments: :none | :unaddressed,
          review: :pending | :approved | :changes_requested,
          merge_guard: :clear | :open_checks | :rewritten | :held | :ci_checks,
          ci_proof: :none | :provable | :running | :turn | :spent,
          ci: :pending | :green | :none | :red | :required_missing,
          no_ci: :not_configured | :not_reported,
          missing_checks: [String.t()],
          running_checks: [String.t()],
          red_kind: :failure | :cancelled | :human_only | :also_red_on_base | :run_in_progress,
          base_red: base_red() | nil,
          failing_check: String.t() | nil,
          set_aside: [String.t()],
          rerun_done: boolean(),
          base_held: boolean(),
          cancel_reruns: non_neg_integer(),
          red_attempts: non_neg_integer(),
          max_red_attempts: pos_integer(),
          same_failure_streak: non_neg_integer(),
          fix_failures: [failure()],
          mergeable: :clean | :behind | :dirty | :unstable | :blocked | :unknown,
          ahead: [competitor()],
          competing: [competitor()],
          conflict_attempts: non_neg_integer(),
          landing_timed_out: boolean()
        }

  @typedoc """
  The values one fact takes, and the condition under which it is enumerated: each fact named in it
  holding one of the values listed. Outside it the fact keeps its default.
  """
  @type domain :: {atom(), [term()]} | {atom(), [term()], [{atom(), [term()]}]}

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct phase: :in_progress,
            origin: nil,
            github: :ok,
            hold: :none,
            run: :none,
            auto_merge: :off,
            pr: :open,
            pr_number: nil,
            base: :ok,
            base_ref: nil,
            head_origin: :symphony,
            review_comments: :none,
            review: :pending,
            merge_guard: :clear,
            ci_proof: :none,
            ci: :pending,
            no_ci: :not_configured,
            missing_checks: [],
            running_checks: [],
            red_kind: :failure,
            base_red: nil,
            failing_check: nil,
            set_aside: [],
            rerun_done: false,
            base_held: false,
            cancel_reruns: 0,
            red_attempts: 0,
            max_red_attempts: 10,
            same_failure_streak: 0,
            fix_failures: [],
            mergeable: :unknown,
            ahead: [],
            competing: [],
            conflict_attempts: 0,
            landing_timed_out: false

  @phases [:in_progress, :code_review, :qa, :rework, :ci_fix, :merging]
  @with_pr [pr: [:open, :draft]]
  @red_failure [ci: [:red], red_kind: [:failure]]
  @guarded_phases [:code_review, :qa, :ci_fix, :merging]
  @guarded [phase: @guarded_phases, hold: [:none], run: [:none], pr: [:open], ci: [:green], mergeable: [:clean, :dirty]]
  # A placeholder competitor: a rule reads `ahead` and `competing` only as empty or not.
  @competitor %{issue_identifier: "TP-0", pr_number: 1, files: ["SPEC.md"]}

  # In enumeration order: a condition only names a fact listed before it. Each count lists the
  # value just under its limit and the limit itself (`max_red_attempts` is 10; conflicts stop at 3;
  # a cancelled run is rerun twice).
  @domains [
    {:phase, @phases},
    {:github, [:ok, :rate_limited]},
    {:hold, [:none, :question, :blocked]},
    {:run, [:none, :active]},
    {:auto_merge, [:off, :armed]},
    {:pr, [:missing, :open, :draft, :closed, :merged]},
    {:base, [:ok, :changed], @with_pr},
    {:head_origin, [:symphony, :person], @with_pr},
    {:review_comments, [:none, :unaddressed], @with_pr},
    {:review, [:pending, :approved], [phase: [:code_review], pr: [:open, :draft]]},
    {:review, [:pending, :changes_requested], [phase: [:rework], pr: [:open, :draft]]},
    {:ci, [:pending, :green, :none, :red, :required_missing], @with_pr},
    {:red_kind, [:failure, :cancelled, :human_only, :also_red_on_base, :run_in_progress], [ci: [:red]]},
    {:cancel_reruns, [1, 2], [ci: [:red], red_kind: [:cancelled]]},
    {:base_held, [false, true], @red_failure},
    {:rerun_done, [false, true], @red_failure},
    {:red_attempts, [9, 10], @red_failure},
    {:same_failure_streak, [2, 3], @red_failure},
    {:mergeable, [:clean, :behind, :dirty, :unstable, :blocked, :unknown], @with_pr},
    {:ahead, [[], [@competitor]], [mergeable: [:dirty, :behind]]},
    {:conflict_attempts, [2, 3], [mergeable: [:dirty]]},
    {:competing, [[], [@competitor]], [mergeable: [:dirty]]},
    {:landing_timed_out, [false, true], [mergeable: [:blocked]]},
    # Read only where the merge is next or carried on to, and enumerated on one clean and one
    # conflicting green PR with no hold and no run: the rule that guards it reads nothing else.
    {:merge_guard, [:clear, :open_checks, :rewritten, :held, :ci_checks], @guarded},
    {:ci_proof, [:provable, :running, :turn, :spent], [merge_guard: [:ci_checks]]}
  ]

  @doc "Builds facts from a map or keyword list; an unknown key raises."
  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}), do: struct!(__MODULE__, attrs)

  @doc "Every watched phase, in workflow order."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "The values of every fact a rule decides on, with the condition each is enumerated under."
  @spec domains() :: [domain()]
  def domains, do: @domains

  @doc """
  Every combination of the values in `domains`, as facts, lazily. A conditional fact branches only
  where its condition holds.
  """
  @spec combinations([domain()]) :: Enumerable.t()
  def combinations(domains \\ @domains) do
    Enum.reduce(domains, [%__MODULE__{}], fn domain, acc -> Stream.flat_map(acc, &expand(&1, domain)) end)
  end

  defp expand(facts, {field, values}), do: Enum.map(values, &Map.put(facts, field, &1))

  defp expand(facts, {field, values, condition}) do
    if Enum.all?(condition, fn {on, allowed} -> Map.fetch!(facts, on) in allowed end), do: expand(facts, {field, values}), else: [facts]
  end
end
