defmodule SymphonyElixir.Repo.Fetcher do
  @moduledoc """
  Runs every `git fetch` Symphony makes, one per repo at a time: the full
  `git fetch origin` before a dispatch (a worktree source checkout, a
  `workspace.source` clone, or the checkout a `WORKFLOW.md` is read from), and
  the targeted fetches of one branch or commit that run inside a worktree (the
  acceptance gate, a QA pass, the parent walkthrough, the `github_fetch_origin`
  agent tool).

  Two fetches of the same `.git` at once fail with `cannot lock ref`. A repo is
  keyed by its git common dir, so a worktree and the checkout it was added
  from share one lock. A full fetch asked for while another one of the same
  repo runs or waits joins that one and gets its result, instead of fetching
  again. A targeted fetch waits its turn and runs in its caller. A fetch that
  still fails with `cannot lock ref` (someone fetched the repo by hand, or a
  branch was force-pushed during the fetch) is run once more after a short
  delay.

  The same lock serializes the other git calls that write the shared repo's
  metadata (`with_lock/3`), such as a dispatch's `git worktree add` and every
  host-side `git worktree remove`: the worktrees of one repo share its refs,
  `.git/config` and `.git/worktrees`.

  A full fetch runs in its own process, so the server keeps taking requests.
  Without the server (some tests), every fetch runs in the caller, unlocked.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{GitConfigCommands, PathSafety, Workspace}

  @default_retry_delay_ms 1_000
  @lock_failure "cannot lock ref"
  @remote_fetch_args Enum.join(GitConfigCommands.subcommand_args(["fetch", "origin"]), " ")

  @type result :: {String.t(), non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @doc """
  Fetches `origin` in `repo` and returns git's output and exit status.

  `opts`:
    * `:server` - the server to ask (default `#{inspect(__MODULE__)}`).
    * `:git` - the git executable (default `"git"`).
    * `:network_timeout_ms` - how long the fetch may run before it is stopped
      (see `SymphonyElixir.Workspace.safe_git/3`). A stopped fetch hands the
      lock on like any other.
    * `:retry_delay_ms` - the wait before the retry after `cannot lock ref`
      (default #{@default_retry_delay_ms}, or the `:repo_fetch_retry_delay_ms`
      application env).
  """
  @spec fetch_origin(Path.t(), keyword()) :: result()
  def fetch_origin(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    repo = Path.expand(repo)
    git = Keyword.get(opts, :git, "git")
    git_opts = Keyword.take(opts, [:network_timeout_ms])
    fetch = fn -> with_retry(repo, fn -> Workspace.safe_git(git, ["-C", repo, "fetch", "origin"], git_opts) end, opts) end

    case server(opts) do
      nil -> fetch.()
      server -> server |> GenServer.call({:fetch, lock_key(repo), fetch}, :infinity) |> unwrap()
    end
  end

  @doc """
  Runs `fetch`, a targeted `git fetch` in `dir`, while no other fetch of the
  same repo runs, and once more after `cannot lock ref`. Returns what `fetch`
  returns.

  `fetch` runs in the caller. A result other than `{output, status}` is never
  retried. Takes the `:server` and `:retry_delay_ms` options of
  `fetch_origin/2`.
  """
  @spec fetch(Path.t(), (-> term()), keyword()) :: term()
  def fetch(dir, fetch, opts \\ []) when is_binary(dir) and is_function(fetch, 0) and is_list(opts) do
    dir = Path.expand(dir)
    with_lock(dir, fn -> with_retry(dir, fetch, opts) end, opts)
  end

  @doc """
  Runs `fun` in the caller while no fetch of the repo of `dir` runs and no
  other caller holds its lock, and returns what `fun` returns. It is never
  retried. Takes the `:server` option of `fetch_origin/2`.

  For a git call besides a fetch that writes the repo's shared metadata, such
  as a dispatch's `git worktree add` or `git worktree remove`. `fun` must not
  fetch the same repo: the lock is not reentrant.
  """
  @spec with_lock(Path.t(), (-> term()), keyword()) :: term()
  def with_lock(dir, fun, opts \\ []) when is_binary(dir) and is_function(fun, 0) and is_list(opts) do
    case server(opts) do
      nil ->
        fun.()

      server ->
        {:ok, ref} = GenServer.call(server, {:lock, lock_key(Path.expand(dir))}, :infinity)

        try do
          fun.()
        after
          GenServer.call(server, {:unlock, ref}, :infinity)
        end
    end
  end

  @doc """
  The shell commands a remote worker's dispatch script runs to fetch `origin` in
  `$repo`, under `set -e`, with the `symphony_git` the script defines
  (`SymphonyElixir.Workspace.remote_safe_git_functions/0`) and the options of
  `SymphonyElixir.GitConfigCommands.subcommand_args/1`. The lock lives in this
  node, so on the worker host a fetch that fails with `cannot lock ref` is only run
  once more, a second later.
  """
  @spec remote_fetch_origin_script() :: String.t()
  def remote_fetch_origin_script do
    """
    symphony_fetch_status=0
    symphony_fetch_output=$(symphony_git "$repo" #{@remote_fetch_args} 2>&1) || symphony_fetch_status=$?
    if [ "$symphony_fetch_status" -ne 0 ]; then
      printf '%s\\n' "$symphony_fetch_output" >&2
      case "$symphony_fetch_output" in
        *"#{@lock_failure}"*) sleep 1; symphony_git "$repo" #{@remote_fetch_args} ;;
        *) exit "$symphony_fetch_status" ;;
      esac
    fi\
    """
  end

  defp server(opts), do: GenServer.whereis(Keyword.get(opts, :server, __MODULE__))

  defp unwrap({:ok, result}), do: result
  defp unwrap({:crashed, reason}), do: exit(reason)

  # The git common dir: `<repo>/.git` for a checkout, and the dir a linked
  # worktree's `.git` file points at, through its `commondir`.
  defp lock_key(dir) do
    dot_git = Path.join(dir, ".git")

    common_dir =
      case File.read(dot_git) do
        {:ok, "gitdir:" <> gitdir} -> common_dir(Path.expand(String.trim(gitdir), dir))
        {:error, :eisdir} -> dot_git
        _other -> dir
      end

    case PathSafety.canonicalize(common_dir) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> common_dir
    end
  end

  defp common_dir(gitdir) do
    case File.read(Path.join(gitdir, "commondir")) do
      {:ok, commondir} -> Path.expand(String.trim(commondir), gitdir)
      {:error, _reason} -> gitdir
    end
  end

  # Each repo with a fetch running holds `{active, queue}`: the running full
  # fetch (`{:fetch, monitor, waiters}`) or the caller holding the lock
  # (`{:lock, monitor}`), and the requests waiting after it, oldest first.
  @impl true
  def handle_call({:fetch, key, fetch}, from, repos) do
    case repos do
      %{^key => {{:fetch, ref, waiters}, queue}} ->
        {:noreply, Map.put(repos, key, {{:fetch, ref, [from | waiters]}, queue})}

      %{^key => {active, queue}} ->
        {:noreply, Map.put(repos, key, {active, enqueue_fetch(queue, fetch, from)})}

      %{} ->
        {:noreply, Map.put(repos, key, {start({:fetch, fetch, [from]}), []})}
    end
  end

  def handle_call({:lock, key}, from, repos) do
    case repos do
      %{^key => {active, queue}} -> {:noreply, Map.put(repos, key, {active, queue ++ [{:lock, from}]})}
      %{} -> {:noreply, Map.put(repos, key, {start({:lock, from}), []})}
    end
  end

  def handle_call({:unlock, ref}, _from, repos) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, finish(repos, ref, :unlocked)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, repos) do
    {:noreply, finish(repos, ref, reason)}
  end

  defp enqueue_fetch(queue, fetch, from) do
    case Enum.split_while(queue, &(not match?({:fetch, _fetch, _waiters}, &1))) do
      {before, [{:fetch, queued, waiters} | rest]} -> before ++ [{:fetch, queued, [from | waiters]} | rest]
      {queue, []} -> queue ++ [{:fetch, fetch, [from]}]
    end
  end

  defp start({:fetch, fetch, waiters}) do
    {_pid, ref} = spawn_monitor(fn -> exit({:fetched, fetch.()}) end)
    {:fetch, ref, waiters}
  end

  # A caller that died while it waited is monitored all the same: its `:DOWN`
  # comes at once and hands the lock on.
  defp start({:lock, {pid, _tag} = from}) do
    ref = Process.monitor(pid)
    GenServer.reply(from, {:ok, ref})
    {:lock, ref}
  end

  defp finish(repos, ref, reason) do
    {key, {active, queue}} = Enum.find(repos, fn {_key, {active, _queue}} -> elem(active, 1) == ref end)

    with {:fetch, _ref, waiters} <- active do
      Enum.each(waiters, &GenServer.reply(&1, reply(reason)))
    end

    case queue do
      [] -> Map.delete(repos, key)
      [next | queue] -> Map.put(repos, key, {start(next), queue})
    end
  end

  defp reply({:fetched, result}), do: {:ok, result}
  defp reply(reason), do: {:crashed, reason}

  defp with_retry(dir, fetch, opts) do
    case fetch.() do
      {output, status} when is_binary(output) and is_integer(status) and status != 0 ->
        if String.contains?(output, @lock_failure), do: retry(dir, fetch, opts, output), else: {output, status}

      result ->
        result
    end
  end

  defp retry(dir, fetch, opts, output) do
    Logger.warning("git fetch could not lock a ref repo=#{dir} output=#{inspect(String.trim(output))}; retrying once")
    Process.sleep(Keyword.get_lazy(opts, :retry_delay_ms, &default_retry_delay_ms/0))
    fetch.()
  end

  defp default_retry_delay_ms do
    Application.get_env(:symphony_elixir, :repo_fetch_retry_delay_ms, @default_retry_delay_ms)
  end
end
