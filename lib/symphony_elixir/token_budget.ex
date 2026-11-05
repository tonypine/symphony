defmodule SymphonyElixir.TokenBudget do
  @moduledoc """
  What Symphony does when a run spends its ticket's token budget (`agent.limits.tokens_per_issue`,
  `SymphonyElixir.Orchestrator`): it stops the run and asks a person what now, through the one
  path (`SymphonyElixir.Questions`, `ask/2`).

  The question names the tokens the run spent, the limit, and what the run got done (`facts/0`):
  whether its pull request has its work, the commits it left unpushed and the files it changed
  without committing. Its options are "Give it another budget" (recommended: Unblock, one more run
  with the same limit), "Start it over from main" (Restart) and "Keep it paused"; the person may
  answer in their own words too, which keeps it paused (`SymphonyElixir.DispatchLoop.answer_move/1`).
  While it is open the ticket's pause reads "Its token budget is spent (100M)" (`pause_text/1`), so
  the Director shows "Paused: its token budget is spent (100M)".

  The run's `run.ended` event says it ended on its budget (`exit_text/2`), with the limit and the
  run's totals, and the summary changelog has a line for it (`SymphonyElixir.IssueSummary`).
  """

  alias SymphonyElixir.{DispatchLoop, Questions}

  @typedoc """
  What the question says: the ticket's `name` (its identifier), the run's `total_tokens` (nil when
  unknown) and the `limit`, whether its pull request has its work (`pushed`), and the commits it
  left unpushed and the files it changed without committing (nil when its workspace can't be read).
  """
  @type facts :: %{
          name: String.t(),
          total_tokens: non_neg_integer() | nil,
          limit: pos_integer(),
          pushed: boolean(),
          unpushed_commits: non_neg_integer() | nil,
          changed_files: non_neg_integer() | nil
        }

  @doc "The question's title for the ticket `name`, which `answered_since?/3` finds it by."
  @spec title(String.t()) :: String.t()
  def title(name) when is_binary(name), do: "#{name} spent its token budget"

  @doc ~S|The line the ticket's pause reads while the question is open: "Its token budget is spent (100M)".|
  @spec pause_text(pos_integer()) :: String.t()
  def pause_text(limit) when is_integer(limit), do: "Its token budget is spent (#{compact(limit)})"

  @doc ~S|How the run ended, for its `run.ended` event: "token budget spent (100M tokens of a 100M limit)".|
  @spec exit_text(non_neg_integer() | nil, pos_integer()) :: String.t()
  def exit_text(total, limit) when is_integer(total), do: "token budget spent (#{compact(total)} tokens of a #{compact(limit)} limit)"
  def exit_text(_total, limit), do: "token budget spent (a #{compact(limit)} limit)"

  @doc ~S|A token count in a few characters: 950, 12k, 1.5M, 100M.|
  @spec compact(non_neg_integer()) :: String.t()
  def compact(count) when is_integer(count) and count >= 1_000_000, do: scaled(count, 1_000_000, "M")
  def compact(count) when is_integer(count) and count >= 1_000, do: scaled(count, 1_000, "k")
  def compact(count) when is_integer(count), do: Integer.to_string(count)

  defp scaled(count, unit, suffix) do
    tenths = div(count * 10, unit)
    whole = div(tenths, 10)
    if rem(tenths, 10) == 0 or whole >= 10, do: "#{whole}#{suffix}", else: "#{whole}.#{rem(tenths, 10)}#{suffix}"
  end

  @doc """
  Asks the question on `ticket` (`question_attrs/1`), pausing it on `pause_text/1` of its limit. An
  open question with the same words is returned, not asked twice.
  """
  @spec ask(Questions.ticket(), facts()) :: {:ok, Questions.question()} | {:error, term()}
  def ask({:ticket, _repo_key, _issue_id} = ticket, %{limit: limit} = facts), do: Questions.ask(ticket, question_attrs(facts), pause_text: pause_text(limit))

  @doc """
  The question: its title (`title/1`), the spend, the limit and what the run got done, and the
  options "#{DispatchLoop.another_budget_label()}" (recommended), "#{DispatchLoop.option_label(:restart)}"
  and "#{DispatchLoop.option_label(:keep)}".
  """
  @spec question_attrs(facts()) :: map()
  def question_attrs(%{name: name, limit: limit} = facts) do
    title = title(name)

    %{
      title: title,
      question: "#{title}. Should Symphony give it another budget, start it over from main, or keep it paused?",
      why: "#{spent(facts)} Symphony stopped it and starts no run on #{name} until you answer. #{done(facts)}",
      if_unanswered: "#{name} stays paused and Symphony starts no run on it.",
      recommendation_reason: "Another run with the same limit picks up the work where this one stopped.",
      options: [
        %{
          label: DispatchLoop.another_budget_label(),
          effect: "Symphony starts one more run on #{name} where it stopped, with another #{compact(limit)} tokens.",
          recommended: true
        },
        %{
          label: DispatchLoop.option_label(:restart),
          effect: "Symphony closes the pull request of #{name}, drops its work and starts again from the main branch.",
          recommended: false
        },
        %{label: DispatchLoop.option_label(:keep), effect: "#{name} stays paused until you decide.", recommended: false}
      ]
    }
  end

  defp spent(%{total_tokens: total, limit: limit}) when is_integer(total),
    do: "The last run spent #{compact(total)} tokens, past the limit of #{compact(limit)} tokens a ticket's run may spend."

  defp spent(%{limit: limit}), do: "The last run reached the limit of #{compact(limit)} tokens a ticket's run may spend."

  defp done(facts) do
    pull_request = if facts.pushed, do: "Its pull request has the work it pushed", else: "It pushed nothing to a pull request"

    case {facts.unpushed_commits, facts.changed_files} do
      {commits, files} when is_integer(commits) and is_integer(files) ->
        "#{pull_request}; its workspace keeps #{plural(commits, "commit")} not pushed and #{plural(files, "file")} changed but not committed."

      _unread ->
        "#{pull_request}."
    end
  end

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(count, unit), do: "#{count} #{unit}s"

  @doc """
  Whether a person already answered the question for `name` among the ticket's `questions` at or
  after `since` (the start of the run that spent the budget): then that run is settled, and the
  start-up does not hold the ticket on it again.
  """
  @spec answered_since?([Questions.question()], String.t(), DateTime.t() | nil) :: boolean()
  def answered_since?(questions, name, since) when is_list(questions) and is_binary(name) do
    title = title(name)
    Enum.any?(questions, &(&1.state == :answered and &1.title == title and after?(&1.answer, since)))
  end

  defp after?(%{at: %DateTime{} = at}, %DateTime{} = since), do: DateTime.compare(at, since) != :lt
  defp after?(_answer, _since), do: true
end
