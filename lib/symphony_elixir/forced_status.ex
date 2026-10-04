defmodule SymphonyElixir.ForcedStatus do
  @moduledoc """
  What a forced ticket is doing now and what it waits on, as `/api/v1/state` `forced` and the
  dashboards show it.

  The orchestrator gathers the signals for the ticket (or for a forced parent's current part) and
  `describe/1` turns them into a `phase` and a `waiting_on`:

    * a running agent gives the run's kind as the phase (`implementation`, `rework`,
      `review_feedback`, `ci_fix`, `landing`, `breakdown`, `close_out`, `final_verification`) and
      waits on nothing; a running Auto Review QA pass gives `auto_review`;
    * a `Merging` ticket held while CI runs on its head is `waiting_on_ci` (`ci`);
    * a ticket in `In Review` is `waiting_for_human` (`human`);
    * a ticket in `Backlog` or `Triage` keeps the phase its next run would have and waits on
      `backlog`;
    * a ticket in the Auto Review state is `auto_review`, waiting on a `slot` while its pass is
      queued;
    * otherwise the phase is the next run's kind, waiting on its open `blocker`s, the operator's
      Pause (`paused`), a usage-limit pause (`usage_limit`), a free `slot`, or GitHub auto-merge
      (`ci`), in that order.
  """

  @type phase ::
          :implementation
          | :rework
          | :review_feedback
          | :ci_fix
          | :waiting_on_ci
          | :auto_review
          | :waiting_for_human
          | :landing
          | :breakdown
          | :close_out
          | :final_verification

  @type waiting_on :: :slot | :human | :ci | :blocker | :usage_limit | :paused | :backlog | nil

  @type signals :: %{
          optional(:running_kind) => atom() | nil,
          optional(:qa) => :running | :queued | nil,
          optional(:state) => String.t() | nil,
          optional(:auto_review_state) => String.t() | nil,
          optional(:kind) => atom() | nil,
          optional(:merging_ci_wait?) => boolean(),
          optional(:auto_merge?) => boolean(),
          optional(:blockers) => [String.t()],
          optional(:paused?) => boolean(),
          optional(:usage_limit?) => boolean(),
          optional(:slot_waiting?) => boolean()
        }

  @type status :: %{phase: phase(), running: boolean(), waiting_on: waiting_on(), blockers: [String.t()]}

  @run_phases [
    :implementation,
    :rework,
    :review_feedback,
    :ci_fix,
    :landing,
    :breakdown,
    :close_out,
    :final_verification
  ]
  @backlog_states ["backlog", "triage"]

  @phase_labels %{
    "implementation" => "implementation",
    "rework" => "rework",
    "review_feedback" => "review feedback",
    "ci_fix" => "CI fix",
    "waiting_on_ci" => "waiting on CI",
    "auto_review" => "Auto Review",
    "waiting_for_human" => "waiting for a human",
    "landing" => "landing",
    "breakdown" => "breakdown",
    "close_out" => "close-out",
    "final_verification" => "final verification"
  }

  @waiting_labels %{
    "slot" => "slot",
    "human" => "human",
    "ci" => "CI",
    "usage_limit" => "usage limit",
    "paused" => "paused",
    "backlog" => "backlog"
  }

  @doc "The phase and what the ticket waits on, from the signals the orchestrator gathered."
  @spec describe(signals()) :: status()
  def describe(%{} = signals) do
    {phase, running?, waiting_on} = classify(signals, normalize(Map.get(signals, :state)))
    blockers = if waiting_on == :blocker, do: Map.get(signals, :blockers, []), else: []

    %{phase: phase, running: running?, waiting_on: waiting_on, blockers: blockers}
  end

  @doc "How long, in whole seconds, a ticket forced at `forced_since` has been forced at `now`."
  @spec forced_for_seconds(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def forced_for_seconds(%DateTime{} = forced_since, %DateTime{} = now), do: max(DateTime.diff(now, forced_since, :second), 0)

  @doc "Whether a ticket forced for `forced_for_seconds` is past `stale_after_hours`."
  @spec stale?(non_neg_integer(), pos_integer()) :: boolean()
  def stale?(forced_for_seconds, stale_after_hours) when is_integer(forced_for_seconds) and is_integer(stale_after_hours),
    do: forced_for_seconds >= stale_after_hours * 3_600

  @doc "The phase as the dashboards print it: `implementation`, `CI fix`, `waiting for a human`, ..."
  @spec phase_label(phase() | String.t() | nil) :: String.t()
  def phase_label(phase), do: Map.get(@phase_labels, to_label_key(phase), "unknown")

  @doc "What the ticket waits on as the dashboards print it: `running`, `blocker MT-1, MT-2`, `slot`, `-`."
  @spec waiting_label(map()) :: String.t()
  def waiting_label(%{running: true}), do: "running"

  def waiting_label(%{} = status) do
    case to_label_key(Map.get(status, :waiting_on)) do
      "blocker" -> "blocker " <> blockers_label(Map.get(status, :blockers, []))
      key -> Map.get(@waiting_labels, key, "-")
    end
  end

  @doc """
  One line for a forced ticket: `implementation · running`, `implementation · waiting on blocker
  MT-1`, `waiting for a human`. The waiting part is left out when the phase already says it.
  """
  @spec summary(map()) :: String.t()
  def summary(%{} = status) do
    phase = phase_label(Map.get(status, :phase))

    cond do
      Map.get(status, :running) == true -> phase <> " · running"
      redundant_wait?(status) -> phase
      true -> phase <> " · waiting on " <> waiting_label(status)
    end
  end

  @doc "A forced-for duration in its two largest units: `45s`, `12m`, `3h 5m`, `2d 4h`."
  @spec duration_label(integer() | nil) :: String.t()
  def duration_label(seconds) when is_integer(seconds) and seconds < 60, do: "#{max(seconds, 0)}s"
  def duration_label(seconds) when is_integer(seconds) and seconds < 3_600, do: "#{div(seconds, 60)}m"
  def duration_label(seconds) when is_integer(seconds) and seconds < 86_400, do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  def duration_label(seconds) when is_integer(seconds), do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
  def duration_label(_seconds), do: "n/a"

  defp run_phase(kind) when kind in @run_phases, do: kind
  defp run_phase(:qa), do: :auto_review
  defp run_phase(_kind), do: :implementation

  defp classify(%{running_kind: kind}, _state) when not is_nil(kind), do: {run_phase(kind), true, nil}
  defp classify(%{qa: :running}, _state), do: {:auto_review, true, nil}
  defp classify(%{merging_ci_wait?: true}, _state), do: {:waiting_on_ci, false, :ci}
  defp classify(_signals, "in review"), do: {:waiting_for_human, false, :human}
  defp classify(signals, state) when state in @backlog_states, do: {next_phase(signals), false, :backlog}

  defp classify(signals, state) do
    if state != nil and state == normalize(Map.get(signals, :auto_review_state)),
      do: {:auto_review, false, if(Map.get(signals, :qa) == :queued, do: :slot)},
      else: {next_phase(signals), false, waiting_on(signals)}
  end

  defp next_phase(signals), do: signals |> Map.get(:kind) |> run_phase()

  defp waiting_on(signals) do
    cond do
      Map.get(signals, :blockers, []) != [] -> :blocker
      Map.get(signals, :paused?, false) -> :paused
      Map.get(signals, :usage_limit?, false) -> :usage_limit
      Map.get(signals, :slot_waiting?, false) -> :slot
      Map.get(signals, :auto_merge?, false) -> :ci
      true -> nil
    end
  end

  defp redundant_wait?(status) do
    case {to_label_key(Map.get(status, :phase)), to_label_key(Map.get(status, :waiting_on))} do
      {_phase, ""} -> true
      {"waiting_for_human", "human"} -> true
      {"waiting_on_ci", "ci"} -> true
      _other -> false
    end
  end

  defp blockers_label([]), do: "unknown"
  defp blockers_label(blockers), do: Enum.join(blockers, ", ")

  defp to_label_key(nil), do: ""
  defp to_label_key(value) when is_atom(value), do: Atom.to_string(value)
  defp to_label_key(value) when is_binary(value), do: value

  defp normalize(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize(_state), do: nil
end
