defmodule SymphonyElixir.MissingCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.MissingCoverage

  @tag :tmp_dir
  test "names the uncovered lines of each module below 100%, skipping ignored and covered ones", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.coverdata"), "")
    test_pid = self()

    lines = %{
      Full => [{{Full, 0}, {0, 1}}, {{Full, 3}, {1, 0}}],
      Gap => [{{Gap, 3}, {1, 0}}, {{Gap, 8}, {0, 1}}, {{Gap, 9}, {0, 1}}],
      Skipped => [{{Skipped, 2}, {0, 1}}]
    }

    deps = %{
      import: fn path ->
        send(test_pid, {:imported, List.to_string(path)})
        :ok
      end,
      modules: fn -> [Full, Gap, Skipped, Gone] end,
      analyse: fn module ->
        case Map.fetch(lines, module) do
          {:ok, result} -> {:ok, result}
          :error -> {:error, :not_cover_compiled}
        end
      end,
      source: &"lib/#{&1 |> inspect() |> String.downcase()}.ex"
    }

    assert MissingCoverage.describe(dir, [Skipped], deps) == ["Gap uncovered: lib/gap.ex:8, lib/gap.ex:9"]
    assert_received {:imported, imported}
    assert imported == Path.join(dir, "a.coverdata")
    assert MissingCoverage.describe(dir, [~r/^Gap$/, Skipped], deps) == []
  end

  @tag :tmp_dir
  test "the default :cover calls find nothing in a directory without coverage data", %{tmp_dir: dir} do
    assert MissingCoverage.describe(dir, []) == []
  end

  test "the default analyse answers an error for a module :cover never saw" do
    assert {:error, _} = MissingCoverage.default_deps().analyse.(NoSuchModuleEver)
  end

  test "the default source is the module's path relative to the project" do
    assert MissingCoverage.default_deps().source.(MissingCoverage) == "lib/symphony_elixir/missing_coverage.ex"
  end
end
