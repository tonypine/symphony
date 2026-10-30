defmodule SymphonyElixir.PrWatch.Competitors do
  @moduledoc """
  A conflicting pull request that waits on the open pull requests changing the same files (rules
  R14a and R15, the action `wait_for_competitors`) waits as a visible dependency, not in Symphony's
  memory: a `Blocked` hold of the landing kind on its ticket (`SymphonyElixir.BlockedHold`), and a
  Linear blocked-by link from each competitor's ticket.

    * `competing/3` is the fact `competing`: every open pull request of the repository that shares
      a file with the ticket's, with its ticket when Symphony watches it. It leaves out a pull
      request out of the race (on a hold, or idle two hours by `SymphonyElixir.LandingOrder`'s
      rule), one whose link would close a cycle (`closes_cycle?/3`), and one a person released the
      ticket from (`Unblock`). A forced ticket never waits, so it has none.
    * `wait/4` applies the wait: the hold, then a link from each competitor's ticket that Linear
      doesn't have yet. A competitor with no ticket (a person's pull request) gets no link; the
      hold names it by number and title. The links Symphony added are recorded on the ticket's
      watch record (`links`), so it only ever removes its own.
    * `settle/5` judges the wait on each read of the watcher. A competitor that landed (its ticket
      terminal, its pull request merged) stays linked, as history. One that left the race (its pull
      request closed, on a hold, idle two hours, or no longer sharing a file) is unlinked when
      Symphony added the link. The hold clears once no competitor is left; a wait that stepped
      behind its competitors (R15) then restarts the conflict count.
    * `release/3` is a person's `Unblock`: Symphony's links are removed and the ticket no longer
      waits on those pull requests while they stay open. `leave/3` ends the wait of a ticket the
      watcher stops watching.

  Beside the hold, the ticket's pause (`SymphonyElixir.Pauses`, the one writer) has one reason per
  competitor it waits on (`SymphonyElixir.BlockedHold.landing_reasons/1`): "Waiting for TP-1 to land:
  it changes the same files". `wait/4` sets them; `settle/5` lines them up with the competitors
  still racing, so a competitor that lands or leaves loses its reason and the last goes with the
  hold; `release/3` and `leave/3` clear every one, and no other reason. Each write is best-effort and
  made after the hold's: the next read makes it again.

  The fields of a link record: the competitor's `issue_id`, `issue_identifier`, `pr_number`,
  `pr_url`, `title` and shared `files`; its `head_sha` and `progress_at` (since when it hasn't
  moved, for a pull request the landing order doesn't rank); `linked` (Symphony added the Linear
  link), `step_behind` (R15) and `released` (a person's `Unblock`).
  """

  require Logger

  alias SymphonyElixir.{BlockedHold, Hold, LandingOrder, Pauses, RunStore, TicketState, Tracker}
  alias SymphonyElixir.Linear.Issue

  @listed_files 10
  @director %{kind: :person, name: "Director"}

  @typedoc "A competitor a wait recorded (see the moduledoc)."
  @type link :: %{
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          pr_number: pos_integer() | nil,
          pr_url: String.t() | nil,
          title: String.t() | nil,
          files: [String.t()],
          head_sha: String.t() | nil,
          progress_at: DateTime.t() | nil,
          linked: boolean(),
          step_behind: boolean(),
          released: boolean()
        }

  @typedoc """
  The ticket a fact is computed for: its issue id, its pull request's number and files, whether it
  is forced, and the competitors it recorded.
  """
  @type own :: %{
          issue_id: String.t(),
          pr_number: pos_integer() | nil,
          files: [String.t()],
          forced: boolean(),
          links: [link()]
        }

  @typedoc """
  What one read of the watcher knows of the race: the open pull requests by number, the watched
  ones the landing order ranks by number, each watched ticket's blockers by issue id, the issue ids
  whose pull request was read merged, the ticket's own files (nil when unknown), and the clock.
  """
  @type race :: %{
          required(:pulls) => %{optional(pos_integer()) => map()},
          required(:members) => %{optional(pos_integer()) => LandingOrder.member()},
          required(:blockers) => %{optional(String.t()) => [String.t()]},
          required(:now) => DateTime.t(),
          optional(:merged) => MapSet.t(String.t()),
          optional(:files) => [String.t()] | nil
        }

  @typedoc "What `settle/5` left: the landing hold (nil once cleared), the links to keep, and whether the conflict count restarts."
  @type settled :: %{hold: map() | nil, links: [link()], restart_conflicts: boolean()}

  @doc "The fact `competing` for `own` (see the moduledoc), ordered by pull request number."
  @spec competing(own(), [map()], race()) :: [map()]
  def competing(%{forced: true}, _pulls, _race), do: []

  def competing(own, pulls, race) do
    pulls
    |> Enum.filter(&(is_integer(&1.number) and &1.number != own.pr_number))
    |> Enum.flat_map(fn pull ->
      member = Map.get(race.members, pull.number)

      with [_ | _] = shared <- LandingOrder.shared_files(own.files, pull.files || []),
           true <- member == nil or LandingOrder.leads?(member, race.now),
           competitor = competitor(pull, member, shared),
           false <- excluded?(competitor, own, race.blockers) do
        [competitor]
      else
        _out -> []
      end
    end)
    |> Enum.sort_by(& &1.pr_number)
  end

  @doc """
  Whether `own` must not wait on `competitor`: a person released it from that one (`Unblock`), or
  the link would close a cycle.
  """
  @spec excluded?(map(), own() | map(), %{optional(String.t()) => [String.t()]}) :: boolean()
  def excluded?(competitor, own, blockers) do
    Enum.any?(Map.get(own, :links, []), &(&1.released and same?(&1, competitor))) or
      closes_cycle?(blockers, Map.get(competitor, :issue_id), own.issue_id)
  end

  @doc """
  Whether a link making `competitor_id` block `own_id` closes a cycle: the competitor is already,
  directly or through others, blocked by the ticket. `blockers` maps an issue id to its blockers'
  ids, as far as the watcher knows them.
  """
  @spec closes_cycle?(%{optional(String.t()) => [String.t()]}, String.t() | nil, String.t()) :: boolean()
  def closes_cycle?(blockers, competitor_id, own_id) when is_binary(competitor_id) do
    reaches?(blockers, Map.get(blockers, competitor_id, []), own_id, MapSet.new([competitor_id]))
  end

  def closes_cycle?(_blockers, _competitor_id, _own_id), do: false

  defp reaches?(_blockers, [], _own_id, _seen), do: false

  defp reaches?(blockers, [id | rest], own_id, seen) do
    cond do
      id == own_id -> true
      MapSet.member?(seen, id) -> reaches?(blockers, rest, own_id, seen)
      true -> reaches?(blockers, Map.get(blockers, id, []) ++ rest, own_id, MapSet.put(seen, id))
    end
  end

  @doc "The issue ids of the tickets a wait stepped behind (R15), for the landing order."
  @spec behind([link()]) :: [String.t()]
  def behind(links), do: for(%{step_behind: true, released: false, issue_id: id} when is_binary(id) <- links, do: id)

  @doc """
  Applies a wait on `competitors` (see the moduledoc). `opts`: `:repo_key`, `:now`, `:links` (the
  ones recorded so far), and `:tracker`, `:store` and `:linker` (the Linear blocked-by links,
  `SymphonyElixir.Linear.Adapter` by default). A link Linear refuses is logged and the wait holds
  without it; a hold the store refuses is the error.
  """
  @spec wait(Issue.t(), [map(), ...], boolean(), keyword()) :: {:ok, [link()]} | {:error, term()}
  def wait(%Issue{} = issue, [_ | _] = competitors, step_behind, opts) do
    repo_key = Keyword.fetch!(opts, :repo_key)

    with :ok <- Hold.set(repo_key, issue.id, :blocked, BlockedHold.landing_attrs(competitors), hold_opts(opts)) do
      sync_pause(repo_key, issue.id, competitors)
      recorded = Keyword.get(opts, :links, [])
      existing = existing_blockers(issue)
      links = Enum.map(competitors, &link(&1, issue, {existing, recorded}, step_behind, opts))
      linked = for %{linked: true} = link <- links, not Enum.any?(recorded, &(&1.linked and same?(&1, link))), do: link.issue_identifier

      Logger.info(
        "pr_watch.competitors_linked issue_id=#{issue.id} issue_identifier=#{issue.identifier} " <>
          "linked=#{Enum.join(linked, ",")} waits_on=#{Enum.map_join(links, ",", &name/1)} step_behind=#{step_behind}"
      )

      {:ok, Enum.filter(recorded, & &1.released) ++ links}
    end
  end

  defp link(competitor, issue, {existing, recorded}, step_behind, opts) do
    identifier = Map.get(competitor, :issue_identifier)

    linked =
      cond do
        not is_binary(identifier) -> false
        Enum.any?(recorded, &(&1.linked and same?(&1, competitor))) -> true
        MapSet.member?(existing, identifier) or MapSet.member?(existing, Map.get(competitor, :issue_id)) -> false
        true -> add_link(identifier, issue, opts)
      end

    competitor
    |> record()
    |> Map.merge(%{progress_at: Keyword.fetch!(opts, :now), linked: linked, step_behind: step_behind, released: false})
  end

  defp add_link(identifier, issue, opts) do
    case linker(opts).add_blocked_by(identifier, issue.id) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("PR watch could not link #{identifier} as a blocker of issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        false
    end
  end

  @doc """
  Judges the ticket's wait on one read (see the moduledoc). `hold` is the ticket's `Blocked` hold
  (nil without one); a hold of another kind ends the wait, so every competitor left is unlinked.
  `opts`: `:repo_key`, `:terminal_states`, `:tracker`, `:store` and `:linker`. A link Linear
  refuses to remove keeps its competitor waited on, and the next read tries again.
  """
  @spec settle(Issue.t(), map() | nil, [link()], race(), keyword()) :: settled()
  def settle(%Issue{} = issue, hold, links, race, opts) do
    {released, waiting} = Enum.split_with(links, & &1.released)
    released = Enum.filter(released, &Map.has_key?(race.pulls, &1.pr_number))
    waiting? = BlockedHold.landing?(hold)
    judged = Enum.map(waiting, &judge(&1, waiting?, issue, race, opts))
    left = for {:left, link} <- judged, do: link
    {unlinked, stuck} = Enum.split_with(left, &unlink(&1, issue, opts))
    remaining = for({:racing, link} <- judged, do: link) ++ stuck
    log_unlinked(issue, unlinked)

    case BlockedHold.landing_desired(hold, remaining) do
      :clear ->
        clear(issue, hold, released, links, Enum.any?(waiting, & &1.step_behind), opts)

      {:set, attrs} ->
        renew(issue, hold, attrs, {released, remaining}, opts)

      :none ->
        sync_pause(Keyword.fetch!(opts, :repo_key), issue.id, if(waiting?, do: remaining, else: []))
        %{hold: if(waiting?, do: hold), links: released ++ remaining, restart_conflicts: false}
    end
  end

  defp judge(link, waiting?, issue, race, opts) do
    pull = Map.get(race.pulls, link.pr_number)

    cond do
      landed?(link, issue, race, opts) -> {:landed, link}
      not waiting? or is_nil(pull) -> {:left, link}
      true -> judge_open(link, pull, race)
    end
  end

  defp judge_open(link, pull, race) do
    shared = if is_list(Map.get(race, :files)), do: LandingOrder.shared_files(race.files, pull.files || []), else: link.files
    progress_at = if pull.head_sha == link.head_sha and link.progress_at, do: link.progress_at, else: race.now

    racing? =
      case Map.get(race.members, pull.number) do
        nil -> DateTime.diff(race.now, progress_at, :millisecond) < LandingOrder.idle_ms()
        member -> LandingOrder.leads?(member, race.now)
      end

    if shared != [] and racing?,
      do: {:racing, %{link | files: Enum.take(shared, @listed_files), head_sha: pull.head_sha, progress_at: progress_at}},
      else: {:left, link}
  end

  # A competitor lands once its ticket is terminal or its pull request was read merged.
  defp landed?(%{issue_id: id}, issue, race, opts) when is_binary(id) do
    terminal = MapSet.new(Keyword.get(opts, :terminal_states, []), &normalize/1)

    MapSet.member?(Map.get(race, :merged, MapSet.new()), id) or
      Enum.any?(issue.blocked_by || [], &(Map.get(&1, :id) == id and MapSet.member?(terminal, normalize(Map.get(&1, :state)))))
  end

  defp landed?(_link, _issue, _race, _opts), do: false

  # Symphony removes only the links it added; true once the link is gone.
  defp unlink(%{linked: true} = link, issue, opts) do
    case linker(opts).remove_blocked_by(link.issue_identifier, issue.id) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("PR watch could not unlink #{link.issue_identifier} from issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        false
    end
  end

  defp unlink(_link, _issue, _opts), do: true

  # A hold the store won't clear keeps every competitor recorded, so the next read judges them again.
  defp clear(issue, hold, released, links, step_behind?, opts) do
    case Hold.clear(Keyword.fetch!(opts, :repo_key), issue.id, :blocked, hold_opts(opts)) do
      :ok ->
        sync_pause(Keyword.fetch!(opts, :repo_key), issue.id, [])
        Logger.info("PR watch cleared the landing hold of issue_id=#{issue.id} issue_identifier=#{issue.identifier}: no competing pull request is left")
        %{hold: nil, links: released, restart_conflicts: step_behind?}

      {:error, reason} ->
        Logger.warning("PR watch could not clear the landing hold of issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        %{hold: hold, links: links, restart_conflicts: false}
    end
  end

  defp renew(issue, hold, attrs, {released, remaining}, opts) do
    repo_key = Keyword.fetch!(opts, :repo_key)

    case Hold.set(repo_key, issue.id, :blocked, attrs, hold_opts(opts)) do
      :ok ->
        sync_pause(repo_key, issue.id, remaining)
        %{hold: Map.merge(hold, attrs), links: released ++ remaining, restart_conflicts: false}

      {:error, _reason} ->
        %{hold: hold, links: released ++ remaining, restart_conflicts: false}
    end
  end

  # The pause follows the wait: a reason for each competitor waited on that it lacks is set, and a
  # landing reason (`BlockedHold.landing_reason?/1`, live or backfilled) for one no longer waited on is
  # cleared. Any other reason is left as it is.
  defp sync_pause(repo_key, issue_id, competitors, by \\ nil) do
    ticket = {:ticket, repo_key, issue_id}
    wanted = BlockedHold.landing_reasons(competitors)
    wanted_keys = Enum.map(wanted, &key/1)
    held_keys = ticket |> landing_reasons_held() |> Enum.map(&key/1)

    stale? = &(BlockedHold.landing_reason?(&1) and key(&1) not in wanted_keys)

    for reason <- wanted, key(reason) not in held_keys, do: Pauses.set(ticket, reason, set_by: BlockedHold.reason_setter(:landing))
    _ = Pauses.clear_reasons(ticket, stale?, if(by, do: [by: by], else: []))
    :ok
  end

  defp landing_reasons_held(ticket) do
    case Pauses.get(ticket) do
      {:ok, %{reasons: reasons}} -> Enum.filter(reasons, &BlockedHold.landing_reason?/1)
      _none -> []
    end
  end

  defp key(reason), do: {reason.kind, reason.waits_on}

  defp log_unlinked(_issue, []), do: :ok

  defp log_unlinked(issue, links) do
    case for(%{linked: true} = link <- links, do: link.issue_identifier) do
      [] -> :ok
      unlinked -> Logger.info("pr_watch.competitors_unlinked issue_id=#{issue.id} issue_identifier=#{issue.identifier} unlinked=#{Enum.join(unlinked, ",")}")
    end
  end

  @doc """
  A person's `Unblock` of a landing hold (see the moduledoc): removes the links Symphony added and
  marks every competitor released, on the ticket's watch record, and clears every landing reason of
  its pause, by the Director. `opts`: `:store` (or `:run_store`) and `:linker`.
  """
  @spec release(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def release(repo_key, issue_id, opts \\ []) do
    store = store(opts)
    sync_pause(repo_key, issue_id, [], @director)

    with %{} = record <- store.get_ticket_state(repo_key, issue_id),
         %{links: [_ | _] = links} = watch <- TicketState.pr_watch(record) do
      issue = %Issue{id: issue_id, identifier: record.issue_identifier}
      log_unlinked(issue, for(%{linked: true, released: false} = link <- links, unlink(link, issue, opts), do: link))
      links = Enum.map(links, &%{&1 | released: true, linked: false})
      store.put_ticket_pr_watch(repo_key, issue_id, record.issue_identifier, %{watch | links: links})
    else
      {:error, reason} -> {:error, reason}
      _nothing -> :ok
    end
  end

  @doc """
  Ends the wait of a ticket the watcher no longer watches: its landing hold clears and the links
  Symphony added are removed. `record` is its normalised state record.
  """
  @spec leave(String.t(), TicketState.t(), keyword()) :: :ok
  def leave(repo_key, record, opts) do
    issue = %Issue{id: record.issue_id, identifier: record.issue_identifier}

    if BlockedHold.landing?(TicketState.get_hold(record, :blocked)) do
      _ = Hold.clear(repo_key, record.issue_id, :blocked, hold_opts(opts))
    end

    sync_pause(repo_key, record.issue_id, [])

    links = (record.pr_watch && record.pr_watch.links) || []
    log_unlinked(issue, for(%{released: false} = link <- links, unlink(link, issue, opts), do: link))
    :ok
  end

  defp competitor(pull, member, shared) do
    %{
      issue_id: member && member.issue_id,
      issue_identifier: member && Map.get(member, :issue_identifier),
      pr_number: pull.number,
      pr_url: Map.get(pull, :url) || (member && Map.get(member, :pr_url)),
      title: Map.get(pull, :title),
      head_sha: Map.get(pull, :head_sha),
      files: Enum.take(shared, @listed_files)
    }
  end

  defp record(competitor) do
    %{
      issue_id: Map.get(competitor, :issue_id),
      issue_identifier: Map.get(competitor, :issue_identifier),
      pr_number: Map.get(competitor, :pr_number),
      pr_url: Map.get(competitor, :pr_url),
      title: Map.get(competitor, :title),
      files: Map.get(competitor, :files, []),
      head_sha: Map.get(competitor, :head_sha)
    }
  end

  # The same competitor: its ticket when both name one, else its pull request.
  defp same?(%{issue_id: id}, %{issue_id: id}) when is_binary(id), do: true
  defp same?(left, right), do: is_integer(Map.get(left, :pr_number)) and Map.get(left, :pr_number) == Map.get(right, :pr_number)

  defp existing_blockers(%Issue{blocked_by: blockers}) do
    for blocker <- List.wrap(blockers), key <- [Map.get(blocker, :id), Map.get(blocker, :identifier)], is_binary(key), into: MapSet.new(), do: key
  end

  defp name(%{issue_identifier: identifier}) when is_binary(identifier), do: identifier
  defp name(%{pr_number: number}), do: "PR ##{number}"

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  defp hold_opts(opts), do: [tracker: Keyword.get(opts, :tracker, Tracker), store: store(opts)]
  defp store(opts), do: Keyword.get(opts, :store) || Keyword.get(opts, :run_store, RunStore)
  defp linker(opts), do: Keyword.get(opts, :linker, SymphonyElixir.Linear.Adapter)
end
