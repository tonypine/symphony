defmodule SymphonyElixir.WorkspaceRemoval do
  @moduledoc """
  The one place that decides whether a ticket's workspace is removed. Removing a workspace is an
  allow list, not a deny list: a workspace is removed only for one of the reasons below, and in
  every other case it stays as it is, uncommitted changes included.

    * `:terminal` - the ticket ended: it reached one of the workflow's terminal states (Done,
      Canceled and their configured synonyms).
    * `:restart` - a person asked for it: Start over removes the workspace so the ticket starts
      again from its base branch.
    * `:age_gc` - the age collector found a workspace older than `workspaces.cleanup.max_age_days`
      whose ticket has ended or no longer exists (`removable_ticket?/2`).
    * `:orphan` - the startup sweep found a workspace no tracked ticket names, whose ticket has
      ended or no longer exists, and `workspaces.cleanup.orphan_action` is `delete` or `trash`.

  A person's Stop, a run displaced by a Start, a run that times out, fails, is refused or is
  interrupted by an app update, and a pull request closed while its ticket is still open name no
  reason here, so they keep the workspace, and the ticket's next run continues in it.

  Every remover asks `check/1` first: `remove/3` (the orchestrator's removals, queued with
  `SymphonyElixir.WorkspaceCleanup`), `remove_now/3` (Start over), `remove_path/4` (the PR review
  poller) and the age collector and startup sweep in `SymphonyElixir.Workspace`. A reason outside the
  list is refused: nothing is removed and nothing is recorded.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker, Workspace, WorkspaceCleanup, WorkspaceRebuild}

  @reasons [:terminal, :restart, :age_gc, :orphan]

  @typedoc "A reason the allow list holds."
  @type reason :: :terminal | :restart | :age_gc | :orphan

  @typedoc "What Symphony knows of a workspace's ticket: `:unknown` when it could not be read."
  @type ticket_status :: :ended | :missing | :open | :unknown

  @doc "The reasons a workspace may be removed for."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  `:ok` when `reason` is on the allow list, `{:error, {:removal_not_allowed, reason}}` for anything
  else (a former `:stop`, a boolean, `nil`).
  """
  @spec check(term()) :: :ok | {:error, {:removal_not_allowed, term()}}
  def check(reason) when reason in @reasons, do: :ok
  def check(reason), do: {:error, {:removal_not_allowed, reason}}

  @doc """
  Queues the removal of the issue's workspaces on `worker_host` (every host when `nil`) for
  `reason`, and records it on the ticket as a `workspace.removed` event. The removal runs the repo's
  `before_remove` hook, which closes the pull request only for `:terminal`. A reason outside the list
  is refused: nothing is queued and nothing is recorded.
  """
  @spec remove(map(), Workspace.worker_host(), term(), GenServer.server()) :: :ok | {:error, {:removal_not_allowed, term()}}
  def remove(%{identifier: identifier} = issue, worker_host, reason, server \\ WorkspaceCleanup) when is_binary(identifier) do
    with :ok <- refuse_unless_allowed(check(reason), issue) do
      WorkspaceRebuild.record_removal(Map.get(issue, :repo_key), Map.get(issue, :id), reason)
      WorkspaceCleanup.remove(Map.put(issue, :remove_reason, reason), worker_host, server)
    end
  end

  @doc """
  Removes the issue's workspaces at once for `reason`, with `workspace` (`SymphonyElixir.Workspace`
  by default) reporting a removal that failed. Start over waits on it, so its move is not made when
  the folder could not be removed.
  """
  @spec remove_now(map(), term(), module()) :: :ok | {:error, term()}
  def remove_now(%{identifier: identifier} = issue, reason, workspace \\ Workspace) when is_binary(identifier) do
    with :ok <- refuse_unless_allowed(check(reason), issue) do
      workspace.remove_issue_workspaces_checked(issue)
    end
  end

  @doc """
  Removes the workspace at `path` for `reason`, with `workspace` (`SymphonyElixir.Workspace` by
  default), and returns what its `remove/2` returns; a reason outside the list is refused.
  """
  @spec remove_path(Path.t(), Workspace.worker_host(), term(), module()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()} | {:error, {:removal_not_allowed, term()}}
  def remove_path(path, worker_host, reason, workspace \\ Workspace) do
    with :ok <- refuse_unless_allowed(check(reason), %{identifier: Path.basename(to_string(path))}) do
      workspace.remove(path, worker_host)
    end
  end

  @doc """
  What Symphony knows of the ticket a workspace folder is named after: `:ended` in a terminal
  state, `:missing` when the tracker has no such ticket, `:open` in any other state, and `:unknown`
  when it could not be read.

  Options: `:fetch` reads a ticket by its identifier (`Tracker.fetch_issue_by_identifier/1` by
  default) and `:terminal_states` (the workflow's by default).
  """
  @spec ticket_status(String.t(), keyword()) :: ticket_status()
  def ticket_status(identifier, opts \\ []) when is_binary(identifier) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_by_identifier/1)

    case fetch.(identifier) do
      {:ok, %{state: state}} -> if ended_state?(state, terminal_states(opts)), do: :ended, else: :open
      {:error, :issue_not_found} -> :missing
      _unreadable -> :unknown
    end
  rescue
    error ->
      Logger.warning("Couldn't read the ticket of workspace #{identifier}: #{Exception.message(error)}; keeping the workspace")
      :unknown
  end

  @doc """
  True when the ticket a workspace is named after has ended or no longer exists: the only tickets
  whose workspaces the age collector and the startup sweep may remove. An open ticket keeps its
  workspace however old it is, and so does one whose state could not be read.
  """
  @spec removable_ticket?(String.t(), keyword()) :: boolean()
  def removable_ticket?(identifier, opts \\ []), do: ticket_status(identifier, opts) in [:ended, :missing]

  @doc "True when `state` is one of `terminal_states`, compared trimmed and case-insensitively."
  @spec ended_state?(term(), [String.t()]) :: boolean()
  def ended_state?(state, terminal_states) when is_binary(state), do: normalize(state) in Enum.map(terminal_states, &normalize/1)
  def ended_state?(_state, _terminal_states), do: false

  defp terminal_states(opts), do: Keyword.get_lazy(opts, :terminal_states, fn -> Config.settings!().tracker.terminal_states end)

  defp normalize(state), do: state |> to_string() |> String.trim() |> String.downcase()

  defp refuse_unless_allowed(:ok, _issue), do: :ok

  defp refuse_unless_allowed({:error, {:removal_not_allowed, reason}} = refused, issue) do
    Logger.warning("Refused to remove the workspace of #{Map.get(issue, :identifier)}: #{inspect(reason)} is not a removal reason; keeping it")
    refused
  end
end
