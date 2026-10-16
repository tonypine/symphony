defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Repo, as: GitHubRepo

  @shortdoc "Close open GitHub PRs for the current branch before workspace removal"

  @moduledoc """
  Closes open pull requests for the branch supplied by Symphony.

  This task is intended for use from the `before_remove` workspace hook.

  Repo and branch precedence: `SYMPHONY_REPO` / `SYMPHONY_BRANCH`, then the
  matching `--repo` / `--branch` flags for manual invocation.

  It closes them only when the ticket ended: Symphony sets `SYMPHONY_REMOVE_REASON` to `terminal`
  and names the state in `SYMPHONY_ISSUE_STATE`, which the closing comment quotes. Any other reason
  (`stop`, `cleanup`) keeps them open. A manual run, without the variable, closes them.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --repo owner/repo --branch feature/my-branch
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        repo = configured_value("SYMPHONY_REPO", opts[:repo])
        branch = configured_value("SYMPHONY_BRANCH", opts[:branch])

        if terminal_removal?() do
          maybe_close_open_pull_requests(repo, branch, present_string(System.get_env("SYMPHONY_ISSUE_STATE")))
        end

        :ok
    end
  end

  defp terminal_removal? do
    present_string(System.get_env("SYMPHONY_REMOVE_REASON")) in [nil, "terminal"]
  end

  defp configured_value(env_key, flag_value) do
    [System.get_env(env_key), flag_value]
    |> Enum.find_value(&present_string/1)
  end

  defp maybe_close_open_pull_requests(_repo, nil, _issue_state), do: :ok
  defp maybe_close_open_pull_requests(nil, _branch, _issue_state), do: :ok

  defp maybe_close_open_pull_requests(repo, branch, issue_state) do
    if configured_repo?(repo) and gh_available?() and gh_authenticated?() do
      repo
      |> list_open_pull_request_numbers(branch)
      |> Enum.each(&close_pull_request(repo, branch, issue_state, &1))
    end

    :ok
  end

  defp configured_repo?(repo) do
    case configured_github_repos() do
      {:ok, []} ->
        refuse_unconfigured_repo(repo, [])

      {:ok, repos} ->
        Enum.any?(repos, &GitHubRepo.same?(&1, repo)) ||
          refuse_unconfigured_repo(repo, repos)

      {:error, _reason} ->
        refuse_unconfigured_repo(repo, [])
    end
  end

  defp refuse_unconfigured_repo(repo, repos) do
    Mix.shell().error("Refusing to close PRs for unconfigured repo #{repo}; configured repos: #{Enum.join(repos, ", ")}")
    false
  end

  defp configured_github_repos do
    with {:ok, system_config} <- Config.system() do
      repos =
        system_config.repos
        |> Enum.flat_map(&configured_repo_paths(&1, system_config.workspace))
        |> Enum.map(&github_repo_from_git_origin/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&String.downcase/1)

      {:ok, repos}
    end
  end

  defp configured_repo_paths(repo, workspace) do
    [
      Map.get(repo, :path),
      repo_workspace_path(repo),
      workspace_repo_path(workspace),
      Config.settings_for_repo!(repo.name).workspace.repo
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  rescue
    _error ->
      [Map.get(repo, :path), repo_workspace_path(repo), workspace_repo_path(workspace)]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp repo_workspace_path(repo), do: repo |> Map.get(:workspace) |> workspace_repo_path()

  defp workspace_repo_path(workspace), do: if(is_map(workspace), do: Map.get(workspace, :repo), else: nil)

  defp github_repo_from_git_origin(path) when is_binary(path) do
    GitHubRepo.from_url(path) || github_repo_from_git_dir(path)
  end

  defp github_repo_from_git_dir(path) do
    case run_command("git", ["-C", Path.expand(path), "remote", "get-url", "origin"]) do
      {:ok, output} ->
        output
        |> String.trim()
        |> GitHubRepo.from_url()

      {:error, _reason} ->
        nil
    end
  end

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request(repo, branch, issue_state, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch, issue_state)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch, nil) do
    "Closing because the Linear issue for branch #{branch} entered a terminal state without merge."
  end

  defp closing_comment(branch, issue_state) do
    "Closing because the Linear issue for branch #{branch} moved to #{issue_state} without merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp present_string(_value), do: nil

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
