defmodule SymphonyElixir.GitHub.PullRequest do
  @moduledoc """
  Reads pull request lifecycle state through the GitHub CLI.
  """

  require Logger

  alias SymphonyElixir.GitHub.{CommentMarker, Hosts}

  @passing_check_conclusions ["SUCCESS", "NEUTRAL", "SKIPPED"]

  @type comment :: %{
          optional(:id) => String.t() | nil,
          optional(:node_id) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:body) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:kind) => String.t(),
          optional(:path) => String.t() | nil,
          optional(:line) => integer() | nil,
          optional(:created_at) => DateTime.t() | nil,
          optional(:updated_at) => DateTime.t() | nil
        }

  @type activity :: %{
          pr_url: String.t(),
          pr_number: non_neg_integer() | nil,
          pr_title: String.t() | nil,
          pr_description: String.t() | nil,
          pr_author: String.t() | nil,
          pr_node_id: String.t() | nil,
          state: String.t() | nil,
          review_decision: String.t() | nil,
          mergeable: String.t() | nil,
          merge_state_status: String.t() | nil,
          head_ref_name: String.t() | nil,
          base_ref_name: String.t() | nil,
          head_ref_oid: String.t() | nil,
          base_ref_oid: String.t() | nil,
          is_cross_repository: boolean() | nil,
          auto_merge_enabled: boolean(),
          latest_activity_at: DateTime.t() | nil,
          latest_review_activity_at: DateTime.t() | nil,
          comments: [comment()]
        }

  @type ci_check :: %{
          optional(:name) => String.t() | nil,
          optional(:status) => String.t() | nil,
          optional(:conclusion) => String.t() | nil,
          optional(:details_url) => String.t() | nil,
          optional(:workflow_name) => String.t() | nil,
          optional(:run_id) => String.t() | nil,
          optional(:stale) => boolean()
        }

  @type ci_status :: %{
          optional(:workflow_runs) => [head_run()],
          pr_url: String.t(),
          pr_title: String.t() | nil,
          pr_node_id: String.t() | nil,
          state: String.t() | nil,
          head_ref_name: String.t() | nil,
          commit_sha: String.t() | nil,
          is_cross_repository: boolean() | nil,
          head_repository: map() | nil,
          mergeable: String.t() | nil,
          merge_state_status: String.t() | nil,
          base_ref_name: String.t() | nil,
          auto_merge_enabled: boolean(),
          checks: [ci_check()]
        }

  @type head_run :: %{id: String.t() | nil, status: String.t() | nil, conclusion: String.t() | nil}

  @type review :: %{
          optional(:id) => String.t() | nil,
          optional(:node_id) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:body) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:state) => String.t() | nil,
          optional(:commit_id) => String.t() | nil,
          optional(:submitted_at) => DateTime.t() | nil
        }

  @type workflow_run :: %{
          id: String.t() | nil,
          workflow_name: String.t() | nil,
          status: String.t() | nil,
          conclusion: String.t() | nil,
          url: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @type open_pull_request :: %{
          number: non_neg_integer() | nil,
          url: String.t() | nil,
          title: String.t() | nil,
          head_sha: String.t() | nil,
          files: [String.t()]
        }

  @run_fields "databaseId,workflowName,status,conclusion,url,createdAt"

  @doc "Whether a fetched PR conflicts with its base: `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`."
  @spec conflicting?(map()) :: boolean()
  def conflicting?(pr) when is_map(pr) do
    upcase(Map.get(pr, :mergeable)) == "CONFLICTING" or upcase(Map.get(pr, :merge_state_status)) == "DIRTY"
  end

  @spec fetch_activity(term(), keyword()) :: {:ok, activity()} | {:error, term()}
  def fetch_activity(pr_url, opts \\ []) do
    if is_binary(pr_url) and is_list(opts) do
      do_fetch_activity(pr_url, opts)
    else
      {:error, :invalid_pr_url}
    end
  end

  @spec current_user(keyword()) :: {:ok, String.t()} | {:error, term()}
  def current_user(opts \\ []) when is_list(opts) do
    case run_gh(["api", "user", "--jq", ".login"], opts) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:error, :empty_current_user}
          login -> {:ok, login}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_ci_status(term(), keyword()) :: {:ok, ci_status()} | {:error, term()}
  def fetch_ci_status(pr_url, opts \\ []) do
    if is_binary(pr_url) and is_list(opts) do
      do_fetch_ci_status(pr_url, opts)
    else
      {:error, :invalid_pr_url}
    end
  end

  @doc "The commit a merged pull request landed as, or nil while it is not merged."
  @spec merge_commit_sha(String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def merge_commit_sha(pr_url, opts \\ []) when is_binary(pr_url) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         {:ok, output} <- run_gh(github_api_args(host, "repos/#{owner}/#{repo}/pulls/#{number}"), opts),
         {:ok, %{} = pr} <- Jason.decode(output) do
      {:ok, if(Map.get(pr, "merged") == true, do: normalize_id(Map.get(pr, "merge_commit_sha")))}
    else
      :error -> {:error, :invalid_pr_url}
      {:ok, _decoded} -> {:error, :invalid_pr_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pr_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `head_sha` includes `sha`, in the repository of the pull request at `pr_url`: true when
  GitHub compares `sha...head_sha` as `ahead` or `identical`.
  """
  @spec commit_included?(String.t(), String.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def commit_included?(pr_url, sha, head_sha, opts \\ []) when is_binary(pr_url) and is_binary(sha) and is_binary(head_sha) do
    with {:ok, host, owner, repo, _number} <- parse_github_pr_url(pr_url, opts),
         {:ok, output} <- run_gh(github_api_args(host, "repos/#{owner}/#{repo}/compare/#{sha}...#{head_sha}") ++ ["--jq", ".status"], opts) do
      case String.trim(output) do
        status when status in ["ahead", "identical"] -> {:ok, true}
        status when status in ["behind", "diverged"] -> {:ok, false}
        status -> {:error, {:unexpected_compare_status, status}}
      end
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  @open_pull_requests_query """
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes { number url title headRefOid files(first: 100) { nodes { path } } }
      }
    }
  }
  """

  @doc """
  The open pull requests of the repository `pr_url` belongs to, in one GraphQL query: the 100
  most recently updated, each with its first 100 changed paths.
  """
  @spec list_open_pull_requests(String.t(), keyword()) :: {:ok, [open_pull_request()]} | {:error, term()}
  def list_open_pull_requests(pr_url, opts \\ []) when is_binary(pr_url) and is_list(opts) do
    with {:ok, host, owner, repo, _number} <- parse_github_pr_url(pr_url, opts),
         args = github_api_args(host, "graphql") ++ ["-f", "query=#{@open_pull_requests_query}", "-f", "owner=#{owner}", "-f", "name=#{repo}"],
         {:ok, output} <- run_gh(args, opts),
         {:ok, %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => nodes}}}}} when is_list(nodes) <- Jason.decode(output) do
      {:ok, nodes |> Enum.filter(&is_map/1) |> Enum.map(&normalize_open_pull_request/1)}
    else
      :error -> {:error, :invalid_pr_url}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_open_pull_requests_payload, error.data}}
      {:error, reason} -> {:error, reason}
      {:ok, _decoded} -> {:error, :invalid_open_pull_requests_payload}
    end
  end

  defp normalize_open_pull_request(node) do
    files = get_in(node, ["files", "nodes"])

    %{
      number: if(is_integer(node["number"]), do: node["number"]),
      url: node["url"],
      title: node["title"],
      head_sha: node["headRefOid"],
      files: if(is_list(files), do: for(%{"path" => path} when is_binary(path) <- files, do: path), else: [])
    }
  end

  def fetch_failed_log(run_id, opts \\ [])

  @doc """
  The failed-step log of a workflow run. The repository is the checkout in `:cwd`, or `:repo`
  (`owner/repo` or `host/owner/repo`) when given.
  """
  @spec fetch_failed_log(String.t() | integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_failed_log(run_id, opts) when (is_binary(run_id) or is_integer(run_id)) and is_list(opts) do
    run_gh(["run", "view", to_string(run_id), "--log-failed"] ++ repo_args(opts), opts)
  end

  def fetch_failed_log(_run_id, _opts), do: {:error, :invalid_run_id}

  @doc """
  The latest workflow runs on `branch` of `repo` (`owner/repo` or `host/owner/repo`), newest
  first, in one request: at most `:limit` runs (default 50).
  """
  @spec list_branch_runs(String.t(), String.t(), keyword()) :: {:ok, [workflow_run()]} | {:error, term()}
  def list_branch_runs(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) and is_list(opts) do
    args = ["run", "list", "-R", repo, "--branch", branch, "--limit", to_string(Keyword.get(opts, :limit, 50)), "--json", @run_fields]

    with {:ok, output} <- run_gh(args, opts) do
      case Jason.decode(output) do
        {:ok, runs} when is_list(runs) -> {:ok, runs |> Enum.filter(&is_map/1) |> Enum.map(&normalize_workflow_run/1)}
        _other -> {:error, :invalid_workflow_runs_payload}
      end
    end
  end

  defp normalize_workflow_run(run) do
    %{
      id: normalize_id(run["databaseId"]),
      workflow_name: run["workflowName"],
      status: upcase(run["status"]),
      conclusion: upcase(run["conclusion"]),
      url: run["url"],
      created_at: parse_datetime(run["createdAt"])
    }
  end

  defp repo_args(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" -> ["-R", repo]
      _none -> []
    end
  end

  def fetch_pr_comments(pr_url, opts \\ [])

  @spec fetch_pr_comments(term(), keyword()) :: {:ok, [comment()]} | {:error, term()}
  def fetch_pr_comments(pr_url, opts) when is_binary(pr_url) and is_list(opts) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         {:ok, comments} <- fetch_paginated_api(host, "repos/#{owner}/#{repo}/issues/#{number}/comments", opts, :invalid_pr_comments_payload) do
      {:ok, Enum.map(comments, &normalize_pr_comment/1)}
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_pr_comments(_pr_url, _opts), do: {:error, :invalid_pr_url}

  def fetch_pr_review_comments(pr_url, opts \\ [])

  @spec fetch_pr_review_comments(term(), keyword()) :: {:ok, [comment()]} | {:error, term()}
  def fetch_pr_review_comments(pr_url, opts) when is_binary(pr_url) and is_list(opts) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         {:ok, comments} <- fetch_paginated_api(host, "repos/#{owner}/#{repo}/pulls/#{number}/comments", opts, :invalid_pr_review_comments_payload) do
      {:ok, Enum.map(comments, &normalize_inline_comment/1)}
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_pr_review_comments(_pr_url, _opts), do: {:error, :invalid_pr_url}

  def fetch_pr_reviews(pr_url, opts \\ [])

  @spec fetch_pr_reviews(term(), keyword()) :: {:ok, [review()]} | {:error, term()}
  def fetch_pr_reviews(pr_url, opts) when is_binary(pr_url) and is_list(opts) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         {:ok, reviews} <- fetch_paginated_api(host, "repos/#{owner}/#{repo}/pulls/#{number}/reviews", opts, :invalid_pr_reviews_payload) do
      {:ok, Enum.map(reviews, &normalize_review/1)}
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_pr_reviews(_pr_url, _opts), do: {:error, :invalid_pr_url}

  def rerun_failed(run_id, opts \\ [])

  @spec rerun_failed(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def rerun_failed(run_id, opts) when (is_binary(run_id) or is_integer(run_id)) and is_list(opts) do
    case run_gh(["run", "rerun", to_string(run_id), "--failed"], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def rerun_failed(_run_id, _opts), do: {:error, :invalid_run_id}

  @typedoc "What a squash merge needs: the PR's GraphQL node id, the head it was checked at, and its title and body."
  @type squash_request :: %{
          pr_node_id: String.t(),
          head_sha: String.t(),
          pr_number: non_neg_integer() | nil,
          pr_title: String.t() | nil,
          pr_description: String.t() | nil
        }

  @enable_auto_merge_mutation """
  mutation($pullRequestId: ID!, $expectedHeadOid: GitObjectID, $commitHeadline: String, $commitBody: String) {
    enablePullRequestAutoMerge(input: {pullRequestId: $pullRequestId, mergeMethod: SQUASH, expectedHeadOid: $expectedHeadOid, commitHeadline: $commitHeadline, commitBody: $commitBody}) {
      clientMutationId
    }
  }
  """

  @merge_mutation """
  mutation($pullRequestId: ID!, $expectedHeadOid: GitObjectID, $commitHeadline: String, $commitBody: String) {
    mergePullRequest(input: {pullRequestId: $pullRequestId, mergeMethod: SQUASH, expectedHeadOid: $expectedHeadOid, commitHeadline: $commitHeadline, commitBody: $commitBody}) {
      clientMutationId
    }
  }
  """

  @doc """
  Turns on GitHub auto-merge (squash, PR title and body) for the head in `request`. GitHub
  refuses it for a PR that can already merge; that comes back as `{:error, :clean_status}`.
  A head that moved since it was read comes back as `{:error, :head_moved}`. Other refusals
  (no branch protection, auto-merge not allowed) come back as the `gh` failure.
  """
  @spec enable_auto_merge(String.t(), squash_request(), keyword()) :: :ok | {:error, term()}
  def enable_auto_merge(pr_url, request, opts \\ []) when is_binary(pr_url) and is_map(request) do
    case squash_mutation(pr_url, @enable_auto_merge_mutation, request, opts) do
      {:error, {:gh_failed, _args, _status, output}} = error ->
        cond do
          clean_status_output?(output) -> {:error, :clean_status}
          head_moved_output?(output) -> {:error, :head_moved}
          true -> error
        end

      result ->
        result
    end
  end

  @disable_auto_merge_mutation """
  mutation($pullRequestId: ID!) {
    disablePullRequestAutoMerge(input: {pullRequestId: $pullRequestId}) {
      clientMutationId
    }
  }
  """

  @doc "Turns GitHub auto-merge off for the PR with GraphQL node id `pr_node_id`."
  @spec disable_auto_merge(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def disable_auto_merge(pr_url, pr_node_id, opts \\ []) when is_binary(pr_url) and is_binary(pr_node_id) do
    with {:ok, host, _owner, _repo, _number} <- parse_github_pr_url(pr_url, opts),
         {:ok, _output} <- run_gh(github_api_args(host, "graphql") ++ ["-f", "query=#{@disable_auto_merge_mutation}", "-f", "pullRequestId=#{pr_node_id}"], opts) do
      :ok
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Squash-merges the PR now, only if its head is still the one in `request`."
  @spec squash_merge(String.t(), squash_request(), keyword()) :: :ok | {:error, term()}
  def squash_merge(pr_url, request, opts \\ []) when is_binary(pr_url) and is_map(request) do
    squash_mutation(pr_url, @merge_mutation, request, opts)
  end

  @doc """
  Merges the base branch into the PR branch on GitHub, only if the head is still
  `expected_head_sha`. A merge conflict comes back as `{:error, :conflict}`.
  """
  @spec update_branch(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_branch(pr_url, expected_head_sha, opts \\ []) when is_binary(pr_url) and is_binary(expected_head_sha) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         args = github_api_args(host, "repos/#{owner}/#{repo}/pulls/#{number}/update-branch") ++ ["--method", "PUT", "-f", "expected_head_sha=#{expected_head_sha}"],
         {:ok, _output} <- run_gh(args, opts) do
      :ok
    else
      :error ->
        {:error, :invalid_pr_url}

      {:error, {:gh_failed, _args, _status, output}} = error ->
        if merge_conflict_output?(output), do: {:error, :conflict}, else: error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp squash_mutation(pr_url, mutation, request, opts) do
    with {:ok, host, _owner, _repo, _number} <- parse_github_pr_url(pr_url, opts),
         {:ok, _output} <- run_gh(github_api_args(host, "graphql") ++ squash_mutation_fields(mutation, request), opts) do
      :ok
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp squash_mutation_fields(mutation, request) do
    [
      "-f",
      "query=#{mutation}",
      "-f",
      "pullRequestId=#{Map.fetch!(request, :pr_node_id)}",
      "-f",
      "expectedHeadOid=#{Map.fetch!(request, :head_sha)}",
      "-f",
      "commitHeadline=#{squash_headline(request)}",
      "-f",
      "commitBody=#{Map.get(request, :pr_description) || ""}"
    ]
  end

  # GitHub's own squash title: "<PR title> (#<number>)".
  defp squash_headline(%{pr_title: title, pr_number: number}) when is_binary(title) and is_integer(number), do: "#{title} (##{number})"
  defp squash_headline(%{pr_title: title}) when is_binary(title), do: title
  defp squash_headline(_request), do: ""

  defp clean_status_output?(output) when is_binary(output), do: output =~ ~r/clean status/i
  defp clean_status_output?(_output), do: false

  defp head_moved_output?(output) when is_binary(output), do: output =~ ~r/expected head oid does not match/i
  defp head_moved_output?(_output), do: false

  defp merge_conflict_output?(output) when is_binary(output), do: output =~ ~r/merge conflict/i
  defp merge_conflict_output?(_output), do: false

  def post_inline_comment_reply(pr_url, comment_id, body, opts \\ [])

  @spec post_inline_comment_reply(term(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_inline_comment_reply(pr_url, comment_id, body, opts)
      when is_binary(pr_url) and is_binary(comment_id) and is_binary(body) and is_list(opts) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         {:ok, output} <-
           run_gh(
             github_api_args(host, "repos/#{owner}/#{repo}/pulls/#{number}/comments/#{comment_id}/replies") ++
               ["-f", "body=#{body}"],
             opts
           ),
         {:ok, payload} when is_map(payload) <- decode_reply_payload(output) do
      {:ok, payload}
    else
      :error -> {:error, :invalid_pr_url}
      {:ok, _decoded} -> {:error, :invalid_reply_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  def post_inline_comment_reply(_pr_url, _comment_id, _body, _opts), do: {:error, :invalid_reply}

  defp decode_reply_payload(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, payload} -> {:ok, payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_reply_payload, Exception.message(error)}}
    end
  end

  @spec reply_to_comment(String.t(), comment(), String.t(), keyword()) :: :ok | {:error, term()}
  def reply_to_comment(pr_url, comment, body, opts \\ []) do
    cond do
      inline_comment?(comment) and is_binary(pr_url) and is_binary(body) ->
        reply_to_inline_comment(pr_url, comment, body, opts)

      is_binary(pr_url) and is_binary(body) ->
        reply_to_pr_comment(pr_url, body, opts)

      true ->
        {:error, :invalid_reply}
    end
  end

  @spec request_review(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def request_review(pr_url, reviewers, opts \\ []) when is_binary(pr_url) and is_list(reviewers) do
    reviewers = reviewers |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    case reviewers do
      [] ->
        :ok

      [_ | _] ->
        case parse_github_pr_url(pr_url, opts) do
          {:ok, _host, _owner, _repo, _number} -> do_request_review(pr_url, reviewers, opts)
          :error -> {:error, :invalid_pr_url}
        end
    end
  end

  defp do_request_review(pr_url, reviewers, opts) do
    args = ["pr", "edit", pr_url] ++ Enum.flat_map(reviewers, &["--add-reviewer", &1])

    case run_gh(args, opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp inline_comment?(%{kind: "inline_comment"}), do: true
  defp inline_comment?(%{"kind" => "inline_comment"}), do: true
  defp inline_comment?(_comment), do: false

  defp reply_to_inline_comment(pr_url, comment, body, opts) do
    with {:ok, host, owner, repo, number} <- parse_github_pr_url(pr_url, opts),
         comment_id when is_binary(comment_id) <- comment_id(comment),
         {:ok, _output} <-
           run_gh(
             github_api_args(host, "repos/#{owner}/#{repo}/pulls/#{number}/comments/#{comment_id}/replies") ++
               ["-f", "body=#{CommentMarker.mark(body)}"],
             opts
           ) do
      :ok
    else
      :error -> {:error, :invalid_pr_url}
      nil -> {:error, :missing_comment_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_to_pr_comment(pr_url, body, opts) do
    case parse_github_pr_url(pr_url, opts) do
      {:ok, _host, _owner, _repo, _number} -> do_reply_to_pr_comment(pr_url, body, opts)
      :error -> {:error, :invalid_pr_url}
    end
  end

  defp do_reply_to_pr_comment(pr_url, body, opts) do
    case run_gh(["pr", "comment", pr_url, "--body", CommentMarker.mark(body)], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_fetch_activity(pr_url, opts) do
    with {:ok, _host, _owner, _repo, _number} <- parse_github_pr_url(pr_url, opts),
         {:ok, pr} <- view_pr(pr_url, opts),
         {:ok, inline_comments} <- fetch_inline_comments(pr_url, pr, opts) do
      comments = pr_comments(pr) ++ review_comments(pr) ++ inline_comments
      latest_activity_at = latest_activity_at(pr, comments)
      latest_review_activity_at = latest_review_activity_at(comments)

      {:ok,
       %{
         pr_url: Map.get(pr, "url") || pr_url,
         pr_number: Map.get(pr, "number"),
         pr_title: Map.get(pr, "title"),
         pr_description: Map.get(pr, "body"),
         pr_author: get_in(pr, ["author", "login"]),
         pr_node_id: normalize_id(Map.get(pr, "id")),
         state: Map.get(pr, "state"),
         review_decision: Map.get(pr, "reviewDecision"),
         mergeable: normalize_id(Map.get(pr, "mergeable")),
         merge_state_status: normalize_id(Map.get(pr, "mergeStateStatus")),
         head_ref_name: normalize_id(Map.get(pr, "headRefName")),
         base_ref_name: normalize_id(Map.get(pr, "baseRefName")),
         head_ref_oid: normalize_id(Map.get(pr, "headRefOid")),
         base_ref_oid: normalize_id(Map.get(pr, "baseRefOid")),
         is_cross_repository: Map.get(pr, "isCrossRepository"),
         auto_merge_enabled: is_map(Map.get(pr, "autoMergeRequest")),
         latest_activity_at: latest_activity_at,
         latest_review_activity_at: latest_review_activity_at,
         comments: comments
       }}
    else
      :error -> {:error, :invalid_pr_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_fetch_ci_status(pr_url, opts) do
    args = [
      "pr",
      "view",
      pr_url,
      "--json",
      "id,number,state,title,url,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup"
    ]

    with {:ok, host, owner, repo, _number} <- parse_github_pr_url(pr_url, opts),
         {:ok, output} <- run_gh(args, opts),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      %{
        pr_url: Map.get(pr, "url") || pr_url,
        pr_title: Map.get(pr, "title"),
        pr_node_id: normalize_id(Map.get(pr, "id")),
        state: Map.get(pr, "state"),
        head_ref_name: normalize_id(Map.get(pr, "headRefName")),
        commit_sha: normalize_id(Map.get(pr, "headRefOid")),
        is_cross_repository: Map.get(pr, "isCrossRepository"),
        head_repository: Map.get(pr, "headRepository"),
        mergeable: normalize_id(Map.get(pr, "mergeable")),
        merge_state_status: normalize_id(Map.get(pr, "mergeStateStatus")),
        base_ref_name: normalize_id(Map.get(pr, "baseRefName")),
        auto_merge_enabled: is_map(Map.get(pr, "autoMergeRequest")),
        checks: normalize_status_check_rollup(Map.get(pr, "statusCheckRollup"))
      }
      |> put_head_runs({host, owner, repo}, opts)
    else
      :error -> {:error, :invalid_pr_url}
      {:ok, _decoded} -> {:error, :invalid_pr_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pr_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every check reported can have passed while a workflow run that reported them has not finished:
  # a rerun of its failed jobs drops those checks from the rollup until the new attempt queues
  # them, and a job with `needs:` has no check until it starts. So a rollup that reads green also
  # carries the head's workflow runs, read in one request, for `CiPoller.ci_action/1` to check.
  # A rollup still waiting on GitHub Actions checks reads them too: GitHub can leave a job's check
  # `in_progress` after its workflow run completed, and only the run says it is finished (see
  # `resolve_stale_checks/2`). A rollup with a failed check, a pending check from outside GitHub
  # Actions, or no GitHub Actions check needs no extra call.
  defp put_head_runs(%{commit_sha: sha, checks: checks} = ci_status, repo, opts) do
    if is_binary(sha) and actions_rollup_without_failure?(checks) do
      with {:ok, runs} <- list_head_runs(repo, sha, opts) do
        {:ok, ci_status |> Map.put(:workflow_runs, runs) |> resolve_stale_checks(runs)}
      end
    else
      {:ok, ci_status}
    end
  end

  defp actions_rollup_without_failure?(checks) do
    Enum.any?(checks, &is_binary(Map.get(&1, :run_id))) and
      Enum.all?(checks, &(passing_check?(&1) or (unfinished_check?(&1) and is_binary(Map.get(&1, :run_id)))))
  end

  # A check that still reads unfinished in a workflow run that completed with a passing
  # conclusion is stale: GitHub never closed it, and the run can't end while one of its jobs
  # runs. It counts as finished with the run's conclusion, so it can't hold a landing forever. A
  # run that failed leaves its unfinished checks as they are; the next read has their conclusion.
  defp resolve_stale_checks(ci_status, runs) do
    passed_runs =
      for %{id: id, status: "COMPLETED", conclusion: conclusion} <- runs,
          conclusion in @passing_check_conclusions,
          into: %{},
          do: {id, conclusion}

    Map.update!(ci_status, :checks, fn checks ->
      Enum.map(checks, &resolve_stale_check(&1, passed_runs, ci_status))
    end)
  end

  defp resolve_stale_check(check, passed_runs, ci_status) do
    with true <- unfinished_check?(check),
         {:ok, conclusion} <- Map.fetch(passed_runs, Map.get(check, :run_id)) do
      Logger.info("Ignoring stale check #{Map.get(check, :name)} in completed run #{Map.get(check, :run_id)} pr_url=#{ci_status.pr_url} commit_sha=#{ci_status.commit_sha}")
      Map.merge(check, %{status: "COMPLETED", conclusion: conclusion, stale: true})
    else
      _not_stale -> check
    end
  end

  defp passing_check?(check), do: upcase(Map.get(check, :conclusion)) in @passing_check_conclusions

  defp unfinished_check?(check) do
    upcase(Map.get(check, :status)) not in ["COMPLETED", "SUCCESS", "FAILURE", "ERROR"] or upcase(Map.get(check, :conclusion)) in [nil, ""]
  end

  defp list_head_runs({host, owner, repo}, sha, opts) do
    endpoint = "repos/#{owner}/#{repo}/actions/runs?head_sha=#{URI.encode_www_form(sha)}&per_page=100"

    with {:ok, output} <- run_gh(github_api_args(host, endpoint), opts) do
      case Jason.decode(output) do
        {:ok, %{"workflow_runs" => runs}} when is_list(runs) ->
          {:ok, for(run when is_map(run) <- runs, do: normalize_head_run(run))}

        _other ->
          {:error, :invalid_workflow_runs_payload}
      end
    end
  end

  defp normalize_head_run(run) do
    %{id: normalize_id(run["id"]), status: upcase(run["status"]), conclusion: upcase(run["conclusion"])}
  end

  defp view_pr(pr_url, opts) do
    args = [
      "pr",
      "view",
      pr_url,
      "--json",
      "id,number,state,reviewDecision,mergeable,mergeStateStatus,autoMergeRequest,headRefName,baseRefName,headRefOid,baseRefOid,isCrossRepository,updatedAt,comments,reviews,title,body,url,author"
    ]

    with {:ok, output} <- run_gh(args, opts),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      {:ok, pr}
    else
      {:ok, _decoded} -> {:error, :invalid_pr_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pr_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_inline_comments(pr_url, %{"number" => number}, opts) when is_integer(number) do
    case parse_github_pr_url(pr_url, opts) do
      {:ok, host, owner, repo, _number} ->
        case run_gh(github_api_args(host, "repos/#{owner}/#{repo}/pulls/#{number}/comments"), opts) do
          {:ok, output} ->
            decode_inline_comments(output)

          {:error, {:gh_failed, _args, 404, _output}} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:ok, []}
    end
  end

  defp fetch_inline_comments(_pr_url, _pr, _opts), do: {:ok, []}

  defp decode_inline_comments(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, comments} when is_list(comments) ->
        {:ok, Enum.map(comments, &normalize_inline_comment/1)}

      {:ok, _payload} ->
        {:ok, []}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_inline_comments_payload, Exception.message(error)}}
    end
  end

  defp fetch_paginated_api(host, endpoint, opts, invalid_reason) do
    case run_gh(github_paginated_api_args(host, endpoint), opts) do
      {:ok, output} -> decode_paginated_list(output, invalid_reason)
      {:error, {:gh_failed, _args, 404, _output}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_paginated_list(output, invalid_reason) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, payload} when is_list(payload) ->
        {:ok, flatten_paginated_payload(payload)}

      {:ok, _payload} ->
        {:error, invalid_reason}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {invalid_reason, Exception.message(error)}}
    end
  end

  defp flatten_paginated_payload(payload) do
    Enum.flat_map(payload, fn
      page when is_list(page) -> page
      item when is_map(item) -> [item]
      _other -> []
    end)
  end

  defp pr_comments(%{"comments" => comments}) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: normalize_id(Map.get(comment, "id") || Map.get(comment, "databaseId") || Map.get(comment, "url")),
        kind: "comment",
        author: get_in(comment, ["author", "login"]),
        body: Map.get(comment, "body"),
        url: Map.get(comment, "url"),
        created_at: parse_datetime(Map.get(comment, "createdAt")),
        updated_at: parse_datetime(Map.get(comment, "updatedAt"))
      }
    end)
  end

  defp pr_comments(_pr), do: []

  defp normalize_pr_comment(comment) when is_map(comment) do
    %{
      id: normalize_id(Map.get(comment, "id") || Map.get(comment, "node_id") || Map.get(comment, "html_url")),
      node_id: normalize_id(Map.get(comment, "node_id")),
      kind: "comment",
      author: get_in(comment, ["user", "login"]),
      author_association: normalize_id(Map.get(comment, "author_association")),
      body: Map.get(comment, "body"),
      url: Map.get(comment, "html_url"),
      created_at: parse_datetime(Map.get(comment, "created_at")),
      updated_at: parse_datetime(Map.get(comment, "updated_at"))
    }
  end

  defp normalize_pr_comment(_comment), do: %{}

  defp review_comments(%{"reviews" => reviews}) when is_list(reviews) do
    reviews
    |> Enum.map(fn review ->
      %{
        id: normalize_id(Map.get(review, "id") || Map.get(review, "databaseId") || Map.get(review, "url")),
        kind: "review",
        author: get_in(review, ["author", "login"]),
        body: Map.get(review, "body"),
        url: Map.get(review, "url"),
        state: Map.get(review, "state"),
        created_at: parse_datetime(Map.get(review, "submittedAt")),
        updated_at: parse_datetime(Map.get(review, "submittedAt"))
      }
    end)
    |> Enum.reject(&(blank?(Map.get(&1, :body)) and blank?(Map.get(&1, :state))))
  end

  defp review_comments(_pr), do: []

  defp normalize_status_check_rollup(checks) when is_list(checks) do
    Enum.map(checks, &normalize_status_check/1)
  end

  defp normalize_status_check_rollup(_checks), do: []

  defp normalize_status_check(check) when is_map(check) do
    details_url = Map.get(check, "detailsUrl") || Map.get(check, "targetUrl")
    status = Map.get(check, "status") || Map.get(check, "state")
    conclusion = Map.get(check, "conclusion") || Map.get(check, "state")

    %{
      name: normalize_id(Map.get(check, "name") || Map.get(check, "context") || Map.get(check, "workflowName")),
      status: normalize_id(status),
      conclusion: normalize_id(conclusion),
      details_url: normalize_id(details_url),
      workflow_name: normalize_id(Map.get(check, "workflowName")),
      run_id: run_id_from_details_url(details_url)
    }
  end

  defp normalize_status_check(_check), do: %{}

  defp run_id_from_details_url(url) when is_binary(url) do
    case Regex.run(~r{/actions/runs/(\d+)}, url) do
      [_full, run_id] -> run_id
      _ -> nil
    end
  end

  defp run_id_from_details_url(_url), do: nil

  defp normalize_inline_comment(comment) when is_map(comment) do
    %{
      id: normalize_id(Map.get(comment, "id") || Map.get(comment, "node_id") || Map.get(comment, "html_url")),
      node_id: normalize_id(Map.get(comment, "node_id")),
      kind: "inline_comment",
      author: get_in(comment, ["user", "login"]),
      body: Map.get(comment, "body"),
      url: Map.get(comment, "html_url"),
      path: Map.get(comment, "path"),
      line: normalize_line(Map.get(comment, "line") || Map.get(comment, "original_line")),
      side: normalize_id(Map.get(comment, "side")),
      position: normalize_line(Map.get(comment, "position")),
      original_position: normalize_line(Map.get(comment, "original_position")),
      review_id: normalize_id(Map.get(comment, "pull_request_review_id")),
      commit_id: normalize_id(Map.get(comment, "commit_id")),
      diff_hunk: Map.get(comment, "diff_hunk"),
      created_at: parse_datetime(Map.get(comment, "created_at")),
      updated_at: parse_datetime(Map.get(comment, "updated_at"))
    }
  end

  defp normalize_inline_comment(_comment), do: %{}

  defp normalize_review(review) when is_map(review) do
    %{
      id: normalize_id(Map.get(review, "id") || Map.get(review, "node_id") || Map.get(review, "html_url")),
      node_id: normalize_id(Map.get(review, "node_id")),
      author: get_in(review, ["user", "login"]),
      body: Map.get(review, "body"),
      url: Map.get(review, "html_url"),
      state: normalize_id(Map.get(review, "state")),
      commit_id: normalize_id(Map.get(review, "commit_id")),
      submitted_at: parse_datetime(Map.get(review, "submitted_at"))
    }
  end

  defp normalize_review(_review), do: %{}

  defp latest_activity_at(pr, comments) do
    ([parse_datetime(Map.get(pr, "updatedAt"))] ++ Enum.flat_map(comments, &comment_timestamps/1))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp latest_review_activity_at(comments) do
    comments
    |> Enum.flat_map(&comment_timestamps/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp comment_timestamps(comment) when is_map(comment) do
    [Map.get(comment, :updated_at), Map.get(comment, :created_at)]
  end

  defp comment_timestamps(_comment), do: []

  defp parse_github_pr_url(url, opts) when is_binary(url) do
    with %URI{scheme: "https", host: host, path: path} <- URI.parse(url),
         {:ok, host} <- Hosts.canonical_github_host(host, opts),
         {:ok, owner, repo, number} <- parse_pull_request_path(path) do
      {:ok, host, owner, repo, number}
    else
      _ -> :error
    end
  end

  defp parse_github_pr_url(_url, _opts), do: :error

  defp parse_pull_request_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [owner, repo, "pull", number | _rest] ->
        if valid_path_part?(owner) and valid_path_part?(repo) and number =~ ~r/^\d+$/ do
          {:ok, owner, repo, String.to_integer(number)}
        else
          :error
        end

      _path_parts ->
        :error
    end
  end

  defp parse_pull_request_path(_path), do: :error

  defp valid_path_part?(value) when is_binary(value) do
    value != "" and not String.match?(value, ~r/\s/)
  end

  defp github_api_args("github.com", endpoint), do: ["api", endpoint]
  defp github_api_args(host, endpoint), do: ["api", "--hostname", host, endpoint]

  defp github_paginated_api_args("github.com", endpoint), do: ["api", "--paginate", "--slurp", endpoint]
  defp github_paginated_api_args(host, endpoint), do: ["api", "--hostname", host, "--paginate", "--slurp", endpoint]

  @doc false
  @spec run_gh([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_gh(args, opts) when is_list(args) do
    cmd_opts = [stderr_to_stdout: true] ++ cwd_opt(Keyword.get(opts, :cwd))

    case gh_runner(opts).(args, cmd_opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:gh_failed, args, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:gh_unavailable, Exception.message(error)}}
  end

  defp gh_runner(opts) do
    case Keyword.get(opts, :gh_runner) do
      runner when is_function(runner, 2) -> runner
      _ -> &System.cmd("gh", &1, &2)
    end
  end

  defp cwd_opt(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: [cd: cwd], else: []
  end

  defp cwd_opt(_cwd), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(_value), do: nil

  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(_value), do: nil

  defp normalize_line(value) when is_integer(value), do: value
  defp normalize_line(_value), do: nil

  defp comment_id(comment) when is_map(comment) do
    normalize_id(Map.get(comment, :id) || Map.get(comment, "id") || Map.get(comment, :node_id) || Map.get(comment, "node_id"))
  end

  defp comment_id(_comment), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
