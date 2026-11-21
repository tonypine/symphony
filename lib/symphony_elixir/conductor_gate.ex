defmodule SymphonyElixir.ConductorGate do
  @moduledoc """
  Keeps Symphony from being stopped for an update or a restart while a Conductor turn is mid-run
  (TP-1590).

  Conductor turns are not held by an update's pause (`SymphonyElixir.Conductor`): they keep
  starting and answering while dispatch waits for the restart. So the menu bar app asks for the
  handover (`handover/1`, the control API's `handover`) once dispatch is paused and no agent run is
  active, and stops Symphony only once it is given. Every Conductor turn enters the gate as it
  starts (`enter/1`) and leaves it as it ends (`leave/1`, or its process ending). The check and the
  close are one call of this process, so no turn can begin between them:

    * `handover/1` with no turn active closes the gate and answers `:ok`. From then on `enter/1`
      answers `:closed`: a turn that would start waits, still owed, and runs first thing after the
      restart (`SymphonyElixir.Conductor.Message.owed_tickets/1`);
    * with turns active it answers `{:wait, count}`, and the app asks again at its next poll. Turns
      keep starting for `wait_ms/0` from the first ask; after that `enter/1` answers `:closed`, so
      the turns running end and a gap forms even when they overlap without one. The wait is then
      bounded by the longest turn's own time limit;
    * a gate closed for `closed_ms/0` with Symphony still up (the app never stopped it), and a
      wait no one asked about for `ask_ms/0` (the drain was called off), open again, and so does
      `reopen/1`, which a Resume of dispatch calls.

  The numbers are fixed (SPEC.md, Section 4.1.11). A gate that is not running lets every turn
  through and gives the handover at once, as a Symphony without it did.
  """

  use GenServer

  @wait_ms 2 * 60 * 1_000
  @closed_ms 5 * 60 * 1_000
  @ask_ms 60 * 1_000

  @typedoc "What `handover/1` answers: Symphony may stop now, or this many Conductor turns are still running."
  @type handover :: :ok | {:wait, pos_integer()}

  @doc "How long Conductor turns keep starting after the first ask for the handover finds one running."
  @spec wait_ms() :: pos_integer()
  def wait_ms, do: @wait_ms

  @doc "How long a gate given the handover stays closed while Symphony is still up."
  @spec closed_ms() :: pos_integer()
  def closed_ms, do: @closed_ms

  @doc "How long a wait for the handover lasts with no one asking about it."
  @spec ask_ms() :: pos_integer()
  def ask_ms, do: @ask_ms

  @doc "Starts the gate. `clock` (a function giving monotonic milliseconds) is for tests."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "A Conductor turn of the calling process starts: `:ok`, or `:closed` when it must not start now."
  @spec enter(GenServer.server()) :: :ok | :closed
  def enter(server \\ __MODULE__), do: call(server, {:enter, self()}, :ok)

  @doc "The calling process's Conductor turn ended."
  @spec leave(GenServer.server()) :: :ok
  def leave(server \\ __MODULE__), do: call(server, {:leave, self()}, :ok)

  @doc "Runs `work` as a Conductor turn: `{:ok, what it returned}`, or `:closed` without running it."
  @spec run(GenServer.server(), (-> result)) :: {:ok, result} | :closed when result: term()
  def run(server \\ __MODULE__, work) when is_function(work, 0) do
    case enter(server) do
      :ok ->
        try do
          {:ok, work.()}
        after
          leave(server)
        end

      :closed ->
        :closed
    end
  end

  @doc "The app asks whether it may stop Symphony now; see the module doc."
  @spec handover(GenServer.server()) :: handover()
  def handover(server \\ __MODULE__), do: call(server, :handover, :ok)

  @doc "Opens the gate again: dispatch was resumed, so no stop follows."
  @spec reopen(GenServer.server()) :: :ok
  def reopen(server \\ __MODULE__), do: call(server, :reopen, :ok)

  @doc "How many Conductor turns are running, and whether new ones are refused."
  @spec status(GenServer.server()) :: %{running: non_neg_integer(), closed: boolean()}
  def status(server \\ __MODULE__), do: call(server, :status, %{running: 0, closed: false})

  defp call(server, message, default) do
    if GenServer.whereis(server), do: GenServer.call(server, message), else: default
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    {:ok, %{clock: clock, turns: %{}, closed_at: nil, asked_at: nil, last_ask: nil}}
  end

  @impl true
  def handle_call({:enter, pid}, _from, state) do
    state = expire(state)

    # A turn already inside enters again from within (a tree turn's own agent turn): it is let
    # through and counts once.
    if refusing?(state) and not Map.has_key?(state.turns, pid) do
      {:reply, :closed, state}
    else
      entry =
        case Map.get(state.turns, pid) do
          {ref, depth} -> {ref, depth + 1}
          nil -> {Process.monitor(pid), 1}
        end

      {:reply, :ok, %{state | turns: Map.put(state.turns, pid, entry)}}
    end
  end

  def handle_call({:leave, pid}, _from, state) do
    case Map.get(state.turns, pid) do
      {ref, depth} when depth > 1 -> {:reply, :ok, %{state | turns: Map.put(state.turns, pid, {ref, depth - 1})}}
      _last_or_none -> {:reply, :ok, drop(state, pid)}
    end
  end

  def handle_call(:handover, _from, state) do
    state = expire(state)
    now = state.clock.()

    case map_size(state.turns) do
      0 -> {:reply, :ok, %{state | closed_at: state.closed_at || now, asked_at: nil, last_ask: nil}}
      count -> {:reply, {:wait, count}, %{state | asked_at: state.asked_at || now, last_ask: now}}
    end
  end

  def handle_call(:reopen, _from, state), do: {:reply, :ok, %{state | closed_at: nil, asked_at: nil, last_ask: nil}}

  def handle_call(:status, _from, state) do
    state = expire(state)
    {:reply, %{running: map_size(state.turns), closed: refusing?(state)}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}

  defp drop(state, pid) do
    case Map.pop(state.turns, pid) do
      {nil, _turns} ->
        state

      {{ref, _depth}, turns} ->
        Process.demonitor(ref, [:flush])
        %{state | turns: turns}
    end
  end

  defp refusing?(%{closed_at: closed_at}) when is_integer(closed_at), do: true
  defp refusing?(%{asked_at: asked_at} = state) when is_integer(asked_at), do: state.clock.() - asked_at >= @wait_ms
  defp refusing?(_state), do: false

  defp expire(state) do
    now = state.clock.()

    state
    |> then(&if(is_integer(&1.closed_at) and now - &1.closed_at >= @closed_ms, do: %{&1 | closed_at: nil}, else: &1))
    |> then(&if(is_integer(&1.last_ask) and now - &1.last_ask >= @ask_ms, do: %{&1 | asked_at: nil, last_ask: nil}, else: &1))
  end
end
