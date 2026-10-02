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

    Agent.start_link(fn -> %{comments: comments, subissues: 0} end, agent_opts)
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
  def reserve_subissue(pid, cap) when is_pid(pid) and is_integer(cap) do
    Agent.get_and_update(pid, fn
      %{subissues: count} = state when count < cap -> {:ok, %{state | subissues: count + 1}}
      state -> {{:error, {:subissue_cap_reached, cap}}, state}
    end)
  end

  def reserve_subissue(_pid, _cap), do: {:error, :subissue_registry_unavailable}

  @doc "Gives back a slot claimed by `reserve_subissue/2` when the create did not go through."
  @spec release_subissue(pid()) :: :ok
  def release_subissue(pid) when is_pid(pid) do
    Agent.update(pid, fn state -> %{state | subissues: state.subissues - 1} end)
  end
end
