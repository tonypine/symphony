defmodule SymphonyElixir.Config.EmbedDependenciesTest do
  use ExUnit.Case, async: true

  # `embeds_one(..., defaults_to_struct: true)` bakes the embed's struct into
  # the parent at compile time, while Ecto only records a runtime reference to
  # the embed. A `require` makes it an export dependency, so Mix recompiles the
  # parent when the embed's struct defaults change. Without it, an incremental
  # build keeps a stale default in the parent (TP-282).
  test "schemas require embeds from other files whose struct they default to" do
    embeds = cross_file_struct_default_embeds()

    assert {SymphonyElixir.Config.SystemSchema, :auto_review, SymphonyElixir.Config.Schema.AutoReview} in embeds

    missing =
      for {parent, field, related} <- embeds,
          related not in required_modules(parent),
          do: "#{inspect(parent)}.#{field}: add `require #{inspect(related)}`"

    assert missing == []
  end

  defp cross_file_struct_default_embeds do
    {:ok, modules} = :application.get_key(:symphony_elixir, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        field <- module.__schema__(:embeds),
        %{related: related} = module.__schema__(:embed, field),
        match?(%^related{}, Map.get(struct(module), field)),
        source(module) != source(related),
        do: {module, field, related}
  end

  defp source(module), do: module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()

  defp required_modules(parent) do
    {:ok, ast} = parent |> source() |> File.read!() |> Code.string_to_quoted()

    {_ast, {aliases, requires}} =
      Macro.prewalk(ast, {%{}, []}, fn
        {:alias, _meta, [{:__aliases__, _, segments}]} = node, {aliases, requires} ->
          {node, {Map.put(aliases, List.last(segments), segments), requires}}

        {:alias, _meta, [{:__aliases__, _, segments}, [as: {:__aliases__, _, [as]}]]} = node, {aliases, requires} ->
          {node, {Map.put(aliases, as, segments), requires}}

        {:require, _meta, [{:__aliases__, _, segments}]} = node, {aliases, requires} ->
          {node, {aliases, [segments | requires]}}

        node, acc ->
          {node, acc}
      end)

    Enum.map(requires, fn [head | rest] -> Module.concat(Map.get(aliases, head, [head]) ++ rest) end)
  end
end
