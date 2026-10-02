defmodule SymphonyElixir.AgentTools.Linear do
  @moduledoc """
  Narrow Linear operations exposed to agent prompts.

  The current issue id is supplied by Symphony session context. Callers cannot
  pass an issue id through tool arguments.
  """

  require Logger

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Workspace.Attachments
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.PromptSafety
  alias SymphonyElixir.SensitivePath
  alias SymphonyElixir.SubIssueWait

  @comment_limit_default 50
  @comment_limit_max 100
  @title_max_length 120
  @related_issue_first 50
  @public_file_upload_max_bytes 5 * 1024 * 1024
  @private_file_upload_max_bytes 50 * 1024 * 1024
  @default_attachment_allowed_hosts ["github.com"]
  # Moving an issue to `Merging` is how a human approves a merge, so agents may not do it.
  @merging_state "Merging"
  # Sub-issues land in Backlog so an agent cannot start other agents; a human promotes them.
  @backlog_state "Backlog"
  @subissue_cap_per_run 10
  # A project update notifies everyone following the project, so a run may post only one.
  @project_update_cap_per_run 1
  @project_update_healths ["onTrack", "atRisk", "offTrack"]

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @current_issue_query """
  query SymphonyAgentCurrentIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state { id name type }
      team { id key name }
      project { id name }
      branchName
      url
      assignee { id name }
      createdAt
      updatedAt
    }
  }
  """

  @subissues_query """
  query SymphonyAgentSubissues($id: String!, $first: Int!) {
    issue(id: $id) {
      children(first: $first) {
        nodes {
          id
          identifier
          title
          state { id name type }
          url
        }
      }
    }
  }
  """

  @parent_issue_query """
  query SymphonyAgentParentIssue($id: String!) {
    issue(id: $id) {
      parent {
        id
        identifier
        title
        description
        state { id name type }
        url
      }
    }
  }
  """

  @comments_query """
  query SymphonyAgentIssueComments($id: String!, $limit: Int!) {
    issue(id: $id) {
      comments(last: $limit, orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user { id name }
        }
      }
    }
  }
  """

  @related_issues_query """
  query SymphonyAgentRelatedIssues($id: String!, $first: Int!) {
    issue(id: $id) {
      relations(first: $first) {
        nodes {
          type
          relatedIssue {
            id
            identifier
            title
          }
        }
      }
      inverseRelations(first: $first) {
        nodes {
          type
          issue {
            id
            identifier
            title
          }
        }
      }
    }
  }
  """

  @team_states_query """
  query SymphonyAgentIssueTeamStates($id: String!) {
    issue(id: $id) {
      labels {
        nodes {
          name
        }
      }
      team {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyAgentViewer {
    viewer {
      id
    }
  }
  """

  @update_issue_state_mutation """
  mutation SymphonyAgentUpdateIssueState($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: { stateId: $stateId }) {
      success
      issue {
        id
        identifier
        state { id name type }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation SymphonyAgentAddComment($issueId: String!, $body: String!) {
    commentCreate(input: { issueId: $issueId, body: $body }) {
      success
      comment {
        id
        body
        url
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyAgentUpdateComment($id: String!, $body: String!) {
    commentUpdate(id: $id, input: { body: $body }) {
      success
      comment {
        id
        body
        url
      }
    }
  }
  """

  @delete_comment_mutation """
  mutation SymphonyAgentDeleteComment($id: String!) {
    commentDelete(id: $id) {
      success
    }
  }
  """

  @attach_url_mutation """
  mutation SymphonyAgentAttachURL($issueId: String!, $url: String!, $title: String) {
    attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @file_upload_mutation """
  mutation SymphonyAgentFileUpload($filename: String!, $contentType: String!, $size: Int!, $makePublic: Boolean) {
    fileUpload(filename: $filename, contentType: $contentType, size: $size, makePublic: $makePublic) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """

  @attachment_create_mutation """
  mutation SymphonyAgentAttachFile($issueId: String!, $url: String!, $title: String!) {
    attachmentCreate(input: { issueId: $issueId, url: $url, title: $title }) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @subissue_scope_query """
  query SymphonyAgentSubissueScope($id: String!) {
    issue(id: $id) {
      id
      team {
        id
        states {
          nodes {
            id
            name
            type
          }
        }
      }
      project { id }
      assignee { id }
    }
  }
  """

  @create_subissue_mutation """
  mutation SymphonyAgentCreateSubissue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        url
        state { id name type }
      }
    }
  }
  """

  @project_update_scope_query """
  query SymphonyAgentProjectUpdateScope($id: String!) {
    issue(id: $id) {
      project { id }
    }
  }
  """

  @create_project_update_mutation """
  mutation SymphonyAgentCreateProjectUpdate($input: ProjectUpdateCreateInput!) {
    projectUpdateCreate(input: $input) {
      success
      projectUpdate {
        id
        url
        health
      }
    }
  }
  """

  @type context :: %{
          optional(:issue) => Issue.t() | map(),
          optional(:issue_id) => String.t(),
          optional(:workspace) => Path.t(),
          optional(:comment_registry) => pid() | nil,
          optional(:command_security) => map()
        }

  @spec get_current_issue(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_current_issue(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@current_issue_query, %{id: issue_id}, opts) do
      with {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
        {:ok, wrap_issue(issue)}
      end
    end
  end

  @spec get_subissues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_subissues(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@subissues_query, %{id: issue_id, first: @related_issue_first}, opts) do
      with {:ok, nodes} <- fetch_path(body, ["data", "issue", "children", "nodes"], []) do
        {:ok, Enum.map(nodes, &wrap_issue_summary/1)}
      end
    end
  end

  @spec get_parent_issue(context(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def get_parent_issue(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@parent_issue_query, %{id: issue_id}, opts) do
      {:ok, wrap_issue_summary(get_in(body, ["data", "issue", "parent"]))}
    end
  end

  @spec get_comments(context(), integer() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_comments(context, limit \\ @comment_limit_default, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, normalized_limit} <- normalize_limit(limit),
         {:ok, body} <- graphql(@comments_query, %{id: issue_id, limit: normalized_limit}, opts),
         {:ok, nodes} <- fetch_path(body, ["data", "issue", "comments", "nodes"], []) do
      {:ok, nodes |> Enum.reverse() |> Enum.map(&wrap_comment(&1, context, opts))}
    end
  end

  @spec get_related_issues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_related_issues(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@related_issues_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      {:ok, issue |> related_issues() |> Enum.map(&wrap_issue_summary/1)}
    end
  end

  @spec update_state(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id), do: update_state(context, state_name_or_id, [])

  @spec update_state(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id, opts) when is_binary(state_name_or_id) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, state_id} <- resolve_state_id(issue_id, state_name_or_id, opts),
         {:ok, response} <- graphql(@update_issue_state_mutation, %{id: issue_id, stateId: state_id}, opts) do
      check_mutation_success(response, "issueUpdate")
    end
  end

  def update_state(_context, _state_name_or_id, _opts), do: {:error, :invalid_state}

  @spec add_comment(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body), do: add_comment(context, body, [])

  @spec add_comment(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body, opts) when is_binary(body) do
    with {:ok, issue_id} <- current_issue_id(context),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "linear_add_comment", opts),
         {:ok, response} <- graphql(@add_comment_mutation, %{issueId: issue_id, body: body}, opts),
         {:ok, response} <- check_mutation_success(response, "commentCreate") do
      comment_id = get_in(response, ["data", "commentCreate", "comment", "id"])
      CommentRegistry.record(Map.get(context, :comment_registry), comment_id)
      {:ok, response}
    end
  end

  def add_comment(_context, _body, _opts), do: {:error, :invalid_comment_body}

  @spec update_comment(context(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body), do: update_comment(context, comment_id, body, [])

  @spec update_comment(context(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body, opts) when is_binary(comment_id) and is_binary(body) do
    with :ok <- verify_comment_owner(context, comment_id),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "linear_update_comment", opts),
         {:ok, response} <- graphql(@update_comment_mutation, %{id: comment_id, body: body}, opts) do
      check_mutation_success(response, "commentUpdate")
    end
  end

  def update_comment(_context, _comment_id, _body, _opts), do: {:error, :invalid_comment}

  @spec delete_comment(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_comment(context, comment_id), do: delete_comment(context, comment_id, [])

  @spec delete_comment(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_comment(context, comment_id, opts) when is_binary(comment_id) do
    with :ok <- verify_comment_owner(context, comment_id),
         {:ok, response} <- graphql(@delete_comment_mutation, %{id: comment_id}, opts),
         {:ok, response} <- check_mutation_success(response, "commentDelete") do
      CommentRegistry.remove(Map.get(context, :comment_registry), comment_id)
      {:ok, response}
    end
  end

  def delete_comment(_context, _comment_id, _opts), do: {:error, :invalid_comment}

  @spec list_own_comment_ids(context(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_own_comment_ids(context, opts \\ []) do
    with {:ok, _issue_id} <- current_issue_id(context),
         {:ok, viewer_id} <- viewer_id(opts),
         {:ok, comments} <- get_comments(context, @comment_limit_max, opts) do
      ids =
        comments
        |> Enum.filter(fn comment -> get_in(comment, ["user", "id"]) == viewer_id end)
        |> Enum.map(& &1["id"])
        |> Enum.filter(&is_binary/1)

      {:ok, ids}
    end
  end

  @spec recover_comment_registry_seeds(map(), String.t() | atom() | nil) :: [String.t()]
  def recover_comment_registry_seeds(issue, tracker_kind),
    do: recover_comment_registry_seeds(issue, tracker_kind, [])

  @spec recover_comment_registry_seeds(map(), String.t() | atom() | nil, keyword()) :: [String.t()]
  def recover_comment_registry_seeds(issue, "linear", opts) do
    case list_own_comment_ids(%{issue: issue}, opts) do
      {:ok, ids} ->
        ids

      {:error, reason} ->
        Logger.warning("Failed to seed comment registry from Linear: #{inspect(reason)}")
        []
    end
  end

  def recover_comment_registry_seeds(_issue, _tracker_kind, _opts), do: []

  @spec attach_url(context(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def attach_url(context, url, title), do: attach_url(context, url, title, [])

  @spec attach_url(context(), String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def attach_url(context, url, title, opts) when is_binary(url) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, normalized_url} <- validate_url(url, opts),
         {:ok, normalized_title} <- normalize_title(title),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [url: normalized_url, title: normalized_title],
             context,
             "linear_attach_url",
             opts
           ),
         {:ok, response} <-
           graphql(@attach_url_mutation, %{issueId: issue_id, url: normalized_url, title: normalized_title}, opts) do
      check_mutation_success(response, "attachmentLinkURL")
    end
  end

  def attach_url(_context, _url, _title, _opts), do: {:error, :invalid_url}

  @spec attach_file(context(), Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def attach_file(context, local_path, title), do: attach_file(context, local_path, title, [])

  @spec attach_file(context(), Path.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def attach_file(context, local_path, title, opts) when is_binary(local_path) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, workspace} <- workspace(context),
         {:ok, path} <- validate_workspace_file(local_path, workspace),
         {:ok, normalized_title} <- normalize_title(title),
         {:ok, contents} <- file_read(path),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [title: normalized_title, file: contents],
             context,
             "linear_attach_file",
             opts
           ),
         {:ok, upload} <- request_file_upload(path, opts),
         :ok <- put_upload(contents, upload, content_type(path), opts),
         {:ok, asset_url} <- upload_asset_url(upload),
         {:ok, response} <-
           graphql(
             @attachment_create_mutation,
             %{issueId: issue_id, url: asset_url, title: normalized_title || Path.basename(path)},
             opts
           ) do
      check_mutation_success(response, "attachmentCreate")
    end
  end

  def attach_file(_context, _local_path, _title, _opts), do: {:error, :invalid_local_path}

  @doc """
  Creates a Backlog child of the current issue in the same team and project, assigned to the same
  assignee. Only `title`, `description`, and `priority` come from the caller; everything that
  scopes the new issue is read from the current issue. At most #{@subissue_cap_per_run} per run.
  """
  @spec create_subissue(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_subissue(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, title, description, priority} <- validate_subissue_fields(attrs),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [title: title, description: description],
             context,
             "linear_create_subissue",
             opts
           ),
         :ok <- CommentRegistry.reserve_subissue(registry, @subissue_cap_per_run) do
      case create_backlog_child(issue_id, title, description, priority, opts) do
        {:ok, response} ->
          {:ok, response}

        {:error, _reason} = error ->
          CommentRegistry.release_subissue(registry)
          error
      end
    end
  end

  @doc """
  Posts a project update to the current issue's project. Only `body` and an optional `health`
  (`onTrack`, `atRisk`, `offTrack`) come from the caller; the project is read from the current
  issue. At most #{@project_update_cap_per_run} per run.
  """
  @spec create_project_update(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_project_update(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body, health} <- validate_project_update_fields(attrs),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "linear_create_project_update", opts),
         :ok <- CommentRegistry.reserve_project_update(registry, @project_update_cap_per_run) do
      case post_project_update(issue_id, body, health, opts) do
        {:ok, response} ->
          {:ok, response}

        {:error, _reason} = error ->
          CommentRegistry.release_project_update(registry)
          error
      end
    end
  end

  defp validate_project_update_fields(attrs) do
    body = Map.get(attrs, "body")
    health = Map.get(attrs, "health")

    cond do
      not is_binary(body) or String.trim(body) == "" -> {:error, :invalid_project_update_body}
      not (is_nil(health) or health in @project_update_healths) -> {:error, :invalid_project_update_health}
      true -> {:ok, body, health}
    end
  end

  defp post_project_update(issue_id, body, health, opts) do
    with {:ok, scope} <- graphql(@project_update_scope_query, %{id: issue_id}, opts),
         {:ok, project_id} <- fetch_path(scope, ["data", "issue", "project", "id"], :issue_has_no_project),
         input = Map.reject(%{"projectId" => project_id, "body" => body, "health" => health}, fn {_key, value} -> is_nil(value) end),
         {:ok, response} <- graphql(@create_project_update_mutation, %{input: input}, opts) do
      check_mutation_success(response, "projectUpdateCreate")
    end
  end

  defp validate_subissue_fields(attrs) do
    title = Map.get(attrs, "title")
    description = Map.get(attrs, "description")
    priority = Map.get(attrs, "priority")

    cond do
      not is_binary(title) or String.trim(title) == "" -> {:error, :invalid_subissue_title}
      not is_binary(description) -> {:error, :invalid_subissue_description}
      not (is_nil(priority) or priority in 0..4) -> {:error, :invalid_subissue_priority}
      true -> {:ok, String.trim(title), description, priority}
    end
  end

  defp create_backlog_child(issue_id, title, description, priority, opts) do
    with {:ok, body} <- graphql(@subissue_scope_query, %{id: issue_id}, opts),
         {:ok, parent} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, states} <- fetch_path(parent, ["team", "states", "nodes"], []),
         {:ok, state_id} <- backlog_state_id(states),
         input = subissue_input(parent, state_id, title, description, priority),
         {:ok, response} <- graphql(@create_subissue_mutation, %{input: input}, opts) do
      check_mutation_success(response, "issueCreate")
    end
  end

  defp backlog_state_id(states) do
    state =
      Enum.find(states, &state_name_matches?(&1, @backlog_state)) ||
        Enum.find(states, &(&1["type"] == "backlog"))

    case state do
      %{"id" => state_id} -> {:ok, state_id}
      _ -> {:error, {:backlog_state_not_found, states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)}}
    end
  end

  defp subissue_input(parent, state_id, title, description, priority) do
    %{
      "teamId" => get_in(parent, ["team", "id"]),
      "parentId" => parent["id"],
      "stateId" => state_id,
      "title" => title,
      "description" => description,
      "projectId" => get_in(parent, ["project", "id"]),
      "assigneeId" => get_in(parent, ["assignee", "id"]),
      "priority" => priority
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolve_state_id(issue_id, state_name_or_id, opts) do
    normalized = String.trim(state_name_or_id)

    if normalized == "" do
      {:error, :invalid_state}
    else
      settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

      with {:ok, state, labels} <- lookup_team_state(issue_id, normalized, opts),
           {:ok, state_id} <- refuse_human_only_state(state),
           {:ok, state_id} <- refuse_auto_review_handoff_state(state, state_id, settings) do
        refuse_waiting_on_sub_issues_state(state, state_id, labels, settings)
      end
    end
  end

  # UUIDs are resolved against the team states too, so the target's name is known before the
  # human-only check runs.
  defp lookup_team_state(issue_id, name_or_id, opts) do
    matches? =
      if Regex.match?(@uuid_pattern, name_or_id),
        do: &state_id_matches?(&1, name_or_id),
        else: &state_name_matches?(&1, name_or_id)

    with {:ok, body} <- graphql(@team_states_query, %{id: issue_id}, opts),
         {:ok, states} <- fetch_path(body, ["data", "issue", "team", "states", "nodes"], []) do
      case Enum.find(states, matches?) do
        %{"id" => _} = state ->
          labels = body |> get_in(["data", "issue", "labels", "nodes"]) |> List.wrap() |> Enum.map(&label_name/1)
          {:ok, state, labels}

        _ ->
          available = states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
          {:error, {:state_not_found, available}}
      end
    end
  end

  defp refuse_human_only_state(%{"id" => state_id} = state) do
    if state_name_matches?(state, @merging_state),
      do: {:error, {:merging_requires_human_approval, state["name"]}},
      else: {:ok, state_id}
  end

  # With Auto Review on, Symphony moves the issue on from the PR being open, so an
  # agent asking for `In Review` is refused rather than silently redirected.
  defp refuse_auto_review_handoff_state(state, state_id, settings) do
    if AutoReview.enabled?(settings) and state_name_matches?(state, AutoReview.review_state()),
      do: {:error, {:in_review_set_by_auto_review, state["name"], AutoReview.state(settings)}},
      else: {:ok, state_id}
  end

  # Only a `breakdown` parent parks in the waiting state, and only while that state is on; otherwise
  # Symphony would hold the issue there with nothing to bring it back.
  defp refuse_waiting_on_sub_issues_state(state, state_id, labels, settings) do
    waiting_state = SubIssueWait.state(settings)

    cond do
      is_nil(waiting_state) or not state_name_matches?(state, waiting_state) ->
        {:ok, state_id}

      not SubIssueWait.enabled?(settings) ->
        {:error, {:waiting_on_sub_issues_state_disabled, state["name"]}}

      Enum.any?(labels, &Issue.breakdown_label?/1) ->
        {:ok, state_id}

      true ->
        {:error, {:waiting_on_sub_issues_state_for_breakdown_only, state["name"]}}
    end
  end

  defp label_name(%{"name" => name}), do: name
  defp label_name(_label), do: nil

  defp state_id_matches?(state, state_id) do
    String.downcase(to_string(state["id"])) == String.downcase(state_id)
  end

  defp state_name_matches?(state, name) do
    String.downcase(to_string(state["name"])) == String.downcase(name)
  end

  defp request_file_upload(path, opts) do
    make_public = Keyword.get(opts, :make_public, false) == true

    with {:ok, %File.Stat{size: size}} <- file_stat(path),
         :ok <- validate_file_upload_policy(path, size, make_public, opts),
         {:ok, body} <-
           graphql(
             @file_upload_mutation,
             %{filename: Path.basename(path), contentType: content_type(path), size: size, makePublic: make_public},
             opts
           ),
         {:ok, upload_file} <- fetch_path(body, ["data", "fileUpload", "uploadFile"], :upload_not_available) do
      case get_in(body, ["data", "fileUpload", "success"]) do
        false -> {:error, {:linear_mutation_failed, "fileUpload", body}}
        _ -> {:ok, upload_file}
      end
    end
  end

  defp validate_file_upload_policy(path, size, true, opts) do
    max_bytes = Keyword.get(opts, :max_public_upload_bytes, @public_file_upload_max_bytes)

    with :ok <- reject_sensitive_upload_filename(path, true),
         :ok <- validate_public_upload_extension(path, opts) do
      if size > max_bytes do
        {:error, {:file_upload_too_large, %{actual_bytes: size, max_bytes: max_bytes, make_public: true}}}
      else
        :ok
      end
    end
  end

  defp validate_file_upload_policy(path, size, false, opts) do
    max_bytes = Keyword.get(opts, :max_private_upload_bytes, @private_file_upload_max_bytes)

    with :ok <- reject_sensitive_upload_filename(path, false) do
      if size > max_bytes do
        {:error, {:file_upload_too_large, %{actual_bytes: size, max_bytes: max_bytes, make_public: false}}}
      else
        :ok
      end
    end
  end

  defp reject_sensitive_upload_filename(path, make_public) do
    basename = Path.basename(path)

    if SensitivePath.sensitive_basename?(basename) do
      {:error, {sensitive_upload_error(make_public), basename}}
    else
      :ok
    end
  end

  defp sensitive_upload_error(true), do: :public_upload_denied_sensitive_filename
  defp sensitive_upload_error(false), do: :private_upload_denied_sensitive_filename

  defp validate_public_upload_extension(path, opts) do
    extension = path |> Path.extname() |> String.downcase()
    allowed_extensions = public_upload_extensions(opts)

    if extension != "" and extension in allowed_extensions do
      :ok
    else
      {:error, {:public_extension_not_allowed, extension}}
    end
  end

  defp public_upload_extensions(opts) do
    case Keyword.get_lazy(opts, :settings, &Config.settings!/0) do
      %Schema{workspace: %{attachments: %Attachments{public_upload_extensions: extensions}}} ->
        extensions

      _settings ->
        Attachments.default_public_upload_extensions()
    end
  end

  defp put_upload(contents, %{"uploadUrl" => upload_url} = upload, content_type, opts) when is_binary(upload_url) do
    upload_client = Keyword.get(opts, :upload_client, &Req.put/2)

    headers =
      upload
      |> Map.get("headers", [])
      |> Enum.map(fn %{"key" => key, "value" => value} -> {key, value} end)
      |> ensure_content_type_header(content_type)

    case upload_client.(upload_url, headers: headers, body: contents) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:file_upload_status, status, body}}
      {:error, reason} -> {:error, {:file_upload_failed, reason}}
    end
  end

  defp put_upload(_contents, _upload, _content_type, _opts), do: {:error, :upload_url_missing}

  defp ensure_content_type_header(headers, content_type) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end) do
      headers
    else
      headers ++ [{"content-type", content_type}]
    end
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp file_read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp upload_asset_url(%{"assetUrl" => asset_url}) when is_binary(asset_url) and asset_url != "", do: {:ok, asset_url}
  defp upload_asset_url(_upload), do: {:error, :asset_url_missing}

  defp content_type(path), do: MIME.from_path(path)

  defp related_issues(issue) do
    relations =
      issue
      |> Map.get("relations", %{})
      |> Map.get("nodes", [])
      |> Enum.flat_map(&related_issue_from_relation(&1, "relation"))

    inverse_relations =
      issue
      |> Map.get("inverseRelations", %{})
      |> Map.get("nodes", [])
      |> Enum.flat_map(&related_issue_from_relation(&1, "inverse_relation"))

    relations ++ inverse_relations
  end

  defp related_issue_from_relation(%{"type" => type} = relation, direction) do
    if block_relation?(type) do
      issue = Map.get(relation, "relatedIssue") || Map.get(relation, "issue")

      case issue do
        %{} ->
          [
            %{
              "relation" => direction,
              "type" => type,
              "id" => issue["id"],
              "identifier" => issue["identifier"],
              "title" => issue["title"]
            }
          ]

        _ ->
          []
      end
    else
      []
    end
  end

  defp related_issue_from_relation(_relation, _direction), do: []

  defp wrap_issue(issue) when is_map(issue) do
    issue
    |> put_assignee_id()
    |> wrap_string_field("title", &PromptSafety.linear_issue_title/1)
    |> wrap_string_field("description", &PromptSafety.linear_issue_body/1)
    |> wrap_nested_comment_nodes()
  end

  defp wrap_issue(issue), do: issue

  defp put_assignee_id(%{"assignee" => %{"id" => assignee_id}} = issue) when is_binary(assignee_id) do
    Map.put_new(issue, "assignee_id", assignee_id)
  end

  defp put_assignee_id(issue), do: issue

  defp wrap_issue_summary(issue) when is_map(issue) do
    issue
    |> wrap_string_field("title", &PromptSafety.linear_issue_title/1)
    |> wrap_string_field("description", &PromptSafety.linear_issue_body/1)
  end

  defp wrap_issue_summary(issue), do: issue

  defp wrap_comment(comment) when is_map(comment) do
    comment
    |> redact_string_field("body")
    |> wrap_string_field("body", &PromptSafety.linear_issue_comment_body/1)
  end

  defp wrap_comment(comment), do: comment

  defp wrap_comment(comment, context, opts) when is_map(comment) do
    comment
    |> redact_string_field("body", context, "linear_get_comments", opts)
    |> wrap_string_field("body", &PromptSafety.linear_issue_comment_body/1)
  end

  defp wrap_comment(comment, _context, _opts), do: comment

  defp redact_string_field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        {redacted, _patterns} = SecretScanner.redact(value)
        Map.put(map, key, redacted)

      _missing_or_non_string ->
        map
    end
  end

  defp redact_string_field(map, key, context, tool, opts) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        {redacted, patterns} = SecretScanner.redact(value)
        SecretScanner.audit_redaction(patterns, context, tool, key, opts)
        Map.put(map, key, redacted)

      _missing_or_non_string ->
        map
    end
  end

  defp wrap_nested_comment_nodes(%{"comments" => %{"nodes" => nodes}} = issue) when is_list(nodes) do
    put_in(issue, ["comments", "nodes"], Enum.map(nodes, &wrap_comment/1))
  end

  defp wrap_nested_comment_nodes(issue), do: issue

  defp wrap_string_field(map, key, fun) when is_map(map) and is_binary(key) and is_function(fun, 1) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end

  defp block_relation?(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.contains?("block")
  end

  defp block_relation?(_type), do: false

  defp verify_comment_owner(context, comment_id) do
    if CommentRegistry.owned?(Map.get(context, :comment_registry), comment_id) do
      :ok
    else
      {:error, :comment_not_owned_by_run}
    end
  end

  defp normalize_limit(nil), do: {:ok, @comment_limit_default}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, @comment_limit_max)}
  end

  defp normalize_limit(_limit), do: {:error, :invalid_limit}

  defp validate_url(url, opts) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      host = String.downcase(uri.host)
      allowed_hosts = attachment_allowed_hosts(opts)

      if host in allowed_hosts do
        {:ok, trimmed}
      else
        {:error, {:host_not_allowed, host}}
      end
    else
      {:error, :invalid_url}
    end
  end

  defp attachment_allowed_hosts(opts) do
    opts
    |> Keyword.get_lazy(:settings, &Config.settings!/0)
    |> get_in([Access.key(:workspace), Access.key(:attachments), Access.key(:allowed_hosts)])
    |> normalize_allowed_hosts()
  end

  defp normalize_allowed_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> @default_attachment_allowed_hosts
      normalized -> normalized
    end
  end

  defp normalize_allowed_hosts(_hosts), do: @default_attachment_allowed_hosts

  defp normalize_title(nil), do: {:ok, nil}

  defp normalize_title(title) when is_binary(title) do
    trimmed = String.trim(title)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) <= @title_max_length -> {:ok, trimmed}
      true -> {:error, :title_too_long}
    end
  end

  defp normalize_title(_title), do: {:error, :invalid_title}

  defp validate_workspace_file(local_path, workspace) do
    expanded_path = Path.expand(local_path, workspace)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path),
         :ok <- ensure_inside_workspace(canonical_path, canonical_workspace),
         :ok <- ensure_regular_file(canonical_path) do
      {:ok, canonical_path}
    end
  end

  defp ensure_inside_workspace(path, workspace) do
    workspace_prefix = workspace <> "/"

    if path == workspace or String.starts_with?(path, workspace_prefix) do
      :ok
    else
      {:error, :path_outside_workspace}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp viewer_id(opts) do
    with {:ok, body} <- graphql(@viewer_query, %{}, opts) do
      fetch_path(body, ["data", "viewer", "id"], :viewer_not_found)
    end
  end

  defp current_issue_id(%{issue_id: issue_id}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %Issue{id: issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %{id: issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %{"id" => issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(_context), do: {:error, :missing_current_issue}

  defp workspace(%{workspace: workspace}) when is_binary(workspace) and workspace != "", do: {:ok, workspace}
  defp workspace(_context), do: {:error, :missing_workspace}

  defp graphql(query, variables, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, body} <- linear_client.(query, variables, []) do
      case body do
        %{"errors" => errors} when is_list(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
        %{errors: errors} when is_list(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
        body -> {:ok, body}
      end
    end
  end

  defp check_mutation_success(response, field) do
    case get_in(response, ["data", field, "success"]) do
      false -> {:error, {:linear_mutation_failed, field, response}}
      _ -> {:ok, response}
    end
  end

  defp fetch_path(body, path, default_or_error) do
    case get_in(body, path) do
      nil when is_list(default_or_error) -> {:ok, default_or_error}
      nil -> {:error, default_or_error}
      value -> {:ok, value}
    end
  end
end
