defmodule SymphonyElixir.AsyncEnvGuardTest do
  # The process environment is global to the test VM. An `async: true` module that changes `PATH`
  # makes every concurrent test that looks up an executable (`git`, `ssh`, `tart`) fail with
  # `:enoent` for as long as it runs (TP-1297). Tests that change `PATH` go in an `async: false`
  # module, which may sit in the same file as the async one.
  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)

  test "no async test module changes PATH" do
    offenders =
      @test_root
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> path_writes_in_async_modules(file)
        |> Enum.map(&"#{Path.relative_to(file, Path.dirname(@test_root))}:#{&1}")
      end)

    assert offenders == [],
           "These async: true test modules change PATH, which races every concurrent test that " <>
             "runs a command. Move those tests to an async: false module:\n" <> Enum.join(offenders, "\n")
  end

  describe "the detector" do
    test "flags a PATH write in an async module, and in a helper module nested in one" do
      source = """
      defmodule A do
        use ExUnit.Case, async: true

        test "unset" do
          System.delete_env("PATH")
          System.put_env("PATH", "/tmp")
          System.put_env(%{"PATH" => "/tmp", "HOME" => "/tmp"})
          System.put_env([{"PATH", "/tmp"}])
          restore_env("PATH", nil)
        end

        defmodule Helper do
          def run, do: System.put_env("PATH", "/tmp")
        end
      end
      """

      assert path_writes_in_async_modules(source, "a_test.exs") == [5, 6, 7, 8, 9, 13]
    end

    test "passes an async: false module, a default one, and other variables in an async one" do
      source = """
      defmodule A do
        use ExUnit.Case, async: true

        test "other variables" do
          System.put_env("HOME", "/tmp")
          System.delete_env("SYMPHONY_TOKEN")
          System.get_env("PATH")
        end
      end

      defmodule B do
        use ExUnit.Case, async: false

        test "path", do: System.put_env("PATH", "/tmp")
      end

      defmodule C do
        use SymphonyElixir.TestSupport

        test "path", do: System.delete_env("PATH")
      end
      """

      assert path_writes_in_async_modules(source, "a_test.exs") == []
    end

    test "a test module nested in an async one takes its own async setting" do
      source = """
      defmodule A do
        use ExUnit.Case, async: true

        defmodule B do
          use ExUnit.Case, async: false

          test "path", do: System.put_env("PATH", "/tmp")
        end
      end
      """

      assert path_writes_in_async_modules(source, "a_test.exs") == []
    end
  end

  defp path_writes_in_async_modules(source, file) do
    source
    |> Code.string_to_quoted!(file: file)
    |> walk(false, [])
    |> Enum.reverse()
  end

  defp walk({:defmodule, _meta, [_alias, [do: body]]}, async?, acc) do
    walk(body, module_async(body, async?), acc)
  end

  defp walk({_form, meta, args} = node, true, acc) when is_list(args) do
    acc = if path_write?(node), do: [Keyword.fetch!(meta, :line) | acc], else: acc
    walk_children(node, true, acc)
  end

  defp walk(node, async?, acc), do: walk_children(node, async?, acc)

  defp walk_children({form, _meta, args}, async?, acc) when is_list(args) do
    Enum.reduce([form | args], acc, &walk(&1, async?, &2))
  end

  defp walk_children({left, right}, async?, acc), do: walk(right, async?, walk(left, async?, acc))
  defp walk_children(list, async?, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, async?, &2))
  defp walk_children(_leaf, _async?, acc), do: acc

  # A module that uses a test case takes that case's async setting (ExUnit's default is false);
  # a helper module without one runs inside its parent's tests, so it takes the parent's.
  defp module_async(body, inherited) do
    case Enum.find(statements(body), &test_case_use?/1) do
      {:use, _meta, [_module | opts]} -> Keyword.get(List.flatten(opts), :async, false)
      nil -> inherited
    end
  end

  defp test_case_use?({:use, _meta, [module | opts]}), do: test_case?(module, opts)
  defp test_case_use?(_statement), do: false

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  defp test_case?({:__aliases__, _meta, parts}, opts) do
    List.last(parts) |> Atom.to_string() |> String.ends_with?("Case") or
      parts == [:SymphonyElixir, :TestSupport] or Keyword.has_key?(List.flatten(opts), :async)
  end

  defp test_case?(_module, _opts), do: false

  defp path_write?({{:., _, [{:__aliases__, _, [:System]}, fun]}, _, ["PATH" | _]})
       when fun in [:put_env, :delete_env],
       do: true

  defp path_write?({{:., _, [{:__aliases__, _, [:System]}, :put_env]}, _, [{:%{}, _, pairs}]}),
    do: Enum.any?(pairs, &match?({"PATH", _}, &1))

  defp path_write?({{:., _, [{:__aliases__, _, [:System]}, :put_env]}, _, [pairs]}) when is_list(pairs),
    do: Enum.any?(pairs, &match?({"PATH", _}, &1))

  defp path_write?({:restore_env, _, ["PATH", _]}), do: true
  defp path_write?(_node), do: false
end
