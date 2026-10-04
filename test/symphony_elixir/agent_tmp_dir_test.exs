defmodule SymphonyElixir.AgentTmpDirTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTmpDir

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-agent-tmp-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "names one short folder per base after a hash of its owner", %{root: root} do
    assert [first, second] = AgentTmpDir.paths("symphony-run-", "/work/TP-1", [root, "/tmp"])
    assert first =~ ~r"^#{root}/symphony-run-[0-9a-f]{12}$"
    assert Path.basename(first) == Path.basename(second)
    assert AgentTmpDir.paths("symphony-run-", "/work/TP-1", [root]) == [first]
    refute AgentTmpDir.paths("symphony-run-", "/work/TP-2", [root]) == [first]
    assert hd(AgentTmpDir.default_bases()) == "/tmp"
  end

  test "creates the first folder it can, private and empty", %{root: root} do
    blocker = Path.join(root, "file")
    File.write!(blocker, "")
    [unusable, usable] = AgentTmpDir.paths("symphony-run-", "/work/TP-1", [blocker, root])
    File.mkdir_p!(usable)
    File.write!(Path.join(usable, "stale.txt"), "")

    assert {:ok, ^usable} = AgentTmpDir.create([unusable, usable])
    assert File.ls!(usable) == []
    assert Bitwise.band(File.stat!(usable).mode, 0o777) == 0o700
    assert AgentTmpDir.create([unusable]) == :error
  end

  test "puts the folder behind the agent's $TMPDIR and in its sandbox writable paths" do
    assert AgentTmpDir.env("claude", "/tmp/x") == %{"CLAUDE_CODE_TMPDIR" => "/tmp/x"}
    assert AgentTmpDir.env("codex", "/tmp/x") == %{"TMPDIR" => "/tmp/x"}
    assert AgentTmpDir.env("claude", nil) == %{}

    settings = AgentTmpDir.allow_write(Config.settings!(), "/tmp/x")
    assert List.last(settings.workspace.sandbox.allow_write_paths) == "/tmp/x"
  end
end
