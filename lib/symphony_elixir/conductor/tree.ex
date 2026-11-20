defmodule SymphonyElixir.Conductor.Tree do
  @moduledoc """
  A groomed ticket and the sub-tickets under it: what Symphony does to the tree, apart from the
  model turns that decide it (`SymphonyElixir.Conductor`).

  ## The split

  A plan of shape `split` (`SymphonyElixir.TicketPlan`) is carried out by `split/3`: each entry of
  its `sub_tickets` that names no `identifier` becomes a sub-ticket in the tracker, under the groomed
  ticket, Urgent, in its team and project and assigned as it is (an entry with a `repo` of its own
  goes to that repo's first routed team and project). The entry's `ask` is the sub-ticket's
  description and its first `ask.recorded` (`source: parent`, `from` the parent), so its own
  Grooming plans from it. An entry that already names an `identifier` is a sub-ticket the ticket
  had: it is adopted as it is.

  A sub-ticket that waits `after` siblings is created in `Backlog`, linked as blocked by each of
  them, and only then moved to `Todo`, so no dispatch finds it before its links. The identifiers
  are written back as a new version of the plan as soon as a sub-ticket exists, so a split that
  stops half way (3 of 5 created) creates only the missing ones when it runs again; the links and
  the move to `Todo` are read from the tracker and made where they are missing.

  Once every entry has its sub-ticket, Symphony's records take the new sub-tickets (an observation
  of the parent and of each, not a poll) and the parent moves to the waiting state
  (`groomed_split`), where it holds no run. The split runs again whenever a first run is about to
  start on a ticket whose plan is a split (`SymphonyElixir.Conductor.Grooming.split_due?/2`), so a
  split parent never gets a coding run.

  A split that fails is counted (`failed/3`, a status note under `grooming.split_try:<n>`): it is
  tried again at the next dispatch, and from the third failure on the person is asked each time.
  """

  require Logger

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.{Config, RepoTeams, RunStore, SubIssueWait}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{TicketEvents, TicketObservation, TicketPlan, Tracker, TransitionGuard}

  @urgent 1
  @todo "Todo"
  @backlog "Backlog"
  @split_tries 3
  @split_try_key "grooming.split_try:"
  @written_fields [:event_id, :at, :version]

  @typedoc "A sub-ticket Symphony created: its id, its identifier and the repo it belongs to."
  @type child :: %{id: String.t(), identifier: String.t(), repo: String.t()}

  @doc "Whether the waiting state a split parent waits in exists for `repo_key`, so a split can be carried out."
  @spec supported?(String.t() | nil) :: boolean()
  def supported?(repo_key) when is_binary(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> SubIssueWait.enabled?(settings)
      {:error, _reason} -> false
    end
  end

  def supported?(_repo_key), do: false

  @doc """
  Why Symphony refuses the sub-tickets a plan of `issue` lists, in plain words, or nil: an entry
  names a repo Symphony does not manage, or an `identifier` that is not one of the ticket's
  sub-tickets (`known`, their identifiers). `opts`: `repo` (`(key -> {:ok, repo} | {:error, term})`,
  default `Config.repo/1`).
  """
  @spec refusal([map()], String.t(), [String.t()], keyword()) :: String.t() | nil
  def refusal(entries, repo_key, known, opts) do
    Enum.find_value(entries, fn entry ->
      repo = Map.get(entry, :repo)
      identifier = Map.get(entry, :identifier)

      cond do
        is_binary(identifier) and identifier not in known -> "sub-ticket #{entry.key} names #{identifier}, which is not a sub-ticket of this ticket"
        repo not in [nil, repo_key] and not managed?(repo, opts) -> "sub-ticket #{entry.key} names the repo #{inspect(repo)}, which Symphony does not manage"
        true -> nil
      end
    end)
  end

  defp managed?(repo, opts), do: match?({:ok, _repo}, Keyword.get(opts, :repo, &Config.repo/1).(repo))

  @doc """
  Carries out the split the current plan of `issue` holds (see the module doc) and parks the ticket
  in the waiting state. `:ok` once it waits there; `{:error, why}`, in plain words, when a step
  failed, with what was created kept on the plan. `opts`: `tracker` (default
  `SymphonyElixir.Tracker`), `repo` and `routed_teams` (how another repo's team and project are
  found, as `refusal/4` and `SymphonyElixir.RepoTeams.routed_teams/1`), `observe`
  (`(repo_key, issue -> term)`, default `SymphonyElixir.TicketObservation.observe/2`).
  """
  @spec split(String.t(), Issue.t(), keyword()) :: :ok | {:error, String.t()}
  def split(repo_key, %Issue{id: issue_id} = issue, opts \\ []) do
    issue = with_record(issue)

    with %{shape: "split", sub_tickets: [_ | _] = entries} = plan <- TicketPlan.current(issue_id),
         {entries, failure} = create_missing(entries, repo_key, issue, opts),
         :ok <- write_identifiers(repo_key, issue_id, plan, entries),
         :ok <- failure || :ok,
         {:ok, parent} <- read_one(issue_id, opts),
         {:ok, children} <- read_children(entries, parent, opts),
         :ok <- link(entries, children, opts),
         :ok <- promote(entries, children, repo_key, opts),
         :ok <- observe([issue_id | Enum.map(children, & &1.id)], entries, repo_key, opts),
         :ok <- park(repo_key, issue, opts) do
      identifiers = Enum.map_join(entries, ", ", & &1.identifier)
      note(repo_key, issue_id, "Symphony split this ticket into #{identifiers}. It waits for them and gets no run of its own.", "grooming.split")
      Logger.info("Split a groomed ticket into sub-tickets #{context(issue, repo_key)} sub_tickets=#{identifiers}")
      :ok
    else
      {:error, why} -> {:error, why}
      _single_plan -> {:error, "the ticket holds no split plan"}
    end
  end

  # The dispatch's issue may lack what the record holds (a team, a project, an assignee).
  defp with_record(%Issue{id: issue_id} = issue) do
    case RunStore.get_ticket_state(issue_id) do
      %{} = record ->
        %{issue | team: issue.team || Map.get(record, :team), project: issue.project || Map.get(record, :project), assignee_id: issue.assignee_id || Map.get(record, :assignee)}

      _none ->
        issue
    end
  end

  defp read_one(issue_id, opts) do
    case tracker(opts).fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _rest]} -> {:ok, issue}
      {:ok, []} -> {:error, "the tracker does not return the ticket"}
      {:error, reason} -> {:error, "the ticket could not be read: #{inspect(reason)}"}
    end
  end

  # Each entry with no sub-ticket yet gets one, in order; the first that fails stops the rest.
  defp create_missing(entries, repo_key, issue, opts) do
    Enum.reduce(entries, {[], nil}, fn
      %{identifier: identifier} = entry, {done, failure} when is_binary(identifier) ->
        {done ++ [entry], failure}

      entry, {done, nil} ->
        case create(repo_key, issue, entry, opts) do
          {:ok, child} -> {done ++ [Map.put(entry, :identifier, child.identifier)], nil}
          {:error, why} -> {done ++ [entry], {:error, "sub-ticket #{entry.key} could not be created: #{why}"}}
        end

      entry, {done, failure} ->
        {done ++ [entry], failure}
    end)
  end

  @doc """
  Creates the sub-ticket `entry` describes (its `title`, its `ask`, the sibling keys it waits
  `after` and optionally its `repo`) under `issue`, and records its ask on it. It is created in
  `Todo`, or in `Backlog` when it waits `after` a sibling, whose link must exist before it is
  dispatched. `opts`: as `split/3`'s.
  """
  @spec create(String.t(), Issue.t(), map(), keyword()) :: {:ok, child()} | {:error, String.t()}
  def create(repo_key, %Issue{id: parent_id} = issue, entry, opts) do
    repo = Map.get(entry, :repo) || repo_key

    with {:ok, team, project} <- target(issue, repo_key, repo, opts),
         attrs = %{title: entry.title, description: entry.ask, priority: @urgent, state: first_state(entry), team: team, project: project},
         {:ok, %{id: id, identifier: identifier}} <- tracker(opts).create_issue(Map.merge(attrs, %{assignee_id: issue.assignee_id, parent_id: parent_id})) do
      from = issue.identifier || parent_id
      asked = TicketPlan.record_ask(repo, id, entry.ask, source: "parent", from: from, idempotency: "ask.recorded:parent")
      with {:error, reason} <- asked, do: Logger.warning("Could not record the ask of sub-ticket #{identifier} of #{from}: #{inspect(reason)}")
      {:ok, %{id: id, identifier: identifier, repo: repo}}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp first_state(entry), do: if(Map.get(entry, :after, []) == [], do: @todo, else: @backlog)

  # The team and project a sub-ticket goes to: its parent's, or its own repo's first routed ones.
  defp target(%Issue{team: team, project: project}, repo_key, repo_key, _opts) do
    case team do
      %{key: key} when is_binary(key) -> {:ok, key, project && (project[:id] || project[:slug_id] || project[:name])}
      _none -> {:error, "the ticket's team is not known"}
    end
  end

  defp target(_issue, _repo_key, other, opts) do
    with {:ok, repo} <- Keyword.get(opts, :repo, &Config.repo/1).(other),
         [team | _rest] <- Keyword.get(opts, :routed_teams, &RepoTeams.routed_teams/1).(repo) do
      {:ok, team, List.first(Map.get(repo, :projects) || [])}
    else
      _unknown -> {:error, "the repo #{inspect(other)} has no team Symphony can file in"}
    end
  end

  # The identifiers go on the plan as soon as they exist, so a later run creates only what is missing.
  defp write_identifiers(repo_key, issue_id, plan, entries) do
    if entries == plan.sub_tickets do
      :ok
    else
      next = plan |> Map.drop(@written_fields) |> Map.merge(%{sub_tickets: entries, reason: "Sub-tickets created", by: "grooming"})

      case TicketPlan.write(repo_key, issue_id, next) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, "the sub-tickets' identifiers could not be written on the plan: #{inspect(reason)}"}
      end
    end
  end

  # The plan's sub-tickets as the tracker holds them now: their state and their blockers.
  defp read_children(entries, %Issue{sub_issues: sub_issues}, opts) do
    listed = for %{id: id, identifier: identifier} <- List.wrap(if(is_list(sub_issues), do: sub_issues)), into: %{}, do: {identifier, id}
    missing = for %{identifier: identifier} <- entries, not is_map_key(listed, identifier), do: identifier

    with [] <- missing,
         {:ok, children} <- tracker(opts).fetch_issue_states_by_ids(Enum.map(entries, &Map.fetch!(listed, &1.identifier))) do
      {:ok, children}
    else
      [_ | _] -> {:error, "the tracker does not list #{Enum.join(missing, ", ")} under the ticket yet"}
      {:error, reason} -> {:error, "the sub-tickets could not be read: #{inspect(reason)}"}
    end
  end

  # Each sub-ticket is blocked by the siblings it waits after; a link the tracker already holds is kept.
  defp link(entries, children, opts) do
    by_key = Map.new(entries, &{&1.key, &1.identifier})
    by_identifier = Map.new(children, &{&1.identifier, &1})

    wanted =
      for entry <- entries, key <- Map.get(entry, :after, []), child = by_identifier[entry.identifier], blocker = by_key[key], not blocked_by?(child, blocker) do
        {blocker, child}
      end

    Enum.reduce_while(wanted, :ok, fn {blocker, child}, :ok ->
      case tracker(opts).add_blocked_by(blocker, child.id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{child.identifier} could not be linked as blocked by #{blocker}: #{inspect(reason)}"}}
      end
    end)
  end

  defp blocked_by?(%Issue{blocked_by: blockers}, identifier), do: Enum.any?(List.wrap(blockers), &(is_map(&1) and Map.get(&1, :identifier) == identifier))

  # A sub-ticket Symphony created in Backlog starts once its links exist; one a person keeps there stays.
  defp promote(entries, children, repo_key, opts) do
    repos = Map.new(entries, &{&1.identifier, Map.get(&1, :repo) || repo_key})

    children
    |> Enum.filter(&(is_binary(&1.state) and String.downcase(String.trim(&1.state)) == "backlog" and created?(&1.id)))
    |> Enum.reduce_while(:ok, fn child, :ok ->
      ctx = %{repo_key: repos[child.identifier], issue_identifier: child.identifier}

      case TransitionGuard.perform(child.id, :breakdown_promote, ctx, tracker: tracker(opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{child.identifier} could not be moved to #{@todo}: #{inspect(reason)}"}}
      end
    end)
  end

  defp created?(issue_id), do: Enum.any?(TicketPlan.ask(issue_id), &(&1.source == "parent"))

  # Symphony's records take the parent's new sub-tickets, and each sub-ticket, now and not at a poll.
  defp observe(ids, entries, repo_key, opts) do
    observe = Keyword.get(opts, :observe, &TicketObservation.observe/2)
    repos = Map.new(entries, &{&1.identifier, Map.get(&1, :repo) || repo_key})

    case tracker(opts).fetch_issue_states_by_ids(ids) do
      {:ok, issues} ->
        for %Issue{} = issue <- issues, do: observe.(Map.get(repos, issue.identifier, repo_key), issue)
        :ok

      {:error, reason} ->
        {:error, "the new sub-tickets could not be read back: #{inspect(reason)}"}
    end
  end

  defp park(repo_key, %Issue{id: issue_id} = issue, opts) do
    ctx = %{repo_key: repo_key, settings: Config.settings_for_repo!(repo_key), issue_identifier: issue.identifier}

    case TransitionGuard.perform(issue_id, :groomed_split, ctx, tracker: tracker(opts)) do
      :ok -> :ok
      {:error, reason} -> {:error, "the ticket could not be moved to the waiting state: #{inspect(reason)}"}
    end
  end

  @doc """
  Counts a split that failed, with `why` in plain words, as a status note on the ticket. `:retry`
  while the next dispatch tries again by itself; `:ask` from the third failure on, when the person
  is asked instead (`question/2`).
  """
  @spec failed(String.t(), String.t(), String.t()) :: :retry | :ask
  def failed(repo_key, issue_id, why) do
    try = Enum.count(Facts.events(issue_id), &(&1.type == "note" and is_binary(&1.idempotency) and String.starts_with?(&1.idempotency, @split_try_key))) + 1
    note(repo_key, issue_id, "Symphony could not split this ticket into its sub-tickets: #{why}.", "#{@split_try_key}#{try}")
    if try < @split_tries, do: :retry, else: :ask
  end

  @doc "The question Symphony asks the person once a split keeps failing for `why`."
  @spec question(String.t()) :: map()
  def question(why) do
    %{
      title: "The sub-tickets could not be created",
      question: "Symphony could not split this ticket into its sub-tickets: #{Facts.fit(why, 600)}. Try again?",
      why: "The plan splits this ticket, and no run starts on it until its sub-tickets exist.",
      if_unanswered: "The ticket stays paused and nothing is built.",
      recommendation_reason: "The plan is written; only creating the sub-tickets failed.",
      options: [
        %{label: "Try again", effect: "Symphony creates the missing sub-tickets.", recommended: true, action: "continue"},
        %{label: "Cancel the ticket", effect: "The ticket is cancelled.", recommended: false, action: "cancel"}
      ]
    }
  end

  defp note(repo_key, issue_id, text, key) do
    case TicketEvents.record(repo_key, issue_id, "note", %{text: Facts.fit(text, 4_000), status: true}, idempotency: key) do
      {:ok, _event} -> :ok
      {:error, reason} -> Logger.warning("Could not record a note on issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(reason)}")
    end
  end

  defp tracker(opts), do: Keyword.get(opts, :tracker, Tracker)

  defp context(%Issue{id: issue_id, identifier: identifier}, repo_key), do: "issue_id=#{issue_id} issue_identifier=#{identifier} repo_key=#{repo_key}"
end
