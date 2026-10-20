defmodule SymphonyElixir.Restart do
  @moduledoc """
  The full reset behind the Director app's **Restart** move: the one action that throws a ticket's
  attempt away and starts it again from main.

  `Rework` continues the existing pull request (see `docs/design/state-machine.md`); a person who
  means the old full reset says so with this move instead. It is human-only — the control API
  performs it, and `SymphonyElixir.TransitionGuard` refuses an agent's request that would amount
  to one (asking for `In Progress` from a post-implementation phase).

  `perform/2` runs the reset:

    1. every open pull request of the ticket is closed on GitHub;
    2. the ticket's workspaces are removed, which deletes the worktree and its branch, so the next
       dispatch creates `auto/<identifier>` again from the configured base branch;
    3. the workpad comment is superseded: the prior attempt is kept under a `Superseded` heading
       and a fresh `Plan`, `Acceptance Criteria` and `Validation` follow it.

  The move to `In Progress` follows, outside this module, through the guard.

  Every step is idempotent: a ticket with no open pull request, no workspace and no workpad still
  resets, and a second `restart` on the same ticket finds less to do and does it. A failure stops
  the reset where it happened and reports which step it was; the move is then not made, so a
  person can read the message in the Inbox and try again.

  Options: `:github` (the pull request module, default `SymphonyElixir.GitHub.PullRequest`),
  `:workspace` (the workspace module, default `SymphonyElixir.Workspace`), and the workpad's own
  `:settings`, `:linear_client`, `:now` and `:linear_retry_opts`, which pass through to
  `SymphonyElixir.Workpad.supersede/2`.
  """

  require Logger

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.Workpad
  alias SymphonyElixir.Workspace

  @typedoc "The reset stopped at `message`, which names the step and what GitHub or Linear said."
  @type error :: {:error, {:restart, String.t()}}

  @doc "Runs the full reset for `issue`. The caller moves the ticket to `In Progress` afterwards."
  @spec perform(Issue.t(), keyword()) :: :ok | error()
  def perform(%Issue{} = issue, opts) when is_list(opts) do
    with :ok <- close_pull_requests(issue, opts),
         :ok <- remove_workspaces(issue, opts) do
      supersede_workpad(issue, opts)
    end
  end

  # The ticket's own pull request, from Symphony's record of it (`SymphonyElixir.TicketPullRequest`).
  # Only an open one is closed: a reset with no pull request — a ticket restarted before its first
  # handoff, or one whose PR already closed or merged — has nothing here.
  defp close_pull_requests(%Issue{} = issue, opts) do
    github = Keyword.get(opts, :github, PullRequest)

    issue
    |> TicketPullRequest.current_urls()
    |> Enum.reduce_while(:ok, fn pr_url, :ok ->
      case close_pull_request(github, issue, pr_url) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp close_pull_request(github, issue, pr_url) do
    case github.fetch_activity(pr_url, []) do
      {:ok, activity} ->
        if open?(activity[:state]), do: close_pull_request(github, issue, pr_url, activity), else: :ok

      {:error, reason} ->
        failed("couldn't read #{pr_url} (#{inspect(reason)})")
    end
  end

  defp close_pull_request(github, issue, pr_url, _activity) do
    case github.close(pr_url, []) do
      :ok ->
        Logger.info("Restart closed pull request issue_id=#{issue.id} issue_identifier=#{issue.identifier} pr_url=#{pr_url}")
        # The record says so at once, so the next dispatch starts the branch again from the base
        # branch even while the old branch is still on origin (`SymphonyElixir.Workspace`).
        TicketPullRequest.mark_finished(issue.repo_key, pr_url, "closed")

      {:error, reason} ->
        failed("GitHub refused to close #{pr_url} (#{inspect(reason)})")
    end
  end

  defp open?(state) when is_binary(state), do: String.upcase(String.trim(state)) == "OPEN"
  defp open?(_state), do: false

  # Removal deletes the worktree and its branch, so the next dispatch of this ticket creates the
  # branch again from the repo's configured base branch: the fresh branch the reset promises. The
  # checked removal reports a worktree or branch it couldn't delete, so the move is not made then.
  defp remove_workspaces(issue, opts) do
    workspace = Keyword.get(opts, :workspace, Workspace)

    case workspace.remove_issue_workspaces_checked(issue) do
      :ok -> :ok
      other -> failed("couldn't remove the workspace of #{issue.identifier} (#{inspect(other)})")
    end
  rescue
    error -> failed("couldn't remove the workspace of #{issue.identifier} (#{Exception.message(error)})")
  end

  defp supersede_workpad(issue, opts) do
    case Workpad.supersede(issue, workpad_opts(opts)) do
      :ok -> :ok
      {:error, reason} -> failed("couldn't supersede the workpad of #{issue.identifier} (#{inspect(reason)})")
    end
  end

  defp workpad_opts(opts), do: Keyword.take(opts, [:settings, :linear_client, :now, :linear_retry_opts])

  defp failed(message), do: {:error, {:restart, message}}
end
