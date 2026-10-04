defmodule SymphonyElixir.AgentTools.PushCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTools.PushCheck
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workspace

  @branch "auto/ACME-424"
  @config %Schema.PushCheck{command: ".githooks/pre-push --head", result_file: "tmp/push-check", paths: ["*.ex", "mix.lock"]}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-push-check-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    git!(root, ["init", "--bare", "-b", "main", origin])
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Test User"])
    git!(workspace, ["config", "user.email", "test@example.com"])
    git!(workspace, ["remote", "add", "origin", origin])
    commit!(workspace, "README.md", "hello\n")
    git!(workspace, ["push", "origin", "main"])
    git!(workspace, ["fetch", "origin"])
    git!(workspace, ["checkout", "-b", @branch])
    on_exit(fn -> File.rm_rf(root) end)

    %{workspace: workspace}
  end

  test "is off while no command is configured" do
    runner = fn args -> flunk("git #{inspect(args)} should not run") end

    assert :ok = PushCheck.verify("/nowhere", @branch, %Schema.PushCheck{}, runner)
  end

  test "lets a push that changes none of the checked paths through without a result", %{workspace: workspace} do
    commit!(workspace, "docs/notes.md", "notes\n")

    assert :ok = verify(workspace)
  end

  test "lets a push that changes nothing through", %{workspace: workspace} do
    assert :ok = verify(workspace)
  end

  test "requires a result when the push changes a checked path", %{workspace: workspace} do
    head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")

    assert {:error, {:push_check_required, :missing, details}} = verify(workspace)
    assert details == %{"command" => ".githooks/pre-push --head", "result_file" => "tmp/push-check", "head" => head}
  end

  test "counts deleting a checked file as a change", %{workspace: workspace} do
    commit!(workspace, "mix.lock", "%{}\n")
    git!(workspace, ["push", "origin", @branch])
    git!(workspace, ["rm", "-q", "mix.lock"])
    git!(workspace, ["commit", "-q", "-m", "drop lock"])

    assert {:error, {:push_check_required, :missing, _details}} = verify(workspace)
  end

  test "an empty path list checks every push that changes a file", %{workspace: workspace} do
    commit!(workspace, "docs/notes.md", "notes\n")

    assert {:error, {:push_check_required, :missing, _details}} = verify(workspace, %{@config | paths: []})
  end

  test "accepts a pass recorded for the pushed commit", %{workspace: workspace} do
    head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")
    write_result!(workspace, "#{head} pass\n")

    assert :ok = verify(workspace)
  end

  test "refuses a failure recorded for the pushed commit with the recorded failures", %{workspace: workspace} do
    head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")

    write_result!(
      workspace,
      "#{head} fail\nmix format --check-formatted failed. Fix: run `mix format`, commit, and push again.\n"
    )

    assert {:error, {:push_check_failed, details}} = verify(workspace)
    assert details["head"] == head
    assert details["output"] == "mix format --check-formatted failed. Fix: run `mix format`, commit, and push again."

    write_result!(workspace, "#{head} fail")
    assert {:error, {:push_check_failed, %{"output" => ""}}} = verify(workspace)
  end

  test "clamps long failure output on a character boundary", %{workspace: workspace} do
    head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")
    write_result!(workspace, "#{head} fail\na" <> String.duplicate("é", 3_000))

    assert {:error, {:push_check_failed, %{"output" => output}}} = verify(workspace)
    assert String.valid?(output)
    assert String.ends_with?(output, "\n... (truncated)")
    assert byte_size(output) < 4_096 + 20
  end

  test "refuses a result recorded for another commit", %{workspace: workspace} do
    old_head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")
    write_result!(workspace, "#{old_head} pass\n")
    head = commit!(workspace, "lib/app.ex", "defmodule App do\n  def go, do: :ok\nend\n")

    assert {:error, {:push_check_required, :stale, details}} = verify(workspace)
    assert details["head"] == head
    assert details["recorded_head"] == old_head
  end

  test "refuses a result file that is not a push check result", %{workspace: workspace} do
    commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")

    for content <- ["garbage\n", "", "not-a-sha pass\n", "abc pass extra\n"] do
      write_result!(workspace, content)
      assert {:error, {:push_check_required, :invalid, _details}} = verify(workspace)
    end
  end

  test "does not follow a symlink or read a directory or an oversized file", %{workspace: workspace} do
    head = commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")
    target = Path.join(workspace, "elsewhere")
    File.write!(target, "#{head} pass\n")
    result_path = Path.join(workspace, "tmp/push-check")
    File.mkdir_p!(Path.dirname(result_path))

    File.ln_s!(target, result_path)
    assert {:error, {:push_check_required, :invalid, _details}} = verify(workspace)

    File.rm!(result_path)
    File.mkdir_p!(result_path)
    assert {:error, {:push_check_required, :invalid, _details}} = verify(workspace)

    File.rm_rf!(result_path)
    File.write!(result_path, "#{head} pass\n" <> String.duplicate("x", 16_384))
    assert {:error, {:push_check_required, :invalid, _details}} = verify(workspace)

    File.rm_rf!(Path.join(workspace, "tmp"))
    File.write!(Path.join(workspace, "tmp"), "a file where the directory should be")
    assert {:error, {:push_check_required, :invalid, _details}} = verify(workspace)
  end

  test "checks only what the push adds to the branch's remote-tracking ref", %{workspace: workspace} do
    commit!(workspace, "lib/app.ex", "defmodule App do\nend\n")
    git!(workspace, ["push", "origin", @branch])
    commit!(workspace, "docs/notes.md", "notes\n")

    assert :ok = verify(workspace)
  end

  test "checks every push when no base can be found", %{workspace: workspace} do
    git!(workspace, ["update-ref", "-d", "refs/remotes/origin/main"])
    commit!(workspace, "docs/notes.md", "notes\n")

    assert {:error, {:push_check_required, :missing, _details}} = verify(workspace)
  end

  test "checks the push when git cannot list the changed files" do
    runner = fn
      ["rev-parse", "--verify", "--quiet", _ref] -> {:ok, String.duplicate("a", 40) <> "\n"}
      ["diff" | _rest] -> {:error, :diff_failed}
    end

    assert {:error, {:push_check_required, :missing, _details}} =
             PushCheck.verify(System.tmp_dir!(), @branch, %{@config | result_file: "symphony-missing-push-check"}, runner)
  end

  test "fails when the pushed branch does not exist", %{workspace: workspace} do
    assert {:error, {:git_failed, ["rev-parse", "--verify", "--quiet", "refs/heads/missing^{commit}"], _status, _output}} =
             PushCheck.verify(workspace, "missing", @config, runner(workspace))
  end

  defp verify(workspace, config \\ @config), do: PushCheck.verify(workspace, @branch, config, runner(workspace))

  defp runner(workspace) do
    fn args ->
      case Workspace.safe_git(args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {:git_failed, args, status, output}}
      end
    end
  end

  defp write_result!(workspace, content) do
    path = Path.join(workspace, "tmp/push-check")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit!(workspace, file, content) do
    path = Path.join(workspace, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    git!(workspace, ["add", file])
    git!(workspace, ["commit", "-q", "-m", "change #{file}"])
    workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
