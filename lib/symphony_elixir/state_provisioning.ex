defmodule SymphonyElixir.StateProvisioning do
  @moduledoc """
  Creates the machine-owned Linear workflow states and labels at startup, and reports drift.

  The five phase states (`Code Review`, `QA`, `Plan Review`, `Epic Review`, `CI Fix`, named by
  `issues.states.code_review` and its siblings) and the machine-owned labels (`Blocked`,
  `Needs Decision`, `CI green`, `CI red`, `CI running`) are found by name, team-scoped: a state or
  label a team is missing is created there, and one it already has is left alone, so a second
  startup creates nothing.

  A missing name is reported loudly with the exact state or label, before it is created, so a name
  renamed in Linear is visible at startup rather than passing as a quiet create. A name the board
  already carries is never created again: nothing is duplicated by name.

  The states are inert here: nothing dispatches on, enters or reads them yet. The labels are
  machine-owned; a person can still add or remove them by hand, and provisioning only creates.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{RepoTeams, Tracker}

  @labels ["Blocked", "Needs Decision", "CI green", "CI red", "CI running"]

  @machine_states [
    {:code_review_state, "issues.states.code_review"},
    {:qa_state, "issues.states.qa"},
    {:plan_review_state, "issues.states.plan_review"},
    {:epic_review_state, "issues.states.epic_review"},
    {:ci_fix_state, "issues.states.ci_fix"}
  ]

  # Linear requires a color for a new state. Each phase has its own, by config key, so a renamed
  # state keeps it; they sit near the warm yellow of Linear's In Progress.
  @state_colors %{
    "issues.states.code_review" => "#f2994a",
    "issues.states.qa" => "#e5b53b",
    "issues.states.plan_review" => "#d9a05b",
    "issues.states.epic_review" => "#c98a3c",
    "issues.states.ci_fix" => "#eb5757"
  }

  # What each label shows, for the Setup labels check's consequence when a team is missing it.
  @label_shows %{
    "Blocked" => "Tickets Symphony pauses on a dependency or a block can't be marked on the ticket.",
    "Needs Decision" => "Decisions you are asked for can't be marked on the ticket.",
    "CI green" => "A ticket can't show that its pull request's checks passed.",
    "CI red" => "A ticket can't show that its pull request's checks failed.",
    "CI running" => "A ticket can't show that its pull request's checks are running."
  }

  @read_labels [
    {["plan", "breakdown"], "No ticket can be marked as a plan, so a plan is worked as one pull request."},
    {["qa:skip"], "No ticket can skip QA."},
    {["protected-paths-approved"], "A pull request that changes protected paths can't be waived through."},
    {["skip-update-hold"], "A ticket can't skip waiting for the app update that includes its fix."}
  ]

  @deprecated_labels ["human-action"]

  @typedoc """
  A label Symphony applies or reads, as the Setup labels check wants it in each routed team:
  `names` are its accepted spellings (any one will do), `exact?` whether only the exact spelling
  counts (the labels Symphony creates and writes itself), and `shows` what is lost without it.
  """
  @type machine_label :: %{names: [String.t()], severity: :error | :warning, exact?: boolean(), shows: String.t()}

  @doc "The machine-owned labels Symphony keeps on the board."
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc """
  Every label Symphony applies or reads, the one list the Setup labels check reads: the
  machine-owned labels (errors, exact spelling), then the labels people add for Symphony to read
  (warnings, any case), the `force_label` (`agent.concurrency.force_label`) and each
  `escalate_labels` entry. The deprecated `human-action` is left out: it is reported on its own.
  """
  @spec machine_labels(String.t() | nil, [String.t()]) :: [machine_label()]
  def machine_labels(force_label, escalate_labels) when is_list(escalate_labels) do
    owned = for name <- @labels, do: %{names: [name], severity: :error, exact?: true, shows: Map.fetch!(@label_shows, name)}
    read = for {names, shows} <- @read_labels, do: %{names: names, severity: :warning, exact?: false, shows: shows}

    configured =
      [{force_label, "No ticket can be expedited past the queue."}] ++
        Enum.map(escalate_labels, &{&1, "Code Review can't be told to ask you before approving a ticket."})

    taken = (owned ++ read) |> Enum.flat_map(& &1.names) |> Enum.concat(@deprecated_labels) |> MapSet.new(&normalize/1)

    {extra, _taken} =
      Enum.flat_map_reduce(configured, taken, fn {name, shows}, taken ->
        if is_binary(name) and normalize(name) != "" and not MapSet.member?(taken, normalize(name)),
          do: {[%{names: [String.trim(name)], severity: :warning, exact?: false, shows: shows}], MapSet.put(taken, normalize(name))},
          else: {[], taken}
      end)

    owned ++ read ++ extra
  end

  @doc "The labels that are deprecated: still read by some config, but nothing should name them."
  @spec deprecated_labels() :: [String.t()]
  def deprecated_labels, do: @deprecated_labels

  @doc """
  The configured phase states as `{config key, state name}`, skipping any turned off with `null` or
  a blank value.
  """
  @spec machine_states(Schema.t() | term()) :: [{String.t(), String.t()}]
  def machine_states(%Schema{tracker: tracker}) do
    for {field, key} <- @machine_states, name = Map.get(tracker, field), is_binary(name), do: {key, name}
  end

  def machine_states(_settings), do: []

  @doc """
  The Linear team keys or ids Symphony is scoped to: the `issues` team and each repository's teams
  as `SymphonyElixir.RepoTeams.routed_teams/2` resolves them, so a repo routed only by project gets
  its project's team. `opts` go to `routed_teams/2`.
  """
  @spec configured_teams(Schema.t(), [map()], keyword()) :: [String.t()]
  def configured_teams(%Schema{} = settings, repos, opts \\ []) when is_list(repos) do
    opts = Keyword.put_new(opts, :tracker, settings.tracker)

    [settings.tracker.team | Enum.flat_map(repos, &RepoTeams.routed_teams(&1, opts))]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @doc """
  Finds or creates the machine-owned states and labels in each team: the configured `teams` (keys
  or ids), or every team the tracker already has states in when none is configured. With no team to
  provision in, it does nothing.

  Always returns `:ok`: startup carries on when the tracker can't be read or written, with a warning.
  """
  @spec provision(Schema.t() | term(), [String.t()], keyword()) :: :ok
  def provision(settings, teams, opts \\ []) do
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, existing_states} <- tracker.workflow_states(),
         {:ok, existing_labels} <- tracker.labels() do
      case target_teams(teams, existing_states) do
        [] ->
          Logger.info("State provisioning skipped: no Linear team to create the machine-owned states and labels in")

        target_teams ->
          target_teams
          |> Enum.flat_map(&provision_team(&1, machine_states(settings), existing_states, existing_labels, tracker))
          |> log_summary()
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("State provisioning skipped: could not read the Linear states and labels: #{inspect(reason)}")
        :ok
    end
  end

  # The configured teams, or the teams the tracker's existing states belong to, so a workspace with
  # no team configured (Symphony polls all of them) still gets the states.
  defp target_teams([], existing_states) do
    existing_states
    |> Enum.map(&(Map.get(&1, :team_key) || Map.get(&1, :team_id)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp target_teams(teams, _existing_states), do: teams

  defp provision_team(team, states, existing_states, existing_labels, tracker) do
    Enum.map(states, fn {config_key, name} -> ensure_state(team, config_key, name, existing_states, tracker) end) ++
      Enum.map(@labels, fn name -> ensure_label(team, name, existing_labels, tracker) end)
  end

  defp ensure_state(team, config_key, name, existing_states, tracker) do
    if state_present?(existing_states, team, name) do
      :present
    else
      Logger.warning(
        "Linear workflow state #{inspect(name)} is missing from team #{inspect(team)}; creating it. " <>
          "If it was renamed in Linear, point #{config_key} at the new name so Symphony finds it instead"
      )

      create(:workflow_state, name, team, tracker, Map.fetch!(@state_colors, config_key))
    end
  end

  defp ensure_label(team, name, existing_labels, tracker) do
    if label_present?(existing_labels, team, name) do
      :present
    else
      Logger.warning("Linear label #{inspect(name)} is missing from team #{inspect(team)}; creating it")
      create(:label, name, team, tracker)
    end
  end

  defp create(:workflow_state, name, team, tracker, color) do
    case tracker.create_workflow_state(name, team, color) do
      {:ok, _state} ->
        Logger.info("Created Linear workflow state #{inspect(name)} in team #{inspect(team)}")
        :created

      {:error, reason} ->
        Logger.warning("Could not create the Linear workflow state #{inspect(name)} in team #{inspect(team)}: #{inspect(reason)}")
        :failed
    end
  end

  defp create(:label, name, team, tracker) do
    case tracker.create_label(name, team) do
      {:ok, _label} ->
        Logger.info("Created Linear label #{inspect(name)} in team #{inspect(team)}")
        :created

      {:error, reason} ->
        Logger.warning("Could not create the Linear label #{inspect(name)} in team #{inspect(team)}: #{inspect(reason)}")
        :failed
    end
  end

  defp log_summary(results) do
    counts = Enum.frequencies(results)

    Logger.info(
      "State provisioning: #{Map.get(counts, :created, 0)} created, " <>
        "#{Map.get(counts, :present, 0)} already present, #{Map.get(counts, :failed, 0)} failed"
    )
  end

  # A state carries the name in its team. A label carries it in its team, or workspace-wide, which is
  # where `Linear.Adapter.lookup_issue_label/2` looks after a team label.
  defp state_present?(states, team, name) do
    Enum.any?(states, fn state -> same_name?(Map.get(state, :name), name) and belongs_to_team?(state, team) end)
  end

  defp label_present?(labels, team, name) do
    Enum.any?(labels, fn label ->
      same_name?(Map.get(label, :name), name) and (is_nil(Map.get(label, :team_id)) or belongs_to_team?(label, team))
    end)
  end

  defp same_name?(left, right), do: normalize(left) != "" and normalize(left) == normalize(right)

  defp belongs_to_team?(resource, team) do
    wanted = normalize(team)
    wanted != "" and wanted in [normalize(Map.get(resource, :team_key)), normalize(Map.get(resource, :team_id))]
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
