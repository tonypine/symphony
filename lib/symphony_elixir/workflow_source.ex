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
  a checkout with no `origin` remote or no resolvable base branch ref. Once the ref
  resolves and the first snapshot is written, the repo's workflow store switches to
  the snapshot without a restart.

  A repo with `workspace.source` has no checkout of the engineer's: its workflow is
  read from Symphony's own clone (see `SymphonyElixir.ManagedClone`), which
  `refresh_all/1` makes at startup when it is missing.
  """

  require Logger

  alias SymphonyElixir.Config.{Cache, SystemSchema}
  alias SymphonyElixir.{ManagedClone, Paths, Workflow, Workspace}
  alias SymphonyElixir.Repo.FetchLog

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
  Loads the workflow Symphony would use for `repo` at startup, without fetching or
  writing the snapshot: the committed `WORKFLOW.md` on the remote base branch when
  it parses, otherwise the file `read_path/1` returns (the last good snapshot, or
  the configured file before the first one).
  """
  @spec load_for_check(SystemSchema.Repo.t()) :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def load_for_check(%SystemSchema.Repo{} = repo) do
    local_path = SystemSchema.repo_workflow_path(repo)

    with {:ok, checkout} <- ref_checkout(repo, local_path),
         {:ok, _content, workflow} <- ref_workflow(repo, checkout, Path.relative_to(local_path, checkout)) do
      {:ok, workflow}
    else
      _ -> Workflow.load(read_path(repo))
    end
  end

  @doc """
  Refreshes every configured repo's snapshot without fetching, after cloning a
  `workspace.source` repo that has no clone yet.

  Returns `{:error, message}` naming the repo and git's error when such a clone
  cannot be made: the repo then has no `WORKFLOW.md` to read. The other repos are
  still refreshed.
  """
  @spec refresh_all(SystemSchema.t()) :: :ok | {:error, String.t()}
  def refresh_all(%SystemSchema{repos: repos}) do
    repos
    |> Enum.map(fn repo ->
      with :ok <- clone_managed_repo(repo) do
        refresh(repo)
        :ok
      end
    end)
    |> Enum.find(:ok, &match?({:error, _message}, &1))
  end

  defp clone_managed_repo(%SystemSchema.Repo{name: name, workspace: %{github: github, repo: clone}}) when is_binary(github) do
    case ManagedClone.sync(name, github, clone, fetch: false) do
      :ok ->
        :ok

      {:error, {:managed_clone_failed, _repo_key, {_step, reason}}} ->
        {:error,
         "Could not clone repo #{name} from #{ManagedClone.clone_url(github)} into #{clone}: " <>
           "#{ManagedClone.describe_reason(reason)}\nSymphony reads the repo's WORKFLOW.md from this clone, so it cannot start without it."}
    end
  end

  defp clone_managed_repo(_repo), do: :ok

  defp ref_checkout(%SystemSchema.Repo{workflow_source: "local"}, _local_path), do: :local

  # Never look above Symphony's own clone for a checkout, even before it exists.
  defp ref_checkout(%SystemSchema.Repo{workspace: %{github: github, repo: clone}}, _local_path) when is_binary(github),
    do: {:ok, clone}

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
      case FetchLog.record(repo.name, git(checkout, ["fetch", "origin"])) do
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

    case ref_workflow(repo, checkout, workflow_in_repo) do
      {:ok, content, _workflow} ->
        first_snapshot? = not File.regular?(snapshot)
        result = write_snapshot(snapshot, content)
        if first_snapshot?, do: switch_primary_store_to_snapshot(repo, snapshot)
        result

      {:error, reason} ->
        log_refresh_error(repo, checkout, workflow_in_repo, snapshot, reason)
        {:error, reason}
    end
  end

  defp ref_workflow(repo, checkout, workflow_in_repo) do
    with {:ok, ref} <- base_ref(repo, checkout),
         {:ok, content} <- git(checkout, ["show", "#{ref}:#{workflow_in_repo}"]),
         {:ok, workflow} <- Workflow.parse_repo_workflow(content) do
      {:ok, content, workflow}
    end
  end

  # The primary workflow store follows the configured workflow path, which points at
  # the local file when no snapshot existed at boot. Other repos' stores resolve
  # `read_path/1` on every reload.
  defp switch_primary_store_to_snapshot(%SystemSchema.Repo{name: name}, snapshot) do
    if name == Application.get_env(:symphony_elixir, :primary_repo_name) do
      Workflow.set_workflow_file_path(snapshot)
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
