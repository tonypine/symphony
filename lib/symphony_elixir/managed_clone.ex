defmodule SymphonyElixir.ManagedClone do
  @moduledoc """
  Keeps Symphony's own clone of a repo configured with
  `repositories[].workspace.source`.

  The clone lives at `<workspaces.clones_root>/<owner>/<repo>`, by default under
  `~/.local/share/symphony/repos`. The agent sandbox denies no part of that folder,
  so an agent can run git in a worktree whose `.git` points into the clone. It is a
  `--no-checkout` clone: agent worktrees are created from it and the repo's
  `WORKFLOW.md` is read from its fetched ref, so it needs no working tree of its
  own. The engineer's own checkout of the repo is never read or written.

  Cloning and fetching hold a lock per clone, so concurrent dispatches for the same
  repo never race on the first clone or on a fetch. A failed clone leaves nothing
  behind: the clone is made in a temporary folder next to the final one and renamed
  into place once it is complete.
  """

  require Logger

  alias SymphonyElixir.GitHub.Repo, as: GitHubRepo
  alias SymphonyElixir.Workspace

  @default_root "~/.local/share/symphony/repos"
  @default_url_base "git@github.com:"
  @output_tail_chars 2_048
  # GitHub owner names are 1-39 letters, digits and single hyphens; repo names are
  # letters, digits, `.`, `_` and `-`.
  @github_pattern ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}\z/

  @type failure :: {:managed_clone_failed, String.t(), {:clone | :fetch, term()}}

  @doc """
  The folder clones are kept under when `workspaces.clones_root` is unset.
  """
  @spec default_root() :: Path.t()
  def default_root, do: Path.expand(@default_root)

  @doc """
  Reads a `workspace.source` value, `owner/repo` or a github.com URL (HTTPS or SSH),
  as `owner/repo`.
  """
  @spec parse_source(term()) :: {:ok, String.t()} | :error
  def parse_source(source) when is_binary(source) do
    source = String.trim(source)
    github = if github?(source), do: source, else: GitHubRepo.gh_repo_from_url(source, github_enterprise_hosts: [])

    if github?(github), do: {:ok, github}, else: :error
  end

  def parse_source(_source), do: :error

  defp github?(value) when is_binary(value) do
    Regex.match?(@github_pattern, value) and
      Path.basename(value) not in [".", ".."] and
      not String.ends_with?(value, ".git")
  end

  defp github?(_value), do: false

  @doc """
  The clone folder for `owner/repo` under `root` (the default root when nil).
  """
  @spec path(Path.t() | nil, String.t()) :: Path.t()
  def path(root, github) when is_binary(github) do
    Path.join(Path.expand(root || @default_root), String.downcase(github))
  end

  @doc """
  The URL the clone is made from, whatever URL `workspace.source` was written as.
  Symphony clones over SSH, with the same keys the engineer's own git uses, because
  it runs git with credential helpers turned off, so an HTTPS remote could not push.
  """
  @spec clone_url(String.t()) :: String.t()
  def clone_url(github) when is_binary(github) do
    Application.get_env(:symphony_elixir, :managed_clone_url_base, @default_url_base) <> github <> ".git"
  end

  @doc """
  Makes sure the clone exists and, with `fetch: true` (the default), fetches
  `origin` into an existing clone. A fresh clone is not fetched again.

  Returns `{:error, {:managed_clone_failed, repo_key, {step, reason}}}` when the
  clone or the fetch fails.
  """
  @spec sync(String.t(), String.t(), Path.t(), keyword()) :: :ok | {:error, failure()}
  def sync(repo_key, github, clone_path, opts \\ []) when is_binary(repo_key) and is_binary(github) and is_binary(clone_path) do
    clone_path = Path.expand(clone_path)
    fetch? = Keyword.get(opts, :fetch, true)

    :global.trans(lock_id(clone_path), fn -> sync_locked(repo_key, github, clone_path, fetch?) end, [node()], :infinity)
  end

  @doc false
  @spec lock_id(Path.t()) :: {term(), pid()}
  def lock_id(clone_path), do: {{__MODULE__, Path.expand(clone_path)}, self()}

  @doc """
  Whether the clone at `clone_path` has been made.
  """
  @spec cloned?(Path.t()) :: boolean()
  def cloned?(clone_path) when is_binary(clone_path), do: File.dir?(Path.join(Path.expand(clone_path), ".git"))

  defp sync_locked(repo_key, github, clone_path, fetch?) do
    cond do
      not cloned?(clone_path) -> clone(repo_key, github, clone_path)
      fetch? -> fetch(repo_key, clone_path)
      true -> :ok
    end
  end

  defp clone(repo_key, github, clone_path) do
    tmp = "#{clone_path}.tmp-#{System.unique_integer([:positive])}"
    url = clone_url(github)

    result =
      with :ok <- mkdir_parent(clone_path),
           :ok <- git(["clone", "--quiet", "--no-checkout", url, tmp]),
           :ok <- rename(tmp, clone_path) do
        Logger.info("Cloned managed repo repo=#{repo_key} github=#{github} path=#{clone_path}")
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm_rf(tmp)
        failure(repo_key, :clone, clone_path, reason)
    end
  end

  defp fetch(repo_key, clone_path) do
    case git(["-C", clone_path, "fetch", "--quiet", "origin"]) do
      :ok -> :ok
      {:error, reason} -> failure(repo_key, :fetch, clone_path, reason)
    end
  end

  defp mkdir_parent(clone_path) do
    case File.mkdir_p(Path.dirname(clone_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, Path.dirname(clone_path), reason}}
    end
  end

  defp rename(tmp, clone_path) do
    case File.rename(tmp, clone_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, clone_path, reason}}
    end
  end

  defp git(args) do
    case Workspace.safe_git(args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_failed, status, output_tail(output)}}
    end
  end

  defp output_tail(output) do
    output
    |> String.trim()
    |> String.slice(-@output_tail_chars, @output_tail_chars)
  end

  defp failure(repo_key, step, clone_path, reason) do
    Logger.error("Managed clone #{step} failed repo=#{repo_key} path=#{clone_path} reason=#{inspect(reason)}")
    {:error, {:managed_clone_failed, repo_key, {step, reason}}}
  end
end
