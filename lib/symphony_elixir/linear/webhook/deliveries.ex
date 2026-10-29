defmodule SymphonyElixir.Linear.Webhook.Deliveries do
  @moduledoc """
  Counts the deliveries of Linear's workspace webhook (`POST /api/v1/linear/webhook`), so the
  operator can watch them arrive before anything acts on them.

  An accepted delivery is counted by its `type` and `action` (`unknown` when the payload has none),
  and by what observing it into the ticket's record did
  (`SymphonyElixir.TicketObservation.observe_delivery/2`; none for a delivery that isn't observed),
  and the last ten are kept with the ticket identifier the payload names and that observation. A
  rejected one is counted by its reason. The counts live in a public ETS table owned by this server, so counting never
  waits on a process; they are diagnostic and start again from zero when Symphony restarts.
  Without the server (some tests), counting is a no-op and the summary is empty.
  """

  use GenServer

  @table __MODULE__
  @recent_limit 10
  @max_value_length 64
  @observations [:updated, :unchanged, :stale, :unrouted, :removed, :no_record, :error]

  @typedoc "What observing a delivery into the ticket's record did, as `SymphonyElixir.TicketObservation.observe_delivery/2` says."
  @type observation :: :updated | :unchanged | :stale | :unrouted | :removed | :no_record | :error

  @typedoc "One accepted delivery, as the summary lists it."
  @type delivery :: %{
          type: String.t(),
          action: String.t(),
          identifier: String.t() | nil,
          observation: observation() | nil,
          received_at: DateTime.t()
        }

  @type summary :: %{
          total: non_neg_integer(),
          rejected: non_neg_integer(),
          last_at: DateTime.t() | nil,
          last_type: String.t() | nil,
          last_action: String.t() | nil,
          last_rejected_at: DateTime.t() | nil,
          last_rejected_reason: atom() | nil,
          counts: [%{type: String.t(), action: String.t(), count: pos_integer()}],
          rejected_reasons: [%{reason: atom(), count: pos_integer()}],
          observations: %{observation() => non_neg_integer()},
          recent: [delivery()]
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
  Counts one accepted delivery from its decoded `payload`, with what observing it did
  (`observation`, nil when it wasn't observed). Only `type`, `action` and `data.identifier` are
  read; a payload without them is counted as `unknown`.
  """
  @spec accepted(term(), DateTime.t(), observation() | nil) :: :ok
  def accepted(payload, received_at \\ DateTime.utc_now(), observation \\ nil) do
    observation = if observation in @observations, do: observation

    delivery = %{
      type: text(field(payload, "type")) || "unknown",
      action: text(field(payload, "action")) || "unknown",
      identifier: payload |> field("data") |> field("identifier") |> text(),
      observation: observation,
      received_at: received_at
    }

    if observation, do: :ets.update_counter(@table, {:observation, observation}, 1, {{:observation, observation}, 0})
    :ets.update_counter(@table, :total, 1, {:total, 0})
    :ets.update_counter(@table, {:count, delivery.type, delivery.action}, 1, {{:count, delivery.type, delivery.action}, 0})
    seq = :ets.update_counter(@table, :seq, 1, {:seq, 0})
    :ets.insert(@table, [{{:recent, seq}, delivery}, {:last, delivery}])
    :ets.delete(@table, {:recent, seq - @recent_limit})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Counts one rejected delivery and why it was refused."
  @spec rejected(atom(), DateTime.t()) :: :ok
  def rejected(reason, rejected_at \\ DateTime.utc_now()) when is_atom(reason) do
    :ets.update_counter(@table, :rejected, 1, {:rejected, 0})
    :ets.update_counter(@table, {:rejected_reason, reason}, 1, {{:rejected_reason, reason}, 0})
    :ets.insert(@table, {:last_rejected, %{reason: reason, at: rejected_at}})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "What has arrived since Symphony started: the counts, the last delivery and the last ten, newest first."
  @spec summary() :: summary()
  def summary do
    entries = :ets.tab2list(@table)
    seq = lookup(entries, :seq, 0)
    last = lookup(entries, :last, %{})
    last_rejected = lookup(entries, :last_rejected, %{})

    %{
      total: lookup(entries, :total, 0),
      rejected: lookup(entries, :rejected, 0),
      last_at: Map.get(last, :received_at),
      last_type: Map.get(last, :type),
      last_action: Map.get(last, :action),
      last_rejected_at: Map.get(last_rejected, :at),
      last_rejected_reason: Map.get(last_rejected, :reason),
      counts: counts(entries),
      rejected_reasons: rejected_reasons(entries),
      observations: Map.new(@observations, &{&1, lookup(entries, {:observation, &1}, 0)}),
      recent: recent(entries, seq)
    }
  rescue
    ArgumentError -> empty_summary()
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp empty_summary do
    %{
      total: 0,
      rejected: 0,
      last_at: nil,
      last_type: nil,
      last_action: nil,
      last_rejected_at: nil,
      last_rejected_reason: nil,
      counts: [],
      rejected_reasons: [],
      observations: Map.new(@observations, &{&1, 0}),
      recent: []
    }
  end

  defp counts(entries) do
    for({{:count, type, action}, count} <- entries, do: %{type: type, action: action, count: count})
    |> Enum.sort_by(&{-&1.count, &1.type, &1.action})
  end

  defp rejected_reasons(entries) do
    for({{:rejected_reason, reason}, count} <- entries, do: %{reason: reason, count: count})
    |> Enum.sort_by(&{-&1.count, &1.reason})
  end

  # Newest first: the sequence numbers of the last ten still in the table.
  defp recent(entries, seq) do
    for n <- seq..max(seq - @recent_limit + 1, 1)//-1, {_key, delivery} <- [List.keyfind(entries, {:recent, n}, 0)], do: delivery
  end

  defp lookup(entries, key, default) do
    case List.keyfind(entries, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp field(%{} = map, key), do: Map.get(map, key)
  defp field(_not_a_map, _key), do: nil

  defp text(value) when is_binary(value) and value != "", do: String.slice(value, 0, @max_value_length)
  defp text(_value), do: nil
end
