defmodule SymphonyElixir.Harnesses.ToolSession do
  @moduledoc """
  Starts the session of Symphony's own tools (`SymphonyElixir.McpServer`) that a harness's
  agent reaches over MCP: the ticket and pull-request tools, scoped to the run's issue and
  workspace. Every launcher starts one per agent session and stops it with
  `SymphonyElixir.McpServer.stop_session/1`.
  """

  alias SymphonyElixir.{DependencyGate, McpServer}
  alias SymphonyElixir.GitHub.Hosts

  @doc """
  Starts the tool session for an agent in `workspace`, on `worker_host` (nil for this host).
  `opts` are the launcher's: the issue, the run, the tool scope and the clients the tools use.
  """
  @spec start(Path.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def start(workspace, worker_host, opts) do
    issue = Keyword.get(opts, :issue)

    context = %{
      issue: issue,
      issue_id: Keyword.get(opts, :issue_id),
      workspace: workspace,
      command_security: command_security_context(workspace, worker_host),
      comment_registry: Keyword.get(opts, :linear_comment_registry),
      tool_scope: Keyword.get(opts, :tool_scope),
      tool_opts: tool_opts(opts),
      dependency_gate: DependencyGate.build(workspace, issue, Keyword.get(opts, :settings), opts),
      on_tool_call: Keyword.get(opts, :on_tool_call)
    }

    mcp_opts =
      [
        run_id: Keyword.get(opts, :run_id),
        server: Keyword.get(opts, :mcp_server, McpServer),
        shim_path: Keyword.get(opts, :mcp_shim_path),
        worker_host: worker_host
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    McpServer.start_session(context, mcp_opts)
  end

  defp tool_opts(opts) do
    opts
    |> Keyword.take([
      :linear_client,
      :upload_client,
      :gh_runner,
      :git_runner,
      :settings,
      :tool_scope,
      :qa_driver,
      :qa_android_driver,
      :unlocked_paths,
      :review_verdict_sink,
      :qa_verdict_sink,
      :repo_key,
      :run_id,
      :run_kind,
      :run_profile,
      :agent_tmp_dir
    ])
  end

  defp command_security_context(workspace, worker_host) do
    origin_url = discover_origin_url(workspace, worker_host)

    %{
      origin_url: origin_url,
      origin_repo: github_repo_from_url(origin_url),
      origin_gh_repo: github_gh_repo_from_url(origin_url),
      workspace: workspace,
      worker_host: worker_host
    }
  end

  defp discover_origin_url(workspace, nil) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           SymphonyElixir.Workspace.safe_git(git, ["-C", workspace, "remote", "get-url", "origin"]) do
      output |> String.trim() |> blank_to_nil()
    else
      _result -> nil
    end
  end

  defp discover_origin_url(_workspace, worker_host) when is_binary(worker_host), do: nil

  defp github_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {_host, owner, repo} -> "#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_repo_from_url(_url), do: nil

  defp github_gh_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {"github.com", owner, repo} -> "#{owner}/#{repo}"
      {host, owner, repo} when is_binary(host) -> "#{host}/#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_gh_repo_from_url(_url), do: nil

  defp github_repo_parts_from_url(url) when is_binary(url) do
    Enum.find_value(
      [
        ~r{^https?://([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^ssh://[^@]+@([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^(?:[^@]+@)?([^/:]+):([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^([^/\s:]*github[^/\s:]*)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}
      ],
      fn regex ->
        case Regex.run(regex, url) do
          [_full, host, owner, repo] -> canonical_github_repo_parts(host, owner, repo)
          _ -> nil
        end
      end
    )
  end

  defp canonical_github_repo_parts(host, owner, repo) do
    case Hosts.canonical_github_host(host) do
      {:ok, canonical_host} -> {canonical_host, owner, repo}
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end
end
