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

  ## The close of a groomed ticket

  A groomed ticket in the waiting state closes by one rule (`due/3`): its own pull request merged
  or it never had one, and none of its sub-tickets is left outside Done or Canceled (one in
  `Backlog` holds it). Then the Conductor's `final_check` turn is owed: it reads the whole tree and
  answers `done`, which moves the ticket to `Done` (`final_check_pass`), or adds sub-tickets
  (`tree` operations of `op: add`), which is a round: the plan takes a new version whose `reason`
  starts with `Final check`, and those versions are the count of rounds (`rounds/1`). After
  `conductor.final_check_rounds` rounds Symphony refuses one more and asks the person instead
  (`apply/3` answers `{:ask, question}`); "Allow one more round" lets one through (`asked/2` records
  it, `round_limit/2` counts it), and "Close it as it is" moves the ticket to `Done`.

  ## Recalibration

  While sub-tickets are still open, each one that ends owes the parent a `sub_ticket_ended` turn
  (`due/3`, `seen/3`), which may change the tree with `tree` operations: `add` a sub-ticket,
  `cancel` one that is not Done (the Director's cancel move: its run stops, its pull request
  closes), `rewrite` one (a new `ask.recorded` on it, `source: parent`; its working run is stopped
  first only with `stop: true`; a sub-ticket that already has a plan then writes it again in a
  Conductor turn of its own, `SymphonyElixir.Conductor.Message.recalibrate/3`) and `stop` a sub-ticket's working run. Each operation carried out is
  recorded on the sub-ticket it touched as a `conductor.intervention` (`added`, `canceled`,
  `replanned`, `stopped`) with its reason, and together they give the parent's plan a new version
  (`by: recalibration`, its reason opening with `Recalibration`), whose `sub_tickets` follow them.

  With the Conductor or its `final_check` junction off the turn cannot run at all, and the ticket
  closes on its sub-tickets alone, as a ticket did before plans
  (`SymphonyElixir.SubIssueWait.close?/3`). That is the only close without a final check. A final
  check that ran and did not conclude never closes the ticket: Symphony asks the person instead
  (`apply/3` and `checked/3` answer `{:ask, :stuck, question}`), naming what is open, and the ticket
  stays in the waiting state until they answer "Check again" or "Close it as it is". That is so when
  the check answered that the ticket is not done and added nothing, when none of the sub-tickets it
  wanted could be created, when its `done` could not move the ticket, and when the turn itself
  failed or could not be read 2 times in a row (each counted by `checked/3`, a status note under
  `final_check.try:<n>`).
  """

  require Logger

  alias SymphonyElixir.Conductor.{Facts, Message}
  alias SymphonyElixir.{Config, DirectorMoves, Orchestrator, RepoTeams, RunStore, SubIssueWait}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketObservation, TicketPlan, Tracker, TransitionGuard}

  @urgent 1
  @todo "Todo"
  @backlog "Backlog"
  @split_tries 3
  @split_try_key "grooming.split_try:"
  @final_tries 2
  @final_try_key "final_check.try:"
  @asked_key "final_check.asked:"
  @stuck_key "final_check.stuck:"
  @round "Final check"
  @recalibration "Recalibration"
  @ended_key "tree.ended:"
  @done "Done"
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
  dispatched. `opts`: as `split/3`'s, and `standalone: true` for a ticket of its own, in the same
  team and project and assigned the same but not under `issue` (the ticket a message on a finished
  ticket asks for, `SymphonyElixir.Conductor.Message`), with `ask`, how its ask is recorded
  (`SymphonyElixir.TicketPlan.record_ask/4`'s options; default from its parent).
  """
  @spec create(String.t(), Issue.t(), map(), keyword()) :: {:ok, child()} | {:error, String.t()}
  def create(repo_key, %Issue{id: parent_id} = issue, entry, opts) do
    repo = Map.get(entry, :repo) || repo_key
    issue = with_record(issue)
    family = if Keyword.get(opts, :standalone, false), do: %{}, else: %{parent_id: parent_id}

    with {:ok, team, project} <- target(issue, repo_key, repo, opts),
         attrs = %{title: entry.title, description: entry.ask, priority: @urgent, state: first_state(entry), team: team, project: project},
         {:ok, %{id: id, identifier: identifier}} <- tracker(opts).create_issue(attrs |> Map.put(:assignee_id, issue.assignee_id) |> Map.merge(family)) do
      from = issue.identifier || parent_id
      asked = TicketPlan.record_ask(repo, id, entry.ask, Keyword.get(opts, :ask, source: "parent", from: from, idempotency: "ask.recorded:parent"))
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
    repos = for %{identifier: identifier} = entry <- entries, into: %{}, do: {identifier, Map.get(entry, :repo) || repo_key}

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
    repos = for %{identifier: identifier} = entry <- entries, into: %{}, do: {identifier, Map.get(entry, :repo) || repo_key}

    case tracker(opts).fetch_issue_states_by_ids(ids) do
      {:ok, issues} ->
        for %Issue{} = issue <- issues, do: observe.(Map.get(repos, issue.identifier, repo_key), issue)
        :ok

      {:error, reason} ->
        {:error, "the new sub-tickets could not be read back: #{inspect(reason)}"}
    end
  end

  @doc """
  Puts the ticket `issue_id` and its new sub-tickets `children` on Symphony's records now: each is
  read from the tracker by id and observed under its repo, so the parent lists its sub-tickets and
  each names its parent before any poll. `opts`: `tracker` and `observe`, as `split/3`'s.
  """
  @spec observed(String.t(), String.t(), [child()], keyword()) :: :ok | {:error, String.t()}
  def observed(repo_key, issue_id, children, opts) do
    observe([issue_id | Enum.map(children, & &1.id)], children, repo_key, opts)
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

  @doc """
  What the groomed ticket `issue`, in the waiting state, is owed now (see the module doc): `:close`
  (Symphony moves it to `Done` itself), `:final_check` (the Conductor's turn),
  `:sub_ticket_ended` (the Conductor's turn too: sub-tickets are still open, and one ended that no
  such turn looked at yet, `seen/3`), or nil while it waits: a sub-ticket is open, its sub-tickets
  were not read (`:unknown`), or it has a pull request that did not merge, which is a person's to
  settle. `opts`: `conductor` (the `conductor`
  settings, default `Config.conductor_settings/0`) and `events` (the ticket's, default its record's).
  """
  @spec due(Issue.t() | term(), Enumerable.t(String.t()), keyword()) :: :close | :final_check | :sub_ticket_ended | nil
  def due(%Issue{id: issue_id, sub_issues: sub_issues} = issue, terminal_states, opts)
      when is_binary(issue_id) and is_list(sub_issues) do
    settings = Keyword.get_lazy(opts, :conductor, &Config.conductor_settings/0)
    events = Keyword.get_lazy(opts, :events, fn -> Facts.events(issue_id) end)

    if Issue.open_sub_issues(issue, terminal_states) == [],
      do: due_ended(issue, settings),
      else: due_open(issue, terminal_states, settings, events)
  end

  def due(_issue, _terminal_states, _opts), do: nil

  @doc "`due/3` with the `conductor` settings and the ticket's events as they are now."
  @spec due(Issue.t() | term(), Enumerable.t(String.t())) :: :close | :final_check | :sub_ticket_ended | nil
  def due(issue, terminal_states), do: due(issue, terminal_states, [])

  # Every sub-ticket ended (or none is left): the ticket closes, after its final check when one is owed.
  # Only a final check that cannot run at all (the Conductor or its junction is off) is skipped.
  defp due_ended(%Issue{id: issue_id, sub_issues: sub_issues}, settings) do
    cond do
      RunStore.merged_wait?(issue_id) != true and SubIssueWait.pull_request(issue_id) == :unmerged -> nil
      sub_issues == [] -> :close
      turn?(settings, "final_check") -> :final_check
      true -> :close
    end
  end

  defp due_open(issue, terminal_states, settings, events) do
    if turn?(settings, "sub_ticket_ended") and unseen(issue, terminal_states, events) != [], do: :sub_ticket_ended
  end

  defp turn?(settings, junction), do: settings.enabled == true and junction in settings.junctions

  # The sub-tickets that ended and that no `sub_ticket_ended` turn was started for yet.
  defp unseen(%Issue{sub_issues: sub_issues} = issue, terminal_states, events) do
    open = MapSet.new(Issue.open_sub_issues(issue, terminal_states), & &1.id)
    seen = for %{type: "note", idempotency: @ended_key <> id} <- events, into: MapSet.new(), do: id
    Enum.reject(sub_issues, &(MapSet.member?(open, &1.id) or MapSet.member?(seen, &1.id)))
  end

  @doc """
  Records each sub-ticket of `issue` that ended and was not looked at yet as seen (a status note
  under `tree.ended:<its id>`), as the `sub_ticket_ended` turn that looks at them starts: one turn
  is owed for them, whatever it answers.
  """
  @spec seen(String.t(), Issue.t(), Enumerable.t(String.t())) :: :ok
  def seen(repo_key, %Issue{id: issue_id} = issue, terminal_states) do
    for sub <- unseen(issue, terminal_states, Facts.events(issue_id)) do
      note(repo_key, issue_id, "Sub-ticket #{sub.identifier} ended: #{sub.state}.", @ended_key <> sub.id)
    end

    :ok
  end

  @doc "How many rounds of sub-tickets the final check added to the ticket whose `events` these are."
  @spec rounds([TicketEvents.Event.t()]) :: non_neg_integer()
  def rounds(events) when is_list(events) do
    Enum.count(TicketPlan.versions(events), &String.starts_with?(to_string(Map.get(&1, :reason)), @round))
  end

  @doc """
  How many rounds the final check may add on the ticket whose `events` these are: `settings`'
  `final_check_rounds`, and one more for each time the person was asked and let it go on (`asked/2`).
  """
  @spec round_limit([TicketEvents.Event.t()], map()) :: non_neg_integer()
  def round_limit(events, settings) when is_list(events), do: settings.final_check_rounds + keyed(events, @asked_key)

  # The final checks in a row that did not finish, since the person was last asked about one.
  defp tries(events) do
    events |> Enum.reverse() |> Enum.take_while(&(not keyed?(&1, @stuck_key))) |> Enum.count(&keyed?(&1, @final_try_key))
  end

  defp keyed(events, prefix), do: Enum.count(events, &keyed?(&1, prefix))

  defp keyed?(event, prefix), do: event.type == "note" and is_binary(event.idempotency) and String.starts_with?(event.idempotency, prefix)

  @doc """
  Carries out what a turn on the ticket answered about its tree (`answer`'s `done` and `tree`).
  `ctx` holds the `issue`, its `repo_key`, the turn's `run_id` and `junction`, and the `conductor`
  settings.

  At `final_check`: `done` with nothing to add moves the ticket to `Done`; sub-tickets to add are a
  round, made while one is left (`round_limit/2`), else `{:ask, :rounds, question}` is answered and
  nothing is added: the person decides. Only `add` is read there. A check that concluded nothing
  (not done with nothing to add, no sub-ticket it wanted could be created, or the move to `Done`
  failed) answers `{:ask, :stuck, question}`: the ticket never closes on such a check.

  At `sub_ticket_ended` every operation is carried out, in order (see the module doc). One that
  can't be (the ticket it names is not a sub-ticket of this one, or it ended, or the step failed) is
  logged and left out.

  `opts`: as `split/3`'s, and `cancel` (`(identifier, reason -> {:ok, term} | {:error, term})`,
  default the Director's cancel move), `stop` (`(identifier -> {:ok, %{stopped: boolean}} | term)`,
  default `SymphonyElixir.Orchestrator.stop_running/1`) and `recalibrate` (`(issue_id, ask event ->
  term)`, what a `rewrite` starts on the sub-ticket).
  """
  @spec apply(map(), map(), keyword()) :: :ok | {:ask, :rounds | :stuck, map()}
  def apply(%{done: done, tree: operations}, %{junction: "final_check", issue: %Issue{id: issue_id} = issue} = ctx, opts) do
    adds = Enum.filter(operations, &(&1.op == "add"))
    events = Facts.events(issue_id)
    made = rounds(events)
    titles = Enum.map_join(adds, "; ", & &1.title)

    cond do
      adds == [] and done -> pass(ctx.repo_key, issue, opts)
      adds == [] -> {:ask, :stuck, stuck_question(issue_id, "it answered that the ticket is not done, and added no sub-ticket")}
      made >= round_limit(events, ctx.conductor) -> {:ask, :rounds, rounds_question(made, titles)}
      carry_out(adds, @round, ctx, opts) == 0 -> {:ask, :stuck, stuck_question(issue_id, "none of the sub-tickets it wanted to add could be created (#{titles})")}
      true -> :ok
    end
  end

  def apply(%{tree: operations}, ctx, opts) do
    _carried = carry_out(operations, @recalibration, ctx, opts)
    :ok
  end

  defp pass(repo_key, %Issue{id: issue_id} = issue, opts) do
    ctx = %{repo_key: repo_key, issue_identifier: issue.identifier}

    case TransitionGuard.perform(issue_id, :final_check_pass, ctx, tracker: tracker(opts)) do
      :ok ->
        _ = RunStore.delete_merged_wait(issue_id)
        note(repo_key, issue_id, "The final check passed: every sub-ticket ended and the plan's outcomes hold. This ticket is #{@done}.", "final_check.passed")
        Logger.info("Moved a groomed ticket to #{@done}: its final check passed #{context(issue, repo_key)}")

      {:error, reason} ->
        Logger.warning("The final check passed, but the ticket could not be moved to #{@done} #{context(issue, repo_key)}: #{inspect(reason)}")
        {:ask, :stuck, stuck_question(issue_id, "it passed, but the ticket could not be moved to #{@done} ")}
    end
  end

  # Each operation in order, on the plan's sub-ticket entries. What was carried out is written as a
  # new version of the plan, whose reason opens with `why` and holds each operation's own. Answers
  # how many operations were carried out.
  defp carry_out([], _why, _ctx, _opts), do: 0

  defp carry_out(operations, why, %{issue: %Issue{id: issue_id} = issue, repo_key: repo_key} = ctx, opts) do
    ctx = Map.merge(ctx, %{issue: with_record(issue), known: known_children(issue_id), terminal: terminal_states(repo_key)})
    versions = TicketPlan.versions(issue_id)
    plan = List.last(versions)
    ctx = Map.put(ctx, :keys, for(version <- versions, entry <- Map.get(version, :sub_tickets, []), into: MapSet.new(), do: entry.key))
    start = %{entries: Map.get(plan, :sub_tickets, []), created: [], reasons: []}

    done =
      Enum.reduce(operations, start, fn operation, acc ->
        case operate(operation, acc, ctx, opts) do
          {:ok, acc} ->
            %{acc | reasons: acc.reasons ++ [operation.reason]}

          {:error, reason} ->
            Logger.warning("The Conductor's #{operation.op} was not carried out #{context(issue, repo_key)} on=#{operation[:ticket] || operation[:title]}: #{reason}")
            acc
        end
      end)

    if done.reasons != [], do: record_version(plan, done, why, ctx, opts)
    length(done.reasons)
  end

  defp record_version(plan, done, why, %{issue: %Issue{id: issue_id}, repo_key: repo_key}, opts) do
    reason = Facts.fit("#{why}: " <> Enum.join(done.reasons, " "), 1_000)
    next = plan |> Map.drop(@written_fields ++ [:sub_tickets]) |> Map.merge(%{reason: reason, by: "recalibration"})
    next = if done.entries == [], do: next, else: Map.put(next, :sub_tickets, done.entries)

    with {:error, why} <- TicketPlan.write(repo_key, issue_id, next),
         do: Logger.warning("The plan's new version could not be written issue_id=#{issue_id} repo_key=#{repo_key}: #{inspect(why)}")

    with [_ | _] = created <- done.created,
         {:error, why} <- observe([issue_id | Enum.map(created, & &1.id)], done.entries, repo_key, opts),
         do: Logger.warning("The added sub-tickets are not on Symphony's records yet issue_id=#{issue_id} repo_key=#{repo_key}: #{why}")
  end

  # A new sub-ticket: created, linked to what it waits on and started, under the next free key.
  defp operate(%{op: "add"} = operation, acc, %{issue: issue, repo_key: repo_key} = ctx, opts) do
    entry = entry(operation, acc.entries, ctx)

    with {:ok, child} <- create(repo_key, issue, entry, opts) do
      start(child, entry, ctx, opts)
      intervene(child, "added", operation.reason, ctx)
      listed = Map.merge(entry, %{identifier: child.identifier, after: plan_keys(entry.after, acc.entries)})
      {:ok, %{acc | entries: acc.entries ++ [listed], created: acc.created ++ [child]}}
    end
  end

  # A sub-ticket that is no longer needed: cancelled as the Director cancels one, and off the plan.
  defp operate(%{op: "cancel", ticket: identifier} = operation, acc, ctx, opts) do
    cancel = Keyword.get(opts, :cancel, &DirectorMoves.move(:cancel, &1, %{note: &2}))

    with {:ok, child} <- open_child(identifier, ctx),
         {:ok, _moved} <- cancel.(identifier, "The Conductor of #{by(ctx)} cancelled this sub-ticket: #{operation.reason}") do
      intervene(child, "canceled", operation.reason, ctx)
      {:ok, %{acc | entries: Enum.reject(acc.entries, &(Map.get(&1, :identifier) == identifier))}}
    else
      {:error, reason} -> {:error, text(reason)}
    end
  end

  # A sub-ticket asked for something else: its new ask is recorded on it, from this ticket.
  defp operate(%{op: "rewrite", ticket: identifier, ask: ask} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(identifier, ctx),
         :ok <- if(operation.stop, do: stop(child, operation.reason, ctx, opts), else: :ok),
         {:ok, event} <- TicketPlan.record_ask(child.repo, child.id, ask, source: "parent", from: by(ctx)) do
      intervene(child, "replanned", operation.reason, ctx)
      # A sub-ticket that already has a plan writes it again for the new ask, in a turn of its own.
      Keyword.get(opts, :recalibrate, &Message.recalibrate/2).(child.id, event)
      {:ok, %{acc | entries: Enum.map(acc.entries, &if(Map.get(&1, :identifier) == identifier, do: %{&1 | ask: ask}, else: &1))}}
    else
      {:error, reason} -> {:error, text(reason)}
    end
  end

  defp operate(%{op: "stop", ticket: identifier} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(identifier, ctx),
         :ok <- stop(child, operation.reason, ctx, opts) do
      {:ok, acc}
    end
  end

  defp stop(child, reason, ctx, opts) do
    case Keyword.get(opts, :stop, &Orchestrator.stop_running/1).(child.identifier) do
      {:ok, %{stopped: true}} -> intervene(child, "stopped", reason, ctx)
      other -> {:error, "its run was not stopped (#{inspect(other)})"}
    end
  end

  # The sub-ticket `identifier` names, when it is this ticket's and has not ended.
  defp open_child(identifier, %{known: known, terminal: terminal, repo_key: repo_key}) do
    case Map.get(known, identifier) do
      nil ->
        {:error, "#{identifier} is not a sub-ticket of this ticket"}

      %{id: id, state: state} ->
        open_child(%{id: id, identifier: identifier, repo: recorded_repo(id) || repo_key}, state, terminal)
    end
  end

  defp open_child(child, state, terminal) do
    if normalize(state) in terminal, do: {:error, "#{child.identifier} already ended (#{state})"}, else: {:ok, child}
  end

  defp recorded_repo(issue_id), do: with(%{repo_key: repo_key} <- RunStore.get_ticket_state(issue_id), do: repo_key)

  defp terminal_states(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> Enum.map(settings.tracker.terminal_states, &normalize/1)
      {:error, _reason} -> []
    end
  end

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)

  defp by(%{issue: issue}), do: issue.identifier || issue.id

  # A plan entry for an added sub-ticket, under the next key no version of the plan ever used. Its
  # `after` are the identifiers of the ticket's sub-tickets it waits on; any other name is dropped.
  defp entry(operation, entries, %{known: known, keys: used}) do
    keys = MapSet.union(used, MapSet.new(entries, & &1.key))
    key = Enum.find_value(Stream.iterate(1, &(&1 + 1)), &if(not MapSet.member?(keys, "s#{&1}"), do: "s#{&1}"))
    waits = Enum.filter(Map.get(operation, :after, []), &is_map_key(known, &1))
    operation |> Map.take([:title, :ask, :repo]) |> Map.merge(%{key: key, after: waits})
  end

  defp plan_keys(identifiers, entries), do: for(%{identifier: identifier, key: key} <- entries, identifier in identifiers, do: key)

  # The ticket's sub-tickets as its record lists them: each identifier with its id and state.
  defp known_children(issue_id) do
    record = RunStore.get_ticket_state(issue_id)

    for %{id: id, identifier: identifier} = sub <- List.wrap(is_map(record) && Map.get(record, :sub_issues)), into: %{} do
      {identifier, %{id: id, state: Map.get(sub, :state)}}
    end
  end

  # A sub-ticket created in Backlog is linked to what it waits on, then moved to Todo. A step that
  # fails is said on the parent, and the sub-ticket still starts when it can: it must not hold the
  # parent from Backlog for good.
  defp start(_child, %{after: []}, _ctx, _opts), do: :ok

  defp start(child, %{after: waits}, %{issue: issue, repo_key: repo_key}, opts) do
    linked = for blocker <- waits, {:error, reason} <- [tracker(opts).add_blocked_by(blocker, child.id)], do: "the link to #{blocker} (#{inspect(reason)})"
    promoted = TransitionGuard.perform(child.id, :breakdown_promote, %{repo_key: child.repo, issue_identifier: child.identifier}, tracker: tracker(opts))
    failed = linked ++ for({:error, reason} <- [promoted], do: "its move to #{@todo} (#{inspect(reason)})")

    if failed != [] do
      text = "Symphony added #{child.identifier} but could not make #{Enum.join(failed, " or ")}. Check it by hand: in #{@backlog} it holds this ticket."
      note(repo_key, issue.id, text, "tree.start_failed:#{child.id}")
    end

    :ok
  end

  # What the Conductor of `ctx.issue` did to the sub-ticket `child`, on the sub-ticket's own record.
  defp intervene(child, action, reason, %{run_id: run_id} = ctx) do
    payload = %{action: action, reason: reason, by: by(ctx), target: child.identifier}

    case TicketEvents.record(child.repo, child.id, "conductor.intervention", payload, idempotency: "conductor.intervention:#{run_id}:#{action}") do
      {:ok, _event} -> :ok
      {:error, why} -> Logger.warning("Could not record conductor.intervention on #{child.identifier}: #{inspect(why)}")
    end
  end

  defp rounds_question(made, titles) do
    %{
      title: "The final check still finds work after #{made} rounds",
      question: "The final check wants to add to this ticket once more: #{Facts.fit(titles, 600)}. It already added sub-tickets #{made} times. Allow one more round?",
      why: "After #{made} rounds of added sub-tickets a person decides whether the ticket keeps growing.",
      if_unanswered: "The ticket stays paused in the waiting state and nothing more is added.",
      recommendation_reason: "The final check names work the plan's outcomes still need.",
      options: [
        %{label: "Allow one more round", effect: "The final check runs again and may add sub-tickets once more.", recommended: true, action: "continue"},
        %{label: "Close it as it is", effect: "The ticket moves to #{@done} without the added work.", recommended: false, action: "close"}
      ]
    }
  end

  # What Symphony asks when a final check ran and did not conclude for `why`: it names the checks
  # of the plan that are still open, and the ticket stays where it is until the person answers.
  defp stuck_question(issue_id, why) do
    open = Enum.map_join(TicketChecks.open(issue_id, []), "; ", &"#{&1.id} #{&1.statement}")
    open = if open == "", do: "", else: " Still open: #{Facts.fit(open, 600)}."

    %{
      title: "The final check could not close this ticket",
      question: "Every sub-ticket ended, but the final check did not close this ticket: #{Facts.fit(why, 600)}.#{open} Check again, or close it as it is?",
      why: "Only the final check closes a ticket with sub-tickets, and this one did not conclude.",
      if_unanswered: "The ticket stays in the waiting state and nothing more happens on it.",
      recommendation_reason: "Nothing says yet that the ticket does what was asked.",
      options: [
        %{label: "Check again", effect: "The final check runs once more.", recommended: true, action: "continue"},
        %{label: "Close it as it is", effect: "The ticket moves to #{@done} without a final check that passed.", recommended: false, action: "close"}
      ]
    }
  end

  @doc """
  Records that the person was asked about the final check, once the question holds the ticket:
  `:rounds`, whether it may add one more round, which lets one through once they answer; `:stuck`,
  what to do with a check that did not conclude, after which its failed tries count from zero.
  """
  @spec asked(String.t(), String.t(), :rounds | :stuck) :: :ok
  def asked(repo_key, issue_id, :rounds) do
    made = rounds(Facts.events(issue_id))
    note(repo_key, issue_id, "After #{made} rounds the final check still wanted to add sub-tickets, so Symphony asked the person.", "#{@asked_key}#{made}")
  end

  def asked(repo_key, issue_id, :stuck) do
    asked = keyed(Facts.events(issue_id), @stuck_key) + 1
    note(repo_key, issue_id, "The final check could not close this ticket, so Symphony asked the person.", "#{@stuck_key}#{asked}")
  end

  @doc """
  Looks at what a `final_check` turn left: `before` holds whether it paused the ticket (`held`),
  how many rounds were made when it started (`rounds`) and how the turn ended (`exit`). A turn that
  closed the ticket, paused it or made a round changed something. Any other did not finish and is
  counted, as a status note (see the module doc): the next poll tries once more, and after 2 in a
  row `{:ask, :stuck, question}` is answered, since the ticket never closes without its check.
  """
  @spec checked(String.t(), Issue.t(), map()) :: :ok | {:ask, :stuck, map()}
  def checked(repo_key, %Issue{id: issue_id}, %{held: held, rounds: before, exit: exit}) do
    events = Facts.events(issue_id)

    if held == :held or rounds(events) > before or match?(%{phase: @done}, RunStore.get_ticket_state(issue_id)) do
      :ok
    else
      try = tries(events) + 1
      key = "#{@final_try_key}#{keyed(events, @final_try_key) + 1}"

      if try < @final_tries do
        note(repo_key, issue_id, "The final check did not finish (#{exit}). Symphony tries once more.", key)
      else
        note(repo_key, issue_id, "The final check did not finish, #{try} times in a row (#{exit}). Symphony asks what to do.", key)
        {:ask, :stuck, stuck_question(issue_id, "the turn failed or its answer could not be read, #{try} times in a row")}
      end
    end
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
