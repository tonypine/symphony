defmodule SymphonyElixir.PrWatch.HeadSync do
  @moduledoc """
  A pushed head GitHub has not attached to its pull request yet (TP-1422).

  GitHub derives a PR's head from its branch, and that derived value can lag the branch: a push can
  sit on the branch for minutes while the PR still shows the older head, with no check runs and no
  push event for the new one. Judged by the PR, the run that pushed looks idle. Judged by the
  branch, it made progress. This module reads both and says which:

    * `:in_sync`: the PR head is the run's head.
    * `:not_on_origin`: the PR head is another commit and so is the branch tip on `origin` (or it
      can't be read): the head is not pushed, and the PR is right.
    * `{:lagging, head}`: the branch tip on `origin` is the run's head and the PR still shows
      another. That is a known state, not idleness: `await/2` waits for GitHub, and once the PR has
      lagged for #{div(60_000, 1000)} seconds nudges it with a no-op base update (the PR's own base
      again), which makes GitHub re-sync the head and start its checks.
    * `:unknown`: the PR could not be read.

  Each step is on the ticket's timeline as a `note` event, once per head: the wait ("waiting for
  GitHub to pick up <sha>"), the nudge ("GitHub had not attached <sha> to PR #N; nudged it") and the
  pick-up ("GitHub picked up <sha> on PR #N; CI running on <sha>").
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.{TicketEvents, Workspace}

  @nudge_after_ms 60_000
  @wait_ms 120_000
  @poll_ms 10_000

  @typedoc "What `await/2` found."
  @type outcome :: :in_sync | :not_on_origin | :unknown | {:lagging, String.t()}

  @typedoc """
  The run's pushed head and where it lives: the ticket (`repo_key`, `issue_id`), its PR, the run
  (`run_id`, for the notes) and its workspace.
  """
  @type target :: %{
          required(:repo_key) => String.t() | nil,
          required(:issue_id) => String.t() | nil,
          required(:pr_url) => String.t(),
          required(:head) => String.t(),
          required(:workspace) => Path.t() | nil,
          optional(:worker_host) => String.t() | nil,
          optional(:run_id) => String.t() | nil
        }

  @doc "How long the PR may lag its branch before `await/2` nudges it, in milliseconds."
  @spec nudge_after_ms() :: pos_integer()
  def nudge_after_ms, do: @nudge_after_ms

  @doc """
  Reads the PR at `target.pr_url` until its head is `target.head`, for at most #{div(@wait_ms, 1000)}
  seconds, while the branch tip on `origin` is that head (see the moduledoc for the outcomes). After
  #{div(@nudge_after_ms, 1000)} seconds of lag it nudges the PR once (`PullRequest.change_base/3`
  with its own base).

  `opts`: `:github` (default `SymphonyElixir.GitHub.PullRequest`, needs `fetch_ci_status/2` and
  `change_base/3`), `:branch_tip_reader` (`fn workspace, worker_host, branch -> sha | nil end`,
  default `origin_tip/3`), `:sleep` and `:monotonic_ms` (the clock), `:nudge_after_ms`, `:wait_ms`
  and `:poll_ms`.
  """
  @spec await(target(), keyword()) :: outcome()
  def await(%{pr_url: pr_url, head: head} = target, opts \\ []) when is_binary(pr_url) and is_binary(head) do
    case read(target, opts) do
      {:lagging, pr_head, _base} = lagging ->
        note(target, :waiting, pr_head)
        wait(target, lagging, %{started: now(opts), nudged: false, polls: max_polls(opts)}, opts)

      other ->
        other
    end
  end

  # The wait is bounded twice: by the clock (`:wait_ms`) and by the number of reads it may make.
  defp wait(target, {:lagging, _pr_head, base}, state, opts) do
    elapsed = now(opts) - state.started
    nudged = state.nudged or nudge(target, base, elapsed, opts)

    if elapsed >= Keyword.get(opts, :wait_ms, @wait_ms) or state.polls <= 0 do
      Logger.info("GitHub has not attached #{target.head} to #{target.pr_url} yet; still waiting for it to pick it up")
      {:lagging, target.head}
    else
      sleep(opts, Keyword.get(opts, :poll_ms, @poll_ms))

      case read(target, opts) do
        {:lagging, _pr_head, _base} = lagging ->
          wait(target, lagging, %{state | nudged: nudged, polls: state.polls - 1}, opts)

        :in_sync ->
          note(target, :picked_up, nil)
          :in_sync

        other ->
          other
      end
    end
  end

  defp max_polls(opts), do: div(Keyword.get(opts, :wait_ms, @wait_ms), max(Keyword.get(opts, :poll_ms, @poll_ms), 1)) + 1

  defp nudge(target, base, elapsed, opts) do
    if elapsed >= Keyword.get(opts, :nudge_after_ms, @nudge_after_ms) and is_binary(base) do
      github = Keyword.get(opts, :github, PullRequest)

      case github.change_base(target.pr_url, base, cwd: target.workspace) do
        :ok ->
          note(target, :nudged, nil)
          true

        {:error, reason} ->
          Logger.warning("Could not nudge #{target.pr_url} to pick up #{target.head}: #{inspect(reason)}")
          false
      end
    else
      false
    end
  end

  defp read(target, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(target.pr_url, cwd: target.workspace) do
      {:ok, %{commit_sha: head}} when head == target.head ->
        :in_sync

      {:ok, %{commit_sha: pr_head} = status} ->
        if branch_tip(target, Map.get(status, :head_ref_name), opts) == target.head,
          do: {:lagging, pr_head, Map.get(status, :base_ref_name)},
          else: :not_on_origin

      _unreadable ->
        :unknown
    end
  end

  defp branch_tip(target, branch, opts) do
    reader = Keyword.get(opts, :branch_tip_reader, &origin_tip/3)
    reader.(target.workspace, Map.get(target, :worker_host), branch)
  end

  @doc """
  The commit `branch` points at on the workspace's `origin`, from `git ls-remote` (a network read),
  or nil when it can't be read. Without a `branch`, the workspace's current branch. Only local
  workspaces are read; an SSH worker's reads as nil.
  """
  @spec origin_tip(Path.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def origin_tip(workspace, nil, branch) when is_binary(workspace) do
    with true <- File.dir?(workspace),
         branch when is_binary(branch) <- branch || current_branch(workspace),
         {output, 0} <- Workspace.safe_git(["ls-remote", "origin", "refs/heads/#{branch}"], cd: workspace, stderr_to_stdout: true),
         [sha | _rest] <- output |> String.trim() |> String.split(~r/\s+/, trim: true),
         true <- sha =~ ~r/\A[0-9a-f]{40}\z/ do
      sha
    else
      _unreadable -> nil
    end
  end

  def origin_tip(_workspace, _worker_host, _branch), do: nil

  defp current_branch(workspace) do
    case Workspace.safe_git(["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} when output not in ["", "HEAD\n"] -> String.trim(output)
      _detached -> nil
    end
  end

  defp note(%{repo_key: repo_key, issue_id: issue_id} = target, kind, pr_head) when is_binary(repo_key) and is_binary(issue_id) do
    head = target.head
    opts = [head_sha: head, idempotency: "pr_head_sync:#{kind}:#{head}", run_id: Map.get(target, :run_id)]

    # The note is the wait's trace on the timeline; a write the store refuses never stops the wait.
    _ = TicketEvents.record(repo_key, issue_id, "note", %{text: note_text(kind, target, pr_head)}, opts)
    :ok
  end

  defp note(_target, _kind, _pr_head), do: :ok

  defp note_text(:waiting, target, pr_head) do
    "Waiting for GitHub to pick up #{short(target.head)}: the branch is at it, but #{pr_name(target.pr_url)} still shows #{short(pr_head)}"
  end

  defp note_text(:nudged, target, _pr_head), do: "GitHub had not attached #{short(target.head)} to #{pr_name(target.pr_url)}; nudged it"

  defp note_text(:picked_up, target, _pr_head) do
    "GitHub picked up #{short(target.head)} on #{pr_name(target.pr_url)}; CI running on #{short(target.head)}"
  end

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 8)
  defp short(_sha), do: "an older head"

  defp pr_name(pr_url) do
    case Regex.run(~r{/pull/(\d+)}, pr_url) do
      [_match, number] -> "PR ##{number}"
      nil -> "its PR"
    end
  end

  defp now(opts), do: Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end).()
  defp sleep(opts, ms), do: Keyword.get(opts, :sleep, &Process.sleep/1).(ms)
end
