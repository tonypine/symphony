defmodule SymphonyElixir.Setup.NearMatch do
  @moduledoc """
  Whether a name someone typed is a near miss of one Symphony expects, for the Setup checks that
  name a likely typo (an unknown route value, a misspelt label).

  Two names are near when they match but for case and spaces, or when they are a short edit
  distance apart once case and spaces are folded away: two edits for a name of six characters or
  more, one for a name of three to five, none for a shorter one (two edits turn any two-letter team
  key into any other).
  """

  @doc "Whether `value` is a near match of `name` (nil is near nothing)."
  @spec near?(String.t(), String.t() | nil) :: boolean()
  def near?(_value, nil), do: false

  def near?(value, name) when is_binary(value) and is_binary(name) do
    {value, name} = {fold(value), fold(name)}
    value == name or distance(value, name) <= allowed_distance(name)
  end

  @doc "Whether `left` and `right` differ only by case and spaces."
  @spec same_but_case_and_space?(String.t(), String.t()) :: boolean()
  def same_but_case_and_space?(left, right) when is_binary(left) and is_binary(right), do: fold(left) == fold(right)

  defp fold(text), do: text |> String.downcase() |> String.replace(~r/\s+/u, "")

  defp allowed_distance(name) do
    case String.length(name) do
      length when length >= 6 -> 2
      length when length >= 3 -> 1
      _short -> 0
    end
  end

  # The Levenshtein distance, a row at a time.
  defp distance(left, right) do
    right = String.graphemes(right)

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(Enum.to_list(0..length(right)), fn {char, row}, previous ->
      previous
      |> Enum.zip(tl(previous))
      |> Enum.zip(right)
      |> Enum.reduce([row], fn {{diagonal, above}, other}, [left_cell | _rest] = cells ->
        [Enum.min([left_cell + 1, above + 1, diagonal + if(char == other, do: 0, else: 1)]) | cells]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
