defmodule SymphonyElixir.GitFilterDriversTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitFilterDrivers

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-git-filter-drivers-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp driver_args(name) do
    ["-c", "filter.#{name}.clean=", "-c", "filter.#{name}.smudge=", "-c", "filter.#{name}.process=", "-c", "filter.#{name}.required=false"]
  end

  defp entry(origin, key, value), do: "#{origin}\0#{key}\n#{value}\0"

  # A reader that answers the repo config read with `config` and each `--file` read from `files`,
  # and records every call.
  defp reader(config, files \\ %{}) do
    test = self()

    fn args, opts ->
      send(test, {:git, args, opts})

      case Enum.drop_while(args, &(&1 != "--file")) do
        ["--file", path | _rest] -> Map.get(files, path, {"", 1, ""})
        [] -> config
      end
    end
  end

  test "blanks every driver the config defines, keyed by its name as git prints it" do
    config =
      entry("file:.git/config", "filter.lfs.smudge", "git-lfs smudge -- %f") <>
        entry("file:.git/config", "filter.Odd Name.v2.process", "run") <>
        "file:.git/config\0filter.lfs.required\0" <>
        entry("file:.git/config", "core.bare", "false")

    assert GitFilterDrivers.config_args(["-C", "/repo", "status"], [], reader({config, 0, ""})) ==
             {:ok, driver_args("Odd Name.v2") ++ driver_args("lfs")}

    assert_received {:git, ["-C", "/repo", "config", "-z", "--show-origin", "--get-regexp", _pattern], []}
  end

  test "reads the config with the command's global options and options" do
    args = ["-c", "user.name=x", "--no-pager", "--work-tree", "/tree", "-C", "/repo", "checkout", "-f"]
    assert GitFilterDrivers.config_args(args, [cd: "/", env: [{"GIT_INDEX_FILE", "/i"}]], reader({"", 1, ""})) == {:ok, []}

    assert_received {:git, ["-c", "user.name=x", "--no-pager", "--work-tree", "/tree", "-C", "/repo", "config" | _rest], [cd: "/", env: [{"GIT_INDEX_FILE", "/i"}]]}

    # No subcommand: git prints its usage, and the scan still reads the config first.
    assert GitFilterDrivers.config_args(["-C", "/repo"], [], reader({"", 1, ""})) == {:ok, []}
    assert_received {:git, ["-C", "/repo", "config" | _rest], []}
  end

  test "reads no config for a subcommand that never touches work-tree content" do
    for args <- [["-C", "/repo", "rev-parse", "HEAD"], ["fetch", "origin"], ["show", "HEAD:README.md"]] do
      assert GitFilterDrivers.config_args(args, [], reader({"", 128, ""})) == {:ok, []}
    end

    refute_received {:git, _args, _opts}
  end

  test "refuses the command when the config can't be read" do
    assert GitFilterDrivers.config_args(["-C", "/missing", "status"], [], reader({"", 128, "fatal: cannot change to '/missing'\n"})) ==
             {:error, "symphony: refusing to run git, reading its config failed: fatal: cannot change to '/missing'\n", 128}
  end

  test "refuses the command when a driver name holds `=`, which -c would split on" do
    config = entry("file:.git/config", "filter.a=b.smudge", "touch /tmp/pwned")

    assert {:error, message, 128} = GitFilterDrivers.config_args(["status"], [], reader({config, 0, ""}))
    assert message =~ ~s(filter driver "a=b")
  end

  test "blanks drivers in included files whatever the include's condition", %{root: root} do
    nested = Path.join(root, "nested.cfg")
    worktree_only = Path.join(root, "worktree-only.cfg")
    absolute = Path.join(root, "absolute.cfg")
    for path <- [nested, worktree_only, absolute], do: File.write!(path, "")

    config =
      entry("file:.git/config", "includeif.gitdir:**/worktrees/**.path", "../../worktree-only.cfg") <>
        entry("file:.git/config", "include.path", "~/symphony-no-such-file.cfg") <>
        entry("file:.git/config", "include.path", "") <>
        entry("command line:", "include.path", "relative.cfg") <>
        entry("command line:", "include.path", absolute)

    files = %{
      worktree_only => {entry("file:#{worktree_only}", "filter.hidden.smudge", "evil") <> entry("file:#{worktree_only}", "include.path", "nested.cfg"), 0, ""},
      nested => {entry("file:#{nested}", "filter.deeper.clean", "evil") <> entry("file:#{nested}", "include.path", worktree_only), 0, ""},
      absolute => {"", 128, "fatal: bad config line 1"}
    }

    assert GitFilterDrivers.config_args(["-C", "repo", "worktree", "add", "/w", "b"], [cd: root], reader({config, 0, ""}, files)) ==
             {:ok, driver_args("deeper") ++ driver_args("hidden")}

    # Each file is read once, without its own includes, and only files that exist are read.
    assert_received {:git, ["config", "--file", ^worktree_only, "--no-includes" | _rest], _opts}
    assert_received {:git, ["config", "--file", ^nested, "--no-includes" | _rest], _opts}
    assert_received {:git, ["config", "--file", ^absolute, "--no-includes" | _rest], _opts}
    refute_received {:git, ["config", "--file", ^worktree_only | _rest], _opts}
  end

  test "stops following includes at git's depth limit", %{root: root} do
    paths = for i <- 1..12, do: Path.join(root, "#{i}.cfg")
    for path <- paths, do: File.write!(path, "")

    files =
      paths
      |> Enum.with_index(1)
      |> Map.new(fn {path, i} ->
        next = Path.join(root, "#{i + 1}.cfg")
        {path, {entry("file:#{path}", "filter.d#{i}.smudge", "x") <> entry("file:#{path}", "include.path", next), 0, ""}}
      end)

    config = entry("command line:", "include.path", hd(paths))

    assert {:ok, args} = GitFilterDrivers.config_args(["status"], [], reader({config, 0, ""}, files))
    assert args == Enum.flat_map(Enum.sort(for(i <- 1..10, do: "d#{i}")), &driver_args/1)
  end
end
