defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  require Logger

  alias SymphonyElixir.Config

  @pubsub SymphonyElixir.PubSub
  @dashboard_topic "observability:dashboard"
  @transcript_topic "observability:transcript"
  @ticket_events_topic "ticket_events"
  @ticket_records_topic "ticket_records"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @dashboard_topic)
  end

  @spec broadcast_update(String.t() | nil) :: :ok
  def broadcast_update(repo_key \\ nil) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @dashboard_topic, {@update_message, %{repo_key: repo_key(repo_key)}})

      _ ->
        :ok
    end
  end

  @spec subscribe_transcript() :: :ok | {:error, term()}
  def subscribe_transcript do
    Phoenix.PubSub.subscribe(@pubsub, transcript_topic())
  end

  @spec broadcast_transcript_event(String.t() | nil, String.t(), map()) :: :ok
  def broadcast_transcript_event(repo_key, issue_id, event)
      when is_binary(issue_id) and is_map(event) do
    event = event |> Map.put(:repo_key, repo_key(repo_key)) |> Map.put(:issue_id, issue_id)

    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        case Phoenix.PubSub.broadcast(@pubsub, transcript_topic(), {:transcript_event, event}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("failed to broadcast transcript event: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  def broadcast_transcript_event(_repo_key, _issue_id, _event), do: :ok

  @spec transcript_topic() :: String.t()
  def transcript_topic, do: @transcript_topic

  @doc """
  Subscribes the caller to the notices of events written to tickets' histories
  (`SymphonyElixir.TicketEvents.record/5`): each arrives as `{:ticket_event, notice}`.
  """
  @spec subscribe_ticket_events() :: :ok | {:error, term()}
  def subscribe_ticket_events do
    Phoenix.PubSub.subscribe(@pubsub, @ticket_events_topic)
  end

  @spec unsubscribe_ticket_events() :: :ok
  def unsubscribe_ticket_events do
    Phoenix.PubSub.unsubscribe(@pubsub, @ticket_events_topic)
  end

  @doc """
  Broadcasts `notice` to the subscribers of `subscribe_ticket_events/0`, best-effort: with no PubSub
  running, or when the broadcast fails (logged), it is `:ok` all the same.
  """
  @spec broadcast_ticket_event(map()) :: :ok
  def broadcast_ticket_event(notice) when is_map(notice) do
    with pid when is_pid(pid) <- Process.whereis(@pubsub),
         {:error, reason} <- Phoenix.PubSub.broadcast(@pubsub, @ticket_events_topic, {:ticket_event, notice}) do
      Logger.warning("failed to broadcast ticket event: #{inspect(reason)}")
    end

    :ok
  end

  @spec ticket_events_topic() :: String.t()
  def ticket_events_topic, do: @ticket_events_topic

  @doc """
  Subscribes the caller to the changes of tickets' records (`SymphonyElixir.TicketObservation`):
  each arrives as `{:ticket_record, repo_key, issue_id, :changed}`. With no PubSub running it
  subscribes to nothing.
  """
  @spec subscribe_ticket_records() :: :ok | {:error, term()}
  def subscribe_ticket_records do
    if Process.whereis(@pubsub), do: Phoenix.PubSub.subscribe(@pubsub, @ticket_records_topic), else: :ok
  end

  @doc """
  Tells the subscribers of `subscribe_ticket_records/0` that the record of `issue_id` in `repo_key`
  changed, best-effort as `broadcast_ticket_event/1` is.
  """
  @spec broadcast_ticket_record_changed(String.t(), String.t()) :: :ok
  def broadcast_ticket_record_changed(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    message = {:ticket_record, repo_key, issue_id, :changed}

    with pid when is_pid(pid) <- Process.whereis(@pubsub),
         {:error, reason} <- Phoenix.PubSub.broadcast(@pubsub, @ticket_records_topic, message) do
      Logger.warning("failed to broadcast ticket record change: #{inspect(reason)}")
    end

    :ok
  end

  defp repo_key(repo_key) when is_binary(repo_key) do
    case String.trim(repo_key) do
      "" -> default_repo_key()
      trimmed -> trimmed
    end
  end

  defp repo_key(_repo_key), do: default_repo_key()

  defp default_repo_key, do: Config.repo_key_or_nil()
end
