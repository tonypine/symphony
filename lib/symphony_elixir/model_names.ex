defmodule SymphonyElixir.ModelNames do
  @moduledoc """
  A model's name as a person reads it, from the id a run profile resolves: `claude-opus-5-5` is
  "Claude Opus 5.5", `claude-haiku-4-5-20251001` "Claude Haiku 4.5", `gpt-5.1-codex` "GPT 5.1 Codex".

  The id's words are capitalised, its numbers joined by a point, a trailing release date dropped and
  a provider's prefix (`anthropic/claude-opus-5-5`) left out. An id it can't read is returned as it is.
  """

  @upper %{"gpt" => "GPT", "glm" => "GLM", "ai" => "AI"}

  @doc "The display name of the model `id`: \"Claude Opus 5.5\"; nil for nil or a blank id."
  @spec display_name(String.t() | nil) :: String.t() | nil
  def display_name(nil), do: nil

  def display_name(id) when is_binary(id) do
    case id |> String.trim() |> String.split("/") |> List.last() do
      "" -> nil
      name -> name |> String.split("-", trim: true) |> drop_date() |> words() |> Enum.join(" ")
    end
  end

  # A release date (`20251001`) at the end names a snapshot, not the model.
  defp drop_date(parts) do
    case List.last(parts) do
      last when is_binary(last) and byte_size(last) == 8 -> if String.match?(last, ~r/^\d{8}$/), do: Enum.drop(parts, -1), else: parts
      _last -> parts
    end
  end

  # Numbers next to each other are one version (`5`, `5` -> `5.5`); any other part is a word.
  defp words(parts) do
    parts
    |> Enum.chunk_while(
      [],
      fn part, acc ->
        cond do
          number?(part) and acc != [] and Enum.all?(acc, &number?/1) -> {:cont, acc ++ [part]}
          acc == [] -> {:cont, [part]}
          true -> {:cont, acc, [part]}
        end
      end,
      fn acc -> {:cont, acc, []} end
    )
    |> Enum.map(fn
      [word] -> word(word)
      numbers -> Enum.join(numbers, ".")
    end)
  end

  defp number?(part), do: String.match?(part, ~r/^\d+$/)

  defp word(part), do: Map.get_lazy(@upper, part, fn -> String.capitalize(part) end)
end
