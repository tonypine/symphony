defmodule SymphonyElixir.PrWatch.SilentWait do
  @moduledoc """
  The silent-wait detector of the PR and CI watcher: whether a watched ticket waits with nothing
  under way and no reason anybody can act on. It reads the watcher's record of the ticket
  (`TicketState.pr_watch`), never GitHub, and runs on each tick (`SymphonyElixir.PrWatch.Repo`).

  A ticket with an active run or a hold is never silent, nor one the watcher acted on in this tick
  (it moved the ticket, reran a check or called GitHub). Nor is one whose decision, made within the
  last two ticks, leaves it waiting on someone (`owner`) until something happens (`clears_when`),
  unless the wait outlived its bound: CI still running past `ci.merging_wait_timeout_ms`, or
  GitHub's rate limit still holding one tick past its reset. A ticket whose upkeep GitHub refused
  on its head on the last read (`upkeep_failure`: U1's update-branch, U2's rerun of a cancelled
  run) is quiet whatever it waits on: only the next read retries the upkeep, and no wait ends while
  it fails. So is one whose R28 waits on the update U1 already made on its head on an earlier read
  (GitHub took it, or found a conflict, but the head never moved): U1 never repeats on that head.
  Any other ticket is quiet, and one quiet for two poll cycles in a row is silent: it is listed in
  `silent_waits` and logged once. Quiet ticks count poll intervals, not polls, so an extra
  tick (`poll_now`, Check Now) inside an interval adds none.
  """

  alias SymphonyElixir.PrDecision.Action

  @silent_ticks 2

  @typedoc """
  A ticket's silence as the record keeps it: since when it is quiet (or since when its wait ran
  past its bound), how many ticks in a row it was (for a quiet ticket, the poll intervals it
  spans), the bound that passed (`nil` when quiet) and why.
  """
  @type t :: %{since: DateTime.t(), ticks: pos_integer(), bound: String.t() | nil, reason: String.t()}

  @typedoc """
  What the detector reads besides the record: whether a run is active, the ticket's hold, the
  tick's time, the tick interval, the CI wait bound, and the silence the record held.
  """
  @type context :: %{
          run: :active | :none,
          hold: :none | :question | :blocked,
          now: DateTime.t(),
          interval_ms: pos_integer(),
          ci_wait_ms: pos_integer(),
          previous: t() | nil
        }

  @doc "The ticket's silence after this tick, or nil when it is not quiet."
  @spec check(map() | nil, context()) :: t() | nil
  def check(_watch, %{run: :active}), do: nil
  def check(_watch, %{hold: hold}) when hold != :none, do: nil

  def check(watch, ctx) do
    decision = watch && watch.decision

    cond do
      not fresh?(decision, ctx) -> quiet(quiet_reason(decision), ctx)
      applied_now?(decision, ctx) -> nil
      failure = upkeep_failure(watch) -> quiet(failure, ctx)
      stalled_update?(watch, decision, ctx) -> quiet("U1 updated the branch on the head on an earlier read, but the head has not moved", ctx)
      waiting?(decision) -> bound(watch, decision, ctx)
      true -> quiet("#{decision.rule} decided `#{decision.kind}`, but no run started and no wait is recorded", ctx)
    end
  end

  @doc "Whether `silence` is long enough to list: two quiet poll cycles in a row, or a wait past its bound."
  @spec listed?(t() | nil) :: boolean()
  def listed?(%{bound: bound}) when is_binary(bound), do: true
  def listed?(%{ticks: ticks}) when is_integer(ticks), do: ticks >= @silent_ticks
  def listed?(_silence), do: false

  # A decision is the ticket's reason only while the watcher keeps making it.
  defp fresh?(%{decided_at: %DateTime{} = at}, ctx), do: DateTime.diff(ctx.now, at, :millisecond) < @silent_ticks * ctx.interval_ms
  defp fresh?(_decision, _ctx), do: false

  # The watcher acted on this tick (a move, a rerun, a GitHub call): the ticket is moving, not waiting.
  defp applied_now?(%{outcome: :applied, decided_at: at}, ctx), do: DateTime.compare(at, ctx.now) == :eq
  defp applied_now?(_decision, _ctx), do: false

  # The upkeep GitHub refused on the record's head, which nothing but the next read retries.
  defp upkeep_failure(%{upkeep_failure: %{head_sha: head} = failure, head_sha: head}),
    do: "#{failure.rule} `#{failure.kind}` failed on the head (#{failure.error}), and only the next read retries it"

  defp upkeep_failure(_watch), do: nil

  # R28 with no PR ahead waits on the update U1 made on the record's head before this tick; the
  # update made on this tick is the watcher acting.
  defp stalled_update?(%{head_sha: head, applied: applied}, %{rule: "R28"} = decision, ctx) do
    not match?(%{args: %{prs: [_ | _]}}, decision) and Enum.any?(applied, &earlier_update?(&1, head, ctx.now))
  end

  defp stalled_update?(_watch, _decision, _ctx), do: false

  defp earlier_update?(%{rule: "U1", head_sha: head, at: %DateTime{} = at}, head, now), do: DateTime.compare(at, now) == :lt
  defp earlier_update?(_entry, _head, _now), do: false

  defp waiting?(%{owner: owner, clears_when: clears_when}), do: owner in Action.owners() and is_binary(clears_when) and clears_when != ""
  defp waiting?(_decision), do: false

  defp quiet_reason(nil), do: "the watcher has no decision on it"
  defp quiet_reason(decision), do: "the watcher's last decision (#{decision.rule}) is older than two ticks"

  # A ticket still quiet keeps counting from the tick it went quiet, one tick per poll interval
  # passed, so extra polls inside an interval add none. A wait past its bound is no quiet streak:
  # its `since` is the bound's start, so a ticket quiet after it starts counting afresh.
  defp quiet(reason, %{previous: %{since: since, bound: nil}} = ctx) do
    %{since: since, ticks: 1 + div(DateTime.diff(ctx.now, since, :millisecond), ctx.interval_ms), bound: nil, reason: reason}
  end

  defp quiet(reason, ctx), do: %{since: ctx.now, ticks: 1, bound: nil, reason: reason}

  # A wait on CI or on GitHub's rate limit has a bound; past it, the wait is silent too.
  defp bound(_watch, %{owner: :ci} = decision, ctx) do
    since = decision[:since] || decision.decided_at

    if DateTime.diff(ctx.now, since, :millisecond) > ctx.ci_wait_ms do
      minutes = div(ctx.ci_wait_ms, 60_000)
      past(since, "ci.merging_wait_timeout_ms", "#{decision.rule}: CI has been running for more than #{minutes} min", ctx)
    end
  end

  defp bound(%{github: {:rate_limited, %DateTime{} = reset_at}}, %{owner: :github} = decision, ctx) do
    if DateTime.diff(ctx.now, reset_at, :millisecond) > ctx.interval_ms do
      past(reset_at, "rate_limit_reset", "#{decision.rule}: GitHub's rate limit was due to reset at #{reset_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()}", ctx)
    end
  end

  defp bound(_watch, _decision, _ctx), do: nil

  defp past(since, bound, reason, %{previous: %{bound: bound, ticks: ticks}}), do: %{since: since, ticks: ticks + 1, bound: bound, reason: reason}
  defp past(since, bound, reason, _ctx), do: %{since: since, ticks: 1, bound: bound, reason: reason}
end
