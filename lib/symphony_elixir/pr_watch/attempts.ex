defmodule SymphonyElixir.PrWatch.Attempts do
  @moduledoc """
  What the PR and CI watcher counts per ticket, kept on its record (`TicketState.pr_watch`) from one
  tick to the next, and the facts it feeds `SymphonyElixir.PrDecision.decide/1`.

  Two counts of CI Fix runs, which never spend each other's kind:

    * **red**: a run sent for a red head (`R21`). It is held against
      `pull_requests.checks.max_fix_attempts` (default 10): a backstop, not a budget (D15). Reaching
      it files a fix ticket for CI (`R20`). The count restarts when that fix ticket's `Blocked` hold
      clears, so the head gets CI Fix runs again.
    * **conflict**: a run sent for a conflict with the base branch (`R14`), against a fixed
      #{SymphonyElixir.PrDecision.max_conflict_attempts()}.

  Both reset only when the PR is green **and** conflict-free: a conflicting PR keeps its last green
  checks, because GitHub doesn't run its workflows while it conflicts, so a green read alone says
  nothing about the conflict.

  It also keeps the heads whose failed checks were rerun once (`rerun_done`), with the checks each
  rerun named, so a rerun whose checks dropped out of the rollup reads as running rather than green
  (`rerun_pending?/2`); each red run's failing check and first error line (`fix_failures`, the fix
  ticket's evidence); the fix ticket a backstop filed; since when a `Merging` head has been
  blocked by branch protection on green checks (`landing_timed_out`); the head an update-branch
  moved past, whose runs are cancelled once the head moves on; and the last head Symphony knows it
  put there in a `Merging` stay (`trusted_head`): the head the stay began on, one a run left, or
  the one an update-branch made. Any other head in `Merging` is a person's push (`head_origin`).

  Since GitHub shows Symphony's pushes and a person's under the same account, the head's author
  can't tell them apart; where the head came from can.

  Everything here is pure: the caller passes the read and the clock.
  """

  alias SymphonyElixir.PrDecision.Facts

  @typedoc "Since when the head has been blocked by branch protection on green checks."
  @type blocked :: %{head_sha: String.t() | nil, since: DateTime.t()}

  @type t :: %{
          red: non_neg_integer(),
          conflict: non_neg_integer(),
          reruns: %{optional(String.t()) => [String.t()]},
          fix_failures: [Facts.failure()],
          fix_ticket: String.t() | nil,
          blocked: blocked() | nil,
          updated_from: String.t() | nil,
          trusted_head: String.t() | nil,
          head_origin: :symphony | :person
        }

  @conflict_free [:clean, :behind, :unstable, :blocked]
  @green [:green, :none]

  @doc "No attempts spent."
  @spec new() :: t()
  def new do
    %{red: 0, conflict: 0, reruns: %{}, fix_failures: [], fix_ticket: nil, blocked: nil, updated_from: nil, trusted_head: nil, head_origin: :symphony}
  end

  @doc "The attempts a record kept, with defaults for what it lacks; anything else is `new/0`."
  @spec normalize(term()) :: t()
  def normalize(%{} = attempts) do
    %{
      red: count(Map.get(attempts, :red)),
      conflict: count(Map.get(attempts, :conflict)),
      reruns: reruns(Map.get(attempts, :reruns)),
      fix_failures: failures(Map.get(attempts, :fix_failures)),
      fix_ticket: string(Map.get(attempts, :fix_ticket)),
      blocked: blocked(Map.get(attempts, :blocked)),
      updated_from: string(Map.get(attempts, :updated_from)),
      trusted_head: string(Map.get(attempts, :trusted_head)),
      head_origin: if(Map.get(attempts, :head_origin) == :person, do: :person, else: :symphony)
    }
  end

  def normalize(_attempts), do: new()

  @doc "The facts these attempts fill, as `SymphonyElixir.PrWatch.Fetch.facts/2` takes them from the ticket."
  @spec fact_keys() :: [atom()]
  def fact_keys, do: [:red_attempts, :conflict_attempts, :rerun_done, :fix_failures, :landing_timed_out, :head_origin]

  @doc """
  The attempts after this tick's `read` of the PR (nil when the ticket has none), before deciding.
  `ticket` gives the phase, hold and run, whether this tick begins a new stay in the phase
  (`new_stay`), and the heads the ticket's runs left (`run_heads`). A fix ticket whose hold cleared
  restarts the red count; a green, conflict-free PR resets both counts; the merge-wait clock runs
  while a `Merging` head is blocked by branch protection on green checks; a `Merging` head
  Symphony didn't put there is a person's. Only the current head's rerun is kept.
  """
  @spec observe(t(), map() | nil, map(), DateTime.t()) :: t()
  def observe(attempts, read, ticket, %DateTime{} = now) do
    attempts
    |> normalize()
    |> restart_after_fix_ticket(ticket)
    |> reset_when_settled(read)
    |> clock(read, ticket, now)
    |> keep_head_reruns(read)
    |> head_origin(read, ticket)
  end

  # Outside `Merging`, or with no head read, every head is Symphony's. A run's head, the stay's
  # first head and the head an update-branch made are trusted; another one is a person's push.
  defp head_origin(attempts, %{head_sha: head}, %{phase: :merging} = ticket) when is_binary(head) do
    cond do
      Map.get(ticket, :new_stay, false) or is_nil(attempts.trusted_head) -> trust(attempts, head)
      head == attempts.trusted_head -> %{attempts | head_origin: :symphony}
      Map.get(ticket, :run) == :active or head in Map.get(ticket, :run_heads, []) -> trust(attempts, head)
      attempts.updated_from == attempts.trusted_head -> trust(attempts, head)
      true -> %{attempts | head_origin: :person}
    end
  end

  defp head_origin(attempts, _read, _ticket), do: %{attempts | trusted_head: nil, head_origin: :symphony}

  defp trust(attempts, head), do: %{attempts | trusted_head: head, head_origin: :symphony}

  defp restart_after_fix_ticket(%{fix_ticket: identifier} = attempts, %{hold: hold}) when is_binary(identifier) and hold != :blocked,
    do: restart_red(attempts)

  defp restart_after_fix_ticket(attempts, _ticket), do: attempts

  defp reset_when_settled(attempts, %{pr: :open, ci: ci, mergeable: mergeable}) when ci in @green and mergeable in @conflict_free,
    do: %{attempts | red: 0, conflict: 0, fix_failures: []}

  defp reset_when_settled(attempts, _read), do: attempts

  defp clock(attempts, %{mergeable: :blocked, ci: ci, head_sha: head}, %{phase: :merging}, now) when ci in @green do
    case attempts.blocked do
      %{head_sha: ^head} -> attempts
      _other -> %{attempts | blocked: %{head_sha: head, since: now}}
    end
  end

  defp clock(attempts, _read, _ticket, _now), do: %{attempts | blocked: nil}

  defp keep_head_reruns(attempts, %{head_sha: head}) when is_binary(head), do: %{attempts | reruns: Map.take(attempts.reruns, [head])}
  defp keep_head_reruns(attempts, _read), do: %{attempts | reruns: %{}}

  @doc """
  The facts for `decide/1`: the counts, whether the head's failed checks were rerun already (always,
  with `flaky_retry` off), the fix runs' failures, and whether the merge wait (`timeout_ms`) passed.
  """
  @spec facts(t(), map() | nil, %{flaky_retry: boolean(), merging_wait_timeout_ms: pos_integer()}, DateTime.t()) :: map()
  def facts(attempts, read, settings, %DateTime{} = now) do
    attempts = normalize(attempts)

    %{
      red_attempts: attempts.red,
      conflict_attempts: attempts.conflict,
      rerun_done: not settings.flaky_retry or rerun_done?(attempts, read),
      fix_failures: attempts.fix_failures,
      landing_timed_out: timed_out?(attempts.blocked, now, settings.merging_wait_timeout_ms),
      head_origin: attempts.head_origin
    }
  end

  defp rerun_done?(attempts, %{head_sha: head}) when is_binary(head), do: Map.has_key?(attempts.reruns, head)
  defp rerun_done?(_attempts, _read), do: false

  defp timed_out?(%{since: since}, now, timeout_ms), do: DateTime.diff(now, since, :millisecond) >= timeout_ms
  defp timed_out?(nil, _now, _timeout_ms), do: false

  @doc """
  Whether a rerun of the head's failed checks has not reported yet: GitHub drops the rerun checks
  from the rollup until its new attempt queues them, so the head would read green on the checks
  that passed. True while a check the rerun named is missing from the read.
  """
  @spec rerun_pending?(t(), map() | nil) :: boolean()
  def rerun_pending?(attempts, %{head_sha: head, check_names: names}) when is_binary(head) and is_list(names) do
    case Map.get(normalize(attempts).reruns, head) do
      [_ | _] = rerun -> Enum.any?(rerun, &(&1 not in names))
      _none -> false
    end
  end

  def rerun_pending?(_attempts, _read), do: false

  @doc "Records that the failed `checks` of `head` were rerun."
  @spec rerun(t(), String.t() | nil, [String.t()]) :: t()
  def rerun(attempts, head, checks) when is_binary(head), do: %{normalize(attempts) | reruns: %{head => Enum.filter(checks, &is_binary/1)}}
  def rerun(attempts, _head, _checks), do: normalize(attempts)

  @doc """
  Spends one CI Fix run of `kind`. A red run records its failure (the failing check and the first
  line of its error) as the fix ticket's evidence.
  """
  @spec spend(t(), :red | :conflict, Facts.failure() | nil) :: t()
  def spend(attempts, kind, failure \\ nil)

  def spend(attempts, :red, failure) do
    attempts = normalize(attempts)
    %{attempts | red: attempts.red + 1, fix_failures: attempts.fix_failures ++ List.wrap(failure)}
  end

  def spend(attempts, :conflict, _failure) do
    attempts = normalize(attempts)
    %{attempts | conflict: attempts.conflict + 1}
  end

  @doc "Records the fix ticket the red backstop waits on; its hold clearing restarts the red count."
  @spec filed(t(), String.t() | nil) :: t()
  def filed(attempts, identifier), do: %{normalize(attempts) | fix_ticket: string(identifier)}

  @doc "Restarts the red count and forgets the fix ticket: the head gets CI Fix runs again."
  @spec restart_red(t()) :: t()
  def restart_red(attempts), do: %{normalize(attempts) | red: 0, fix_failures: [], fix_ticket: nil}

  @doc "Records the head an update-branch moved past, or clears it (nil)."
  @spec updated_from(t(), String.t() | nil) :: t()
  def updated_from(attempts, head), do: %{normalize(attempts) | updated_from: string(head)}

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp reruns(%{} = reruns) do
    for {head, checks} <- reruns, is_binary(head), is_list(checks), into: %{}, do: {head, Enum.filter(checks, &is_binary/1)}
  end

  defp reruns(_reruns), do: %{}

  defp failures(failures) when is_list(failures) do
    for %{check: check} = failure <- failures, is_binary(check), do: %{check: check, error: string(Map.get(failure, :error)) || ""}
  end

  defp failures(_failures), do: []

  defp blocked(%{since: %DateTime{} = since} = blocked), do: %{head_sha: string(Map.get(blocked, :head_sha)), since: since}
  defp blocked(_blocked), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
