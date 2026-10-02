defmodule SymphonyElixir.WorkflowSource do
  @moduledoc """
  Resolves where a repo's `WORKFLOW.md` is read from.

  With `workflow_source: ref` (the default) the workflow is read from the fetched
  remote base branch (`origin/<base_branch>`) of the git checkout that holds the
  configured workflow file, so uncommitted or unpulled edits in that checkout never
  reach a run. The committed content is copied into a snapshot under the Symphony
  state root, and the config cache and workflow stores watch that snapshot.

  The snapshot is only replaced with content that parses, so a missing or invalid
  `WORKFLOW.md` on the ref logs an error and keeps the last known good workflow.

  With `workflow_source: local`, or when the workflow file is not inside a git
  checkout, the configured file is read directly. The configured file is also read
  directly, with a warning, while no snapshot has been written yet, for example in
  a checkout with no `origin` remote or no resolvable base branch ref.
  """

  require Logger

  alias SymphonyElixir.Config.{Cache, SystemSchema}
  alias SymphonyElixir.{Paths, Workflow, Workspace}

  @default_branch_refs ["origin/HEAD", "origin/main", "origin/master"]

  @type refresh_result :: :ok | :unchanged | :skipped | {:error, term()}

  @doc """
  Returns the path the workflow loaders read for `repo`: the ref snapshot once one
  has been written, otherwise the configured file.
  """
  @spec read_path(SystemSchema.Repo.t()) :: Path.t()
  def read_path(%SystemSchema.Repo{} = repo) do
    local_path = SystemSchema.repo_workflow_path(repo)

    with {:ok, _checkout} <- ref_checkout(repo, local_path),
         snapshot = snapshot_path(repo, local_path),
         true <- File.regular?(snapshot) do
      snapshot
    else
      _ -> local_path
    end
  end

  @doc """
  Copies the committed `WORKFLOW.md` from the remote base branch into the repo's
  snapshot.

  Options:

    * `:fetch` - run `git fetch origin` in the checkout first (default `false`).
    * `:fetched_repo` - a checkout already fetched for this dispatch; the fetch is
      skipped when it is the workflow checkout.
  """
  @spec refresh(SystemSchema.Repo.t(), keyword()) :: refresh_result()
  def refresh(%SystemSchema.Repo{} = repo, opts \\ []) do
    local_path = SystemSchema.repo_workflow_path(repo)

    case ref_checkout(repo, local_path) do
      {:ok, checkout} ->
        maybe_fetch(repo, checkout, opts)
        refresh_snapshot(repo, checkout, local_path)

      :local ->
        :skipped
    end
  end

  @doc """
  Refreshes every configured repo's snapshot without fetching.
  """
  @spec refresh_all(SystemSchema.t()) :: :ok
  def refresh_all(%SystemSchema{repos: repos}) do
    Enum.each(repos, &refresh/1)
  end

  defp ref_checkout(%SystemSchema.Repo{workflow_source: "local"}, _local_path), do: :local

  defp ref_checkout(%SystemSchema.Repo{}, local_path) do
    case git_checkout_root(Path.dirname(local_path)) do
      nil -> :local
      checkout -> {:ok, checkout}
    end
  end

  defp git_checkout_root(dir) do
    cond do
      File.exists?(Path.join(dir, ".git")) -> dir
      Path.dirname(dir) == dir -> nil
      true -> git_checkout_root(Path.dirname(dir))
    end
  end

  defp snapshot_path(%SystemSchema.Repo{name: name}, local_path) do
    Path.join([Paths.state_root(), "workflows", Workspace.safe_identifier(name), Path.basename(local_path)])
  end

  defp maybe_fetch(repo, checkout, opts) do
    fetched_repo = Keyword.get(opts, :fetched_repo)

    if Keyword.get(opts, :fetch, false) and not same_checkout?(checkout, fetched_repo) do
      case git(checkout, ["fetch", "origin"]) do
        {:ok, _output} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to fetch workflow checkout repo=#{repo.name} checkout=#{checkout} reason=#{inspect(reason)}; reading the last fetched ref")
      end
    end
  end

  defp same_checkout?(_checkout, nil), do: false
  defp same_checkout?(checkout, fetched_repo), do: Path.expand(fetched_repo) == checkout

  defp refresh_snapshot(repo, checkout, local_path) do
    workflow_in_repo = Path.relative_to(local_path, checkout)
    snapshot = snapshot_path(repo, local_path)

    with {:ok, ref} <- base_ref(repo, checkout),
         {:ok, content} <- git(checkout, ["show", "#{ref}:#{workflow_in_repo}"]),
         {:ok, _workflow} <- Workflow.parse_repo_workflow(content) do
      write_snapshot(snapshot, content)
    else
      {:error, reason} ->
        log_refresh_error(repo, checkout, workflow_in_repo, snapshot, reason)
        {:error, reason}
    end
  end

  defp log_refresh_error(repo, checkout, workflow_in_repo, snapshot, reason) do
    if File.regular?(snapshot) do
      Logger.error("Failed to load workflow from ref repo=#{repo.name} checkout=#{checkout} workflow=#{workflow_in_repo} reason=#{inspect(reason)}; keeping last known good workflow")
    else
      Logger.warning(
        "Failed to load workflow from ref repo=#{repo.name} checkout=#{checkout} workflow=#{workflow_in_repo} reason=#{inspect(reason)}; reading the local workflow file until the ref resolves (set workflow_source: local to silence this)"
      )
    end
  end

  defp base_ref(%SystemSchema.Repo{base_branch: base_branch}, checkout) do
    candidates =
      case sanitize_branch(base_branch) do
        nil -> @default_branch_refs
        branch -> ["origin/#{branch}"]
      end

    case Enum.find(candidates, &ref_exists?(checkout, &1)) do
      nil -> {:error, {:workflow_ref_not_found, candidates}}
      ref -> {:ok, ref}
    end
  end

  defp sanitize_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "origin/" <> name -> name
      "refs/heads/" <> name -> name
      name -> name
    end
  end

  defp sanitize_branch(_branch), do: nil

  defp ref_exists?(checkout, ref) do
    match?({:ok, _output}, git(checkout, ["rev-parse", "--verify", "--quiet", "--end-of-options", "#{ref}^{commit}"]))
  end

  defp write_snapshot(snapshot, content) do
    if File.read(snapshot) == {:ok, content} do
      :unchanged
    else
      File.mkdir_p!(Path.dirname(snapshot))
      tmp = "#{snapshot}.#{System.unique_integer([:positive])}.tmp"
      File.write!(tmp, content)
      File.rename!(tmp, snapshot)
      Cache.invalidate(snapshot)
      :ok
    end
  end

  defp git(checkout, args) do
    case Workspace.safe_git(["-C", checkout | args]) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  end
end
