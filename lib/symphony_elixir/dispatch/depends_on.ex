defmodule SymphonyElixir.Dispatch.DependsOn do
  @moduledoc """
  Whether a ticket's stored dependencies hold it back from dispatch (`depends_on` on
  `SymphonyElixir.TicketState`, written by `SymphonyElixir.RunStore.add_dependency/3` and
  `remove_dependency/2`).

  A dependency names another ticket and what this one needs of it:

  - `:done`: the ticket depended on is merged: its record's phase is Done, or its pull request merged
    and it waits on its own sub-tickets, or it is groomed and its pull request merged, as the
    old blocker hold counted a blocker resolved (`SymphonyElixir.SubIssueWait.merged_blocker?/1`,
    read from Symphony's stores), so a sub-ticket that depends on its merged parent never waits on
    it while the parent waits on the sub-ticket. A cancelled ticket meets no dependency, and neither
    does a ticket Symphony holds no record of.
  - `:released`: it is Done and the running build includes its merge. What the build includes is
    what `SymphonyElixir.UpdateHold` knows, in the same cache: `resolve/4`, in the poll task, looks
    each one up (`SymphonyElixir.UpdateHold.awaiting_update/4`), and `unmet/4` only reads the cache.
    As for the update hold, a ticket merged in another repository, one opted out with the
    `skip-update-hold` label, and every ticket when the running build has no sha are released at
    Done. One whose lookup has not answered yet is not released, and is looked up again at the next
    poll.

  The decision reads the stored records alone, on every pass, and writes nothing: no pause, no read
  of Linear. A ticket held so starts by itself on the first pass that finds the dependency met.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, SubIssueWait, TicketState, UpdateHold}

  @done "done"

  @doc """
  The dependencies among `dependencies` (`t:SymphonyElixir.TicketState.dependency/0`) that are not
  met, in their order: `records` holds the record of each ticket depended on by issue id (a ticket
  missing from it has none), `build` is the running build (`SymphonyElixir.BuildInfo.current/0`)
  and `cache` the update hold's cache.
  """
  @spec unmet([TicketState.dependency()], %{String.t() => map()}, map(), UpdateHold.cache()) :: [TicketState.dependency()]
  def unmet(dependencies, records, build, cache) when is_list(dependencies) and is_map(records) do
    Enum.reject(dependencies, &met?(&1, Map.get(records, &1.issue_id), build, cache))
  end

  @doc """
  The dependencies among `dependencies` still open, whatever the running build holds: those `unmet/4`
  finds unmet for a build with no sha, so a `:released` dependency counts as met once its ticket is
  done. What a reader that shows who waits on whom (Home, the dispatch order, the presenter) reads:
  a ticket done but not yet in the build waits on the build, not on that ticket.
  """
  @spec open([TicketState.dependency()], %{String.t() => map()}) :: [TicketState.dependency()]
  def open(dependencies, records), do: unmet(dependencies, records, %{}, UpdateHold.empty_cache())

  @doc """
  The ticket `issue_id`'s stored dependencies still open (`open/2`), read from the store
  (`SymphonyElixir.RunStore.dependencies/1`), each with the record of the ticket it names (nil when
  Symphony holds none); `[]` when it has none or the store can't be read.
  """
  @spec open_for(String.t() | nil) :: [{TicketState.dependency(), map() | nil}]
  def open_for(issue_id) when is_binary(issue_id) do
    case RunStore.dependencies(issue_id) do
      [_ | _] = entries ->
        records = for {entry, %{} = record} <- entries, into: %{}, do: {entry.issue_id, record}
        open = open(Enum.map(entries, &elem(&1, 0)), records)
        Enum.filter(entries, fn {entry, _record} -> entry in open end)

      _none_or_unreadable ->
        []
    end
  end

  def open_for(_issue_id), do: []

  @doc "The identifiers of the ticket `issue_id`'s open stored dependencies (`open_for/1`), each once."
  @spec open_identifiers(String.t() | nil) :: [String.t()]
  def open_identifiers(issue_id) do
    for {%{} = entry, record} <- open_for(issue_id),
        identifier = name_of(entry, record),
        is_binary(identifier),
        uniq: true,
        do: identifier
  end

  defp name_of(%{identifier: identifier}, _record) when is_binary(identifier), do: identifier
  defp name_of(_entry, %{issue_identifier: identifier}), do: identifier
  defp name_of(_entry, _record), do: nil

  defp met?(%{kind: :done, issue_id: id}, record, _build, _cache), do: done?(record) or merged?(id, record)
  defp met?(%{kind: :released, issue_id: id}, record, build, cache), do: done?(record) and released?(id, build, cache)

  defp done?(%{phase: phase}) when is_binary(phase), do: phase |> String.trim() |> String.downcase() == @done
  defp done?(_record), do: false

  defp merged?(id, %{phase: phase}) when is_binary(phase), do: SubIssueWait.merged_blocker?(%{id: id, state: phase})
  defp merged?(_id, _record), do: false

  # Whether the running build includes the merge of the ticket `id`, as the update hold's cache
  # knows it.
  defp released?(id, %{sha: build_sha, repo: build_repo}, cache) when is_binary(build_sha) and is_binary(build_repo) do
    case Map.get(cache.blockers, id) do
      {:merged, _pr_url, merge_sha} -> Map.get(cache.included, {merge_sha, build_sha}) == true
      fact when fact in [:none, :skip] -> true
      nil -> false
    end
  end

  defp released?(_id, _build, _cache), do: true

  @doc """
  Looks up, into the update hold's `cache`, whether the running `build` includes the merge of each
  Done ticket a `:released` dependency in `records` (every ticket record) names, and returns the
  cache. A ticket already in the cache is not looked up again; records that could not be read (the
  store's error) look nothing up. Takes the lookup options of
  `SymphonyElixir.UpdateHold.awaiting_update/4`; the record's own repository is the one its pull
  request is read under.
  """
  @spec resolve([map()] | {:error, term()}, map(), UpdateHold.cache(), keyword()) :: UpdateHold.cache()
  def resolve(records, build, cache, opts \\ []), do: resolve_records(records, build, cache, opts)

  defp resolve_records(records, build, cache, opts) when is_list(records) do
    by_id = for %{issue_id: id} = record when is_binary(id) <- records, into: %{}, do: {id, record}

    released =
      for record <- records,
          %{kind: :released, issue_id: id} <- TicketState.normalize(record).depends_on,
          on = Map.get(by_id, id),
          done?(on),
          uniq: true,
          do: TicketState.normalize(on)

    Enum.reduce(released, cache, fn on, cache ->
      {_waiting, cache} = UpdateHold.awaiting_update(issue(on), build, cache, Keyword.put(opts, :repo_key, on.repo_key))
      cache
    end)
  end

  defp resolve_records(_unreadable, _build, cache, _opts), do: cache

  defp issue(record) do
    %Issue{id: record.issue_id, identifier: record.issue_identifier, state: record.phase, labels: record.labels, repo_key: record.repo_key}
  end

  @doc "The line a dispatch skip shows for `unmet` (`unmet/4`), naming each ticket waited on."
  @spec reason([TicketState.dependency(), ...]) :: String.t()
  def reason([_ | _] = unmet), do: Enum.map_join(unmet, "; ", &line/1)

  defp line(%{kind: :done} = dependency), do: "waiting for #{name(dependency)} to be done"
  defp line(%{kind: :released} = dependency), do: "waiting for a Symphony update that includes #{name(dependency)}"

  defp name(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp name(%{issue_id: id}), do: "ticket #{id}"
end
