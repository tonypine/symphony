defmodule SymphonyElixir.Dispatch.Shadow do
  @moduledoc """
  The dispatch shadow: before the dispatcher trusts the ticket records, every poll cycle compares
  the candidates the poll cache gives with the ones the records give
  (`SymphonyElixir.Dispatch.Candidates`) and keeps the differences here, so `/api/v1/state` shows
  whether the two paths agree (`dispatch_shadow`). Dispatch reads the side `dispatch.source` names
  and the shadow computes the other, so the comparison keeps running whichever is in use.

  `compare/2` and `compare/3` are pure. The report lives in a public ETS table owned by this
  server, so recording never waits on a process; without the server (some tests), recording is a
  no-op and the report is empty. It keeps how many cycles were compared and how many had a
  difference since Symphony started, the differences of the last cycles of the window
  (`dispatch.shadow_window`), and the last ten differences that appeared, newest first. A difference that lasts over several cycles
  appears, and is logged at warning level, once; once it clears, it appears again if it comes back.

  A record can be newer than the poll snapshot it is compared with: Symphony writes its own moves to
  the record first, and a webhook writes a person's, while the snapshot was read before. `classify/3`
  sets aside a difference in a ticket's presence or state whose record phase was written after the
  snapshot was read (`record_newer`): the record is the fresher side, so it is not drift. The report
  counts those apart, once each like a difference, with the identifiers of the last five. The next
  poll reads Linear again, and the comparison on that fresh snapshot shows a lag that is real.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Linear.Issue

  @table __MODULE__
  @recent_limit 10
  @record_newer_limit 5
  @field_order %{candidate: 0, state: 1, priority: 2}
  # The fields a phase write changes: a move changes the state, and in or out of the active states
  # whether the ticket is a candidate at all.
  @phase_fields [:candidate, :state]
  @empty_summary %{
    cycles_compared: 0,
    cycles_with_differences: 0,
    window_cycles: 0,
    window_differences: 0,
    recent: [],
    record_newer: %{count: 0, recent: []}
  }

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

  @typedoc """
  One cycle's comparison once classified (`classify/3`): the differences to report, and the ones
  the record's newer phase write explains.
  """
  @type classified :: %{differences: [difference()], record_newer: [difference()]}

  @type summary :: %{
          cycles_compared: non_neg_integer(),
          cycles_with_differences: non_neg_integer(),
          window_cycles: non_neg_integer(),
          window_differences: non_neg_integer(),
          recent: [map()],
          record_newer: %{count: non_neg_integer(), recent: [String.t() | nil]}
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
  def compare(poll_candidates, record_candidates), do: compare(poll_candidates, record_candidates, :poll)

  @doc """
  `compare/2` for the side dispatch uses (`in_use`, `dispatch.source`) and the other: `used` are the
  candidates dispatch reads, `other` the ones only the shadow computes. The differences name the
  poll and the record sides whichever is in use, so the report reads the same either way.
  """
  @spec compare([Issue.t()], [Issue.t()], :poll | :record) :: [difference()]
  def compare(used, other, :record), do: compare(other, used, :poll)

  def compare(poll_candidates, record_candidates, :poll) when is_list(poll_candidates) and is_list(record_candidates) do
    poll = Map.new(poll_candidates, &{&1.id, &1})
    record = Map.new(record_candidates, &{&1.id, &1})

    (Map.keys(poll) ++ Map.keys(record))
    |> Enum.uniq()
    |> Enum.flat_map(&differences(Map.get(poll, &1), Map.get(record, &1)))
    |> Enum.sort_by(&{&1.repo_key || "", &1.identifier || "", field_order(&1.field)})
  end

  @doc """
  Splits `differences` by which side is newer: a difference in a ticket's presence or state whose
  record phase was written after the poll snapshot was read (`read_at`) is `record_newer`; every
  other one stays a difference. `phase_at` maps an issue id to when its record's phase was last
  written (`SymphonyElixir.TicketState`). A snapshot or a phase write with no known time, and a
  priority difference, stay differences.
  """
  @spec classify([difference()], DateTime.t() | nil, %{optional(String.t()) => DateTime.t() | nil}) :: classified()
  def classify(differences, read_at, phase_at) when is_list(differences) and is_map(phase_at) do
    {record_newer, differences} = Enum.split_with(differences, &record_newer?(&1, read_at, Map.get(phase_at, &1.issue_id)))
    %{differences: differences, record_newer: record_newer}
  end

  @doc """
  Records one compared cycle and its `differences` (a list, or a cycle `classify/3` split), keeping
  the last `window` cycles' counts. A difference new since the last cycle joins the recent ones and
  is logged at warning level; a `record_newer` one new since the last cycle is counted apart.
  """
  @spec record([difference()] | classified(), pos_integer(), DateTime.t()) :: :ok
  def record(compared, window, %DateTime{} = now \\ DateTime.utc_now()) when is_integer(window) and window > 0 do
    %{differences: differences, record_newer: record_newer} = classified(compared)
    cycle = bump(:cycles_compared)
    if differences != [], do: bump(:cycles_with_differences)
    :ets.insert(@table, {{:cycle, cycle}, length(differences)})
    :ets.select_delete(@table, [{{{:cycle, :"$1"}, :_}, [{:"=<", :"$1", cycle - window}], [true]}])
    note_open(differences, now)
    note_record_newer(record_newer)
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
    newer = for {{:newer_recent, seq}, identifier} <- entries, do: {seq, identifier}

    %{
      cycles_compared: lookup(entries, :cycles_compared),
      cycles_with_differences: lookup(entries, :cycles_with_differences),
      window_cycles: length(window),
      window_differences: Enum.sum(window),
      recent: newest_first(recent),
      record_newer: %{count: lookup(entries, :record_newer), recent: newest_first(newer)}
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

  defp classified(differences) when is_list(differences), do: %{differences: differences, record_newer: []}
  defp classified(%{differences: differences, record_newer: record_newer} = compared) when is_list(differences) and is_list(record_newer), do: compared

  defp record_newer?(%{field: field}, %DateTime{} = read_at, %DateTime{} = phase_at) when field in @phase_fields,
    do: DateTime.compare(phase_at, read_at) == :gt

  defp record_newer?(_difference, _read_at, _phase_at), do: false

  # The differences open now; one not open in the last cycle is new, and one open then but not now
  # has cleared.
  defp note_open(differences, now) do
    for difference <- new_since_last_cycle(:open, differences) do
      seq = bump(:recent_seq)
      :ets.insert(@table, {{:recent, seq}, Map.put(difference, :at, now)})
      :ets.delete(@table, {:recent, seq - @recent_limit})
      log(difference)
    end
  end

  # A record newer than the snapshot stays so on every cycle until its repo's next poll: it counts
  # once, as a difference appears once.
  defp note_record_newer(record_newer) do
    for difference <- new_since_last_cycle(:newer_open, record_newer) do
      bump(:record_newer)
      seq = bump(:newer_seq)
      :ets.insert(@table, {{:newer_recent, seq}, difference.identifier})
      :ets.delete(@table, {:newer_recent, seq - @record_newer_limit})
    end
  end

  # The entries of `differences` not open (under `tag`) in the last cycle, and forgets the ones open
  # then but not now.
  defp new_since_last_cycle(tag, differences) do
    open = MapSet.new(differences, &open_key/1)

    for {{^tag, key} = entry, true} <- :ets.match_object(@table, {{tag, :_}, true}), not MapSet.member?(open, key) do
      :ets.delete(@table, entry)
    end

    Enum.filter(differences, &:ets.insert_new(@table, {{tag, open_key(&1)}, true}))
  end

  defp newest_first(entries), do: entries |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))

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
