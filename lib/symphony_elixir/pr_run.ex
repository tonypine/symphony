defmodule SymphonyElixir.PrRun do
  @moduledoc """
  Builds PR-shaped run contexts for explicit operator dispatch.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.{PullRequest, Repo}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workspace

  @pr_view_fields "number,state,title,body,url,headRefName,baseRefName,headRepository"

  @type resolved :: %{
          issue: Issue.t(),
          pr: map(),
          repo_key: String.t()
        }

  @spec resolve(String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(target), do: resolve(target, [])

  @spec resolve(String.t(), keyword()) :: {:ok, resolved()} | {:error, term()}
  def resolve(target, opts) when is_binary(target) and is_list(opts) do
    repo_key = Keyword.get(opts, :repo_key) || Config.repo_key!()

    with {:ok, settings} <- Config.settings_for_repo(repo_key),
         {:ok, primary_repo} <- primary_repo(settings),
         {:ok, origin_repos} <- origin_github_repos(primary_repo, settings, opts),
         {:ok, pr} <- fetch_pr(target, origin_repos.gh_repo, opts),
         :ok <- validate_same_repo_pr(pr, origin_repos.repo),
         {:ok, issue} <- issue_for_pr(pr, repo_key, Keyword.get(opts, :intent)) do
      {:ok, %{issue: issue, pr: pr, repo_key: repo_key}}
    end
  end

  def resolve(_target, _opts), do: {:error, :invalid_pr_target}

  defp primary_repo(%{workspace: %{repo: repo}}) when is_binary(repo) and repo != "" do
    {:ok, Path.expand(repo)}
  end

  defp primary_repo(_settings), do: {:error, :missing_workspace_repo}

  defp origin_github_repos(primary_repo, settings, opts) do
    github_opts = [github_enterprise_hosts: settings.github.enterprise_hosts]

    with {:ok, origin_url} <- origin_url(primary_repo, opts),
         repo when is_binary(repo) <- Repo.from_url(origin_url, github_opts),
         gh_repo when is_binary(gh_repo) <- Repo.gh_repo_from_url(origin_url, github_opts) do
      {:ok, %{repo: repo, gh_repo: gh_repo}}
    else
      _reason -> {:error, :missing_github_origin_repo}
    end
  end

  defp origin_url(primary_repo, opts) do
    case Workspace.safe_git(["-C", primary_repo, "remote", "get-url", "origin"], Keyword.take(opts, [:env])) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:origin_url_failed, status, output}}
    end
  end

  defp fetch_pr(target, origin_repo, opts) do
    with {:ok, output} <-
           PullRequest.run_gh(["pr", "view", String.trim(target), "--repo", origin_repo, "--json", @pr_view_fields], opts),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      {:ok, pr}
    else
      {:ok, _decoded} -> {:error, :invalid_pull_request_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pull_request_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_same_repo_pr(pr, origin_repo) do
    head_repo =
      case Map.get(pr, "headRepository") do
        %{"nameWithOwner" => name} -> name
        _ -> nil
      end

    if Repo.same?(head_repo, origin_repo) do
      :ok
    else
      {:error, {:unsupported_cross_repo_pr, head_repo, origin_repo}}
    end
  end

  defp issue_for_pr(pr, repo_key, intent) do
    with {:ok, number} <- required_integer(pr, "number"),
         {:ok, url} <- required_string(pr, "url"),
         {:ok, head_ref} <- required_string(pr, "headRefName") do
      base_ref = string_value(pr, "baseRefName")
      title = string_value(pr, "title") || "Pull request ##{number}"
      body = string_value(pr, "body") || ""
      intent = normalize_intent(intent)

      pr_context = %{
        number: number,
        url: url,
        title: title,
        body: body,
        state: string_value(pr, "state"),
        head_ref: head_ref,
        base_ref: base_ref,
        intent: intent
      }

      {:ok,
       %Issue{
         id: "pr:#{repo_key}:#{number}",
         identifier: "PR-#{number}",
         title: title,
         description: body,
         state: "In Progress",
         repo_key: repo_key,
         run_kind: :pr,
         intent: intent,
         pr_context: pr_context,
         workspace_branch: head_ref,
         workspace_base_ref: "origin/#{head_ref}"
       }}
    end
  end

  defp required_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_pr_field, key}}
    end
  end

  defp required_string(map, key) do
    case string_value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_pr_field, key}}
    end
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp normalize_intent(intent) when is_binary(intent) do
    case String.trim(intent) do
      "" -> "make progress on this pull request"
      trimmed -> trimmed
    end
  end

  defp normalize_intent(_intent), do: "make progress on this pull request"
end
