defmodule Mix.Tasks.Symphony.DoneWithOpenSubtickets do
  @moduledoc """
  List every parent in a terminal state that still has open sub-tickets.

  Tickets whose PR merged before `issues.states.waiting_on_sub_issues` existed went `Done` with
  sub-tickets still open, and nothing revisits them. This task reads every configured repository's
  scope (its team, projects, labels and assignee) in the terminal states and prints each parent with
  a sub-ticket outside them, so a person decides what to do with it. It only reads the tracker.

  It sees the first 20 sub-tickets of each parent, as the poll does.
  """

  use Mix.Task

  alias SymphonyElixir.{Config, Tracker, Workflow}
  alias SymphonyElixir.Linear.Issue

  @shortdoc "List terminal parents with open sub-tickets (read-only)"
  @switches [config: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        configure(opts)
        {:ok, _started} = Application.ensure_all_started(:req)
        report()

      _ ->
        Mix.raise(usage())
    end
  end

  defp configure(opts) do
    case Keyword.get_values(opts, :config) do
      [] -> :ok
      paths -> :ok = Workflow.set_symphony_file_path(Path.expand(List.last(paths)))
    end
  end

  defp report do
    settings =
      case Config.settings() do
        {:ok, settings} -> settings
        {:error, reason} -> Mix.raise(Config.format_error(reason))
      end

    terminal_states = settings.tracker.terminal_states

    case Tracker.fetch_issues_by_states(terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.map(&{&1, Issue.open_sub_issues(&1, terminal_states)})
        |> Enum.reject(fn {_issue, open} -> open == [] end)
        |> Enum.sort_by(fn {issue, _open} -> sort_key(issue.identifier) end)
        |> format()
        |> Mix.shell().info()

      {:error, reason} ->
        Mix.raise("Unable to fetch issues in #{Enum.join(terminal_states, ", ")}: #{inspect(reason)}")
    end
  end

  defp format([]), do: "No parent in a terminal state has open sub-tickets."

  defp format(parents) do
    count = length(parents)
    heading = "#{count} #{if count == 1, do: "parent", else: "parents"} in a terminal state with open sub-tickets:"

    lines =
      Enum.flat_map(parents, fn {issue, open} ->
        ["- #{issue.identifier} (#{issue.state}): #{issue.title}" | Enum.map(open, &"  - #{sub_issue_label(&1)}: #{Map.get(&1, :state) || "unknown"}")]
      end)

    Enum.join([heading, "" | lines], "\n")
  end

  defp sub_issue_label(sub_issue), do: Map.get(sub_issue, :identifier) || Map.get(sub_issue, :id)

  # `TP-9` before `TP-10`.
  defp sort_key(identifier) do
    identifier = to_string(identifier)

    case Regex.run(~r/^(.*?)(\d+)$/, identifier) do
      [_match, prefix, number] -> {prefix, String.to_integer(number)}
      nil -> {identifier, 0}
    end
  end

  defp usage do
    "Usage: mix symphony.done_with_open_subtickets [--config PATH]"
  end
end
