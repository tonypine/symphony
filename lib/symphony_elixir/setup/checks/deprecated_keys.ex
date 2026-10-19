defmodule SymphonyElixir.Setup.Checks.DeprecatedKeys do
  @moduledoc """
  A key the running `symphony.yml` sets that is deprecated (K1): one warning per key, with its path,
  what replaced it and its line. A key that does nothing now gets a `config_edit` remove fix. A key
  that still acts while it is deprecated (the acceptance gate's `mode` and `escalate`) gets an `open`
  fix: removing it would change what Symphony does.
  """

  @behaviour SymphonyElixir.Setup.Check

  alias SymphonyElixir.Config.{Cache, SystemSchema}
  alias SymphonyElixir.Setup.{ConfigLines, Problem}

  @impl true
  def id, do: "deprecated_key"

  @impl true
  def title, do: "Deprecated keys in symphony.yml"

  @impl true
  def needs_linear?, do: false

  @impl true
  def run(context) do
    case Cache.get_symphony(context.symphony_path) do
      {:error, _reason} ->
        []

      # The running config: a rejected edit is reported by the failed-reload check.
      result ->
        content = read(context.symphony_path)
        result |> elem(1) |> SystemSchema.deprecations() |> Enum.map(&problem(&1, content))
    end
  end

  defp problem(%{path: path, replacement: replacement} = deprecation, content) do
    Problem.new(
      id: "#{id()}:#{path}",
      severity: :warning,
      category: :keys,
      title: "symphony.yml sets #{path}, which is deprecated",
      consequence: consequence(deprecation),
      details: [Key: path, Replacement: replacement, Line: content && ConfigLines.line(content, path)],
      fix: fix(deprecation)
    )
  end

  defp consequence(%{no_effect?: true, replacement: replacement}),
    do: "Nothing uses it any more (#{replacement}), and a later Symphony will refuse to load a symphony.yml that still sets it."

  defp consequence(%{replacement: replacement}),
    do: "It still works for now, but it will be removed: #{replacement}. Move the setting before then."

  defp fix(%{no_effect?: true, path: path}), do: Problem.config_edit(path, :remove)
  defp fix(_deprecation), do: Problem.open(:symphony_yml)

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end
end
