defmodule SymphonyElixir.ShippedToday do
  @moduledoc """
  The tickets Symphony saw ship on the host's local day, for `shipped_today` in `/api/v1/state`.

  `completed_at` stays in UTC; only the day boundary follows the host's time zone, the one the Mac
  app shows clock times in. Every function takes `to_local`, which converts a UTC `NaiveDateTime`
  to local time (default: the host's time zone), so tests can pin the zone.
  """

  @type entry :: %{
          required(:issue_id) => String.t(),
          required(:completed_at) => DateTime.t(),
          optional(atom()) => term()
        }
  @type shipped :: %{optional(String.t()) => entry()}
  @type to_local :: (NaiveDateTime.t() -> NaiveDateTime.t())

  @doc "The host's local calendar day at the UTC instant `at`."
  @spec local_date(DateTime.t(), to_local()) :: Date.t()
  def local_date(%DateTime{} = at, to_local \\ &host_local_time/1) do
    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> to_local.()
    |> NaiveDateTime.to_date()
  end

  @doc "Adds `entry`, shipped at `now`, and drops the entries from an earlier local day."
  @spec record(shipped(), entry(), DateTime.t(), to_local()) :: shipped()
  def record(shipped, %{issue_id: issue_id} = entry, %DateTime{} = now, to_local \\ &host_local_time/1) do
    today = local_date(now, to_local)

    shipped
    |> Map.filter(fn {_issue_id, shipped} -> local_date(shipped.completed_at, to_local) == today end)
    |> Map.put(issue_id, entry)
  end

  @doc """
  The tickets shipped on `now`'s local day before a restart, from the run records: each carries
  the time Symphony noted its `issue_completed` event. The newest run of a ticket comes first.
  """
  @spec hydrate([map()], DateTime.t(), to_local()) :: shipped()
  def hydrate(runs, %DateTime{} = now, to_local \\ &host_local_time/1) do
    today = local_date(now, to_local)

    for run <- runs,
        %DateTime{} = completed_at <- [Map.get(run, :issue_completed_notified_at)],
        local_date(completed_at, to_local) == today,
        issue_id = Map.get(run, :issue_id),
        is_binary(issue_id),
        reduce: %{} do
      acc ->
        Map.put_new(acc, issue_id, %{
          issue_id: issue_id,
          identifier: Map.get(run, :issue_identifier),
          title: Map.get(run, :title),
          repo_key: Map.get(run, :repo_key),
          completed_at: completed_at
        })
    end
  end

  @doc "The entries shipped on `now`'s local day, newest first."
  @spec today(shipped(), DateTime.t(), to_local()) :: [entry()]
  def today(shipped, %DateTime{} = now, to_local \\ &host_local_time/1) do
    today = local_date(now, to_local)

    shipped
    |> Map.values()
    |> Enum.filter(&(local_date(&1.completed_at, to_local) == today))
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
  end

  defp host_local_time(%NaiveDateTime{} = utc) do
    utc
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
