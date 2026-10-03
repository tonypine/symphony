defmodule SymphonyElixir.UsageLimit do
  @moduledoc """
  Per-provider holds on dispatch after a provider usage limit (`agent.usage_limit`).

  A run that ends on a usage limit (for Claude, a used-up five-hour or weekly window; for
  Codex, a used-up primary or secondary window) holds new runs of the same provider until the
  window resets. Codex runs are provider `"openai"` (see `for_agent_kind/2`), so a Claude hold
  never holds them and a Codex hold never holds Claude runs. Each hold is keyed by
  `{provider, scope}`: scope `:all` holds every run of the provider, a model scope
  (`"opus"`, `"sonnet"`) only runs whose model is in that family.

  The orchestrator owns the holds and persists them with `RunStore.put_usage_limits/1`;
  this module builds and matches them.
  """

  alias SymphonyElixir.RunStore

  @type key :: {String.t(), String.t() | :all}

  @type entry :: %{
          provider: String.t(),
          scope: String.t() | :all,
          reason: String.t(),
          window: String.t() | nil,
          since: DateTime.t(),
          resets_at: DateTime.t() | nil,
          resume_at: DateTime.t(),
          source: atom() | nil,
          phase: :paused,
          issue_identifier: String.t() | nil
        }

  @typedoc "The latest reset time and utilization seen per `{provider, window}`."
  @type windows :: %{
          optional({String.t(), String.t()}) => %{resets_at: DateTime.t() | nil, utilization: number() | nil}
        }

  @doc "The hold key for a usage-limit `info` from the agent."
  @spec key(map()) :: key()
  def key(info) when is_map(info), do: {Map.get(info, :provider) || "anthropic", Map.get(info, :scope) || :all}

  @doc """
  Creates the hold for `info`, or refreshes `existing`. A known reset time is used as
  reported; an unknown one falls back to the remembered reset time of the window (see
  `remember_windows/2`), then to `now + unknown_reset_retry_seconds`. A refresh without
  a known reset time never brings the resume time forward.
  """
  @spec put(entry() | nil, map(), keyword()) :: entry()
  def put(existing, info, opts) when is_map(info) do
    now = Keyword.fetch!(opts, :now)
    config = Keyword.fetch!(opts, :config)
    {provider, scope} = key(info)
    resets_at = Map.get(info, :resets_at)

    resume_at =
      if resets_at do
        DateTime.add(resets_at, config.resume_margin_seconds)
      else
        unknown_reset_resume_at(info, Keyword.get(opts, :windows, %{}), now, config)
      end

    resume_at =
      case existing do
        %{resume_at: %DateTime{} = previous} when is_nil(resets_at) -> latest(previous, resume_at)
        _ -> resume_at
      end

    %{
      provider: provider,
      scope: scope,
      reason: reason(provider),
      window: Map.get(info, :window),
      since: (existing && existing.since) || now,
      resets_at: resets_at,
      resume_at: resume_at,
      source: Map.get(info, :source),
      phase: :paused,
      issue_identifier: Keyword.get(opts, :issue_identifier)
    }
  end

  defp reason("openai"), do: "codex_usage_limit"
  defp reason(_provider), do: "claude_usage_limit"

  defp unknown_reset_resume_at(info, windows, now, config) do
    case remembered_reset(info, windows, now) do
      %DateTime{} = resets_at -> DateTime.add(resets_at, config.resume_margin_seconds)
      nil -> DateTime.add(now, config.unknown_reset_retry_seconds)
    end
  end

  # With no window named (the result-text fallback), the window closest to used up is
  # the best guess for the one that ran out.
  defp remembered_reset(info, windows, now) do
    provider = Map.get(info, :provider) || "anthropic"
    window = Map.get(info, :window)

    windows
    |> Enum.filter(fn {{window_provider, window_name}, %{resets_at: resets_at}} ->
      window_provider == provider and (is_nil(window) or window_name == window) and
        match?(%DateTime{}, resets_at) and DateTime.compare(resets_at, now) == :gt
    end)
    |> Enum.max_by(fn {_key, seen} -> {seen.utilization || 0, DateTime.to_unix(seen.resets_at)} end, fn -> nil end)
    |> case do
      {_key, %{resets_at: resets_at}} -> resets_at
      nil -> nil
    end
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  @doc """
  Keeps the reset time and utilization from a worker update's `usage_windows`
  (`%{window => %{resets_at:, utilization:}}`), so a later rejection without a reset
  time can still be timed.
  """
  @spec remember_windows(windows(), map(), String.t()) :: windows()
  def remember_windows(windows, usage_windows, provider \\ "anthropic") when is_map(windows) and is_map(usage_windows) do
    Enum.reduce(usage_windows, windows, fn
      {window, %{} = seen}, acc when is_binary(window) ->
        Map.put(acc, {provider, window}, %{resets_at: Map.get(seen, :resets_at), utilization: Map.get(seen, :utilization)})

      _other, acc ->
        acc
    end)
  end

  @doc "`profile` with the provider a run of agent `kind` is limited by: Codex runs are `\"openai\"`."
  @spec for_agent_kind(map(), String.t() | nil) :: map()
  def for_agent_kind(profile, "codex") when is_map(profile), do: Map.put(profile, :provider, "openai")
  def for_agent_kind(profile, _kind) when is_map(profile), do: profile

  @doc "Whether `entry` (or a key) holds a run with `profile` (its `provider` and `model`)."
  @spec covers?(entry() | key(), map()) :: boolean()
  def covers?(%{provider: provider, scope: scope}, profile), do: covers?({provider, scope}, profile)

  def covers?({provider, scope}, %{} = profile) do
    Map.get(profile, :provider, "anthropic") == provider and scope_matches?(scope, Map.get(profile, :model))
  end

  defp scope_matches?(:all, _model), do: true
  defp scope_matches?(scope, model) when is_binary(scope) and is_binary(model), do: String.contains?(String.downcase(model), scope)
  defp scope_matches?(_scope, _model), do: false

  @doc "The first hold in `usage_limits` that covers `profile`, or nil."
  @spec holding(map(), map()) :: entry() | nil
  def holding(usage_limits, profile) when is_map(usage_limits) and is_map(profile) do
    usage_limits
    |> Enum.sort_by(fn {_key, entry} -> DateTime.to_unix(entry.resume_at) end, :desc)
    |> Enum.find_value(fn {_key, entry} -> if covers?(entry, profile), do: entry end)
  end

  @doc "The persisted hold that covers `profile`, or nil; for dispatch paths outside the orchestrator."
  @spec persisted_holding(map(), module()) :: entry() | nil
  def persisted_holding(profile, run_store \\ RunStore) when is_map(profile) do
    case run_store.get_usage_limits() do
      %{} = usage_limits -> holding(usage_limits, profile)
      {:error, _reason} -> nil
    end
  end

  @doc "Milliseconds from `now` until `entry` resumes, never negative."
  @spec remaining_ms(entry(), DateTime.t()) :: non_neg_integer()
  def remaining_ms(%{resume_at: resume_at}, %DateTime{} = now), do: max(DateTime.diff(resume_at, now, :millisecond), 0)

  @doc "The `scope` as it reads in logs."
  @spec scope_label(String.t() | :all) :: String.t()
  def scope_label(:all), do: "all"
  def scope_label(scope) when is_binary(scope), do: scope

  @doc "The limit a hold is on, as people read it: `Claude 5-hour limit`."
  @spec limit_label(map()) :: String.t()
  def limit_label(entry) when is_map(entry) do
    "#{provider_label(Map.get(entry, :provider))} #{window_label(Map.get(entry, :window))}"
  end

  defp provider_label(provider) when provider in [nil, "anthropic"], do: "Claude"
  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label(provider), do: to_string(provider)

  defp window_label("five_hour"), do: "5-hour limit"
  defp window_label("seven_day"), do: "weekly limit"
  defp window_label("seven_day_opus"), do: "weekly Opus limit"
  defp window_label("seven_day_sonnet"), do: "weekly Sonnet limit"
  defp window_label(nil), do: "usage limit"
  defp window_label(window), do: "#{window} limit"

  @doc """
  The dashboard banner for a hold: `Paused: Claude 5-hour limit, resumes ~14:05`. The resume
  time is in local time, with the date when it is not today. `resume_at` may be a
  `DateTime` or an ISO 8601 string. `opts[:to_local]` converts a UTC `NaiveDateTime` to local
  time (default: the host's time zone).
  """
  @spec banner(map(), DateTime.t(), keyword()) :: String.t()
  def banner(entry, %DateTime{} = now, opts \\ []) when is_map(entry) do
    "Paused: #{limit_label(entry)}" <> resume_suffix(datetime(Map.get(entry, :resume_at)), now, opts)
  end

  defp resume_suffix(nil, _now, _opts), do: ""

  defp resume_suffix(%DateTime{} = resume_at, now, opts) do
    to_local = Keyword.get(opts, :to_local, &host_local_time/1)
    local = to_local.(DateTime.to_naive(resume_at))
    time = local |> NaiveDateTime.to_time() |> Calendar.strftime("%H:%M")

    if NaiveDateTime.to_date(local) == NaiveDateTime.to_date(to_local.(DateTime.to_naive(now))) do
      ", resumes ~#{time}"
    else
      ", resumes ~#{Calendar.strftime(local, "%b %-d")} #{time}"
    end
  end

  defp datetime(%DateTime{} = datetime), do: datetime

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp datetime(_value), do: nil

  defp host_local_time(%NaiveDateTime{} = utc) do
    utc
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  @doc """
  The holds as the status snapshot lists them, soonest resume first, each with the latest
  utilization seen for its window.
  """
  @spec snapshot(map(), windows()) :: [map()]
  def snapshot(usage_limits, windows) when is_map(usage_limits) and is_map(windows) do
    usage_limits
    |> Map.values()
    |> Enum.sort_by(&DateTime.to_unix(&1.resume_at))
    |> Enum.map(fn entry ->
      seen = Map.get(windows, {entry.provider, entry.window}, %{})

      entry
      |> Map.take([:provider, :scope, :reason, :window, :phase, :since, :resets_at, :resume_at, :source, :issue_identifier])
      |> Map.put(:utilization, Map.get(seen, :utilization))
    end)
  end
end
