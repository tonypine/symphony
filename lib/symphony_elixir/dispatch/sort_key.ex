defmodule SymphonyElixir.Dispatch.SortKey do
  @moduledoc """
  Fractional sort keys, the stored order of the dispatch queue (`SymphonyElixir.Dispatch.Queue`).

  A port of the reference fractional indexing algorithm (David Greenspan's `fractional-indexing`,
  after "Implementing Fractional Indexing", observablehq.com/@dgreensp), with its 62-character
  alphabet `0-9A-Za-z`: a key sorts by plain byte comparison, `key_between/2` gives a key between
  two neighbours (nil for an open end: the top or the end of the list) and `n_keys_between/3` gives
  `n` keys evenly spaced between two bounds. A key is an integer part (its head letter says its
  length, so the ends are counted and never run out early) followed by a fraction with no trailing
  zero. No Elixir package of the algorithm is maintained, so it is ported here with the reference's
  published test cases.
  """

  @digits "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @base byte_size(@digits)
  @zero "0"
  @last "z"
  @smallest_integer "A" <> String.duplicate(@zero, 26)

  @typedoc "A fractional sort key."
  @type t :: String.t()

  @doc """
  A key that sorts after `a` and before `b` (either nil for an open end); `{:error, message}` with
  the reference's message when a bound is not a valid key or `a` is not below `b`.
  """
  @spec key_between(t() | nil, t() | nil) :: {:ok, t()} | {:error, String.t()}
  def key_between(a, b) do
    {:ok, between!(a, b)}
  catch
    {:sort_key_error, message} -> {:error, message}
  end

  @doc """
  `n` keys in order, evenly spaced between `a` and `b` (either nil for an open end), as
  `key_between/2` errs.
  """
  @spec n_keys_between(t() | nil, t() | nil, non_neg_integer()) :: {:ok, [t()]} | {:error, String.t()}
  def n_keys_between(a, b, n) when is_integer(n) and n >= 0 do
    {:ok, n_between!(a, b, n)}
  catch
    {:sort_key_error, message} -> {:error, message}
  end

  @doc "Whether `key` is a valid key."
  @spec valid?(term()) :: boolean()
  def valid?(key) when is_binary(key) and key != "" do
    validate_key!(key)
    true
  catch
    {:sort_key_error, _message} -> false
  end

  def valid?(_key), do: false

  defp n_between!(_a, _b, 0), do: []
  defp n_between!(a, b, 1), do: [between!(a, b)]

  defp n_between!(a, nil, n) do
    a |> Stream.iterate(&between!(&1, nil)) |> Stream.drop(1) |> Enum.take(n)
  end

  defp n_between!(nil, b, n) do
    b |> Stream.iterate(&between!(nil, &1)) |> Stream.drop(1) |> Enum.take(n) |> Enum.reverse()
  end

  defp n_between!(a, b, n) do
    half = div(n, 2)
    c = between!(a, b)
    n_between!(a, c, half) ++ [c] ++ n_between!(c, b, n - half - 1)
  end

  defp between!(a, b) do
    if a, do: validate_key!(a)
    if b, do: validate_key!(b)
    if a && b && a >= b, do: fail("#{a} >= #{b}")
    generate(a, b)
  end

  defp generate(nil, nil), do: "a" <> @zero

  defp generate(nil, b) do
    {ib, fb} = split(b)

    cond do
      ib == @smallest_integer -> ib <> midpoint("", fb)
      ib < b -> ib
      true -> decrement(ib)
    end
  end

  defp generate(a, nil) do
    {ia, fa} = split(a)
    increment(ia) || ia <> midpoint(fa, nil)
  end

  defp generate(a, b) do
    {ia, fa} = split(a)
    {ib, fb} = split(b)

    if ia == ib do
      ia <> midpoint(fa, fb)
    else
      # `ia` below `b`'s integer part is never the largest one, so it always increments.
      i = increment(ia)
      if i < b, do: i, else: ia <> midpoint(fa, nil)
    end
  end

  # A fraction between the fractions `a` ("" for zero) and `b` (nil for one).
  defp midpoint(a, b) do
    case common_prefix(a, b) do
      "" -> midpoint_digits(a, b)
      prefix -> prefix <> midpoint(drop(a, byte_size(prefix)), drop(b, byte_size(prefix)))
    end
  end

  defp midpoint_digits(a, b) do
    digit_a = if a == "", do: 0, else: digit(first(a))
    digit_b = if is_nil(b), do: @base, else: digit(first(b))

    cond do
      digit_b - digit_a > 1 -> char(div(digit_a + digit_b + 1, 2))
      b != nil and byte_size(b) > 1 -> first(b)
      true -> char(digit_a) <> midpoint(drop(a, 1), nil)
    end
  end

  # The digits `a` (zero-padded) and `b` share at their start.
  defp common_prefix(_a, nil), do: ""
  defp common_prefix(a, b), do: common_prefix(a, b, 0)

  defp common_prefix(a, b, n) do
    if n < byte_size(b) and digit_at(a, n) == binary_part(b, n, 1),
      do: common_prefix(a, b, n + 1),
      else: binary_part(b, 0, n)
  end

  defp digit_at(a, n) when n < byte_size(a), do: binary_part(a, n, 1)
  defp digit_at(_a, _n), do: @zero

  defp validate_key!(""), do: fail("invalid order key: ")

  defp validate_key!(key) do
    if key == @smallest_integer, do: fail("invalid order key: #{key}")
    {_integer, fraction} = split(key)
    if String.ends_with?(fraction, @zero), do: fail("invalid order key: #{key}")
    :ok
  end

  defp split(key) do
    length = integer_length(first(key))
    if length > byte_size(key), do: fail("invalid order key: #{key}")
    {binary_part(key, 0, length), drop(key, length)}
  end

  defp integer_length(<<head>>) when head in ?a..?z, do: head - ?a + 2
  defp integer_length(<<head>>) when head in ?A..?Z, do: ?Z - head + 2
  defp integer_length(head), do: fail("invalid order key head: #{head}")

  defp increment(<<head, digits::binary>>) do
    case carry(digits, 1) do
      {:ok, digits} -> <<head>> <> digits
      {:overflow, digits} -> grow(head, digits)
    end
  end

  defp grow(?Z, _digits), do: "a" <> @zero
  defp grow(?z, _digits), do: nil
  defp grow(head, digits) when head + 1 > ?a, do: <<head + 1>> <> digits <> @zero
  defp grow(head, digits), do: <<head + 1>> <> drop_last(digits)

  defp decrement(<<head, digits::binary>>) do
    case carry(digits, -1) do
      {:ok, digits} -> <<head>> <> digits
      {:overflow, digits} -> shrink(head, digits)
    end
  end

  # "A" with every digit zero is the smallest integer, which `generate/2` never decrements.
  defp shrink(?a, _digits), do: "Z" <> @last
  defp shrink(head, digits) when head - 1 < ?Z, do: <<head - 1>> <> digits <> @last
  defp shrink(head, digits), do: <<head - 1>> <> drop_last(digits)

  # Adds `step` (1 or -1) to the digits, from the last one: `{:ok, digits}`, or `{:overflow, digits}`
  # when it carried (or borrowed) past the first one.
  defp carry(digits, step) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.map_reduce(true, fn
      d, false ->
        {d, false}

      d, true ->
        case digit(d) + step do
          @base -> {@zero, true}
          -1 -> {@last, true}
          value -> {char(value), false}
        end
    end)
    |> then(fn {reversed, carried} -> {if(carried, do: :overflow, else: :ok), reversed |> Enum.reverse() |> Enum.join()} end)
  end

  defp digit(d) do
    case :binary.match(@digits, d) do
      {index, 1} -> index
      :nomatch -> fail("invalid order key digit: #{d}")
    end
  end

  defp char(index), do: binary_part(@digits, index, 1)
  defp first(key), do: binary_part(key, 0, 1)
  # As the reference's `slice`: past the end gives "".
  defp drop(key, n) when n >= byte_size(key), do: ""
  defp drop(key, n), do: binary_part(key, n, byte_size(key) - n)
  defp drop_last(key), do: binary_part(key, 0, byte_size(key) - 1)

  defp fail(message), do: throw({:sort_key_error, message})
end
