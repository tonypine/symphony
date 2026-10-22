defmodule SymphonyElixir.Artifacts.TranscriptTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Artifacts.Transcript

  @session "5f0c6a52-0e4b-4c4f-9d8e-2a1b3c4d5e6f"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-transcripts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:symphony_elixir, :claude_projects_dir)
    Application.put_env(:symphony_elixir, :claude_projects_dir, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :claude_projects_dir, previous),
        else: Application.delete_env(:symphony_elixir, :claude_projects_dir)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "the root is Claude Code's projects folder unless the application names another", %{root: root} do
    assert Transcript.root(:claude) == root

    Application.delete_env(:symphony_elixir, :claude_projects_dir)
    assert Transcript.root(:claude) == Path.expand("~/.claude/projects")
  end

  describe "a Claude Code session's own transcript" do
    test "sits in the folder named after its working directory, every other character as a dash", %{root: root} do
      repo = write!(root, "-Users-tonypine-repos-symphony/#{@session}.jsonl")
      workspace = write!(root, "-Users-tonypine-symphony-workspaces-symphony-TP-1082/#{@session}.jsonl")

      assert Transcript.locate(:claude, "/Users/tonypine/repos/symphony", @session, nil) == {:ok, repo}
      assert Transcript.locate(:claude, "/Users/tonypine/symphony-workspaces/symphony/TP-1082", @session, nil) == {:ok, workspace}
    end

    test "is none when the file is missing, or the session has no id or working directory", %{root: root} do
      write!(root, "-w/#{@session}.jsonl")

      assert Transcript.locate(:claude, "/w", "another-session", nil) == :none
      assert Transcript.locate(:claude, "/w", nil, nil) == :none
      assert Transcript.locate(:claude, nil, @session, nil) == :none
      assert Transcript.locate(:claude, "", @session, nil) == :none
    end

    test "is none for a session id that would name a path outside its folder", %{root: root} do
      write!(root, "-w/#{@session}.jsonl")
      write!(root, "other/#{@session}.jsonl")

      assert Transcript.locate(:claude, "/w", "../other/#{@session}", nil) == :none
    end
  end

  describe "a path the run reported" do
    test "is the transcript when it is a .jsonl file in Claude Code's projects folder", %{root: root} do
      reported = write!(root, "-elsewhere/reported.jsonl")
      write!(root, "-w/#{@session}.jsonl")

      assert Transcript.locate(:claude, "/w", @session, reported) == {:ok, reported}
    end

    test "anywhere else, or not .jsonl, is ignored and logged, and the session's own file is used", %{root: root} do
      own = write!(root, "-w/#{@session}.jsonl")
      outside = write!(System.tmp_dir!(), "symphony-outside-#{System.unique_integer([:positive])}.jsonl")
      on_exit(fn -> File.rm(outside) end)
      not_jsonl = write!(root, "-w/notes.txt")

      for reported <- [outside, not_jsonl, root <> "-sibling/x.jsonl"] do
        log = capture_log(fn -> assert Transcript.locate(:claude, "/w", @session, reported) == {:ok, own} end)
        assert log =~ "Ignoring the reported transcript path #{inspect(reported)}: a transcript is a .jsonl file under #{root}"
      end

      assert capture_log(fn -> assert Transcript.locate(:claude, "/nowhere", @session, outside) == :none end) =~ "Ignoring"
      assert capture_log(fn -> assert Transcript.locate(:claude, "/w", @session, "") == {:ok, own} end) == ""
    end
  end

  test "a Codex session, or one of no known runtime, has none", %{root: root} do
    reported = write!(root, "-w/#{@session}.jsonl")

    assert Transcript.locate(:codex, "/w", @session, reported) == :none
    assert Transcript.locate(nil, "/w", @session, reported) == :none
  end

  defp write!(dir, relative) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"type":"user"}\n))
    path
  end
end
