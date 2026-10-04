defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Renders a status snapshot for orchestrator and worker activity as a terminal UI.

  This GenServer owns the OTP lifecycle and scheduling concerns: pulling the
  orchestrator snapshot, throttling renders, and writing to the terminal.
  All formatting/rendering logic — the bulk of the original module — lives in
  `SymphonyElixir.StatusDashboard.Renderer`.

  It draws only when standard output is a terminal, so a Symphony whose output
  goes to a file (as under the menu bar app) logs no frames. `frame/2` renders
  the same view on request for `symphony dashboard`, which polls it over the
  control API.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.StatusDashboard.Renderer
  alias SymphonyElixirWeb.ObservabilityPubSub

  @minimum_idle_rerender_ms 1_000
  @startup_snapshot_grace_ms 5_000

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :render_fun,
    :format_fun,
    :started_at_ms,
    :token_samples,
    :last_tps_second,
    :last_tps_value,
    :last_rendered_content,
    :last_rendered_at_ms,
    :pending_content,
    :flush_timer_ref,
    :last_snapshot_fingerprint,
    :snapshot_consecutive_misses,
    :snapshot_stale?
  ]

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          render_fun: (String.t() -> term()),
          format_fun: (term(), number(), pos_integer() | nil -> String.t()),
          started_at_ms: integer(),
          token_samples: [{integer(), integer()}],
          last_tps_second: integer() | nil,
          last_tps_value: float() | nil,
          last_rendered_content: String.t() | nil,
          last_rendered_at_ms: integer() | nil,
          pending_content: String.t() | nil,
          flush_timer_ref: reference() | nil,
          last_snapshot_fingerprint: term() | nil,
          snapshot_consecutive_misses: non_neg_integer(),
          snapshot_stale?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Renders the current dashboard frame for a terminal `columns` wide, or the
  default width when nil. Returns `:unavailable` when the dashboard isn't running.
  """
  @spec frame(pos_integer() | nil, GenServer.name()) :: {:ok, String.t()} | :unavailable
  def frame(columns, server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, {:frame, columns})
      _ -> :unavailable
    end
  end

  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    observability = Config.settings!().observability
    refresh_ms = refresh_ms_override || observability.refresh_ms
    render_interval_ms = render_interval_ms_override || observability.render_interval_ms
    render_fun = Keyword.get(opts, :render_fun, &render_to_terminal/1)
    format_fun = Keyword.get(opts, :format_fun, &Renderer.format_snapshot_content/3)
    enabled = resolve_override(enabled_override, observability.dashboard_enabled and dashboard_enabled?())
    started_at_ms = System.monotonic_time(:millisecond)
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       render_fun: render_fun,
       format_fun: format_fun,
       started_at_ms: started_at_ms,
       token_samples: [],
       last_tps_second: nil,
       last_tps_value: nil,
       last_rendered_content: nil,
       last_rendered_at_ms: nil,
       pending_content: nil,
       flush_timer_ref: nil,
       last_snapshot_fingerprint: nil,
       snapshot_consecutive_misses: 0,
       snapshot_stale?: false
     }}
  end

  @spec render_offline_status_for_runtime() :: :ok
  def render_offline_status_for_runtime do
    if dashboard_enabled?() do
      render_offline_status()
    else
      :ok
    end
  end

  @spec render_offline_status() :: :ok
  def render_offline_status do
    Renderer.offline_status_content()
    |> render_to_terminal()

    :ok
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering offline status: #{Exception.message(error)}")
      :ok
  end

  @spec handle_call({:frame, pos_integer() | nil}, GenServer.from(), t()) ::
          {:reply, {:ok, String.t()} | :unavailable, t()}
  def handle_call({:frame, columns}, _from, state) do
    {snapshot_data, tps, next_state} = sample_snapshot(state, System.monotonic_time(:millisecond))
    {:reply, {:ok, state.format_fun.(snapshot_data, tps, columns)}, next_state}
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard frame: #{Exception.message(error)}")
      {:reply, :unavailable, state}
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{enabled: true} = state), do: {:noreply, maybe_render(refresh_runtime_config(state))}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:flush_render, timer_ref}, %{enabled: true, flush_timer_ref: timer_ref} = state) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      case state.pending_content do
        nil ->
          %{state | flush_timer_ref: nil}

        content ->
          state
          |> Map.put(:flush_timer_ref, nil)
          |> Map.put(:pending_content, nil)
          |> render_content(content, now_ms)
      end

    {:noreply, state}
  end

  def handle_info({:flush_render, _timer_ref}, state), do: {:noreply, state}
  def handle_info(:tick, state), do: {:noreply, state}

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = Config.settings!().observability

    %{
      state
      | enabled: resolve_override(state.enabled_override, observability.dashboard_enabled and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || observability.refresh_ms,
        render_interval_ms: state.render_interval_ms_override || observability.render_interval_ms
    }
  end

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    now_ms = System.monotonic_time(:millisecond)
    {snapshot_data, tps, state} = sample_snapshot(state, now_ms)

    if snapshot_data != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      content = state.format_fun.(snapshot_data, tps, nil)

      state
      |> maybe_update_snapshot_fingerprint(snapshot_data)
      |> maybe_enqueue_render(content, now_ms)
    else
      state
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard: #{Exception.message(error)}")
      state
  end

  # Reads the orchestrator snapshot and records a token sample for the throughput figure.
  defp sample_snapshot(state, now_ms) do
    {raw_snapshot_data, token_samples} =
      snapshot_with_samples(
        state.token_samples,
        now_ms,
        state.snapshot_consecutive_misses
      )

    snapshot_data = snapshot_data_for_render(raw_snapshot_data, state.started_at_ms, now_ms)

    state = Map.put(state, :token_samples, token_samples)
    state = update_snapshot_staleness_state(state, raw_snapshot_data)

    current_tokens = Renderer.snapshot_total_tokens(snapshot_data)

    {tps_second, tps} =
      Renderer.throttled_tps(
        state.last_tps_second,
        state.last_tps_value,
        now_ms,
        token_samples,
        current_tokens
      )

    {snapshot_data, tps, %{state | last_tps_second: tps_second, last_tps_value: tps}}
  end

  defp maybe_enqueue_render(state, content, now_ms) do
    cond do
      content == state.last_rendered_content ->
        state

      render_now?(state, now_ms) ->
        render_content(state, content, now_ms)

      true ->
        schedule_flush_render(%{state | pending_content: content}, now_ms)
    end
  end

  defp maybe_update_snapshot_fingerprint(state, snapshot_data) do
    if snapshot_data == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, snapshot_data)
    end
  end

  defp update_snapshot_staleness_state(%__MODULE__{} = state, {:ok, %{snapshot_stale?: true} = snapshot}) do
    if not state.snapshot_stale? do
      Logger.warning("snapshot stale",
        age_ms: Map.get(snapshot, :staleness_ms),
        orchestrator_mailbox_len: Map.get(snapshot, :orchestrator_mailbox_len),
        orchestrator_alive?: Map.get(snapshot, :orchestrator_alive?)
      )
    end

    %{
      state
      | snapshot_stale?: true,
        snapshot_consecutive_misses: Map.get(snapshot, :consecutive_misses, state.snapshot_consecutive_misses + 1)
    }
  end

  defp update_snapshot_staleness_state(%__MODULE__{} = state, {:ok, _snapshot}) do
    %{state | snapshot_stale?: false, snapshot_consecutive_misses: 0}
  end

  defp update_snapshot_staleness_state(%__MODULE__{} = state, _snapshot_data), do: state

  defp snapshot_data_for_render({:ok, _snapshot} = snapshot_data, _started_at_ms, _now_ms), do: snapshot_data

  defp snapshot_data_for_render(:error, started_at_ms, now_ms) do
    if startup_snapshot_pending?(started_at_ms, now_ms), do: :pending, else: :error
  end

  defp startup_snapshot_pending?(started_at_ms, now_ms) when is_integer(started_at_ms) and is_integer(now_ms) do
    now_ms - started_at_ms < @startup_snapshot_grace_ms
  end

  defp startup_snapshot_pending?(_started_at_ms, _now_ms), do: false

  defp periodic_rerender_due?(%{last_rendered_at_ms: nil}, _now_ms), do: true

  defp periodic_rerender_due?(%{last_rendered_at_ms: last_rendered_at_ms}, now_ms)
       when is_integer(last_rendered_at_ms) do
    now_ms - last_rendered_at_ms >= @minimum_idle_rerender_ms
  end

  defp periodic_rerender_due?(_state, _now_ms), do: false

  defp render_now?(%{last_rendered_at_ms: nil, flush_timer_ref: nil}, _now_ms), do: true

  defp render_now?(%{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms}, now_ms)
       when is_integer(last_rendered_at_ms) and is_integer(render_interval_ms) do
    now_ms - last_rendered_at_ms >= render_interval_ms
  end

  defp render_now?(_state, _now_ms), do: false

  defp schedule_flush_render(%{flush_timer_ref: timer_ref} = state, _now_ms) when is_reference(timer_ref),
    do: state

  defp schedule_flush_render(state, now_ms) do
    delay_ms = flush_delay_ms(state, now_ms)
    timer_ref = make_ref()
    Process.send_after(self(), {:flush_render, timer_ref}, delay_ms)
    %{state | flush_timer_ref: timer_ref}
  end

  defp flush_delay_ms(%{last_rendered_at_ms: nil}, _now_ms), do: 1

  defp flush_delay_ms(
         %{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms},
         now_ms
       ) do
    remaining = render_interval_ms - (now_ms - last_rendered_at_ms)
    max(1, remaining)
  end

  defp render_content(state, content, now_ms) do
    state.render_fun.(content)

    %{
      state
      | last_rendered_content: content,
        last_rendered_at_ms: now_ms,
        pending_content: nil,
        flush_timer_ref: nil
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering terminal dashboard frame: #{Exception.message(error)}")
      %{state | pending_content: nil, flush_timer_ref: nil}
  end

  defp snapshot_with_samples(token_samples, now_ms, consecutive_misses) do
    case snapshot_payload(consecutive_misses) do
      {:ok, %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot} ->
        total_tokens = Map.get(codex_totals, :total_tokens, 0)

        {
          {:ok,
           %{
             running: running,
             watching: Map.get(snapshot, :watching, []),
             retrying: retrying,
             awaiting_clarification: Map.get(snapshot, :awaiting_clarification, []),
             skipped: Map.get(snapshot, :skipped, []),
             codex_totals: codex_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             usage_limits: Map.get(snapshot, :usage_limits, []),
             workspace_lifecycle: Map.get(snapshot, :workspace_lifecycle),
             dispatch_state: Map.get(snapshot, :dispatch_state, %{active?: true, blockers: []}),
             polling: Map.get(snapshot, :polling),
             snapshot_stale?: Map.get(snapshot, :snapshot_stale?, false),
             staleness_ms: Map.get(snapshot, :staleness_ms),
             consecutive_misses: Map.get(snapshot, :consecutive_misses, 0),
             orchestrator_mailbox_len: Map.get(snapshot, :orchestrator_mailbox_len),
             orchestrator_alive?: Map.get(snapshot, :orchestrator_alive?)
           }},
          Renderer.update_token_samples(token_samples, now_ms, total_tokens)
        }

      :error ->
        {
          :error,
          Renderer.prune_samples(token_samples, now_ms)
        }
    end
  end

  defp snapshot_payload(consecutive_misses) do
    case Orchestrator.snapshot_cache_entry() do
      {:ok, %{snapshot: snapshot, system_ms: system_ms}} ->
        age_ms = max(0, System.system_time(:millisecond) - system_ms)
        stale_threshold_ms = snapshot_stale_threshold_ms()
        stale? = age_ms > stale_threshold_ms
        misses = if stale?, do: consecutive_misses + 1, else: 0
        diagnostics = if stale?, do: orchestrator_diagnostics(), else: %{}

        snapshot =
          snapshot
          |> Map.put(:snapshot_stale?, stale?)
          |> Map.put(:staleness_ms, if(stale?, do: age_ms, else: nil))
          |> Map.put(:consecutive_misses, misses)
          |> Map.merge(diagnostics)

        normalize_snapshot_payload(snapshot)

      :missing ->
        :error
    end
  end

  defp normalize_snapshot_payload(snapshot) do
    case snapshot do
      %{
        running: running,
        retrying: retrying,
        codex_totals: codex_totals
      } = snapshot
      when is_list(running) and is_list(retrying) ->
        {:ok,
         %{
           running: running,
           watching: Map.get(snapshot, :watching, []),
           retrying: retrying,
           awaiting_clarification: Map.get(snapshot, :awaiting_clarification, []),
           skipped: Map.get(snapshot, :skipped, []),
           codex_totals: codex_totals,
           rate_limits: Map.get(snapshot, :rate_limits),
           usage_limits: Map.get(snapshot, :usage_limits, []),
           workspace_lifecycle: Map.get(snapshot, :workspace_lifecycle),
           polling: Map.get(snapshot, :polling),
           dispatch_state: Map.get(snapshot, :dispatch_state, %{active?: true, blockers: []}),
           snapshot_stale?: Map.get(snapshot, :snapshot_stale?, false),
           staleness_ms: Map.get(snapshot, :staleness_ms),
           consecutive_misses: Map.get(snapshot, :consecutive_misses, 0),
           orchestrator_mailbox_len: Map.get(snapshot, :orchestrator_mailbox_len),
           orchestrator_alive?: Map.get(snapshot, :orchestrator_alive?)
         }}

      _ ->
        :error
    end
  end

  defp snapshot_stale_threshold_ms do
    Config.settings!().observability
    |> Map.get(:snapshot_publish_ms, 500)
    |> case do
      publish_ms when is_integer(publish_ms) and publish_ms > 0 -> publish_ms * 3
      _ -> 1_500
    end
  end

  defp orchestrator_diagnostics do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) ->
        %{
          orchestrator_alive?: Process.alive?(pid),
          orchestrator_mailbox_len: orchestrator_mailbox_len(pid)
        }

      _ ->
        %{orchestrator_alive?: false, orchestrator_mailbox_len: nil}
    end
  end

  defp orchestrator_mailbox_len(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when is_integer(len) -> len
      _ -> nil
    end
  end

  defp render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      content,
      "\n"
    ])
  end

  defp dashboard_enabled? do
    not mix_test_env?() and stdout_terminal?()
  end

  defp mix_test_env? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() == :test
      rescue
        _ -> false
      end
    else
      false
    end
  end

  # `:io.columns/0` answers only when standard output is a terminal, not a file or pipe.
  defp stdout_terminal?, do: match?({:ok, _columns}, :io.columns())

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end
