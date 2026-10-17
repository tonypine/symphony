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
  blocked by branch protection on green checks (`landing_timed_out`); the head and cause the last
  CI Fix run was sent for, so a ticket that entered CI Fix doesn't spend a second attempt on the
  run already sent (`sent?/3`); the head an update-branch
  moved past, whose runs are cancelled once the head moves on; and the last head Symphony knows it
  put there in a `Merging` stay (`trusted_head`): the head the stay began on, one a run left, or
  the one an update-branch made. Any other head in `Merging` is a person's push (`head_origin`).

  Since GitHub shows Symphony's pushes and a person's under the same account, the head's author
  can't tell them apart; where the head came from can.

  Two more things, for the CI cases a plain read can't settle (D3, D15 (c)):

    * **A check that never reports** (`unreported`): since when the head has waited on a check the
      base branch requires, or on its first check at all while the base has workflows. Until
      `merging_wait_timeout_ms` passes (`pull_requests.checks.landing_wait_timeout_ms`), the head
      reads as running (`settle/4`); past it, a required check reads `required_missing` (R17 asks a
      person) and a head with no check at all reads as having none. The person's answer is kept on
      the head: `proceed` waives the missing checks for that head only, `rework` asks nothing more
      on it, a rerun restarts the wait.
    * **The same failure again** (`streak`): each red CI Fix run's failure, from the last green head
      on. The current head's failure (`failure`: the failed check and the first line of its error,
      read once per head) counts the runs before it, on earlier heads, that failed the same way
      (`same_failure_streak`): 3 in a row reaches the red backstop. The signature is the self-heal
      lane's own (`signature/1`), so the lane compares like with like after a fix lands.

  Everything here is pure: the caller passes the read and the clock.
  """

  alias SymphonyElixir.PrDecision.Facts

  @typedoc "The `pull_requests.checks` settings the facts read."
  @type ci_settings :: %{flaky_retry: boolean(), merging_wait_timeout_ms: pos_integer()}

  @typedoc "Since when the head has been blocked by branch protection on green checks."
  @type blocked :: %{head_sha: String.t() | nil, since: DateTime.t()}

  @typedoc """
  Since when the head has waited on a check that never reported, the question R17 asked about it
  (its title, and how many decisions with that title the ticket held before), and the answer.
  """
  @type unreported :: %{
          head_sha: String.t() | nil,
          since: DateTime.t(),
          asked: %{title: String.t(), prior: non_neg_integer()} | nil,
          answer: :proceed | :rework | nil
        }

  @type t :: %{
          red: non_neg_integer(),
          conflict: non_neg_integer(),
          reruns: %{optional(String.t()) => [String.t()]},
          fix_failures: [Facts.failure()],
          streak: [Facts.failure()],
          failure: Facts.failure() | nil,
          unreported: unreported() | nil,
          fix_ticket: String.t() | nil,
          blocked: blocked() | nil,
          updated_from: String.t() | nil,
          trusted_head: String.t() | nil,
          head_origin: :symphony | :person,
          sent: %{head_sha: String.t() | nil, cause: :red | :conflict} | nil
        }

  @conflict_free [:clean, :behind, :unstable, :blocked]
  @green [:green, :none]

  @doc "No attempts spent."
  @spec new() :: t()
  def new do
    %{
      red: 0,
      conflict: 0,
      reruns: %{},
      fix_failures: [],
      streak: [],
      failure: nil,
      unreported: nil,
      fix_ticket: nil,
      blocked: nil,
      updated_from: nil,
      trusted_head: nil,
      head_origin: :symphony,
      sent: nil
    }
  end

  @doc "The attempts a record kept, with defaults for what it lacks; anything else is `new/0`."
  @spec normalize(term()) :: t()
  def normalize(%{} = attempts) do
    %{
      red: count(Map.get(attempts, :red)),
      conflict: count(Map.get(attempts, :conflict)),
      reruns: reruns(Map.get(attempts, :reruns)),
      fix_failures: failures(Map.get(attempts, :fix_failures)),
      streak: failures(Map.get(attempts, :streak)),
      failure: attempts |> Map.get(:failure) |> List.wrap() |> failures() |> List.first(),
      unreported: unreported(Map.get(attempts, :unreported)),
      fix_ticket: string(Map.get(attempts, :fix_ticket)),
      blocked: blocked(Map.get(attempts, :blocked)),
      updated_from: string(Map.get(attempts, :updated_from)),
      trusted_head: string(Map.get(attempts, :trusted_head)),
      head_origin: if(Map.get(attempts, :head_origin) == :person, do: :person, else: :symphony),
      sent: sent(Map.get(attempts, :sent))
    }
  end

  def normalize(_attempts), do: new()

  @doc "The facts these attempts fill, as `SymphonyElixir.PrWatch.Fetch.facts/2` takes them from the ticket."
  @spec fact_keys() :: [atom()]
  def fact_keys, do: [:red_attempts, :conflict_attempts, :rerun_done, :same_failure_streak, :fix_failures, :landing_timed_out, :head_origin]

  @doc """
  The attempts after this tick's `read` of the PR (nil when the ticket has none), before deciding.
  `ticket` gives the phase, hold and run, whether this tick begins a new stay in the phase
  (`new_stay`), and the heads the ticket's runs left (`run_heads`). A fix ticket whose hold cleared
  restarts the red count; a green, conflict-free PR resets both counts; a green head breaks the
  same-failure streak; the merge-wait clock runs while a `Merging` head is blocked by branch
  protection on green checks, and the unreported-check clock while the head waits on a check that
  never reported (`read.ci` `required_missing`, or `awaiting_checks`); a `Merging` head Symphony
  didn't put there is a person's. Only the current head's rerun and failure (`read.failure`) are
  kept.
  """
  @spec observe(t(), map() | nil, map(), DateTime.t()) :: t()
  def observe(attempts, read, ticket, %DateTime{} = now) do
    attempts
    |> normalize()
    |> restart_after_fix_ticket(ticket)
    |> reset_when_settled(read)
    |> clock(read, ticket, now)
    |> unreported_clock(read, now)
    |> break_streak(read)
    |> keep_head_failure(read)
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
    do: %{attempts | red: 0, conflict: 0, fix_failures: [], streak: []}

  defp reset_when_settled(attempts, _read), do: attempts

  defp clock(attempts, %{mergeable: :blocked, ci: ci, head_sha: head}, %{phase: :merging}, now) when ci in @green do
    case attempts.blocked do
      %{head_sha: ^head} -> attempts
      _other -> %{attempts | blocked: %{head_sha: head, since: now}}
    end
  end

  defp clock(attempts, _read, _ticket, _now), do: %{attempts | blocked: nil}

  defp unreported_clock(attempts, %{head_sha: head} = read, now) do
    if Map.get(read, :ci) == :required_missing or Map.get(read, :awaiting_checks) == true do
      case attempts.unreported do
        %{head_sha: ^head} -> attempts
        _other -> %{attempts | unreported: %{head_sha: head, since: now, asked: nil, answer: nil}}
      end
    else
      %{attempts | unreported: nil}
    end
  end

  defp unreported_clock(attempts, _read, _now), do: %{attempts | unreported: nil}

  defp break_streak(attempts, %{ci: ci}) when ci in @green, do: %{attempts | streak: []}
  defp break_streak(attempts, _read), do: attempts

  # The read's failure when it has one (`SymphonyElixir.PrWatch.Fetch.failure/3`), else the one kept
  # for its head.
  defp keep_head_failure(attempts, %{head_sha: head} = read) when is_binary(head) do
    case Map.get(read, :failure) || attempts.failure do
      %{head_sha: ^head} = failure -> %{attempts | failure: failure}
      _other -> %{attempts | failure: nil}
    end
  end

  defp keep_head_failure(attempts, _read), do: %{attempts | failure: nil}

  defp keep_head_reruns(attempts, %{head_sha: head}) when is_binary(head), do: %{attempts | reruns: Map.take(attempts.reruns, [head])}
  defp keep_head_reruns(attempts, _read), do: %{attempts | reruns: %{}}

  @doc """
  The facts for `decide/1`: the counts, whether the head's failed checks were rerun already (always,
  with `flaky_retry` off), the same-failure streak, the fix runs' failures, and whether the merge
  wait (`timeout_ms`) passed.
  """
  @spec facts(t(), map() | nil, ci_settings(), DateTime.t()) :: map()
  def facts(attempts, read, settings, %DateTime{} = now) do
    attempts = normalize(attempts)

    %{
      red_attempts: attempts.red,
      conflict_attempts: attempts.conflict,
      rerun_done: not settings.flaky_retry or rerun_done?(attempts, read),
      same_failure_streak: same_failure_streak(attempts, read),
      fix_failures: attempts.fix_failures,
      landing_timed_out: timed_out?(attempts.blocked, now, settings.merging_wait_timeout_ms),
      head_origin: attempts.head_origin
    }
  end

  defp rerun_done?(attempts, %{head_sha: head}) when is_binary(head), do: Map.has_key?(attempts.reruns, head)
  defp rerun_done?(_attempts, _read), do: false

  defp timed_out?(%{since: since}, now, timeout_ms), do: DateTime.diff(now, since, :millisecond) >= timeout_ms
  defp timed_out?(nil, _now, _timeout_ms), do: false

  # The fix runs before the current head's failure, on earlier heads, that failed the same way, in a
  # row back from the last one.
  defp same_failure_streak(%{failure: %{head_sha: head} = failure} = attempts, %{head_sha: head}) when is_binary(head) do
    signature = signature(failure)

    attempts.streak
    |> Enum.reject(&(Map.get(&1, :head_sha) == head))
    |> Enum.reverse()
    |> Enum.take_while(&(signature(&1) == signature))
    |> length()
  end

  defp same_failure_streak(_attempts, _read), do: 0

  @doc """
  The read as the facts see it once the unreported-check wait is applied (`timeout_ms`, the
  `merging_wait_timeout_ms` setting): a required check that hasn't reported reads as running until
  the wait passes, unless the person waived it for this head (green) or sent the ticket to Rework
  over it (running: the rework run fixes the workflow); a head with no check at all while the base
  has workflows reads as having no CI (`no_ci: :not_reported`) once the wait passed. Any other read
  is returned as it is.
  """
  @spec settle(map() | nil, t(), pos_integer(), DateTime.t()) :: map() | nil
  def settle(%{ci: :required_missing, head_sha: head} = read, attempts, timeout_ms, %DateTime{} = now) do
    case head_clock(attempts, head) do
      %{answer: :proceed} -> %{read | ci: :green}
      %{answer: nil} = unreported -> if timed_out?(unreported, now, timeout_ms), do: read, else: %{read | ci: :pending}
      # Sent to Rework over it, or no clock on the head yet.
      _rework_or_none -> %{read | ci: :pending}
    end
  end

  def settle(%{awaiting_checks: true, head_sha: head} = read, attempts, timeout_ms, %DateTime{} = now) do
    if timed_out?(head_clock(attempts, head), now, timeout_ms),
      do: Map.merge(read, %{ci: :none, no_ci: :not_reported}),
      else: read
  end

  def settle(read, _attempts, _timeout_ms, _now), do: read

  defp head_clock(attempts, head) do
    case normalize(attempts).unreported do
      %{head_sha: ^head} = unreported -> unreported
      _other -> nil
    end
  end

  @doc """
  Records that R17 asked a person about the check `head` waits on: the question's `title`, and how
  many recorded decisions with that title the ticket held before (`prior`), so only a newer one
  answers it (`answer/3`).
  """
  @spec asked(t(), String.t() | nil, String.t(), non_neg_integer()) :: t()
  def asked(attempts, head, title, prior) do
    attempts = normalize(attempts)

    case head_clock(attempts, head) do
      nil -> attempts
      unreported -> %{attempts | unreported: %{unreported | asked: %{title: title, prior: prior}}}
    end
  end

  @doc """
  The question R17 asked about the current head and not yet answered, or nil: what `answer/3` looks
  for among the ticket's recorded decisions.
  """
  @spec open_question(t()) :: %{title: String.t(), prior: non_neg_integer()} | nil
  def open_question(attempts) do
    case normalize(attempts).unreported do
      %{asked: %{} = asked, answer: nil} -> asked
      _none -> nil
    end
  end

  @doc """
  Records the person's answer to R17 on the current head: `:proceed` waives the missing checks for
  that head, `:rework` asks nothing more on it (the move to Rework is the hold's), and `:rerun` (or
  an answer that picks no option) restarts the wait at `now`, so the question can come again.
  """
  @spec answer(t(), :proceed | :rework | :rerun | :other, DateTime.t()) :: t()
  def answer(attempts, pick, %DateTime{} = now) do
    attempts = normalize(attempts)

    case attempts.unreported do
      nil -> attempts
      unreported when pick in [:proceed, :rework] -> %{attempts | unreported: %{unreported | answer: pick}}
      unreported -> %{attempts | unreported: %{unreported | since: now, asked: nil, answer: nil}}
    end
  end

  @doc """
  The cause the red backstop hands the self-heal lane for `failure` (`SymphonyElixir.PrDecision.Apply`):
  the failed check and the first line of its error.
  """
  @spec cause(Facts.failure()) :: {:ci_check_failed, String.t(), String.t()}
  def cause(%{check: check} = failure), do: {:ci_check_failed, check, Map.get(failure, :error) || ""}

  @doc """
  A failure's signature: `SymphonyElixir.SelfHeal.signature/1` of the outcome the red backstop
  builds from it, so the streak and the self-heal lane read the same failure the same way.
  """
  @spec signature(Facts.failure()) :: String.t()
  def signature(failure), do: SymphonyElixir.SelfHeal.signature(%{cause: cause(failure)})

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

  @doc """
  Records that the failed `checks` of `head` were rerun. The head's failure is read again once the
  rerun failed too: the rerun's log is the one its next fix run reads.
  """
  @spec rerun(t(), String.t() | nil, [String.t()]) :: t()
  def rerun(attempts, head, checks) when is_binary(head), do: %{normalize(attempts) | reruns: %{head => Enum.filter(checks, &is_binary/1)}, failure: nil}
  def rerun(attempts, _head, _checks), do: normalize(attempts)

  @doc """
  Spends one CI Fix run of `kind`. A red run records its failure (the failing check, the first line
  of its error and the head) as the fix ticket's evidence and in the same-failure streak.
  """
  @spec spend(t(), :red | :conflict, Facts.failure() | nil) :: t()
  def spend(attempts, kind, failure \\ nil), do: spent(normalize(attempts), kind, failure)

  defp spent(attempts, :red, failure) do
    %{attempts | red: attempts.red + 1, fix_failures: attempts.fix_failures ++ List.wrap(failure), streak: attempts.streak ++ List.wrap(failure)}
  end

  defp spent(attempts, :conflict, _failure), do: %{attempts | conflict: attempts.conflict + 1}

  @doc """
  Records that a CI Fix run was sent for `cause` on `head`: once the ticket is in CI Fix, the run
  that takes that fix is the one already sent, so it spends no second attempt (`sent?/3`).
  """
  @spec sent(t(), String.t() | nil, :red | :conflict) :: t()
  def sent(attempts, head, cause), do: %{normalize(attempts) | sent: %{head_sha: head, cause: cause}}

  @doc "Whether a CI Fix run was already sent for `cause` on `head`."
  @spec sent?(t(), String.t() | nil, :red | :conflict) :: boolean()
  def sent?(attempts, head, cause), do: normalize(attempts).sent == %{head_sha: head, cause: cause}

  @doc "Records the fix ticket the red backstop waits on; its hold clearing restarts the red count."
  @spec filed(t(), String.t() | nil) :: t()
  def filed(attempts, identifier), do: %{normalize(attempts) | fix_ticket: string(identifier)}

  @doc "Restarts the red count and forgets the fix ticket: the head gets CI Fix runs again."
  @spec restart_red(t()) :: t()
  def restart_red(attempts), do: %{normalize(attempts) | red: 0, fix_failures: [], streak: [], fix_ticket: nil}

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
    for %{check: check} = failure <- failures, is_binary(check) do
      %{check: check, error: string(Map.get(failure, :error)) || "", head_sha: string(Map.get(failure, :head_sha))}
    end
  end

  defp failures(_failures), do: []

  defp sent(%{cause: cause} = sent) when cause in [:red, :conflict], do: %{head_sha: string(Map.get(sent, :head_sha)), cause: cause}
  defp sent(_sent), do: nil

  defp unreported(%{since: %DateTime{} = since} = unreported) do
    %{
      head_sha: string(Map.get(unreported, :head_sha)),
      since: since,
      asked: asked(Map.get(unreported, :asked)),
      answer: if(Map.get(unreported, :answer) in [:proceed, :rework], do: Map.get(unreported, :answer))
    }
  end

  defp unreported(_unreported), do: nil

  defp asked(%{title: title} = asked) when is_binary(title), do: %{title: title, prior: count(Map.get(asked, :prior))}
  defp asked(_asked), do: nil

  defp blocked(%{since: %DateTime{} = since} = blocked), do: %{head_sha: string(Map.get(blocked, :head_sha)), since: since}
  defp blocked(_blocked), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
