defmodule SymphonyElixir.AgentTools.Linear.CommentRegistry do
  @moduledoc false

  # Per-run state for the scoped Linear tools: the comment ids this run created (so it may only
  # edit its own comments) and how many sub-issues it has created (so it stays under the cap), with
  # their ids by identifier (so a later sub-issue may be blocked by an earlier one), the documents it
  # created (so it may edit them before Linear lists their attachments, and stays under the cap), and
  # whether it asked a person for something (so its issue waits for that person in the Human Review
  # state), the comments of its that hold a `## Supervisor check` (so a ticket with no PR may still
  # go to `In Review` with Auto Review on), and whether it opened a PR (so that move is refused
  # before Linear's GitHub integration lists the PR among the issue's attachments).

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {seed_ids, agent_opts} = Keyword.pop(opts, :seed_ids, [])

    comments =
      seed_ids
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    state = %{
      comments: comments,
      subissues: 0,
      created_subissues: %{},
      project_updates: 0,
      documents: 0,
      created_documents: MapSet.new(),
      human_action_requested: false,
      supervisor_check_comments: MapSet.new(),
      pull_request_created: false
    }

    Agent.start_link(fn -> state end, agent_opts)
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

  @doc "The ids of the comments this run created or owns."
  @spec comment_ids(pid()) :: [String.t()]
  def comment_ids(pid) when is_pid(pid), do: Agent.get(pid, &MapSet.to_list(&1.comments))

  @spec remove(pid() | nil, String.t()) :: :ok
  def remove(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, fn state ->
      %{state | comments: MapSet.delete(state.comments, comment_id), supervisor_check_comments: MapSet.delete(state.supervisor_check_comments, comment_id)}
    end)
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

  @doc "Records a sub-issue this run created, by identifier."
  @spec record_subissue(pid(), String.t(), String.t()) :: :ok
  def record_subissue(pid, identifier, issue_id) when is_pid(pid) and is_binary(identifier) and is_binary(issue_id) do
    Agent.update(pid, fn state -> %{state | created_subissues: Map.put(state.created_subissues, identifier, issue_id)} end)
  end

  @doc "The sub-issues this run created, as a map of identifier to issue id."
  @spec created_subissues(pid()) :: %{String.t() => String.t()}
  def created_subissues(pid) when is_pid(pid), do: Agent.get(pid, & &1.created_subissues)

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

  @doc """
  Atomically claims one of the run's `cap` document slots, refusing without a registry like
  `reserve_subissue/2`.
  """
  @spec reserve_document(pid() | nil, pos_integer()) :: :ok | {:error, term()}
  def reserve_document(pid, cap) when is_pid(pid) and is_integer(cap),
    do: reserve(pid, :documents, cap, :document_cap_reached)

  def reserve_document(_pid, _cap), do: {:error, :document_registry_unavailable}

  @doc "Gives back a slot claimed by `reserve_document/2` when no document was created."
  @spec release_document(pid()) :: :ok
  def release_document(pid) when is_pid(pid), do: release(pid, :documents)

  @doc "Records a document this run created, by id."
  @spec record_document(pid(), String.t()) :: :ok
  def record_document(pid, document_id) when is_pid(pid) and is_binary(document_id) do
    Agent.update(pid, fn state -> %{state | created_documents: MapSet.put(state.created_documents, document_id)} end)
  end

  @doc "The ids of the documents this run created; none without a registry."
  @spec document_ids(pid() | nil) :: [String.t()]
  def document_ids(pid) when is_pid(pid), do: Agent.get(pid, &MapSet.to_list(&1.created_documents))
  def document_ids(_pid), do: []

  @doc """
  Atomically claims one of the run's `cap` human-action request slots, refusing without a registry
  like `reserve_subissue/2`.
  """
  @spec reserve_human_action(pid() | nil, pos_integer()) :: :ok | {:error, term()}
  def reserve_human_action(pid, cap) when is_pid(pid) and is_integer(cap),
    do: reserve(pid, :human_actions, cap, :human_action_cap_reached)

  def reserve_human_action(_pid, _cap), do: {:error, :human_action_registry_unavailable}

  @doc "Gives back a slot claimed by `reserve_human_action/2` when no request was posted."
  @spec release_human_action(pid()) :: :ok
  def release_human_action(pid) when is_pid(pid), do: release(pid, :human_actions)

  @doc "Records that the run's issue has an open human-action request, posted now or earlier."
  @spec record_human_action_request(pid()) :: :ok
  def record_human_action_request(pid) when is_pid(pid), do: Agent.update(pid, &Map.put(&1, :human_action_requested, true))

  @doc "True once `record_human_action_request/1` ran for this run."
  @spec human_action_requested?(pid() | nil) :: boolean()
  def human_action_requested?(pid) when is_pid(pid), do: Agent.get(pid, &Map.get(&1, :human_action_requested, false))
  def human_action_requested?(_pid), do: false

  @doc "Records that the run withdrew its issue's last open human-action request."
  @spec clear_human_action_request(pid() | nil) :: :ok
  def clear_human_action_request(pid) when is_pid(pid), do: Agent.update(pid, &Map.put(&1, :human_action_requested, false))
  def clear_human_action_request(_pid), do: :ok

  @doc """
  Records whether the run's comment `comment_id` holds a `## Supervisor check` block
  (`SymphonyElixir.SupervisorCheck`), as written now: an edit that drops the block clears it.
  """
  @spec record_supervisor_check(pid() | nil, String.t() | nil, boolean()) :: :ok
  def record_supervisor_check(pid, comment_id, holds_block?) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, fn state ->
      comments = if holds_block?, do: MapSet.put(state.supervisor_check_comments, comment_id), else: MapSet.delete(state.supervisor_check_comments, comment_id)
      %{state | supervisor_check_comments: comments}
    end)
  end

  def record_supervisor_check(_pid, _comment_id, _holds_block?), do: :ok

  @doc "True while at least one of the run's comments holds a `## Supervisor check` block."
  @spec supervisor_check?(pid() | nil) :: boolean()
  def supervisor_check?(pid) when is_pid(pid), do: Agent.get(pid, &(MapSet.size(&1.supervisor_check_comments) > 0))
  def supervisor_check?(_pid), do: false

  @doc "Records that the run opened a pull request."
  @spec record_pull_request(pid() | nil) :: :ok
  def record_pull_request(pid) when is_pid(pid), do: Agent.update(pid, &Map.put(&1, :pull_request_created, true))
  def record_pull_request(_pid), do: :ok

  @doc "True once `record_pull_request/1` ran for this run."
  @spec pull_request_created?(pid() | nil) :: boolean()
  def pull_request_created?(pid) when is_pid(pid), do: Agent.get(pid, & &1.pull_request_created)
  def pull_request_created?(_pid), do: false

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
