defmodule SymphonyElixir.AgentTools.ProtectedPathsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTools.ProtectedPaths

  # A git stand-in: no symlinks in any tree, `diff base...head` lists `changed` and
  # `diff remote head` lists `unpushed`.
  defp git(changed, unpushed) do
    fn
      ["ls-tree" | _args] -> {:ok, ""}
      ["diff", "--name-only", "--no-renames", "base...head" | _paths] -> {:ok, Enum.join(changed, "\n")}
      ["diff", "--name-only", "--no-renames", "remote", "head" | _paths] -> {:ok, Enum.join(unpushed, "\n")}
    end
  end

  test "a changed CI workflow is reported" do
    files = [".github/workflows/make-all.yml"]
    assert ProtectedPaths.verify("base", "head", nil, git(files, [])) == {:error, {:protected_paths_changed, files}}
  end

  test "a grant of one workflow lets exactly that file through" do
    changed = [".github/workflows/make-all.yml", ".github/workflows/protected-paths.yml"]

    assert ProtectedPaths.verify("base", "head", nil, git(changed, []), [".github/workflows/make-all.yml"]) ==
             {:error, {:protected_paths_changed, [".github/workflows/protected-paths.yml"]}}
  end

  test "files the branch's remote copy already has don't count" do
    changed = [".github/workflows/make-all.yml", "WORKFLOW.md"]

    assert ProtectedPaths.verify("base", "head", "remote", git(changed, ["WORKFLOW.md"])) ==
             {:error, {:protected_paths_changed, ["WORKFLOW.md"]}}

    assert ProtectedPaths.verify("base", "head", "remote", git(changed, [])) == :ok
  end

  test "with nothing changed, the remote copy is not read" do
    assert ProtectedPaths.verify("base", "head", "remote", git([], ["WORKFLOW.md"])) == :ok
  end
end
