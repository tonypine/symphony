defmodule SymphonyElixir.Setup.Checks.HoldDrift do
  @moduledoc """
  Tickets whose hold labels drift from the store (L4): a `Blocked` or `Needs Decision` label with
  no hold, or a hold whose label is missing. The polls repair drift as they see it, so drift that
  lasts is drift that repair couldn't fix; the check lists a ticket once two checks in a row have
  seen it drift (`SymphonyElixir.Hold.Drift`), and reads Linear for nothing.

  One warning per repo names its tickets, with one details line each: which way it drifted and since
  when. The fix re-syncs the label from the store, for one of the tickets or for all of them.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Hold
  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Setup.Problem

  @lasting_checks 2

  @impl true
  def id, do: "hold_drift"

  @impl true
  def title, do: "Hold labels that don't match their holds"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(context) do
    context.now
    |> Drift.observe()
    |> Enum.filter(&(&1.checks >= @lasting_checks))
    |> Enum.group_by(& &1.repo_key)
    |> Enum.sort()
    |> Enum.map(fn {repo_key, entries} -> problem(repo_key, entries) end)
  end

  @doc "The name a drifted ticket goes by in the problem and its fix: its identifier, else its id."
  @spec ticket_name(Drift.entry()) :: String.t()
  def ticket_name(entry), do: entry.identifier || entry.issue_id

  defp problem(repo_key, entries) do
    names = Enum.map(entries, &ticket_name/1)

    Problem.new(
      id: "#{id()}:#{repo_key}",
      severity: :warning,
      category: :labels,
      title: title(repo_key, names),
      consequence:
        "A ticket's label says it is paused when it isn't, or a paused ticket doesn't show it, and Symphony couldn't put it right " <>
          "on its own. Re-sync sets the label from the hold Symphony keeps.",
      repos: [repo_key],
      tickets: Enum.map(entries, &%{identifier: ticket_name(&1), url: &1.url}),
      details: Enum.map(entries, &{ticket_name(&1), detail(&1)}),
      fix: Problem.resync_hold(repo_key, names)
    )
  end

  defp title(repo_key, [name]), do: "#{name}'s hold label doesn't match its hold (#{repo_key})"
  defp title(repo_key, names), do: "#{length(names)} tickets in #{repo_key} have hold labels that don't match their holds"

  defp detail(%{drift: {:stray_label, kind}, since: since}), do: "#{Hold.label(kind)} label with no hold, since #{format(since)}"
  defp detail(%{drift: {:missing_label, kind}, since: since}), do: "#{Hold.label(kind)} hold with no label, since #{format(since)}"

  defp format(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
