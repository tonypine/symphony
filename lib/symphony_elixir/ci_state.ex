defmodule SymphonyElixir.CiState do
  @moduledoc """
  The CI attribute of a ticket's current PR head, and its projection onto the board.

  A CI result reaches the store through two writers. A GitHub webhook delivery writes the coarse
  state it carries (`red` for a check that failed, `running` for a head that moved) straight into
  the ticket's state record, so the board moves without waiting for a poll; the timed
  `SymphonyElixir.CiPoller` reconciles with the authoritative rollup and is the only writer that
  calls a head `green`. Both go through `record/6`, so the `CI green` / `CI red` / `CI running`
  labels on the ticket always match the store's current head (`docs/design/state-machine.md`
  §Attributes, §Board states).

  Every write is best-effort: a store or tracker failure is logged, never raised, so tracking CI
  can't take down the poll or the webhook handler that called it.
  """

  require Logger

  alias SymphonyElixir.MachineLabels
  alias SymphonyElixir.{RunStore, Tracker}

  @running "running"
  @green "green"
  @red "red"

  @doc """
  The machine-owned CI label for a CI status (`running` / `green` / `red`), or nil for a status
  that clears the labels (a closed PR).
  """
  @spec label(String.t() | nil) :: String.t() | nil
  def label("running"), do: "CI running"
  def label("green"), do: "CI green"
  def label("red"), do: "CI red"
  def label(_status), do: nil

  @doc """
  Writes `status` of `head_sha` into the ticket's state record and projects the matching CI label;
  a nil `status` clears the labels. `opts` selects the `:run_store` and `:tracker`. The attribute
  write is skipped when the writer carries none (a test store), and the label is projected only
  when the store accepted the write.
  """
  def record(repo_key, issue_id, head_sha, status, at, opts \\ [])

  @spec record(String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil, DateTime.t(), keyword()) ::
          :ok
  def record(repo_key, issue_id, head_sha, status, %DateTime{} = at, opts)
      when is_binary(repo_key) and is_binary(issue_id) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    tracker = Keyword.get(opts, :tracker, Tracker)

    if is_binary(status) do
      case put_state(run_store, repo_key, issue_id, head_sha, status, at) do
        :changed -> project(tracker, issue_id, status)
        _other -> :ok
      end
    else
      project(tracker, issue_id, nil)
    end
  end

  def record(_repo_key, _issue_id, _head_sha, _status, _at, _opts), do: :ok

  @doc "The status `SymphonyElixir.CiPoller.ci_action/1` reads as the CI attribute of a head."
  @spec status_for_action(term()) :: String.t() | nil
  def status_for_action(:success), do: @green
  def status_for_action(:pending), do: @running
  def status_for_action({:failure, _checks}), do: @red
  def status_for_action(:closed), do: nil
  def status_for_action(_action), do: nil

  # The store's last-write-wins write, best-effort: an unsupported store (a test double) or a
  # failed write must not project a label that the store doesn't hold.
  defp put_state(run_store, repo_key, issue_id, head_sha, status, at) do
    if exports?(run_store, :record_ci_state, 5) do
      case run_store.record_ci_state(repo_key, issue_id, head_sha, status, at) do
        {:ok, outcome} ->
          outcome

        {:error, reason} ->
          Logger.warning("Failed to record CI state head_sha=#{head_sha} issue_id=#{issue_id}: #{inspect(reason)}")
          :error
      end
    else
      :unsupported
    end
  end

  # Exactly one CI label is left on the ticket: the wanted one is set and the rest cleared, so a
  # head that moved from red to running doesn't end up wearing both.
  defp project(tracker, issue_id, status) do
    wanted = label(status)

    Enum.each(MachineLabels.ci_labels(), fn name ->
      if name == wanted do
        set_machine_label(tracker, issue_id, name)
      else
        clear_machine_label(tracker, issue_id, name)
      end
    end)
  end

  defp set_machine_label(tracker, issue_id, name), do: call(tracker, :set_machine_label, [issue_id, name])

  defp clear_machine_label(tracker, issue_id, name), do: call(tracker, :clear_machine_label, [issue_id, name])

  defp call(tracker, fun, args) do
    if exports?(tracker, fun, length(args)) do
      case apply(tracker, fun, args) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to #{fun} #{inspect(args)}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp exports?(module, fun, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
