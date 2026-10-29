defmodule SymphonyElixir.Dispatch.Shadow do
  @moduledoc """
  The dispatch shadow: before the dispatcher trusts the ticket records, every poll cycle compares
  the candidates the poll cache gives with the ones the records give
  (`SymphonyElixir.Dispatch.Candidates`) and keeps the differences here, so `/api/v1/state` shows
  whether the two paths agree (`dispatch_shadow`). Dispatch keeps reading the poll cache.

  `compare/2` is pure. The report lives in a public ETS table owned by this server, so recording
  never waits on a process; without the server (some tests), recording is a no-op and the report is
  empty. It keeps how many cycles were compared and how many had a difference since Symphony
  started, the differences of the last cycles of the window (`dispatch.shadow_window`), and the
  last ten differences that appeared, newest first. A difference that lasts over several cycles
  appears, and is logged at warning level, once; once it clears, it appears again if it comes back.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Linear.Issue

  @table __MODULE__
  @recent_limit 10
  @field_order %{candidate: 0, state: 1, priority: 2}
  @empty_summary %{cycles_compared: 0, cycles_with_differences: 0, window_cycles: 0, window_differences: 0, recent: []}

  @typedoc """
  Which side has the ticket: only the poll, only the record, or both with a different `field`.
  """
  @type side :: :poll | :record | :both

  @typedoc """
  What differs: whether it is a candidate at all (`candidate`), its state or its priority.
  """
  @type field :: :candidate | :state | :priority

  @typedoc """
  One difference: the ticket, its side and field, and what each side has (the state for
  `candidate`, nil on the side without the ticket).
  """
  @type difference :: %{
          repo_key: String.t() | nil,
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          side: side(),
          field: field(),
          poll: term(),
          record: term()
        }

  @type summary :: %{
          cycles_compared: non_neg_integer(),
          cycles_with_differences: non_neg_integer(),
          window_cycles: non_neg_integer(),
          window_differences: non_neg_integer(),
          recent: [map()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  The differences between `poll_candidates` (the poll cache's candidates) and `record_candidates`
  (the records'), matched by issue id: a ticket only the poll has, one only the record has, and one
  in both with a different state or priority. Sorted by repo, identifier and field.
  """
  @spec compare([Issue.t()], [Issue.t()]) :: [difference()]
  def compare(poll_candidates, record_candidates) when is_list(poll_candidates) and is_list(record_candidates) do
    poll = Map.new(poll_candidates, &{&1.id, &1})
    record = Map.new(record_candidates, &{&1.id, &1})

    (Map.keys(poll) ++ Map.keys(record))
    |> Enum.uniq()
    |> Enum.flat_map(&differences(Map.get(poll, &1), Map.get(record, &1)))
    |> Enum.sort_by(&{&1.repo_key || "", &1.identifier || "", field_order(&1.field)})
  end

  @doc """
  Records one compared cycle and its `differences`, keeping the last `window` cycles' counts. A
  difference new since the last cycle joins the recent ones and is logged at warning level.
  """
  @spec record([difference()], pos_integer(), DateTime.t()) :: :ok
  def record(differences, window, %DateTime{} = now \\ DateTime.utc_now())
      when is_list(differences) and is_integer(window) and window > 0 do
    cycle = bump(:cycles_compared)
    if differences != [], do: bump(:cycles_with_differences)
    :ets.insert(@table, {{:cycle, cycle}, length(differences)})
    :ets.select_delete(@table, [{{{:cycle, :"$1"}, :_}, [{:"=<", :"$1", cycle - window}], [true]}])
    note_open(differences, now)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The report: cycles compared and cycles with a difference since Symphony started, the cycles in
  the window and their differences, and the last ten differences that appeared, newest first.
  """
  @spec summary() :: summary()
  def summary do
    entries = :ets.tab2list(@table)
    window = for {{:cycle, _cycle}, count} <- entries, do: count
    recent = for {{:recent, seq}, difference} <- entries, do: {seq, difference}

    %{
      cycles_compared: lookup(entries, :cycles_compared),
      cycles_with_differences: lookup(entries, :cycles_with_differences),
      window_cycles: length(window),
      window_differences: Enum.sum(window),
      recent: recent |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))
    }
  rescue
    ArgumentError -> @empty_summary
  end

  @doc "Forgets the report."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp differences(%Issue{} = poll, nil), do: [difference(poll, :poll, :candidate, poll.state, nil)]
  defp differences(nil, %Issue{} = record), do: [difference(record, :record, :candidate, nil, record.state)]

  defp differences(%Issue{} = poll, %Issue{} = record) do
    for field <- [:state, :priority], Map.fetch!(poll, field) != Map.fetch!(record, field) do
      difference(poll, :both, field, Map.fetch!(poll, field), Map.fetch!(record, field))
    end
  end

  defp difference(%Issue{} = issue, side, field, poll, record) do
    %{repo_key: issue.repo_key, issue_id: issue.id, identifier: issue.identifier, side: side, field: field, poll: poll, record: record}
  end

  # The differences open now; one not open in the last cycle is new, and one open then but not now
  # has cleared.
  defp note_open(differences, now) do
    open = MapSet.new(differences, &open_key/1)

    for difference <- differences, :ets.insert_new(@table, {{:open, open_key(difference)}, true}) do
      seq = bump(:recent_seq)
      :ets.insert(@table, {{:recent, seq}, Map.put(difference, :at, now)})
      :ets.delete(@table, {:recent, seq - @recent_limit})
      log(difference)
    end

    for {{:open, key} = entry, true} <- :ets.match_object(@table, {{:open, :_}, true}), not MapSet.member?(open, key) do
      :ets.delete(@table, entry)
    end
  end

  defp field_order(field), do: Map.fetch!(@field_order, field)

  defp open_key(difference), do: {difference.repo_key, difference.issue_id, difference.field}

  defp log(difference) do
    Logger.warning(
      "Dispatch shadow difference: repo_key=#{difference.repo_key} issue_id=#{difference.issue_id} " <>
        "issue_identifier=#{difference.identifier} side=#{difference.side} field=#{difference.field} " <>
        "poll=#{inspect(difference.poll)} record=#{inspect(difference.record)}"
    )
  end

  defp bump(key), do: :ets.update_counter(@table, key, 1, {key, 0})

  defp lookup(entries, key) do
    case List.keyfind(entries, key, 0) do
      {^key, value} -> value
      nil -> 0
    end
  end
end
