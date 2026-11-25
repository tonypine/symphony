defmodule SymphonyElixir.Home.SubTickets do
  @moduledoc """
  What the Home read gives of an epic's sub-tickets and of a ticket's dependencies, shared by its
  slot entries (`SymphonyElixir.Home.Slots`) and its queue rows (`SymphonyElixir.Home.Queue`), all
  read from Symphony's own stores (no Linear and no GitHub request).

  - An epic's sub-tickets are the records it is the parent of (`SymphonyElixir.Dispatch.Queue.parents/1`)
    and the sub-issues its record lists that Symphony holds no record of. A cancelled one is in
    no list and no count.
  - A done sub-ticket (in a terminal state, not cancelled) gives its identifier, title, pull
    request number (`pull_request_number`, from its stored pull request,
    `SymphonyElixir.TicketPullRequest`, which keeps the URL once merged) and when it was done
    (`done_at`, the time its record entered its phase), oldest first; one known only by a link has
    nil for what only a record holds.
  - An open sub-ticket gives what a queue row gives of it: its state (`phase`), identifier, title,
    repo, dependencies and parent, in the stored queue order (`SymphonyElixir.Dispatch.Queue.places/2`).
  - A dependency gives its issue id, identifier, kind (`done` or `released`) and whether it is
    `met`: not among the open ones `SymphonyElixir.Dispatch.DependsOn.open/2` finds, the rule a
    row's `waits_on` follows, so the two never disagree.
  """

  alias SymphonyElixir.Dispatch
  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.TicketPullRequest

  @cancelled ["canceled", "cancelled", "duplicate"]

  @typedoc "An epic's sub-tickets: the records under it, and the links of those Symphony holds no record of."
  @type t :: %{records: [map()], links: [map()]}

  @doc "The records under each parent, by the parent's identifier, from `parents` (`SymphonyElixir.Dispatch.Queue.parents/1`)."
  @spec index([map()], %{String.t() => String.t()}) :: %{String.t() => [map()]}
  def index(records, parents) do
    Enum.group_by(Enum.filter(records, &Map.has_key?(parents, &1.issue_id)), &Map.fetch!(parents, &1.issue_id))
  end

  @doc "The sub-tickets of `epic` (a record), from `index/2`, a cancelled one left out."
  @spec of(map(), %{String.t() => [map()]}) :: t()
  def of(epic, index) do
    records = Map.get(index, epic.issue_identifier, [])
    known = MapSet.new(records, & &1.issue_id)

    %{
      records: Enum.reject(records, &cancelled?(&1.phase)),
      links: Enum.reject(epic.sub_issues, &(MapSet.member?(known, &1.id) or cancelled?(&1.state)))
    }
  end

  @doc "How many of the sub-tickets are done (in a state of `terminal`, lowercase) and how many there are."
  @spec counts(t(), MapSet.t(String.t())) :: {non_neg_integer(), non_neg_integer()}
  def counts(%{records: records, links: links}, terminal) do
    phases = Enum.map(records, & &1.phase) ++ Enum.map(links, & &1.state)
    {Enum.count(phases, &terminal?(&1, terminal)), length(phases)}
  end

  @doc "The done sub-tickets, oldest completion first (one with no known time first), each with its pull request number and done time."
  @spec done(t(), MapSet.t(String.t())) :: [map()]
  def done(%{records: records, links: links}, terminal) do
    from_records =
      for record <- records, terminal?(record.phase, terminal) do
        %{
          issue_id: record.issue_id,
          identifier: record.issue_identifier,
          title: record.title,
          pull_request_number: pull_request_number(record),
          done_at: record.phase_at
        }
      end

    from_links =
      for link <- links, terminal?(link.state, terminal), do: %{issue_id: link.id, identifier: link.identifier, title: nil, pull_request_number: nil, done_at: nil}

    Enum.sort_by(from_records ++ from_links, &{done_key(&1.done_at), &1.identifier || ""})
  end

  @doc """
  The open sub-tickets but those whose issue id is in `leave_out`, each as a queue entry, in the
  stored queue order (`places`, `SymphonyElixir.Dispatch.Queue.places/2`): the placed records,
  then the unplaced ones by identifier, then the links in the order the epic lists them. `by_id`
  holds every record by issue id, for the dependencies.
  """
  @spec open(map(), t(), MapSet.t(String.t()), keyword()) :: [map()]
  def open(epic, %{records: records, links: links}, terminal, opts) do
    by_id = Keyword.fetch!(opts, :by_id)
    places = Keyword.fetch!(opts, :places)
    leave_out = Keyword.get(opts, :leave_out, MapSet.new())

    from_records =
      records
      |> Enum.reject(&(terminal?(&1.phase, terminal) or MapSet.member?(leave_out, &1.issue_id)))
      |> Enum.sort_by(&place_key(Map.get(places, &1.issue_id), &1.issue_identifier))
      |> Enum.map(fn record ->
        %{
          issue_id: record.issue_id,
          identifier: record.issue_identifier,
          title: record.title,
          phase: record.phase,
          repo_key: record.repo_key,
          parent: epic.issue_identifier,
          dependencies: dependencies(record, by_id)
        }
      end)

    from_links =
      for link <- links, not terminal?(link.state, terminal), not MapSet.member?(leave_out, link.id) do
        %{issue_id: link.id, identifier: link.identifier, title: nil, phase: link.state, repo_key: nil, parent: epic.issue_identifier, dependencies: []}
      end

    from_records ++ from_links
  end

  @doc """
  Every stored dependency of `record` (`depends_on`), in its order, each with its issue id,
  identifier (the stored one, else the record's of the ticket it names), kind and whether it is
  `met`; `by_id` holds every record by issue id.
  """
  @spec dependencies(map(), %{String.t() => map()}) :: [map()]
  def dependencies(record, by_id) do
    open = DependsOn.open(record.depends_on, by_id)

    for dependency <- record.depends_on do
      identifier = dependency.identifier || Map.get(by_id, dependency.issue_id, %{})[:issue_identifier]
      %{issue_id: dependency.issue_id, identifier: identifier, kind: Atom.to_string(dependency.kind), met: dependency not in open}
    end
  end

  @doc "The places of the open `records` in the stored queue, under `parents` (`SymphonyElixir.Dispatch.Queue.places/2`)."
  @spec places([map()], %{String.t() => String.t()}, MapSet.t(String.t())) :: %{String.t() => Dispatch.Queue.place()}
  def places(records, parents, terminal) do
    records |> Enum.reject(&terminal?(&1.phase, terminal)) |> Dispatch.Queue.places(parents)
  end

  defp pull_request_number(%{repo_key: repo_key, issue_id: issue_id}) when is_binary(repo_key) and is_binary(issue_id) do
    with %{pr_url: url} when is_binary(url) <- TicketPullRequest.get(repo_key, issue_id),
         [_url, number] <- Regex.run(~r{/pull/(\d+)}, url) do
      String.to_integer(number)
    else
      _none -> nil
    end
  end

  defp pull_request_number(_record), do: nil

  defp done_key(nil), do: {0, 0}
  defp done_key(%DateTime{} = at), do: {1, DateTime.to_unix(at, :microsecond)}

  defp place_key(nil, identifier), do: {1, [], identifier || ""}
  defp place_key(place, identifier), do: {0, place, identifier || ""}

  defp terminal?(state, terminal), do: MapSet.member?(terminal, normalize(state))
  defp cancelled?(state), do: normalize(state) in @cancelled

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()
end
