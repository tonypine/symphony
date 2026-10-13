defmodule SymphonyElixir.RetiredStates do
  @moduledoc """
  The drain report: every ticket still sitting in a retired or draining state, with what it waits
  on and the move that frees it.

  `Auto Review` is retired with the acceptance gate (`docs/design/state-machine.md` §Retired): the
  transition guard refuses every move into it (`SymphonyElixir.TransitionGuard.retired_states/0`),
  so no ticket can enter it again. `In Review` and `Human Review` retire once they drain (decision
  D11: drain only, no migration command): a ticket there finishes on the legacy path, and a
  straggler is moved on by a person's hand — a parked plan into `Plan Review`, an open decision into
  its phase with a `Needs Decision` hold.

  `report/1` runs at startup and logs each straggler loudly. The poll task refreshes it at most
  every `@refresh_interval_ms` (`refresh_if_due/1`), and the dashboard reads the last result
  (`drain_report/0`). A ticket that leaves the report is looked up and logged with the state it
  landed in, so none vanishes from it without landing somewhere visible. The removal of the
  draining states waits on this report being empty.
  """

  require Logger

  alias SymphonyElixir.{Tracker, TransitionGuard}

  @draining_states ["In Review", "Human Review"]
  @refresh_interval_ms 5 * 60 * 1000
  @landed_limit 20
  @cache_key {__MODULE__, :drain_report}

  @type straggler :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          wait: atom(),
          waits_on: String.t(),
          move: String.t()
        }
  @type landing :: %{id: String.t() | nil, identifier: String.t() | nil, from: String.t() | nil, to: String.t() | nil}
  @type drain :: %{stragglers: [straggler()], landed: [landing()], checked_at_ms: integer() | nil}

  @doc "The states the report reads: the retired states and the draining ones."
  @spec states() :: [String.t()]
  def states, do: TransitionGuard.retired_states() ++ @draining_states

  @doc """
  Logs an error for each ticket in a retired or draining state, records the report for the
  dashboard and returns the tickets. `opts[:tracker]` overrides the tracker (tests, a fake);
  `opts[:now_ms]` the clock. A tracker that can't be read is logged as a warning, reports nothing
  and keeps the last report.
  """
  @spec report(keyword()) :: [map()]
  def report(opts \\ []) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    case tracker.fetch_issues_by_states(states()) do
      {:ok, issues} ->
        Enum.each(issues, &log_straggler/1)
        record(issues, tracker, now_ms)
        issues

      {:error, reason} ->
        Logger.warning("Could not check for tickets left in a retired state (#{Enum.join(states(), ", ")}): #{inspect(reason)}")
        []
    end
  end

  @doc "`report/1` when the last report is older than the refresh interval (or there is none)."
  @spec refresh_if_due(keyword()) :: :ok
  def refresh_if_due(opts \\ []) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

    case drain_report() do
      %{checked_at_ms: checked} when is_integer(checked) and now_ms - checked < @refresh_interval_ms ->
        :ok

      _ ->
        _ = report(Keyword.put(opts, :now_ms, now_ms))
        :ok
    end
  end

  @doc "The last recorded report: the stragglers, the latest landings and when it was checked."
  @spec drain_report() :: drain()
  def drain_report, do: :persistent_term.get(@cache_key, %{stragglers: [], landed: [], checked_at_ms: nil})

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "What a ticket in a retired or draining state waits on, and the move that frees it."
  @spec wait(map()) :: {atom(), String.t(), String.t()}
  def wait(issue) do
    state = normalize(Map.get(issue, :state))
    labels = issue |> Map.get(:labels) |> List.wrap() |> Enum.map(&normalize/1)

    cond do
      Enum.any?(TransitionGuard.retired_states(), &(normalize(&1) == state)) ->
        {:retired, "nothing: no path dispatches or moves on from this state", "move it by hand to Code Review (its PR is open) or In Progress"}

      Enum.any?(labels, &(&1 in ["plan", "breakdown"])) ->
        {:parked_plan, "a parked plan waiting on its review", "move it by hand to Plan Review"}

      state == "human review" or Enum.any?(labels, &(&1 in ["needs decision", "needs-human", "human-action"])) ->
        {:open_decision, "an open decision for a person", "move it by hand into its phase with a Needs Decision hold"}

      "blocked" in labels ->
        {:blocked_qa, "blocked QA", "move it by hand to QA; its Blocked hold keeps it there until the fix lands"}

      true ->
        {:supervisor_check, "a supervisor check of its PR", "move it by hand to Code Review (its PR is open) or In Progress"}
    end
  end

  defp record(issues, tracker, now_ms) do
    previous = drain_report()
    stragglers = Enum.map(issues, &straggler/1)
    current_ids = MapSet.new(stragglers, & &1.id)
    left = Enum.reject(previous.stragglers, &MapSet.member?(current_ids, &1.id))
    landed = Enum.take(landings(left, tracker) ++ previous.landed, @landed_limit)

    :persistent_term.put(@cache_key, %{stragglers: stragglers, landed: landed, checked_at_ms: now_ms})
  end

  defp straggler(issue) do
    {wait, waits_on, move} = wait(issue)

    %{
      id: Map.get(issue, :id),
      identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title),
      url: Map.get(issue, :url),
      state: Map.get(issue, :state),
      wait: wait,
      waits_on: waits_on,
      move: move
    }
  end

  defp landings([], _tracker), do: []

  defp landings(left, tracker) do
    now_in =
      case tracker.fetch_issue_states_by_ids(Enum.map(left, & &1.id)) do
        {:ok, issues} -> Map.new(issues, &{Map.get(&1, :id), Map.get(&1, :state)})
        {:error, _reason} -> %{}
      end

    Enum.map(left, fn straggler ->
      to = Map.get(now_in, straggler.id)
      name = straggler.identifier || straggler.id

      Logger.info("#{name} left the #{straggler.state} state for #{to || "a state that could not be read"}; it is off the drain report")

      %{id: straggler.id, identifier: straggler.identifier, from: straggler.state, to: to}
    end)
  end

  defp log_straggler(issue) do
    {_wait, waits_on, move} = wait(issue)
    state = Map.get(issue, :state)
    kind = if Enum.any?(TransitionGuard.retired_states(), &(normalize(&1) == normalize(state))), do: "retired", else: "draining"

    Logger.error("#{Map.get(issue, :identifier) || Map.get(issue, :id)} is still in the #{kind} #{state} state, waiting on #{waits_on}: #{move}")
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: nil
end
