defmodule SymphonyElixir.TicketPullRequest.Backfill do
  @moduledoc """
  Seeds the ticket pull request record (`SymphonyElixir.TicketPullRequest`) at startup for the
  tickets already in flight, from the PR URLs Symphony already stores. It costs no GitHub and no
  Linear request.

  For each ticket of a repo, the first of these that names a PR seeds a record with source
  `backfill`:

  1. the CI poller's record (`RunStore.list_ci_checks/1`), deleted once its PR closes;
  2. the PR review poller's record (`RunStore.list_pr_reviews/1`), unless it landed the PR;
  3. the newest handoff signal in the ticket's signals ledger carrying a `pr_url`.

  It is idempotent: a ticket that already has a record, whatever its PR or state, keeps it. A store
  that cannot be read is logged and seeds nothing for that repo.
  """

  require Logger

  alias SymphonyElixir.{Handoff, RunStore, TicketPullRequest, TicketState}

  @handoff_signal Handoff.signal()

  @type outcome :: %{seeded: non_neg_integer(), kept: non_neg_integer()}

  @doc "Backfills every repo of `repo_keys`, and logs how many records it seeded."
  @spec run([String.t()]) :: outcome()
  def run(repo_keys) when is_list(repo_keys) do
    outcome =
      Enum.reduce(repo_keys, %{seeded: 0, kept: 0}, fn repo_key, acc ->
        outcome = run_repo(repo_key)
        %{seeded: acc.seeded + outcome.seeded, kept: acc.kept + outcome.kept}
      end)

    if outcome.seeded > 0, do: Logger.info("Backfilled #{outcome.seeded} ticket pull request record(s) from stored PR URLs")
    outcome
  end

  @doc "Backfills the tickets of `repo_key`: `seeded` new records, `kept` tickets that had one."
  @spec run_repo(String.t()) :: outcome()
  def run_repo(repo_key) do
    with {:ok, ci_checks} <- read(RunStore.list_ci_checks(repo_key)),
         {:ok, pr_reviews} <- read(RunStore.list_pr_reviews(repo_key)),
         {:ok, ticket_states} <- read(RunStore.list_ticket_states(repo_key)) do
      (ci_checks ++ Enum.reject(pr_reviews, &landed?/1) ++ Enum.map(ticket_states, &handoff_pr/1))
      |> Enum.filter(&(is_binary(Map.get(&1, :issue_id)) and is_binary(Map.get(&1, :pr_url))))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.reduce(%{seeded: 0, kept: 0}, &seed(repo_key, &1, &2))
    else
      {:error, reason} ->
        Logger.warning("Failed to backfill ticket pull request records repo_key=#{repo_key}: #{inspect(reason)}")
        %{seeded: 0, kept: 0}
    end
  end

  defp read(records) when is_list(records), do: {:ok, records}
  defp read({:error, _reason} = error), do: error

  # The auto-merge lane keeps its record once GitHub merged the PR: that PR is no longer in flight.
  defp landed?(record), do: match?(%{state: "merged"}, Map.get(record, :auto_merge))

  # The newest handoff signal that names a PR, as `%{issue_id:, pr_url:, branch:}`.
  defp handoff_pr(record) do
    record
    |> TicketState.normalize()
    |> Map.fetch!(:signals)
    |> Enum.find_value(%{}, fn
      %{name: @handoff_signal, details: %{pr_url: pr_url} = details} when is_binary(pr_url) ->
        %{issue_id: Map.get(record, :issue_id), pr_url: pr_url, branch: Map.get(details, :branch)}

      _signal ->
        nil
    end)
  end

  defp seed(repo_key, %{issue_id: issue_id} = pr, acc) do
    case TicketPullRequest.put_new(repo_key, issue_id, %{pr_url: pr.pr_url, branch: Map.get(pr, :branch), source: "backfill"}) do
      {:ok, :inserted} ->
        %{acc | seeded: acc.seeded + 1}

      {:ok, :exists} ->
        %{acc | kept: acc.kept + 1}

      {:error, reason} ->
        Logger.warning("Failed to backfill the pull request #{inspect(pr.pr_url)} of issue_id=#{issue_id}: #{inspect(reason)}")
        acc
    end
  end
end
