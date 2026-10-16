defmodule SymphonyElixir.AutoMerge do
  @moduledoc """
  The GitHub half of `SymphonyElixir.PrDecision.Apply` for a PR that lands: turning GitHub
  auto-merge on (`arm/2`, rule R30) and off (`disarm/2`, R3, and before a fix run or a hold in
  `Merging`), squash-merging a PR that can merge now (`merge/2`, R29), merging the base branch in
  (`update_branch/2`, R28) and cancelling the CI runs an update-branch left on the head it replaced
  (`cancel_stale_runs/3`). It decides nothing: the PR and CI watcher (`docs/pr-ci-decisions.md`)
  picks the action, and these only make the call.

  Each takes the watcher's read of the PR (`SymphonyElixir.PrWatch.Fetch.read/2`): its URL, GraphQL
  node id, head, number, title and body. `opts[:github]` replaces `SymphonyElixir.GitHub.PullRequest`
  (tests); the other `opts` go to `gh`.

  The texts it posts on the ticket when it turns auto-merge off or a landing agent takes the PR are
  here too.
  """

  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue

  @merging_state "merging"
  @back_to_merging "moving this ticket to Merging again turns auto-merge back on."

  @doc "Auto-merge runs with PR polling on (`pull_requests.enabled`) and `pull_requests.auto_merge` on."
  @spec enabled?(map()) :: boolean()
  def enabled?(%{pr_review: %{mode: "polling", auto_merge: true}}), do: true
  def enabled?(_settings), do: false

  @doc "True when the issue is in `Merging`."
  @spec merging?(term()) :: boolean()
  def merging?(%Issue{state: state}) when is_binary(state), do: normalize(state) == @merging_state
  def merging?(_issue), do: false

  @doc """
  Turns GitHub auto-merge on (squash, the PR's title and body) for the read's head. GitHub refuses it
  for a PR that can already merge (`{:error, :clean_status}`) and for a head that moved since the
  read (`{:error, :head_moved}`).
  """
  @spec arm(map(), keyword()) :: :ok | {:error, term()}
  def arm(pr, opts), do: with_request(pr, &github(opts).enable_auto_merge(pr.pr_url, &1, gh_opts(opts)))

  @doc "Squash-merges the PR now, only if its head is still the read's."
  @spec merge(map(), keyword()) :: :ok | {:error, term()}
  def merge(pr, opts), do: with_request(pr, &github(opts).squash_merge(pr.pr_url, &1, gh_opts(opts)))

  @doc "Turns GitHub auto-merge off for the PR."
  @spec disarm(map(), keyword()) :: :ok | {:error, term()}
  def disarm(%{pr_url: pr_url, pr_node_id: node_id}, opts) when is_binary(pr_url) do
    if is_binary(node_id),
      do: github(opts).disable_auto_merge(pr_url, node_id, gh_opts(opts)),
      else: {:error, :missing_pr_node_id}
  end

  @doc """
  Asks GitHub to merge the base branch into the PR, only if the head is still the read's. A merge
  that conflicts comes back as `{:error, :conflict}`: the next read shows the PR conflicting.
  """
  @spec update_branch(map(), keyword()) :: :ok | {:error, term()}
  def update_branch(%{pr_url: pr_url, head_sha: head}, opts) when is_binary(pr_url) do
    if is_binary(head),
      do: github(opts).update_branch(pr_url, head, gh_opts(opts)),
      else: {:error, :missing_head_sha}
  end

  @doc """
  Cancels the CI runs still going on `stale_head`, which an update-branch replaced with the PR's new
  head: they can never land and only hold runners. Returns the ids it cancelled.
  """
  @spec cancel_stale_runs(map(), String.t(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def cancel_stale_runs(%{pr_url: pr_url}, stale_head, opts) when is_binary(pr_url) and is_binary(stale_head) do
    github(opts).cancel_stale_runs(pr_url, stale_head, gh_opts(opts))
  end

  defp with_request(%{pr_node_id: node_id, head_sha: head} = pr, call) when is_binary(node_id) and is_binary(head) do
    call.(%{
      pr_node_id: node_id,
      head_sha: head,
      pr_number: Map.get(pr, :pr_number),
      pr_title: Map.get(pr, :pr_title),
      pr_description: Map.get(pr, :pr_description)
    })
  end

  defp with_request(_pr, _call), do: {:error, :missing_pr_node_id}

  @doc "The Linear comment posted when a landing agent takes the PR over from auto-merge."
  @spec fallback_comment(String.t() | nil, String.t()) :: String.t()
  def fallback_comment(pr_url, reason) do
    "Symphony couldn't land #{pr_url || "this PR"} with GitHub auto-merge (#{reason}), so a landing agent will merge it instead."
  end

  @doc "The Linear comment posted when auto-merge is turned off because the PR conflicts with its base branch."
  @spec conflict_comment(String.t() | nil) :: String.t()
  def conflict_comment(pr_url) do
    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because it conflicts with the base branch. " <>
      "The approval covered the diff before the conflict, so the conflict fix goes back through review; " <>
      @back_to_merging
  end

  @doc "The Linear comment posted when auto-merge is turned off for a CI-fix run."
  @spec ci_fix_comment(String.t() | nil) :: String.t()
  def ci_fix_comment(pr_url) do
    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because CI failed and a fix run may push new code. " <>
      "The approval covered the diff before the fix, so the fix goes back through review; " <>
      @back_to_merging
  end

  @doc "The Linear comment posted when auto-merge is turned off because the ticket left `Merging`."
  @spec exit_comment(String.t() | nil, String.t() | nil) :: String.t()
  def exit_comment(pr_url, state) do
    left = if state, do: "left Merging for #{state}", else: "left Merging"

    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because this ticket #{left}, " <>
      "so the PR doesn't merge without an approval; moving this ticket to Merging again turns auto-merge back on."
  end

  @doc "The Linear comment posted when auto-merge is turned off because a person pushed to the PR in `Merging`."
  @spec person_push_comment(String.t() | nil) :: String.t()
  def person_push_comment(pr_url) do
    "Symphony turned off GitHub auto-merge on #{pr_url || "this PR"} because a person pushed to it while it was in Merging: " <>
      "the approval covered the diff before that push, so it goes back to Code Review; " <> @back_to_merging
  end

  defp github(opts), do: Keyword.get(opts, :github, PullRequest)
  defp gh_opts(opts), do: Keyword.drop(opts, [:github])

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
