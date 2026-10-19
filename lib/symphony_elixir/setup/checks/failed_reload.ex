defmodule SymphonyElixir.Setup.Checks.FailedReload do
  @moduledoc """
  A `symphony.yml` or repo `WORKFLOW.md` edit that `Config.Cache` rejected (K2): an unknown or
  removed key, an invalid value, a file that no longer parses or reads. Symphony keeps running the
  last config that loaded, so the edit does nothing until the file loads again. One error per file,
  naming the key or line and the reason, and since when the running config is stale. The next
  reload of a fixed file clears it.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.{Config, WorkflowSource}
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Setup.{ConfigLines, Problem}

  @impl true
  def id, do: "failed_reload"

  @impl true
  def title, do: "Config edits Symphony rejected"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(context) do
    repos = workflow_repos(context.system)

    Cache.status()
    |> Enum.filter(& &1.stale?)
    |> Enum.flat_map(&List.wrap(problem(&1, context, repos)))
  end

  defp problem(%{kind: :symphony, path: path} = entry, context, _repos) do
    if path == Path.expand(context.symphony_path) do
      file_problem(entry, "symphony.yml", [], Problem.open(:symphony_yml))
    end
  end

  defp problem(%{kind: :workflow, path: path} = entry, _context, repos) do
    case Map.get(repos, path) do
      nil -> nil
      repo -> file_problem(entry, "WORKFLOW.md of #{repo}", [repo], Problem.open(:repos))
    end
  end

  defp file_problem(entry, name, repos, fix) do
    reason = reason(entry.last_error)
    key = key(entry.last_error)

    Problem.new(
      id: "#{id()}:#{entry.path}",
      severity: :error,
      category: :keys,
      title: "Symphony didn't load your #{name} edit: #{reason}",
      consequence:
        "Symphony is still running the settings it loaded before #{since(entry.stale_since)}, so your edit does nothing yet. " <>
          "Fix the file and Symphony loads it on the next reload.",
      repos: repos,
      details: [File: entry.path, Key: key, Line: line(entry, key), Reason: reason, "Stale since": since(entry.stale_since)],
      fix: fix
    )
  end

  # Each repo's `WORKFLOW.md` as the cache knows it: the snapshot of its base ref, or its file.
  defp workflow_repos(nil), do: %{}
  defp workflow_repos(system), do: Map.new(system.repos, &{Path.expand(WorkflowSource.read_path(&1)), &1.name})

  defp reason({:missing_file, reason}), do: "the file can't be read (#{:file.format_error(reason)})"
  defp reason({:invalid_symphony_config, message}), do: message
  defp reason({:invalid_repo_workflow_config, message}), do: message
  defp reason(reason), do: Config.format_error(reason)

  # The key the reason names in backticks, as the schema writes it: unknown symphony.yml key `pull_request`.
  defp key({_kind, message}) when is_binary(message) do
    case Regex.run(~r/`([^`]+)`/, message) do
      [_match, key] -> key
      nil -> nil
    end
  end

  defp key(_reason), do: nil

  defp line(%{last_error: {_kind, %YamlElixir.ParsingError{line: line}}}, _key) when is_integer(line), do: line
  defp line(_entry, nil), do: nil

  defp line(entry, key) do
    case File.read(entry.path) do
      {:ok, content} -> ConfigLines.line(content, key)
      {:error, _reason} -> nil
    end
  end

  defp since(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
