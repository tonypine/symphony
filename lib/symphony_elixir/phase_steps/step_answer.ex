defmodule SymphonyElixir.PhaseSteps.StepAnswer do
  @moduledoc """
  What a step's answer and failure look like on the step's own `step.completed` (the step runner,
  `SymphonyElixir.PhaseSteps`, and the stepped QA pass), so Symphony never writes a machine `note`
  to carry a run's step output:

    * `fields/1`: the structured `answer` of a delegated or orchestrated step, a list of
      `%{label, value}` in the answer's key order (the order its map keeps), at most 12 entries,
      the label humanised (underscores to spaces, at most 60 characters) and the value a string of at
      most 1,500 characters: scalars as text, lists one item per line, nested maps flattened to
      `key: value` lines. Never a JSON string; cut, never refused.
    * `reason/1`: why a step ended `failed`, cut to the 300 characters the event takes.
  """

  @max_entries 12
  @label 60
  @value 1_500
  @reason 300
  @none "none"

  @doc "The `answer` entries for a step's answer map; `[]` for an empty answer."
  @spec fields(map()) :: [%{label: String.t(), value: String.t()}]
  def fields(answer) when is_map(answer) do
    answer
    |> Enum.take(@max_entries)
    |> Enum.map(fn {key, value} -> %{label: label(key), value: cut(render(value), @value)} end)
  end

  @doc "Why a step ended `failed`, cut to what the event takes; never blank."
  @spec reason(term()) :: String.t()
  def reason(why) do
    case why |> scalar() |> String.trim() do
      "" -> @none
      text -> cut(text, @reason)
    end
  end

  defp label(key) do
    case key |> scalar() |> String.replace("_", " ") |> String.trim() do
      "" -> "answer"
      label -> cut(label, @label)
    end
  end

  defp render(value) when is_map(value), do: value |> flatten("") |> blank_to_none()
  defp render(value) when is_list(value), do: value |> Enum.map_join("\n", &item/1) |> blank_to_none()
  defp render(value), do: value |> scalar() |> blank_to_none()

  defp item(value) when is_map(value), do: value |> flatten("") |> String.replace("\n", ", ")
  defp item(value) when is_list(value), do: Enum.map_join(value, ", ", &item/1)
  defp item(value), do: scalar(value)

  defp flatten(map, prefix) do
    map
    |> Enum.map_join("\n", fn
      {key, value} when is_map(value) -> flatten(value, prefix <> scalar(key) <> ".")
      {key, value} when is_list(value) -> prefix <> scalar(key) <> ": " <> Enum.map_join(value, ", ", &item/1)
      {key, value} -> prefix <> scalar(key) <> ": " <> scalar(value)
    end)
  end

  defp scalar(nil), do: ""
  defp scalar(value) when is_binary(value), do: String.trim(value)
  defp scalar(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp scalar(value), do: inspect(value)

  defp blank_to_none(text), do: if(String.trim(text) == "", do: @none, else: String.trim(text))

  defp cut(text, max), do: if(String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text)
end
