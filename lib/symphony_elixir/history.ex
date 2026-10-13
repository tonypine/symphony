defmodule SymphonyElixir.History do
  @moduledoc """
  What the crew used and shipped over the last days, for `GET /api/v1/history`, from the run
  records alone (no Linear request).

  Days are UTC, the day the daily token budget resets on. A run counts on the day it started; its
  tokens include its pre-push reviewer's. A ticket counts as merged on the day Symphony noted its
  `issue_completed` event. The provider is the one the run recorded, else the one its model
  names.
  """

  alias SymphonyElixir.{Config, RunStore}

  @default_days 14
  @max_days 90

  @type payload :: map()

  @doc """
  The history for `params["days"]` days ending today (default #{@default_days}, at most
  #{@max_days}). `opts`: `:today` (a `Date`), `:runs_started_on` (a `Date` → runs function) and
  `:agent` (the `agent` settings with `max_tokens_per_day` and `max_tokens_per_issue`).
  """
  @spec payload(map(), keyword()) :: {:ok, payload()} | {:error, :invalid_days}
  def payload(params, opts \\ []) when is_map(params) do
    with {:ok, days} <- parse_days(Map.get(params, "days")) do
      today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
      runs_started_on = Keyword.get(opts, :runs_started_on, &RunStore.list_runs_started_on/1)
      agent = Keyword.get_lazy(opts, :agent, fn -> Config.settings!().agent end)
      dates = Enum.map((days - 1)..0//-1, &Date.add(today, -&1))
      runs = Enum.flat_map(dates, &list_or_empty(runs_started_on.(&1)))
      cap = Map.get(agent, :max_tokens_per_issue)

      {:ok,
       %{
         days: days,
         from: Date.to_iso8601(List.first(dates)),
         to: Date.to_iso8601(today),
         daily_budget: Map.get(agent, :max_tokens_per_day),
         per_ticket_cap: cap,
         tokens_per_day: tokens_per_day(runs, dates),
         tickets: tickets(runs, cap),
         merged_per_day: merged_per_day(runs, dates)
       }}
    end
  end

  @doc "The provider that served `run`: the recorded one, else the one its model names."
  @spec provider(map()) :: String.t()
  def provider(run) when is_map(run) do
    case Map.get(run, :provider) do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> run |> Map.get(:model) |> model_provider()
    end
  end

  defp model_provider(model) when is_binary(model) do
    model = String.downcase(model)

    cond do
      String.contains?(model, "/") -> "openrouter"
      String.starts_with?(model, ["claude", "opus", "sonnet", "haiku", "fable"]) -> "anthropic"
      String.starts_with?(model, ["gpt", "codex", "o1", "o3", "o4"]) -> "openai"
      true -> "unknown"
    end
  end

  defp model_provider(_model), do: "unknown"

  defp parse_days(nil), do: {:ok, @default_days}
  defp parse_days(days) when is_integer(days) and days in 1..@max_days, do: {:ok, days}

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} -> parse_days(days)
      _ -> {:error, :invalid_days}
    end
  end

  defp parse_days(_days), do: {:error, :invalid_days}

  defp list_or_empty(runs) when is_list(runs), do: runs
  defp list_or_empty(_error), do: []

  defp tokens_per_day(runs, dates) do
    by_day = Enum.group_by(runs, &run_date/1)

    Enum.map(dates, fn date ->
      providers =
        by_day
        |> Map.get(date, [])
        |> Enum.group_by(&provider/1, &run_total_tokens/1)
        |> Map.new(fn {provider, tokens} -> {provider, Enum.sum(tokens)} end)

      %{date: Date.to_iso8601(date), total_tokens: providers |> Map.values() |> Enum.sum(), providers: providers}
    end)
  end

  defp tickets(runs, cap) do
    runs
    |> Enum.filter(&is_binary(Map.get(&1, :issue_id)))
    |> Enum.sort_by(&Map.get(&1, :started_at), {:desc, DateTime})
    |> Enum.group_by(&Map.get(&1, :issue_id))
    |> Enum.map(fn {issue_id, [newest | _] = issue_runs} ->
      %{
        issue_id: issue_id,
        identifier: Map.get(newest, :issue_identifier),
        title: Map.get(newest, :title),
        repo_key: Map.get(newest, :repo_key),
        total_tokens: issue_runs |> Enum.map(&run_total_tokens/1) |> Enum.sum(),
        attempts: length(issue_runs),
        cap: cap
      }
    end)
    |> Enum.sort_by(&{-&1.total_tokens, &1.identifier || ""})
  end

  defp merged_per_day(runs, dates) do
    merged =
      for run <- runs,
          %DateTime{} = completed_at <- [Map.get(run, :issue_completed_notified_at)],
          issue_id = Map.get(run, :issue_id),
          is_binary(issue_id),
          into: %{},
          do: {issue_id, DateTime.to_date(completed_at)}

    counts = merged |> Map.values() |> Enum.frequencies()
    Enum.map(dates, &%{date: Date.to_iso8601(&1), merged: Map.get(counts, &1, 0)})
  end

  defp run_date(%{started_at: %DateTime{} = started_at}), do: DateTime.to_date(started_at)

  defp run_total_tokens(run), do: total_tokens(Map.get(run, :tokens)) + total_tokens(Map.get(run, :reviewer_tokens))

  defp total_tokens(%{total_tokens: tokens}) when is_integer(tokens), do: tokens
  defp total_tokens(_tokens), do: 0
end
