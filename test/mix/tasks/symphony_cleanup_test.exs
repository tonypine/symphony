defmodule Mix.Tasks.Symphony.CleanupTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Symphony.Cleanup
  alias SymphonyElixir.Config.Cache

  setup do
    previous_shell = Mix.shell()
    previous_state_root = Application.get_env(:symphony_elixir, :state_root_override)
    previous_logs_root = Application.get_env(:symphony_elixir, :logs_root_override)
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_temp_roots = Application.get_env(:symphony_elixir, :storage_inventory_temp_roots_override)
    previous_symphony_file = Application.get_env(:symphony_elixir, :symphony_file_path)
    Mix.shell(Mix.Shell.Process)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cleanup-task-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_app_env(:state_root_override, previous_state_root)
      restore_app_env(:logs_root_override, previous_logs_root)
      restore_app_env(:log_file, previous_log_file)
      restore_app_env(:storage_inventory_temp_roots_override, previous_temp_roots)
      restore_app_env(:symphony_file_path, previous_symphony_file)
      Cache.clear()
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root, state_root: Path.join(test_root, "state"), logs_root: Path.join(test_root, "logs"), workspace_root: Path.join(test_root, "workspaces")}
  end

  test "prints dry-run storage inventory", %{
    test_root: test_root,
    state_root: state_root,
    logs_root: logs_root,
    workspace_root: workspace_root
  } do
    File.mkdir_p!(Path.join(state_root, "audit"))
    File.write!(Path.join([state_root, "audit", "2026-05-21.ndjson"]), "{}\n")
    File.mkdir_p!(Path.join(state_root, "run_store"))
    File.write!(Path.join([state_root, "run_store", "schema.DAT"]), "store\n")
    File.mkdir_p!(logs_root)
    File.write!(Path.join(logs_root, "symphony.log"), "log\n")
    File.mkdir_p!(workspace_root)
    File.write!(Path.join(workspace_root, "workspace.txt"), "workspace\n")

    Cleanup.run([
      "--dry-run",
      "--config",
      "test/fixtures/runtime/symphony.yml",
      "--state-root",
      state_root,
      "--logs-root",
      logs_root,
      "--workspace-root",
      workspace_root,
      "--temp-root",
      Path.join(test_root, "tmp")
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "Symphony cleanup dry-run"
    assert output =~ "app_logs:"
    assert output =~ "audit:"
    assert output =~ "run_store:"
    assert output =~ "workspace_root:"
    assert output =~ "2026-05-21"
    assert output =~ "No files were deleted"
  end

  test "requires dry-run and rejects apply" do
    assert_raise Mix.Error, ~r/Usage: mix symphony.cleanup --dry-run/, fn ->
      Cleanup.run([])
    end

    assert_raise Mix.Error, ~r/Usage: mix symphony.cleanup --dry-run/, fn ->
      Cleanup.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/--apply is not supported yet/, fn ->
      Cleanup.run(["--apply"])
    end
  end

  test "uses default temp roots when temp root is omitted", %{
    test_root: test_root,
    state_root: state_root,
    logs_root: logs_root,
    workspace_root: workspace_root
  } do
    temp_root = Path.join(test_root, "default-tmp")
    File.mkdir_p!(Path.join(temp_root, "symphony-mcp-default"))
    Application.put_env(:symphony_elixir, :storage_inventory_temp_roots_override, [temp_root])

    Cleanup.run([
      "--dry-run",
      "--state-root",
      state_root,
      "--logs-root",
      logs_root,
      "--workspace-root",
      workspace_root
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "symphony-mcp-default"
  end

  test "uses the last repeated root flag", %{
    test_root: test_root
  } do
    first_state_root = Path.join(test_root, "first-state")
    last_state_root = Path.join(test_root, "last-state")
    first_logs_root = Path.join(test_root, "first-logs")
    last_logs_root = Path.join(test_root, "last-logs")
    first_workspace_root = Path.join(test_root, "first-workspaces")
    last_workspace_root = Path.join(test_root, "last-workspaces")

    File.mkdir_p!(Path.join(last_state_root, "audit"))
    File.write!(Path.join([last_state_root, "audit", "2026-05-22.ndjson"]), "{}\n")
    File.mkdir_p!(last_logs_root)
    File.write!(Path.join(last_logs_root, "symphony.log"), "log\n")
    File.mkdir_p!(last_workspace_root)
    File.write!(Path.join(last_workspace_root, "workspace.txt"), "workspace\n")

    Cleanup.run([
      "--dry-run",
      "--state-root",
      first_state_root,
      "--state-root",
      last_state_root,
      "--logs-root",
      first_logs_root,
      "--logs-root",
      last_logs_root,
      "--workspace-root",
      first_workspace_root,
      "--workspace-root",
      last_workspace_root
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "state_root: #{last_state_root}"
    assert output =~ "logs_root: #{last_logs_root}"
    assert output =~ "workspace_root: #{last_workspace_root}"
    assert output =~ "2026-05-22"
  end

  test "uses configured roots when root flags are omitted", %{
    test_root: test_root
  } do
    workspace_root = Path.join(test_root, "configured-workspaces")
    config_path = write_symphony_config!(test_root, workspace_root)

    Cleanup.run([
      "--dry-run",
      "--config",
      config_path,
      "--temp-root",
      Path.join(test_root, "tmp")
    ])

    assert_receive {:mix_shell, :info, [output]}
    assert output =~ "workspace_root: #{workspace_root}"
  end

  defp write_symphony_config!(root, workspace_root) do
    workflow_path = Path.join(root, "WORKFLOW.md")
    symphony_path = Path.join(root, "symphony.yml")

    File.mkdir_p!(root)
    File.write!(workflow_path, "---\n{}\n---\nTest workflow.\n")

    File.write!(symphony_path, """
    issues:
      provider: memory
    repositories:
      - key: cleanup-task-test
        default: true
        workflow: WORKFLOW.md
    workspaces:
      root: #{workspace_root}
    execution:
      harnesses:
        codex:
          command: codex app-server
    runs:
      default: {harness: codex, provider: openai, model: gpt-test}
    """)

    symphony_path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
