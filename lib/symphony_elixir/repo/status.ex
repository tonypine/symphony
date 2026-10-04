defmodule SymphonyElixir.Repo.Status do
  @moduledoc """
  What Symphony knows about each repo in `repositories:`, for `GET /api/v1/repos`.

  One entry per repo, in config order: its routing, where its code comes from (a
  local checkout, or the clone Symphony keeps of a `workspace.source` repo), its
  GitHub repository, whether its `WORKFLOW.md` loads, its last fetch before a
  dispatch and the worktrees its running agents use.

  Error messages are cut to a length and have tokens, API keys and the user part
  of URLs replaced, so a git error that echoes a remote URL leaks no credential.
  """

  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.{Config, ManagedClone, Workflow, WorkflowSource, WorkflowStore, Workspace}
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.GitHub.Repo, as: GitHubRepo
  alias SymphonyElixir.Repo.{FetchLog, Supervisor}

  @max_message_chars 2_000
  @url_userinfo ~r{(://)[^/@\s]+@}

  @doc """
  Lists every configured repo. `running` is the orchestrator snapshot's running
  entries; an entry without a repo key belongs to the primary repo.
  """
  @spec list([map()]) :: {:ok, [map()]} | {:error, term()}
  def list(running) when is_list(running) do
    with {:ok, system_config} <- Config.system() do
      primary = SystemSchema.primary_repo(system_config)
      worktrees = Enum.group_by(running, &(Map.get(&1, :repo_key) || primary.name))

      {:ok, Enum.map(system_config.repos, &entry(&1, system_config, Map.get(worktrees, &1.name, [])))}
    end
  end

  @doc """
  The GitHub repository of a configured repo as `list/1` reports it (`owner/repo`, or
  `host/owner/repo` off github.com), or nil when it has none.
  """
  @spec github_repo(SystemSchema.Repo.t()) :: String.t() | nil
  def github_repo(%SystemSchema.Repo{} = repo), do: github(repo, Config.system!())

  defp entry(%SystemSchema.Repo{} = repo, system_config, running) do
    %{
      key: repo.name,
      default: repo.default,
      base_branch: repo.base_branch,
      source: source(repo, system_config),
      github: github(repo, system_config),
      routing: %{team: repo.team, projects: repo.projects, labels: repo.labels, assignee: repo.assignee},
      workflow: workflow(repo),
      last_fetch: last_fetch(repo.name),
      worktrees: Enum.map(running, &worktree/1)
    }
  end

  defp source(%SystemSchema.Repo{workspace: %{github: github, repo: clone}}, _system_config) when is_binary(github) do
    %{kind: "managed", github: github, clone_path: clone, cloned: ManagedClone.cloned?(clone)}
  end

  defp source(repo, system_config), do: %{kind: "local", path: local_path(repo, system_config)}

  # The checkout worktrees are made from (the repo's own `workspace.repo`, else the
  # shared one), else the repo's `path`, else the folder holding its `WORKFLOW.md`.
  defp local_path(repo, system_config) do
    [repo_workspace_repo(repo), system_config.workspace.repo, repo.path]
    |> Enum.find(&present?/1)
    |> case do
      nil -> repo |> SystemSchema.repo_workflow_path() |> Path.dirname()
      path -> Path.expand(path)
    end
  end

  defp repo_workspace_repo(%SystemSchema.Repo{workspace: %{repo: repo}}), do: repo
  defp repo_workspace_repo(_repo), do: nil

  defp github(%SystemSchema.Repo{workspace: %{github: github}}, _system_config) when is_binary(github), do: github

  defp github(repo, system_config) do
    path = local_path(repo, system_config)

    case Workspace.safe_git(["-C", path, "remote", "get-url", "origin"]) do
      {url, 0} -> GitHubRepo.gh_repo_from_url(String.trim(url), github_enterprise_hosts: system_config.github.enterprise_hosts)
      {_output, _status} -> nil
    end
  end

  defp workflow(repo) do
    status =
      case WorkflowStore.status(Supervisor.workflow_store_name(repo.name)) do
        {:ok, status} -> status
        :unavailable -> load_workflow(repo)
      end
      |> with_ref_error(repo)

    %{
      path: status.path,
      found: status.status != :missing,
      status: Atom.to_string(status.status),
      error: status.error && status.error |> workflow_error() |> safe_message()
    }
  end

  # The store reads the last good snapshot while the workflow on the base branch
  # does not load, so it says valid: report the ref's error instead.
  defp with_ref_error(%{status: :valid} = status, repo) do
    case WorkflowSource.ref_error(repo) do
      nil -> status
      reason -> %{status | status: ref_status(reason), error: {:workflow_ref_error, reason}}
    end
  end

  defp with_ref_error(status, _repo), do: status

  defp ref_status({:git_failed, _args, _status, _output}), do: :missing
  defp ref_status({:workflow_ref_not_found, _refs}), do: :missing
  defp ref_status(_reason), do: :invalid

  defp workflow_error({:workflow_ref_error, reason}),
    do: "WORKFLOW.md on the base branch does not load, so Symphony keeps the last good workflow: #{ref_error(reason)}"

  defp workflow_error(reason), do: Config.format_error(reason)

  defp ref_error({:git_failed, _args, _status, _output} = reason), do: fetch_error(reason)
  defp ref_error({:workflow_ref_not_found, refs}), do: "no #{Enum.join(refs, ", ")} ref in the checkout"
  defp ref_error(reason), do: Config.format_error(reason)

  # A repo whose store is not running (it was added after startup) reads its file.
  defp load_workflow(repo) do
    path = WorkflowSource.read_path(repo)

    case Workflow.load(path) do
      {:ok, _workflow} -> %{path: path, status: :valid, error: nil}
      {:error, reason} -> %{path: path, status: WorkflowStore.load_status(reason), error: reason}
    end
  end

  defp last_fetch(repo_key) do
    case FetchLog.last(repo_key) do
      nil -> nil
      %{at: at, result: :ok} -> %{at: iso8601(at), result: "ok", error: nil}
      %{at: at, result: {:error, reason}} -> %{at: iso8601(at), result: "error", error: safe_message(fetch_error(reason))}
    end
  end

  defp fetch_error({:managed_clone_failed, _repo_key, {step, {:git_failed, status, output}}}),
    do: git_failure("git #{step}", status, output)

  defp fetch_error({{:git_failed, _repo, args, status}, output}), do: git_failure(Enum.join(["git" | args], " "), status, output)
  defp fetch_error({:git_failed, args, status, output}), do: git_failure(Enum.join(["git" | args], " "), status, output)
  defp fetch_error(reason), do: inspect(reason)

  defp git_failure(command, status, output), do: "#{command} exited with status #{status}: #{String.trim(output)}"

  defp worktree(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      path: Map.get(entry, :workspace_path),
      worker_host: Map.get(entry, :worker_host)
    }
  end

  defp safe_message(message) when is_binary(message) do
    {message, _patterns} = message |> String.replace(@url_userinfo, "\\1[REDACTED]@") |> SecretScanner.redact()
    String.slice(message, 0, @max_message_chars)
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
