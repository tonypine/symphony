defmodule SymphonyElixir.GitConfigCommandsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitConfigCommands

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-git-config-commands-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp driver_args(name) do
    ["-c", "filter.#{name}.clean=", "-c", "filter.#{name}.smudge=", "-c", "filter.#{name}.process=", "-c", "filter.#{name}.required=false"]
  end

  defp entry(scope \\ "local", origin, key, value), do: "#{scope}\0#{origin}\0#{key}\n#{value}\0"

  # A reader that answers the repo config read with `config`, each `--file` read from `files` and
  # the read of git's config directories with `config_dirs`, and records every call.
  defp reader(config, files \\ %{}, config_dirs \\ {"", 128, "fatal: unexpected read"}) do
    test = self()

    fn args, opts ->
      send(test, {:git, args, opts})

      cond do
        "rev-parse" in args -> config_dirs
        "--file" in args -> Map.get(files, Enum.at(args, Enum.find_index(args, &(&1 == "--file")) + 1), {"", 1, ""})
        true -> config
      end
    end
  end

  test "blanks every driver the config defines, keyed by its name as git prints it" do
    config =
      entry("file:.git/config", "filter.lfs.smudge", "git-lfs smudge -- %f") <>
        entry("file:.git/config", "filter.Odd Name.v2.process", "run") <>
        "local\0file:.git/config\0filter.lfs.required\0" <>
        entry("file:.git/config", "core.bare", "false")

    assert GitConfigCommands.config_args(["-C", "/repo", "status"], [], reader({config, 0, ""})) ==
             {:ok, driver_args("Odd Name.v2") ++ driver_args("lfs")}

    assert_received {:git, ["-C", "/repo", "config", "-z", "--show-scope", "--show-origin", "--get-regexp", _pattern], []}
    # No include, so git isn't asked where its config files are.
    refute_received {:git, _args, _opts}
  end

  test "replaces every merge driver the config defines with git's own merge" do
    config =
      entry("file:.git/config", "merge.ours.driver", "touch /tmp/pwned") <>
        entry("file:.git/config", "merge.ours.name", "keep ours") <>
        entry("file:.git/config", "filter.lfs.smudge", "git-lfs smudge -- %f")

    assert GitConfigCommands.config_args(["-C", "/repo", "merge", "--no-commit", "main"], [], reader({config, 0, ""})) ==
             {:ok, driver_args("lfs") ++ ["-c", "merge.ours.driver=git merge-file --marker-size=%L -L %X -L %S -L %Y %A %O %B"]}

    config = entry("file:.git/config", "merge.a=b.driver", "touch /tmp/pwned")
    assert {:error, message, 128} = GitConfigCommands.config_args(["merge", "main"], [], reader({config, 0, ""}))
    assert message =~ ~s(merge driver "a=b")
  end

  test "turns off diff drivers and the config's pack commands right after the subcommand" do
    no_diff_drivers = ["--no-ext-diff", "--no-textconv"]

    assert GitConfigCommands.subcommand_args(["-C", "/repo", "-c", "a.b=c", "--no-pager", "diff", "--stat", "x"]) ==
             ["-C", "/repo", "-c", "a.b=c", "--no-pager", "diff"] ++ no_diff_drivers ++ ["--stat", "x"]

    assert GitConfigCommands.subcommand_args(["log", "-p"]) == ["log" | no_diff_drivers] ++ ["-p"]
    assert GitConfigCommands.subcommand_args(["show", "HEAD"]) == ["show" | no_diff_drivers] ++ ["HEAD"]
    assert GitConfigCommands.subcommand_args(["whatchanged", "-p"]) == ["whatchanged" | no_diff_drivers] ++ ["-p"]
    assert GitConfigCommands.subcommand_args(["blame", "f"]) == ["blame" | no_diff_drivers] ++ ["f"]
    assert GitConfigCommands.subcommand_args(["format-patch", "-1"]) == ["format-patch" | no_diff_drivers] ++ ["-1"]
    assert GitConfigCommands.subcommand_args(["fetch", "origin"]) == ["fetch", "--upload-pack=git-upload-pack", "origin"]
    assert GitConfigCommands.subcommand_args(["ls-remote", "origin"]) == ["ls-remote", "--upload-pack=git-upload-pack", "origin"]
    assert GitConfigCommands.subcommand_args(["pull"]) == ["pull", "--upload-pack=git-upload-pack"]
    assert GitConfigCommands.subcommand_args(["push", "origin", "b"]) == ["push", "--receive-pack=git-receive-pack", "origin", "b"]

    for args <- [["-C", "/repo", "status"], ["-C", "/repo"], [], ["merge", "diff"]] do
      assert GitConfigCommands.subcommand_args(args) == args
    end
  end

  test "reads the config with the command's global options and options" do
    args = ["-c", "user.name=x", "--no-pager", "--work-tree", "/tree", "-C", "/repo", "checkout", "-f"]
    assert GitConfigCommands.config_args(args, [cd: "/", env: [{"GIT_INDEX_FILE", "/i"}]], reader({"", 1, ""})) == {:ok, []}

    assert_received {:git, ["-c", "user.name=x", "--no-pager", "--work-tree", "/tree", "-C", "/repo", "config" | _rest], [cd: "/", env: [{"GIT_INDEX_FILE", "/i"}]]}

    # No subcommand: git prints its usage, and the scan still reads the config first.
    assert GitConfigCommands.config_args(["-C", "/repo"], [], reader({"", 1, ""})) == {:ok, []}
    assert_received {:git, ["-C", "/repo", "config" | _rest], []}
  end

  test "reads no config for a subcommand that never touches work-tree content" do
    for args <- [["-C", "/repo", "rev-parse", "HEAD"], ["fetch", "origin"], ["show", "HEAD:README.md"]] do
      assert GitConfigCommands.config_args(args, [], reader({"", 128, ""})) == {:ok, []}
    end

    refute_received {:git, _args, _opts}
  end

  test "refuses range-diff, whose textconv drivers no option turns off" do
    assert {:error, message, 128} = GitConfigCommands.config_args(["-C", "/repo", "range-diff", "a..b", "c..d"], [], reader({"", 1, ""}))
    assert message == "symphony: refusing to run git, range-diff runs the repo's textconv drivers in a git log no option reaches\n"
    refute_received {:git, _args, _opts}
  end

  test "refuses the command when the config can't be read" do
    assert GitConfigCommands.config_args(["-C", "/missing", "status"], [], reader({"", 128, "fatal: cannot change to '/missing'\n"})) ==
             {:error, "symphony: refusing to run git, reading its config failed: fatal: cannot change to '/missing'\n", 128}
  end

  test "refuses the command when a driver name holds `=`, which -c would split on" do
    config = entry("file:.git/config", "filter.a=b.smudge", "touch /tmp/pwned")

    assert {:error, message, 128} = GitConfigCommands.config_args(["status"], [], reader({config, 0, ""}))
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
        entry("command", "command line:", "include.path", "relative.cfg") <>
        entry("command", "command line:", "include.path", absolute)

    files = %{
      worktree_only => {entry("file:#{worktree_only}", "filter.hidden.smudge", "evil") <> entry("file:#{worktree_only}", "include.path", "nested.cfg"), 0, ""},
      nested => {entry("file:#{nested}", "filter.deeper.clean", "evil") <> entry("file:#{nested}", "include.path", worktree_only), 0, ""},
      absolute => {"", 128, "fatal: bad config line 1"}
    }

    read = reader({config, 0, ""}, files, {"#{root}/repo/.git\n#{root}/repo/.git\n", 0, ""})

    assert GitConfigCommands.config_args(["-C", "repo", "worktree", "add", "/w", "b"], [cd: root], read) ==
             {:ok, driver_args("deeper") ++ driver_args("hidden")}

    # Each file is read once, without its own includes, and only files that exist are read.
    assert_received {:git, ["config", "--file", ^worktree_only, "--no-includes" | _rest], _opts}
    assert_received {:git, ["config", "--file", ^nested, "--no-includes" | _rest], _opts}
    assert_received {:git, ["config", "--file", ^absolute, "--no-includes" | _rest], _opts}
    refute_received {:git, ["config", "--file", ^worktree_only | _rest], _opts}
  end

  test "reads relative includes from the config directories git names", %{root: root} do
    common_dir = Path.join(root, "common")
    git_dir = Path.join(root, "worktree-git")
    local = Path.join(common_dir, "local.cfg")
    worktree = Path.join(git_dir, "worktree.cfg")
    for path <- [local, worktree], do: File.mkdir_p!(Path.dirname(path))
    for path <- [local, worktree], do: File.write!(path, "")

    # From a subdirectory git prints the origin relative to the top of the work tree, not to `-C`.
    config =
      entry("local", "file:.git/config", "include.path", "local.cfg") <>
        entry("worktree", "file:.git/config.worktree", "include.path", "worktree.cfg")

    files = %{
      local => {entry("command", "file:#{local}", "filter.local.smudge", "evil"), 0, ""},
      worktree => {entry("command", "file:#{worktree}", "filter.worktree.clean", "evil"), 0, ""}
    }

    args = ["-c", "user.name=x", "-C", "/repo/sub", "status"]
    read = reader({config, 0, ""}, files, {"#{common_dir}\n#{git_dir}\n", 0, ""})

    assert GitConfigCommands.config_args(args, [cd: "/"], read) == {:ok, driver_args("local") ++ driver_args("worktree")}

    assert_received {:git, ["-c", "user.name=x", "-C", "/repo/sub", "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"], [cd: "/"]}
  end

  test "refuses the command when git can't say where its config files are" do
    config = entry("local", "file:.git/config", "include.path", "local.cfg")

    assert GitConfigCommands.config_args(["status"], [], reader({config, 0, ""}, %{}, {"", 128, "fatal: not a git repository\n"})) ==
             {:error, "symphony: refusing to run git, reading its config failed: fatal: not a git repository\n", 128}

    # A directory name holding a newline leaves the lines ambiguous.
    assert {:error, message, 128} = GitConfigCommands.config_args(["status"], [], reader({config, 0, ""}, %{}, {"/a\nb\n/c\n", 0, ""}))
    assert message =~ "no config directories"
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

    config = entry("command", "command line:", "include.path", hd(paths))

    assert {:ok, args} = GitConfigCommands.config_args(["status"], [], reader({config, 0, ""}, files))
    assert args == Enum.flat_map(Enum.sort(for(i <- 1..10, do: "d#{i}")), &driver_args/1)
  end

  describe "shell_functions/0" do
    setup %{root: root} do
      repo = Path.join(root, "repo")
      File.mkdir_p!(repo)
      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.name", "Test User"])
      git!(repo, ["config", "user.email", "test@example.com"])
      File.write!(Path.join(repo, ".gitattributes"), "*.txt filter=deep\n*.md filter=home\n")
      File.write!(Path.join(repo, "notes.txt"), "stored\n")
      File.write!(Path.join(repo, "notes.md"), "stored\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "attributes"])
      File.mkdir_p!(Path.join([repo, ".git", "inc"]))
      %{repo: repo, proof: Path.join(root, "SYMPHONY_FILTER_PWNED")}
    end

    test "blanks the drivers of every file the repo config includes, whatever the condition", %{root: root, repo: repo, proof: proof} do
      home = Path.join(root, "home")
      File.mkdir_p!(home)
      inc = Path.join([repo, ".git", "inc"])

      # `a` includes itself by another spelling, and `b` through a relative path; neither applies here.
      File.write!(Path.join(inc, "a"), "[filter \"once\"]\n\tclean = cat\n[include]\n\tpath = ../inc/./a\n\tpath = b\n")
      File.write!(Path.join(inc, "b"), "[filter \"deep\"]\n\tsmudge = touch '#{proof}'; cat\n\trequired = true\n")
      File.write!(Path.join(home, "drivers"), "[filter \"home\"]\n\tsmudge = touch '#{proof}'; cat\n")
      git!(repo, ["config", "includeIf.gitdir:/nowhere/.path", "inc/a"])
      git!(repo, ["config", "includeIf.onbranch:nowhere.path", "~/drivers"])

      File.rm!(Path.join(repo, "notes.txt"))
      File.rm!(Path.join(repo, "notes.md"))

      assert {output, 0} =
               run_shell(~s(symphony_git_filter_keys "$repo"; symphony_git "$repo" checkout -- notes.txt notes.md), repo, home)

      assert output |> String.split("\n", trim: true) |> Enum.sort() ==
               ["filter.deep.required", "filter.deep.smudge", "filter.home.smudge", "filter.once.clean"]

      assert File.read!(Path.join(repo, "notes.txt")) == "stored\n"
      assert File.read!(Path.join(repo, "notes.md")) == "stored\n"
      refute File.exists?(proof)
    end

    test "refuses the command when an include path holds a newline", %{repo: repo, proof: proof} do
      git!(repo, ["config", "filter.deep.smudge", "touch '#{proof}'; cat"])
      git!(repo, ["config", "includeIf.gitdir:/nowhere/.path", "a\nb"])

      assert {output, 128} = run_shell(~s(symphony_git "$repo" status 2>&1), repo)
      assert output =~ "symphony: refusing to run git, "
      assert output =~ "includes a path it can't be sure of"

      # Subcommands that touch no work-tree file skip the scan.
      assert {_output, 0} = run_shell(~s(symphony_git "$repo" rev-parse HEAD), repo)

      assert {output, 128} = run_shell(~s(symphony_git "$repo" range-diff HEAD HEAD HEAD 2>&1), repo)
      assert output == "symphony: refusing to run git, range-diff runs the repo's textconv drivers in a git log no option reaches\n"
      refute File.exists?(proof)
    end

    test "refuses the command when one of the repo's own config files can't be read", %{repo: repo} do
      # Git reads `config.worktree` only with `extensions.worktreeConfig`; the scan reads it anyway.
      File.write!(Path.join([repo, ".git", "config.worktree"]), "[broken\n")

      assert {output, 128} = run_shell(~s(symphony_git "$repo" status 2>&1), repo)
      assert output =~ ~r/symphony: refusing to run git, reading .*config\.worktree failed/
    end

    test "an included file git can't read adds no driver", %{repo: repo} do
      File.write!(Path.join([repo, ".git", "inc", "broken"]), "[broken\n")
      git!(repo, ["config", "includeIf.gitdir:/nowhere/.path", "inc/broken"])

      assert {"", 0} = run_shell(~s(symphony_git_filter_keys "$repo" | grep . || true; symphony_git "$repo" status --porcelain), repo)
    end

    test "stops following includes at git's depth limit", %{repo: repo} do
      inc = Path.join([repo, ".git", "inc"])

      for i <- 1..12 do
        File.write!(Path.join(inc, "#{i}"), "[filter \"d#{i}\"]\n\tsmudge = cat\n[include]\n\tpath = #{i + 1}\n")
      end

      git!(repo, ["config", "includeIf.gitdir:/nowhere/.path", "inc/1"])

      assert {output, 0} = run_shell(~s(symphony_git_filter_keys "$repo"), repo)
      assert output |> String.split("\n", trim: true) |> Enum.sort() == Enum.sort(for i <- 1..10, do: "filter.d#{i}.smudge")
    end
  end

  defp run_shell(body, repo, home \\ System.user_home!()) do
    script = Enum.join(["set -eu", SymphonyElixir.Workspace.remote_safe_git_functions(), body], "\n")
    # stderr stays out of the output: the macOS git shim's cache warnings land there in a sandbox.
    System.cmd("sh", ["-c", script], env: [{"repo", repo}, {"HOME", home}])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    output
  end
end
