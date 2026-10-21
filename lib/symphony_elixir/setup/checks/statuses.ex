defmodule SymphonyElixir.Setup.Checks.Statuses do
  @moduledoc """
  The workflow states Symphony moves tickets through, in each routed team as
  `SymphonyElixir.RepoTeams` resolves it, from one states read per team through the team cache.

    * Designed states (S1, error): every state of the ticket machine (`docs/design/state-machine.md`),
      Todo, In Progress, Code Review, QA, Merging, Rework, Plan Review, Epic Review, Waiting on
      sub-tickets, CI Fix, Done and Canceled, each of its type. The phase states and the waiting
      state go by the names `issues.states.*` give them, and one turned off with `null` is not
      wanted. A missing state has a `create_state` fix: its name, its type and its place on the
      board, just after the designed state of the same type before it, or first of its type when
      the team has none of those (the app's Create Status sheet says which). A state of the wrong
      type is its own error; changing a type is the operator's call, so the fix opens Linear.
    * Configured names (S4, error): a name in `issues.states.active` or `issues.states.terminal` that
      no state of the team has. A designed name is left to the designed states, and the default
      terminal list, spellings any one of which will do, is not judged. The fix opens Settings.

  Names match whatever the case and the spaces around them. A team whose states read returns none
  at all is one the key can't see (or a fake tracker nobody seeded), so nothing is called missing in
  it, and a state read without its type (a fake tracker's) is not judged on it.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.RepoTeams
  alias SymphonyElixir.Setup.{NearMatch, Problem, TeamCache}

  # The ticket machine's states in board order: the names, or the `issues.states` field and key that
  # name it, the type and what stops without it.
  @designed [
    {["Todo"], "unstarted", "Symphony picks up new work only from Todo, so no ticket can be queued for it."},
    {["In Progress"], "started", "Symphony can't claim a ticket: an agent starting moves it from Todo to In Progress."},
    {{:code_review_state, "issues.states.code_review"}, "started", "Finished work can't be handed to Code Review, so tickets stop in In Progress."},
    {{:qa_state, "issues.states.qa"}, "started", "Tickets that pass Code Review can't move on to QA."},
    {["Merging"], "started", "Tickets that pass Code Review or QA can't move on to be merged."},
    {["Rework"], "started", "Work Code Review or QA sends back can't come back for changes."},
    {{:plan_review_state, "issues.states.plan_review"}, "started", "A plan can't be handed over for your review."},
    {{:epic_review_state, "issues.states.epic_review"}, "started", "An epic whose sub-tickets are all done can't be reviewed, so it never closes."},
    {{:waiting_on_sub_issues_state, "issues.states.waiting_on_sub_issues"}, "started", "An approved plan can't wait on its sub-tickets, so plan parents stay In Progress."},
    {{:ci_fix_state, "issues.states.ci_fix"}, "started", "A pull request with red checks or a conflict can't be sent to be repaired."},
    {["Done"], "completed", "Merged tickets can't be closed."},
    {["Canceled", "Cancelled"], "canceled", "Dropped work can't be canceled, so it stays among the open tickets."}
  ]

  # The colors of Linear's own states of each type, for a state the fix creates.
  @colors %{"unstarted" => "#e2e2e2", "started" => "#f2c94c", "completed" => "#5e6ad2", "canceled" => "#95a2b3"}

  @configured_lists [{:active_states, "issues.states.active"}, {:terminal_states, "issues.states.terminal"}]

  @impl true
  def id, do: "statuses"

  @impl true
  def title, do: "The workflow states in each Linear team"

  @impl true
  def needs_linear?, do: true

  @doc "The color a state of `type` is created with."
  @spec color(String.t()) :: String.t()
  def color(type), do: Map.get(@colors, type, "#bec2c8")

  @impl true
  def run(%{system: nil}), do: []

  def run(%{system: system, team_cache: cache}) do
    designed = designed(system.tracker)

    with {:ok, teams} <- RepoTeams.cached_teams(system.repos, cache) do
      Enum.reduce_while(teams, [], &add_team(&1, &2, designed, system.tracker, cache))
    end
  end

  # A team's problems, from its one states read.
  defp add_team({team, repos}, problems, designed, tracker, cache) do
    case TeamCache.states(cache, team) do
      {:ok, []} -> {:cont, problems}
      {:ok, states} -> {:cont, problems ++ team_problems(team, repos, designed, tracker, states)}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # The designed states as the config names them, each with its accepted names, type, config key
  # and consequence.
  defp designed(tracker) do
    for {names, type, shows} <- @designed, wanted = wanted(names, tracker, type, shows), do: wanted
  end

  defp wanted({field, key}, tracker, type, shows) do
    case Map.get(tracker, field) do
      name when is_binary(name) -> %{names: [name], type: type, key: key, shows: shows}
      nil -> nil
    end
  end

  defp wanted(names, _tracker, type, shows), do: %{names: names, type: type, key: nil, shows: shows}

  defp team_problems(team, repos, designed, tracker, states) do
    states = Enum.filter(states, &is_binary(&1.name))

    Enum.flat_map(designed, &designed_problems(team, repos, &1, designed, states)) ++
      Enum.flat_map(@configured_lists, &unknown(team, repos, &1, tracker, designed, states))
  end

  defp designed_problems(team, repos, wanted, designed, states) do
    case find(states, wanted) do
      nil -> [missing(team, repos, wanted, designed, states)]
      %{type: type} = state when is_binary(type) and type != wanted.type -> [wrong_type(team, repos, wanted, state)]
      _state -> []
    end
  end

  # S1: a designed state the team doesn't have, with the fix that creates it in its place.
  defp missing(team, repos, %{names: [name | others]} = wanted, designed, states) do
    {after_state, position} = placement(wanted, designed, states)

    Problem.new(
      id: "#{id()}:missing:#{team}:#{name}",
      severity: :error,
      category: :statuses,
      title: ~s(Team #{team} has no "#{name}" state),
      consequence: wanted.shows,
      repos: repos,
      details: [Team: team, State: name, Type: wanted.type, After: after_state, "Set by": wanted.key, "Also accepted": join(others)],
      fix: Problem.create_state(team, name, wanted.type, after_state, position)
    )
  end

  # S1: a designed state of another type than the machine's.
  defp wrong_type(team, repos, wanted, state) do
    Problem.new(
      id: "#{id()}:wrong_type:#{team}:#{hd(wanted.names)}",
      severity: :error,
      category: :statuses,
      title: ~s(Team #{team}'s "#{state.name}" state is #{state.type}, not #{wanted.type}),
      consequence:
        "Linear groups and counts its tickets as #{state.type}, so boards, filters and Symphony's reads of the state see them in the " <>
          "wrong place. Changing a state's type is your call: do it in Linear.",
      repos: repos,
      details: [Team: team, State: state.name, Type: state.type, "Symphony's type": wanted.type, "Set by": wanted.key],
      fix: Problem.open(:linear)
    )
  end

  # Just after the nearest designed state of the same type before it that the team has, and before
  # the team's next state of that type; else first of its type; else (the team has none of the type,
  # or a board read without positions) where Linear puts it.
  defp placement(wanted, designed, states) do
    before = designed |> Enum.filter(&(&1.type == wanted.type)) |> Enum.take_while(&(&1 != wanted))

    case before |> Enum.reverse() |> Enum.find_value(&find(states, &1)) do
      %{} = previous -> {previous.name, after_position(previous, wanted.type, states)}
      nil -> {nil, first_position(wanted.type, states)}
    end
  end

  defp first_position(type, states) do
    case states |> Enum.filter(&(Map.get(&1, :type) == type)) |> Enum.map(&Map.get(&1, :position)) |> Enum.filter(&is_number/1) do
      [] -> nil
      positions -> Enum.min(positions) - 1
    end
  end

  defp after_position(%{position: position}, type, states) when is_number(position) do
    next =
      states
      |> Enum.filter(&(Map.get(&1, :type) == type and is_number(Map.get(&1, :position)) and &1.position > position))
      |> Enum.min_by(& &1.position, fn -> nil end)

    if next, do: (position + next.position) / 2, else: position + 1
  end

  defp after_position(_previous, _type, _states), do: nil

  # S4: a name in a configured state list that no state of the team has.
  defp unknown(team, repos, {field, key}, tracker, designed, states) do
    designed_names = designed |> Enum.flat_map(& &1.names) |> MapSet.new(&normalize/1)

    for name <- judged_names(field, tracker),
        normalize(name) != "",
        not MapSet.member?(designed_names, normalize(name)),
        not Enum.any?(states, &(normalize(&1.name) == normalize(name))) do
      Problem.new(
        id: "#{id()}:unknown:#{team}:#{key}:#{name}",
        severity: :error,
        category: :statuses,
        title: ~s(#{key} names "#{name}", which team #{team} has no state for),
        consequence: unknown_consequence(field, name, team),
        repos: repos,
        details: [Key: key, Value: name, Team: team, "Closest state": closest(name, states)],
        fix: Problem.open(:settings)
      )
    end
  end

  defp judged_names(:terminal_states, tracker) do
    if tracker.terminal_states == %Schema.Tracker{}.terminal_states, do: [], else: List.wrap(tracker.terminal_states)
  end

  defp judged_names(field, tracker), do: tracker |> Map.get(field) |> List.wrap()

  defp unknown_consequence(:active_states, name, team),
    do: ~s(Symphony never picks up tickets from "#{name}": no state in team #{team} has that name. Check the spelling in Settings.)

  defp unknown_consequence(:terminal_states, name, team),
    do: ~s(Symphony doesn't count "#{name}" as finished: no state in team #{team} has that name. Check the spelling in Settings.)

  defp closest(name, states), do: Enum.find_value(states, &(NearMatch.near?(name, &1.name) && &1.name))

  defp find(states, %{names: names}) do
    wanted = MapSet.new(names, &normalize/1)
    Enum.find(states, &MapSet.member?(wanted, normalize(&1.name)))
  end

  defp join([]), do: nil
  defp join(values), do: Enum.join(values, ", ")

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
