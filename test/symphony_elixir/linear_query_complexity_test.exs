defmodule SymphonyElixir.LinearQueryComplexityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Inbox.References
  alias SymphonyElixir.PullRequestPage

  # Linear turns a query down above 10,000 complexity points.
  @linear_limit 10_000

  # Linear's documented query complexity, estimated high, as the Mac app's
  # `LinearQueryComplexityTests.swift` does: a scalar field costs 0.1 points, an object 1, and a
  # connection multiplies what it holds by its page size, `first`, or 50 when a `nodes` list has none.
  # It multiplies `pageInfo` too, and counts a field an `@include` may leave out, so a query under
  # this estimate is under Linear's own count.
  defmodule Estimate do
    @moduledoc false

    def points(query, variables) do
      tokens = query |> tokenize() |> Enum.drop_while(&(&1 != :open)) |> tl()
      {points, depth, _names, []} = selection(tokens, variables)
      %{points: points, connection_depth: depth}
    end

    defp selection([:close | rest], _variables), do: {0.0, 0, MapSet.new(), rest}

    defp selection([{:name, _alias}, :colon, {:name, _name} = field | rest], variables), do: selection([field | rest], variables)

    defp selection([{:name, name} | rest], variables) do
      {args, rest} = args(rest)
      rest = skip_directives(rest)

      {points, depth, rest} =
        case rest do
          [:open | rest] ->
            {child_points, child_depth, child_names, rest} = selection(rest, variables)
            page = page_size(args, variables) || if(MapSet.member?(child_names, "nodes"), do: 50)
            {1 + (page || 1) * child_points, child_depth + if(page, do: 1, else: 0), rest}

          rest ->
            {0.1, 0, rest}
        end

      {more_points, more_depth, names, rest} = selection(rest, variables)
      {points + more_points, max(depth, more_depth), MapSet.put(names, name), rest}
    end

    defp args([{:args, args} | rest]), do: {args, rest}
    defp args(rest), do: {"", rest}

    defp skip_directives([{:directive, _name} | rest]), do: rest |> args() |> elem(1) |> skip_directives()
    defp skip_directives(rest), do: rest

    defp page_size(args, variables) do
      case Regex.run(~r/first\s*:\s*(\$?\w+)/, args) do
        [_, "$" <> variable] -> Map.fetch!(variables, String.to_existing_atom(variable))
        [_, literal] -> String.to_integer(literal)
        nil -> nil
      end
    end

    defp tokenize(<<>>), do: []
    defp tokenize(<<"{", rest::binary>>), do: [:open | tokenize(rest)]
    defp tokenize(<<"}", rest::binary>>), do: [:close | tokenize(rest)]
    defp tokenize(<<":", rest::binary>>), do: [:colon | tokenize(rest)]

    defp tokenize(<<"(", _::binary>> = text) do
      {args, rest} = balanced(text, 0, "")
      [{:args, args} | tokenize(rest)]
    end

    defp tokenize(<<"@", rest::binary>>) do
      [name, rest] = Regex.run(~r/^(\w+)(.*)$/s, rest, capture: :all_but_first)
      [{:directive, name} | tokenize(rest)]
    end

    defp tokenize(<<char::utf8, rest::binary>> = text) do
      case Regex.run(~r/^[\w$!\[\]]+/, text) do
        [name] -> [{:name, name} | tokenize(binary_part(text, byte_size(name), byte_size(text) - byte_size(name)))]
        nil when char in [?\s, ?\n, ?\t, ?\r, ?,] -> tokenize(rest)
      end
    end

    defp balanced(<<"(", rest::binary>>, depth, acc), do: balanced(rest, depth + 1, acc <> "(")
    defp balanced(<<")", rest::binary>>, 1, acc), do: {acc <> ")", rest}
    defp balanced(<<")", rest::binary>>, depth, acc), do: balanced(rest, depth - 1, acc <> ")")
    defp balanced(<<char::utf8, rest::binary>>, depth, acc), do: balanced(rest, depth, acc <> <<char::utf8>>)
  end

  test "the estimate counts scalars, objects, connections and aliases as Linear does" do
    query = """
    query Probe($first: Int!) {
      some: issues(first: $first) @include(if: true) {
        nodes { id state { name } children(first: 5) { nodes { id } } }
        pageInfo { hasNextPage }
      }
    }
    """

    # issues: 1 + 10 × (nodes 1 + id 0.1 + state 1.1 + children (1 + 5 × 1.1) + pageInfo 1.1)
    assert %{points: points, connection_depth: 2} = Estimate.points(query, %{first: 10})
    assert_in_delta points, 1 + 10 * (1 + 0.1 + 1.1 + 6.5 + 1.1), 0.001
  end

  test "the Inbox's one query for every mention and the items' context stays under Linear's limit at its page sizes" do
    {query, limits} = References.query()

    assert %{points: points, connection_depth: depth} = Estimate.points(query, limits)
    assert points < @linear_limit, "SymphonyInboxReferences estimates #{points} points"
    assert depth <= 3
  end

  test "the pull request page's one query for its ticket stays under Linear's limit at its page sizes" do
    {query, limits} = PullRequestPage.query()

    assert %{points: points} = Estimate.points(query, Map.merge(limits, %{url: "u", filter: %{}, withIdentifier: true}))
    assert points < @linear_limit, "SymphonyPullRequestPage estimates #{points} points"
  end
end
