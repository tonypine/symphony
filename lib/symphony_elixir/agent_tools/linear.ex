defmodule SymphonyElixir.AgentTools.Linear do
  @moduledoc """
  Narrow Linear operations exposed to agent prompts.

  The current issue id is supplied by Symphony session context. Callers cannot
  pass an issue id through tool arguments.
  """

  require Logger

  alias SymphonyElixir.AgentLabels
  alias SymphonyElixir.AgentSandboxConfig
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.CiFix
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Workspace.Attachments
  alias SymphonyElixir.DecisionRequest
  alias SymphonyElixir.Decisions
  alias SymphonyElixir.Hold
  alias SymphonyElixir.HumanActions
  alias SymphonyElixir.HumanActions.Collector, as: HumanActionsCollector
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.IssueSummary
  alias SymphonyElixir.Linear.{Client, Issue, TransientRetry}
  alias SymphonyElixir.NeedsDecisionHold
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.PathUnlock
  alias SymphonyElixir.Pauses.Projector
  alias SymphonyElixir.PromptSafety
  alias SymphonyElixir.Questions
  alias SymphonyElixir.SensitivePath
  alias SymphonyElixir.TicketSignals
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TransitionGuard
  alias SymphonyElixir.Walkthrough

  # Who asks and withdraws an agent's requests (`SymphonyElixir.Questions`).
  @asking_run %{kind: :run, name: "The run"}
  @comment_limit_default 50
  @comment_limit_max 100
  @title_max_length 120
  @related_issue_first 50
  @public_file_upload_max_bytes 5 * 1024 * 1024
  @private_file_upload_max_bytes 50 * 1024 * 1024
  @default_attachment_allowed_hosts ["github.com"]
  # Moving an issue to `Merging` is how a human approves a merge, so agents may not do it.
  # Sub-issues land in Backlog so an agent cannot start other agents; a human promotes them.
  @backlog_state "Backlog"
  # Where a withdrawn request's issue goes back to when its history doesn't say.
  @subissue_update_fields [{"title", :title}, {"description", :description}, {"blocked_by", :blocked_by}, {"cancel_reason", :cancel_reason}]
  # A project update notifies everyone following the project, so a run may post only one.
  @project_update_cap_per_run 1
  @project_update_healths ["onTrack", "atRisk", "offTrack"]
  # Requests for a human are deduplicated by title, so this only bounds a run that loops.
  @human_action_cap_per_run 5
  @human_action_max_tradeoffs 3
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
      attachments(first: 50) {
        nodes {
          url
        }
      }
      state {
        name
        type
      }
      inverseRelations(first: 50) {
        nodes {
          type
          issue {
            identifier
            state {
              name
            }
          }
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

  @comment_body_query """
  query SymphonyAgentCommentBody($id: String!) {
    comment(id: $id) {
      body
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
      priority
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
  query SymphonyAgentHumanActionScope($id: String!) {
    issue(id: $id) {
      id
      description
      state { name }
      team { states { nodes { id name } } }
      labels { nodes { id name } }
      comments(last: 50, orderBy: createdAt) {
        nodes { id body createdAt parent { id } }
      }
      history(first: 50) {
        nodes { createdAt fromState { name } toState { name } }
      }
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

  # A QA pass reads the parent's documents too (its Screens document sits on the parent).
  @readable_document_scope_query """
  query SymphonyAgentReadableDocumentScope($id: String!, $first: Int!) {
    issue(id: $id) {
      id
      identifier
      attachments(first: $first) {
        nodes { metadata }
      }
      parent {
        identifier
        attachments(first: $first) {
          nodes { metadata }
        }
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

  @issue_description_query """
  query SymphonyAgentIssueDescription($id: String!) {
    issue(id: $id) {
      id
      description
    }
  }
  """

  @update_issue_description_mutation """
  mutation SymphonyAgentUpdateIssueDescription($id: String!, $description: String!) {
    issueUpdate(id: $id, input: { description: $description }) {
      success
      issue { id url }
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
         result <- resolve_state_id(context, issue_id, state_name_or_id, opts) do
      case result do
        {:ok, {:state, state_id}, move} -> apply_state(context, issue_id, state_id, move, opts)
        {:hold, kind, attrs} -> apply_hold(context, issue_id, kind, attrs, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  def update_state(_context, _state_name_or_id, _opts), do: {:error, :invalid_state}

  # The record is written first, as `TransitionGuard.perform/4` does: the agent's move is Symphony's
  # own, so the ticket's record takes the target as its phase (`TicketSignals.record_phase/3`) before
  # Linear is asked, and a later read of Linear finds no drift to move back
  # (`SymphonyElixir.TicketObservation`). A move Linear doesn't make puts the record's phase back: the
  # agent gets the error and the ticket stays where it was.
  defp apply_state(context, issue_id, state_id, move, opts) do
    repo_key = issue_repo_key(context)
    before = TicketSignals.recorded_phase(repo_key, issue_id)
    :ok = TicketSignals.record_phase(repo_key, issue_id, move.to)

    with {:ok, response} <- graphql(@update_issue_state_mutation, %{id: issue_id, stateId: state_id}, opts),
         {:ok, result} <- check_mutation_success(response, "issueUpdate") do
      record_fix_verdict(context, issue_id, move)
      {:ok, result}
    else
      error ->
        :ok = TicketSignals.restore_phase(repo_key, issue_id, before)
        error
    end
  end

  # A CI Fix ticket the fixing agent sends to Rework is the lane's substantive verdict: the repair
  # needs a real change, so the ticket re-enters review instead of returning to its origin
  # (`SymphonyElixir.CiFix`). The move itself is this tool's ordinary validated state request; only
  # the verdict is recorded, and best-effort, like every other ledger write.
  defp record_fix_verdict(context, issue_id, %{fix_verdict: verdict} = move) when is_binary(verdict) do
    CiFix.record_verdict(issue_repo_key(context), issue_id, verdict, %{to: move.to})
  end

  defp record_fix_verdict(_context, _issue_id, _move), do: :ok

  # The Backlog escape hatch is retired: the guard paused the ticket instead of moving it
  # (`SymphonyElixir.TransitionGuard`), so it keeps its phase and gains the `Blocked` label with the
  # reason recorded. A run that marked the issue blocked by open tickets waits on them, and the pause
  # lifts on its own once they are terminal; otherwise a person lifts it with `Unblock`. The agent did
  # not move the issue.
  defp apply_hold(_context, _issue_id, :blocked, attrs, _opts) do
    {:ok,
     %{
       "held" => true,
       "hold" => "Blocked",
       "reason" => Map.get(attrs, :reason),
       "clearing_condition" => Map.get(attrs, :clearing_condition),
       "message" =>
         "The issue stays in its current state with the `Blocked` label. " <>
           "Symphony lifts the pause when what it waits on clears, and a person lifts it " <>
           "with Unblock; do not move the issue yourself."
     }}
  end

  @spec add_comment(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body), do: add_comment(context, body, [])

  @spec add_comment(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body, opts) when is_binary(body) do
    with {:ok, issue_id} <- current_issue_id(context),
         :ok <- reject_ruling(body),
         {:ok, mutation, variables} <- comment_create(issue_id, body, Keyword.get(opts, :parent_id)),
         :ok <- reject_unlock_answer(variables, opts),
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

  # A reply under a decision request is the person's answer, and the agent posts as that person: a
  # reply under a request whose options unlock protected paths would grant them (`PathUnlock`).
  defp reject_unlock_answer(%{parentId: parent_id}, opts) do
    with {:ok, response} <- graphql(@comment_body_query, %{id: parent_id}, opts) do
      if unlocking_request?(get_in(response, ["data", "comment", "body"])), do: {:error, :path_unlock_answer}, else: :ok
    end
  end

  defp reject_unlock_answer(_variables, _opts), do: :ok

  defp unlocking_request?(body) do
    case Request.parse(body) do
      %{unlocks: unlocks} -> Enum.any?(unlocks, &(&1 != []))
      nil -> false
    end
  end

  @spec update_comment(context(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body), do: update_comment(context, comment_id, body, [])

  @spec update_comment(context(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body, opts) when is_binary(comment_id) and is_binary(body) do
    with :ok <- verify_comment_owner(context, comment_id),
         :ok <- reject_truncated_body(body),
         :ok <- reject_ruling(body),
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

  @doc """
  Uploads the workspace file at `local_path` to Linear and attaches it to the current issue. In a
  QA session (`opts[:qa_verdict_sink]`, the QA process), a successful upload also sends the sink
  `{:qa_upload, path, urls}`: the file's resolved path and its Linear URLs, the attachment's first,
  so the pass can point the evidence the agent cites at the file it keeps (`SymphonyElixir.QaAgent`).
  """
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
           ),
         {:ok, response} <- check_mutation_success(response, "attachmentCreate") do
      report_upload(Keyword.get(opts, :qa_verdict_sink), path, [get_in(response, ["data", "attachmentCreate", "attachment", "url"]), asset_url])
      {:ok, response}
    end
  end

  def attach_file(_context, _local_path, _title, _opts), do: {:error, :invalid_local_path}

  defp report_upload(sink, path, urls) when is_pid(sink) do
    send(sink, {:qa_upload, path, urls |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()})
  end

  defp report_upload(_sink, _path, _urls), do: :ok

  @doc """
  Creates a Backlog child of the current issue in the same team and project, assigned to the same
  assignee. Only `title`, `description`, `priority`, and `blocked_by` come from the caller;
  everything that scopes the new issue is read from the current issue. Without a `priority`, the
  child inherits the current issue's, so `tickets.priorities` dispatches it like its parent. A
  title this run already filed under the current issue is refused with the earlier sub-issue's
  identifier, so a looping run can't file the same sub-issue again and again.

  `blocked_by` lists identifiers of sibling sub-issues (the current issue's existing children, or
  sub-issues this run created) that block the new one. Unknown identifiers are refused before
  anything is created; the `blocks` relations are created right after the issue.
  """
  @spec create_subissue(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_subissue(context, attrs, opts \\ []) when is_map(attrs) do
    create_child(context, attrs, @backlog_state, opts)
  end

  @doc """
  Creates a child of the current issue in the state named `state_name`, scoped exactly like
  `create_subissue/3`'s Backlog child (same team, project, assignee and parent, and the parent's
  priority unless `attrs` names one) and with the same validation, secret scan and per-run title
  deduplication.

  This is the machine-side filing path, for a flow that files a child an agent must not: an epic
  review files each gap it found as a follow-up in `Todo` (`SymphonyElixir.EpicReview`), because a
  `Backlog` child does not hold its parent and the epic would sit unnoticed until a person promoted
  it. Agents keep `linear_create_subissue` and its Backlog contract; no tool is registered for this
  function.
  """
  @spec create_subissue_in_state(context(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_subissue_in_state(context, state_name, attrs, opts \\ [])
      when is_binary(state_name) and is_map(attrs) do
    create_child(context, attrs, state_name, opts)
  end

  defp create_child(context, attrs, state_name, opts) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, title, description, priority, blocked_by} <- validate_subissue_fields(attrs),
         :ok <- reject_unlock_grant(description),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [title: title, description: description],
             context,
             "linear_create_subissue",
             opts
           ),
         :ok <- CommentRegistry.check_subissue_title(registry, issue_id, title) do
      create_child_issue(issue_id, {title, description, priority, blocked_by}, state_name, registry, opts)
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
         :ok <- reject_unlock_grant(Map.get(change, :description)),
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
      apply_subissue_change(parent, children, child, change, issue_repo_key(context), opts)
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

  defp apply_subissue_change(parent, _children, child, %{cancel_reason: reason}, repo_key, opts) do
    with {:ok, canceled} <- canceled_state(get_in(parent, ["team", "states", "nodes"]) || []),
         {:ok, response} <- graphql(@add_comment_mutation, %{issueId: child["id"], body: reason}, opts),
         {:ok, _response} <- check_mutation_success(response, "commentCreate"),
         ctx = %{target: canceled, repo_key: repo_key},
         :ok <- TransitionGuard.perform(child["id"], :breakdown_cancel, ctx, tracker: tracker(opts)) do
      {:ok, %{"identifier" => child["identifier"], "canceled" => true}}
    end
  end

  defp apply_subissue_change(_parent, children, child, change, _repo_key, opts) do
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

  # The name of the team's canceled state: the state `:breakdown_cancel` resolves to for a Backlog
  # sub-issue, found by name first and then by type.
  defp canceled_state(states) do
    state =
      Enum.find(states, &(state_name_matches?(&1, "Canceled") or state_name_matches?(&1, "Cancelled"))) ||
        Enum.find(states, &(&1["type"] == "canceled"))

    case state do
      %{"name" => name} -> {:ok, name}
      _ -> {:error, {:canceled_state_not_found, states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)}}
    end
  end

  @doc """
  Marks the current issue blocked by existing issues: each identifier in `blocked_by` gets a
  `blocks` relation to the current issue, so Symphony holds it in `Todo` until every blocker is
  terminal. Every identifier is looked
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
  Records that the current issue needs something only a human can do: posts an
  `## Decision needed:` comment (`SymphonyElixir.HumanActions.Request`), which Symphony lists in
  the project's human-action update, and leaves the issue in its phase with the `Needs Decision`
  hold set (`SymphonyElixir.NeedsDecisionHold`). It never adds a label itself. The request stays
  open until a person answers it, or the agent withdraws it. A request with the same title still
  open on the issue is not posted again, but the issue still gains the hold. A request whose title
  or question a person already answered (`SymphonyElixir.Decisions`) is not posted at all: the
  result carries the recorded answer, which the run applies. Every field is
  refused when it holds a secret pattern, and when it holds code the Director does not read
  (`SymphonyElixir.HumanActions.PlainWords`): the error names each token and its field. At most
  #{@human_action_cap_per_run} per run.
  """
  @spec request_human_action(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_human_action(context, attrs, opts \\ []) when is_map(attrs) do
    registry = Map.get(context, :comment_registry)

    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, request} <- validate_human_action(attrs),
         :ok <- reject_human_action_secrets(request, context, opts),
         {:ok, settings} <- human_actions_settings(context, opts),
         :ok <- CommentRegistry.reserve_human_action(registry, @human_action_cap_per_run) do
      case post_human_action(issue_id, issue_repo_key(context), request, settings, opts) do
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
    %{"title" => title, "why" => why, "decision" => decision, "unblocks" => unblocks, "if_unanswered" => if_unanswered} =
      Map.merge(%{"title" => nil, "why" => nil, "decision" => nil, "unblocks" => nil, "if_unanswered" => nil}, attrs)

    case Enum.find(human_action_checks(title, decision, unblocks, if_unanswered), fn {valid?, _message} -> not valid?.() end) do
      {_check, message} when is_function(message, 0) ->
        {:error, {:invalid_human_action, message.()}}

      {_check, message} ->
        {:error, {:invalid_human_action, message}}

      nil ->
        request = %{
          title: Request.one_line(title),
          why: if(is_binary(why), do: why, else: ""),
          question: decision["question"],
          options: Enum.map(decision["options"], &decision_option/1),
          recommendation_reason: present_text(decision["recommendation_reason"]),
          if_unanswered: present_text(if_unanswered),
          unblocks: present_text(unblocks)
        }

        case DecisionRequest.check(request) do
          :ok -> {:ok, describe_unlocks(request)}
          {:error, message} -> {:error, {:invalid_human_action, message}}
        end
    end
  end

  # The shape of the tool's input, in order and lazy: a later check relies on the earlier ones
  # having passed. What a request must say is the writer's standard (`DecisionRequest.check/1`).
  defp human_action_checks(title, decision, unblocks, if_unanswered) do
    options = DecisionRequest.option_count()

    [
      {fn -> non_blank?(title) end, "`title` must be a non-blank string."},
      {fn -> is_map(decision) end,
       "`decision` is required: one `question` and #{options.first} to #{options.last} `options`. " <>
         "A person only makes decisions; a check an agent can't run belongs to CI or a QA playbook, " <>
         "and a manual check that could be a test becomes a test."},
      {fn -> optional_string?(decision["question"]) end, "`decision.question` must be a string."},
      {fn -> is_list(decision["options"]) and length(decision["options"]) in options end,
       "`decision.options` must list #{options.first} to #{options.last} options, each with a `label` and an `effect`; " <>
         "with no real choice to make, there is nothing to ask a person."},
      {fn -> Enum.all?(decision["options"], &valid_decision_option?/1) end, "Each of `decision.options` needs a non-blank `label` and `effect`."},
      {fn -> Enum.all?(decision["options"], &valid_tradeoffs?(&1["tradeoffs"])) end,
       "Each option's `tradeoffs` lists at most #{DecisionRequest.max_tradeoffs()}, each with a `kind` (#{Enum.join(Request.tradeoff_kinds(), ", ")}) and a non-blank `text`."},
      {fn -> Enum.all?(decision["options"], &valid_unlocks?(&1["unlocks"])) end, "Each option's `unlocks` must be a list of protected paths, as strings."},
      {fn -> unprotected_unlocks(decision["options"]) == [] end,
       fn ->
         "`unlocks` names paths that are not protected: #{Enum.join(unprotected_unlocks(decision["options"]), ", ")}. " <>
           "It may only name the protected paths: #{Enum.join(AgentSandboxConfig.workspace_protected_paths(), ", ")}."
       end},
      {fn -> optional_string?(decision["recommendation_reason"]) end, "`decision.recommendation_reason` must be a string."},
      {fn -> optional_string?(unblocks) end, "`unblocks` must be a string."},
      {fn -> optional_string?(if_unanswered) end, "`if_unanswered` must be a string."}
    ]
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp present_text(value), do: if(non_blank?(value), do: value)

  defp valid_decision_option?(%{} = option), do: non_blank?(option["label"]) and non_blank?(option["effect"])
  defp valid_decision_option?(_option), do: false

  defp valid_tradeoffs?(nil), do: true

  defp valid_tradeoffs?(tradeoffs) when is_list(tradeoffs) and length(tradeoffs) <= @human_action_max_tradeoffs,
    do: Enum.all?(tradeoffs, &valid_tradeoff?/1)

  defp valid_tradeoffs?(_tradeoffs), do: false

  defp valid_tradeoff?(%{"kind" => kind, "text" => text}), do: kind in Request.tradeoff_kinds() and non_blank?(text)
  defp valid_tradeoff?(_tradeoff), do: false

  defp valid_unlocks?(nil), do: true
  defp valid_unlocks?(unlocks) when is_list(unlocks), do: Enum.all?(unlocks, &non_blank?/1)
  defp valid_unlocks?(_unlocks), do: false

  defp unprotected_unlocks(options), do: options |> Enum.flat_map(&List.wrap(&1["unlocks"])) |> PathUnlock.unprotected() |> Enum.uniq()

  defp decision_option(option) do
    %{
      label: option["label"],
      effect: option["effect"],
      recommended: option["recommended"] == true,
      tradeoffs: for(tradeoff <- List.wrap(option["tradeoffs"]), do: %{kind: tradeoff["kind"], text: tradeoff["text"]})
    }
    |> put_option_unlocks(PathUnlock.protected(option["unlocks"]))
  end

  defp put_option_unlocks(option, []), do: option
  defp put_option_unlocks(option, unlocks), do: Map.put(option, :unlocks, unlocks)

  # The Director never reads a path: the Why names what each unlocking option lets the ticket change
  # by its plain description (`PathUnlock.describe/1`).
  defp describe_unlocks(%{options: options, why: why} = request) do
    sentences =
      for %{unlocks: [_path | _more] = unlocks} = option <- options do
        "“#{Request.label(option)}” lets this ticket change #{PathUnlock.describe_all(unlocks)}."
      end

    %{request | why: Enum.join([String.trim(why) | sentences], " ")}
  end

  defp reject_human_action_secrets(request, context, opts) do
    options = Enum.map_join(request.options, "\n", fn option -> Enum.join(["#{option.label}: #{option.effect}" | Enum.map(option.tradeoffs, & &1.text)], "\n") end)

    fields = [
      title: request.title,
      why: request.why,
      unblocks: request.unblocks,
      if_unanswered: request.if_unanswered,
      question: request.question,
      recommendation_reason: request.recommendation_reason,
      options: options
    ]

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

  defp issue_identifier(%{issue: %{identifier: identifier}}) when is_binary(identifier), do: identifier
  defp issue_identifier(_context), do: nil

  @doc """
  The open human-action requests on the current issue (`SymphonyElixir.HumanActions.Request`),
  as `{comment_id, request}`: requests with no withdrawal reply that the issue hasn't moved on
  from since.
  """
  @spec open_human_action_requests(context(), Schema.t(), keyword()) ::
          {:ok, [{String.t(), Request.t()}]} | {:error, term()}
  def open_human_action_requests(context, settings, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@human_action_scope_query, %{id: issue_id}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      {:ok, HumanActionsCollector.open_requests(issue, settings)}
    end
  end

  defp post_human_action(issue_id, repo_key, request, settings, opts) do
    with {:ok, body} <- graphql(@human_action_scope_query, %{id: issue_id}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      case decided(issue, request) do
        nil -> hold_request(repo_key, issue, open_request_titled(issue, request.title, settings), request, settings, opts)
        decision -> {:ok, already_decided(decision)}
      end
    end
  end

  # A question a person already answered is not asked again: the description's Decisions section
  # (`SymphonyElixir.Decisions`). A reply under a request answers nothing.
  defp decided(issue, request) do
    Decisions.find(Decisions.recorded(issue["description"]), request.title, request.question)
  end

  defp already_decided(decision) do
    %{
      "requested" => false,
      "reason" => "already_decided",
      "decision" => %{"question" => decision.question, "answer" => decision.answer, "scope" => decision.scope},
      "message" =>
        "A person already decided this question. Apply the recorded answer and carry on: it is part of the ticket's scope. " <>
          "Ask again only with a different question that the answer does not settle."
    }
  end

  # Nothing moves. A new request goes through the one writer (`DecisionRequest.ask/4`), which sets
  # the hold and posts the comment through this tool's Linear client, so the ticket keeps its phase
  # and the person answers it there. A request the ticket already has is the one recorded, so the
  # hold is set again from it (`DecisionRequest.project/4`) and nothing is posted. A request raised
  # from the CI Fix lane is the lane's `cannot_fix` verdict: the repair needs access or a secret,
  # which no run can supply, so the ticket waits for a person in place.
  defp hold_request(repo_key, issue, open, request, settings, opts) do
    state = get_in(issue, ["state", "name"])

    with {:ok, result} <- ask_or_project(repo_key, issue, open, request, opts) do
      record_hold_verdict(repo_key, issue, state, settings)

      {:ok,
       result
       |> Map.put("state", state)
       |> Map.put("held", true)
       |> Map.put("hold", Hold.label(:needs_decision))}
    end
  end

  # Best-effort, like every other ledger write: a hold is set either way.
  defp record_hold_verdict(repo_key, issue, state, settings) do
    case CiFix.hold_verdict(state, settings) do
      nil -> :ok
      verdict -> CiFix.record_verdict(repo_key, issue["id"], verdict, %{})
    end
  end

  defp ask_or_project(repo_key, issue, {comment_id, open_request}, _request, opts) do
    with :ok <- DecisionRequest.project(repo_key, issue["id"], NeedsDecisionHold.attrs(open_request), opts) do
      {:ok, %{"requested" => false, "reason" => "already_open", "commentId" => comment_id}}
    end
  end

  defp ask_or_project(repo_key, issue, nil, request, opts) do
    held = %{id: issue["id"], state: get_in(issue, ["state", "name"]), repo_key: repo_key}

    # The request already passed `validate_human_action/1`, so the writer's error is the post's or
    # the hold's, returned as the tool returned it before.
    ask_opts = [post: &post_request(issue, &1, opts), label_tracker: opts[:tracker], asked_by: @asking_run] ++ Keyword.take(opts, [:store])

    # A question the hold already carries was asked before, its comment posted or waiting to be.
    # While the pause projector posts the comment, a question not open before is a new request.
    ticket = {:ticket, repo_key, issue["id"]}
    projected? = Projector.owns?() and is_binary(repo_key) and repo_key != "" and not Questions.same_open?(ticket, request)

    case DecisionRequest.ask(held, request, ask_opts) do
      {:ok, result} -> {:ok, result}
      :ok when projected? -> {:ok, projected_request(ticket, request)}
      :ok -> {:ok, %{"requested" => false, "reason" => "already_open"}}
      {:error, {_step, reason}} -> {:error, reason}
    end
  end

  # The request the pause projector posts from the Question: whether its comment is on Linear yet,
  # or waits for the reconciler to post it.
  defp projected_request(ticket, request) do
    case Questions.open_asking(ticket, request) do
      %{id: id} -> %{"requested" => true, "questionId" => id, "posted" => Projector.commented?(ticket, id)}
      nil -> %{"requested" => true}
    end
  end

  defp open_request_titled(issue, title, settings) do
    title = Request.normalize_title(title)
    Enum.find(HumanActionsCollector.open_requests(issue, settings), fn {_comment_id, open} -> Request.normalize_title(open.title) == title end)
  end

  # The comment the writer posts, rendered to say the ticket is not going anywhere.
  defp post_request(issue, body, opts) do
    with {:ok, response} <- graphql(@add_comment_mutation, %{issueId: issue["id"], body: body}, opts),
         {:ok, response} <- check_mutation_success(response, "commentCreate") do
      comment = get_in(response, ["data", "commentCreate", "comment"]) || %{}
      {:ok, %{"requested" => true, "commentId" => comment["id"], "url" => comment["url"]}}
    end
  end

  # The tracker `TransitionGuard.perform/4` writes through. Tests inject a spy; the run uses the
  # repo's configured tracker.
  defp tracker(opts), do: Keyword.get(opts, :tracker, Tracker)

  @doc """
  Withdraws open human-action requests on the current issue that are no longer needed: the open
  Questions they were asked as first (`SymphonyElixir.Questions.withdraw/4`, every one or only the
  one titled `title`), then a reply `## Action withdrawn` with `reason` under each request comment,
  so the next human-action update drops them. While the pause projector owns the replies
  (`SymphonyElixir.Pauses.Projector.owns?/0`), the reply under a withdrawn Question's request is its
  projection, posted when the withdrawal committed, and this tool replies only under the requests no
  Question carries. Once no open request is left, the `Needs Decision`
  hold is cleared so the ticket continues in place. An issue with no open request is left as it is.
  The reason is refused when it holds a secret pattern.
  """
  @spec withdraw_human_action(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def withdraw_human_action(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, reason, title} <- validate_withdrawal(attrs),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([reason: reason], context, "linear_withdraw_human_action", opts),
         {:ok, settings} <- human_actions_settings(context, opts) do
      ticket = {:ticket, issue_repo_key(context), issue_id}
      withdrawn = withdraw_questions(ticket, reason, title)

      post_withdrawal(issue_id, reason, title, settings, Keyword.put(opts, :projected, projected_titles(ticket, withdrawn)))
      |> with_questions(ticket, withdrawn)
      |> settle_withdrawal(context, issue_id, opts)
    end
  end

  # The Questions go first: they are the truth the requests on Linear project.
  defp withdraw_questions({:ticket, repo_key, _issue_id}, _reason, _title) when repo_key in [nil, ""], do: []

  defp withdraw_questions(ticket, reason, title) do
    for question <- Questions.open(ticket),
        is_nil(title) or Request.normalize_title(question.title) == Request.normalize_title(title),
        match?({:ok, _question}, Questions.withdraw(ticket, question.id, reason, by: @asking_run, cause: "superseded")),
        do: question.id
  end

  # The titles of the requests whose withdrawn Question the pause projector replies under, while it
  # owns the replies: the tool posts no reply under them.
  defp projected_titles(ticket, ids) do
    if Projector.owns?(),
      do: for(id <- ids, %{title: title} <- [Questions.find(ticket, id)], do: Request.normalize_title(title)),
      else: []
  end

  # A Question withdrawn with no request on Linear (its comment never posted) is a withdrawal too.
  defp with_questions({:ok, %{"withdrawn" => true} = withdrawal}, _ticket, ids), do: {:ok, Map.put(withdrawal, "questionIds", ids)}

  defp with_questions({:ok, %{"withdrawn" => false}}, ticket, [_ | _] = ids),
    do: {:ok, %{"withdrawn" => true, "questionIds" => ids, "requestCommentIds" => [], "replyCommentIds" => [], "remaining" => length(Questions.open(ticket))}}

  defp with_questions(result, _ticket, _ids), do: result

  # The withdrawal landed: the hold it releases goes first, so an issue that no longer waits on a
  # person is cleared before the human-action list is refreshed. Anything else `post_withdrawal`
  # returned passes through.
  defp settle_withdrawal({:ok, %{"withdrawn" => true} = withdrawal} = result, context, issue_id, opts) do
    with :ok <- release_decision_hold(context, issue_id, withdrawal, opts) do
      Keyword.get(opts, :refresh_human_actions, &HumanActions.refresh/0).()
      result
    end
  end

  defp settle_withdrawal(other, _context, _issue_id, _opts), do: other

  # A request moved nothing, so its `Needs Decision` hold is what the withdrawal clears: the store
  # first, then the label, and the ticket continues in place. Another request still open means the
  # ticket still waits, so the hold stays.
  defp release_decision_hold(_context, _issue_id, %{"remaining" => remaining}, _opts) when remaining != 0, do: :ok
  defp release_decision_hold(context, issue_id, _withdrawal, opts), do: Hold.clear(issue_repo_key(context), issue_id, :needs_decision, opts)

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
    with {:ok, body} <- graphql(@human_action_scope_query, %{id: issue_id}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      open = HumanActionsCollector.open_requests(issue, settings)
      {withdrawing, remaining} = Enum.split_with(open, &withdrawing?(&1, title))

      if withdrawing == [] do
        {:ok, %{"withdrawn" => false, "reason" => "no_open_request"}}
      else
        withdraw_requests(issue, withdrawing, remaining, reason, opts)
      end
    end
  end

  defp withdrawing?(_request, nil), do: true
  defp withdrawing?({_comment_id, request}, title), do: Request.normalize_title(request.title) == Request.normalize_title(title)

  defp withdraw_requests(issue, withdrawing, remaining, reason, opts) do
    with {:ok, reply_ids} <- reply_withdrawals(issue["id"], withdrawing, reason, opts) do
      {:ok,
       %{
         "withdrawn" => true,
         "requestCommentIds" => Enum.map(withdrawing, fn {comment_id, _request} -> comment_id end),
         "replyCommentIds" => reply_ids,
         "remaining" => length(remaining),
         "state" => get_in(issue, ["state", "name"])
       }}
    end
  end

  defp reply_withdrawals(issue_id, withdrawing, reason, opts) do
    projected = Keyword.get(opts, :projected, [])
    {_projected, replying} = Enum.split_with(withdrawing, fn {_comment_id, request} -> Request.normalize_title(request.title) in projected end)

    Enum.reduce_while(replying, {:ok, []}, fn {comment_id, _request}, {:ok, ids} ->
      variables = %{issueId: issue_id, parentId: comment_id, body: Request.render_withdrawal(reason)}

      with {:ok, response} <- graphql(@add_reply_mutation, variables, opts),
           {:ok, response} <- check_mutation_success(response, "commentCreate") do
        {:cont, {:ok, ids ++ [get_in(response, ["data", "commentCreate", "comment", "id"])]}}
      else
        error -> {:halt, error}
      end
    end)
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

  With `parent_documents: true` (a QA pass, whose design usually sits on the parent), the
  documents the parent's runs created are readable too: the list returns them as
  `parentDocuments`, next to the parent's identifier. Writing stays limited to the issue's own
  documents (`update_document/3`).
  """
  @spec get_document(context(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def get_document(context, document_id, opts \\ []) do
    if is_nil(document_id),
      do: list_issue_documents(context, opts),
      else: read_issue_document(context, document_id, opts)
  end

  defp list_issue_documents(context, opts) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, scope} <- readable_document_scope(issue_id, opts),
         owned = owned_document_ids(scope, context),
         parent_ids = parent_document_ids(scope) -- owned,
         {:ok, documents} <- list_documents(owned ++ parent_ids, opts) do
      documents = Enum.map(documents, fn document -> wrap_string_field(document, "title", &PromptSafety.linear_document_title/1) end)
      {parent_documents, own_documents} = Enum.split_with(documents, &(&1["id"] in parent_ids))
      {:ok, put_parent_documents(%{"documents" => own_documents}, scope, parent_documents, opts)}
    end
  end

  defp put_parent_documents(listing, scope, parent_documents, opts) do
    if Keyword.get(opts, :parent_documents, false),
      do: Map.merge(listing, %{"parent" => get_in(scope, ["parent", "identifier"]), "parentDocuments" => parent_documents}),
      else: listing
  end

  defp read_issue_document(context, document_id, opts) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, document_id} <- document_id_field(document_id),
         {:ok, scope} <- readable_document_scope(issue_id, opts),
         :ok <- verify_document_readable(scope, context, document_id),
         {:ok, body} <- signed_graphql(@document_query, %{id: document_id}, opts),
         {:ok, document} <- fetch_path(body, ["data", "document"], :document_not_found) do
      {:ok, wrap_document(document, context, opts)}
    end
  end

  defp readable_document_scope(issue_id, opts) do
    if Keyword.get(opts, :parent_documents, false),
      do: issue_scope(@readable_document_scope_query, issue_id, opts),
      else: document_scope(issue_id, opts)
  end

  defp document_scope(issue_id, opts), do: issue_scope(@document_scope_query, issue_id, opts)

  defp issue_scope(query, issue_id, opts) do
    with {:ok, body} <- graphql(query, %{id: issue_id, first: @document_attachment_first}, opts) do
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

  defp verify_document_readable(scope, context, document_id) do
    if document_id in parent_document_ids(scope),
      do: :ok,
      else: verify_document_owner(scope, context, document_id)
  end

  # The documents this run created, plus the ones the issue's attachments mark as created for it.
  defp owned_document_ids(scope, context) do
    Enum.uniq(attached_document_ids(scope) ++ CommentRegistry.document_ids(Map.get(context, :comment_registry)))
  end

  # Only a scope read with `parent_documents: true` carries the parent.
  defp parent_document_ids(scope), do: scope |> Map.get("parent") |> attached_document_ids() |> Enum.uniq()

  defp attached_document_ids(nil), do: []

  defp attached_document_ids(scope) do
    for %{"metadata" => %{@document_metadata_key => document_id}} <- get_in(scope, ["attachments", "nodes"]) || [],
        is_binary(document_id),
        do: document_id
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

  @doc """
  Writes the Symphony summary block at the end of the current issue's description: the status, the
  review brief and artifact links, and one new changelog entry dated today (UTC) on top of the
  ones the block holds, capped. The description is read right before the write, and every byte
  outside the block stays as it is, so a person's edit between runs survives. Fields holding a
  secret pattern are refused before any Linear call.
  """
  @spec update_issue_summary(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_issue_summary(context, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, summary} <- IssueSummary.new(attrs),
         :ok <- SecretScanner.reject_fields_if_secret_pattern(summary_secret_fields(summary), context, "linear_update_issue_summary", opts),
         {:ok, body} <- graphql(@issue_description_query, %{id: issue_id}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, description} <- IssueSummary.put(issue["description"], summary, Keyword.get_lazy(opts, :today, &Date.utc_today/0)),
         variables = %{id: issue_id, description: description},
         {:ok, response} <- graphql(@update_issue_description_mutation, variables, opts),
         {:ok, response} <- check_mutation_success(response, "issueUpdate") do
      {:ok, %{"issue" => get_in(response, ["data", "issueUpdate", "issue"]), "descriptionLength" => String.length(description)}}
    end
  end

  @doc """
  Records which test proves each walkthrough step the implementer covered: each named step of the
  current issue's `## User walkthrough` ends with `Proved by: <test>` (`SymphonyElixir.Walkthrough.record_proofs/2`).
  The description is read right before the write, and every byte outside those steps' proof lines
  stays as it is. A test naming a check, a step the walkthrough lacks, and a step its author marked
  `Proved by: QA` are refused before the write; a test holding a secret pattern before any Linear call.
  """
  @spec record_walkthrough_proofs(context(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_walkthrough_proofs(context, attrs, opts \\ []) when is_map(attrs) do
    proofs = Map.get(attrs, "proofs")

    with {:ok, issue_id} <- current_issue_id(context),
         :ok <- SecretScanner.reject_fields_if_secret_pattern(proof_secret_fields(proofs), context, "linear_record_walkthrough_proofs", opts),
         {:ok, body} <- graphql(@issue_description_query, %{id: issue_id}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, description} <- Walkthrough.record_proofs(issue["description"], proofs),
         variables = %{id: issue_id, description: description},
         {:ok, response} <- graphql(@update_issue_description_mutation, variables, opts),
         {:ok, response} <- check_mutation_success(response, "issueUpdate") do
      {:ok, %{"issue" => get_in(response, ["data", "issueUpdate", "issue"]), "steps" => Enum.map(proofs, & &1["step"])}}
    end
  end

  defp proof_secret_fields(proofs) do
    for %{"test" => test} when is_binary(test) <- List.wrap(proofs), do: {:test, test}
  end

  defp summary_secret_fields(summary) do
    links = Enum.flat_map(summary.artifacts, &[artifact_label: &1.label, artifact_url: &1.url])
    [status: summary.status, changelog_entry: summary.entry, review_brief: summary.review_brief || ""] ++ links
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

  defp create_child_issue(issue_id, {title, description, priority, blocked_by}, state_name, registry, opts) do
    with {:ok, body} <- graphql(@subissue_scope_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, parent} <- fetch_path(body, ["data", "issue"], :issue_not_found),
         {:ok, states} <- fetch_path(parent, ["team", "states", "nodes"], []),
         {:ok, state_id} <- child_state_id(states, state_name),
         {:ok, blockers} <- resolve_blockers(blocked_by, parent, registry),
         input = subissue_input(parent, state_id, title, description, priority || parent["priority"]),
         {:ok, response} <- graphql(@create_subissue_mutation, %{input: input}, opts),
         {:ok, response} <- check_mutation_success(response, "issueCreate"),
         {:ok, identifier, new_id} <- created_subissue(response) do
      CommentRegistry.record_subissue(registry, issue_id, title, identifier, new_id)
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

  # The new child's initial state, by name (case-insensitively), the way the team names it. `Backlog`
  # also matches the team's backlog-type state, so an agent's sub-issue lands in the column the
  # tracker shows as Backlog even when the team renamed it. Any other `state_name` — an epic review's
  # `Todo` follow-up (`SymphonyElixir.EpicReview`) — is matched by name alone.
  defp child_state_id(states, state_name) do
    state =
      Enum.find(states, &state_name_matches?(&1, state_name)) ||
        if(state_name_matches?(%{"name" => @backlog_state}, state_name),
          do: Enum.find(states, &(&1["type"] == "backlog"))
        )

    case state do
      %{"id" => state_id} -> {:ok, state_id}
      _ -> {:error, child_state_error(state_name, states)}
    end
  end

  # A team with no `Backlog` keeps the error the agent tool's mapping knows
  # (`SymphonyElixir.Codex.DynamicTool`), and a machine-side filing names the state it asked for.
  defp child_state_error(state_name, states) do
    available = states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)

    if state_name_matches?(%{"name" => @backlog_state}, state_name) do
      {:backlog_state_not_found, available}
    else
      {:child_state_not_found, state_name, available}
    end
  end

  # The one state write outside the guard is sub-issue creation's initial state: the guard resolves
  # a move of an existing issue (from-state to target), and an `issueCreate` has no from-state to
  # move from. So sub-issue creation's initial state is outside TransitionGuard's scope: `create_subissue/3`'s
  # Backlog child and `create_subissue_in_state/4`'s named one (an epic review's `Todo` follow-up)
  # both come through here, and this is the only stateId the Linear tool hands Linear without
  # `TransitionGuard.resolve_request/2`; the state-scanning test in `agent_tools_linear_test.exs`
  # keeps that list to the two known sites.
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

  defp resolve_state_id(context, issue_id, state_name_or_id, opts) do
    normalized = String.trim(state_name_or_id)

    if normalized == "" do
      {:error, :invalid_state}
    else
      settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

      with {:ok, state, issue} <- lookup_team_state(issue_id, normalized, opts) do
        ticket = %{ticket: {:ticket, issue_repo_key(context), issue_id}, issue_identifier: issue_identifier(context)}
        guard_state(state, settings, issue, ticket)
      end
    end
  end

  # The guard's answer decides what the tool does: a state the issue moves to, a hold that pauses it
  # in place, or the refusal the tool passes back. A resolved move carries what recording its signal
  # needs: the state it came from, the state it goes to, the repo key and the lane verdict the move
  # means (nil for every move but a CI Fix ticket's own request to `Rework`). A block report pauses
  # the ticket named in `ticket` through the guard.
  defp guard_state(state, settings, issue, ticket) do
    from_state = get_in(issue, ["state", "name"])

    ctx =
      Map.merge(ticket, %{
        settings: settings,
        from_state: from_state,
        plan_parent?: plan_parent?(issue),
        open_blockers: open_blockers(issue, settings.tracker.terminal_states)
      })

    case TransitionGuard.resolve_request(state, ctx) do
      {:ok, resolved} -> {:ok, {:state, resolved["id"]}, move_details(from_state, resolved, settings)}
      {:hold, _kind, _attrs} = hold -> hold
      {:error, _reason} = error -> error
    end
  end

  defp move_details(from_state, resolved, settings) do
    %{
      from: from_state,
      to: resolved["name"],
      fix_verdict: CiFix.verdict_for_move(from_state, resolved["name"], settings)
    }
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
          {:ok, state, get_in(body, ["data", "issue"])}

        _ ->
          available = states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
          {:error, {:state_not_found, available}}
      end
    end
  end

  # The identifiers of the issue's blocked-by blockers still outside a terminal state, the way
  # `Issue.open_blockers/2` counts them: a blocker without a known state is open.
  defp open_blockers(issue, terminal_states) do
    terminal = MapSet.new(terminal_states, &normalize_state_name/1)

    for %{"type" => "blocks", "issue" => %{"identifier" => identifier} = blocker} <-
          issue |> get_in(["inverseRelations", "nodes"]) |> List.wrap(),
        is_binary(identifier),
        not MapSet.member?(terminal, normalize_state_name(get_in(blocker, ["state", "name"]))),
        uniq: true,
        do: identifier
  end

  defp normalize_state_name(name), do: name |> to_string() |> String.trim() |> String.downcase()

  # A `plan` (or `breakdown`) parent: it is groomed into sub-tickets and never opens a pull
  # request, and it is the ticket whose handoff enters `Plan Review`.
  defp plan_parent?(issue) do
    labels = issue |> get_in(["labels", "nodes"]) |> List.wrap() |> Enum.map(&label_name/1)
    Enum.any?(labels, &Issue.breakdown_label?/1)
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

  # A comment opening with `Decision:` or `Ruling:` reads as a person's ruling. Symphony records none
  # (answers come from the Director), but agents post as the operator's Linear user, so an agent
  # may still not write one. Nor may it write a grant
  # that unlocks a protected path (`PathUnlock`), which a reply under a decision request would
  # record as the person's answer.
  defp reject_ruling(body) do
    cond do
      Decisions.ruling?(body) -> {:error, :ruling_comment_body}
      PathUnlock.grant_text?(body) -> {:error, :path_unlock_grant_text}
      true -> :ok
    end
  end

  # A sub-issue's description is where its Decisions section lives, so it may not hold a grant.
  defp reject_unlock_grant(text) do
    if PathUnlock.grant_text?(text), do: {:error, :path_unlock_grant_text}, else: :ok
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
