defmodule SymphonyElixir.AgentTools.Linear.CommentRegistry do
  @moduledoc false

  # Per-run state for the scoped Linear tools: the comment ids this run created (so it may only
  # edit its own comments) and how many sub-issues it has created (so it stays under the cap).

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {seed_ids, agent_opts} = Keyword.pop(opts, :seed_ids, [])

    comments =
      seed_ids
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Agent.start_link(fn -> %{comments: comments, subissues: 0, project_updates: 0} end, agent_opts)
  end

  @spec record(pid() | nil, String.t()) :: :ok
  def record(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, fn state -> %{state | comments: MapSet.put(state.comments, comment_id)} end)
  end

  def record(_pid, _comment_id), do: :ok

  @spec owned?(pid() | nil, String.t()) :: boolean()
  def owned?(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.get(pid, &MapSet.member?(&1.comments, comment_id))
  end

  def owned?(_pid, _comment_id), do: false

  @spec remove(pid() | nil, String.t()) :: :ok
  def remove(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, fn state -> %{state | comments: MapSet.delete(state.comments, comment_id)} end)
  end

  def remove(_pid, _comment_id), do: :ok

  @doc """
  Atomically claims one of the run's `cap` sub-issue slots. Without a registry the run has no
  counter to enforce the cap with, so creation is refused.
  """
  @spec reserve_subissue(pid() | nil, pos_integer()) :: :ok | {:error, term()}
  def reserve_subissue(pid, cap) when is_pid(pid) and is_integer(cap),
    do: reserve(pid, :subissues, cap, :subissue_cap_reached)

  def reserve_subissue(_pid, _cap), do: {:error, :subissue_registry_unavailable}

  @doc "Gives back a slot claimed by `reserve_subissue/2` when the create did not go through."
  @spec release_subissue(pid()) :: :ok
  def release_subissue(pid) when is_pid(pid), do: release(pid, :subissues)

  @doc """
  Atomically claims one of the run's `cap` project-update slots, refusing without a registry like
  `reserve_subissue/2`.
  """
  @spec reserve_project_update(pid() | nil, pos_integer()) :: :ok | {:error, term()}
  def reserve_project_update(pid, cap) when is_pid(pid) and is_integer(cap),
    do: reserve(pid, :project_updates, cap, :project_update_cap_reached)

  def reserve_project_update(_pid, _cap), do: {:error, :project_update_registry_unavailable}

  @doc "Gives back a slot claimed by `reserve_project_update/2` when the post did not go through."
  @spec release_project_update(pid()) :: :ok
  def release_project_update(pid) when is_pid(pid), do: release(pid, :project_updates)

  defp reserve(pid, counter, cap, cap_error) do
    Agent.get_and_update(pid, fn state ->
      count = Map.get(state, counter, 0)

      if count < cap,
        do: {:ok, Map.put(state, counter, count + 1)},
        else: {{:error, {cap_error, cap}}, state}
    end)
  end

  defp release(pid, counter) do
    Agent.update(pid, fn state -> Map.update!(state, counter, &(&1 - 1)) end)
  end
end
