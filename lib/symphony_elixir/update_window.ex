defmodule SymphonyElixir.UpdateWindow do
  @moduledoc """
  When an update the menu bar app has ready takes Symphony down (TP-1590).

  The app downloads and verifies a release, then tells Symphony it is ready (`arm/3`, the control
  API's `update_ready`). Symphony keeps dispatching. It picks the moment itself (`decide/3`, read
  when a run ends, before the freed slot is refilled, and at each poll):

    * the first moment no agent run is active (a run between turns does not count, as in
      `GET /api/v1/drain`), it holds dispatch: `:hold`, which sets Symphony's pause on the update's
      `:build` reason. The app sees the pause with no active run and swaps itself, so the pause
      lasts only the restart;
    * with runs always active, after `wait_ms/0` it holds dispatch so a gap forms, but only once no
      active run began less than `recent_ms/0` ago: an update never starts holding behind a run
      that just began;
    * a hold that reaches `hold_ms/0` with runs still active is lifted (`:lift`) and the wait
      starts again; one with no run left (the app never came for it) is called off (`:disarm`), and
      the app arms it again if it still wants it.

  A newer version armed while the update waits or holds replaces the target and keeps the time
  already waited (`arm/3`), so several builds published in a row cost one hold, not one each. The
  numbers are fixed and do not depend on how many builds were published (SPEC.md, Section 8).

  The window is kept in the orchestrator's memory: a Symphony that restarts forgets it, and the app,
  which reads it from the state payload (`status/1`), arms it again.
  """

  @wait_ms 15 * 60 * 1_000
  @recent_ms 3 * 60 * 1_000
  @hold_ms 10 * 60 * 1_000

  @enforce_keys [:version, :ready_at, :wait_from]
  defstruct [:version, :ready_at, :wait_from, phase: :waiting, holding_since: nil]

  @type phase :: :waiting | :holding
  @type t :: %__MODULE__{
          version: String.t(),
          ready_at: DateTime.t(),
          wait_from: DateTime.t(),
          phase: phase(),
          holding_since: DateTime.t() | nil
        }

  @typedoc "What the orchestrator does next: set the update's pause, lift it, call the update off, or nothing."
  @type decision :: :hold | :lift | :disarm | :none

  @doc "How long an update waits, with dispatch running, for a moment with no active run before it holds dispatch."
  @spec wait_ms() :: pos_integer()
  def wait_ms, do: @wait_ms

  @doc "A run that began less than this long ago keeps an update from starting to hold dispatch."
  @spec recent_ms() :: pos_integer()
  def recent_ms, do: @recent_ms

  @doc "The longest an update holds dispatch while runs are still active, before it lifts the hold."
  @spec hold_ms() :: pos_integer()
  def hold_ms, do: @hold_ms

  @doc """
  The app has `version` ready. A first one starts the wait at `now`; a newer one replaces the
  target and keeps the wait and the hold it is in. An older or the same version changes nothing.
  """
  @spec arm(t() | nil, String.t(), DateTime.t()) :: t()
  def arm(nil, version, now), do: %__MODULE__{version: version, ready_at: now, wait_from: now}

  def arm(%__MODULE__{} = window, version, _now) do
    if newer?(version, window.version), do: %{window | version: version}, else: window
  end

  @doc """
  What to do now, from the start times of the active agent runs. Returns the decision and the
  window after it (nil once called off).
  """
  @spec decide(t() | nil, [DateTime.t()], DateTime.t()) :: {decision(), t() | nil}
  def decide(nil, _runs, _now), do: {:none, nil}

  def decide(%__MODULE__{phase: :waiting} = window, runs, now) do
    if runs == [] or (elapsed(window.wait_from, now) >= @wait_ms and Enum.all?(runs, &(elapsed(&1, now) >= @recent_ms))) do
      {:hold, %{window | phase: :holding, holding_since: now}}
    else
      {:none, window}
    end
  end

  def decide(%__MODULE__{phase: :holding} = window, runs, now) do
    cond do
      elapsed(window.holding_since, now) < @hold_ms -> {:none, window}
      runs == [] -> {:disarm, nil}
      true -> {:lift, %{window | phase: :waiting, holding_since: nil, wait_from: now}}
    end
  end

  @doc "Someone else lifted the update's pause (the Director's Resume): the update waits again from `now`."
  @spec lifted(t() | nil, DateTime.t()) :: t() | nil
  def lifted(%__MODULE__{phase: :holding} = window, now), do: %{window | phase: :waiting, holding_since: nil, wait_from: now}
  def lifted(window, _now), do: window

  @doc "The window as the state payload reports it (`update_window`), nil when no update is ready."
  @spec status(t() | nil) :: map() | nil
  def status(nil), do: nil

  def status(%__MODULE__{} = window) do
    %{version: window.version, phase: window.phase, ready_at: window.ready_at, holding_since: window.holding_since}
  end

  @doc "Whether `version` is a release's version as an update names it (`0.0.1.42`)."
  @spec version?(term()) :: boolean()
  def version?(version), do: is_binary(version) and parts(version) != nil

  defp newer?(version, than), do: parts(version) > parts(than)

  defp parts(version) do
    numbers = version |> String.split(".") |> Enum.map(&Integer.parse/1)
    if length(numbers) > 1 and Enum.all?(numbers, &match?({_n, ""}, &1)), do: Enum.map(numbers, &elem(&1, 0))
  end

  defp elapsed(from, now), do: DateTime.diff(now, from, :millisecond)
end
