defmodule SymphonyElixir.TicketSignals do
  @moduledoc """
  Best-effort recording of the machine's transitions into a ticket's signals ledger.

  Every recording here is a side effect next to an already-decided move. A store failure is logged
  and swallowed, so it can never change a transition, a board move or a label. The ledger lives in
  `SymphonyElixir.RunStore` and its shape in `SymphonyElixir.TicketState`.
  """

  require Logger

  alias SymphonyElixir.RunStore

  @doc """
  Appends `name` with `details` to the ticket's signals ledger. No-ops when the ticket carries no
  repo key, so a move made outside a configured repo records nothing rather than failing.
  """
  @spec record(String.t() | nil, String.t() | nil, String.t(), map()) :: :ok
  def record(repo_key, issue_id, name, details) when is_binary(repo_key) and is_binary(issue_id) do
    repo_key
    |> RunStore.record_ticket_signal(issue_id, name, details)
    |> log_error("record #{name} signal")
  end

  def record(_repo_key, _issue_id, _name, _details), do: :ok

  @doc """
  Records a verdict of `kind` with `outcome`, bound to the `head_sha` it judged and carrying
  `details`, on the ticket's record. No-ops when the ticket carries no repo key.
  """
  @spec record_verdict(String.t() | nil, String.t() | nil, String.t(), String.t() | nil, String.t(), map()) :: :ok
  def record_verdict(repo_key, issue_id, kind, head_sha, outcome, details \\ %{}) do
    if is_binary(repo_key) and is_binary(issue_id) do
      repo_key
      |> RunStore.record_ticket_verdict(issue_id, kind, head_sha, outcome, details)
      |> log_error("record #{kind} verdict")
    else
      :ok
    end
  end

  defp log_error(:ok, _action), do: :ok

  defp log_error({:error, reason}, action) do
    Logger.warning("Failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
