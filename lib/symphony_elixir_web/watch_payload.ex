defmodule SymphonyElixirWeb.WatchPayload do
  @moduledoc """
  The PR and CI watcher's record of a ticket as the API serves it (`docs/pr-ci-decisions.md`): the
  `watch` block of `GET /api/v1/state`'s `issues`, of `GET /api/v1/:issue_identifier` and of Check
  Now, an entry of `silent_waits`, GitHub's `rate_limit`, and `app_update`: the tickets an app update
  would unblock and the app repository's newest release.

  The `watch` and `app_update` blocks' shapes are contracts with the app:
  `test/fixtures/api/watch_block.json` and `test/fixtures/api/app_update_block.json` are examples of
  them, which the API's tests compare against and the app's decoding tests read.
  """

  alias SymphonyElixir.PrDecision.Action
  alias SymphonyElixir.PrWatch
  alias SymphonyElixir.TicketState

  @pr_words %{missing: "no PR", open: "open", draft: "a draft", closed: "closed", merged: "merged"}
  @ci_words %{pending: "CI running", green: "CI green", none: "no CI", red: "CI red", required_missing: "a required check missing"}
  @mergeable_words %{
    clean: "no conflict",
    behind: "behind the base",
    dirty: "conflicts with the base",
    unstable: "unstable",
    blocked: "blocked by branch protection",
    unknown: "mergeability unknown"
  }
  @hold_words %{needs_decision: "Needs Decision hold", blocked: "Blocked hold"}

  @doc """
  The `watch` block of a ticket state record: the phase, the PR head the facts were read on and how
  they arrived (`source`), the decision (`rule`, `action`, `reason`, who acts next (`owner`) and
  what clears it (`clears_when`), since when it stands, its `outcome`), the facts in one line
  (`summary`) and in full (`facts`, with `protected_files`: the protected paths the PR changes when
  only a check a person clears is red on its head, R18), the last five actions applied with how
  their facts arrived, the ticket's silence, and what it waits on
  (`waits_on`: the competing PRs of its landing hold, and the fix ticket of the red backstop, D15).
  `decision`, `applied` and `links` are the record's own. Nil when the watcher doesn't watch the
  ticket.
  """
  @spec watch(TicketState.t() | nil) :: map() | nil
  def watch(%{pr_watch: %{} = watch}) do
    decision = watch.decision || %{}
    {owner, clears_when} = next_step(decision)

    %{
      phase: name(watch.stay || watch.facts.phase),
      head: watch.head_sha,
      pr_url: watch.pr_url,
      source: name(watch.source),
      read_at: iso8601(watch.read_at),
      rule: decision[:rule],
      action: name(decision[:kind]),
      reason: decision[:reason],
      owner: name(owner),
      clears_when: clears_when,
      since: iso8601(decision[:since]),
      outcome: name(decision[:outcome]),
      summary: summary(watch),
      facts: facts(watch),
      actions: Enum.map(watch.actions, &action/1),
      silent: silent(watch.silent),
      decision: watch.decision,
      applied: watch.applied,
      links: watch.links,
      waits_on: waits_on(watch)
    }
  end

  def watch(_record), do: nil

  @doc "An entry of `silent_waits` (`SymphonyElixir.PrWatch.silent_waits/1`)."
  @spec silent_wait(map()) :: map()
  def silent_wait(entry) do
    %{
      issue_id: entry.issue_id,
      identifier: entry.issue_identifier,
      repo_key: entry.repo_key,
      phase: name(entry.phase),
      pr_url: entry.pr_url,
      since: iso8601(entry.since),
      rule: entry.rule,
      bound: entry.bound,
      reason: entry.reason
    }
  end

  @doc "GitHub's rate limit as the watcher last read it (`SymphonyElixir.PrWatch.rate_limit/1`): remaining, limit and reset."
  @spec rate_limit(map() | nil) :: map() | nil
  def rate_limit(%{} = rate_limit), do: %{remaining: rate_limit.remaining, limit: Map.get(rate_limit, :limit), reset: iso8601(rate_limit.reset_at)}
  def rate_limit(nil), do: nil

  @doc """
  The `app_update` block of `GET /api/v1/state`: the tickets held only for an app update (the
  `:app_update` entries of the snapshot's `blocked`: the Todo tickets whose pause holds a `:build`
  reason of `SymphonyElixir.UpdateHold`), and `latest_release`, the newest published
  release of the repository the app updates from (`SymphonyElixir.PrWatch.Release`), nil until
  Symphony knows one. The app checks for an update at once when it is newer than the build it runs.
  """
  @spec app_update([map()], SymphonyElixir.PrWatch.Release.t() | nil) :: map()
  def app_update(blocked, release) do
    identifiers = for %{kind: :app_update, identifier: identifier} <- blocked, do: identifier
    %{unblocks: length(identifiers), issue_identifiers: identifiers, latest_release: latest_release(release)}
  end

  defp latest_release(%{} = release),
    do: %{repo: release.repo, tag: release.tag, published_at: iso8601(release.published_at), source: release.source}

  defp latest_release(nil), do: nil

  # Who acts next and what clears it: a wait's own, or for an action Symphony carries out (such as
  # `dispatch`), Symphony until the action is done.
  defp next_step(%{owner: owner} = decision) when not is_nil(owner), do: {owner, decision[:clears_when]}
  defp next_step(decision), do: Action.next_step(decision[:kind]) || {nil, decision[:clears_when]}

  defp waits_on(watch) do
    fix_tickets =
      case watch.decision do
        %{waits_on: %{type: "fix_ticket", keys: keys}} -> Enum.map(keys, &%{identifier: &1, kind: "fix_ticket"})
        _other -> []
      end

    PrWatch.competitor_waits(watch) ++ fix_tickets
  end

  # The facts in one line, as a person reads them.
  defp summary(%{facts: facts} = watch) do
    read? = facts.pr in [:open, :draft]

    [
      if(facts.pr_number && facts.pr != :missing, do: "PR ##{facts.pr_number} #{@pr_words[facts.pr]}", else: @pr_words[facts.pr]),
      if(read?, do: @ci_words[facts.ci]),
      if(read?, do: @mergeable_words[facts.mergeable]),
      if(facts.auto_merge == :armed, do: "auto-merge on"),
      if(facts.run == :active, do: "run active"),
      @hold_words[facts.hold],
      if(match?({:rate_limited, _reset_at}, watch.github), do: "GitHub rate limited")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp facts(watch) do
    {github, reset_at} =
      case watch.github do
        {:rate_limited, reset_at} -> {"rate_limited", iso8601(reset_at)}
        :ok -> {"ok", nil}
      end

    watch.facts
    |> Map.from_struct()
    |> Map.merge(%{
      pr_url: watch.pr_url,
      head_sha: watch.head_sha,
      source: watch.source,
      read_at: iso8601(watch.read_at),
      github: github,
      github_reset_at: reset_at,
      rate_limit: facts_rate_limit(watch.rate_limit),
      protected_files: protected_files(watch)
    })
  end

  # R18's evidence: the protected paths the PR changes, read on the record's head; none otherwise.
  defp protected_files(%{protected_files: %{head_sha: head, paths: paths}, head_sha: head}), do: paths
  defp protected_files(_watch), do: []

  defp facts_rate_limit(%{} = rate_limit), do: %{remaining: rate_limit.remaining, reset_at: iso8601(rate_limit.reset_at)}
  defp facts_rate_limit(nil), do: nil

  defp action(action) do
    %{
      rule: action[:rule],
      action: name(action[:kind]),
      head: action[:head_sha],
      at: iso8601(action[:at]),
      source: name(action[:source])
    }
  end

  defp silent(%{} = silent), do: %{since: iso8601(silent.since), ticks: silent.ticks, bound: silent.bound, reason: silent.reason}
  defp silent(nil), do: nil

  defp name(nil), do: nil
  defp name(value) when is_atom(value), do: Atom.to_string(value)

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_datetime), do: nil
end
