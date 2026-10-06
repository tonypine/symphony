defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, GitConfigCommands, ManagedClone, PathSafety, ProcessTree, SSH, Tracker, WorkflowSource}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Hooks
  alias SymphonyElixir.GitHub.Repo, as: GitHubRepo
  alias SymphonyElixir.Repo.{Fetcher, FetchLog}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  # How much of a timed-out hook's output its log line keeps.
  @hook_output_tail_lines 20
  @hook_output_tail_chars 2_048
  @orphan_backup_identity "symphony"
  @orphan_backup_email "symphony@localhost"
  @orphan_backup_message "symphony: orphaned worktree state before PR reset"
  # `diff.ignoreSubmodules` and `submodule.recurse`: a nested repo in a workspace keeps its own
  # config, which the agent writes, so `status` must not run git in it to see whether it is dirty,
  # nor `checkout` or `reset` recurse into it. (`add` ignores `diff.ignoreSubmodules`; the orphan
  # backup's `add -A` starts from an empty index, which lists no nested repo to check.)
  # The last five keep git from running a command the config names: a fetch lists no refs of the
  # repo's alternate object stores (`core.alternateRefsCommand`), no `git://` remote goes through
  # `core.gitProxy`, and nothing checks or makes a signature with `gpg.program`.
  # `core.askPass=` keeps an HTTPS remote that asks for credentials from running the config's
  # command. The empty value also skips git's `SSH_ASKPASS` fallback, a desktop prompt an
  # unattended fetch shouldn't raise; the operator's own `GIT_ASKPASS` still wins over it. With no
  # askpass left, `GIT_TERMINAL_PROMPT=0` fails the call instead of asking on the operator's
  # terminal.
  # `core.sshCommand`: an SSH connection that stops answering is dropped after a minute instead
  # of holding the git call (and the repo's fetch lock) forever.
  @safe_git_config_overrides [
    "core.sshCommand=ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
    "core.fsmonitor=",
    "core.hooksPath=",
    "credential.helper=",
    "core.askPass=",
    "diff.ignoreSubmodules=dirty",
    "protocol.ext.allow=never",
    "protocol.file.allow=user",
    "submodule.recurse=false",
    "core.alternateRefsCommand=true",
    "protocol.git.allow=never",
    "log.showSignature=false",
    "merge.verifySignatures=false",
    "push.gpgSign=false"
  ]
  # Exit status and output line of an SSH worker's `after_create` wrapper that
  # skipped the hook because it can't run on the base branch tree.
  @remote_after_create_skipped_status 47
  @remote_after_create_skipped_line "workspace_after_create_skipped"
  @safe_git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"GIT_TERMINAL_PROMPT", "0"}
  ]
  @safe_git_env_keys Enum.map(@safe_git_env, &elem(&1, 0))
  # The git subcommands that talk to a remote, and the wall-clock limit each call of one gets.
  # A remote can accept the connection and then never answer, and the SSH keepalives don't see
  # that while the server's sshd still answers them.
  @network_git_subcommands ["fetch", "pull", "push", "ls-remote"]
  @default_git_network_timeout_ms 300_000
  # The exit status of a network call Symphony stopped at its timeout, as `timeout(1)` uses.
  @git_timeout_status 124

  @type worker_host :: String.t() | nil
  @type lifecycle_action :: %{
          optional(:repo_key) => String.t(),
          optional(:identifier) => String.t(),
          optional(:path) => Path.t(),
          optional(:destination) => Path.t(),
          optional(:worker_host) => worker_host(),
          optional(:action) => :deleted | :logged | :trashed | :failed,
          optional(:reason) => :age_gc | :orphan,
          optional(:error) => term()
        }

  @spec safe_identifier(term()) :: String.t()
  def safe_identifier(identifier) do
    identifier =
      cond do
        is_binary(identifier) and identifier != "" -> identifier
        is_nil(identifier) -> "issue"
        true -> to_string(identifier)
      end

    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  @spec safe_git([String.t()]) :: {Collectable.t(), non_neg_integer()}
  def safe_git(args) when is_list(args) do
    safe_git("git", args, [])
  end

  @spec safe_git([String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  @spec safe_git(String.t(), [String.t()]) :: {Collectable.t(), non_neg_integer()}
  def safe_git(args, opts) when is_list(args) and is_list(opts) do
    safe_git("git", args, opts)
  end

  def safe_git(command, args) when is_binary(command) and is_list(args) do
    safe_git(command, args, [])
  end

  # Every call also turns off the filter and merge drivers the repo's config defines, and the
  # diff drivers and upload or receive pack commands it names (see
  # `SymphonyElixir.GitConfigCommands`), and refuses to run git when it can't. The scan runs git
  # through `/bin/sh`, so a missing git raises first, as `System.cmd/3` does.
  #
  # A `fetch`, `pull`, `push` or `ls-remote` is stopped, with git's whole process group, once it
  # has run for `:network_timeout_ms` (default 5 minutes, or the `:git_network_timeout_ms`
  # application env), and then returns status 124 with a line saying so. It is stopped as well
  # when its caller exits. Each one logs its duration.
  @spec safe_git(String.t(), [String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def safe_git(command, args, opts) when is_binary(command) and is_list(args) and is_list(opts) do
    unless System.find_executable(command) do
      :erlang.error(:enoent, [command, args, opts])
    end

    {timeout_ms, opts} = Keyword.pop_lazy(opts, :network_timeout_ms, &default_git_network_timeout_ms/0)

    case GitConfigCommands.config_args(args, opts, &read_git(command, &1, &2)) do
      {:ok, driver_args} ->
        invocation = git_invocation(args, Keyword.get(opts, :cd))
        run_safe_git(command, driver_args ++ GitConfigCommands.subcommand_args(args), opts, invocation, timeout_ms)

      {:error, message, status} ->
        {message, status}
    end
  end

  defp run_safe_git(command, args, opts, {[subcommand | _args] = invocation, dir}, timeout_ms)
       when subcommand in @network_git_subcommands do
    log_command = Enum.join(["git" | invocation], " ")
    dir = dir || File.cwd!()
    started_at = System.monotonic_time(:millisecond)

    case run_git_port(command, safe_git_args(args), safe_git_opts(opts), timeout_ms) do
      {:ok, {output, status}} ->
        Logger.info("Git network call completed repo=#{dir} command=#{inspect(log_command)} status=#{status} duration_ms=#{elapsed_ms(started_at)}")

        {output, status}

      {:timeout, output} ->
        Logger.error("Git network call timed out repo=#{dir} command=#{inspect(log_command)} timeout_ms=#{timeout_ms} duration_ms=#{elapsed_ms(started_at)}; stopped it")

        {"symphony: #{log_command} timed out after #{timeout_ms} ms and was stopped\n" <> output, @git_timeout_status}
    end
  end

  defp run_safe_git(command, args, opts, _invocation, _timeout_ms) do
    System.cmd(command, safe_git_args(args), safe_git_opts(opts))
  end

  # The subcommand with its arguments, and the dir the call runs in: the last `-C <dir>`, or the
  # `:cd` option. Takes git's `-C <dir>` and `-c <config>` options before the subcommand.
  defp git_invocation(["-C", dir | args], _dir), do: git_invocation(args, dir)
  defp git_invocation(["-c", _config | args], dir), do: git_invocation(args, dir)
  defp git_invocation(args, dir), do: {args, dir}

  # Runs git in a port owned by a task, which stops git's process group (git and the `ssh` it
  # started) at the deadline, or when the caller exits first.
  defp run_git_port(command, args, opts, timeout_ms) do
    owner = self()
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: args, env: port_env(Keyword.fetch!(opts, :env))] ++
        Keyword.take(opts, [:cd])

    Task.async(fn ->
      Process.flag(:trap_exit, true)
      port = Port.open({:spawn_executable, System.find_executable(command)}, port_opts)
      collect_hook_output(port, owner, [], deadline)
    end)
    |> Task.await(:infinity)
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)} end)
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp default_git_network_timeout_ms do
    Application.get_env(:symphony_elixir, :git_network_timeout_ms, @default_git_network_timeout_ms)
  end

  # The shell functions an SSH worker's script defines to run git as `safe_git/3` does:
  # `symphony_git <dir> <args>` runs `git -C <dir> <args>` with the same env and `-c` overrides,
  # and blanks the filter drivers the repo's config defines (see
  # `SymphonyElixir.GitConfigCommands.shell_functions/0`).
  @spec remote_safe_git_functions() :: String.t()
  def remote_safe_git_functions do
    env = Enum.map_join(@safe_git_env, " ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)
    overrides = Enum.map_join(@safe_git_config_overrides, " ", &"-c #{shell_escape(&1)}")

    """
    symphony_git_raw() { #{env} git #{overrides} "$@"; }
    #{GitConfigCommands.shell_functions()}\
    """
  end

  # Runs git like `safe_git/1` but keeps stderr out of the output, for content reads
  # such as `git show <ref>:<path>`: a warning git prints (a config notice, the xcrun
  # shim's cache warning) would otherwise land in the file content.
  @spec safe_git_stdout([String.t()]) :: {String.t(), non_neg_integer(), String.t()}
  def safe_git_stdout(args) when is_list(args) do
    case GitConfigCommands.config_args(args, [], &read_git("git", &1, &2)) do
      {:ok, driver_args} -> read_git("git", driver_args ++ GitConfigCommands.subcommand_args(args), [])
      {:error, message, status} -> {"", status, message}
    end
  end

  # The shell sends stderr to a temp file, so it never reaches the BEAM's own stderr either.
  defp read_git(command, args, opts) do
    stderr_path = Path.join(System.tmp_dir!(), "symphony-git-stderr-#{System.unique_integer([:positive])}")
    File.write!(stderr_path, "")

    try do
      {stdout, status} =
        System.cmd(
          "/bin/sh",
          ["-c", ~s(exec "$@" 2>"$0"), stderr_path, command | safe_git_args(args)],
          opts |> Keyword.take([:cd, :env]) |> put_safe_git_env()
        )

      {stdout, status, File.read!(stderr_path)}
    after
      File.rm(stderr_path)
    end
  end

  # `opts`:
  #   * `:active_workspace_identifiers` - identifiers (or workspace basenames) of
  #     other issues a running or retrying agent owns. Their worktrees are never
  #     detached to release a branch for this issue.
  #   * `:sibling_issue_lookup` - reads the issue a sibling worktree belongs to by
  #     identifier, as `Tracker.fetch_issue_by_identifier/1` (the default) does. A
  #     sibling's worktree is detached only when its issue is terminal or unknown.
  #   * `:on_hook` - called with `{:started, hook_name, timeout_ms}` and
  #     `{:finished, hook_name}` around each hook run.
  @spec create_for_issue(map() | String.t() | nil, worker_host(), String.t() | nil, keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, repo_key \\ nil, opts \\ []) do
    issue_context =
      issue_or_identifier
      |> issue_context(repo_key)
      |> Map.put(:active_workspaces, normalize_identifier_set(Keyword.get(opts, :active_workspace_identifiers, [])))
      |> Map.put(:sibling_issue_lookup, Keyword.get(opts, :sibling_issue_lookup, &Tracker.fetch_issue_by_identifier/1))
      |> Map.put(:on_hook, Keyword.get(opts, :on_hook))

    try do
      safe_repo_key = safe_identifier(issue_context.repo_key)
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_repo_key, safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, after_create} <- ensure_workspace(workspace, issue_context, worker_host),
           :ok <- refresh_repo_workflow(issue_context, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, after_create, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec validate(Path.t()) :: :ok | {:error, term()}
  def validate(workspace), do: validate(workspace, nil)

  @spec validate(Path.t(), worker_host()) :: :ok | {:error, term()}
  def validate(workspace, worker_host) when is_binary(workspace) do
    validate_workspace_path(workspace, worker_host)
  end

  def validate(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}}
  end

  # Runs after the workspace prepare so a local worktree fetch is already done and
  # the run (and its hooks) sees the `WORKFLOW.md` committed on the fetched ref.
  defp refresh_repo_workflow(issue_context, worker_host) do
    with {:ok, repo} <- Config.repo(issue_context.repo_key) do
      settings = settings_for_issue_context(issue_context)

      _result =
        WorkflowSource.refresh(repo,
          fetch: settings.workspace.fetch_before_dispatch,
          fetched_repo: locally_fetched_repo(settings, worker_host)
        )
    end

    :ok
  end

  defp locally_fetched_repo(%{workspace: %{strategy: "worktree", fetch_before_dispatch: true, repo: repo}}, nil), do: repo
  defp locally_fetched_repo(_settings, _worker_host), do: nil

  # Returns the workspace with what its `after_create` still needs: `:new` for a
  # workspace just created, `:unfinished` for a reused one whose `after_create`
  # never succeeded, and `:done` otherwise. A remote prepare script reports the
  # state itself; a local one is read from the pending marker here.
  defp ensure_workspace(workspace, issue_context, worker_host) do
    settings = settings_for_issue_context(issue_context)

    result =
      case settings.workspace.strategy do
        "worktree" ->
          ensure_worktree_workspace(workspace, issue_context, worker_host, settings)

        _strategy ->
          ensure_directory_workspace(workspace, issue_context, worker_host, settings)
      end

    case result do
      {:ok, workspace, true} -> {:ok, workspace, :new}
      {:ok, workspace, false} -> {:ok, workspace, local_after_create_state(workspace)}
      other -> other
    end
  end

  defp local_after_create_state(workspace) do
    if File.exists?(after_create_pending_marker(workspace)), do: :unfinished, else: :done
  end

  defp ensure_directory_workspace(workspace, _issue_context, nil, _settings) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_directory_workspace(workspace, _issue_context, worker_host, settings) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("root", settings.workspace.root),
        remote_shell_assign("workspace", workspace),
        remote_workspace_parent_containment_preamble(),
        remote_after_create_running_check(),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        remote_after_create_pending_mark_command(settings),
        "cd \"$workspace\"",
        "physical_workspace=$(pwd -P)",
        remote_workspace_containment_check(),
        remote_workspace_output_command()
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # File the rework agent writes to mark clearly non-actionable bot review comments
  # so they are skipped by the auto-reply. Excluded from git so it is never tracked.
  @skip_comments_filename ".symphony-skip-comments.json"

  defp ensure_worktree_workspace(workspace, issue_context, nil, settings) do
    with {:ok, repo} <- local_worktree_repo(settings),
         :ok <- prepare_worktree_repo(repo, issue_context, settings),
         branch = worktree_branch(issue_context),
         base_ref = worktree_base_ref(issue_context),
         create_base_ref = worktree_create_base_ref(repo, issue_context, base_ref),
         create_base_ref = create_base_ref || managed_clone_base_ref(repo, branch, settings),
         siblings = sibling_release_policy(issue_context),
         {:ok, created?} <-
           add_or_reuse_local_worktree(repo, workspace, branch, base_ref, create_base_ref, siblings) do
      ensure_skip_comments_excluded(workspace)
      {:ok, workspace, created?}
    else
      {:error, reason, output} ->
        log_local_worktree_failure(workspace, issue_context, reason, output)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_worktree_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    branch = worktree_branch(issue_context)
    base_ref = worktree_base_ref(issue_context)
    create_base_ref = remote_worktree_create_base_ref(issue_context, base_ref)
    reset_base_ref = base_ref || ""

    script =
      [
        "set -eu",
        remote_safe_git_functions(),
        remote_shell_assign("root", settings.workspace.root),
        remote_shell_assign("repo", settings.workspace.repo || ""),
        remote_shell_assign("workspace", workspace),
        "branch=#{shell_escape(branch)}",
        "base_ref=#{shell_escape(create_base_ref || "HEAD")}",
        "reset_base_ref=#{shell_escape(reset_base_ref)}",
        "if [ -z \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: workspace.repo is required for worktree strategy\"",
        "  exit 41",
        "fi",
        "if [ ! -d \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: $repo\"",
        "  exit 41",
        "fi",
        "symphony_git \"$repo\" rev-parse --git-dir >/dev/null",
        remote_fetch_before_dispatch_command(settings),
        remote_workspace_parent_containment_preamble(),
        remote_after_create_running_check(),
        "if [ -d \"$workspace\" ]; then",
        "  if ! worktrees=$(symphony_git \"$repo\" worktree list --porcelain); then",
        "    echo \"workspace_worktree_list_failed: $repo\"",
        "    exit 43",
        "  fi",
        "  registered=$(printf '%s\\n' \"$worktrees\" | awk '/^worktree / {print substr($0, 10)}' | grep -Fx \"$workspace\" || true)",
        "  if [ -z \"$registered\" ]; then",
        "    echo \"workspace_not_registered_worktree: $workspace\"",
        "    exit 42",
        "  fi",
        "  if [ -n \"$reset_base_ref\" ]; then",
        "    reset_base_sha=$(symphony_git \"$repo\" rev-parse --verify --end-of-options \"$reset_base_ref^{commit}\")",
        remote_worktree_branch_owner_command(),
        "    if [ -n \"$branch_owner\" ] && [ \"$branch_owner\" != \"$workspace\" ]; then",
        "      printf '%s\\t%s\\t%s\\t%s\\n' 'workspace_branch_already_checked_out_elsewhere' \\",
        "        \"$branch\" \"$branch_owner\" \"$workspace\"",
        "      exit 45",
        "    fi",
        remote_worktree_reset_backup_lines(),
        "    symphony_git \"$workspace\" reset --hard",
        "    symphony_git \"$workspace\" checkout -f -B \"$branch\" \"$reset_base_sha\"",
        "  fi",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  #{remote_worktree_add_command()}",
        "  created=1",
        "else",
        "  #{remote_worktree_add_command()}",
        "  created=1",
        "fi",
        remote_after_create_pending_mark_command(settings),
        "cd \"$workspace\"",
        "physical_workspace=$(pwd -P)",
        remote_workspace_containment_check(),
        remote_workspace_output_command()
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in ["", nil, false]))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, 45}} ->
        {:error, parse_remote_branch_collision(output, workspace)}

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp local_worktree_repo(settings) do
    repo = settings.workspace.repo

    if is_binary(repo) and String.trim(repo) != "" do
      {:ok, Path.expand(repo)}
    else
      {:error, :missing_workspace_repo}
    end
  end

  # A `workspace.source` repo is Symphony's own clone: it is made again if it is
  # missing and fetched (when `fetch_before_dispatch` is on), under a per-clone lock.
  defp prepare_worktree_repo(repo, issue_context, %{workspace: %{github: github} = workspace}) when is_binary(github) do
    result = ManagedClone.sync(issue_context.repo_key, github, repo, fetch: workspace.fetch_before_dispatch)
    if workspace.fetch_before_dispatch, do: FetchLog.record(issue_context.repo_key, result), else: result
  end

  defp prepare_worktree_repo(repo, issue_context, settings), do: maybe_fetch_worktree_repo(repo, issue_context, settings)

  # The clone's local default branch is never updated by a fetch, so with no
  # `base_branch` a new branch starts from the fetched `origin/HEAD`. An existing
  # branch is checked out as it is, as for a local checkout.
  defp managed_clone_base_ref(repo, branch, %{workspace: %{github: github}}) when is_binary(github) do
    if not git_branch_exists?(repo, branch) and git_ref_exists?(repo, "origin/HEAD"), do: "origin/HEAD"
  end

  defp managed_clone_base_ref(_repo, _branch, _settings), do: nil

  defp maybe_fetch_worktree_repo(repo, issue_context, settings) do
    case settings.workspace.fetch_before_dispatch do
      true -> FetchLog.record(issue_context.repo_key, fetch_origin(repo))
      false -> :ok
    end
  end

  defp fetch_origin(repo) do
    case Fetcher.fetch_origin(repo) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_failed, repo, ["fetch", "origin"], status}, output}
    end
  end

  defp remote_fetch_before_dispatch_command(settings) do
    if settings.workspace.fetch_before_dispatch do
      Fetcher.remote_fetch_origin_script()
    end
  end

  # `base_ref` drives the reuse path's `git reset --hard` (nil for issue runs so an
  # in-progress worktree is preserved; set by PR runs to the PR head). `create_base_ref`
  # drives fresh worktree creation, defaulting to the configured base branch so a new
  # worktree branches off clean trunk rather than whatever the source repo HEAD is on.
  defp add_or_reuse_local_worktree(repo, workspace, branch, base_ref, create_base_ref, siblings) do
    cond do
      File.dir?(workspace) ->
        reuse_local_worktree(repo, workspace, branch, base_ref, siblings)

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        add_local_worktree(repo, workspace, branch, create_base_ref, siblings)

      true ->
        add_local_worktree(repo, workspace, branch, create_base_ref, siblings)
    end
  end

  defp reuse_local_worktree(repo, workspace, branch, base_ref, siblings) do
    case registered_worktree?(repo, workspace) do
      true ->
        with :ok <- reset_worktree_to_base_ref(repo, workspace, branch, base_ref, siblings) do
          {:ok, false}
        end

      false ->
        {:error, {:workspace_not_registered_worktree, workspace}}
    end
  end

  # PR runs pass an explicit base_ref (e.g. "origin/<head>") so a redispatch sees
  # the latest PR head on the requested branch. Issue runs pass nil and keep the
  # existing worktree state.
  defp reset_worktree_to_base_ref(_repo, _workspace, _branch, nil, _siblings), do: :ok
  defp reset_worktree_to_base_ref(_repo, _workspace, _branch, "", _siblings), do: :ok

  defp reset_worktree_to_base_ref(repo, workspace, branch, base_ref, siblings) when is_binary(base_ref) do
    with :ok <- check_branch_not_checked_out_elsewhere(repo, workspace, branch, siblings),
         {:ok, commit_sha} <- resolve_git_commit(workspace, base_ref) do
      _ = backup_local_work_before_reset(workspace)

      with :ok <- run_git(workspace, ["reset", "--hard"]) do
        run_git(workspace, ["checkout", "-f", "-B", branch, commit_sha])
      end
    end
  end

  # Before the reuse reset rewrites the branch to the remote head, snapshot any
  # local-only work so a crashed prior run's commits, uncommitted edits, or
  # untracked files (which a colliding `checkout -f` would clobber) stay
  # recoverable under refs/symphony/orphaned/<sha> instead of being silently
  # dropped. Best-effort: backup failures never block the reset, which is what
  # lets a rework adopt the authoritative remote head (e.g. UI-pushed commits).
  defp backup_local_work_before_reset(workspace) do
    case git_output(workspace, ["rev-parse", "HEAD"]) do
      {:ok, head_output} ->
        head_sha = head_output |> IO.iodata_to_binary() |> String.trim()

        if worktree_has_local_only_work?(workspace) do
          snapshot_orphaned_work(workspace, head_sha)
        end

      {:error, _reason, _output} ->
        :ok
    end

    :ok
  end

  defp worktree_has_local_only_work?(workspace) do
    worktree_dirty?(workspace) or worktree_has_unpushed_commits?(workspace)
  end

  defp worktree_dirty?(workspace) do
    case git_output(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, ""} -> false
      {:ok, _status} -> true
      {:error, _reason, _output} -> false
    end
  end

  defp worktree_has_unpushed_commits?(workspace) do
    case git_output(workspace, ["rev-list", "--max-count=1", "HEAD", "--not", "--remotes"]) do
      {:ok, ""} -> false
      {:ok, _commits} -> true
      {:error, _reason, _output} -> false
    end
  end

  # Snapshot the worktree's full visible state (tracked, uncommitted, and
  # untracked-but-not-ignored files) as a commit parented on HEAD, so unpushed
  # history and any working changes are recoverable from one ref. A throwaway
  # index keeps the live index and worktree untouched.
  defp snapshot_orphaned_work(workspace, head_sha) do
    index_file = orphan_backup_index_path(workspace, head_sha)
    index_env = [{"GIT_INDEX_FILE", index_file}]

    # A throwaway index must not pre-exist; git rejects an empty/partial index
    # file (e.g. one left by a crashed run) and would skip the backup otherwise.
    _ = File.rm(index_file)

    try do
      with {_add, 0} <- safe_git(["-C", workspace, "add", "-A"], env: index_env),
           {tree_out, 0} <- safe_git(["-C", workspace, "write-tree"], env: index_env),
           tree = tree_out |> IO.iodata_to_binary() |> String.trim(),
           {commit_out, 0} <- safe_git(orphan_commit_tree_args(workspace, tree, head_sha)) do
        commit = commit_out |> IO.iodata_to_binary() |> String.trim()
        ref = "refs/symphony/orphaned/#{head_sha}"
        _ = run_git(workspace, ["update-ref", ref, commit])

        Logger.warning("Workspace reset preserved local work workspace=#{workspace} head=#{head_sha} backup_ref=#{ref} backup_commit=#{commit}")
      else
        _ -> :ok
      end
    after
      _ = File.rm(index_file)
    end
  end

  defp orphan_commit_tree_args(workspace, tree, head_sha) do
    [
      "-C",
      workspace,
      "-c",
      "user.name=#{@orphan_backup_identity}",
      "-c",
      "user.email=#{@orphan_backup_email}",
      "commit-tree",
      tree,
      "-p",
      head_sha,
      "-m",
      @orphan_backup_message
    ]
  end

  defp orphan_backup_index_path(workspace, head_sha) do
    Path.join(System.tmp_dir!(), "symphony-orphan-#{Path.basename(workspace)}-#{head_sha}.index")
  end

  # Adds the skip-comments file to the worktree's git exclude so the agent can write
  # it without it ever being tracked or accidentally committed. Best-effort: any
  # failure here must not block workspace creation.
  defp ensure_skip_comments_excluded(workspace) do
    with {:ok, common_dir} <- git_output(workspace, ["rev-parse", "--git-common-dir"]) do
      exclude_path =
        common_dir
        |> IO.iodata_to_binary()
        |> String.trim()
        |> resolve_workspace_relative(workspace)
        |> Path.join("info/exclude")

      ensure_exclude_entry(exclude_path, "/#{@skip_comments_filename}")
    end

    :ok
  end

  defp resolve_workspace_relative(path, workspace) do
    case Path.type(path) do
      :absolute -> path
      _ -> Path.join(workspace, path)
    end
  end

  defp ensure_exclude_entry(exclude_path, entry) do
    existing =
      case File.read(exclude_path) do
        {:ok, contents} -> contents
        _ -> ""
      end

    if entry in String.split(existing, "\n") do
      :ok
    else
      _ = File.mkdir_p(Path.dirname(exclude_path))
      prefix = if String.trim_trailing(existing, "\n") == "", do: "", else: String.trim_trailing(existing, "\n") <> "\n"
      _ = File.write(exclude_path, prefix <> entry <> "\n")
      :ok
    end
  end

  # Under the repo's fetch lock: parallel `worktree add`s of one repo race for its
  # `.git/config` lock and refs, and the loser exits 255 with its branch made but no
  # worktree. `--no-track` keeps the add from writing the branch's upstream config.
  defp add_local_worktree(repo, workspace, branch, base_ref, siblings) do
    File.mkdir_p!(Path.dirname(workspace))

    Fetcher.with_lock(repo, fn ->
      case check_branch_not_checked_out_elsewhere(repo, workspace, branch, siblings) do
        :ok ->
          repo
          |> run_git(worktree_add_args(repo, workspace, branch, base_ref))
          |> handle_local_worktree_add_result(repo, workspace)

        error ->
          error
      end
    end)
  end

  defp handle_local_worktree_add_result(:ok, _repo, _workspace), do: {:ok, true}

  defp handle_local_worktree_add_result({:error, reason, output}, repo, workspace) do
    case reuse_local_worktree_after_add_failure(repo, workspace) do
      {:ok, false} -> {:ok, false}
      :error -> {:error, reason, output}
    end
  end

  defp reuse_local_worktree_after_add_failure(repo, workspace), do: reuse_local_worktree_after_add_failure(repo, workspace, 10)

  defp reuse_local_worktree_after_add_failure(repo, workspace, attempts) when attempts > 0 do
    case registered_worktree?(repo, workspace) do
      true ->
        {:ok, false}

      false ->
        Process.sleep(20)
        reuse_local_worktree_after_add_failure(repo, workspace, attempts - 1)
    end
  end

  defp reuse_local_worktree_after_add_failure(_repo, _workspace, _attempts), do: :error

  defp check_branch_not_checked_out_elsewhere(repo, workspace, branch, siblings) do
    # On `git worktree list --porcelain` failure, fall through to the actual
    # `git worktree add` so its native error surfaces via the existing path.
    with {:ok, output} <- git_output(repo, ["worktree", "list", "--porcelain"]),
         path when is_binary(path) <- find_worktree_for_branch(output, branch),
         false <- Path.expand(path) == Path.expand(workspace),
         :error <- release_branch_from_stale_sibling(path, workspace, branch, siblings) do
      {:error, {:branch_already_checked_out_elsewhere, branch: branch, at: path, requested: workspace}}
    else
      _ -> :ok
    end
  end

  # A Linear team-key rename (TON-218 -> TP-218) moves an issue to a new
  # workspace directory while its old sibling worktree still has the PR branch
  # checked out. When that sibling holds no uncommitted or unpushed work, detach
  # its HEAD so the renamed issue's workspace can take the branch over. Anything
  # else (a worktree outside this repo's workspace dir, one a running or retrying
  # agent owns, one whose issue is still open, or one with local-only work) keeps
  # the collision error.
  defp release_branch_from_stale_sibling(owner, workspace, branch, siblings) do
    if Path.dirname(Path.expand(owner)) == Path.dirname(Path.expand(workspace)) and
         not MapSet.member?(siblings.active, Path.basename(owner)) and
         not worktree_has_local_only_work?(owner) and
         sibling_issue_closed?(Path.basename(owner), siblings) and
         run_git(owner, ["checkout", "--detach"]) == :ok do
      Logger.info("Released workspace branch from stale sibling worktree branch=#{branch} sibling=#{owner} workspace=#{workspace}")
      :ok
    else
      :error
    end
  end

  defp sibling_release_policy(issue_context) do
    %{
      active: issue_context.active_workspaces,
      issue_id: issue_context.issue_id,
      lookup: issue_context.sibling_issue_lookup
    }
  end

  # An open issue whose agent is not running right now (held by the usage limit,
  # waiting on sub-tickets or a review) comes back to its worktree, so only a
  # terminal or unknown issue gives its branch up. One that resolves to this very
  # issue is its own pre-rename workspace. A failed lookup keeps the branch.
  # Linear answers an unknown identifier with an "Entity not found" GraphQL error.
  defp sibling_issue_closed?(identifier, %{issue_id: issue_id, lookup: lookup}) do
    case lookup.(identifier) do
      {:ok, %{id: ^issue_id}} when is_binary(issue_id) ->
        true

      {:ok, %{state: state}} ->
        terminal_issue_state?(state)

      {:error, :issue_not_found} ->
        true

      {:error, {:linear_graphql_errors, errors}} ->
        Enum.any?(List.wrap(errors), &entity_not_found_error?/1)

      {:error, reason} ->
        Logger.warning("Kept workspace branch on sibling worktree; issue lookup failed sibling=#{identifier} reason=#{inspect(reason)}")
        false
    end
  end

  defp terminal_issue_state?(state) when is_binary(state) do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&Schema.normalize_issue_state/1)
    |> Enum.member?(Schema.normalize_issue_state(state))
  end

  defp terminal_issue_state?(_state), do: false

  defp entity_not_found_error?(%{"message" => message}) when is_binary(message), do: message =~ ~r/not found/i
  defp entity_not_found_error?(_error), do: false

  defp find_worktree_for_branch(porcelain_output, branch) when is_binary(branch) do
    porcelain_output
    |> IO.iodata_to_binary()
    |> String.split(~r/\R\R+/, trim: true)
    |> Enum.find_value(&worktree_block_branch_owner(&1, branch))
  end

  defp worktree_block_branch_owner(block, branch) do
    lines = String.split(block, ~r/\R/, trim: true)
    needle = "branch refs/heads/" <> branch

    if Enum.any?(lines, &(&1 == needle)) do
      Enum.find_value(lines, fn
        "worktree " <> path -> path
        _line -> nil
      end)
    end
  end

  defp worktree_add_args(repo, workspace, branch, base_ref) do
    cond do
      is_binary(base_ref) and base_ref != "" ->
        ["worktree", "add", "--no-track", "-B", branch, workspace, base_ref]

      git_branch_exists?(repo, branch) ->
        ["worktree", "add", workspace, branch]

      true ->
        ["worktree", "add", "-b", branch, workspace, "HEAD"]
    end
  end

  defp remote_worktree_add_command do
    "branch_owner=$(symphony_git \"$repo\" worktree list --porcelain | awk -v b=\"$branch\" 'BEGIN { wt = \"\" } /^worktree / { wt = substr($0, 10); next } $0 == \"branch refs/heads/\" b { print wt; exit }'); if [ -n \"$branch_owner\" ] && [ \"$branch_owner\" != \"$workspace\" ]; then printf 'workspace_branch_already_checked_out_elsewhere\\t%s\\t%s\\t%s\\n' \"$branch\" \"$branch_owner\" \"$workspace\"; exit 45; fi; if [ \"$base_ref\" != \"HEAD\" ]; then symphony_git \"$repo\" worktree add --no-track -B \"$branch\" \"$workspace\" \"$base_ref\"; elif symphony_git \"$repo\" rev-parse --verify \"refs/heads/$branch\" >/dev/null 2>&1; then symphony_git \"$repo\" worktree add \"$workspace\" \"$branch\"; else symphony_git \"$repo\" worktree add -b \"$branch\" \"$workspace\" HEAD; fi"
  end

  # Mirror `snapshot_orphaned_work/2` for remote workers: snapshot a crashed run's
  # unpushed commits plus uncommitted and untracked changes under
  # refs/symphony/orphaned/<sha> before the reset rewrites the branch, so the
  # rework still adopts the remote head without silently destroying local work.
  # The whole block is a subshell guarded with `|| true` so a backup failure can
  # never abort the `set -eu` script before the reset runs.
  defp remote_worktree_reset_backup_lines do
    [
      "    ( reset_head_sha=$(symphony_git \"$workspace\" rev-parse HEAD 2>/dev/null) || exit 0",
      "      [ -n \"$reset_head_sha\" ] || exit 0",
      "      reset_dirty=$(symphony_git \"$workspace\" status --porcelain=v1 --untracked-files=all)",
      "      reset_unpushed=$(symphony_git \"$workspace\" rev-list --max-count=1 HEAD --not --remotes)",
      "      [ -n \"$reset_dirty\" ] || [ -n \"$reset_unpushed\" ] || exit 0",
      "      reset_index=$(mktemp -u \"${TMPDIR:-/tmp}/symphony-orphan.XXXXXX\")",
      "      export GIT_INDEX_FILE=\"$reset_index\"",
      "      symphony_git \"$workspace\" add -A",
      "      reset_tree=$(symphony_git \"$workspace\" write-tree)",
      "      unset GIT_INDEX_FILE",
      "      rm -f \"$reset_index\"",
      "      reset_backup=$(symphony_git \"$workspace\" -c user.name=#{@orphan_backup_identity} -c user.email=#{@orphan_backup_email} commit-tree \"$reset_tree\" -p \"$reset_head_sha\" -m '#{@orphan_backup_message}')",
      "      symphony_git \"$workspace\" update-ref \"refs/symphony/orphaned/$reset_head_sha\" \"$reset_backup\" ) || true"
    ]
  end

  defp remote_worktree_branch_owner_command do
    [
      "branch_owner=$(printf '%s\\n' \"$worktrees\" | ",
      "awk -v b=\"$branch\" 'BEGIN { wt = \"\" } ",
      "/^worktree / { wt = substr($0, 10); next } ",
      "$0 == \"branch refs/heads/\" b { print wt; exit }')"
    ]
    |> Enum.join("")
  end

  # Builds the shell preamble that canonicalizes the remote workspace root and
  # proves the existing workspace, or the nearest existing parent for a new
  # workspace, stays under that physical root before the script mutates it.
  defp remote_workspace_parent_containment_preamble do
    """
    mkdir -p "$root" || {
      echo "workspace_root_unreadable: $root"
      exit 50
    }
    physical_root=$(cd "$root" 2>/dev/null && pwd -P) || {
      echo "workspace_root_unreadable: $root"
      exit 50
    }
    if [ -z "$physical_root" ]; then
      echo "workspace_root_unreadable: $root"
      exit 50
    fi
    if [ -L "$workspace" ]; then
      echo "workspace_symlink_rejected: $workspace"
      exit 51
    fi
    workspace_parent=${workspace%/*}
    if [ -z "$workspace_parent" ] || [ "$workspace_parent" = "$workspace" ]; then
      echo "workspace_path_unreadable: $workspace"
      exit 50
    fi
    if [ -e "$workspace" ]; then
      if [ -d "$workspace" ]; then
        physical_workspace=$(cd "$workspace" 2>/dev/null && pwd -P) || {
          echo "workspace_path_unreadable: $workspace"
          exit 50
        }
        #{remote_workspace_containment_check()}
      else
        physical_parent=$(cd "$workspace_parent" 2>/dev/null && pwd -P) || {
          echo "workspace_path_unreadable: $workspace_parent"
          exit 50
        }
        #{remote_workspace_parent_containment_check()}
      fi
    else
      existing_parent="$workspace_parent"
      while [ ! -e "$existing_parent" ]; do
        next_parent=${existing_parent%/*}
        if [ -z "$next_parent" ] || [ "$next_parent" = "$existing_parent" ]; then
          echo "workspace_path_unreadable: $workspace_parent"
          exit 50
        fi
        existing_parent="$next_parent"
      done
      physical_parent=$(cd "$existing_parent" 2>/dev/null && pwd -P) || {
        echo "workspace_path_unreadable: $existing_parent"
        exit 50
      }
      #{remote_workspace_parent_containment_check()}
      mkdir -p "$workspace_parent"
      physical_parent=$(cd "$workspace_parent" 2>/dev/null && pwd -P) || {
        echo "workspace_path_unreadable: $workspace_parent"
        exit 50
      }
      #{remote_workspace_parent_containment_check()}
    fi\
    """
  end

  # Asserts $physical_workspace lies strictly under $physical_root (which both
  # paths must by then be canonical, symlink-resolved absolute paths). Compared
  # with trailing slashes so /root-evil cannot satisfy a /root prefix.
  defp remote_workspace_containment_check do
    """
    case "$physical_workspace/" in
      "$physical_root"/) echo "workspace_equals_root: $physical_workspace"; exit 52 ;;
      "$physical_root"/*) ;;
      *) echo "workspace_outside_root: $physical_workspace not under $physical_root"; exit 53 ;;
    esac\
    """
  end

  defp remote_workspace_parent_containment_check do
    """
    case "$physical_parent/" in
      "$physical_root"/) ;;
      "$physical_root"/*) ;;
      *) echo "workspace_outside_root: $physical_parent not under $physical_root"; exit 53 ;;
    esac\
    """
  end

  # Removal and hooks must not create parent directories as a side effect of
  # validation; they only prove the existing path, or nearest existing parent for
  # a missing path, is physically contained before a mutation happens.
  defp remote_workspace_mutation_containment_preamble do
    """
    mkdir -p "$root" || {
      echo "workspace_root_unreadable: $root"
      exit 50
    }
    physical_root=$(cd "$root" 2>/dev/null && pwd -P) || {
      echo "workspace_root_unreadable: $root"
      exit 50
    }
    if [ -z "$physical_root" ]; then
      echo "workspace_root_unreadable: $root"
      exit 50
    fi
    if [ -L "$workspace" ]; then
      echo "workspace_symlink_rejected: $workspace"
      exit 51
    fi
    workspace_parent=${workspace%/*}
    if [ -z "$workspace_parent" ] || [ "$workspace_parent" = "$workspace" ]; then
      echo "workspace_path_unreadable: $workspace"
      exit 50
    fi
    if [ -e "$workspace" ]; then
      if [ -d "$workspace" ]; then
        physical_workspace=$(cd "$workspace" 2>/dev/null && pwd -P) || {
          echo "workspace_path_unreadable: $workspace"
          exit 50
        }
        #{remote_workspace_containment_check()}
      else
        physical_parent=$(cd "$workspace_parent" 2>/dev/null && pwd -P) || {
          echo "workspace_path_unreadable: $workspace_parent"
          exit 50
        }
        #{remote_workspace_parent_containment_check()}
      fi
    else
      existing_parent="$workspace_parent"
      while [ ! -e "$existing_parent" ]; do
        next_parent=${existing_parent%/*}
        if [ -z "$next_parent" ] || [ "$next_parent" = "$existing_parent" ]; then
          echo "workspace_path_unreadable: $workspace_parent"
          exit 50
        fi
        existing_parent="$next_parent"
      done
      physical_parent=$(cd "$existing_parent" 2>/dev/null && pwd -P) || {
        echo "workspace_path_unreadable: $existing_parent"
        exit 50
      }
      #{remote_workspace_parent_containment_check()}
    fi\
    """
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    issue_context = workspace_issue_context(workspace)

    remove_workspace(workspace, issue_context, nil)
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    issue_context = workspace_issue_context(workspace)

    remove_workspace(workspace, issue_context, worker_host)
  end

  defp remove_workspace(workspace, issue_context, nil) do
    settings = settings_for_issue_context(issue_context)

    result =
      if settings.workspace.strategy == "worktree" do
        remove_worktree_workspace(workspace, issue_context, nil, settings)
      else
        remove_directory_workspace(workspace, issue_context, nil, settings)
      end

    if match?({:ok, _removed_paths}, result), do: clear_after_create_pending(workspace, nil)
    result
  end

  defp remove_workspace(workspace, issue_context, worker_host) when is_binary(worker_host) do
    settings = settings_for_issue_context(issue_context)

    if settings.workspace.strategy == "worktree" do
      remove_worktree_workspace(workspace, issue_context, worker_host, settings)
    else
      remove_directory_workspace(workspace, issue_context, worker_host, settings)
    end
  end

  defp remove_directory_workspace(workspace, issue_context, nil, _settings) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, issue_context, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  defp remove_directory_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host),
         :ok <- maybe_run_before_remove_hook(workspace, issue_context, worker_host) do
      script =
        [
          "set -eu",
          remote_shell_assign("root", settings.workspace.root),
          remote_shell_assign("workspace", workspace),
          remote_workspace_mutation_containment_preamble(),
          "rm -rf \"$workspace\"",
          remote_after_create_marker_remove_command()
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
        {:ok, {_output, 0}} ->
          {:ok, []}

        {:ok, {output, status}} ->
          {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_worktree_workspace(workspace, issue_context, nil, settings) do
    with {:ok, repo} <- local_worktree_repo(settings),
         :ok <- validate_workspace_path(workspace, nil),
         :ok <- remove_local_worktree(repo, workspace, issue_context) do
      {:ok, [workspace]}
    else
      {:error, reason, output} -> {:error, reason, output}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_worktree_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    branch = worktree_branch(issue_context)

    with :ok <- validate_workspace_path(workspace, worker_host),
         :ok <- maybe_run_before_remove_hook(workspace, issue_context, worker_host) do
      script =
        [
          "set -eu",
          remote_safe_git_functions(),
          remote_shell_assign("root", settings.workspace.root),
          remote_shell_assign("repo", settings.workspace.repo || ""),
          remote_shell_assign("workspace", workspace),
          "branch=#{shell_escape(branch)}",
          "if [ -z \"$repo\" ]; then",
          "  echo \"workspace_repo_missing: workspace.repo is required for worktree strategy\"",
          "  exit 41",
          "fi",
          "if [ ! -d \"$repo\" ]; then",
          "  echo \"workspace_repo_missing: $repo\"",
          "  exit 41",
          "fi",
          "symphony_git \"$repo\" rev-parse --git-dir >/dev/null",
          remote_workspace_mutation_containment_preamble(),
          "if ! worktrees=$(symphony_git \"$repo\" worktree list --porcelain); then",
          "  echo \"workspace_worktree_list_failed: $repo\"",
          "  exit 43",
          "fi",
          "registered=$(printf '%s\\n' \"$worktrees\" | awk '/^worktree / {print substr($0, 10)}' | grep -Fx \"$workspace\" || true)",
          "if [ -n \"$registered\" ]; then",
          "  symphony_git \"$repo\" worktree remove --force \"$workspace\"",
          "elif [ -e \"$workspace\" ]; then",
          "  echo \"workspace_not_registered_worktree: $workspace\"",
          "  exit 42",
          "fi",
          remote_after_create_marker_remove_command(),
          "if symphony_git \"$repo\" rev-parse --verify \"refs/heads/$branch\" >/dev/null 2>&1; then",
          "  if ! branch_delete_output=$(symphony_git \"$repo\" branch -D \"$branch\" 2>&1); then",
          "    case \"$branch_delete_output\" in",
          "      *\"checked out at\"*|*\"is checked out\"*)",
          "        printf '%s\\n' \"workspace_branch_delete_skipped: $branch checked out elsewhere\"",
          "        ;;",
          "      *)",
          "        printf '%s\\n' \"$branch_delete_output\"",
          "        exit 44",
          "        ;;",
          "    esac",
          "  fi",
          "fi"
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
        {:ok, {_output, 0}} ->
          {:ok, []}

        {:ok, {output, status}} ->
          {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{identifier: identifier} = issue, worker_host)
      when is_binary(identifier) and is_binary(worker_host) do
    remove_issue_workspace(identifier, issue_context(issue), worker_host)
  end

  def remove_issue_workspaces(%{identifier: identifier} = issue, nil) when is_binary(identifier) do
    issue_context = issue_context(issue)

    case settings_for_issue_context(issue_context).worker.ssh_hosts do
      [] ->
        remove_issue_workspace(identifier, issue_context, nil)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    remove_issue_workspace(identifier, issue_context(identifier), worker_host)
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    issue_context = issue_context(identifier)

    case settings_for_issue_context(issue_context).worker.ssh_hosts do
      [] ->
        remove_issue_workspace(identifier, issue_context, nil)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspace(identifier, issue_context, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec free_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes, do: free_bytes(nil)

  @spec free_bytes(worker_host()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(nil) do
    root = Path.expand(Config.settings!().workspace.root)

    with :ok <- File.mkdir_p(root),
         {output, 0} <- System.cmd("df", ["-Pk", root], stderr_to_stdout: true),
         {:ok, bytes} <- parse_df_available_bytes(output) do
      {:ok, bytes}
    else
      {:error, reason} ->
        {:error, {:workspace_free_space_check_failed, root, reason}}

      {output, status} ->
        {:error, {:workspace_free_space_check_failed, root, status, output}}
    end
  end

  def free_bytes(worker_host) when is_binary(worker_host) do
    root = Config.settings!().workspace.root

    script =
      [
        "set -eu",
        remote_shell_assign("root", root),
        "mkdir -p \"$root\"",
        "df -Pk \"$root\" | awk 'NR==2 {print $4}'"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_df_available_bytes(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_free_space_check_failed, worker_host, root, status, output}}

      {:error, reason} ->
        {:error, {:workspace_free_space_check_failed, worker_host, root, reason}}
    end
  end

  @spec reclaim_stale_workspaces() :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces, do: reclaim_stale_workspaces(Config.repo_key!(), MapSet.new(), DateTime.utc_now())

  @spec reclaim_stale_workspaces(term()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(protected_identifiers),
    do: reclaim_stale_workspaces(Config.repo_key!(), protected_identifiers, DateTime.utc_now())

  @spec reclaim_stale_workspaces(String.t(), term()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(repo_key, protected_identifiers) when is_binary(repo_key),
    do: reclaim_stale_workspaces(repo_key, protected_identifiers, DateTime.utc_now())

  @spec reclaim_stale_workspaces(term(), DateTime.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(protected_identifiers, %DateTime{} = now) do
    reclaim_stale_workspaces(Config.repo_key!(), protected_identifiers, now)
  end

  @spec reclaim_stale_workspaces(String.t(), term(), DateTime.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(repo_key, protected_identifiers, %DateTime{} = now) when is_binary(repo_key) do
    with {:ok, stale_entries} <- scan_stale_workspaces(repo_key, now) do
      {:ok, delete_stale_workspaces(stale_entries, protected_identifiers)}
    end
  end

  @doc """
  Identify age-eligible (stale) workspace entries without deleting anything.

  The filesystem traversal lives here so callers can run the expensive scan off
  the orchestrator process and apply the protected-identifier filter against
  fresh state at delete time. Returns `{:ok, []}` when age GC is disabled.
  """
  @spec scan_stale_workspaces(String.t(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def scan_stale_workspaces(repo_key, %DateTime{} = now) when is_binary(repo_key) do
    lifecycle = Config.settings!().workspace.lifecycle

    if lifecycle.age_gc_enabled == true do
      cutoff = DateTime.to_unix(now) - lifecycle.max_age_days * 86_400

      with {:ok, entries} <- local_workspace_entries(repo_key) do
        {:ok, Enum.filter(entries, &(&1.mtime <= cutoff))}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Delete the stale workspace entries returned by `scan_stale_workspaces/2`,
  skipping any whose identifier is currently protected (active).

  This step is cheap relative to the scan, so it is safe to run on the
  orchestrator process with an up-to-date protected set, closing the race where
  a workspace becomes active between the scan and the delete.
  """
  @spec delete_stale_workspaces([map()], term()) :: [lifecycle_action()]
  def delete_stale_workspaces(stale_entries, protected_identifiers) when is_list(stale_entries) do
    protected = normalize_identifier_set(protected_identifiers)

    stale_entries
    |> Enum.reject(&MapSet.member?(protected, &1.identifier))
    |> Enum.map(&delete_lifecycle_workspace(&1, :age_gc))
  end

  @spec sweep_orphan_workspaces(Enumerable.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def sweep_orphan_workspaces(tracked_identifiers) do
    sweep_orphan_workspaces(Config.repo_key!(), tracked_identifiers)
  end

  @spec sweep_orphan_workspaces(String.t(), Enumerable.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def sweep_orphan_workspaces(repo_key, tracked_identifiers) when is_binary(repo_key) do
    lifecycle = Config.settings!().workspace.lifecycle
    tracked = normalize_identifier_set(tracked_identifiers)

    with {:ok, entries} <- local_workspace_entries(repo_key) do
      actions =
        entries
        |> Enum.reject(&MapSet.member?(tracked, &1.identifier))
        |> Enum.map(&perform_orphan_action(&1, lifecycle))

      {:ok, actions}
    end
  end

  @spec local_workspace_entries() :: {:ok, [map()]} | {:error, term()}
  def local_workspace_entries do
    local_workspace_entries(Config.repo_key!())
  end

  @spec local_workspace_entries(String.t()) :: {:ok, [map()]} | {:error, term()}
  def local_workspace_entries(repo_key) when is_binary(repo_key) do
    settings = Config.settings!()
    safe_repo_key = safe_identifier(repo_key)
    root = Path.join(Path.expand(settings.workspace.root), safe_repo_key)
    trash_dir = settings.workspace.lifecycle.trash_dir |> Path.split() |> List.first()

    cond do
      !File.exists?(root) ->
        {:ok, []}

      !File.dir?(root) ->
        {:error, {:workspace_root_not_directory, root}}

      true ->
        case File.ls(root) do
          {:ok, names} ->
            entries =
              names
              |> Enum.reject(&(&1 == trash_dir))
              |> Enum.flat_map(&local_workspace_entry(root, safe_repo_key, &1))

            {:ok, entries}

          {:error, reason} ->
            {:error, {:workspace_root_list_failed, root, reason}}
        end
    end
  end

  defp local_workspace_entry(root, repo_key, name) do
    path = Path.join(root, name)

    case File.stat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} when is_integer(mtime) ->
        [%{repo_key: repo_key, identifier: safe_identifier(name), name: name, path: path, mtime: mtime}]

      _ ->
        []
    end
  end

  defp normalize_identifier_set(identifiers) do
    identifiers
    |> Enum.flat_map(fn
      identifier when is_binary(identifier) -> [safe_identifier(identifier)]
      %{identifier: identifier} when is_binary(identifier) -> [safe_identifier(identifier)]
      %{issue_identifier: identifier} when is_binary(identifier) -> [safe_identifier(identifier)]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp perform_orphan_action(entry, %{orphan_action: "delete"}) do
    delete_lifecycle_workspace(entry, :orphan)
  end

  defp perform_orphan_action(entry, %{orphan_action: "trash"} = lifecycle) do
    trash_lifecycle_workspace(entry, :orphan, lifecycle)
  end

  defp perform_orphan_action(entry, _lifecycle) do
    Logger.warning("Workspace orphan found repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} action=log")

    %{
      repo_key: entry.repo_key,
      identifier: entry.identifier,
      path: entry.path,
      worker_host: nil,
      action: :logged,
      reason: :orphan
    }
  end

  defp delete_lifecycle_workspace(entry, reason) do
    case remove(entry.path) do
      {:ok, _removed_paths} ->
        Logger.warning("Workspace lifecycle removed repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} reason=#{reason} action=delete")

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          worker_host: nil,
          action: :deleted,
          reason: reason
        }

      {:error, error, output} ->
        log_workspace_removal_failure(entry.path, issue_context(%{identifier: entry.identifier, repo_key: entry.repo_key}), nil, error, output)

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          worker_host: nil,
          action: :failed,
          reason: reason,
          error: error
        }
    end
  end

  defp trash_lifecycle_workspace(entry, reason, lifecycle) do
    root = Path.expand(Config.settings!().workspace.root)
    trash_root = Path.join([root, entry.repo_key, lifecycle.trash_dir])
    destination = unique_trash_destination(trash_root, entry.identifier)

    with :ok <- validate_workspace_path(entry.path, nil),
         :ok <- File.mkdir_p(trash_root),
         :ok <- File.rename(entry.path, destination) do
      clear_after_create_pending(entry.path, nil)
      Logger.warning("Workspace orphan found repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} action=trash destination=#{destination}")

      %{
        repo_key: entry.repo_key,
        identifier: entry.identifier,
        path: entry.path,
        destination: destination,
        worker_host: nil,
        action: :trashed,
        reason: reason
      }
    else
      {:error, error} ->
        Logger.warning("Workspace lifecycle trash failed repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} destination=#{destination} reason=#{inspect(error)}")

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          destination: destination,
          worker_host: nil,
          action: :failed,
          reason: reason,
          error: error
        }
    end
  end

  defp unique_trash_destination(trash_root, identifier) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    base = Path.join(trash_root, "#{timestamp}-#{identifier}")

    if File.exists?(base) do
      Path.join(trash_root, "#{timestamp}-#{System.unique_integer([:positive])}-#{identifier}")
    else
      base
    end
  end

  defp parse_df_available_bytes(output) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(&parse_df_available_line/1)
    |> case do
      blocks when is_integer(blocks) and blocks >= 0 -> {:ok, blocks * 1024}
      _ -> {:error, {:invalid_df_output, output}}
    end
  end

  defp parse_df_available_line(line) do
    fields = String.split(line, ~r/\s+/, trim: true)

    cond do
      fields == [] or hd(fields) == "Filesystem" ->
        nil

      length(fields) == 1 ->
        parse_non_negative_integer(hd(fields))

      length(fields) >= 4 ->
        fields |> Enum.at(3) |> parse_non_negative_integer()

      true ->
        nil
    end
  end

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp remove_issue_workspace(identifier, issue_context, worker_host) when is_binary(identifier) do
    safe_repo_key = safe_identifier(issue_context.repo_key)
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_repo_key, safe_id, worker_host) do
      {:ok, workspace} ->
        case remove_workspace(workspace, issue_context, worker_host) do
          {:ok, _removed_paths} ->
            :ok

          {:error, reason, output} ->
            log_workspace_removal_failure(workspace, issue_context, worker_host, reason, output)
        end

        :ok

      {:error, reason} ->
        Logger.warning("Workspace removal skipped #{issue_log_context(issue_context)} identifier=#{identifier} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")
        :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context =
      issue_or_identifier
      |> issue_context(Keyword.get(opts, :repo_key))
      |> Map.put(:on_hook, Keyword.get(opts, :on_hook))

    hooks = hooks_for_issue_context(issue_context, opts)
    env = Keyword.get(opts, :env, [])

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(
          command,
          workspace,
          issue_context,
          "before_run",
          worker_host,
          hooks.timeout_ms,
          env
        )
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, Keyword.get(opts, :repo_key))
    hooks = hooks_for_issue_context(issue_context, opts)
    env = Keyword.get(opts, :env, [])

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(
          command,
          workspace,
          issue_context,
          "after_run",
          worker_host,
          hooks.timeout_ms,
          env
        )
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_repo_key, safe_id, nil) when is_binary(safe_repo_key) and is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(safe_repo_key)
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_repo_key, safe_id, worker_host)
       when is_binary(safe_repo_key) and is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join([Config.settings!().workspace.root, safe_repo_key, safe_id])}
  end

  defp worktree_branch(%{workspace_branch: branch}) when is_binary(branch) and branch != "" do
    branch
  end

  defp worktree_branch(%{issue_identifier: identifier}) when is_binary(identifier) and identifier != "" do
    "auto/#{identifier}"
  end

  defp worktree_branch(_issue_context), do: "auto/issue"

  defp worktree_base_ref(%{workspace_base_ref: base_ref}) when is_binary(base_ref) and base_ref != "", do: base_ref
  defp worktree_base_ref(_issue_context), do: nil

  # Base ref a fresh local worktree branches off. An explicit base_ref (PR runs)
  # wins. Otherwise default to the configured repo base branch, preferring the
  # fetched remote-tracking ref (`origin/<branch>`) and falling back to a local
  # branch of the same name. Returns nil when no base branch is configured or the
  # ref can't be resolved, so creation falls back to the prior HEAD behavior.
  defp worktree_create_base_ref(_repo, _issue_context, base_ref)
       when is_binary(base_ref) and base_ref != "",
       do: base_ref

  defp worktree_create_base_ref(repo, issue_context, _base_ref) do
    case configured_base_branch(issue_context) do
      nil -> nil
      branch -> Enum.find(["origin/#{branch}", branch], &git_ref_exists?(repo, &1))
    end
  end

  # Remote worker variant: the dispatch script runs `git fetch origin` itself, so
  # the remote-tracking ref is resolved on the worker rather than checked here.
  defp remote_worktree_create_base_ref(_issue_context, base_ref)
       when is_binary(base_ref) and base_ref != "",
       do: base_ref

  defp remote_worktree_create_base_ref(issue_context, _base_ref) do
    case configured_base_branch(issue_context) do
      nil -> nil
      branch -> "origin/#{branch}"
    end
  end

  defp configured_base_branch(issue_context) do
    case Config.repo_base_branch(Map.get(issue_context, :repo_key)) do
      {:ok, base_branch} -> sanitize_base_branch(base_branch)
      {:error, _reason} -> nil
    end
  end

  defp sanitize_base_branch(base_branch) when is_binary(base_branch) do
    case String.trim(base_branch) do
      "" -> nil
      "origin/" <> branch -> blank_to_nil(String.trim(branch))
      "refs/heads/" <> branch -> blank_to_nil(String.trim(branch))
      branch -> blank_to_nil(branch)
    end
  end

  defp sanitize_base_branch(_base_branch), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp git_ref_exists?(repo, ref) do
    case resolve_git_commit(repo, ref) do
      {:ok, _output} -> true
      _ -> false
    end
  end

  defp resolve_git_commit(repo, ref) do
    case git_output(repo, ["rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      error -> error
    end
  end

  defp maybe_run_after_create_hook(workspace, issue_context, after_create, worker_host) do
    hooks = hooks_for_issue_context(issue_context)

    case after_create do
      _after_create when is_nil(hooks.after_create) ->
        :ok

      :new ->
        run_after_create_hook(hooks, workspace, issue_context, worker_host)

      :unfinished ->
        Logger.info(
          "Running workspace hook an earlier run left unfinished hook=after_create #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}"
        )

        run_after_create_hook(hooks, workspace, issue_context, worker_host)

      :done ->
        :ok
    end
  end

  defp run_after_create_hook(hooks, workspace, issue_context, worker_host) do
    mark_after_create_pending(workspace, worker_host)
    run = fn -> run_after_create_hook_with_retry(hooks, workspace, issue_context, worker_host) end

    case run_on_base_tree(workspace, issue_context, worker_host, run) do
      :ok -> clear_after_create_pending(workspace, worker_host)
      :skipped -> :ok
      error -> error
    end
  end

  # `after_create` runs on the host, outside the agent sandbox, and usually runs the
  # repo's own build tool (`mix deps.get` evaluates `mix.exs`). A local worktree can
  # be created on a branch an agent already pushed to (a rework, a PR run, a
  # workspace removed and made again), so the hook runs on the tree of the base
  # branch instead: the worktree is detached at the base commit for the hook and put
  # back on its branch afterwards. That runs on the base tree too, so a worktree an
  # earlier hook left detached goes back on its branch. Ignored files (`deps/`,
  # `_build/`) an agent wrote in a reused worktree are removed first: the hook
  # installs them again. A worktree with changes of its own can't be switched, so
  # its hook is skipped, and its pending marker kept. On an SSH worker the hook's
  # wrapper script does the same (see `remote_base_tree_lines/3`).
  defp run_on_base_tree(workspace, issue_context, nil, run) do
    settings = settings_for_issue_context(issue_context)

    case settings.workspace.strategy do
      "worktree" -> run_on_local_base_tree(workspace, issue_context, settings, run)
      _strategy -> run.()
    end
  end

  defp run_on_base_tree(_workspace, _issue_context, _worker_host, run), do: run.()

  defp run_on_local_base_tree(workspace, issue_context, settings, run) do
    base_commit = trusted_base_commit(issue_context, settings)
    branch = worktree_branch(issue_context)

    cond do
      is_nil(base_commit) ->
        skip_base_tree_hook(workspace, issue_context, branch, "no_base_commit")

      not worktree_clean?(workspace) ->
        skip_base_tree_hook(workspace, issue_context, branch, "uncommitted_changes")

      true ->
        unless same_tree?(workspace, base_commit) do
          Logger.info("Running workspace hook on the base branch tree hook=after_create #{issue_log_context(issue_context)} workspace=#{workspace} branch=#{branch} base_commit=#{base_commit}")
        end

        run_detached_at(workspace, base_commit, branch, run)
    end
  end

  defp skip_base_tree_hook(workspace, issue_context, branch, reason) do
    Logger.warning("Skipping workspace hook: it can't run on the base branch tree hook=after_create #{issue_log_context(issue_context)} workspace=#{workspace} branch=#{branch} reason=#{reason}")

    :skipped
  end

  defp run_detached_at(workspace, commit, branch, run) do
    with :ok <- checkout(workspace, ["--detach", commit]) do
      result = with :ok <- git_step(workspace, ["clean", "-ffdxq"]), do: run.()
      with :ok <- checkout(workspace, ["--force", branch]), do: result
    end
  end

  # The commit a new branch starts from: the configured base branch, a managed
  # clone's `origin/HEAD`, or else the source repo's own `HEAD`. Nil when it can't
  # be resolved, or the repo setting is gone after the workflow refresh.
  defp trusted_base_commit(issue_context, settings) do
    with {:ok, repo} <- local_worktree_repo(settings),
         ref = worktree_create_base_ref(repo, issue_context, nil) || managed_clone_default_ref(repo, settings) || "HEAD",
         {:ok, commit} <- resolve_git_commit(repo, ref) do
      commit
    else
      _error -> nil
    end
  end

  defp managed_clone_default_ref(repo, %{workspace: %{github: github}}) when is_binary(github) do
    if git_ref_exists?(repo, "origin/HEAD"), do: "origin/HEAD"
  end

  defp managed_clone_default_ref(_repo, _settings), do: nil

  # Failures name the ref they couldn't resolve, so they never compare equal.
  defp same_tree?(workspace, commit) do
    git_output(workspace, ["rev-parse", "--verify", "HEAD^{tree}"]) ==
      git_output(workspace, ["rev-parse", "--verify", "#{commit}^{tree}"])
  end

  defp worktree_clean?(workspace) do
    git_output(workspace, ["status", "--porcelain=v1", "--untracked-files=all"]) == {:ok, ""}
  end

  defp checkout(workspace, args), do: git_step(workspace, ["checkout", "--quiet" | args])

  defp git_step(workspace, args) do
    case run_git(workspace, args) do
      :ok -> :ok
      {:error, reason, _output} -> {:error, reason}
    end
  end

  # A timeout is usually a loaded machine or a cold cache rather than a hang. The
  # second try starts from whatever the first one got done, and runs within this
  # run, so it costs no agent attempt. Only a local hook is retried: a timed-out
  # remote hook can still be running on the worker, and a second copy would race it.
  defp run_after_create_hook_with_retry(%Hooks{after_create: command} = hooks, workspace, issue_context, worker_host) do
    timeout_ms = Hooks.after_create_timeout_ms(hooks)
    env = workspace_ref_hook_env(issue_context)
    command = after_create_command(command, workspace, issue_context, worker_host)
    run = fn -> run_hook(command, workspace, issue_context, "after_create", worker_host, timeout_ms, env) end

    case run.() do
      {:error, {:workspace_hook_timeout, "after_create", _timeout_ms}} when is_nil(worker_host) ->
        Logger.warning(
          "Retrying workspace hook after timeout hook=after_create #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} timeout_ms=#{timeout_ms}"
        )

        run.()

      result ->
        result
    end
  end

  # Marks a workspace whose `after_create` hasn't succeeded yet, so a later run
  # runs it again there rather than starting the agent in a half-set-up
  # workspace. The marker sits beside the workspace, not in it, so a hook that
  # clones into the empty workspace still can, and it goes when the workspace is
  # removed or trashed. On an SSH worker the prepare script writes the marker for
  # a workspace it creates, the hook keeps it (see `after_create_command/4`), and
  # the next prepare script reads it.
  defp after_create_pending_marker(workspace) do
    Path.join(Path.dirname(workspace), ".#{Path.basename(workspace)}.after_create_pending")
  end

  defp mark_after_create_pending(workspace, nil), do: File.touch!(after_create_pending_marker(workspace))
  defp mark_after_create_pending(_workspace, _worker_host), do: :ok

  defp clear_after_create_pending(workspace, nil) do
    _ = File.rm(after_create_pending_marker(workspace))
    :ok
  end

  defp clear_after_create_pending(_workspace, _worker_host), do: :ok

  # A remote hook writes the pid of its shell into the marker and removes the marker
  # only once it succeeds. A timeout kills only the local `ssh`, so the hook can
  # still be running on the worker, and still finish there: the pid lets the next
  # run's prepare script tell such a hook from one that died, and wait for it
  # rather than start a second copy beside it.
  defp after_create_command(command, _workspace, _issue_context, nil), do: command

  defp after_create_command(command, workspace, issue_context, _worker_host) do
    marker = shell_escape(after_create_pending_marker(workspace))
    {detach, restore} = remote_base_tree_lines(settings_for_issue_context(issue_context), issue_context, marker)

    [
      "{",
      ~s(printf '%s\\n' "$$" > #{marker} || exit 1),
      detach,
      "(",
      command,
      ")",
      "after_create_status=$?",
      restore,
      ~s(if [ "$after_create_status" -eq 0 ]; then rm -f #{marker}; fi),
      ~s(exit "$after_create_status"),
      "}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # The remote side of `run_on_base_tree/4`: shell lines around a worktree's hook
  # that detach it at the base commit (`origin/<base_branch>`, else the worker
  # repo's `HEAD`) and put it back on its branch afterwards, with repo hooks off.
  # A worktree with changes of its own, or no base commit, skips the hook: the
  # wrapper empties the marker, so it reads as pending rather than running, prints
  # the skip line and exits 47, which `run_hook/7` logs as a skip rather than a
  # failure.
  defp remote_base_tree_lines(%{workspace: %{strategy: "worktree", repo: repo}}, issue_context, marker) do
    base_refs = Enum.map_join(List.wrap(remote_worktree_create_base_ref(issue_context, nil)) ++ ["HEAD"], " ", &shell_escape/1)
    branch = shell_escape(worktree_branch(issue_context))

    detach = """
    #{remote_safe_git_functions()}
    after_create_skip() {
      : > #{marker}
      printf '#{@remote_after_create_skipped_line}\\t%s\\n' "$1"
      exit #{@remote_after_create_skipped_status}
    }
    #{remote_shell_assign("after_create_repo", repo || "")}
    after_create_base=
    if [ -n "$after_create_repo" ]; then
      for after_create_ref in #{base_refs}; do
        after_create_base=$(symphony_git "$after_create_repo" rev-parse --verify --quiet --end-of-options "$after_create_ref^{commit}") && break
        after_create_base=
      done
    fi
    [ -n "$after_create_base" ] || after_create_skip no_base_commit
    after_create_changes=$(symphony_git . status --porcelain=v1 --untracked-files=all) || after_create_skip uncommitted_changes
    [ -z "$after_create_changes" ] || after_create_skip uncommitted_changes
    symphony_git . checkout --quiet --detach "$after_create_base" || exit 1
    symphony_git . clean -ffdxq || { symphony_git . checkout --quiet --force #{branch}; exit 1; }\
    """

    restore = ~s(symphony_git . checkout --quiet --force #{branch} || { [ "$after_create_status" -ne 0 ] || after_create_status=1; })

    {detach, restore}
  end

  defp remote_base_tree_lines(_settings, _issue_context, _marker), do: {"", ""}

  # Shell lines for the remote prepare scripts. The marker path matches
  # `after_create_pending_marker/1`. A marker naming a live process is a hook an
  # earlier run timed out on that is still running: the prepare fails (exit 46),
  # before it touches the workspace, and a later retry finds it finished.
  defp remote_after_create_running_check do
    """
    after_create_marker="${workspace%/*}/.${workspace##*/}.after_create_pending"
    if [ -f "$after_create_marker" ]; then
      after_create_pid=$(cat "$after_create_marker")
      if [ -n "$after_create_pid" ] && kill -0 "$after_create_pid" 2>/dev/null; then
        echo "workspace_after_create_still_running: pid $after_create_pid"
        exit 46
      fi
    fi\
    """
  end

  # Marks a workspace the prepare script just created, in the same command, so
  # one whose hook never starts (its `ssh` fails, or the run stops first) is set
  # up on the next run. An empty marker names no process, so it reads as pending,
  # not running; the hook overwrites it with its pid.
  defp remote_after_create_pending_mark_command(%{hooks: %Hooks{after_create: nil}}), do: ""

  defp remote_after_create_pending_mark_command(_settings) do
    ~s(if [ "$created" = 1 ]; then : > "$after_create_marker"; fi)
  end

  defp remote_after_create_marker_remove_command do
    ~s(rm -f "${workspace%/*}/.${workspace##*/}.after_create_pending")
  end

  defp remote_workspace_output_command do
    """
    after_create_pending=0
    if [ "$created" = 0 ] && [ -f "$after_create_marker" ]; then
      after_create_pending=1
    fi
    printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' "$created" "$physical_workspace" "$after_create_pending"\
    """
  end

  defp maybe_run_before_remove_hook(workspace, issue_context, nil) do
    hooks = hooks_for_issue_context(issue_context)

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            env = before_remove_hook_env(issue_context)

            run_hook(
              command,
              workspace,
              issue_context,
              "before_remove",
              nil,
              hooks.timeout_ms,
              env
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, issue_context, worker_host) when is_binary(worker_host) do
    settings = settings_for_issue_context(issue_context)
    hooks = settings.hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        env = before_remove_hook_env(issue_context)

        script =
          [
            "set -eu",
            remote_shell_assign("root", settings.workspace.root),
            remote_shell_assign("workspace", workspace),
            remote_workspace_mutation_containment_preamble(),
            "if [ -d \"$workspace\" ]; then",
            remote_before_remove_env_assignments(env, settings),
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        case run_remote_command(worker_host, script, hooks.timeout_ms) do
          {:ok, {output, status}} ->
            handle_remote_before_remove_result({output, status}, workspace, issue_context, worker_host)

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_non_containment_hook_failure()
    end
  end

  defp handle_remote_before_remove_result({output, status}, workspace, issue_context, worker_host) do
    case remote_workspace_containment_failure?(status, output) do
      true ->
        {:error, {:workspace_remove_failed, worker_host, status, output}}

      false ->
        handle_hook_command_result({output, status}, workspace, issue_context, "before_remove")
    end
  end

  defp hooks_for_issue_context(issue_context, opts \\ []) do
    case Keyword.get(opts, :settings) do
      %{hooks: hooks} ->
        hooks

      _settings ->
        issue_context
        |> Map.get(:repo_key)
        |> settings_for_issue_context()
        |> Map.fetch!(:hooks)
    end
  end

  defp settings_for_issue_context(%{repo_key: repo_key}), do: settings_for_issue_context(repo_key)

  defp settings_for_issue_context(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} ->
        settings

      {:error, {:unknown_repo_key, _repo_key}} ->
        Config.settings!()

      {:error, _reason} ->
        Config.settings_for_repo!(repo_key)
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp ignore_non_containment_hook_failure({:error, {:workspace_remove_failed, _worker_host, status, _output}} = error)
       when status in 50..53,
       do: error

  defp ignore_non_containment_hook_failure(result), do: ignore_hook_failure(result)

  defp remote_workspace_containment_failure?(status, output) when status in 50..53 and is_binary(output) do
    String.contains?(output, ["workspace_root_unreadable:", "workspace_path_unreadable:", "workspace_symlink_rejected:", "workspace_equals_root:", "workspace_outside_root:"])
  end

  defp remote_workspace_containment_failure?(_status, _output), do: false

  defp workspace_ref_hook_env(issue_context) do
    settings = settings_for_issue_context(issue_context)
    branch = worktree_branch(issue_context)

    case configured_hook_repo(issue_context, settings) do
      nil -> [{"SYMPHONY_BRANCH", branch}]
      repo -> [{"SYMPHONY_REPO", repo}, {"SYMPHONY_BRANCH", branch}]
    end
  end

  defp before_remove_hook_env(issue_context), do: workspace_ref_hook_env(issue_context)

  defp configured_hook_repo(issue_context, settings) do
    issue_context
    |> configured_repo_paths(settings)
    |> Enum.find_value(&(GitHubRepo.from_url(&1) || github_repo_from_git_dir(&1)))
  end

  defp configured_repo_paths(%{repo_key: repo_key}, settings) do
    (repo_paths_for_key(repo_key) ++ [settings.workspace.repo])
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp repo_paths_for_key(repo_key) do
    case Config.repos() do
      {:ok, repos} ->
        repos
        |> Enum.filter(&(&1.name == repo_key))
        |> Enum.map(& &1.path)

      {:error, _reason} ->
        []
    end
  end

  defp github_repo_from_git_dir(path) do
    expanded_path = Path.expand(path)

    if File.dir?(expanded_path) do
      case git_output(expanded_path, ["remote", "get-url", "origin"]) do
        {:ok, output} -> GitHubRepo.from_url(String.trim(output))
        {:error, _reason, _output} -> nil
      end
    end
  end

  defp remote_before_remove_env_assignments(env, settings) do
    env
    |> remote_env_assignments()
    |> Kernel.++(remote_before_remove_repo_env_fallback(settings))
    |> Enum.join("\n")
  end

  defp remote_before_remove_repo_env_fallback(%{workspace: %{repo: repo}}) when is_binary(repo) and repo != "" do
    [
      remote_shell_assign("symphony_configured_repo", repo),
      """
      if [ -z "${SYMPHONY_REPO:-}" ] && [ -n "$symphony_configured_repo" ]; then
        symphony_origin_url="$symphony_configured_repo"
        if [ -d "$symphony_configured_repo" ]; then
          symphony_origin_url=$(git -C "$symphony_configured_repo" remote get-url origin 2>/dev/null || true)
        fi
        case "$symphony_origin_url" in
          git@github.com:*)
            SYMPHONY_REPO="${symphony_origin_url#git@github.com:}"
            ;;
          https://github.com/*)
            SYMPHONY_REPO="${symphony_origin_url#https://github.com/}"
            ;;
          ssh://git@github.com/*)
            SYMPHONY_REPO="${symphony_origin_url#ssh://git@github.com/}"
            ;;
        esac
        SYMPHONY_REPO="${SYMPHONY_REPO%.git}"
        SYMPHONY_REPO="${SYMPHONY_REPO%/}"
        if [ -n "$SYMPHONY_REPO" ]; then
          export SYMPHONY_REPO
        fi
      fi
      """
    ]
  end

  defp remote_before_remove_repo_env_fallback(_settings), do: []

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_ms, env) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")

    notify_hook(issue_context, {:started, hook_name, timeout_ms})
    result = run_hook_command(command, workspace, worker_host, env, timeout_ms)
    notify_hook(issue_context, {:finished, hook_name})

    case result do
      {:ok, cmd_result} when hook_name == "after_create" and is_binary(worker_host) ->
        handle_remote_after_create_result(cmd_result, workspace, issue_context)

      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:timeout, output} ->
        Logger.warning(
          "Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} timeout_ms=#{timeout_ms} output_tail=#{inspect(hook_output_tail(output))}"
        )

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_remote_after_create_result(cmd_result, workspace, issue_context) do
    case remote_after_create_skip_reason(cmd_result) do
      nil -> handle_hook_command_result(cmd_result, workspace, issue_context, "after_create")
      reason -> skip_base_tree_hook(workspace, issue_context, worktree_branch(issue_context), reason)
    end
  end

  defp remote_after_create_skip_reason({output, @remote_after_create_skipped_status}) do
    case Regex.run(~r/^#{@remote_after_create_skipped_line}\t(\w+)$/m, output) do
      [_line, reason] -> reason
      nil -> nil
    end
  end

  defp remote_after_create_skip_reason(_cmd_result), do: nil

  # A hook runs under its own timeout, so the run's owner (the orchestrator) holds its
  # stall and watchdog clocks while one runs.
  defp notify_hook(%{on_hook: on_hook}, event) when is_function(on_hook, 1), do: on_hook.(event)
  defp notify_hook(_issue_context, _event), do: :ok

  # Runs the hook as a port in its own process, rather than through `System.cmd/3`,
  # so a timeout can stop a local hook (a retry must not race the first try) and
  # still report what it printed. The process traps exits so that a run stopped
  # mid-hook stops the hook too, rather than leave it running beside the
  # `after_create` the next run starts in the same workspace.
  defp run_hook_command(command, workspace, worker_host, env, timeout_ms) do
    owner = self()

    Task.async(fn ->
      Process.flag(:trap_exit, true)

      with {:ok, port} <- open_hook_port(command, workspace, worker_host, env) do
        collect_hook_output(port, owner, [], System.monotonic_time(:millisecond) + timeout_ms)
      end
    end)
    |> Task.await(:infinity)
  end

  defp open_hook_port(command, workspace, nil, env) do
    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: ["-lc", command],
      cd: workspace,
      env: Enum.map(env ++ [no_gradle_daemon_env()], fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
    ]

    {:ok, Port.open({:spawn_executable, System.find_executable("sh") || "/bin/sh"}, port_opts)}
  end

  defp open_hook_port(command, workspace, worker_host, env) when is_binary(worker_host) do
    script =
      env
      |> remote_env_assignments()
      |> Kernel.++(["cd #{shell_escape(workspace)} && #{command}"])
      |> Enum.join("\n")

    SSH.start_port(worker_host, script)
  end

  # A local hook runs outside the agent's sandbox. A Gradle daemon it started
  # would serve later builds that share its registry and outlive the run, and one
  # it joined could have been started inside an agent's sandbox, so its builds
  # run without one (see `SymphonyElixir.AgentEnv.gradle_env/1`).
  defp no_gradle_daemon_env do
    {"GRADLE_OPTS", String.trim("#{System.get_env("GRADLE_OPTS")} -Dorg.gradle.daemon=false")}
  end

  defp collect_hook_output(port, owner, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect_hook_output(port, owner, [output, data], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, {IO.iodata_to_binary(output), status}}

      {:EXIT, ^owner, _reason} ->
        stop_hook_process(port)
        exit(:shutdown)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        stop_hook_process(port)
        {:timeout, IO.iodata_to_binary(output)}
    end
  end

  # Kills the hook's shell and what it started; the port closes when the task that
  # owns it returns. A port's program leads its own process group, so one signal to
  # the group reaches them all at once: killing the shell's children first would let
  # the shell start its next command, alongside the retry. The group is stopped
  # before the tree walk, which catches what moved to a group of its own. For a
  # remote hook this kills only the local `ssh`: with no pty the worker sends the
  # hook no hangup, so it can keep running there. A git network call is stopped the
  # same way, with the `ssh` it started.
  defp stop_hook_process(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      signal_process_group(os_pid, "-STOP")
      ProcessTree.terminate_port_descendants(port)
      signal_process_group(os_pid, "-KILL")
    end
  end

  defp signal_process_group(os_pid, signal) do
    System.cmd("kill", [signal, "--", "-#{os_pid}"], stderr_to_stdout: true)
  end

  # The last lines a timed-out hook printed, to tell a hang (no output, or stuck on
  # one step) from a hook that was still making progress.
  defp hook_output_tail(output) do
    output
    |> String.split(["\r\n", "\n", "\r"], trim: true)
    |> Enum.take(-@hook_output_tail_lines)
    |> Enum.join("\n")
    |> String.slice(-@hook_output_tail_chars, @hook_output_tail_chars)
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp remote_env_assignments(env) when is_list(env) do
    Enum.map(env, fn {key, value} ->
      "export #{key}=#{shell_escape(to_string(value))}"
    end)
  end

  defp remote_env_assignments(_env), do: []

  defp log_workspace_removal_failure(workspace, issue_context, worker_host, reason, output) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning(
      "Workspace removal failed #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)} output=#{inspect(sanitized_output)}"
    )
  end

  defp log_local_worktree_failure(workspace, issue_context, reason, output) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace worktree preparation failed #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local reason=#{inspect(reason)} output=#{inspect(sanitized_output)}")
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, reason} ->
        workspace_canonicalize_error(reason, expanded_workspace)
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    root = Config.settings!().workspace.root

    with :ok <- validate_remote_workspace_candidate(workspace),
         :ok <- validate_remote_workspace_root(root) do
      validate_remote_workspace_containment(workspace, root)
    end
  end

  defp validate_remote_workspace_candidate(workspace) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      not String.starts_with?(workspace, "/") ->
        {:error, {:workspace_path_unreadable, workspace, :relative}}

      ".." in Path.split(workspace) ->
        {:error, {:workspace_path_unreadable, workspace, :parent_directory_segment}}

      true ->
        :ok
    end
  end

  defp validate_remote_workspace_root(root) do
    if String.starts_with?(root, "/") do
      :ok
    else
      {:error, {:workspace_root_unreadable, root, :relative}}
    end
  end

  defp validate_remote_workspace_containment(workspace, root) do
    cond do
      workspace == root ->
        {:error, {:workspace_equals_root, workspace, root}}

      not String.starts_with?(workspace <> "/", root <> "/") ->
        {:error, {:workspace_outside_root, workspace, root}}

      true ->
        :ok
    end
  end

  defp workspace_canonicalize_error(reason, _fallback_path)
       when is_tuple(reason) and tuple_size(reason) == 3 and elem(reason, 0) == :path_canonicalize_failed do
    {:error, {:workspace_path_unreadable, elem(reason, 1), elem(reason, 2)}}
  end

  defp workspace_canonicalize_error(reason, fallback_path) do
    {:error, {:workspace_path_unreadable, fallback_path, reason}}
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_branch_collision(output, requested_workspace) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "\t", parts: 4) do
        ["workspace_branch_already_checked_out_elsewhere", branch, at, requested] ->
          {:branch_already_checked_out_elsewhere, branch: branch, at: at, requested: requested}

        _ ->
          nil
      end
    end)
    |> case do
      nil ->
        {:branch_already_checked_out_elsewhere, branch: nil, at: nil, requested: requested_workspace}

      reason ->
        reason
    end
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 4) do
          [@remote_workspace_marker, created, path | pending] when created in ["0", "1"] and path != "" ->
            {remote_after_create_state(created, pending), path}

          _ ->
            nil
        end
      end)

    case payload do
      {after_create, workspace} when is_binary(workspace) ->
        {:ok, workspace, after_create}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp remote_after_create_state("1", _pending), do: :new
  defp remote_after_create_state("0", ["1"]), do: :unfinished
  defp remote_after_create_state("0", _pending), do: :done

  # The remove and the branch delete run under the repo's fetch lock, like a
  # dispatch's `worktree add`: both write the shared `.git/worktrees` and refs. The
  # `before_remove` hook runs before it, so a slow hook holds up no other dispatch.
  defp remove_local_worktree(repo, workspace, issue_context) do
    cond do
      registered_worktree?(repo, workspace) ->
        maybe_run_before_remove_hook(workspace, issue_context, nil)
        Fetcher.with_lock(repo, fn -> remove_registered_worktree(repo, workspace, issue_context) end)

      File.exists?(workspace) ->
        {:error, {:workspace_not_registered_worktree, workspace}, ""}

      true ->
        Fetcher.with_lock(repo, fn -> delete_local_worktree_branch(repo, worktree_branch(issue_context)) end)
    end
  end

  defp remove_registered_worktree(repo, workspace, issue_context) do
    with :ok <- run_git(repo, ["worktree", "remove", "--force", workspace]) do
      delete_local_worktree_branch(repo, worktree_branch(issue_context))
    end
  end

  defp delete_local_worktree_branch(repo, branch) do
    case git_branch_exists?(repo, branch) do
      true -> run_git_branch_delete(repo, branch)
      false -> :ok
    end
  end

  defp run_git_branch_delete(repo, branch) do
    case run_git(repo, ["branch", "-D", branch]) do
      :ok ->
        :ok

      {:error, _reason, output} = error ->
        case branch_checked_out_elsewhere?(output) do
          true ->
            Logger.warning("Workspace branch deletion skipped repo=#{repo} branch=#{branch} reason=checked_out_elsewhere output=#{inspect(sanitize_hook_output_for_log(output))}")

            :ok

          false ->
            error
        end
    end
  end

  defp branch_checked_out_elsewhere?(output) when is_binary(output) do
    String.contains?(output, ["checked out at", "is checked out", "used by worktree at"])
  end

  defp branch_checked_out_elsewhere?(_output), do: false

  defp registered_worktree?(repo, workspace) do
    workspace = Path.expand(workspace)

    case git_output(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
        |> Enum.any?(&(Path.expand(&1) == workspace))

      {:error, reason, output} ->
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning("Git worktree list failed repo=#{repo} workspace=#{workspace} reason=#{inspect(reason)} output=#{inspect(sanitized_output)}")

        false
    end
  end

  defp git_branch_exists?(repo, branch) do
    case safe_git(["-C", repo, "rev-parse", "--verify", "refs/heads/#{branch}"]) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp run_git(repo, args) when is_binary(repo) and is_list(args) do
    case git_output(repo, args) do
      {:ok, _output} -> :ok
      {:error, reason, output} -> {:error, reason, output}
    end
  end

  defp git_output(repo, args) when is_binary(repo) and is_list(args) do
    case safe_git(["-C", repo | args]) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:git_failed, repo, args, status}, output}
    end
  end

  defp safe_git_args(args) do
    Enum.flat_map(@safe_git_config_overrides, &["-c", &1]) ++ args
  end

  defp safe_git_opts(opts) do
    opts
    |> Keyword.put(:stderr_to_stdout, true)
    |> put_safe_git_env()
  end

  defp put_safe_git_env(opts) do
    existing_env =
      case Keyword.get(opts, :env, []) do
        env when is_list(env) -> env
        _env -> []
      end

    env =
      existing_env
      |> Enum.reject(fn
        {key, _value} -> key in @safe_git_env_keys
        _entry -> false
      end)
      |> Kernel.++(@safe_git_env)

    Keyword.put(opts, :env, env)
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp workspace_issue_context(workspace) do
    path_parts = Path.split(Path.expand(workspace))

    %{
      issue_id: nil,
      repo_key: workspace_repo_key(path_parts),
      issue_identifier: Path.basename(workspace),
      labels: []
    }
  end

  defp issue_context(issue_or_identifier, repo_key \\ nil)

  defp issue_context(%{id: issue_id, identifier: identifier} = issue, repo_key) do
    %{
      issue_id: issue_id,
      repo_key: issue_repo_key(issue, repo_key),
      issue_identifier: identifier || "issue",
      workspace_branch: workspace_branch(issue),
      workspace_base_ref: workspace_base_ref(issue),
      labels: issue_labels(issue)
    }
  end

  defp issue_context(identifier, repo_key) when is_binary(identifier) do
    %{
      issue_id: nil,
      repo_key: normalize_repo_key(repo_key),
      issue_identifier: identifier,
      workspace_branch: nil,
      workspace_base_ref: nil,
      labels: []
    }
  end

  defp issue_context(_identifier, repo_key) do
    %{
      issue_id: nil,
      repo_key: normalize_repo_key(repo_key),
      issue_identifier: "issue",
      workspace_branch: nil,
      workspace_base_ref: nil,
      labels: []
    }
  end

  defp issue_repo_key(%{repo_key: repo_key}, _fallback), do: normalize_repo_key(repo_key)
  defp issue_repo_key(%{"repo_key" => repo_key}, _fallback), do: normalize_repo_key(repo_key)
  defp issue_repo_key(_issue, fallback), do: normalize_repo_key(fallback)

  defp workspace_branch(%{workspace_branch: branch}) when is_binary(branch), do: String.trim(branch)
  defp workspace_branch(%{"workspace_branch" => branch}) when is_binary(branch), do: String.trim(branch)
  defp workspace_branch(_issue), do: nil

  defp workspace_base_ref(%{workspace_base_ref: ref}) when is_binary(ref), do: String.trim(ref)
  defp workspace_base_ref(%{"workspace_base_ref" => ref}) when is_binary(ref), do: String.trim(ref)
  defp workspace_base_ref(_issue), do: nil

  defp normalize_repo_key(repo_key) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp normalize_repo_key(_repo_key), do: Config.repo_key!()

  defp workspace_repo_key(path_parts) when is_list(path_parts) do
    case Enum.reverse(path_parts) do
      [_identifier, repo_key | _rest] -> repo_key
      _ -> Config.repo_key!()
    end
  end

  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []

  defp issue_log_context(%{issue_id: issue_id, repo_key: repo_key, issue_identifier: issue_identifier}) do
    "repo_key=#{repo_key || "default"} issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
