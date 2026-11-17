defmodule SymphonyElixir.StorageInventoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.StorageInventory
  alias SymphonyElixir.Workflow

  setup do
    previous_temp_roots = Application.get_env(:symphony_elixir, :storage_inventory_temp_roots_override)
    previous_symphony_file = Application.get_env(:symphony_elixir, :symphony_file_path)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-storage-inventory-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_app_env(:storage_inventory_temp_roots_override, previous_temp_roots)
      restore_app_env(:symphony_file_path, previous_symphony_file)
      Cache.clear()
      File.rm_rf(test_root)
    end)

    {:ok,
     test_root: test_root,
     state_root: Path.join(test_root, "state"),
     logs_root: Path.join(test_root, "logs"),
     temp_root: Path.join(test_root, "tmp"),
     workspace_root: Path.join(test_root, "workspaces")}
  end

  test "reports durable roots, audit days, and known temp directories", context do
    %{state_root: state_root, logs_root: logs_root, workspace_root: workspace_root, temp_root: temp_root} = context

    File.mkdir_p!(Path.join(state_root, "audit"))
    File.write!(Path.join([state_root, "audit", "2026-05-20.ndjson"]), "first\n")
    File.write!(Path.join([state_root, "audit", "2026-05-21.ndjson"]), "second\n")
    File.write!(Path.join([state_root, "audit", "notes.txt"]), "not grouped\n")
    File.mkdir_p!(Path.join([state_root, "run_store", "core_dumps"]))
    File.write!(Path.join([state_root, "run_store", "schema.DAT"]), "store\n")
    File.write!(Path.join([state_root, "run_store", "core_dumps", "erl_crash.dump"]), "core\n")
    File.mkdir_p!(logs_root)
    File.write!(Path.join(logs_root, "symphony.log"), "log\n")
    File.mkdir_p!(Path.join([workspace_root, "repo", "RSM-1"]))
    File.write!(Path.join([workspace_root, "repo", "RSM-1", "file.txt"]), "workspace\n")
    File.mkdir_p!(Path.join(temp_root, "symphony-mcp-session"))
    File.write!(Path.join([temp_root, "symphony-mcp-session", "socket"]), "tmp\n")
    unreadable_temp_dir = Path.join(temp_root, "symphony-codex-home-unreadable")
    File.mkdir_p!(unreadable_temp_dir)
    File.chmod!(unreadable_temp_dir, 0)
    on_exit(fn -> File.chmod(unreadable_temp_dir, 0o700) end)

    report =
      StorageInventory.inventory(
        state_root: state_root,
        logs_root: logs_root,
        workspace_root: workspace_root,
        temp_roots: [temp_root]
      )

    assert report.usage.app_logs.files == 1
    assert report.usage.run_store.files == 2
    assert report.usage.workspace_root.files == 1
    assert Enum.map(report.audit_days, & &1.date) == ["2026-05-20", "2026-05-21"]

    assert Enum.any?(report.core_dirs, fn %{label: label, usage: usage} ->
             label == "run_store_core_dumps" and usage.files == 1
           end)

    assert Enum.any?(report.temp_groups, fn %{label: label, matches: matches, usage: usage} ->
             label == "mcp_socket_dirs" and length(matches) == 1 and usage.files == 1
           end)

    assert Enum.any?(report.temp_groups, fn %{label: label, usage: usage} ->
             label == "codex_homes" and usage.status == :partial
           end)

    output = StorageInventory.format(report)
    assert output =~ "Symphony cleanup dry-run"
    assert output =~ "No files were deleted"
    assert output =~ "Audit usage by date:"
    assert output =~ "2026-05-20"
    assert output =~ "Known temp/core directories:"
    assert output =~ "mcp_socket_dirs"
    assert output =~ Path.join(temp_root, "symphony-mcp-session")
  end

  test "marks missing paths without raising", %{state_root: state_root, logs_root: logs_root, workspace_root: workspace_root} do
    report =
      StorageInventory.inventory(
        state_root: state_root,
        logs_root: logs_root,
        workspace_root: workspace_root,
        temp_roots: []
      )

    assert report.usage.app_logs.status == :missing
    assert report.usage.audit.status == :missing
    assert report.usage.run_store.status == :missing
    assert report.usage.workspace_root.status == :missing
    assert report.audit_days == []

    assert StorageInventory.format(report) =~ "none found"
  end

  test "reports unreadable root paths", %{test_root: test_root} do
    File.mkdir_p!(test_root)
    file = Path.join(test_root, "not-a-directory")
    File.write!(file, "file\n")

    usage = StorageInventory.path_usage(Path.join(file, "child"))

    assert usage.status == :unreadable
    assert [%{reason: :enotdir}] = usage.errors
  end

  test "uses configured defaults when explicit roots are omitted", %{temp_root: temp_root} do
    Application.put_env(:symphony_elixir, :storage_inventory_temp_roots_override, [temp_root])
    workspace_root = Path.join(temp_root, "configured-workspaces")
    write_symphony_config!(temp_root, workspace_root)

    report = StorageInventory.inventory()

    assert is_binary(report.roots.state_root)
    assert is_binary(report.roots.logs_root)
    assert report.roots.workspace_root == workspace_root
  end

  test "formats human byte units" do
    report = %{
      roots: %{state_root: "/state", logs_root: "/logs", workspace_root: "/workspaces"},
      usage: %{
        app_logs: usage("/logs", 2_048),
        audit: usage("/state/audit", 2_097_152),
        run_store: usage("/state/run_store", 2_147_483_648),
        workspace_root: usage("/workspaces", 512)
      },
      audit_days: [],
      core_dirs: [],
      temp_groups: []
    }

    output = StorageInventory.format(report)

    assert output =~ "2.0 KiB"
    assert output =~ "2.0 MiB"
    assert output =~ "2.0 GiB"
  end

  defp usage(path, bytes) do
    %{path: path, status: :ok, bytes: bytes, files: 1, dirs: 0, errors: []}
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
      - key: storage-inventory-test
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

    Workflow.set_symphony_file_path(symphony_path)
    Cache.clear()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
