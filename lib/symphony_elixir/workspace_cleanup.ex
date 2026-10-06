defmodule SymphonyElixir.WorkspaceCleanup do
  @moduledoc """
  Removes the workspaces of issues that ended, outside the orchestrator.

  A removal runs the repo's `before_remove` hook, then `git worktree remove` and the branch
  delete under the repo's fetch lock, which can take minutes. The orchestrator hands it here
  with `remove/2` and moves on; each removal runs in a `SymphonyElixir.TaskSupervisor` task, at
  most four at once, and never two for the same issue at once. A removal that crashes is logged
  here; one that fails is logged by `SymphonyElixir.Workspace`.

  Creating a workspace over one being removed is unsafe, so a run calls `await/1` before it
  creates or reuses its issue's workspace: it returns once no removal for that issue is queued
  or running.

  The server only queues and starts tasks, so a call never waits on a removal (except
  `await/1`, which is meant to). A removal whose task cannot start is logged and dropped; the
  startup sweep and the workspace age GC find what it left. Without the server (some tests),
  `remove/2` removes inline and `await/1` returns at once.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Workspace

  @max_concurrent 4

  defstruct remove_fun: nil,
            task_supervisor: nil,
            max_concurrent: @max_concurrent,
            running: %{},
            queue: [],
            waiters: %{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       remove_fun: Keyword.get(opts, :remove_fun, &Workspace.remove_issue_workspaces/2),
       task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
       max_concurrent: Keyword.get(opts, :max_concurrent, @max_concurrent)
     }}
  end

  @doc """
  Queues the removal of the issue's workspaces on `worker_host` (every host when `nil`), as
  `Workspace.remove_issue_workspaces/2` does, and returns without waiting for it.
  """
  @spec remove(%{required(:identifier) => String.t(), optional(atom()) => term()}, Workspace.worker_host(), GenServer.server()) :: :ok
  def remove(%{identifier: identifier} = issue, worker_host, server \\ __MODULE__) when is_binary(identifier) do
    case call(server, {:remove, issue, worker_host}) do
      :ok -> :ok
      :unavailable -> Workspace.remove_issue_workspaces(issue, worker_host)
    end
  end

  @doc """
  Returns once no removal of the issue's workspaces is queued or running.
  """
  @spec await(String.t() | nil, GenServer.server()) :: :ok
  def await(identifier, server \\ __MODULE__) do
    if is_binary(identifier), do: call(server, {:await, identifier})
    :ok
  end

  defp call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, {:noproc, _call} -> :unavailable
  end

  @impl true
  def handle_call({:remove, %{identifier: identifier} = issue, worker_host}, _from, state) do
    state =
      if Enum.any?(state.queue, fn {queued_issue, queued_host} -> queued_issue.identifier == identifier and queued_host == worker_host end) do
        state
      else
        %{state | queue: state.queue ++ [{issue, worker_host}]}
      end

    {:reply, :ok, start_queued(state)}
  end

  def handle_call({:await, identifier}, from, state) do
    if in_flight?(state, identifier) do
      {:noreply, %{state | waiters: Map.update(state.waiters, identifier, [from], &[from | &1])}}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_map_key(state.running, ref) do
    {issue, worker_host} = Map.fetch!(state.running, ref)

    Logger.warning(
      "Workspace cleanup failed: issue_id=#{inspect(Map.get(issue, :id))} issue_identifier=#{issue.identifier} " <>
        "worker_host=#{inspect(worker_host)} reason=#{inspect(reason)}"
    )

    {:noreply, finish(state, ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, ref) do
    {{issue, _worker_host}, running} = Map.pop!(state.running, ref)

    %{state | running: running}
    |> start_queued()
    |> reply_waiters(issue.identifier)
  end

  # Starts queued removals, oldest first, while there is room, skipping an issue whose removal
  # is already running: it starts once that one ends.
  defp start_queued(%__MODULE__{} = state) do
    running_identifiers = MapSet.new(Map.values(state.running), fn {issue, _worker_host} -> issue.identifier end)

    with true <- map_size(state.running) < state.max_concurrent,
         index when is_integer(index) <-
           Enum.find_index(state.queue, fn {issue, _worker_host} -> not MapSet.member?(running_identifiers, issue.identifier) end) do
      {{issue, worker_host} = entry, queue} = List.pop_at(state.queue, index)
      state = %{state | queue: queue}

      case start_task(state, issue, worker_host) do
        {:ok, task} ->
          start_queued(%{state | running: Map.put(state.running, task.ref, entry)})

        {:error, reason} ->
          Logger.warning(
            "Failed to start workspace cleanup: issue_id=#{inspect(Map.get(issue, :id))} issue_identifier=#{issue.identifier} " <>
              "worker_host=#{inspect(worker_host)} reason=#{inspect(reason)}"
          )

          state |> start_queued() |> reply_waiters(issue.identifier)
      end
    else
      _full_or_blocked -> state
    end
  end

  defp start_task(%__MODULE__{remove_fun: remove_fun, task_supervisor: task_supervisor}, issue, worker_host) do
    {:ok, Task.Supervisor.async_nolink(task_supervisor, fn -> remove_fun.(issue, worker_host) end)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp reply_waiters(state, identifier) do
    if in_flight?(state, identifier) do
      state
    else
      {waiters, remaining} = Map.pop(state.waiters, identifier, [])
      Enum.each(waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: remaining}
    end
  end

  defp in_flight?(state, identifier) do
    Enum.any?(Map.values(state.running) ++ state.queue, fn {issue, _worker_host} -> issue.identifier == identifier end)
  end
end
