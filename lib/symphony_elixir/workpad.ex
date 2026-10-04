defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Deterministic issue workpad bootstrap before the first agent turn.

  Each Linear call waits out a rate limit or a dropped connection
  (`SymphonyElixir.Linear.TransientRetry`, with the run's `:linear_retry_opts`)
  instead of failing the run.
  """

  alias SymphonyElixir.{AgentLabels, AgentTools, Config, Linear.Issue, Linear.TransientRetry, Tracker}
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry

  @in_progress_state "In Progress"
  @todo_state "todo"
  @comment_limit 100

  @type bootstrap_result :: {:ok, Issue.t()} | {:error, term()}

  @spec bootstrap(Issue.t(), Path.t()) :: bootstrap_result()
  def bootstrap(%Issue{} = issue, workspace), do: bootstrap(issue, workspace, [])

  @spec bootstrap(Issue.t(), Path.t(), keyword()) :: bootstrap_result()
  def bootstrap(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    if pr_mode?(opts) do
      {:ok, issue}
    else
      with {:ok, issue} <- ensure_in_progress(issue, opts) do
        ensure_workpad(issue, workspace, opts)
      end
    end
  end

  @spec bootstrap_body(String.t(), Path.t()) :: String.t()
  def bootstrap_body(heading, workspace), do: bootstrap_body(heading, workspace, [])

  @spec bootstrap_body(String.t(), Path.t(), keyword()) :: String.t()
  def bootstrap_body(heading, workspace, opts) when is_binary(heading) and is_binary(workspace) do
    timestamp = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()

    """
    #{heading}

    ```text
    #{environment_stamp(workspace, opts)}
    ```

    ### Plan

    - [ ] Reconcile this bootstrap workpad with the Linear issue before implementation.

    ### Acceptance Criteria

    - [ ] Derived from the Linear issue description and comments.

    ### Validation

    - [ ] targeted tests: `<pending>`

    ### Notes

    - #{timestamp} - Symphony created this bootstrap workpad before the first agent turn.

    ### Confusions
    """
  end

  defp pr_mode?(opts), do: Keyword.get(opts, :prompt_mode) in [:pr, "pr"]

  defp todo_state?(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> Kernel.==(@todo_state)
  end

  defp todo_state?(_state), do: false

  defp ensure_in_progress(%Issue{id: issue_id, state: state} = issue, opts) when is_binary(issue_id) do
    if todo_state?(state) do
      move = fn -> Tracker.update_issue_state(issue_id, @in_progress_state) end

      case with_linear_retry(move, "moving #{issue_context(issue)} to #{@in_progress_state}", opts) do
        :ok ->
          {:ok, %{issue | state: @in_progress_state}}

        {:error, reason} ->
          {:error, {:workpad_bootstrap_state_update_failed, reason}}
      end
    else
      {:ok, issue}
    end
  end

  defp ensure_in_progress(%Issue{} = issue, _opts), do: {:ok, issue}

  defp ensure_workpad(%Issue{} = issue, workspace, opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    heading = agent_workpad_heading(settings)

    cond do
      existing_workpad_comment?(issue.comments) ->
        {:ok, issue}

      linear_tracker?(settings) ->
        ensure_linear_workpad(issue, workspace, heading, opts)

      true ->
        create_tracker_workpad(issue, workspace, heading, opts)
    end
  end

  # The read and the create are retried together: a create that timed out after Linear
  # saved the comment is found by the next read instead of posted twice.
  defp ensure_linear_workpad(issue, workspace, heading, opts) do
    find_or_create = fn -> find_or_create_linear_workpad(issue, workspace, heading, opts) end

    case with_linear_retry(find_or_create, "bootstrapping the workpad for #{issue_context(issue)}", opts) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> {:error, {:workpad_bootstrap_comment_failed, reason}}
    end
  end

  defp find_or_create_linear_workpad(issue, workspace, heading, opts) do
    context = %{issue: issue, workspace: workspace}

    with {:ok, comments} <- AgentTools.Linear.get_comments(context, @comment_limit, linear_opts(opts)),
         nil <- find_workpad_comment(comments) do
      create_linear_workpad(issue, workspace, heading, opts)
    else
      workpad_comment when is_map(workpad_comment) ->
        record_workpad_comment(workpad_comment, opts)
        {:ok, put_existing_workpad_comment(issue, workpad_comment)}

      {:error, _reason} = error ->
        error
    end
  end

  # Record the workpad comment id into the run's comment registry at bootstrap
  # time. Registry seeding in AgentRunner re-queries Linear moments after the
  # comment is created and can miss it (read lag), leaving the run unable to
  # update its own workpad (:comment_not_owned_by_run).
  defp create_linear_workpad(issue, workspace, heading, opts) do
    body = bootstrap_body(heading, workspace, opts)
    context = %{issue: issue, workspace: workspace, comment_registry: Keyword.get(opts, :comment_registry)}

    case AgentTools.Linear.add_comment(context, body, linear_opts(opts)) do
      {:ok, _response} ->
        {:ok, put_bootstrap_comment(issue, heading, body, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Comments come from the Linear API with string keys; a missing or
  # non-binary id is a no-op in CommentRegistry.record/2.
  defp record_workpad_comment(comment, opts) do
    CommentRegistry.record(Keyword.get(opts, :comment_registry), Map.get(comment, "id"))
  end

  defp create_tracker_workpad(%Issue{id: issue_id} = issue, workspace, heading, opts) when is_binary(issue_id) do
    body = bootstrap_body(heading, workspace, opts)
    create = fn -> Tracker.create_comment(issue_id, body) end

    case with_linear_retry(create, "posting the workpad for #{issue_context(issue)}", opts) do
      :ok ->
        {:ok, put_bootstrap_comment(issue, heading, body, opts)}

      {:error, reason} ->
        {:error, {:workpad_bootstrap_comment_failed, reason}}
    end
  end

  defp create_tracker_workpad(issue, _workspace, _heading, _opts), do: {:ok, issue}

  defp put_bootstrap_comment(%Issue{} = issue, heading, body, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    author = heading |> String.trim_leading("#") |> String.trim() |> String.replace_suffix(" Workpad", "")
    comment = %{author: author, body: body, created_at: now}

    %{issue | comments: [comment | normalized_comments(issue.comments)]}
  end

  defp put_existing_workpad_comment(%Issue{} = issue, comment) when is_map(comment) do
    comment = %{
      author: get_in(comment, ["user", "name"]) || Map.get(comment, :author) || Map.get(comment, "author") || "Linear",
      body: comment |> comment_body() |> normalize_existing_comment_body(),
      created_at: nil
    }

    %{issue | comments: [comment | normalized_comments(issue.comments)]}
  end

  defp normalized_comments(comments) when is_list(comments), do: comments
  defp normalized_comments(_comments), do: []

  defp existing_workpad_comment?(comments), do: find_workpad_comment(comments) != nil

  defp find_workpad_comment(comments) when is_list(comments) do
    Enum.find(comments, fn comment ->
      comment
      |> comment_body()
      |> workpad_body?()
    end)
  end

  defp find_workpad_comment(_comments), do: nil

  defp comment_body(%{"body" => body}) when is_binary(body), do: body
  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  defp normalize_existing_comment_body(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.replace_prefix("<linear_issue_comment_body>\n", "")
    |> String.replace_suffix("\n</linear_issue_comment_body>", "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp workpad_body?(body) when is_binary(body) do
    Enum.any?(AgentLabels.known_workpad_markers(), &String.contains?(body, &1))
  end

  defp workpad_body?(_body), do: false

  defp agent_workpad_heading(%{agent: %{kind: kind}}), do: AgentLabels.workpad_heading(kind)
  defp agent_workpad_heading(_settings), do: AgentLabels.workpad_heading(nil)

  defp linear_tracker?(%{tracker: %{kind: kind}}), do: to_string(kind) == "linear"
  defp linear_tracker?(_settings), do: false

  defp linear_opts(opts) do
    Keyword.take(opts, [:linear_client, :settings])
  end

  defp with_linear_retry(fun, label, opts) do
    TransientRetry.run(fun, opts |> Keyword.get(:linear_retry_opts, []) |> Keyword.put(:label, label))
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp environment_stamp(workspace, opts) do
    "#{worker_host(opts)}:#{workspace_path(workspace, opts)}@#{short_sha(workspace, opts)}"
  end

  defp workspace_path(workspace, opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) and host != "" -> workspace
      _ -> Path.expand(workspace)
    end
  end

  defp worker_host(opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) and host != "" -> host
      _ -> opts |> hostname_result() |> local_hostname()
    end
  end

  defp hostname_result(opts), do: Keyword.get_lazy(opts, :hostname_result, &:inet.gethostname/0)

  defp local_hostname(hostname_result) do
    case hostname_result do
      {:ok, hostname} -> List.to_string(hostname)
      {:error, _reason} -> "unknown-host"
    end
  end

  defp short_sha(_workspace, opts) do
    case Keyword.fetch(opts, :short_sha) do
      {:ok, sha} when is_binary(sha) and sha != "" -> sha
      _ -> "unknown"
    end
  end
end
