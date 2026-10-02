defmodule SymphonyElixir.QaRunner do
  @moduledoc """
  Runs Auto Review QA passes in the background.

  The CI poller asks for a pass when an issue in Auto Review has green CI. The runner
  starts at most `auto_review.max_concurrent` passes, one per issue, each as a task
  under `SymphonyElixir.TaskSupervisor` that runs `SymphonyElixir.AutoReview.run_qa/2`
  and applies its own outcome. A request for an issue that already has a pass running
  is a no-op, so a slow pass is never started twice.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AutoReview

  @type request_result :: :started | :running | :busy | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts a QA pass for `job` unless one is running for the issue or the runner is at
  `max_concurrent`. `opts` are passed to `AutoReview.run_qa/2`.
  """
  @spec request(map(), keyword()) :: request_result()
  def request(%{issue: %{id: issue_id}} = job, opts \\ []) when is_binary(issue_id) do
    server = Keyword.get(opts, :qa_runner_server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :qa_runner_unavailable}
      pid -> GenServer.call(pid, {:request, job, Keyword.delete(opts, :qa_runner_server)})
    end
  end

  @doc "Issue ids with a QA pass in flight, mapped to the PR head SHA under test."
  @spec running(GenServer.server()) :: %{String.t() => String.t()}
  def running(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{}
      pid -> GenServer.call(pid, :running)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       running: %{},
       run_fun: Keyword.get(opts, :run_fun, &AutoReview.run_qa/2),
       task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:request, %{issue: %{id: issue_id}, sha: sha} = job, opts}, _from, state) do
    max_concurrent = job |> Map.fetch!(:settings) |> Map.fetch!(:auto_review) |> Map.fetch!(:max_concurrent)

    cond do
      Map.has_key?(state.running, issue_id) ->
        {:reply, :running, state}

      map_size(state.running) >= max_concurrent ->
        {:reply, :busy, state}

      true ->
        start_pass(state, issue_id, sha, job, opts)
    end
  end

  def handle_call(:running, _from, state) do
    {:reply, Map.new(state.running, fn {issue_id, %{sha: sha}} -> {issue_id, sha} end), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_issue_id, entry} -> entry.ref == ref end) do
      {issue_id, entry} ->
        if reason != :normal, do: Logger.warning("QA pass crashed issue_id=#{issue_id} sha=#{entry.sha}: #{inspect(reason)}")
        {:noreply, %{state | running: Map.delete(state.running, issue_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_pass(state, issue_id, sha, job, opts) do
    run_fun = state.run_fun

    case Task.Supervisor.start_child(state.task_supervisor, fn -> run_fun.(job, opts) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:reply, :started, %{state | running: Map.put(state.running, issue_id, %{sha: sha, ref: ref})}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
