defmodule SymphonyElixir.AgentTools.Linear do
  @moduledoc """
  Narrow Linear operations exposed to agent prompts.

  The current issue id is supplied by Symphony session context. Callers cannot
  pass an issue id through tool arguments.
  """

  require Logger

  alias SymphonyElixir.AgentLabels
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Workspace.Attachments
  alias SymphonyElixir.HumanActions
  alias SymphonyElixir.HumanActions.Collector, as: HumanActionsCollector
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.HumanReview
  alias SymphonyElixir.Linear.{Client, Issue, TransientRetry}
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.PromptSafety
  alias SymphonyElixir.RunKind
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
  @subissue_update_fields [{"title", :title}, {"description", :description}, {"blocked_by", :blocked_by}, {"cancel_reason", :cancel_reason}]
  # A project update notifies everyone following the project, so a run may post only one.
  @project_update_cap_per_run 1
  @project_update_healths ["onTrack", "atRisk", "offTrack"]
  # Requests for a human are deduplicated by title, so this only bounds a run that loops.
  @human_action_cap_per_run 5
  @human_action_max_steps 15
  @human_action_max_minutes 480
  # Documents hold a ticket's long-lived artifacts, edited over several runs; this bounds a run that loops.
  @document_cap_per_run 10
  @document_attachment_first 100
  # An issue attachment whose metadata carries this key marks a document Symphony created for the
  # issue, so a later run on it may edit the document. A person cannot set attachment metadata.
  @document_metadata_key "symphonyDocumentId"
  @document_title_separator " · "

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
          parent { id }
        }
      }
    }
  }
  """

  # The current issue's family: the blockers it lists, plus its parent, siblings and sub-issues.
  @related_issues_query """
  query SymphonyAgentRelatedIssues($id: String!, $first: Int!) {
    issue(id: $id) {
      id
      relations(first: $first) {
        nodes {
          type
          relatedIssue {
            id
            identifier
            title
            state { name }
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
            state { name }
          }
        }
      }
      parent {
        id
        identifier
        title
        state { name }
        children(first: $first) {
          nodes { id identifier title state { name } }
        }
      }
      children(first: $first) {
        nodes { id identifier title state { name } }
      }
    }
  }
  """

  @related_issue_query """
  query SymphonyAgentRelatedIssue($id: String!, $limit: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state { id name type }
      labels { nodes { name } }
      url
      comments(last: $limit, orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user { id name }
          parent { id }
        }
      }
    }
  }
  """

  @team_states_query """
  query SymphonyAgentIssueTeamStates($id: String!) {
    issue(id: $id) {
      title
      description
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

  @add_reply_mutation """
  mutation SymphonyAgentAddReply($issueId: String!, $parentId: String!, $body: String!) {
    commentCreate(input: { issueId: $issueId, parentId: $parentId, body: $body }) {
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
  query SymphonyAgentSubissueScope($id: String!, $first: Int!) {
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
      children(first: $first) {
        nodes { id identifier }
      }
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

  @create_issue_relation_mutation """
  mutation SymphonyAgentCreateIssueRelation($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) {
      success
    }
  }
  """

  # A sub-issue's blocked-by links are its inverse `blocks` relations.
  @subissue_update_scope_query """
  query SymphonyAgentSubissueUpdateScope($id: String!, $first: Int!) {
    issue(id: $id) {
      id
      team {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
      children(first: $first) {
        nodes {
          id
          identifier
          state { name type }
          inverseRelations(first: $first) {
            nodes {
              id
              type
              issue { id identifier }
            }
          }
        }
      }
    }
  }
  """

  @update_subissue_mutation """
  mutation SymphonyAgentUpdateSubissue($id: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $id, input: $input) {
      success
      issue {
        id
        identifier
        url
        state { name }
      }
    }
  }
  """

  @delete_issue_relation_mutation """
  mutation SymphonyAgentDeleteIssueRelation($id: String!) {
    issueRelationDelete(id: $id) {
      success
    }
  }
  """

  @issue_by_identifier_query """
  query SymphonyAgentIssueByIdentifier($id: String!) {
    issue(id: $id) {
      id
      identifier
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

  @human_action_scope_query """
  query SymphonyAgentHumanActionScope($id: String!, $label: String!) {
    issue(id: $id) {
      id
      team { id }
      labels { nodes { id name } }
      comments(last: 50, orderBy: createdAt) {
        nodes { id body createdAt parent { id } }
      }
      history(first: 50) {
        nodes { createdAt fromState { name } toState { name } }
      }
    }
    issueLabels(filter: {name: {eqIgnoreCase: $label}}, first: 50) {
      nodes { id team { id } }
    }
  }
  """

  @create_label_mutation """
  mutation SymphonyAgentCreateLabel($input: IssueLabelCreateInput!) {
    issueLabelCreate(input: $input) {
      success
      issueLabel { id }
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAgentAddLabel($issueId: String!, $labelId: String!) {
    issueAddLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyAgentRemoveLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) {
      success
    }
  }
  """

  @document_scope_query """
  query SymphonyAgentDocumentScope($id: String!, $first: Int!) {
    issue(id: $id) {
      id
      identifier
      project { id }
      attachments(first: $first) {
        nodes { metadata }
      }
    }
  }
  """

  @create_document_mutation """
  mutation SymphonyAgentCreateDocument($input: DocumentCreateInput!) {
    documentCreate(input: $input) {
      success
      document { id title url }
    }
  }
  """

  @update_document_mutation """
  mutation SymphonyAgentUpdateDocument($id: String!, $input: DocumentUpdateInput!) {
    documentUpdate(id: $id, input: $input) {
      success
      document { id title url }
    }
  }
  """

  @attach_document_mutation """
  mutation SymphonyAgentAttachDocument($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment { id url }
    }
  }
  """

  @document_query """
  query SymphonyAgentDocument($id: String!) {
    document(id: $id) {
      id
      title
      content
      url
      updatedAt
    }
  }
  """

  @documents_query """
  query SymphonyAgentDocuments($ids: [ID!]!, $first: Int!) {
    documents(filter: { id: { in: $ids } }, first: $first) {
      nodes { id title url updatedAt }
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
         {:ok, body} <- signed_graphql(@current_issue_query, %{id: issue_id}, opts) do
      with {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
        {:ok, wrap_issue(issue)}
      end
    end
  end

  @spec get_subissues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_subissues(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- signed_graphql(@subissues_query, %{id: issue_id, first: @related_issue_first}, opts) do
      with {:ok, nodes} <- fetch_path(body, ["data", "issue", "children", "nodes"], []) do
        {:ok, Enum.map(nodes, &wrap_issue_summary/1)}
      end
    end
  end

  @spec get_parent_issue(context(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def get_parent_issue(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- signed_graphql(@parent_issue_query, %{id: issue_id}, opts) do
      {:ok, wrap_issue_summary(get_in(body, ["data", "issue", "parent"]))}
    end
  end

  @spec get_comments(context(), integer() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_comments(context, limit \\ @comment_limit_default, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, normalized_limit} <- normalize_limit(limit),
         {:ok, body} <- signed_graphql(@comments_query, %{id: issue_id, limit: normalized_limit}, opts),
         {:ok, nodes} <- fetch_path(body, ["data", "issue", "comments", "nodes"], []) do
      {:ok, nodes |> Enum.reverse() |> Enum.map(&wrap_comment(&1, context, "linear_get_comments", opts))}
    end
  end

  @spec get_related_issues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_related_issues(context, opts \\ []) do
    with {:ok, related} <- fetch_related_issues(context, opts) do
      {:ok, Enum.map(related, &wrap_issue_summary/1)}
    end
  end

  @doc """
  Reads one issue of the current issue's family (its parent, a sibling, a sub-issue, or an issue
  it blocks or is blocked by) with its comments, newest first. Any other issue is refused.
  """
  @spec get_related_issue(context(), String.t() | nil, integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def get_related_issue(context, identifier, comment_limit, opts \\ []) do
    with {:ok, identifier} <- validate_related_identifier(identifier),
         {:ok, limit} <- normalize_limit(comment_limit),
         {:ok, related} <- fetch_related_issues(context, opts),
         {:ok, issue_id, relations} <- family_member(related, identifier),
         {:ok, body} <- signed_graphql(@related_issue_query, %{id: issue_id, limit: limit}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      {:ok, wrap_related_issue(issue, relations, context, opts)}
    end
  end

  defp fetch_related_issues(context, opts) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@related_issues_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      {:ok, related_issues(issue) ++ family_issues(issue)}
    end
  end

  defp validate_related_identifier(identifier) do
    if non_blank?(identifier), do: {:ok, identifier |> String.trim() |> String.upcase()}, else: {:error, :invalid_related_issue_identifier}
  end

  defp family_member(related, identifier) do
    case Enum.filter(related, &(is_binary(&1["identifier"]) and String.upcase(&1["identifier"]) == identifier)) do
      [] ->
        {:error, {:issue_outside_family, identifier, related |> Enum.map(& &1["identifier"]) |> Enum.uniq()}}

      [%{"id" => issue_id} | _rest] = matches ->
        {:ok, issue_id, matches |> Enum.map(&family_relation/1) |> Enum.uniq()}
    end
  end

  defp family_relation(%{"relation" => "relation", "type" => type}), do: type
  defp family_relation(%{"relation" => "inverse_relation"}), do: "blocked_by"
  defp family_relation(%{"relation" => relation}), do: relation

  defp wrap_related_issue(issue, relations, context, opts) do
    comments = get_in(issue, ["comments", "nodes"]) || []

    issue
    |> wrap_issue_summary()
    |> Map.put("labels", Enum.map(get_in(issue, ["labels", "nodes"]) || [], & &1["name"]))
    |> Map.put("relations", relations)
    |> Map.put("comments", comments |> Enum.reverse() |> Enum.map(&wrap_comment(&1, context, "linear_get_related_issues", opts)))
  end

  @spec update_state(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id), do: update_state(context, state_name_or_id, [])

  @spec update_state(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id, opts) when is_binary(state_name_or_id) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, state_id} <- resolve_state_id(issue_id, state_name_or_id, CommentRegistry.human_action_requested?(Map.get(context, :comment_registry)), opts),
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
         {:ok, mutation, variables} <- comment_create(issue_id, body, Keyword.get(opts, :parent_id)),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "linear_add_comment", opts),
         {:ok, response} <- graphql(mutation, variables, opts),
         {:ok, response} <- check_mutation_success(response, "commentCreate") do
      comment_id = get_in(response, ["data", "commentCreate", "comment", "id"])
      CommentRegistry.record(Map.get(context, :comment_registry), comment_id)
      {:ok, response}
    end
  end

  def add_comment(_context, _body, _opts), do: {:error, :invalid_comment_body}

  # With `parent_id` the comment is a reply under that comment on the current issue.
  defp comment_create(issue_id, body, nil), do: {:ok, @add_comment_mutation, %{issueId: issue_id, body: body}}

  defp comment_create(issue_id, body, parent_id) when is_binary(parent_id) do
    if String.trim(parent_id) == "",
      do: {:error, :invalid_comment_parent},
      else: {:ok, @add_reply_mutation, %{issueId: issue_id, parentId: String.trim(parent_id), body: body}}
  end

  defp comment_create(_issue_id, _body, _parent_id), do: {:error, :invalid_comment_parent}

  @spec update_comment(context(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body), do: update_comment(context, comment_id, body, [])

  @spec update_comment(context(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body, opts) when is_binary(comment_id) and is_binary(body) do
    with :ok <- verify_comment_owner(context, comment_id),
         :ok <- reject_truncated_body(body),
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
    label = "seeding the comment registry for issue_id=#{Map.get(issue, :id)} issue_identifier=#{Map.get(issue, :identifier)}"
    retry_opts = opts |> Keyword.get(:linear_retry_opts, []) |> Keyword.put(:label, label)

    case TransientRetry.run(fn -> list_own_comment_ids(%{issue: issue}, opts) end, retry_opts) do
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
  assignee. Only `title`, `description`, `priority`, and `blocked_by` come from the caller;
  everything that scopes the new issue is read from the current issue. At most
  #{@subissue_cap_per_run} per run.

  `blocked_by` lists identifiers of sibling sub-issues (the current issue's existing children, or
  sub-issues this run created) that block the new one. Unknown identifiers are refused before
  anything is created; the `blocks` relations are created right after the issue.
  """
  @spec create_subissue(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_subissue(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, title, description, priority, blocked_by} <- validate_subissue_fields(attrs),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [title: title, description: description],
             context,
             "linear_create_subissue",
             opts
           ),
         :ok <- CommentRegistry.reserve_subissue(registry, @subissue_cap_per_run) do
      case create_backlog_child(issue_id, {title, description, priority, blocked_by}, registry, opts) do
        {:ok, response} ->
          {:ok, response}

        # The issue exists by then, so its slot stays used.
        {:error, {:blocked_by_relation_failed, _identifier, _blocker, _reason}} = error ->
          error

        {:error, _reason} = error ->
          CommentRegistry.release_subissue(registry)
          error
      end
    end
  end

  @doc """
  Changes a `Backlog` child of the current issue, so a breakdown run can bring its plan in line
  with review comments. `identifier` names the sub-issue; then either `title` and/or `description`
  replace its fields and `blocked_by` sets the complete list of sibling sub-issues that block it
  (links to siblings left out are removed, links to other issues stay), or `cancel_reason` cancels
  it after posting the reason on it. A sub-issue outside `Backlog` was promoted by a person and is
  refused, as is any issue that is not a child of the current one.
  """
  @spec update_subissue(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_subissue(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, identifier, change} <- validate_subissue_update(attrs),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             change |> Map.take([:title, :description, :cancel_reason]) |> Enum.to_list(),
             context,
             "linear_update_subissue",
             opts
           ),
         {:ok, body} <- graphql(@subissue_update_scope_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, parent} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, children} <- fetch_path(parent, ["children", "nodes"], []),
         {:ok, child} <- backlog_child(children, identifier) do
      apply_subissue_change(parent, children, child, change, opts)
    end
  end

  defp validate_subissue_update(attrs) do
    identifier = Map.get(attrs, "identifier")
    change = for {key, field} <- @subissue_update_fields, Map.has_key?(attrs, key), into: %{}, do: {field, attrs[key]}

    with :ok <- check_subissue_identifier(identifier),
         :ok <- check_subissue_change(change) do
      {:ok, identifier |> String.trim() |> String.upcase(), normalize_subissue_change(change)}
    end
  end

  defp check_subissue_identifier(identifier),
    do: if(non_blank?(identifier), do: :ok, else: {:error, :invalid_subissue_identifier})

  # A cancel stands alone: it would drop any edit made with it.
  defp check_subissue_change(change) when map_size(change) == 0, do: {:error, :invalid_subissue_update}
  defp check_subissue_change(%{cancel_reason: _reason} = change) when map_size(change) > 1, do: {:error, :invalid_subissue_update}

  defp check_subissue_change(change) do
    Enum.find_value(change, :ok, fn {field, value} ->
      if valid_subissue_field?(field, value), do: nil, else: {:error, subissue_field_error(field)}
    end)
  end

  defp valid_subissue_field?(:description, value), do: is_binary(value)
  defp valid_subissue_field?(:blocked_by, value), do: valid_blocked_by?(value)
  defp valid_subissue_field?(_title_or_cancel_reason, value), do: non_blank?(value)

  defp subissue_field_error(:title), do: :invalid_subissue_title
  defp subissue_field_error(:description), do: :invalid_subissue_description
  defp subissue_field_error(:blocked_by), do: :invalid_subissue_blocked_by
  defp subissue_field_error(:cancel_reason), do: :invalid_subissue_cancel_reason

  defp normalize_subissue_change(change) do
    change
    |> Map.update(:title, nil, &String.trim/1)
    |> Map.update(:blocked_by, nil, &normalize_identifiers/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp backlog_child(children, identifier) do
    case Enum.find(children, &(&1["identifier"] == identifier)) do
      nil ->
        {:error, {:not_a_subissue, identifier, children |> Enum.map(& &1["identifier"]) |> Enum.sort()}}

      child ->
        if state_name_matches?(child["state"] || %{}, @backlog_state),
          do: {:ok, child},
          else: {:error, {:subissue_not_in_backlog, identifier, get_in(child, ["state", "name"])}}
    end
  end

  defp apply_subissue_change(parent, _children, child, %{cancel_reason: reason}, opts) do
    with {:ok, state_id} <- canceled_state_id(get_in(parent, ["team", "states", "nodes"]) || []),
         {:ok, response} <- graphql(@add_comment_mutation, %{issueId: child["id"], body: reason}, opts),
         {:ok, _response} <- check_mutation_success(response, "commentCreate"),
         {:ok, response} <- graphql(@update_subissue_mutation, %{id: child["id"], input: %{"stateId" => state_id}}, opts),
         {:ok, _response} <- check_mutation_success(response, "issueUpdate") do
      {:ok, %{"identifier" => child["identifier"], "canceled" => true}}
    end
  end

  defp apply_subissue_change(_parent, children, child, change, opts) do
    input = change |> Map.take([:title, :description]) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    with :ok <- update_subissue_fields(child, input, opts),
         :ok <- set_sibling_blockers(children, child, Map.get(change, :blocked_by), opts) do
      {:ok, Map.merge(%{"identifier" => child["identifier"], "updated" => Map.keys(input) |> Enum.sort()}, blocked_by_result(change))}
    end
  end

  defp blocked_by_result(%{blocked_by: blocked_by}), do: %{"blockedBy" => blocked_by}
  defp blocked_by_result(_change), do: %{}

  defp update_subissue_fields(_child, input, _opts) when map_size(input) == 0, do: :ok

  defp update_subissue_fields(child, input, opts) do
    with {:ok, response} <- graphql(@update_subissue_mutation, %{id: child["id"], input: input}, opts),
         {:ok, _response} <- check_mutation_success(response, "issueUpdate") do
      :ok
    end
  end

  defp set_sibling_blockers(_children, _child, nil, _opts), do: :ok

  defp set_sibling_blockers(children, child, blocked_by, opts) do
    siblings = children |> Enum.reject(&(&1["id"] == child["id"])) |> Map.new(&{&1["identifier"], &1["id"]})

    case Enum.reject(blocked_by, &Map.has_key?(siblings, &1)) do
      [] ->
        current = sibling_blocker_relations(child, siblings)
        add = Enum.reject(blocked_by, &Map.has_key?(current, &1))
        remove = current |> Map.drop(blocked_by) |> Map.values()

        case link_blockers_to(child["id"], Enum.map(add, &{&1, Map.fetch!(siblings, &1)}), opts) do
          :ok ->
            unlink_blockers(remove, opts)

          {:error, {:add_blocked_by_failed, blocker, reason}} ->
            {:error, {:subissue_blocked_by_failed, child["identifier"], blocker, reason}}
        end

      unknown ->
        {:error, {:subissue_blocked_by_not_sibling, unknown, siblings |> Map.keys() |> Enum.sort()}}
    end
  end

  # The child's `blocks` relations from its siblings, by the blocking sibling's identifier.
  defp sibling_blocker_relations(child, siblings) do
    sibling_ids = siblings |> Map.values() |> MapSet.new()

    child
    |> get_in(["inverseRelations", "nodes"])
    |> List.wrap()
    |> Enum.filter(&(&1["type"] == "blocks" and MapSet.member?(sibling_ids, get_in(&1, ["issue", "id"]))))
    |> Map.new(&{get_in(&1, ["issue", "identifier"]), &1["id"]})
  end

  defp unlink_blockers(relation_ids, opts) do
    Enum.reduce_while(relation_ids, :ok, fn relation_id, :ok ->
      with {:ok, body} <- graphql(@delete_issue_relation_mutation, %{id: relation_id}, opts),
           {:ok, _body} <- check_mutation_success(body, "issueRelationDelete") do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:remove_blocked_by_failed, reason}}}
      end
    end)
  end

  defp canceled_state_id(states) do
    state =
      Enum.find(states, &(state_name_matches?(&1, "Canceled") or state_name_matches?(&1, "Cancelled"))) ||
        Enum.find(states, &(&1["type"] == "canceled"))

    case state do
      %{"id" => state_id} -> {:ok, state_id}
      _ -> {:error, {:canceled_state_not_found, states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)}}
    end
  end

  @doc """
  Marks the current issue blocked by existing issues: each identifier in `blocked_by` gets a
  `blocks` relation to the current issue, so Symphony holds it in `Todo` until every blocker is
  terminal. A final verification uses it to wait on the gaps it filed. Every identifier is looked
  up before any relation is created; unknown identifiers and the current issue itself are refused.
  """
  @spec add_blocked_by(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_blocked_by(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, identifiers} <- validate_add_blocked_by(Map.get(attrs, "blocked_by")),
         {:ok, blockers} <- resolve_issues_by_identifier(identifiers, opts),
         :ok <- reject_self_blocker(blockers, issue_id),
         :ok <- link_blockers_to(issue_id, blockers, opts) do
      {:ok, %{"blockedBy" => identifiers}}
    end
  end

  defp validate_add_blocked_by(blocked_by) do
    if blocked_by != [] and valid_blocked_by?(blocked_by),
      do: {:ok, normalize_identifiers(blocked_by)},
      else: {:error, :invalid_add_blocked_by}
  end

  defp resolve_issues_by_identifier(identifiers, opts) do
    with {:ok, resolved} <- lookup_identifiers(identifiers, opts),
         [] <- for({identifier, nil} <- resolved, do: identifier) do
      {:ok, resolved}
    else
      unknown when is_list(unknown) -> {:error, {:blocked_by_not_found, unknown}}
      {:error, _reason} = error -> error
    end
  end

  defp lookup_identifiers(identifiers, opts) do
    identifiers
    |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, acc} ->
      case issue_id_for_identifier(identifier, opts) do
        {:ok, id} -> {:cont, {:ok, [{identifier, id} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  # `{:ok, nil}` when Linear has no such issue.
  defp issue_id_for_identifier(identifier, opts) do
    case graphql(@issue_by_identifier_query, %{id: identifier}, opts) do
      {:ok, %{"data" => %{"issue" => %{"id" => id}}}} when is_binary(id) -> {:ok, id}
      {:ok, _body} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_self_blocker(blockers, issue_id) do
    case Enum.find(blockers, fn {_identifier, id} -> id == issue_id end) do
      nil -> :ok
      {identifier, _id} -> {:error, {:blocked_by_self, identifier}}
    end
  end

  defp link_blockers_to(issue_id, blockers, opts) do
    Enum.reduce_while(blockers, :ok, fn {blocker, blocker_id}, :ok ->
      input = %{"issueId" => blocker_id, "relatedIssueId" => issue_id, "type" => "blocks"}

      with {:ok, body} <- graphql(@create_issue_relation_mutation, %{input: input}, opts),
           {:ok, _body} <- check_mutation_success(body, "issueRelationCreate") do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:add_blocked_by_failed, blocker, reason}}}
      end
    end)
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

  @doc """
  Records that the current issue needs something only a human can do: adds the
  `human_actions.label` label to the issue and posts an `## Action needed:` comment
  (`SymphonyElixir.HumanActions.Request`), which Symphony lists in the project's human-action
  update. A request with the same title still open on the issue is not posted again. Every field
  is refused when it holds a secret pattern. At most #{@human_action_cap_per_run} per run.
  """
  @spec request_human_action(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_human_action(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, request} <- validate_human_action(attrs),
         :ok <- reject_human_action_secrets(request, context, opts),
         {:ok, settings} <- human_actions_settings(context, opts),
         :ok <- CommentRegistry.reserve_human_action(registry, @human_action_cap_per_run) do
      case post_human_action(issue_id, request, settings, opts) do
        {:ok, %{"requested" => true}} = result ->
          CommentRegistry.record_human_action_request(registry)
          Keyword.get(opts, :refresh_human_actions, &HumanActions.refresh/0).()
          result

        {:ok, %{"reason" => "already_open"}} = result ->
          CommentRegistry.release_human_action(registry)
          CommentRegistry.record_human_action_request(registry)
          result

        other ->
          CommentRegistry.release_human_action(registry)
          other
      end
    end
  end

  defp validate_human_action(attrs) do
    %{"title" => title, "why" => why, "steps" => steps, "unblocks" => unblocks, "est_minutes" => est_minutes} =
      Map.merge(%{"title" => nil, "why" => nil, "steps" => nil, "unblocks" => nil, "est_minutes" => nil}, attrs)

    case Enum.find(human_action_checks(title, why, steps, unblocks, est_minutes), fn {valid?, _message} -> not valid? end) do
      {false, message} ->
        {:error, {:invalid_human_action, message}}

      nil ->
        unblocks = if non_blank?(unblocks), do: unblocks
        {:ok, %{title: Request.one_line(title), why: why, steps: steps, unblocks: unblocks, est_minutes: est_minutes}}
    end
  end

  # In order: a later check may rely on an earlier one having passed.
  defp human_action_checks(title, why, steps, unblocks, est_minutes) do
    [
      {non_blank?(title), "`title` must be a non-blank string."},
      {non_blank?(title) and String.length(Request.one_line(title)) <= @title_max_length, "`title` must be at most #{@title_max_length} characters."},
      {non_blank?(why), "`why` must be a non-blank string."},
      {valid_steps?(steps), "`steps` must list 1 to #{@human_action_max_steps} non-blank strings."},
      {is_nil(unblocks) or is_binary(unblocks), "`unblocks` must be a string."},
      {is_nil(est_minutes) or est_minutes in 1..@human_action_max_minutes, "`est_minutes` must be an integer from 1 to #{@human_action_max_minutes}."}
    ]
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_steps?(steps), do: is_list(steps) and length(steps) in 1..@human_action_max_steps and Enum.all?(steps, &non_blank?/1)

  defp reject_human_action_secrets(request, context, opts) do
    fields = [title: request.title, why: request.why, unblocks: request.unblocks, steps: Enum.join(request.steps, "\n")]
    SecretScanner.reject_fields_if_secret_pattern(fields, context, "linear_request_human_action", opts)
  end

  defp human_actions_settings(context, opts) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings_for_repo!(issue_repo_key(context)) end)

    if settings.human_actions.enabled,
      do: {:ok, settings},
      else: {:error, :human_actions_disabled}
  end

  defp issue_repo_key(%{issue: %{repo_key: repo_key}}), do: repo_key
  defp issue_repo_key(_context), do: nil

  defp post_human_action(issue_id, request, settings, opts) do
    label = settings.human_actions.label

    with {:ok, body} <- graphql(@human_action_scope_query, %{id: issue_id, label: label}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      labelled? = Enum.any?(get_in(issue, ["labels", "nodes"]) || [], &(String.downcase(to_string(&1["name"])) == String.downcase(label)))

      case duplicate_request(issue, request, labelled?, settings) do
        {comment_id, _request} -> {:ok, %{"requested" => false, "reason" => "already_open", "commentId" => comment_id, "label" => label}}
        nil -> create_human_action(issue, body, request, label, labelled?, opts)
      end
    end
  end

  # Without the label, an earlier request is closed (a person removed the label), so a new one is
  # posted.
  defp duplicate_request(_issue, _request, false, _settings), do: nil

  defp duplicate_request(issue, request, true, settings) do
    title = Request.normalize_title(request.title)
    Enum.find(HumanActionsCollector.open_requests(issue, settings), fn {_comment_id, open} -> Request.normalize_title(open.title) == title end)
  end

  defp create_human_action(issue, body, request, label, labelled?, opts) do
    with :ok <- ensure_human_action_label(issue, body, label, labelled?, opts),
         {:ok, response} <- graphql(@add_comment_mutation, %{issueId: issue["id"], body: Request.render(request, label)}, opts),
         {:ok, response} <- check_mutation_success(response, "commentCreate") do
      comment = get_in(response, ["data", "commentCreate", "comment"]) || %{}
      {:ok, %{"requested" => true, "commentId" => comment["id"], "url" => comment["url"], "label" => label}}
    end
  end

  defp ensure_human_action_label(_issue, _body, _label, true, _opts), do: :ok

  defp ensure_human_action_label(issue, body, label, false, opts) do
    team_id = get_in(issue, ["team", "id"])
    labels = get_in(body, ["data", "issueLabels", "nodes"]) || []
    existing = Enum.find(labels, &(get_in(&1, ["team", "id"]) == team_id)) || Enum.find(labels, &is_nil(&1["team"]))

    with {:ok, label_id} <- human_action_label_id(existing, label, team_id, opts),
         {:ok, response} <- graphql(@add_label_mutation, %{issueId: issue["id"], labelId: label_id}, opts),
         {:ok, _response} <- check_mutation_success(response, "issueAddLabel") do
      :ok
    end
  end

  defp human_action_label_id(%{"id" => label_id}, _label, _team_id, _opts), do: {:ok, label_id}

  defp human_action_label_id(nil, label, team_id, opts) do
    with {:ok, response} <- graphql(@create_label_mutation, %{input: %{"name" => label, "teamId" => team_id}}, opts),
         {:ok, response} <- check_mutation_success(response, "issueLabelCreate") do
      fetch_path(response, ["data", "issueLabelCreate", "issueLabel", "id"], :label_not_created)
    end
  end

  @doc """
  Withdraws open human-action requests on the current issue that are no longer needed: replies
  `## Action withdrawn` with `reason` under each one (or only under the one titled `title`), and
  removes the `human_actions.label` label once no open request is left, so the next human-action
  update drops them and the run's next move to `Backlog` or `In Review` no longer goes to Human
  Review. An issue with no open request is left as it is. The reason is refused when it holds a
  secret pattern.
  """
  @spec withdraw_human_action(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def withdraw_human_action(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, reason, title} <- validate_withdrawal(attrs),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([reason: reason], context, "linear_withdraw_human_action", opts),
         {:ok, settings} <- human_actions_settings(context, opts) do
      case post_withdrawal(issue_id, reason, title, settings, opts) do
        {:ok, %{"withdrawn" => true} = withdrawal} = result ->
          forget_human_action_request(context, withdrawal)
          Keyword.get(opts, :refresh_human_actions, &HumanActions.refresh/0).()
          result

        other ->
          other
      end
    end
  end

  # With no open request left on the issue, the run's issue no longer waits on a person.
  defp forget_human_action_request(context, %{"labelRemoved" => true}),
    do: CommentRegistry.clear_human_action_request(Map.get(context, :comment_registry))

  defp forget_human_action_request(_context, _withdrawal), do: :ok

  defp validate_withdrawal(attrs) do
    reason = Map.get(attrs, "reason")
    title = Map.get(attrs, "title")

    cond do
      not non_blank?(reason) -> {:error, {:invalid_human_action_withdrawal, "`reason` must be a non-blank string."}}
      not (is_nil(title) or non_blank?(title)) -> {:error, {:invalid_human_action_withdrawal, "`title` must be a non-blank string when given."}}
      true -> {:ok, reason, title}
    end
  end

  defp post_withdrawal(issue_id, reason, title, settings, opts) do
    label = settings.human_actions.label

    with {:ok, body} <- graphql(@human_action_scope_query, %{id: issue_id, label: label}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      issue_label = Enum.find(get_in(issue, ["labels", "nodes"]) || [], &(String.downcase(to_string(&1["name"])) == String.downcase(label)))
      open = if issue_label, do: HumanActionsCollector.open_requests(issue, settings), else: []
      {withdrawing, remaining} = Enum.split_with(open, &withdrawing?(&1, title))

      if withdrawing == [] do
        {:ok, %{"withdrawn" => false, "reason" => "no_open_request", "label" => label}}
      else
        withdraw_requests(issue["id"], issue_label, withdrawing, remaining, reason, label, opts)
      end
    end
  end

  defp withdrawing?(_request, nil), do: true
  defp withdrawing?({_comment_id, request}, title), do: Request.normalize_title(request.title) == Request.normalize_title(title)

  # Replies first: a withdrawn request stays out of the update even if removing the label fails.
  defp withdraw_requests(issue_id, issue_label, withdrawing, remaining, reason, label, opts) do
    with {:ok, reply_ids} <- reply_withdrawals(issue_id, withdrawing, reason, opts),
         {:ok, label_removed?} <- remove_human_action_label(issue_id, issue_label, remaining, opts) do
      {:ok,
       %{
         "withdrawn" => true,
         "requestCommentIds" => Enum.map(withdrawing, fn {comment_id, _request} -> comment_id end),
         "replyCommentIds" => reply_ids,
         "labelRemoved" => label_removed?,
         "label" => label
       }}
    end
  end

  defp reply_withdrawals(issue_id, withdrawing, reason, opts) do
    Enum.reduce_while(withdrawing, {:ok, []}, fn {comment_id, _request}, {:ok, ids} ->
      variables = %{issueId: issue_id, parentId: comment_id, body: Request.render_withdrawal(reason)}

      with {:ok, response} <- graphql(@add_reply_mutation, variables, opts),
           {:ok, response} <- check_mutation_success(response, "commentCreate") do
        {:cont, {:ok, ids ++ [get_in(response, ["data", "commentCreate", "comment", "id"])]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Another open request on the issue still needs the label.
  defp remove_human_action_label(_issue_id, _issue_label, [_open | _rest], _opts), do: {:ok, false}

  defp remove_human_action_label(issue_id, %{"id" => label_id}, [], opts) do
    with {:ok, response} <- graphql(@remove_label_mutation, %{issueId: issue_id, labelId: label_id}, opts),
         {:ok, _response} <- check_mutation_success(response, "issueRemoveLabel") do
      {:ok, true}
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

  @doc """
  Creates a Linear document in the current issue's project, titled `<identifier> · <title>`, and
  attaches its URL to the current issue with the document id in the attachment's metadata, so
  later runs on the issue may read and edit it. An issue outside a project is refused. Title and
  content are refused when they hold a secret pattern. At most #{@document_cap_per_run} per run.
  """
  @spec create_document(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_document(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, title} <- document_title_field(Map.get(attrs, "title")),
         {:ok, content} <- document_content_field(Map.get(attrs, "content")),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([title: title, content: content], context, "linear_create_document", opts),
         {:ok, scope} <- document_scope(issue_id, opts),
         {:ok, project_id} <- fetch_path(scope, ["project", "id"], :document_issue_has_no_project),
         :ok <- CommentRegistry.reserve_document(registry, @document_cap_per_run) do
      input = %{"projectId" => project_id, "title" => document_title(scope, title), "content" => content}

      case create_project_document(input, opts) do
        {:ok, document} ->
          CommentRegistry.record_document(registry, document["id"])
          attach_document(issue_id, document, opts)

        {:error, _reason} = error ->
          CommentRegistry.release_document(registry)
          error
      end
    end
  end

  @doc """
  Replaces the content, and the title when given, of a document the current issue's runs created:
  one this run created, or one an attachment on the issue marks as created for it. Any other
  document is refused before anything is written, as are content copied from a cut read and
  fields holding a secret pattern. The title keeps the `<identifier> · ` prefix.
  """
  @spec update_document(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_document(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, document_id} <- document_id_field(Map.get(attrs, "document_id")),
         {:ok, title} <- optional_document_title(Map.get(attrs, "title")),
         {:ok, content} <- document_content_field(Map.get(attrs, "content")),
         :ok <- reject_truncated_document(content),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([title: title, content: content], context, "linear_update_document", opts),
         {:ok, scope} <- document_scope(issue_id, opts),
         :ok <- verify_document_owner(scope, context, document_id),
         input = document_update_input(scope, title, content),
         {:ok, response} <- graphql(@update_document_mutation, %{id: document_id, input: input}, opts),
         {:ok, response} <- check_mutation_success(response, "documentUpdate") do
      document = get_in(response, ["data", "documentUpdate", "document"]) || %{}
      {:ok, %{"document" => Map.merge(%{"id" => document_id}, document_summary(document)), "contentLength" => String.length(content)}}
    end
  end

  @doc """
  Without a `document_id`, lists the documents the current issue's runs created (id, title, url).
  With one, reads that document, its content secret-redacted and wrapped as untrusted text. Any
  other document is refused before it is read.
  """
  @spec get_document(context(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def get_document(context, document_id, opts \\ []) do
    if is_nil(document_id),
      do: list_issue_documents(context, opts),
      else: read_issue_document(context, document_id, opts)
  end

  defp list_issue_documents(context, opts) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, scope} <- document_scope(issue_id, opts),
         {:ok, documents} <- list_documents(owned_document_ids(scope, context), opts) do
      {:ok, %{"documents" => Enum.map(documents, fn document -> wrap_string_field(document, "title", &PromptSafety.linear_document_title/1) end)}}
    end
  end

  defp read_issue_document(context, document_id, opts) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, document_id} <- document_id_field(document_id),
         {:ok, scope} <- document_scope(issue_id, opts),
         :ok <- verify_document_owner(scope, context, document_id),
         {:ok, body} <- signed_graphql(@document_query, %{id: document_id}, opts),
         {:ok, document} <- fetch_path(body, ["data", "document"], :document_not_found) do
      {:ok, wrap_document(document, context, opts)}
    end
  end

  defp document_scope(issue_id, opts) do
    with {:ok, body} <- graphql(@document_scope_query, %{id: issue_id, first: @document_attachment_first}, opts) do
      fetch_path(body, ["data", "issue"], :issue_not_found)
    end
  end

  defp document_title_field(title) do
    if non_blank?(title) and String.length(String.trim(title)) <= @title_max_length,
      do: {:ok, String.trim(title)},
      else: {:error, :invalid_document_title}
  end

  defp optional_document_title(nil), do: {:ok, nil}
  defp optional_document_title(title), do: document_title_field(title)

  defp document_content_field(content), do: if(non_blank?(content), do: {:ok, content}, else: {:error, :invalid_document_content})

  defp document_id_field(document_id),
    do: if(non_blank?(document_id), do: {:ok, String.trim(document_id)}, else: {:error, :invalid_document_id})

  # Content copied from a cut read would replace the stored document with its truncated text.
  defp reject_truncated_document(content) do
    if PromptSafety.truncated?(content), do: {:error, :truncated_document_content}, else: :ok
  end

  # A title that already carries the prefix keeps a single one.
  defp document_title(%{"identifier" => identifier}, title) do
    prefix = identifier <> @document_title_separator
    if String.starts_with?(title, prefix), do: title, else: prefix <> title
  end

  defp document_update_input(_scope, nil, content), do: %{"content" => content}
  defp document_update_input(scope, title, content), do: %{"title" => document_title(scope, title), "content" => content}

  defp create_project_document(input, opts) do
    with {:ok, response} <- graphql(@create_document_mutation, %{input: input}, opts),
         {:ok, response} <- check_mutation_success(response, "documentCreate") do
      case get_in(response, ["data", "documentCreate", "document"]) do
        %{"id" => id} = document when is_binary(id) -> {:ok, document}
        _ -> {:error, :document_not_returned}
      end
    end
  end

  # The document exists by then, so its slot stays used and this run may still edit it.
  defp attach_document(issue_id, document, opts) do
    input = %{
      "issueId" => issue_id,
      "url" => document["url"],
      "title" => document["title"],
      "metadata" => %{@document_metadata_key => document["id"]}
    }

    with {:ok, response} <- graphql(@attach_document_mutation, %{input: input}, opts),
         {:ok, _response} <- check_mutation_success(response, "attachmentCreate") do
      {:ok, %{"document" => document_summary(document), "attached" => true}}
    else
      {:error, reason} -> {:error, {:document_attach_failed, document_summary(document), reason}}
    end
  end

  defp document_summary(document), do: Map.take(document, ["id", "title", "url"])

  defp verify_document_owner(scope, context, document_id) do
    if document_id in owned_document_ids(scope, context),
      do: :ok,
      else: {:error, {:document_not_owned_by_issue, document_id}}
  end

  # The documents this run created, plus the ones the issue's attachments mark as created for it.
  defp owned_document_ids(scope, context) do
    attached =
      for %{"metadata" => %{@document_metadata_key => document_id}} <- get_in(scope, ["attachments", "nodes"]) || [],
          is_binary(document_id),
          do: document_id

    Enum.uniq(attached ++ CommentRegistry.document_ids(Map.get(context, :comment_registry)))
  end

  defp list_documents([], _opts), do: {:ok, []}

  defp list_documents(document_ids, opts) do
    with {:ok, body} <- graphql(@documents_query, %{ids: document_ids, first: length(document_ids)}, opts) do
      fetch_path(body, ["data", "documents", "nodes"], [])
    end
  end

  defp wrap_document(document, context, opts) do
    document
    |> redact_string_field("content", context, "linear_get_document", opts)
    |> wrap_string_field("content", &PromptSafety.linear_document_content/1)
    |> wrap_string_field("title", &PromptSafety.linear_document_title/1)
  end

  defp validate_subissue_fields(attrs) do
    title = Map.get(attrs, "title")
    description = Map.get(attrs, "description")
    priority = Map.get(attrs, "priority")
    blocked_by = Map.get(attrs, "blocked_by") || []

    cond do
      not is_binary(title) or String.trim(title) == "" -> {:error, :invalid_subissue_title}
      not is_binary(description) -> {:error, :invalid_subissue_description}
      not (is_nil(priority) or priority in 0..4) -> {:error, :invalid_subissue_priority}
      not valid_blocked_by?(blocked_by) -> {:error, :invalid_subissue_blocked_by}
      true -> {:ok, String.trim(title), description, priority, normalize_identifiers(blocked_by)}
    end
  end

  defp valid_blocked_by?(blocked_by) do
    is_list(blocked_by) and Enum.all?(blocked_by, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp normalize_identifiers(identifiers) do
    identifiers |> Enum.map(&(&1 |> String.trim() |> String.upcase())) |> Enum.uniq()
  end

  defp create_backlog_child(issue_id, {title, description, priority, blocked_by}, registry, opts) do
    with {:ok, body} <- graphql(@subissue_scope_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, parent} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, states} <- fetch_path(parent, ["team", "states", "nodes"], []),
         {:ok, state_id} <- backlog_state_id(states),
         {:ok, blockers} <- resolve_blockers(blocked_by, parent, registry),
         input = subissue_input(parent, state_id, title, description, priority),
         {:ok, response} <- graphql(@create_subissue_mutation, %{input: input}, opts),
         {:ok, response} <- check_mutation_success(response, "issueCreate"),
         {:ok, identifier, new_id} <- created_subissue(response) do
      CommentRegistry.record_subissue(registry, identifier, new_id)
      link_blockers(response, {identifier, new_id}, blockers, opts)
    end
  end

  defp created_subissue(response) do
    case get_in(response, ["data", "issueCreate", "issue"]) do
      %{"id" => id, "identifier" => identifier} when is_binary(id) and is_binary(identifier) -> {:ok, identifier, id}
      _ -> {:error, :subissue_not_returned}
    end
  end

  # Only siblings may block the new sub-issue: the parent's children, plus the ones this run created
  # in case Linear has not listed them yet.
  defp resolve_blockers([], _parent, _registry), do: {:ok, []}

  defp resolve_blockers(identifiers, parent, registry) do
    siblings =
      parent
      |> get_in(["children", "nodes"])
      |> List.wrap()
      |> Map.new(&{&1["identifier"], &1["id"]})
      |> Map.merge(CommentRegistry.created_subissues(registry))

    case Enum.reject(identifiers, &Map.has_key?(siblings, &1)) do
      [] -> {:ok, Enum.map(identifiers, &{&1, Map.fetch!(siblings, &1)})}
      unknown -> {:error, {:blocked_by_not_sibling, unknown, siblings |> Map.keys() |> Enum.sort()}}
    end
  end

  defp link_blockers(response, {identifier, new_id}, blockers, opts) do
    linked =
      Enum.reduce_while(blockers, :ok, fn {blocker, blocker_id}, :ok ->
        input = %{"issueId" => blocker_id, "relatedIssueId" => new_id, "type" => "blocks"}

        with {:ok, body} <- graphql(@create_issue_relation_mutation, %{input: input}, opts),
             {:ok, _body} <- check_mutation_success(body, "issueRelationCreate") do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:blocked_by_relation_failed, identifier, blocker, reason}}}
        end
      end)

    with :ok <- linked do
      {:ok, put_in(response, ["data", "issueCreate", "issue", "blockedBy"], Enum.map(blockers, &elem(&1, 0)))}
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

  defp resolve_state_id(issue_id, state_name_or_id, human_action_requested?, opts) do
    normalized = String.trim(state_name_or_id)

    if normalized == "" do
      {:error, :invalid_state}
    else
      settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

      with {:ok, state, issue, states} <- lookup_team_state(issue_id, normalized, opts),
           :ok <- refuse_auto_review_handoff_state(state, pr_less_issue?(issue), settings),
           state = human_review_redirect(state, issue, states, human_action_requested?, settings),
           {:ok, state_id} <- refuse_human_only_state(state) do
        refuse_waiting_on_sub_issues_state(state, state_id, settings)
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
          {:ok, state, get_in(body, ["data", "issue"]), states}

        _ ->
          available = states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
          {:error, {:state_not_found, available}}
      end
    end
  end

  # An issue only a person can move on goes to the Human Review state instead of `In Review`, apart
  # from the supervisor's queue: a `breakdown` plan whose ticket says a person reviews it, and the
  # issue of a run that asked a person for something (which also goes there instead of `Backlog`).
  defp human_review_redirect(state, issue, states, human_action_requested?, settings) do
    with true <- HumanReview.enabled?(settings),
         true <- needs_person?(state, issue, human_action_requested?, settings),
         %{"id" => _} = human_review <- Enum.find(states, &state_name_matches?(&1, HumanReview.state(settings))) do
      human_review
    else
      _keep -> state
    end
  end

  defp needs_person?(state, issue, human_action_requested?, settings) do
    cond do
      state_name_matches?(state, @backlog_state) ->
        human_action_requested?

      state_name_matches?(state, AutoReview.review_state()) ->
        human_action_requested? or human_reviewed_plan?(issue, settings)

      true ->
        false
    end
  end

  defp human_reviewed_plan?(issue, settings) do
    labels = issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(&label_name/1) |> Enum.filter(&is_binary/1)
    plan = %Issue{title: issue["title"], description: issue["description"], labels: labels}
    Issue.breakdown?(plan) and HumanReview.requested_by_ticket?(plan, settings)
  end

  defp refuse_human_only_state(%{"id" => state_id} = state) do
    if state_name_matches?(state, @merging_state),
      do: {:error, {:merging_requires_human_approval, state["name"]}},
      else: {:ok, state_id}
  end

  # With Auto Review on, Symphony moves the issue on from the PR being open, so an
  # agent asking for `In Review` or the Human Review state is refused rather than silently
  # redirected. It runs before the Human Review redirect, so a run that asked a person for
  # something cannot skip QA that way: a blocked PR reaches Human Review through Auto Review.
  # A `breakdown` parent and a `Final verification:` ticket open no PR: their result goes to
  # a person whatever Auto Review says.
  defp refuse_auto_review_handoff_state(state, pr_less?, settings) do
    if AutoReview.enabled?(settings) and not pr_less? and
         (state_name_matches?(state, AutoReview.review_state()) or HumanReview.in_state?(state["name"], settings)),
       do: {:error, {:in_review_set_by_auto_review, state["name"], AutoReview.state(settings)}},
       else: :ok
  end

  # Moving a `breakdown` parent from `In Review` to the waiting state approves its plan and
  # promotes its sub-tickets, so only a human does it.
  defp refuse_waiting_on_sub_issues_state(state, state_id, settings) do
    case SubIssueWait.state(settings) do
      waiting_state when is_binary(waiting_state) ->
        if state_name_matches?(state, waiting_state),
          do: {:error, {:waiting_on_sub_issues_state_requires_human_approval, state["name"]}},
          else: {:ok, state_id}

      nil ->
        {:ok, state_id}
    end
  end

  defp pr_less_issue?(issue) do
    labels = issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(&label_name/1)
    Enum.any?(labels, &Issue.breakdown_label?/1) or RunKind.classify(%Issue{title: issue["title"]}) == :final_verification
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
          [Map.merge(%{"relation" => direction, "type" => type}, family_summary(issue))]

        _ ->
          []
      end
    else
      []
    end
  end

  defp related_issue_from_relation(_relation, _direction), do: []

  # The parent, the parent's other children, and the current issue's own children.
  defp family_issues(issue) do
    parent = Map.get(issue, "parent")
    siblings = Enum.reject(child_nodes(parent), &(&1["id"] == issue["id"]))

    Enum.map(List.wrap(parent), &family_entry(&1, "parent")) ++
      Enum.map(siblings, &family_entry(&1, "sibling")) ++
      Enum.map(child_nodes(issue), &family_entry(&1, "sub_issue"))
  end

  defp child_nodes(%{"children" => %{"nodes" => nodes}}) when is_list(nodes), do: nodes
  defp child_nodes(_issue), do: []

  defp family_entry(issue, relation), do: Map.put(family_summary(issue), "relation", relation)

  defp family_summary(issue) do
    %{
      "id" => issue["id"],
      "identifier" => issue["identifier"],
      "title" => issue["title"],
      "state" => get_in(issue, ["state", "name"])
    }
  end

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
    |> wrap_string_field("body", &wrap_comment_body/1)
  end

  defp wrap_comment(comment), do: comment

  defp wrap_comment(comment, context, tool, opts) when is_map(comment) do
    comment
    |> redact_string_field("body", context, tool, opts)
    |> wrap_string_field("body", &wrap_comment_body/1)
  end

  defp wrap_comment(comment, _context, _tool, _opts), do: comment

  # The workpad is detected the way `Workpad` finds it, and read back whole so the agent's
  # rewrite does not drop the text past the ordinary comment limit.
  defp wrap_comment_body(body) do
    if Enum.any?(AgentLabels.known_workpad_markers(), &String.contains?(body, &1)),
      do: PromptSafety.linear_workpad_comment_body(body),
      else: PromptSafety.linear_issue_comment_body(body)
  end

  # A body copied from a cut read would replace the stored comment with its truncated text.
  defp reject_truncated_body(body) do
    if PromptSafety.truncated?(body), do: {:error, :truncated_comment_body}, else: :ok
  end

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

  # Reads whose descriptions and comments reach the agent get pre-signed upload URLs, so the
  # agent can download attached images and files without Linear's key. Each read signs afresh.
  defp signed_graphql(query, variables, opts), do: graphql(query, variables, opts, sign_file_urls: true)

  defp graphql(query, variables, opts, client_opts \\ []) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, body} <- linear_client.(query, variables, client_opts) do
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
