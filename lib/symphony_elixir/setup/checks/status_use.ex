defmodule SymphonyElixir.Setup.Checks.StatusUse do
  @moduledoc """
  How Symphony's workflow states are in use, from what the service already knows, without a read of
  Linear of its own:

    * Turned off (S2, warning): the waiting state (`issues.states.waiting_on_sub_issues`) the
      startup check didn't find and turned off (`SymphonyElixir.SubIssueWait.disabled_teams/1`), so
      plan parents stay In Progress until a restart finds it. The statuses check offers to create
      the state; turning it back on takes a restart, so there is no fix here.
    * Retired and draining (S3, warning): the tickets the drain report
      (`SymphonyElixir.RetiredStates.drain_report/0`) still finds in a retired state, one problem
      per state naming them, with the move that frees each. Nothing moves them by itself: the fix
      opens the drain report.
    * A machine state in active (S5, warning): a phase state Symphony runs by itself (Code Review,
      QA, Epic Review, CI Fix) listed in `issues.states.active`. The fix removes it from the list.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{RetiredStates, SubIssueWait}
  alias SymphonyElixir.Setup.Problem

  @active_key "issues.states.active"
  @waiting_key "issues.states.waiting_on_sub_issues"

  # The phase states that can be listed as active: config refuses Plan Review there.
  @phase_fields [
    {:code_review_state, "issues.states.code_review"},
    {:qa_state, "issues.states.qa"},
    {:epic_review_state, "issues.states.epic_review"},
    {:ci_fix_state, "issues.states.ci_fix"}
  ]

  @impl true
  def id, do: "status_use"

  @impl true
  def title, do: "States Symphony turned off, tickets left in retired states, and phase states listed as active"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(%{system: nil}), do: retired()

  def run(%{system: system}), do: waiting_off(system.tracker) ++ retired() ++ active_phases(system.tracker)

  # S2: the waiting state the startup check turned off.
  defp waiting_off(tracker) do
    state = tracker.waiting_on_sub_issues_state

    case SubIssueWait.disabled_teams(state) do
      nil ->
        []

      teams ->
        [
          Problem.new(
            id: "#{id()}:waiting_off",
            severity: :warning,
            category: :statuses,
            title: ~s(Symphony turned "#{state}" off),
            consequence:
              ~s(At startup Symphony found no "#{state}" state#{in_teams(teams)}, so approved plans stay In Progress while ) <>
                "their sub-tickets are worked. Add the state, then restart Symphony to turn it back on.",
            details: [State: state, Teams: join(teams), "Set by": @waiting_key]
          )
        ]
    end
  end

  # S3: the tickets still in each retired state, as the last drain report found them.
  defp retired do
    stragglers = RetiredStates.drain_report().stragglers

    stragglers
    |> Enum.map(& &1.state)
    |> Enum.uniq()
    |> Enum.map(fn state -> retired_problem(state, Enum.filter(stragglers, &(&1.state == state))) end)
  end

  defp retired_problem(state, stragglers) do
    Problem.new(
      id: "#{id()}:retired:#{state}",
      severity: :warning,
      category: :statuses,
      title: retired_title(state, Enum.map(stragglers, &name/1)),
      consequence:
        "#{state} is retired: no run starts there and nothing moves a ticket on from it, so each waits for good. " <>
          "Move each one by hand; the drain report says where.",
      tickets: Enum.map(stragglers, &%{identifier: name(&1), url: &1.url}),
      details: Enum.map(stragglers, &{name(&1), &1.move}),
      fix: Problem.open(:drain_report)
    )
  end

  defp retired_title(state, [name]), do: "#{name} is still in the retired #{state} state"
  defp retired_title(state, names), do: "#{length(names)} tickets are still in the retired #{state} state"

  defp name(straggler), do: straggler.identifier || straggler.id

  # S5: a phase state listed among the active states.
  defp active_phases(tracker) do
    for {field, key} <- @phase_fields,
        phase = Map.get(tracker, field),
        is_binary(phase),
        listed <- List.wrap(tracker.active_states),
        normalize(listed) == normalize(phase) do
      Problem.new(
        id: "#{id()}:active_phase:#{phase}",
        severity: :warning,
        category: :statuses,
        title: ~s(#{@active_key} lists the "#{phase}" phase),
        consequence:
          ~s(Symphony already picks tickets up in "#{phase}" as a phase of its own, so the entry adds nothing; if the phase is ) <>
            "ever turned off, tickets there would be worked as ordinary work. Remove it from the list.",
        details: [Key: @active_key, Value: listed, "Phase set by": key],
        fix: Problem.config_edit(@active_key, :remove, listed)
      )
    end
  end

  defp in_teams([]), do: ""
  defp in_teams(teams), do: " in team #{Enum.join(teams, ", ")}"

  defp join([]), do: nil
  defp join(values), do: Enum.join(values, ", ")

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
