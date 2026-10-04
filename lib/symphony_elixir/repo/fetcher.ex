defmodule SymphonyElixir.Repo.Fetcher do
  @moduledoc """
  Runs every `git fetch origin` Symphony makes in a repo it fetches before a
  dispatch: a worktree source checkout, a `workspace.source` clone, or the
  checkout a `WORKFLOW.md` is read from.

  Two fetches of the same `.git` at once fail with `cannot lock ref`, so this
  server runs one fetch per repo at a time. A fetch asked for while another one
  of the same repo runs waits for that one and gets its result, instead of
  fetching again. A fetch that still fails with `cannot lock ref` (someone
  fetched the repo by hand, or a branch was force-pushed during the fetch) is
  run once more after a short delay.

  The fetch runs in its own process, so the server keeps taking requests for
  other repos. Without the server (some tests), the fetch runs in the caller.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Workspace

  @default_retry_delay_ms 1_000
  @lock_failure "cannot lock ref"

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
    * `:retry_delay_ms` - the wait before the retry after `cannot lock ref`
      (default #{@default_retry_delay_ms}).
  """
  @spec fetch_origin(Path.t(), keyword()) :: result()
  def fetch_origin(repo, opts \\ []) when is_binary(repo) and is_list(opts) do
    repo = Path.expand(repo)
    fetch = fn -> fetch_with_retry(repo, opts) end

    case GenServer.whereis(Keyword.get(opts, :server, __MODULE__)) do
      nil -> fetch.()
      server -> server |> GenServer.call({:fetch, repo, fetch}, :infinity) |> unwrap()
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:crashed, reason}), do: exit(reason)

  @impl true
  def handle_call({:fetch, repo, fetch}, from, fetches) do
    case fetches do
      %{^repo => {ref, waiters}} ->
        {:noreply, Map.put(fetches, repo, {ref, [from | waiters]})}

      %{} ->
        {_pid, ref} = spawn_monitor(fn -> exit({:fetched, fetch.()}) end)
        {:noreply, Map.put(fetches, repo, {ref, [from]})}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, fetches) do
    {repo, {^ref, waiters}} = Enum.find(fetches, fn {_repo, {fetch_ref, _waiters}} -> fetch_ref == ref end)

    reply =
      case reason do
        {:fetched, result} -> {:ok, result}
        reason -> {:crashed, reason}
      end

    Enum.each(waiters, &GenServer.reply(&1, reply))
    {:noreply, Map.delete(fetches, repo)}
  end

  defp fetch_with_retry(repo, opts) do
    case fetch(repo, opts) do
      {output, status} when status != 0 ->
        if String.contains?(output, @lock_failure), do: retry(repo, opts, output), else: {output, status}

      result ->
        result
    end
  end

  defp retry(repo, opts, output) do
    Logger.warning("git fetch origin could not lock a ref repo=#{repo} output=#{inspect(String.trim(output))}; retrying once")
    Process.sleep(Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms))
    fetch(repo, opts)
  end

  defp fetch(repo, opts) do
    Workspace.safe_git(Keyword.get(opts, :git, "git"), ["-C", repo, "fetch", "origin"])
  end
end
