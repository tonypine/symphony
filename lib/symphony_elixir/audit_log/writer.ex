defmodule SymphonyElixir.AuditLog.Writer do
  @moduledoc """
  Writes the orchestrator's per-update audit events outside the orchestrator process, in the
  order they come.

  An agent streams many updates a second, and each one can write a few audit events under the
  audit log's `:global` lock, which every other audit writer also takes. Writing them inline
  stalled the orchestrator, and with it the state API, for as long as the lock and the disk took.
  When the writer isn't running (a one-shot command), events are written in the caller. When it
  stops, it writes the events still queued for it first.
  """

  # Long enough to write a backlog queued behind a slow lock or disk before the application stops.
  use GenServer, shutdown: 30_000
  require Logger

  alias SymphonyElixir.AuditLog

  # The only running entry fields an audit event reads (see `AuditLog.base_event/3`), so a cast
  # doesn't copy the entry's transcript buffer.
  @entry_keys [:issue, :repo_key, :issue_id, :identifier, :run_id, :session_id]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records an agent update's audit events (`AuditLog.record_agent_update/3`) without waiting."
  @spec record_agent_update(map(), map(), map(), GenServer.server()) :: :ok
  def record_agent_update(running_entry, update, token_delta, server \\ __MODULE__)
      when is_map(running_entry) and is_map(update) and is_map(token_delta) do
    write(server, {:agent_update, Map.take(running_entry, @entry_keys), update, token_delta})
  end

  @doc "Records a run's `pr_opened` event (`AuditLog.record_pr_opened/3`) without waiting."
  @spec record_pr_opened(map(), String.t(), GenServer.server()) :: :ok
  def record_pr_opened(running_entry, pr_url, server \\ __MODULE__) when is_map(running_entry) and is_binary(pr_url) do
    write(server, {:pr_opened, Map.take(running_entry, @entry_keys), pr_url})
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:write, write}, state) do
    perform(write)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: drain()

  defp drain do
    receive do
      {:"$gen_cast", {:write, write}} ->
        perform(write)
        drain()
    after
      0 -> :ok
    end
  end

  defp write(server, write) do
    case GenServer.whereis(server) do
      nil -> perform(write)
      pid -> GenServer.cast(pid, {:write, write})
    end
  end

  defp perform({:agent_update, entry, update, token_delta}) do
    record_agent_update_fun().(entry, update, token_delta) |> log_error("record agent update")
  end

  defp perform({:pr_opened, entry, pr_url}) do
    entry |> AuditLog.record_pr_opened(pr_url) |> log_error("record pr_opened")
  end

  # Tests stand in a slow write here.
  defp record_agent_update_fun,
    do: Application.get_env(:symphony_elixir, :audit_log_writer_record_agent_update, &AuditLog.record_agent_update/3)

  defp log_error(:ok, _action), do: :ok

  defp log_error({:error, reason}, action) do
    Logger.warning("Audit log failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
