defmodule SymphonyElixir.Shipped do
  @moduledoc """
  The tickets merged over the last days, for `GET /api/v1/shipped` and the Mac app's Shipped view,
  from the run records and the tickets' signals ledger alone (no Linear request).

  A ticket counts as merged when Symphony noted its `issue_completed` event, on the host's local
  day, as `shipped_today` in `/api/v1/state` counts it, so today's count matches the Overview's
  Shipped today. Its initiative is the plan ticket kept on its run when the completion was noted,
  else the cached plan that lists it (`SymphonyElixir.Initiatives`). Its time from Todo to Done
  runs from Symphony's first claim of it (the `claim` signal: the move out of Todo), else its first
  run, to the merge.
  """

  alias SymphonyElixir.{Initiatives, RunStore, ShippedToday, TicketState, URLUtils}

  @default_days 7
  @max_days 90
  # The run that carries a ticket's completion can start well before the merge.
  @lookback_days 30

  @type payload :: map()

  @doc """
  The tickets merged in the `params["days"]` local days ending today (default #{@default_days}, at
  most #{@max_days}), newest first. `opts`: `:now` (a `DateTime`), `:to_local` (see
  `SymphonyElixir.ShippedToday`), `:runs_started_on` (a UTC `Date` → runs function), `:issue_runs`
  (a repo key and issue id → runs function), `:ticket_states` and `:initiatives`.
  """
  @spec payload(map(), keyword()) :: {:ok, payload()} | {:error, :invalid_days}
  def payload(params, opts \\ []) when is_map(params) do
    with {:ok, days} <- parse_days(Map.get(params, "days")) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      local_date = local_date_fun(Keyword.get(opts, :to_local))
      today = local_date.(now)
      from = Date.add(today, 1 - days)
      dates = Date.range(from, today)
      runs_started_on = Keyword.get(opts, :runs_started_on, &RunStore.list_runs_started_on/1)

      context = %{
        local_date: local_date,
        issue_runs: Keyword.get(opts, :issue_runs, &RunStore.list_issue_runs/2),
        claims: opts |> Keyword.get_lazy(:ticket_states, &RunStore.list_all_ticket_states/0) |> claims(),
        initiatives: Keyword.get_lazy(opts, :initiatives, &Initiatives.cached/0)
      }

      tickets =
        from
        |> Date.add(-@lookback_days)
        |> Date.range(DateTime.to_date(now))
        |> Enum.flat_map(&list_or_empty(runs_started_on.(&1)))
        |> Enum.filter(&completed?/1)
        |> Enum.group_by(&{Map.get(&1, :repo_key), &1.issue_id})
        |> Enum.map(fn {_key, runs} -> Enum.max_by(runs, & &1.issue_completed_notified_at, DateTime) end)
        |> Enum.filter(&(local_date.(&1.issue_completed_notified_at) in dates))
        |> Enum.sort_by(& &1.issue_completed_notified_at, {:desc, DateTime})
        |> Enum.map(&ticket(&1, context))

      counts = Enum.frequencies_by(tickets, & &1.date)

      {:ok,
       %{
         days: days,
         from: Date.to_iso8601(from),
         to: Date.to_iso8601(today),
         total: length(tickets),
         shipped_per_day: Enum.map(dates, &%{date: Date.to_iso8601(&1), shipped: Map.get(counts, Date.to_iso8601(&1), 0)}),
         tickets: tickets
       }}
    end
  end

  defp local_date_fun(nil), do: &ShippedToday.local_date/1
  defp local_date_fun(to_local), do: &ShippedToday.local_date(&1, to_local)

  defp parse_days(nil), do: {:ok, @default_days}
  defp parse_days(days) when is_integer(days) and days in 1..@max_days, do: {:ok, days}

  defp parse_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} -> parse_days(days)
      _ -> {:error, :invalid_days}
    end
  end

  defp parse_days(_days), do: {:error, :invalid_days}

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_error), do: []

  defp completed?(run), do: is_binary(Map.get(run, :issue_id)) and match?(%DateTime{}, Map.get(run, :issue_completed_notified_at))

  # The first time Symphony claimed each ticket, by repo key and issue id.
  defp claims(records) do
    for record <- list_or_empty(records),
        record = TicketState.normalize(record),
        %{name: "claim", at: %DateTime{} = at} <- record.signals,
        reduce: %{} do
      acc -> Map.update(acc, {record.repo_key, record.issue_id}, at, &Enum.min([&1, at], DateTime))
    end
  end

  defp ticket(run, context) do
    repo_key = Map.get(run, :repo_key)
    runs = [run | list_or_empty(context.issue_runs.(repo_key, run.issue_id))]
    merged_at = run.issue_completed_notified_at
    starts = for %{started_at: %DateTime{} = started_at} <- runs, do: started_at
    todo_at = Map.get(context.claims, {repo_key, run.issue_id}) || Enum.min(starts, DateTime, fn -> nil end)

    %{
      issue_id: run.issue_id,
      identifier: Map.get(run, :issue_identifier),
      title: Map.get(run, :title),
      repo_key: repo_key,
      initiative: initiative(run, context.initiatives),
      pr_url: Enum.find_value(runs, &URLUtils.pull_request_url/1),
      merged_at: iso8601(merged_at),
      date: merged_at |> context.local_date.() |> Date.to_iso8601(),
      todo_at: todo_at && iso8601(todo_at),
      todo_to_done_seconds: todo_at && max(DateTime.diff(merged_at, todo_at), 0)
    }
  end

  # Whole seconds, as Symphony writes its other timestamps.
  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp initiative(%{initiative: %{} = initiative}, _initiatives),
    do: %{identifier: Map.get(initiative, :identifier), title: Map.get(initiative, :title)}

  defp initiative(run, initiatives), do: Initiatives.parent_of(run.issue_id, initiatives)
end
