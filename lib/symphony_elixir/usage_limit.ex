defmodule SymphonyElixir.UsageLimit do
  @moduledoc """
  Per-provider holds on dispatch after a provider usage limit (`agent.usage_limit`).

  A run that ends on a usage limit (for Claude, a used-up five-hour or weekly window)
  holds new runs of the same provider until the window resets. Each hold is keyed by
  `{provider, scope}`: scope `:all` holds every run of the provider, a model scope
  (`"opus"`, `"sonnet"`) only runs whose model is in that family.

  At `resume_at` a hold moves to `phase: :canary`: one held run goes out alone while the
  hold keeps covering every other run, and the canary's outcome decides whether the hold
  clears or pauses again.

  The orchestrator owns the holds and persists them with `RunStore.put_usage_limits/1`;
  this module builds and matches them.
  """

  alias SymphonyElixir.RunStore

  @reason "claude_usage_limit"

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
          phase: :paused | :canary,
          canary_issue_id: String.t() | nil,
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
  a known reset time never brings the resume time forward. A canary hold goes back to
  `:paused`.
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
      reason: @reason,
      window: Map.get(info, :window),
      since: (existing && existing.since) || now,
      resets_at: resets_at,
      resume_at: resume_at,
      source: Map.get(info, :source),
      phase: :paused,
      canary_issue_id: nil,
      issue_identifier: Keyword.get(opts, :issue_identifier)
    }
  end

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

  @doc "Whether `entry` (or a key) holds a run with `profile` (its `provider` and `model`)."
  @spec covers?(entry() | key(), map()) :: boolean()
  def covers?(%{provider: provider, scope: scope}, profile), do: covers?({provider, scope}, profile)

  def covers?({provider, scope}, %{} = profile) do
    Map.get(profile, :provider, "anthropic") == provider and scope_matches?(scope, Map.get(profile, :model))
  end

  defp scope_matches?(:all, _model), do: true
  defp scope_matches?(scope, model) when is_binary(scope) and is_binary(model), do: String.contains?(String.downcase(model), scope)
  defp scope_matches?(_scope, _model), do: false

  @doc "Moves `entry` to the canary phase with `issue_id` as the one run let through."
  @spec canary(entry(), String.t()) :: entry()
  def canary(entry, issue_id) when is_binary(issue_id), do: Map.merge(entry, %{phase: :canary, canary_issue_id: issue_id})

  @doc "Whether `entry` is in the canary phase with `issue_id` as its canary."
  @spec canary?(entry(), String.t() | nil) :: boolean()
  def canary?(entry, issue_id), do: Map.get(entry, :phase) == :canary and Map.get(entry, :canary_issue_id) == issue_id

  @doc "`entry` back in the paused phase; a canary restored after a restart is chosen again."
  @spec paused(entry()) :: entry()
  def paused(entry), do: Map.merge(entry, %{phase: :paused, canary_issue_id: nil})

  @doc """
  The first hold in `usage_limits` that covers `profile`, or nil. A hold in the canary
  phase does not hold its own canary, `issue_id`.
  """
  @spec holding(map(), map(), String.t() | nil) :: entry() | nil
  def holding(usage_limits, profile, issue_id \\ nil) when is_map(usage_limits) and is_map(profile) do
    usage_limits
    |> Enum.sort_by(fn {_key, entry} -> DateTime.to_unix(entry.resume_at) end, :desc)
    |> Enum.find_value(fn {_key, entry} -> if covers?(entry, profile) and not canary?(entry, issue_id), do: entry end)
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
end
