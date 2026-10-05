defmodule SymphonyElixir.AutoMerge.FingerprintTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AutoMerge.Fingerprint

  @app_ex """
  defmodule App do
    def alpha(x) do
      x
      |> step_one()
      |> step_two()
    end
  end
  """

  setup do
    root = Path.join(System.tmp_dir!(), "auto-merge-fingerprint-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    author = Path.join(root, "author")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", "--quiet", "--bare", "--initial-branch=main", origin])
    git!(root, ["clone", "--quiet", origin, author])
    git!(author, ["checkout", "--quiet", "-B", "main"])
    commit!(author, %{"lib/app.ex" => @app_ex, "README.md" => "# App\n"})
    git!(author, ["push", "--quiet", "origin", "main"])

    git!(author, ["checkout", "--quiet", "-b", "pr"])
    head = commit!(author, %{"lib/app.ex" => String.replace(@app_ex, "|> step_one()", "|> step_one(:fast)")})
    git!(author, ["push", "--quiet", "origin", "pr"])

    git!(root, ["clone", "--quiet", origin, workspace])
    %{root: root, author: author, workspace: workspace, record: %{workspace_path: workspace}, head: head}
  end

  test "merging the base branch in or rebasing cleanly keeps the fingerprint; a code change does not", %{author: author, record: record, head: head} do
    assert {:ok, approved} = Fingerprint.compute(record, head)
    assert approved =~ ~r/^[0-9a-f]{40}$/

    # main moves on in another file; Symphony's update-branch merges it into the PR.
    git!(author, ["checkout", "--quiet", "main"])
    commit!(author, %{"README.md" => "# App\n\nMore.\n"})
    git!(author, ["push", "--quiet", "origin", "main"])
    git!(author, ["checkout", "--quiet", "pr"])
    git!(author, ["merge", "--quiet", "--no-edit", "main"])
    merged = git!(author, ["rev-parse", "HEAD"])
    git!(author, ["push", "--quiet", "origin", "pr"])

    # The workspace hasn't fetched the merge commit: it is fetched from origin.
    assert {:ok, ^approved} = Fingerprint.compute(record, merged)

    git!(author, ["checkout", "--quiet", "-b", "rebased", head])
    git!(author, ["rebase", "--quiet", "main"])
    rebased = git!(author, ["rev-parse", "HEAD"])
    git!(author, ["push", "--quiet", "origin", "rebased"])
    assert {:ok, ^approved} = Fingerprint.compute(record, rebased)

    git!(author, ["checkout", "--quiet", "pr"])
    fixed = commit!(author, %{"lib/app.ex" => String.replace(@app_ex, "|> step_one()", "|> step_one(:faster)")})
    git!(author, ["push", "--quiet", "origin", "pr"])
    assert {:ok, other} = Fingerprint.compute(record, fixed)
    refute other == approved
  end

  test "a head with no diff of its own has the empty fingerprint", %{workspace: workspace, record: record} do
    main = git!(workspace, ["rev-parse", "origin/main"])
    assert Fingerprint.compute(record, main) == {:ok, "empty"}
  end

  test "a record without a local workspace has nothing to compare", %{root: root, head: head} do
    assert Fingerprint.compute(%{}, head) == {:error, :no_workspace}
    assert Fingerprint.compute(%{workspace_path: ""}, head) == {:error, :no_workspace}
    assert Fingerprint.compute(%{workspace_path: Path.join(root, "missing")}, head) == {:error, :no_workspace}
  end

  test "git failures are errors", %{root: root, author: author, workspace: workspace, record: record, head: head} do
    unknown = String.duplicate("0", 40)
    assert {:error, {:commit_unavailable, ^unknown, _status, _output}} = Fingerprint.compute(record, unknown)

    git!(author, ["checkout", "--quiet", "--orphan", "unrelated"])
    git!(author, ["rm", "--quiet", "-rf", "."])
    orphan = commit!(author, %{"other.txt" => "other\n"})
    git!(author, ["push", "--quiet", "origin", "unrelated"])
    assert {:error, {:git_failed, "merge-base", 1, _output}} = Fingerprint.compute(record, orphan)

    assert {:error, {:git_failed, "patch-id", 1, "boom"}} = Fingerprint.compute(record, head, patch_id: fn _diff -> {"boom\n", 1} end)

    git!(workspace, ["remote", "set-url", "origin", Path.join(root, "gone.git")])
    assert {:error, {:git_failed, "fetch", _status, _output}} = Fingerprint.compute(record, head)
  end

  defp commit!(dir, files) do
    Enum.each(files, fn {path, content} ->
      path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "change #{Enum.join(Map.keys(files), ", ")}"])
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args) do
    identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgSign=false"]
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

    case System.cmd("git", ["-C", dir | identity ++ args], stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
