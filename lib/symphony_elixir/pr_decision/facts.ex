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
    of each fix run, what a check red on the base too was compared with). They never choose a rule.
    `ahead` and `competing` are both: a rule reads them only as empty or not, and the action names
    the PRs in them.

  A red head is a plain failure (`red_kind: :failure`) unless the facts classify it otherwise.
  Limits and timeouts arrive as facts (`max_red_attempts`, `landing_timed_out`), so deciding reads
  no config and no clock.
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
          hold: :none | :needs_decision | :blocked,
          run: :none | :active,
          auto_merge: :off | :armed,
          pr: :missing | :open | :draft | :closed | :merged,
          pr_number: pos_integer() | nil,
          base: :ok | :changed,
          base_ref: String.t() | nil,
          head_origin: :symphony | :person,
          review_comments: :none | :unaddressed,
          ci: :pending | :green | :none | :red | :required_missing,
          no_ci: :not_configured | :not_reported,
          missing_checks: [String.t()],
          red_kind: :failure | :cancelled | :human_only | :also_red_on_base,
          base_red: base_red() | nil,
          failing_check: String.t() | nil,
          rerun_done: boolean(),
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
            ci: :pending,
            no_ci: :not_configured,
            missing_checks: [],
            red_kind: :failure,
            base_red: nil,
            failing_check: nil,
            rerun_done: false,
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
  # A placeholder competitor: a rule reads `ahead` and `competing` only as empty or not.
  @competitor %{issue_identifier: "TP-0", pr_number: 1, files: ["SPEC.md"]}

  # In enumeration order: a condition only names a fact listed before it. Each count lists the
  # value just under its limit and the limit itself (`max_red_attempts` is 10; conflicts stop at 3).
  @domains [
    {:phase, @phases},
    {:github, [:ok, :rate_limited]},
    {:hold, [:none, :needs_decision, :blocked]},
    {:run, [:none, :active]},
    {:auto_merge, [:off, :armed]},
    {:pr, [:missing, :open, :draft, :closed, :merged]},
    {:base, [:ok, :changed], @with_pr},
    {:head_origin, [:symphony, :person], @with_pr},
    {:review_comments, [:none, :unaddressed], @with_pr},
    {:ci, [:pending, :green, :none, :red, :required_missing], @with_pr},
    {:red_kind, [:failure, :cancelled, :human_only, :also_red_on_base], [ci: [:red]]},
    {:rerun_done, [false, true], @red_failure},
    {:red_attempts, [9, 10], @red_failure},
    {:same_failure_streak, [2, 3], @red_failure},
    {:mergeable, [:clean, :behind, :dirty, :unstable, :blocked, :unknown], @with_pr},
    {:ahead, [[], [@competitor]], [mergeable: [:dirty, :behind]]},
    {:conflict_attempts, [2, 3], [mergeable: [:dirty]]},
    {:competing, [[], [@competitor]], [mergeable: [:dirty]]},
    {:landing_timed_out, [false, true], [mergeable: [:blocked]]}
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
