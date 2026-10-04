defmodule SymphonyElixir.DispatchState do
  @moduledoc """
  Computes a unified dispatch-state view from orchestrator state, config and env.

  A dispatch is `active?` only when zero operational blockers apply. Blockers
  are tagged maps so callers can render each one with a specific message +
  remediation.

  A provider usage-limit hold (`:usage_limit`) is listed for every hold, but only makes
  dispatch inactive when the holds cover every run profile in use (`config.run_profiles`,
  each a `provider`, `model` and run `kind`): runs on another provider or model still dispatch,
  and so do landing runs under a headroom hold (see `UsageLimit.holds?/2`).
  """

  alias SymphonyElixir.UsageLimit

  @type blocker ::
          %{kind: :manual, reason: String.t() | nil, since: DateTime.t() | nil}
          | %{
              kind: :budget,
              used: non_neg_integer(),
              limit: pos_integer(),
              day_started_on: Date.t(),
              resets_on: Date.t()
            }
          | %{kind: :missing_api_key, provider: atom()}
          | %{
              kind: :config_invalid,
              message: String.t(),
              since: DateTime.t(),
              consecutive_failures: non_neg_integer()
            }
          | %{
              kind: :tracker_unavailable,
              tracker: atom(),
              reason: atom(),
              since: DateTime.t(),
              consecutive_failures: non_neg_integer()
            }
          | %{
              kind: :usage_limit,
              provider: String.t(),
              scope: String.t() | :all,
              window: String.t() | nil,
              resets_at: DateTime.t() | nil,
              resume_at: DateTime.t(),
              phase: atom()
            }

  @type t :: %{active?: boolean(), blockers: [blocker]}

  @default_tracker_unavailable_threshold 3
  @api_key_feature_keys [:quality_gate, :learnings]
  @provider_env_vars %{
    anthropic: "ANTHROPIC_API_KEY",
    openai: "OPENAI_API_KEY"
  }

  @spec compute(map(), map(), map()) :: t()
  def compute(state, config, env) do
    blockers =
      []
      |> maybe_manual(state)
      |> maybe_budget(state, config)
      |> maybe_missing_api_keys(config, env)
      |> maybe_missing_tracker_api_key(config)
      |> maybe_tracker_unavailable(state, config)
      |> Enum.reverse()

    holds = Map.get(state, :usage_limits, [])

    %{
      active?: blockers == [] and not every_profile_held?(holds, config),
      blockers: blockers ++ Enum.map(holds, &usage_limit_blocker/1)
    }
  end

  defp every_profile_held?([], _config), do: false

  defp every_profile_held?(holds, config) do
    config
    |> Map.get(:run_profiles, [])
    |> Enum.all?(fn profile -> Enum.any?(holds, &UsageLimit.holds?(&1, profile)) end)
  end

  defp usage_limit_blocker(hold) do
    hold
    |> Map.take([:provider, :scope, :window, :resets_at, :resume_at, :phase])
    |> Map.put(:kind, :usage_limit)
  end

  defp maybe_manual(blockers, %{pause: %{paused: true} = pause}) do
    [
      %{
        kind: :manual,
        reason: Map.get(pause, :reason),
        since: Map.get(pause, :paused_at)
      }
      | blockers
    ]
  end

  defp maybe_manual(blockers, _state), do: blockers

  defp maybe_budget(blockers, state, %{daily_limit: limit})
       when is_integer(limit) and limit > 0 do
    used = Map.get(state, :budget_daily_used, 0) || 0

    if used >= limit do
      day = Map.get(state, :budget_day_started_on) || Date.utc_today()

      [
        %{
          kind: :budget,
          used: used,
          limit: limit,
          day_started_on: day,
          resets_on: Date.add(day, 1)
        }
        | blockers
      ]
    else
      blockers
    end
  end

  defp maybe_budget(blockers, _state, _config), do: blockers

  defp maybe_missing_api_keys(blockers, config, env) do
    config
    |> required_api_key_providers()
    |> Enum.reduce(blockers, fn provider, blockers ->
      env_var = Map.fetch!(@provider_env_vars, provider)

      case Map.get(env, env_var) do
        key when is_binary(key) and key != "" -> blockers
        _ -> [%{kind: :missing_api_key, provider: provider} | blockers]
      end
    end)
  end

  defp required_api_key_providers(config) when is_map(config) do
    @api_key_feature_keys
    |> Enum.map(&Map.get(config, &1))
    |> Enum.filter(&feature_enabled?/1)
    |> Enum.map(&feature_provider/1)
    |> Enum.flat_map(&normalize_provider/1)
    |> Enum.uniq()
  end

  defp feature_enabled?(feature) when is_map(feature), do: Map.get(feature, :enabled) == true
  defp feature_enabled?(_feature), do: false

  defp feature_provider(feature) when is_map(feature), do: Map.get(feature, :provider)

  defp normalize_provider(:anthropic), do: [:anthropic]
  defp normalize_provider("anthropic"), do: [:anthropic]
  defp normalize_provider(:openai), do: [:openai]
  defp normalize_provider("openai"), do: [:openai]
  defp normalize_provider(_provider), do: []

  defp maybe_missing_tracker_api_key(blockers, %{tracker_kind: "linear", tracker_api_key_present?: false}),
    do: [%{kind: :missing_api_key, provider: :linear} | blockers]

  defp maybe_missing_tracker_api_key(blockers, _config), do: blockers

  defp maybe_tracker_unavailable(blockers, %{tracker_health: tracker_health}, config)
       when is_map(tracker_health) and is_map(config) do
    consecutive_failures = Map.get(tracker_health, :consecutive_failures, 0)
    since = Map.get(tracker_health, :since)
    threshold = tracker_unavailable_threshold(config)

    if is_integer(consecutive_failures) and consecutive_failures >= threshold and match?(%DateTime{}, since) do
      reason = normalize_tracker_unavailable_reason(Map.get(tracker_health, :reason))
      tracker = normalize_tracker(Map.get(tracker_health, :tracker))

      [tracker_blocker(tracker, reason, since, consecutive_failures) | blockers]
    else
      blockers
    end
  end

  defp maybe_tracker_unavailable(blockers, _state, _config), do: blockers

  defp tracker_blocker(_tracker, {:config_invalid, message}, since, consecutive_failures) do
    %{
      kind: :config_invalid,
      message: message,
      since: since,
      consecutive_failures: consecutive_failures
    }
  end

  defp tracker_blocker(tracker, reason, since, consecutive_failures) do
    %{
      kind: :tracker_unavailable,
      tracker: tracker,
      reason: reason,
      since: since,
      consecutive_failures: consecutive_failures
    }
  end

  defp tracker_unavailable_threshold(%{tracker_unavailable_threshold: threshold})
       when is_integer(threshold) and threshold > 0 do
    threshold
  end

  defp tracker_unavailable_threshold(_config), do: @default_tracker_unavailable_threshold

  defp normalize_tracker(:linear), do: :linear
  defp normalize_tracker("linear"), do: :linear
  defp normalize_tracker(:memory), do: :memory
  defp normalize_tracker("memory"), do: :memory
  defp normalize_tracker(tracker) when is_atom(tracker), do: tracker
  defp normalize_tracker(_tracker), do: :unknown

  defp normalize_tracker_unavailable_reason(:missing_linear_api_token), do: :missing_linear_api_token
  defp normalize_tracker_unavailable_reason(:linear_api_request), do: :linear_api_request
  defp normalize_tracker_unavailable_reason({:linear_api_request, _reason}), do: :linear_api_request

  defp normalize_tracker_unavailable_reason(reason) do
    case config_invalid_message(reason) do
      message when is_binary(message) -> {:config_invalid, message}
      nil -> :unknown
    end
  end

  defp config_invalid_message({:invalid_workflow_config, message}) when is_binary(message) do
    invalid_workflow_config_message(message)
  end

  defp config_invalid_message(:missing_linear_scoping_filter),
    do: "Linear scoping filter missing in WORKFLOW.md"

  defp config_invalid_message(:missing_tracker_kind), do: "Tracker kind missing in WORKFLOW.md"

  defp config_invalid_message({:unsupported_tracker_kind, kind}),
    do: "Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}"

  defp config_invalid_message({:unsupported_agent_kind, kind}),
    do: "Unsupported agent runtime in WORKFLOW.md: #{inspect(kind)}"

  defp config_invalid_message({:missing_workflow_file, path, reason}),
    do: "Missing WORKFLOW.md at #{path}: #{inspect(reason)}"

  defp config_invalid_message(:workflow_front_matter_not_a_map),
    do: "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

  defp config_invalid_message({:workflow_parse_error, reason}),
    do: "Failed to parse WORKFLOW.md: #{inspect(reason)}"

  defp config_invalid_message({:config_invalid, message}) when is_binary(message), do: message
  defp config_invalid_message(_reason), do: nil

  defp invalid_workflow_config_message("WORKFLOW.md: " <> message),
    do: "Invalid WORKFLOW.md config: #{message}"

  defp invalid_workflow_config_message("symphony.yml: " <> message),
    do: "Invalid symphony.yml config: #{message}"

  defp invalid_workflow_config_message(message), do: "Invalid WORKFLOW.md config: #{message}"
end
