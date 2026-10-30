defmodule SymphonyElixir.ClosedPullRequest do
  @moduledoc """
  The hold for a ticket whose change is gone: its pull request is closed or missing, or its head
  has nothing to verify.

  A Backlog move removes the ticket's workspace, and the `before_remove` hook closes its pull
  request. Moving the ticket back to a later phase does not reopen it. A run there would then work
  on a workspace built from the base branch: the reviewer and the QA run see an empty diff, which
  reads as a docs-only change, and the ticket lands in `Merging` with nothing reviewed or verified.

  This module stops that. `guard/3` runs before a run starts (`SymphonyElixir.AgentRunner`): a
  ticket in a phase that judges, repairs or lands its existing pull request — Code Review, QA, CI
  Fix or Merging — whose recorded pull request (`SymphonyElixir.TicketPullRequest`) is closed is
  paused on a Needs Decision hold (`SymphonyElixir.DecisionRequest.ask/4`) instead. The PR and
  CI watcher sends such a ticket to Rework first (rule R8, D5), and a Rework run starts: it opens a
  new pull request from main. The QA run checks the same before its policy
  (`SymphonyElixir.QaVerification`), and the QA run and the Code Review approve hold an empty diff
  rather than skip QA (`SymphonyElixir.QaPolicy`).

  The request asks a person to reopen the pull request (the recommended option: the next poll's
  lookup records it open again, `SymphonyElixir.TicketPullRequest.Lookup`), restart the ticket, or
  cancel it. The answer clears the hold and the ticket continues in place.
  """

  require Logger

  alias SymphonyElixir.{DecisionMove, DecisionRequest, TicketPullRequest}
  alias SymphonyElixir.HumanActions.{PlainWords, Request}
  alias SymphonyElixir.Linear.Issue

  @merging_state "Merging"

  @typedoc """
  Why the ticket has no change to work on: its pull request at the URL is closed, it has no open
  pull request at all, or its head changes nothing against the base branch (with the PR URL when
  it has one).
  """
  @type cause :: {:closed, String.t()} | :no_pull_request | {:no_change, String.t() | nil}

  @doc """
  Pauses `issue` on the hold before a run starts when it sits in a phase that works on its existing
  pull request and that pull request is closed: `:held` then, else `:run`. Any other ticket, and one
  whose pull request is open or was never recorded, runs as before.

  `opts[:repo_key]` names the repo when the issue carries none; `opts[:tracker]` and `opts[:store]`
  go to `DecisionRequest.ask/4`.
  """
  @spec guard(map(), map(), keyword()) :: :run | :held | {:error, term()}
  def guard(%Issue{} = issue, settings, opts) do
    repo_key = repo_key(issue, opts)

    with true <- pull_request_phase?(issue, settings),
         %{state: "closed", pr_url: url} when is_binary(url) <- record(repo_key, issue.id) do
      Logger.warning("Not starting a run for #{label(issue)} in #{issue.state}: its pull request #{url} is closed")

      case pause(issue, {:closed, url}, opts) do
        :ok -> :held
        {:error, reason} -> {:error, {:closed_pull_request_hold_failed, reason}}
      end
    else
      _open_none_or_other_phase -> :run
    end
  end

  def guard(_issue, _settings, _opts), do: :run

  @doc """
  The cause for a ticket with no open pull request: the closed one its record names, else
  `:no_pull_request`.
  """
  @spec missing_cause(Issue.t(), String.t() | nil) :: cause()
  def missing_cause(%Issue{} = issue, repo_key) do
    case record(repo_key || issue.repo_key, issue.id) do
      %{state: "closed", pr_url: url} when is_binary(url) -> {:closed, url}
      _none_or_merged -> :no_pull_request
    end
  end

  @doc """
  Pauses `issue` in its phase on the Needs Decision hold for `cause`. `opts` go to
  `DecisionRequest.ask/4` (`:repo_key`, `:tracker`, `:store`).
  """
  @spec pause(Issue.t(), cause(), keyword()) :: :ok | {:error, term()}
  def pause(%Issue{} = issue, cause, opts) do
    hold_opts = opts |> Keyword.take([:tracker, :store]) |> Keyword.put(:repo_key, repo_key(issue, opts))
    DecisionRequest.ask(issue, request(issue, cause), hold_opts)
  end

  @doc """
  The decision request the hold posts for `cause`, in the Director's words. Exposed so a caller can
  render or assert it without posting.
  """
  @spec request(Issue.t(), cause()) :: map()
  def request(%Issue{} = issue, cause) do
    %{
      title: title(issue, cause),
      question: "#{mention(issue)}#{in_state(issue)} #{problem(cause)}, so there is no change to review, check or merge. How should it continue?",
      why: why(cause),
      if_unanswered: "#{label(issue)} stays#{in_state(issue)} and nothing runs on it.",
      options: options(cause),
      recommendation_reason: recommendation_reason(cause)
    }
  end

  # Code Review, QA and CI Fix judge or repair the pull request's head, and Merging lands it: none
  # of them has anything to work on once it is closed. Todo and In Progress build a change and open
  # their pull request themselves, and so does Rework once its pull request was closed (D5).
  defp pull_request_phase?(%Issue{state: state}, settings) when is_binary(state) do
    tracker = settings.tracker
    phases = [tracker.code_review_state, tracker.qa_state, tracker.ci_fix_state, @merging_state]

    Enum.any?(phases, &(normalize(&1) == normalize(state)))
  end

  defp pull_request_phase?(_issue, _settings), do: false

  defp record(repo_key, issue_id) when is_binary(repo_key) and is_binary(issue_id) do
    case TicketPullRequest.get(repo_key, issue_id) do
      %{} = record -> record
      _none_or_error -> nil
    end
  end

  defp record(_repo_key, _issue_id), do: nil

  defp title(issue, {:no_change, _url}), do: "Restart or cancel #{label(issue)}"
  defp title(issue, _closed_or_missing), do: "Reopen the pull request of #{label(issue)}"

  defp problem({:closed, url}), do: "has its pull request#{pr_name(url)} closed"
  defp problem(:no_pull_request), do: "has no open pull request"
  defp problem({:no_change, url}), do: "has a pull request#{pr_suffix(url)} that changes nothing against the main branch"

  defp why({:no_change, _url}) do
    "Its branch has no commit that the main branch lacks. Either the work already reached the main branch another way, or the branch lost it. " <>
      "Symphony does not skip the checks for a change it cannot see."
  end

  defp why(_closed_or_missing) do
    "Moving a ticket to Backlog closes its pull request, and moving it back does not reopen it. " <>
      "Without an open pull request, a run would check the main branch instead of the ticket's work."
  end

  defp options({:no_change, _url}) do
    [
      %{label: "Restart", effect: "you restart the ticket from the Symphony app; it starts again from the main branch with a fresh pull request", recommended: true},
      cancel_option()
    ]
  end

  defp options(cause) do
    [
      %{label: "Reopen", effect: "you reopen #{pr_or_its(cause)} on GitHub, then pick this; the ticket continues where it is on that pull request", recommended: true},
      %{label: "Restart", effect: "you restart the ticket from the Symphony app; it starts again from the main branch with a fresh pull request", recommended: false},
      cancel_option()
    ]
  end

  # Canceling is the person's pick and Symphony's move (`SymphonyElixir.DecisionMove`).
  defp cancel_option,
    do: DecisionMove.option(%{label: "Cancel", effect: "Symphony moves the ticket to Canceled; nothing is merged", recommended: false}, %{to: "Canceled"})

  defp recommendation_reason({:no_change, _url}), do: "Restarting rebuilds the change, so the review and QA see real work."
  defp recommendation_reason(_cause), do: "Reopening keeps the work, the review and the checks already done."

  defp pr_or_its({:closed, url}), do: pr(url)
  defp pr_or_its(:no_pull_request), do: "its pull request"

  defp pr(url), do: Request.pull_request(url) || "its pull request"

  defp pr_name(url) do
    case Request.pull_request(url) do
      nil -> ""
      pr -> " #{pr}"
    end
  end

  defp pr_suffix(url) do
    case Request.pull_request(url) do
      nil -> ""
      pr -> " (#{pr})"
    end
  end

  defp in_state(%Issue{state: state}) when is_binary(state) and state != "", do: " in #{state}"
  defp in_state(_issue), do: ""

  defp mention(%Issue{title: title} = issue) when is_binary(title) and title != "", do: "#{label(issue)} (#{PlainWords.scrub(title)})"
  defp mention(issue), do: label(issue)

  defp label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp label(%Issue{id: id}), do: inspect(id)

  defp repo_key(issue, opts), do: Keyword.get(opts, :repo_key) || Map.get(issue, :repo_key)

  defp normalize(state), do: state |> String.trim() |> String.downcase()
end
