defmodule SymphonyElixir.Setup.Checks.DeprecatedLabels do
  @moduledoc """
  The deprecated `human-action` label (L3), retired for the `Needs Decision` hold:

    * in `symphony.yml`'s `escalate.labels` (`auto_review.acceptance_gate.escalate.labels` or a
      repository's `acceptance_gate.escalate.labels`): one warning per list, with a `config_edit`
      fix that removes the label from it;
    * on open tickets: one warning per repo naming the tickets its last poll fetched
      (`SymphonyElixir.Routing.PollLog`) that carry it, so it asks Linear for nothing.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.PollLog
  alias SymphonyElixir.Setup.{ConfigLines, Problem}
  alias SymphonyElixir.StateProvisioning

  @global_path "auto_review.acceptance_gate.escalate.labels"

  @impl true
  def id, do: "deprecated_label"

  @impl true
  def title, do: "Deprecated labels in symphony.yml and on tickets"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(context) do
    config_problems(context.symphony_path) ++ ticket_problems(context.system)
  end

  defp config_problems(path) do
    case Cache.get_symphony(path) do
      {:error, _reason} ->
        []

      # The running config: a rejected edit is reported by the failed-reload check.
      result ->
        config = elem(result, 1)
        content = read(path)

        repo_lists =
          for %{"key" => key} = repo <- List.wrap(config["repositories"]),
              do: {"repositories[#{key}].acceptance_gate.escalate.labels", get_in(repo, ["acceptance_gate", "escalate", "labels"])}

        for {key, labels} <- [{@global_path, get_in(config, ["auto_review", "acceptance_gate", "escalate", "labels"])} | repo_lists],
            label <- List.wrap(labels),
            deprecated?(label),
            uniq: true,
            do: config_problem(key, label, content)
    end
  end

  defp config_problem(path, label, content) do
    Problem.new(
      id: "#{id()}:config:#{path}",
      severity: :warning,
      category: :labels,
      title: ~s(symphony.yml lists the deprecated "#{label}" label in #{path}),
      consequence:
        ~s(Symphony asks you for decisions with the "Needs Decision" label now, so nothing adds "#{label}" any more. ) <>
          "Remove it from the list.",
      details: [Key: path, Label: label, Line: content && ConfigLines.line(content, path)],
      fix: Problem.config_edit(path, :remove, label)
    )
  end

  defp ticket_problems(nil), do: []

  defp ticket_problems(system) do
    for repo <- system.repos,
        %{issues: issues} <- [PollLog.last(repo)],
        tickets = for(%Issue{} = issue <- issues, Enum.any?(issue.labels, &deprecated?/1), do: issue),
        tickets != [],
        do: ticket_problem(repo.name, tickets)
  end

  defp ticket_problem(repo_name, tickets) do
    count = length(tickets)

    Problem.new(
      id: "#{id()}:tickets:#{repo_name}",
      severity: :warning,
      category: :labels,
      title: ~s(#{count} open #{if count == 1, do: "ticket in #{repo_name} carries", else: "tickets in #{repo_name} carry"} the deprecated "human-action" label),
      consequence: ~s(Symphony asks you for decisions with the "Needs Decision" label now, so "human-action" does nothing. Remove it in Linear.),
      repos: [repo_name],
      tickets: Enum.map(tickets, &%{identifier: &1.identifier, url: &1.url}),
      fix: Problem.open(:linear)
    )
  end

  defp deprecated?(label) when is_binary(label), do: normalize(label) in Enum.map(StateProvisioning.deprecated_labels(), &normalize/1)
  defp deprecated?(_label), do: false

  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end
end
