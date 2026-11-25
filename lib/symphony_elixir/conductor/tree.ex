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

  A sub-ticket that waits `after` siblings is created in `Backlog`, put on Symphony's records, given
  a stored dependency (`:done`, `SymphonyElixir.RunStore.add_dependency/3`) on each of them, and only
  then moved to `Todo`, so no dispatch finds it before its dependencies; the `:depends_on` dispatch
  gate holds it until those siblings are done. No Linear blocker link is written. Each sub-ticket is
  recorded on the parent the moment it exists (a `ticket.filed`, `kind: split_off`, keyed by its
  identifier), and the identifiers are written back as a new version of the plan once the loop
  ends. A split that stops half way (3 of 5 created, or the process died before the plan was
  written) therefore creates only the missing ones when it runs again: an entry with no identifier
  takes the sub-ticket already filed from this ticket under its title, else a sub-ticket the ticket
  already has with exactly that title, before a new one is created. The dependencies are read from
  the records and the move to `Todo` from the tracker, and each is made where it is missing.

  Once every entry has its sub-ticket, Symphony's records take the new sub-tickets (an observation
  of the parent and of each, not a poll) before their dependencies are stored, and once they are
  started the parent moves to the waiting state
  (`groomed_split`), where it holds no run. The split runs again whenever a first run is about to
  start on a ticket whose plan is a split (`SymphonyElixir.Conductor.Grooming.split_due?/2`), so a
  split parent never gets a coding run.

  A split that fails is counted (`failed/3`, a status note under `grooming.split_try:<n>`): it is
  tried again at the next dispatch, and from the third failure on the person is asked each time.

  ## Waiting for the Conductor

  A turn the ticket is owed while no provider of `runs.conductor` can take a run (it is paused, or
  at its usage limit) waits, and the ticket says why (`waiting/4`): one status note per wait,
  "Waiting for the Conductor: ...". A wait ends when a Conductor turn runs on the ticket. A final
  check that has waited more than 30 minutes asks the person, once per wait: close the ticket on
  its sub-tickets, or keep waiting.

  ## A sub-ticket left in Backlog

  A sub-ticket Symphony created in `Backlog` whose dependency or move to `Todo` failed (`start/5`)
  would hold its parent for good. While the parent waits, each poll owes it one more try (`due/3`
  answers `:start`, `start_left/3`): the sub-ticket is read again, the dependencies it lacks are
  stored and it is
  moved to `Todo`. A try that fails is counted (a status note under
  `tree.start_try:<its id>:<n>`), and after 3 in a row the person is asked ("Try again" or
  cancel). One a person moved out of `Backlog` meanwhile is left alone.

  ## The bounds

  What the Conductor may create under a ticket is bounded (`room/1`), whatever asks for it (a
  split, a tree operation, a ticket a run's turn files): a ticket gets at most 20 sub-tickets
  over its whole life (`created/1` counts every one ever created under it), and a ticket 3
  levels below its root gets none (`depth/1`). A sub-ticket Symphony refuses is said on the ticket
  (a status note under `tree.limit:<n>`), the next turn reads it in its facts (`facts/2`, `limits`),
  and the person is asked once (`limit_ask/1`). A plan of shape `split` on a ticket that deep is
  recorded as `single`, with a note (`fit/3`). Each sub-ticket Symphony creates carries where it
  came from (`ticket.filed_from`), so it files no ticket of its own from a run's turn
  (`SymphonyElixir.Conductor.Filing`).

  ## The close of a groomed ticket

  A groomed ticket in the waiting state closes by one rule (`due/3`): its own pull request merged
  or it never had one, and none of its sub-tickets is left outside Done or Canceled (one in
  `Backlog` holds it). Then the Conductor's `final_check` turn is owed: it reads the whole tree and
  answers `done`, which moves the ticket to `Done` (`final_check_pass`) and records each check of
  its plan still open as proved by the sub-tickets that ended Done (`by: sub_tickets`, naming them),
  so a parent's facts read it as finished through them, or adds sub-tickets
  (`tree` operations of `op: add`), which is a round: the plan takes a new version whose `reason`
  starts with `Final check`, and those versions are the count of rounds (`rounds/1`). After
  `conductor.final_check_rounds` rounds Symphony refuses one more and asks the person instead
  (`apply/3` answers `{:ask, question}`); "Allow one more round" lets one through (`asked/2` records
  it, `round_limit/2` counts it), and "Close it as it is" moves the ticket to `Done`.

  ## Recalibration

  While sub-tickets are still open, each one that ends owes the parent a `sub_ticket_ended` turn
  (`due/3`, `seen/3`). That turn, like every other Conductor turn on a ticket with sub-tickets
  (`family?/1`), may change the tree with `tree` operations (`apply/3`): `add` a sub-ticket (in
  front of another one in the queue with `before`),
  `cancel` one that is not Done (the Director's cancel move: its run stops, its pull request
  closes), `rewrite` one (a new `ask.recorded` on it, `source: parent`; its working run is stopped
  first only with `stop: true`; a sub-ticket that already has a plan then writes it again in a
  Conductor turn of its own, `SymphonyElixir.Conductor.Message.recalibrate/3`), `stop` a
  sub-ticket's working run, `reorder` one among its siblings (the Director's queue move) and
  `depend`: set what one waits on among its siblings. Only sub-tickets that have not ended change;
  an operation that can't be carried out is said on the ticket (`not_done/5`). Each operation
  carried out is recorded on the sub-ticket it touched as a `conductor.intervention` (`added`,
  `canceled`, `replanned`, `stopped`, `reordered`, `rewired`) with its reason, and together they give the parent's plan a new version
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
  alias SymphonyElixir.{Config, DirectorMoves, DirectorQueue, Orchestrator, RepoTeams, RunStore, SubIssueWait}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{TicketChecks, TicketEvents, TicketObservation, TicketPlan, TicketState}
  alias SymphonyElixir.{Tracker, TransitionGuard}

  @urgent 1
  @todo "Todo"
  @backlog "Backlog"
  @split_tries 3
  @split_try_key "grooming.split_try:"
  @final_tries 2
  @final_try_key "final_check.try:"
  @asked_key "final_check.asked:"
  @stuck_key "final_check.stuck:"
  @waits_key "final_check.waits:"
  @round "Final check"
  @recalibration "Recalibration"
  @ended_key "tree.ended:"
  @done "Done"
  @written_fields [:event_id, :at, :version]
  # The bounds on what the Conductor creates under one ticket. They are constants, not settings:
  # they stop a tree that grows without end, and no repo needs its own.
  # How many sub-tickets a ticket may get over its whole life, from every source.
  @max_sub_tickets 20
  # How many levels below its root a ticket may be and still get sub-tickets of its own.
  @max_depth 3
  @limit_key "tree.limit:"
  @start_failed_key "tree.start_failed:"
  @start_try_key "tree.start_try:"
  @start_asked_key "tree.start_asked:"
  @started_key "tree.started:"
  @start_tries 3
  @wait_key "conductor.wait:"
  # What Symphony did not take from a Conductor turn's answer: `conductor.try:<junction>:<run_id>:<n>`.
  @try_key "conductor.try:"
  @wait_asked_key "conductor.wait_asked:"
  # How long a final check may wait on a provider before the person is asked, once per wait.
  @wait_ask_after_minutes 30
  @limit_asked_key "tree.limit_asked"

  @typedoc "What a waiting groomed ticket is owed (`due/3`)."
  @type owed :: :close | :final_check | :sub_ticket_ended | :start | nil

  @typedoc "What Symphony asked the person about a ticket's tree (`asked/3`)."
  @type asked :: :rounds | :stuck | :limit | {:start, String.t()} | {:waiting, pos_integer()}

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

  @doc "How many sub-tickets were ever created under the ticket `issue_id`: the ones recorded on it as filed, and the ones its plans name."
  @spec created(String.t()) :: non_neg_integer()
  def created(issue_id) when is_binary(issue_id), do: created_in(Facts.events(issue_id))

  defp created_in(events) do
    filed = for %{type: "ticket.filed", payload: %{identifier: identifier} = payload} <- events, Map.get(payload, :existing) != true, do: identifier
    planned = for version <- TicketPlan.versions(events), %{identifier: identifier} <- Map.get(version, :sub_tickets, []), is_binary(identifier), do: identifier
    length(Enum.uniq(filed ++ planned))
  end

  @doc "How many levels below its root the ticket `issue_id` is, by Symphony's records: 0 for a ticket with no parent."
  @spec depth(String.t()) :: non_neg_integer()
  def depth(issue_id) when is_binary(issue_id), do: depth(issue_id, 0)

  # No tree is read deeper than the bound, so records that name each other end the walk too.
  defp depth(_issue_id, @max_depth), do: @max_depth

  defp depth(issue_id, level) do
    case TicketPlan.parent_id(issue_id) do
      nil -> level
      parent_id -> depth(parent_id, level + 1)
    end
  end

  @doc """
  Whether the ticket `issue_id` may get one more sub-ticket (see **The bounds** in the module doc):
  `:ok`, or `{:error, why}` with the bound it reached, in plain words that follow "this ticket".
  """
  @spec room(String.t()) :: :ok | {:error, String.t()}
  def room(issue_id) when is_binary(issue_id) do
    cond do
      depth(issue_id) >= @max_depth -> {:error, "is #{@max_depth} levels below its root ticket, and a ticket that deep gets no sub-tickets"}
      created(issue_id) >= @max_sub_tickets -> {:error, "already got #{@max_sub_tickets} sub-tickets, the most one ticket may get"}
      true -> :ok
    end
  end

  @doc """
  `room/1` for the sub-ticket `title` about to be created under `repo_key`'s ticket `issue_id`: a
  refusal is said on the ticket, as a status note, so its next turn reads it and the person is asked.
  """
  @spec room(String.t() | nil, String.t(), String.t()) :: :ok | {:error, String.t()}
  def room(repo_key, issue_id, title) do
    with {:error, why} <- room(issue_id) do
      refused = keyed(Facts.events(issue_id), @limit_key) + 1
      note(repo_key, issue_id, "Symphony did not create the sub-ticket #{inspect(title)}: this ticket #{why}.", "#{@limit_key}#{refused}")
      {:error, "this ticket #{why}"}
    end
  end

  @doc """
  The plan Grooming answered for the ticket `issue_id`, as Symphony records it: a plan of shape
  `split` on a ticket that may get no sub-tickets because of its depth is recorded as `single`,
  without its `sub_tickets`, and a status note on the ticket says so. Any other plan is unchanged.
  """
  @spec fit(String.t() | nil, String.t(), map()) :: map()
  def fit(repo_key, issue_id, %{shape: "split"} = plan) do
    if depth(issue_id) >= @max_depth do
      text = "The plan split this ticket into sub-tickets, but it is #{@max_depth} levels below its root ticket, so it is built as one ticket."
      note(repo_key, issue_id, text, "tree.single")
      plan |> Map.delete(:sub_tickets) |> Map.put(:shape, "single")
    else
      plan
    end
  end

  def fit(_repo_key, _issue_id, plan), do: plan

  @doc """
  The turn's `facts` with the bounds of the groomed ticket `issue_id` (`limits`): how many
  sub-tickets it got and may get, how deep it is and how deep a ticket with sub-tickets may be, the
  rule in words, and each sub-ticket Symphony refused (`refused`). Facts of a ticket with no plan
  are unchanged, but when its depth already rules a split out.
  """
  @spec facts(map(), String.t()) :: map()
  def facts(facts, issue_id) when is_binary(issue_id) do
    events = Facts.events(issue_id)
    level = depth(issue_id)

    if TicketPlan.groomed?(events) or level >= @max_depth do
      limits = %{
        sub_tickets: %{created: created_in(events), max: @max_sub_tickets},
        depth: %{level: level, max: @max_depth},
        rule: "A ticket gets at most #{@max_sub_tickets} sub-tickets over its whole life, and a ticket #{@max_depth} levels below its root gets none: it is never split. Symphony refuses any more.",
        refused: for(%{payload: %{text: text}} = event <- events, keyed?(event, @limit_key), do: text)
      }

      Map.put(facts, :limits, limits)
    else
      facts
    end
  end

  @doc """
  The question Symphony asks the person, once per ticket, after it refused a sub-ticket on the
  ticket `issue_id` (`{:ask, :limit, question}`); `:ok` when it refused none, or already asked.
  """
  @spec limit_ask(String.t()) :: :ok | {:ask, :limit, map()}
  def limit_ask(issue_id) when is_binary(issue_id) do
    events = Facts.events(issue_id)

    case for(%{payload: %{text: text}} = event <- events, keyed?(event, @limit_key), do: text) do
      [_ | _] = refused -> if keyed(events, @limit_asked_key) == 0, do: {:ask, :limit, limit_question(List.last(refused))}, else: :ok
      [] -> :ok
    end
  end

  defp limit_question(refused) do
    %{
      title: "This ticket may get no more sub-tickets",
      question: "#{Facts.fit(refused, 700)} Go on without that sub-ticket, or cancel this ticket?",
      why: "The number of sub-tickets under one ticket, and how deep they go, is bounded, so a ticket cannot grow without end.",
      if_unanswered: "The ticket stays paused, and the work the sub-ticket was for is not done.",
      recommendation_reason: "The rest of the ticket's work is not affected.",
      options: [
        %{label: "Go on without it", effect: "The ticket continues, and the Conductor is told it may add no more.", recommended: true, action: "continue"},
        %{label: "Cancel the ticket", effect: "The ticket is cancelled.", recommended: false, action: "cancel"}
      ]
    }
  end

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
         :ok <- observe([issue_id | Enum.map(children, & &1.id)], entries, repo_key, opts),
         :ok <- link(entries, children),
         :ok <- promote(entries, children, repo_key, opts),
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

  # Each entry with no sub-ticket yet gets one, in order; the first that fails stops the rest. A
  # sub-ticket an earlier, interrupted split left under the ticket is taken instead of a second one.
  defp create_missing(entries, repo_key, issue, opts) do
    with true <- Enum.any?(entries, &(not is_binary(Map.get(&1, :identifier)))),
         {:ok, left} <- left_behind(issue, opts) do
      taken = for %{identifier: identifier} <- entries, is_binary(identifier), do: identifier
      {entries, failure, _left} = Enum.reduce(entries, {[], nil, Enum.reject(left, &(&1.identifier in taken))}, &create_or_adopt(&1, &2, {repo_key, issue, opts}))
      {entries, failure}
    else
      false -> {entries, nil}
      {:error, why} -> {entries, {:error, why}}
    end
  end

  defp create_or_adopt(%{identifier: identifier} = entry, {done, failure, left}, _context) when is_binary(identifier), do: {done ++ [entry], failure, left}

  defp create_or_adopt(entry, {done, nil, left}, {repo_key, issue, opts}) do
    case Enum.find(left, &(&1.title == entry.title)) do
      %{identifier: identifier} = adopted ->
        Logger.info("Took the sub-ticket #{identifier} an earlier split left for #{entry.key} #{context(issue, repo_key)}")
        # One the split created and never recorded is Symphony's all the same: it is asked, given its
        # dependencies and started.
        if TicketPlan.ask(adopted.id) == [], do: asked(Map.get(entry, :repo) || repo_key, adopted, entry.ask, issue, opts)
        {done ++ [Map.put(entry, :identifier, identifier)], nil, left -- [adopted]}

      nil ->
        case create(repo_key, issue, entry, opts) do
          {:ok, child} -> {done ++ [Map.put(entry, :identifier, child.identifier)], nil, left}
          {:error, why} -> {done ++ [entry], {:error, "sub-ticket #{entry.key} could not be created: #{why}"}, left}
        end
    end
  end

  defp create_or_adopt(entry, {done, failure, left}, _context), do: {done ++ [entry], failure, left}

  # The sub-tickets the tracker lists under the ticket, each with the title a plan entry would
  # name it by: the one it was filed under from this ticket (`ticket.filed`), else its own.
  defp left_behind(%Issue{id: issue_id}, opts) do
    with {:ok, %Issue{} = parent} <- read_one(issue_id, opts),
         [_ | _] = ids <- sub_issue_ids(parent),
         {:ok, children} <- tracker(opts).fetch_issue_states_by_ids(ids) do
      filed = filed_titles(issue_id)
      {:ok, Enum.map(children, &%{id: &1.id, identifier: &1.identifier, title: Map.get(filed, &1.identifier, &1.title)})}
    else
      [] -> {:ok, []}
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, reason} -> {:error, "the ticket's sub-tickets could not be read: #{inspect(reason)}"}
    end
  end

  # Sub-tickets a read did not carry (`:unknown`) are none to take.
  defp sub_issue_ids(%Issue{sub_issues: sub_issues}), do: for(%{id: id} <- List.wrap(is_list(sub_issues) && sub_issues), is_binary(id), do: id)

  # The title each sub-ticket Symphony filed from the ticket was filed under, by its identifier.
  defp filed_titles(issue_id) do
    for %{type: "ticket.filed", payload: %{identifier: identifier, title: title} = payload} <- Facts.events(issue_id),
        not is_map_key(payload, :by),
        into: %{},
        do: {identifier, title}
  end

  @doc """
  Creates the sub-ticket `entry` describes (its `title`, its `ask`, the sibling keys it waits
  `after` and optionally its `repo`) under `issue`, and records its ask on it. It is created in
  `Todo`, or in `Backlog` when it waits `after` a sibling, whose dependency must be stored before it is
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

    with :ok <- if(family == %{}, do: :ok, else: room(repo_key, parent_id, entry.title)),
         {:ok, team, project} <- target(issue, repo_key, repo, opts),
         attrs = %{title: entry.title, description: entry.ask, priority: @urgent, state: first_state(entry), team: team, project: project},
         {:ok, %{id: id, identifier: identifier}} <- tracker(opts).create_issue(attrs |> Map.put(:assignee_id, issue.assignee_id) |> Map.merge(family)) do
      child = %{id: id, identifier: identifier, repo: repo}
      if family != %{}, do: filed(repo_key, issue, child, entry)
      asked(repo, child, entry.ask, issue, opts)
      {:ok, child}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp asked(repo, %{id: id, identifier: identifier}, ask, %Issue{} = issue, opts) do
    from = issue.identifier || issue.id
    asked = TicketPlan.record_ask(repo, id, ask, Keyword.get(opts, :ask, source: "parent", from: from, idempotency: "ask.recorded:parent"))
    with {:error, reason} <- asked, do: Logger.warning("Could not record the ask of sub-ticket #{identifier} of #{from}: #{inspect(reason)}")
  end

  # The sub-ticket is on its parent's record the moment it exists, so a split or an operation that
  # stops right after never creates it a second time.
  defp filed(repo_key, %Issue{id: parent_id} = parent, child, entry) do
    payload = %{identifier: child.identifier, kind: "split_off", title: String.slice(entry.title, 0, 300), repo: child.repo}
    from = %{from: parent.identifier || parent_id, by: "conductor", kind: "split_off"}

    # Where it came from is on the sub-ticket too, so it files no ticket of its own from a run's turn.
    for {key, issue_id, type, payload} <- [{repo_key, parent_id, "ticket.filed", payload}, {child.repo, child.id, "ticket.filed_from", from}],
        {:error, reason} <- [TicketEvents.record(key, issue_id, type, payload)] do
      Logger.warning("Could not record #{type} for the sub-ticket #{child.identifier} of issue_id=#{parent_id}: #{inspect(reason)}")
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

  # Each sub-ticket depends on the siblings it waits after; a dependency its record already holds is kept.
  defp link(entries, children) do
    by_key = Map.new(entries, &{&1.key, &1.identifier})
    by_identifier = Map.new(children, &{&1.identifier, &1})

    wanted =
      for entry <- entries,
          key <- Map.get(entry, :after, []),
          %Issue{} = child <- [by_identifier[entry.identifier]],
          %Issue{} = blocker <- [by_identifier[by_key[key]]],
          not depends_on?(child.id, blocker.id),
          do: {blocker, child}

    Enum.reduce_while(wanted, :ok, fn {blocker, child}, :ok ->
      case RunStore.add_dependency(child.id, blocker.id, :done) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{child.identifier} could not be made to depend on #{blocker.identifier}: #{inspect(reason)}"}}
      end
    end)
  end

  # Whether the record of `issue_id` already depends on `on_issue_id`.
  defp depends_on?(issue_id, on_issue_id) do
    case RunStore.get_ticket_state(issue_id) do
      %{} = record -> Enum.any?(TicketState.normalize(record).depends_on, &(&1.issue_id == on_issue_id))
      _none -> false
    end
  end

  # A sub-ticket Symphony created in Backlog starts once its dependencies exist; one a person keeps there stays.
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
  such turn looked at yet, `seen/3`), `:start` (no turn: a sub-ticket Symphony left in `Backlog` is
  given its dependencies and started, `start_left/3`), or nil while it waits: a sub-ticket is open, its sub-tickets
  were not read (`:unknown`), or it has a pull request that did not merge, which is a person's to
  settle. `opts`: `conductor` (the `conductor`
  settings, default `Config.conductor_settings/0`) and `events` (the ticket's, default its record's,
  read with `read`, `Facts.read_events/1`; while that read fails nothing is owed).
  """
  @spec due(Issue.t() | term(), Enumerable.t(String.t()), keyword()) :: owed()
  def due(%Issue{id: issue_id, sub_issues: sub_issues} = issue, terminal_states, opts)
      when is_binary(issue_id) and is_list(sub_issues) do
    settings = Keyword.get_lazy(opts, :conductor, &Config.conductor_settings/0)

    if Issue.open_sub_issues(issue, terminal_states) == [],
      do: due_ended(issue, settings),
      else: due_open(issue, terminal_states, settings, read_events(issue_id, opts))
  end

  def due(_issue, _terminal_states, _opts), do: nil

  defp read_events(issue_id, opts) do
    with :error <- Keyword.fetch(opts, :events), do: Keyword.get(opts, :read, &Facts.read_events/1).(issue_id)
  end

  @doc "`due/3` with the `conductor` settings and the ticket's events as they are now."
  @spec due(Issue.t() | term(), Enumerable.t(String.t())) :: owed()
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

  # A read of the events that failed owes nothing: every ended sub-ticket would look unseen.
  defp due_open(_issue, _terminal_states, _settings, {:error, _reason}), do: nil

  defp due_open(issue, terminal_states, settings, {:ok, events}) do
    cond do
      turn?(settings, "sub_ticket_ended") and unseen(issue, terminal_states, events) != [] -> :sub_ticket_ended
      left(issue, events) != [] -> :start
      true -> nil
    end
  end

  # The sub-tickets Symphony created and could not start, which the tracker still shows in Backlog.
  defp left(%Issue{sub_issues: sub_issues}, events) do
    failed = for %{type: "note", idempotency: @start_failed_key <> id} <- events, into: MapSet.new(), do: id
    started = for %{type: "note", idempotency: @started_key <> id} <- events, into: MapSet.new(), do: id

    for %{id: id, state: state} = sub <- sub_issues,
        MapSet.member?(failed, id) and not MapSet.member?(started, id),
        is_binary(state) and normalize(state) == "backlog",
        do: sub
  end

  @doc """
  Tries once more to start each sub-ticket of `issue` that Symphony created and left in `Backlog`
  (see the module doc): it is read again, given a stored dependency on what it waits on where its
  record lacks one (the sub-tickets its plan entry waits `after`; its parent, for one a run's turn
  filed to do after it) and moved to `Todo`. `:ok`, or `{:ask, {:start, id}, question}` once the same
  sub-ticket failed #{@start_tries} times in a row: the person decides. `opts`: `tracker`.
  """
  @spec start_left(String.t() | nil, Issue.t(), keyword()) :: :ok | {:ask, {:start, String.t()}, map()}
  def start_left(repo_key, %Issue{id: issue_id} = issue, opts \\ []) do
    events = Facts.events(issue_id)
    entries = Map.get(TicketPlan.current(events) || %{}, :sub_tickets, [])

    issue
    |> left(events)
    |> Enum.map(&retry(&1, blockers(&1, entries, issue), {repo_key, issue, events}, opts))
    |> Enum.find(:ok, &(&1 != :ok))
  end

  # What the sub-ticket waits on, each by id and identifier: the siblings its entry waits after, as
  # the parent's sub-tickets name them, or the parent itself.
  defp blockers(%{identifier: identifier}, entries, %Issue{} = parent) do
    by_key = for %{key: key, identifier: named} <- entries, into: %{}, do: {key, named}
    ids = for %{id: id, identifier: named} <- parent.sub_issues, into: %{}, do: {named, id}

    case Enum.find(entries, &(Map.get(&1, :identifier) == identifier)) do
      %{after: waits} -> for key <- waits, blocker = by_key[key], id = ids[blocker], do: %{id: id, identifier: blocker}
      nil -> [%{id: parent.id, identifier: parent.identifier}]
    end
  end

  defp retry(%{id: id, identifier: identifier}, blockers, {repo_key, %Issue{id: parent_id}, events}, opts) do
    child = %{id: id, identifier: identifier, repo: recorded_repo(id) || repo_key}

    case start_again(child, blockers, opts) do
      :ok ->
        note(repo_key, parent_id, "Symphony started #{identifier}, which it had left in #{@backlog}, once its dependencies were stored.", @started_key <> id)

      :moved ->
        :ok

      {:error, why} ->
        prefix = "#{@start_try_key}#{id}:"
        tries = events |> Enum.reverse() |> Enum.take_while(&(not keyed?(&1, @start_asked_key <> id))) |> Enum.count(&keyed?(&1, prefix))
        note(repo_key, parent_id, "Symphony could not start #{identifier} again: #{why}.", "#{prefix}#{keyed(events, prefix) + 1}")
        if tries + 1 < @start_tries, do: :ok, else: {:ask, {:start, id}, start_question(identifier, why)}
    end
  end

  # A dependency its record already holds is kept; a sub-ticket no longer in Backlog is a person's now.
  defp start_again(child, blockers, opts) do
    case tracker(opts).fetch_issue_states_by_ids([child.id]) do
      {:ok, [%Issue{state: state} | _rest]} ->
        if is_binary(state) and normalize(state) == "backlog",
          do: link_and_promote(child, Enum.reject(blockers, &depends_on?(child.id, &1.id)), opts),
          else: :moved

      {:ok, []} ->
        {:error, "the tracker does not return it"}

      {:error, reason} ->
        {:error, "it could not be read (#{inspect(reason)})"}
    end
  end

  defp start_question(identifier, why) do
    %{
      title: "A sub-ticket could not be started",
      question:
        "Symphony created #{identifier} under this ticket and could not start it, #{@start_tries} times: #{Facts.fit(why, 400)}. It waits in #{@backlog}, and this ticket waits for it. Try again?",
      why: "A sub-ticket gets its dependencies on what it waits on before it may start, and that step keeps failing.",
      if_unanswered: "The sub-ticket stays in #{@backlog} and this ticket stays open.",
      recommendation_reason: "The step may go through now, and nothing else is wrong with the ticket.",
      options: [
        %{label: "Try again", effect: "Symphony stores the sub-ticket's dependencies and moves it to #{@todo} once more.", recommended: true, action: "continue"},
        %{label: "Cancel this ticket", effect: "This ticket is cancelled.", recommended: false, action: "cancel"}
      ]
    }
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
  Whether the ticket `issue_id` has sub-tickets, as its record lists them: then every Conductor turn
  on it but Grooming reads the one form that changes them (`SymphonyElixir.Conductor.Answer`'s `tree`).
  """
  @spec family?(String.t()) :: boolean()
  def family?(issue_id) when is_binary(issue_id), do: known_children(issue_id) != %{}

  @doc """
  The turn's `answer` with the sub-tickets its `plan` lists (a plan written outside Grooming, whose
  sub-tickets Symphony keeps, `Answer`'s `sub_tickets: :kept`) read as the same intent as `tree`
  operations on the ticket `issue_id`, put after the answer's own, and the list taken off the plan:

    * an entry with no `identifier` is an `add` (its `key` is the name later operations use);
    * an entry with an `identifier` and an `ask` that differs from that sub-ticket's newest is a
      `rewrite`; one with no `ask`, or the same, keeps the sub-ticket as it is;
    * an entry that gives `after` sets what it waits on (`depend`, when that changes it): the
      identifiers or keys of other entries;
    * the order of the entries is the order wanted among the sub-tickets: when the entries' order
      differs from the queue's, each is put in front of the next (`reorder`).

  A sub-ticket the list leaves out is kept: only a `cancel` operation cancels one. Each operation's
  reason is the plan's. An answer with no such list is unchanged.
  """
  @spec intent(map(), String.t()) :: map()
  def intent(%{plan: %{sub_tickets: [_ | _] = entries} = plan} = answer, issue_id) when is_binary(issue_id) do
    reason = Map.get(plan, :reason) || "The plan's sub-tickets say so."
    terminal = issue_id |> recorded_repo() |> terminal_states()
    known = known_children(issue_id)
    open = for {identifier, %{state: state}} <- known, normalize(state) not in terminal, into: MapSet.new(), do: identifier
    names = Map.new(entries, &{&1.key, Map.get(&1, :identifier) || &1.key})
    named = fn waits -> Enum.map(waits, &Map.get(names, &1, &1)) end

    operations =
      Enum.flat_map(entries, &adds(&1, named, reason)) ++
        Enum.flat_map(entries, &rewrites(&1, known, reason)) ++
        Enum.flat_map(entries, &depends(&1, named, {known, open}, reason)) ++
        reorders(entries, {known, open}, reason)

    %{answer | plan: Map.delete(plan, :sub_tickets), tree: answer.tree ++ operations}
  end

  def intent(%{plan: %{} = plan} = answer, _issue_id), do: %{answer | plan: Map.delete(plan, :sub_tickets)}
  def intent(answer, _issue_id), do: answer

  defp adds(%{identifier: _identifier}, _named, _reason), do: []

  defp adds(entry, named, reason) do
    add = %{op: "add", title: entry.title, ask: entry.ask, after: named.(Map.get(entry, :after, [])), key: entry.key, reason: reason}
    [if(Map.has_key?(entry, :repo), do: Map.put(add, :repo, entry.repo), else: add)]
  end

  defp rewrites(%{identifier: identifier, ask: ask}, known, reason) do
    current = with %{id: id} <- Map.get(known, identifier), %{text: text} <- List.last(TicketPlan.ask(id)), do: text
    if current == ask, do: [], else: [%{op: "rewrite", ticket: identifier, ask: ask, stop: false, reason: reason}]
  end

  defp rewrites(_entry, _known, _reason), do: []

  # What an open sub-ticket waits on, when the entry gives it and it differs from what is stored.
  defp depends(%{identifier: identifier, after: waits}, named, {known, open}, reason) do
    wanted = named.(waits)

    cond do
      not MapSet.member?(open, identifier) -> []
      Enum.sort(sibling_dependencies(known[identifier].id, known)) == Enum.sort(wanted) -> []
      true -> [%{op: "depend", ticket: identifier, after: wanted, reason: reason}]
    end
  end

  defp depends(_entry, _named, _known, _reason), do: []

  # The sub-tickets `id` depends on, among the ticket's sub-tickets `known`, by identifier.
  defp sibling_dependencies(id, known) do
    ids = Map.new(known, fn {identifier, %{id: sibling}} -> {sibling, identifier} end)
    for %{issue_id: on} <- dependencies(id), Map.has_key?(ids, on), do: ids[on]
  end

  defp dependencies(issue_id), do: List.wrap(with(%{} = record <- RunStore.get_ticket_state(issue_id), do: TicketState.normalize(record).depends_on))

  # The open sub-tickets and the new ones, in the entries' order: when it is not the queue's, or a
  # new one is among them, each is put in front of the next one.
  defp reorders(entries, {known, open}, reason) do
    names = for entry <- entries, name = Map.get(entry, :identifier, entry.key), not Map.has_key?(entry, :identifier) or MapSet.member?(open, name), do: name
    new? = Enum.any?(entries, &(not Map.has_key?(&1, :identifier)))
    queued = names |> Enum.filter(&MapSet.member?(open, &1)) |> Enum.sort_by(&(sort_key(known[&1].id) || ""))

    if length(names) < 2 or (not new? and queued == names) do
      []
    else
      for [ticket, before] <- names |> Enum.chunk_every(2, 1, :discard) |> Enum.reverse(),
          do: %{op: "reorder", ticket: ticket, before: before, reason: reason}
    end
  end

  defp sort_key(issue_id), do: with(%{} = record <- RunStore.get_ticket_state(issue_id), do: Map.get(record, :sort_key))

  @doc """
  Carries out what a turn on the ticket answered about its tree (`answer`'s `done` and `tree`).
  `ctx` holds the `issue`, its `repo_key`, the turn's `run_id` and `junction`, and the `conductor`
  settings. Every turn on a ticket with sub-tickets comes here, whatever its junction, and every
  operation is carried out, in order (see the module doc), on the sub-tickets that have not ended.

  At `final_check` the operations other than `add` are carried out first; then `done` with nothing
  to add moves the ticket to `Done`, once a fresh read of its sub-tickets shows none open (one added
  meanwhile keeps it waiting, with a note); sub-tickets to add are a round, made while one is left
  (`round_limit/2`), else `{:ask, :rounds, question}` is answered and nothing is added: the person
  decides. A check that concluded nothing (not done with nothing carried out, no sub-ticket it
  wanted could be created, or the move to `Done` failed) answers `{:ask, :stuck, question}`: the
  ticket never closes on such a check.

  An operation that can't be carried out (the ticket it names is not a sub-ticket of this one, or it
  ended, or the step failed) is left out, and why is said on the ticket (`not_done/5`), so the
  person and the next turn read it.

  `opts`: as `split/3`'s, and `cancel` (`(identifier, reason -> {:ok, term} | {:error, term})`,
  default the Director's cancel move), `stop` (`(identifier -> {:ok, %{stopped: boolean}} | term)`,
  default `SymphonyElixir.Orchestrator.stop_running/1`), `reorder` (`(identifier, target -> {:ok,
  term} | {:error, term})`, default the Director's queue move, `SymphonyElixir.DirectorQueue.move/3`)
  and `recalibrate` (`(issue_id, ask event -> term)`, what a `rewrite` starts on the sub-ticket).
  """
  @spec apply(map(), map(), keyword()) :: :ok | {:ask, :rounds | :stuck, map()}
  def apply(%{done: done, tree: operations}, %{junction: "final_check", issue: %Issue{id: issue_id} = issue} = ctx, opts) do
    {adds, others} = Enum.split_with(operations, &(&1.op == "add"))
    carried = carry_out(others, @recalibration, ctx, opts)

    cond do
      adds == [] and done -> pass(ctx.repo_key, issue, opts)
      adds == [] and carried > 0 -> :ok
      adds == [] -> {:ask, :stuck, stuck_question(issue_id, "it answered that the ticket is not done, and added no sub-ticket")}
      true -> next_round(adds, ctx, opts)
    end
  end

  def apply(%{tree: operations}, ctx, opts) do
    _carried = carry_out(operations, @recalibration, ctx, opts)
    :ok
  end

  # A final check's adds make the next round, within the rounds' limit.
  defp next_round(adds, %{issue: %Issue{id: issue_id}} = ctx, opts) do
    events = Facts.events(issue_id)
    made = rounds(events)
    titles = Enum.map_join(adds, "; ", & &1.title)

    cond do
      made >= round_limit(events, ctx.conductor) -> {:ask, :rounds, rounds_question(made, titles)}
      carry_out(adds, @round, ctx, opts) > 0 -> :ok
      # A bound refused them and the person was not asked about it yet: that question comes first.
      limit_ask(issue_id) != :ok -> :ok
      true -> {:ask, :stuck, stuck_question(issue_id, "none of the sub-tickets it wanted to add could be created (#{titles})")}
    end
  end

  @doc """
  Says on the ticket `issue_id` each thing Symphony did not take from the Conductor's turn `run_id`
  at `junction` (`whys`, in plain words: an operation left out of the answer, or one that could not
  be carried out), one status note each under `conductor.try:<junction>:<run_id>:<n>`. The next
  turn reads them in its facts (`earlier_tries`), and the turn's reply names them (`not_done/2`).
  Always `:ok`.
  """
  @spec not_done(String.t(), String.t(), String.t(), String.t(), [String.t()]) :: :ok
  def not_done(repo_key, issue_id, junction, run_id, whys) do
    taken = Enum.count(Facts.events(issue_id), &keyed?(&1, "#{@try_key}#{junction}:#{run_id}:"))

    whys
    |> Enum.with_index(taken + 1)
    |> Enum.each(fn {why, n} -> note(repo_key, issue_id, Facts.fit("Symphony did not carry out part of the Conductor's answer: #{why}.", 4_000), "#{@try_key}#{junction}:#{run_id}:#{n}") end)
  end

  @doc "What Symphony did not take from the Conductor's turn `run_id` on the ticket `issue_id` (`not_done/5`), oldest first."
  @spec not_done(String.t(), String.t()) :: [String.t()]
  def not_done(issue_id, run_id) do
    for %{type: "note", idempotency: key, payload: %{text: text}} <- Facts.events(issue_id),
        is_binary(key) and String.starts_with?(key, @try_key) and String.contains?(key, ":#{run_id}:"),
        do: text |> String.replace_prefix("Symphony did not carry out part of the Conductor's answer: ", "") |> String.replace_suffix(".", "")
  end

  # The ticket's sub-tickets are read again first: one added since the turn read them (no other
  # turn can add one meanwhile, but a person or a run can) keeps the ticket open, and it waits on it.
  defp pass(repo_key, %Issue{id: issue_id} = issue, opts) do
    case open_now(issue_id, repo_key, opts) do
      {:ok, [], fresh} ->
        done(repo_key, issue, fresh, opts)

      {:ok, open, _fresh} ->
        names = Enum.map_join(open, ", ", &(Map.get(&1, :identifier) || "one without an identifier"))
        waits = keyed(Facts.events(issue_id), @waits_key) + 1
        note(repo_key, issue_id, "The final check passed, but #{names} was added meanwhile and has not ended. This ticket waits for it.", "#{@waits_key}#{waits}")

      {:error, why} ->
        Logger.warning("The final check passed, but the ticket's sub-tickets could not be read again #{context(issue, repo_key)}: #{why}")
        {:ask, :stuck, stuck_question(issue_id, "it passed, but Symphony could not read the sub-tickets again to make sure none was added")}
    end
  end

  defp open_now(issue_id, repo_key, opts) do
    with {:ok, fresh} <- read_one(issue_id, opts), do: {:ok, Issue.open_sub_issues(fresh, terminal_states(repo_key)), fresh}
  end

  defp done(repo_key, %Issue{id: issue_id} = issue, %Issue{} = fresh, opts) do
    ctx = %{repo_key: repo_key, issue_identifier: issue.identifier}

    case TransitionGuard.perform(issue_id, :final_check_pass, ctx, tracker: tracker(opts)) do
      :ok ->
        _ = RunStore.delete_merged_wait(issue_id)
        prove_by_sub_tickets(repo_key, issue, fresh)
        note(repo_key, issue_id, "The final check passed: every sub-ticket ended and the plan's outcomes hold. This ticket is #{@done}.", "final_check.passed")
        Logger.info("Moved a groomed ticket to #{@done}: its final check passed #{context(issue, repo_key)}")

      {:error, reason} ->
        Logger.warning("The final check passed, but the ticket could not be moved to #{@done} #{context(issue, repo_key)}: #{inspect(reason)}")
        {:ask, :stuck, stuck_question(issue_id, "it passed, but the ticket could not be moved to #{@done}")}
    end
  end

  # The ticket finished through its sub-tickets: its final check passed on them, so each check of
  # its plan still open is proved by the sub-tickets that ended Done, named in the proof. A waived
  # check stays waived; a ticket whose sub-tickets were all canceled proves nothing this way.
  defp prove_by_sub_tickets(repo_key, %Issue{id: issue_id} = issue, %Issue{sub_issues: sub_issues}) do
    case for(%{identifier: identifier, state: state} <- List.wrap(sub_issues), is_binary(identifier) and done_state?(state), do: identifier) do
      [] ->
        :ok

      names ->
        details = "The final check passed on its sub-tickets #{Enum.join(names, ", ")}, which ended Done."

        proved = for %{id: check_id} <- TicketChecks.open(issue_id), do: TicketChecks.prove(repo_key, issue_id, %{check_id: check_id, by: "sub_tickets", details: details})
        Logger.info("Recorded #{length(proved)} open check(s) as proved by the sub-tickets #{context(issue, repo_key)} sub_tickets=#{Enum.join(names, ",")}")
    end
  end

  defp done_state?(state), do: is_binary(state) and String.downcase(String.trim(state)) == "done"

  # Each operation in order, on the plan's sub-ticket entries. What was carried out is written as a
  # new version of the plan, whose reason opens with `why` and holds each operation's own; what was
  # not is said on the ticket. Answers how many operations were carried out.
  defp carry_out([], _why, _ctx, _opts), do: 0

  defp carry_out(operations, why, %{issue: %Issue{id: issue_id} = issue, repo_key: repo_key} = ctx, opts) do
    ctx = Map.merge(ctx, %{issue: with_record(issue), known: known_children(issue_id), terminal: terminal_states(repo_key)})
    versions = TicketPlan.versions(issue_id)
    plan = List.last(versions) || %{}
    ctx = Map.put(ctx, :keys, for(version <- versions, entry <- Map.get(version, :sub_tickets, []), into: MapSet.new(), do: entry.key))
    start = %{entries: Map.get(plan, :sub_tickets, []), created: [], reasons: [], made: %{}, skipped: []}

    done =
      Enum.reduce(operations, start, fn operation, acc ->
        case operate(operation, acc, ctx, opts) do
          {:ok, acc} ->
            %{acc | reasons: acc.reasons ++ [operation.reason]}

          {:error, reason} ->
            on = operation[:ticket] || operation[:title]
            Logger.warning("The Conductor's #{operation.op} was not carried out #{context(issue, repo_key)} on=#{on}: #{reason}")
            %{acc | skipped: acc.skipped ++ ["its #{operation.op} of #{on} (#{reason})"]}
        end
      end)

    if done.reasons != [], do: record_version(plan, done, why, ctx, opts)
    if done.skipped != [], do: not_done(repo_key, issue_id, Map.get(ctx, :junction, "tree"), ctx.run_id, done.skipped)
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

  # A new sub-ticket: created, made to depend on what it waits on and started, under the next free
  # key, and put in front of the one it goes `before`. Later operations may name it by its `key`.
  defp operate(%{op: "add"} = operation, acc, %{issue: issue, repo_key: repo_key} = ctx, opts) do
    {entry, blockers} = entry(operation, acc, ctx)

    with {:ok, child} <- create(repo_key, issue, entry, opts) do
      # One whose dependencies could not be stored or that could not be moved stays added: it is said
      # on the parent and tried again.
      if blockers != [], do: start(child, blockers, issue, repo_key, opts)
      intervene(child, "added", operation.reason, ctx)
      listed = Map.merge(entry, %{identifier: child.identifier, after: plan_keys(Enum.map(blockers, & &1.identifier), acc.entries)})
      made = %{id: child.id, identifier: child.identifier, state: first_state(entry), repo: child.repo}
      aliases = [child.identifier | List.wrap(operation[:key])]
      acc = %{acc | entries: acc.entries ++ [listed], created: acc.created ++ [child], made: Map.merge(acc.made, Map.new(aliases, &{&1, made}))}
      {:ok, placed(acc, child, operation, ctx, opts)}
    end
  end

  # A sub-ticket that is no longer needed: cancelled as the Director cancels one, and off the plan.
  defp operate(%{op: "cancel", ticket: name} = operation, acc, ctx, opts) do
    cancel = Keyword.get(opts, :cancel, &DirectorMoves.move(:cancel, &1, %{note: &2}))

    with {:ok, child} <- open_child(name, acc, ctx),
         {:ok, _moved} <- cancel.(child.identifier, "The Conductor of #{by(ctx)} cancelled this sub-ticket: #{operation.reason}") do
      intervene(child, "canceled", operation.reason, ctx)
      {:ok, %{acc | entries: Enum.reject(acc.entries, &(Map.get(&1, :identifier) == child.identifier))}}
    else
      {:error, reason} -> {:error, text(reason)}
    end
  end

  # A sub-ticket asked for something else: its new ask is recorded on it, from this ticket, whatever
  # it was asked before.
  defp operate(%{op: "rewrite", ticket: name, ask: ask} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(name, acc, ctx),
         :ok <- if(operation.stop, do: stop(child, operation.reason, ctx, opts), else: :ok),
         {:ok, event} <- TicketPlan.record_ask(child.repo, child.id, ask, source: "parent", from: by(ctx)) do
      intervene(child, "replanned", operation.reason, ctx)
      # A sub-ticket that already has a plan writes it again for the new ask, in a turn of its own.
      Keyword.get(opts, :recalibrate, &Message.recalibrate/2).(child.id, event)
      {:ok, %{acc | entries: Enum.map(acc.entries, &if(Map.get(&1, :identifier) == child.identifier, do: Map.put(&1, :ask, ask), else: &1))}}
    else
      {:error, reason} -> {:error, text(reason)}
    end
  end

  defp operate(%{op: "stop", ticket: name} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(name, acc, ctx),
         :ok <- stop(child, operation.reason, ctx, opts) do
      {:ok, acc}
    end
  end

  # A sub-ticket put at another place among its siblings, through the Director's queue move, which
  # stays in this ticket's scope and refuses an order that breaks a dependency.
  defp operate(%{op: "reorder", ticket: name} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(name, acc, ctx),
         {:ok, target} <- place(operation, acc, ctx),
         :ok <- tracked(child, target, acc, opts),
         :ok <- reorder(child, target, opts) do
      intervene(child, "reordered", operation.reason, ctx)
      {:ok, %{acc | entries: reordered(acc.entries, child.identifier, target)}}
    end
  end

  # What a sub-ticket waits on among its siblings, set to the list given: each dependency it lacks is
  # stored, each one on a sibling it no longer lists is removed, and one that would close a cycle is
  # refused. Its dependencies on tickets outside this one stay.
  defp operate(%{op: "depend", ticket: name, after: waits} = operation, acc, ctx, opts) do
    with {:ok, child} <- open_child(name, acc, ctx),
         {:ok, blockers} <- blockers_named(waits, child, acc, ctx),
         :ok <- tracked([child | for(%{identifier: identifier} <- blockers, %{} = made <- [Map.get(acc.made, identifier)], do: made)], opts),
         :ok <- rewire(child, blockers, acc, ctx) do
      intervene(child, "rewired", operation.reason, ctx)
      keys = plan_keys(Enum.map(blockers, & &1.identifier), acc.entries)
      {:ok, %{acc | entries: Enum.map(acc.entries, &if(Map.get(&1, :identifier) == child.identifier, do: Map.put(&1, :after, keys), else: &1))}}
    end
  end

  defp stop(child, reason, ctx, opts) do
    case Keyword.get(opts, :stop, &Orchestrator.stop_running/1).(child.identifier) do
      {:ok, %{stopped: true}} -> intervene(child, "stopped", reason, ctx)
      other -> {:error, "its run was not stopped (#{inspect(other)})"}
    end
  end

  # A sub-ticket just added goes in front of the one it names, once it is on Symphony's records; a
  # place that can't be taken leaves it added, at the end, and is said on the ticket.
  defp placed(acc, child, %{before: before}, ctx, opts) do
    with {:ok, target} <- place(%{before: before}, acc, ctx),
         :ok <- tracked(child, target, acc, opts),
         :ok <- reorder(child, target, opts) do
      %{acc | entries: reordered(acc.entries, child.identifier, target)}
    else
      {:error, reason} -> %{acc | skipped: acc.skipped ++ ["the place of #{child.identifier} in front of #{before} (#{text(reason)})"]}
    end
  end

  defp placed(acc, _child, _operation, _ctx, _opts), do: acc

  defp place(%{to: "first"}, _acc, _ctx), do: {:ok, :top}
  defp place(%{to: "last"}, _acc, _ctx), do: {:ok, :end}

  defp place(%{before: name}, acc, ctx) do
    case lookup(name, acc, ctx) do
      {:ok, %{identifier: identifier}} -> {:ok, {:before, identifier}}
      :error -> {:error, "#{name} is not a sub-ticket of this ticket"}
    end
  end

  # A queue move reads Symphony's records: a sub-ticket this turn added, moved or named as the
  # place, is put on them first.
  defp tracked(child, target, acc, opts) do
    neighbours = for {:before, identifier} <- [target], %{} = made <- [Map.get(acc.made, identifier)], do: made
    tracked([child | neighbours], opts)
  end

  defp tracked(children, opts), do: Enum.find_value(children, :ok, &with(:ok <- on_record(Map.take(&1, [:id, :identifier, :repo]), opts), do: nil))

  defp reorder(child, target, opts) do
    case Keyword.get(opts, :reorder, &DirectorQueue.move(&1, &2, [])).(child.identifier, target) do
      {:ok, _moved} -> :ok
      {:error, {_kind, why}} when is_binary(why) -> {:error, why}
      {:error, reason} -> {:error, text(reason)}
    end
  end

  # The plan's entries with the one `identifier` names moved where the queue move put it.
  defp reordered(entries, identifier, target) do
    case Enum.split_with(entries, &(Map.get(&1, :identifier) == identifier)) do
      {[moved], rest} -> List.insert_at(rest, entry_index(rest, target), moved)
      _not_listed -> entries
    end
  end

  defp entry_index(_rest, :top), do: 0
  defp entry_index(rest, :end), do: length(rest)
  defp entry_index(rest, {:before, identifier}), do: Enum.find_index(rest, &(Map.get(&1, :identifier) == identifier)) || length(rest)

  defp blockers_named(names, child, acc, ctx) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, found} ->
      case lookup(name, acc, ctx) do
        {:ok, %{identifier: identifier}} when identifier == child.identifier -> {:halt, {:error, "#{identifier} can't wait on itself"}}
        {:ok, %{id: id, identifier: identifier}} -> {:cont, {:ok, found ++ [%{id: id, identifier: identifier}]}}
        :error -> {:halt, {:error, "#{name} is not a sub-ticket of this ticket"}}
      end
    end)
  end

  # The dependencies it lacks are stored first; only once they all are, the ones it no longer lists go.
  defp rewire(child, blockers, acc, ctx) do
    siblings = MapSet.new(Map.values(ctx.known) ++ Map.values(acc.made), & &1.id)
    wanted = MapSet.new(blockers, & &1.id)
    current = for %{issue_id: on} <- dependencies(child.id), MapSet.member?(siblings, on), do: on

    with [] <- for(%{id: id, identifier: identifier} <- blockers, id not in current, {:error, reason} <- [RunStore.add_dependency(child.id, id, :done)], do: dependency_why(identifier, reason)),
         [] <- for(on <- current, not MapSet.member?(wanted, on), {:error, reason} <- [RunStore.remove_dependency(child.id, on)], do: inspect(reason)) do
      :ok
    else
      whys -> {:error, Enum.join(whys, "; ")}
    end
  end

  defp dependency_why(identifier, reason) do
    why = if reason == :dependency_cycle, do: "would make a cycle: #{identifier} already waits on it", else: "could not be stored (#{inspect(reason)})"
    "waiting on #{identifier} #{why}"
  end

  # The sub-ticket `name` names (its identifier, or the key of one this turn added), when it is
  # this ticket's and has not ended.
  defp open_child(name, acc, %{terminal: terminal, repo_key: repo_key} = ctx) do
    case lookup(name, acc, ctx) do
      :error ->
        {:error, "#{name} is not a sub-ticket of this ticket"}

      {:ok, %{id: id, identifier: identifier, state: state}} ->
        open_child(%{id: id, identifier: identifier, repo: recorded_repo(id) || repo_key}, state, terminal)
    end
  end

  defp open_child(child, state, terminal) do
    if normalize(state) in terminal, do: {:error, "#{child.identifier} already ended (#{state})"}, else: {:ok, child}
  end

  defp lookup(name, %{made: made}, %{known: known}) do
    case {Map.get(made, name), Map.get(known, name)} do
      {%{} = child, _known} -> {:ok, child}
      {nil, %{id: id, state: state}} -> {:ok, %{id: id, identifier: name, state: state}}
      {nil, nil} -> :error
    end
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

  # A plan entry for an added sub-ticket, under the next key no version of the plan ever used, and
  # the sub-tickets it waits on: the identifiers (or this turn's keys) of the ticket's sub-tickets
  # it names `after`; any other name is dropped.
  defp entry(operation, acc, %{keys: used} = ctx) do
    keys = MapSet.union(used, MapSet.new(acc.entries, & &1.key))
    key = Enum.find_value(Stream.iterate(1, &(&1 + 1)), &if(not MapSet.member?(keys, "s#{&1}"), do: "s#{&1}"))
    blockers = for name <- Map.get(operation, :after, []), {:ok, %{id: id, identifier: identifier}} <- [lookup(name, acc, ctx)], uniq: true, do: %{id: id, identifier: identifier}
    entry = operation |> Map.take([:title, :ask, :repo]) |> Map.merge(%{key: key, after: Enum.map(blockers, & &1.identifier)})
    {entry, blockers}
  end

  defp plan_keys(identifiers, entries), do: for(%{identifier: identifier, key: key} <- entries, identifier in identifiers, do: key)

  # The ticket's sub-tickets as its record lists them: each identifier with its id and state.
  defp known_children(issue_id) do
    record = RunStore.get_ticket_state(issue_id)

    for %{id: id, identifier: identifier} = sub <- List.wrap(is_map(record) && Map.get(record, :sub_issues)), into: %{} do
      {identifier, %{id: id, state: Map.get(sub, :state)}}
    end
  end

  @doc """
  Starts the sub-ticket `child` of `parent`, which Symphony created in `Backlog` because it waits
  on `blockers` (each its `id` and `identifier`): it is put on Symphony's records when it is not
  there yet, given a stored `:done` dependency on each of them (`SymphonyElixir.RunStore.add_dependency/3`,
  no Linear link) and only then moved to `Todo`, so no dispatch finds it before its dependencies.
  When one can't be stored it is not moved: it stays in `Backlog`, where no run starts on it. `:ok` once it is in `Todo`; `{:error, why}`, in plain
  words, when a step failed, which is also said on the parent (a status note under
  `tree.start_failed:<the sub-ticket's id>`). `opts`: `tracker` and `observe`, as `split/3`'s.
  """
  @spec start(child(), [%{id: String.t(), identifier: String.t()}], Issue.t(), String.t() | nil, keyword()) ::
          :ok | {:error, String.t()}
  def start(child, blockers, %Issue{id: parent_id}, repo_key, opts) do
    case link_and_promote(child, blockers, opts) do
      :ok ->
        :ok

      {:error, why} ->
        text = "Symphony created #{child.identifier} but could not make #{why}. It stays in #{@backlog}, where it holds this ticket, and Symphony tries again."
        note(repo_key, parent_id, text, "#{@start_failed_key}#{child.id}")
        {:error, why}
    end
  end

  defp link_and_promote(child, blockers, opts) do
    case for(blocker <- blockers, {:error, reason} <- [depend(child, blocker, opts)], do: "its dependency on #{blocker.identifier} (#{inspect(reason)})") do
      [] ->
        ctx = %{repo_key: child.repo, issue_identifier: child.identifier}

        with {:error, reason} <- TransitionGuard.perform(child.id, :breakdown_promote, ctx, tracker: tracker(opts)),
             do: {:error, "its move to #{@todo} (#{inspect(reason)})"}

      failed ->
        {:error, Enum.join(failed, " or ")}
    end
  end

  # A dependency is stored on the sub-ticket's record, which it gets first when it has none yet.
  defp depend(child, blocker, opts) do
    with :ok <- on_record(child, opts), do: RunStore.add_dependency(child.id, blocker.id, :done)
  end

  defp on_record(child, opts) do
    case RunStore.get_ticket_state(child.id) do
      %{} -> :ok
      _none -> observe([child.id], [child], child.repo, opts)
    end
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
  what to do with a check that did not conclude, after which its failed tries count from zero. Or
  about a sub-ticket the ticket may not get (`:limit`), which is asked once per ticket, or one that
  could not be started (`{:start, its id}`), after which its failed tries count from zero.
  """
  @spec asked(String.t(), String.t(), asked()) :: :ok
  def asked(repo_key, issue_id, :rounds) do
    made = rounds(Facts.events(issue_id))
    note(repo_key, issue_id, "After #{made} rounds the final check still wanted to add sub-tickets, so Symphony asked the person.", "#{@asked_key}#{made}")
  end

  def asked(repo_key, issue_id, {:waiting, wait}) do
    note(repo_key, issue_id, "The final check still waits for the Conductor, so Symphony asked the person.", "#{@wait_asked_key}#{wait}")
  end

  def asked(repo_key, issue_id, {:start, child_id}) do
    prefix = @start_asked_key <> child_id
    asked = keyed(Facts.events(issue_id), prefix) + 1
    note(repo_key, issue_id, "A sub-ticket could not be started, #{@start_tries} times, so Symphony asked the person.", "#{prefix}:#{asked}")
  end

  def asked(repo_key, issue_id, :limit) do
    note(repo_key, issue_id, "Symphony refused a sub-ticket this ticket may not get, and asked the person.", @limit_asked_key)
  end

  def asked(repo_key, issue_id, :stuck) do
    asked = keyed(Facts.events(issue_id), @stuck_key) + 1
    note(repo_key, issue_id, "The final check could not close this ticket, so Symphony asked the person.", "#{@stuck_key}#{asked}")
  end

  @doc """
  Says on the ticket `issue_id` that the turn it is owed at `junction` waits, because `provider`
  cannot take a run now: a status note, written once per wait (see the module doc). `:ok`, or
  `{:ask, {:waiting, n}, question}` once a final check has waited more than
  #{@wait_ask_after_minutes} minutes and the person was not asked in this wait. `now` is the time.
  """
  @spec waiting(String.t() | nil, String.t(), String.t(), String.t(), DateTime.t()) :: :ok | {:ask, asked(), map()}
  def waiting(repo_key, issue_id, junction, provider, now \\ DateTime.utc_now()) do
    events = Facts.events(issue_id)
    # The wait in progress: its note, unless a Conductor turn ran on the ticket since.
    since = events |> Enum.reverse() |> Enum.take_while(&(not conductor_run?(&1))) |> Enum.find(&keyed?(&1, @wait_key))
    waits = keyed(events, @wait_key)

    cond do
      is_nil(since) ->
        note(repo_key, issue_id, "Waiting for the Conductor: #{provider} is paused or at its usage limit.", "#{@wait_key}#{waits + 1}")

      junction == "final_check" and DateTime.diff(now, since.at, :minute) > @wait_ask_after_minutes and keyed(events, "#{@wait_asked_key}#{waits}") == 0 ->
        {:ask, {:waiting, waits}, waiting_question(provider)}

      true ->
        :ok
    end
  end

  defp conductor_run?(%{type: "run.started", payload: payload}), do: Map.get(payload, :run_kind) == "conductor"
  defp conductor_run?(_event), do: false

  defp waiting_question(provider) do
    %{
      title: "The final check waits for the Conductor",
      question:
        "Every sub-ticket of this ticket ended, and its final check has waited more than #{@wait_ask_after_minutes} minutes: #{provider} is paused or at its usage limit. Close the ticket on its sub-tickets, or keep waiting?",
      why: "The final check needs the Conductor, and nothing says when its provider takes runs again.",
      if_unanswered: "The ticket stays in the waiting state until the provider takes runs again.",
      recommendation_reason: "The final check is what says the ticket does what was asked.",
      options: [
        %{label: "Keep waiting", effect: "The final check runs once the provider takes runs again.", recommended: true, action: "continue"},
        %{label: "Close it on its sub-tickets", effect: "The ticket moves to #{@done} without a final check.", recommended: false, action: "close"}
      ]
    }
  end

  @doc """
  Looks at what a `final_check` turn left: `before` holds whether it paused the ticket (`held`),
  how many rounds were made when it started (`rounds`), when (`at`) and how the turn ended (`exit`).
  A turn that closed the ticket, paused it, made a round or found a sub-ticket added meanwhile
  changed something. Its answer is already the second one when the first concluded nothing: that
  one was given back to the Conductor in the same turn (`SymphonyElixir.Conductor.tend/4`). Any
  other did not finish and is counted, as a status note (see the module doc): the next poll tries once more, and after 2 in a
  row `{:ask, :stuck, question}` is answered, since the ticket never closes without its check.
  """
  @spec checked(String.t(), Issue.t(), map()) :: :ok | {:ask, :stuck, map()}
  def checked(repo_key, %Issue{id: issue_id}, %{held: held, rounds: before, exit: exit} = left) do
    events = Facts.events(issue_id)

    if held == :held or concluded?(issue_id, events, Map.get(left, :at)) or rounds(events) > before do
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

  # A pass that found a sub-ticket added meanwhile settled the check (the ticket waits on that
  # one), and so did a check that closed the ticket or changed its open sub-tickets.
  defp concluded?(issue_id, events, since) do
    since? = &(is_nil(since) or DateTime.compare(&1.at, since) != :lt)

    Enum.any?(events, &(keyed?(&1, @waits_key) and since?.(&1))) or
      match?(%{phase: @done}, RunStore.get_ticket_state(issue_id)) or
      Enum.any?(TicketPlan.versions(issue_id), &(String.starts_with?(Map.get(&1, :reason) || "", @recalibration) and since?.(&1)))
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
