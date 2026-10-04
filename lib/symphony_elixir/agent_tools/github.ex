defmodule SymphonyElixir.AgentTools.GitHub do
  @moduledoc """
  Narrow GitHub operations exposed to agent prompts.

  Repository, branch, and pull request scope are derived from the Symphony
  session context. Callers cannot pass repo, remote, head, or refspec values
  through tool arguments.
  """

  alias SymphonyElixir.AgentTools.{Linear, ProtectedPaths, PushCheck, SecretScanner}
  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.{CommentMarker, PullRequest}
  alias SymphonyElixir.Repo.Fetcher
  alias SymphonyElixir.Workspace

  @merging_state "Merging"
  @pr_view_fields "number,state,title,body,url,headRefName,baseRefName"
  @failed_conclusions MapSet.new(["ACTION_REQUIRED", "CANCELLED", "FAILURE", "STARTUP_FAILURE", "TIMED_OUT"])
  @max_git_output_bytes 4_096
  @merge_config ["-c", "rerere.enabled=true", "-c", "rerere.autoupdate=true", "-c", "merge.conflictstyle=zdiff3"]

  @type context :: %{
          optional(:issue) => map() | nil,
          optional(:issue_id) => String.t() | nil,
          optional(:comment_registry) => pid() | nil,
          optional(:command_security) => map(),
          optional(:workspace) => Path.t()
        }

  @spec get_pull_request(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pull_request(context, opts \\ []) do
    view_current_pull_request(context, opts)
  end

  @spec fetch_origin(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_origin(context, opts \\ []) do
    if ssh_worker?(context) do
      {:error, {:unsupported_for_ssh_worker, :github_fetch_origin}}
    else
      with {:ok, workspace} <- workspace(context),
           :ok <- verify_current_origin(context, workspace, opts),
           {:ok, output} <- run_fetch_origin(workspace, opts) do
        {:ok, %{"remote" => "origin", "output" => output |> sanitize_git_output() |> String.trim()}}
      end
    end
  end

  @doc """
  Fetches `origin` and merges the base branch into the checked-out branch, outside the agent sandbox.

  The sandbox write-protects paths such as `.ai/skills`, so the agent's own `git merge` fails when
  the base branch changed one. Symphony first fast-forwards to the branch's remote copy when that
  is ahead, then merges with `--no-commit` and repo hooks off: the agent commits the merge (or
  resolves the conflicts) in its sandbox. It refuses a branch that changes a protected path itself.
  """
  @spec sync_base(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_base(context, opts \\ []) do
    if ssh_worker?(context) do
      {:error, {:unsupported_for_ssh_worker, :github_sync_base}}
    else
      with {:ok, workspace} <- workspace(context),
           {:ok, branch} <- current_branch_from_workspace(context, opts),
           :ok <- verify_current_origin(context, workspace, opts),
           {:ok, _output} <- run_fetch_origin(workspace, opts),
           {:ok, heads} <- remote_heads(context, workspace, branch, opts),
           :ok <- refuse_merge_in_progress(workspace, opts),
           :ok <- ProtectedPaths.verify(heads.base_sha, "HEAD", heads.branch_sha, &run_git(&1, workspace, opts)),
           :ok <- fast_forward_to_remote_branch(workspace, heads.branch_sha, opts) do
        merge_base_ref(workspace, branch, heads, opts)
      end
    end
  end

  @spec create_pull_request(context(), term(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_pull_request(context, title, body, draft \\ nil, opts \\ []) do
    with {:ok, title} <- require_string(title, :invalid_title),
         {:ok, body} <- require_string(body, :invalid_body),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [body: body, title: title],
             context,
             "github_create_pull_request",
             opts
           ),
         {:ok, draft?} <- resolve_draft(draft, opts),
         {:ok, origin_repo} <- origin_repo(context),
         {:ok, branch} <- current_branch(context, opts),
         {:ok, output} <-
           PullRequest.run_gh(
             ["pr", "create", "--repo", origin_repo, "--head", branch, "--title", title, "--body", body] ++
               draft_args(draft?),
             github_opts(context, opts)
           ) do
      {:ok, %{"url" => String.trim(output), "repo" => origin_repo, "head" => branch, "draft" => draft?}}
    end
  end

  @spec update_pull_request_body(context(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_pull_request_body(context, body, opts \\ []) do
    with {:ok, body} <- require_string(body, :invalid_body),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "github_update_pull_request_body", opts),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "edit", pr_url, "--body", body], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec add_pr_comment(context(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_pr_comment(context, body, opts \\ []) do
    with {:ok, body} <- require_string(body, :invalid_body),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "github_add_pr_comment", opts),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "comment", pr_url, "--body", CommentMarker.mark(body)], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec reply_to_review_comment(context(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def reply_to_review_comment(context, comment_id, body, opts \\ []) do
    with {:ok, comment_id} <- require_comment_id(comment_id),
         {:ok, body} <- require_string(body, :invalid_body),
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [body: body],
             context,
             "github_reply_to_review_comment",
             opts
           ),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, payload} <-
           PullRequest.post_inline_comment_reply(pr_url, comment_id, CommentMarker.mark(body), github_opts(context, opts)) do
      {:ok,
       %{
         "pr_url" => pr_url,
         "comment_id" => comment_id,
         "reply_id" => Map.get(payload, "id"),
         "url" => Map.get(payload, "html_url")
       }}
    end
  end

  @spec push_branch(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_branch(context, opts \\ []) do
    if ssh_worker?(context) do
      {:error, {:unsupported_for_ssh_worker, :github_push_branch}}
    else
      with {:ok, workspace} <- workspace(context),
           {:ok, branch} <- current_branch(context, opts),
           :ok <- verify_current_origin(context, workspace, opts),
           :ok <- verify_push_urls(context, workspace, opts),
           :ok <- verify_push_protected_paths(context, workspace, branch, opts),
           {:ok, push_check} <- push_check_settings(context, opts),
           :ok <- PushCheck.verify(workspace, branch, push_check, &run_git(&1, workspace, opts)),
           {:ok, output} <- run_git(["push", "origin", branch], workspace, opts) do
        {:ok, %{"remote" => "origin", "branch" => branch, "output" => String.trim(output)}}
      end
    end
  end

  @doc """
  Squash-merges the current branch's pull request at the head commit whose checks were read.

  A human approves the merge by moving the Linear issue to `Merging`, so the merge is refused in
  any other state. It is also refused while a check is failing or pending; a pull request with no
  checks at all is mergeable. Merging an already merged pull request succeeds without a second merge.
  """
  @spec merge_pull_request(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def merge_pull_request(context, opts \\ []) do
    with :ok <- require_merging_state(context, opts),
         {:ok, pr} <- view_current_pull_request(context, opts),
         {:ok, pr_url} <- pull_request_url(pr) do
      case Map.get(pr, "state") do
        "MERGED" -> {:ok, %{"url" => pr_url, "merged" => true, "already_merged" => true}}
        "OPEN" -> squash_merge_pull_request(pr, pr_url, context, opts)
        state -> {:error, {:pull_request_not_open, state}}
      end
    end
  end

  @spec get_pr_checks(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pr_checks(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts) do
      PullRequest.fetch_ci_status(pr_url, github_opts(context, opts))
    end
  end

  @spec list_pr_comments(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_comments(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, comments} <- PullRequest.fetch_pr_comments(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "comments" => comments}}
    end
  end

  @spec list_pr_review_comments(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_review_comments(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, comments} <- PullRequest.fetch_pr_review_comments(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "comments" => comments}}
    end
  end

  @spec list_pr_reviews(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_reviews(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, reviews} <- PullRequest.fetch_pr_reviews(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "reviews" => reviews}}
    end
  end

  @spec get_failed_run_log(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_failed_run_log(context, opts \\ []) do
    with {:ok, status} <- get_pr_checks(context, opts),
         {:ok, check, run_id} <- status |> status_checks() |> latest_failed_check(),
         {:ok, max_bytes} <- failed_run_log_max_bytes(opts),
         {:ok, log} <- PullRequest.fetch_failed_log(run_id, github_opts(context, opts)),
         true <- is_binary(log) do
      {excerpt, truncated?} = clamp_log(log, max_bytes)

      {:ok,
       %{
         "pr_url" => Map.get(status, :pr_url),
         "check" => check,
         "run_id" => run_id,
         "log" => excerpt,
         "truncated" => truncated?,
         "max_bytes" => max_bytes
       }}
    else
      false -> {:error, :invalid_failed_run_log}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_pull_request_url(context, opts) do
    with {:ok, pr} <- view_current_pull_request(context, opts) do
      pull_request_url(pr)
    end
  end

  defp pull_request_url(pr) do
    case Map.get(pr, "url") do
      url when is_binary(url) and url != "" -> {:ok, url}
      _missing -> {:error, :missing_pull_request_url}
    end
  end

  defp require_merging_state(context, opts) do
    with {:ok, issue} <- Linear.get_current_issue(context, opts) do
      case get_in(issue, ["state", "name"]) do
        @merging_state -> :ok
        state_name -> {:error, {:issue_not_in_merging_state, state_name}}
      end
    end
  end

  defp squash_merge_pull_request(pr, pr_url, context, opts) do
    with {:ok, ci_status} <- PullRequest.fetch_ci_status(pr_url, github_opts(context, opts)),
         :ok <- require_passing_checks(ci_status),
         {:ok, head_sha} <- head_commit_sha(ci_status),
         {:ok, _output} <-
           PullRequest.run_gh(
             [
               "pr",
               "merge",
               pr_url,
               "--squash",
               "--match-head-commit",
               head_sha,
               "--subject",
               to_string(Map.get(pr, "title")),
               "--body",
               to_string(Map.get(pr, "body"))
             ],
             github_opts(context, opts)
           ) do
      {:ok, %{"url" => pr_url, "merged" => true, "already_merged" => false, "head_sha" => head_sha}}
    end
  end

  defp require_passing_checks(%{checks: []}), do: :ok

  defp require_passing_checks(ci_status) do
    case CiPoller.ci_action(ci_status) do
      :success -> :ok
      outcome -> {:error, {:checks_not_passing, outcome}}
    end
  end

  defp head_commit_sha(%{commit_sha: head_sha}) when is_binary(head_sha) and head_sha != "", do: {:ok, head_sha}
  defp head_commit_sha(_ci_status), do: {:error, :missing_head_commit_sha}

  defp view_current_pull_request(context, opts) do
    with {:ok, origin_repo} <- origin_repo(context),
         {:ok, branch} <- current_branch(context, opts),
         {:ok, output} <-
           PullRequest.run_gh(
             ["pr", "view", branch, "--repo", origin_repo, "--json", @pr_view_fields],
             github_opts(context, opts)
           ),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      {:ok, pr}
    else
      {:ok, _decoded} -> {:error, :invalid_pull_request_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pull_request_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp origin_repo(context) do
    command_security = command_security(context)
    repo = Map.get(command_security, :origin_gh_repo) || Map.get(command_security, :origin_repo)

    case repo do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _missing -> {:error, :missing_github_origin_repo}
    end
  end

  defp current_branch(context, opts) do
    case captured_current_branch(context) do
      {:ok, branch} ->
        {:ok, branch}

      {:error, _reason} = error ->
        error

      :missing ->
        current_branch_from_workspace(context, opts)
    end
  end

  defp captured_current_branch(context) do
    case command_security(context) |> Map.get(:current_branch) do
      branch when is_binary(branch) ->
        normalize_branch(branch)

      _missing ->
        :missing
    end
  end

  defp current_branch_from_workspace(context, opts) do
    with {:ok, workspace} <- workspace(context),
         {:ok, output} <- run_git(["branch", "--show-current"], workspace, opts) do
      normalize_branch(output)
    end
  end

  defp normalize_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> {:error, :missing_current_branch}
      "HEAD" -> {:error, :detached_head}
      branch -> {:ok, branch}
    end
  end

  defp workspace(context) do
    workspace = Map.get(context, :workspace) || Map.get(command_security(context), :workspace)

    cond do
      is_binary(workspace) and File.dir?(workspace) -> {:ok, workspace}
      is_binary(workspace) -> {:error, :workspace_not_found}
      true -> {:error, :missing_workspace}
    end
  end

  defp command_security(context) when is_map(context), do: Map.get(context, :command_security) || %{}
  defp command_security(_context), do: %{}

  defp ssh_worker?(context) do
    case Map.get(command_security(context), :worker_host) do
      worker_host when is_binary(worker_host) and worker_host != "" -> true
      _worker_host -> false
    end
  end

  defp verify_current_origin(context, workspace, opts) do
    expected_origin_url = Map.get(command_security(context), :origin_url)

    with expected when is_binary(expected) and expected != "" <- expected_origin_url,
         {:ok, current_origin_url} <- current_origin_url(workspace, opts),
         true <- normalize_git_url(current_origin_url) == normalize_git_url(expected) do
      :ok
    else
      _reason -> {:error, :origin_url_mismatch}
    end
  end

  # `remote get-url --push --all` resolves `pushurl`, `pushInsteadOf` and `insteadOf`
  # the same way `git push` does, so a planted rewrite cannot redirect the push.
  defp verify_push_urls(context, workspace, opts) do
    expected = context |> command_security() |> Map.get(:origin_url) |> normalize_git_url()

    with {:ok, output} <- run_git(["remote", "get-url", "--push", "--all", "origin"], workspace, opts),
         [_ | _] = push_urls <- String.split(output, "\n", trim: true),
         true <- Enum.all?(push_urls, &(normalize_git_url(&1) == expected)) do
      :ok
    else
      _reason -> {:error, :origin_url_mismatch}
    end
  end

  # Under the per-repo fetch lock, which retries a fetch that fails on `cannot lock ref`.
  defp run_fetch_origin(workspace, opts) do
    fetch = fn ->
      case run_git(["fetch", "origin"], workspace, opts) do
        {:error, {:git_failed, ["fetch", "origin"], status, output}} -> {output, status}
        result -> result
      end
    end

    case Fetcher.fetch(workspace, fetch) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:git_fetch_failed, status, sanitize_git_output(output)}}
    end
  end

  # A repository whose remote has no base branch can't tell the branch's own changes apart, so the
  # push goes ahead as it did before the check existed.
  defp verify_push_protected_paths(context, workspace, branch, opts) do
    case remote_heads(context, workspace, branch, opts) do
      {:ok, heads} ->
        with {:ok, _output} <- run_fetch_origin(workspace, opts) do
          ProtectedPaths.verify(heads.base_sha, "refs/heads/#{branch}", heads.branch_sha, &run_git(&1, workspace, opts))
        end

      {:error, {:base_branch_not_found, _base_ref}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read from the remote itself: the agent can rewrite its own `refs/remotes/origin/*`.
  defp remote_heads(context, workspace, branch, opts) do
    with {:ok, base} <- base_branch(context, workspace, opts),
         {:ok, output} <- run_git(["ls-remote", "origin", "refs/heads/#{base}", "refs/heads/#{branch}"], workspace, opts) do
      heads = for line <- String.split(output, "\n", trim: true), [sha, ref] <- [String.split(line, "\t")], into: %{}, do: {ref, sha}

      case Map.fetch(heads, "refs/heads/#{base}") do
        {:ok, base_sha} -> {:ok, %{base_ref: "origin/#{base}", base_sha: base_sha, branch_sha: Map.get(heads, "refs/heads/#{branch}")}}
        :error -> {:error, {:base_branch_not_found, "origin/#{base}"}}
      end
    end
  end

  defp base_branch(context, workspace, opts) do
    case Config.repo_base_branch(issue_repo_key(context)) do
      {:ok, branch} when is_binary(branch) and branch != "" -> {:ok, branch}
      _none -> remote_default_branch(workspace, opts)
    end
  end

  # Without a configured base branch, a new workspace branch starts from the remote's HEAD.
  defp remote_default_branch(workspace, opts) do
    with {:ok, output} <- run_git(["ls-remote", "--symref", "origin", "HEAD"], workspace, opts) do
      case Regex.run(~r{^ref: refs/heads/(\S+)\tHEAD$}m, output) do
        [_line, branch] -> {:ok, branch}
        nil -> {:ok, "main"}
      end
    end
  end

  defp refuse_merge_in_progress(workspace, opts) do
    if merge_in_progress?(workspace, opts), do: {:error, :merge_in_progress}, else: :ok
  end

  defp merge_in_progress?(workspace, opts) do
    match?({:ok, _sha}, run_git(["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], workspace, opts))
  end

  # Pulls in what was pushed to the branch since (a base-branch update GitHub made, say). A branch
  # with local commits its remote copy lacks, or with no remote copy, stays as it is.
  defp fast_forward_to_remote_branch(_workspace, nil, _opts), do: :ok

  defp fast_forward_to_remote_branch(workspace, branch_sha, opts) do
    case run_git(["merge-base", "--is-ancestor", "HEAD", branch_sha], workspace, opts) do
      {:ok, _output} ->
        with {:ok, _output} <- run_merge(["merge", "--ff-only", branch_sha], workspace, opts), do: :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp merge_base_ref(workspace, branch, %{base_ref: base_ref, base_sha: base_sha}, opts) do
    message = "Merge #{base_ref} into #{branch}"

    case run_merge(["merge", "--no-commit", "-m", message, base_sha], workspace, opts) do
      {:error, {:git_merge_failed, _status, output}} = error ->
        if merge_in_progress?(workspace, opts), do: merge_result(workspace, base_ref, output, opts), else: error

      {:ok, output} ->
        merge_result(workspace, base_ref, output, opts)

      error ->
        error
    end
  end

  defp run_merge(args, workspace, opts) do
    case run_git(@merge_config ++ args, workspace, opts) do
      {:error, {:git_failed, _args, status, output}} ->
        {:error, {:git_merge_failed, status, sanitize_git_output(output)}}

      result ->
        result
    end
  end

  defp merge_result(workspace, base_ref, output, opts) do
    with {:ok, head} <- run_git(["rev-parse", "HEAD"], workspace, opts),
         {:ok, conflicts} <- run_git(["diff", "--name-only", "--diff-filter=U"], workspace, opts) do
      conflicts = String.split(conflicts, "\n", trim: true)
      status = merge_status(merge_in_progress?(workspace, opts), conflicts)

      {:ok,
       %{
         "base" => base_ref,
         "status" => status,
         "head" => String.trim(head),
         "conflicts" => conflicts,
         "message" => merge_message(status, base_ref),
         "output" => output |> sanitize_git_output() |> String.trim()
       }}
    end
  end

  defp merge_status(false, _conflicts), do: "synced"
  defp merge_status(true, []), do: "merge_staged"
  defp merge_status(true, _conflicts), do: "conflicts"

  defp merge_message("synced", base_ref), do: "The branch contains #{base_ref}; there is nothing to commit."
  defp merge_message("merge_staged", base_ref), do: "#{base_ref} merged without conflicts. Run `git commit --no-edit` to record the merge."

  defp merge_message("conflicts", base_ref) do
    "Merging #{base_ref} left conflicts in the listed files. Resolve them, `git add` them, then run " <>
      "`git -c rerere.enabled=true commit --no-edit` so rerere records the resolution."
  end

  defp current_origin_url(workspace, opts) do
    with {:ok, output} <- run_git(["remote", "get-url", "origin"], workspace, opts),
         origin_url when is_binary(origin_url) <- output |> String.trim() |> blank_to_nil() do
      {:ok, origin_url}
    else
      _reason -> {:error, :origin_url_unavailable}
    end
  end

  defp normalize_git_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.downcase()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp require_string(value, _reason) when is_binary(value), do: {:ok, value}
  defp require_string(_value, reason), do: {:error, reason}

  defp require_comment_id(value) when is_integer(value) and value > 0, do: {:ok, Integer.to_string(value)}

  defp require_comment_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_comment_id}
      trimmed -> if String.match?(trimmed, ~r/^\d+$/), do: {:ok, trimmed}, else: {:error, :invalid_comment_id}
    end
  end

  defp require_comment_id(_value), do: {:error, :invalid_comment_id}

  # An explicit boolean from the caller always wins. When the caller omits `draft`
  # (nil) — e.g. the agent's prompt was compacted and never carried the draft
  # directive — fall back to the repo's configured default so PR review-state does
  # not silently depend on prompt survival.
  defp resolve_draft(value, _opts) when is_boolean(value), do: {:ok, value}
  defp resolve_draft(nil, opts), do: {:ok, default_open_pr_as_draft(opts)}
  defp resolve_draft(_value, _opts), do: {:error, :invalid_draft}

  defp default_open_pr_as_draft(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings.github.open_pull_requests_as_draft
      _settings -> Config.settings!().github.open_pull_requests_as_draft
    end
  end

  # The issue's repository's WORKFLOW.md owns `push_check`.
  defp push_check_settings(context, opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings ->
        {:ok, settings.push_check}

      _settings ->
        with {:ok, settings} <- Config.settings_for_repo(issue_repo_key(context)) do
          {:ok, settings.push_check}
        end
    end
  end

  defp issue_repo_key(%{issue: %{repo_key: repo_key}}) when is_binary(repo_key), do: repo_key
  defp issue_repo_key(_context), do: nil

  defp draft_args(true), do: ["--draft"]
  defp draft_args(false), do: []

  defp github_opts(context, opts) do
    opts
    |> Keyword.put_new(:cwd, Map.get(context, :workspace))
  end

  defp status_checks(%{checks: checks}) when is_list(checks), do: Enum.filter(checks, &is_map/1)

  defp latest_failed_check(checks) do
    checks
    |> Enum.filter(&failed_check?/1)
    |> Enum.find_value(&failed_check_with_run_id/1)
    |> case do
      nil -> {:error, :no_failed_github_actions_run}
      result -> result
    end
  end

  defp failed_check?(check) when is_map(check) do
    case Map.get(check, :conclusion) || Map.get(check, "conclusion") do
      conclusion when is_binary(conclusion) ->
        MapSet.member?(@failed_conclusions, normalize_status_value(conclusion))

      _missing ->
        false
    end
  end

  defp failed_check_with_run_id(check) do
    case Map.get(check, :run_id) || Map.get(check, "run_id") do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, check, run_id}
      _missing -> nil
    end
  end

  defp normalize_status_value(value) when is_binary(value), do: value |> String.trim() |> String.upcase()

  defp failed_run_log_max_bytes(opts) do
    case Keyword.get(opts, :failed_run_log_max_bytes) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      nil ->
        {:ok, settings_failed_run_log_max_bytes(opts)}

      _invalid ->
        {:error, :invalid_failed_run_log_max_bytes}
    end
  end

  defp settings_failed_run_log_max_bytes(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings.github.failed_run_log_max_bytes
      _settings -> Config.settings!().github.failed_run_log_max_bytes
    end
  end

  defp clamp_log(log, max_bytes) when is_binary(log) and byte_size(log) > max_bytes do
    {take_valid_prefix(log, max_bytes), true}
  end

  defp clamp_log(log, _max_bytes) when is_binary(log), do: {log, false}

  defp take_valid_prefix(log, max_bytes) do
    prefix = binary_part(log, 0, min(byte_size(log), max_bytes))

    if String.valid?(prefix) do
      prefix
    else
      take_valid_prefix(log, max_bytes - 1)
    end
  end

  defp sanitize_git_output(output) do
    output
    |> IO.iodata_to_binary()
    |> redact_home_path()
    |> clamp_valid_output(@max_git_output_bytes)
  end

  defp redact_home_path(output) do
    :binary.replace(output, Path.expand("~"), "~", [:global])
  end

  defp clamp_valid_output(output, max_bytes) when byte_size(output) <= max_bytes do
    valid_output_prefix(output, byte_size(output))
  end

  defp clamp_valid_output(output, max_bytes) do
    valid_output_prefix(output, max_bytes) <> "... (truncated)"
  end

  defp valid_output_prefix(output, max_bytes) do
    prefix = binary_part(output, 0, min(byte_size(output), max_bytes))

    if String.valid?(prefix) do
      prefix
    else
      valid_output_prefix(output, max_bytes - 1)
    end
  end

  defp run_git(args, workspace, opts) do
    cmd_opts = [stderr_to_stdout: true, cd: workspace]

    case git_runner(opts).(args, cmd_opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp git_runner(opts) do
    case Keyword.get(opts, :git_runner) do
      runner when is_function(runner, 2) -> runner
      _ -> &Workspace.safe_git/2
    end
  end
end
