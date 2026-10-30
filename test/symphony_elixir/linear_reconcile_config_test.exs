defmodule SymphonyElixir.LinearReconcileConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.SystemSchema

  @base %{
    "issues" => %{"provider" => "memory"},
    "repositories" => [%{"key" => "web"}],
    "agent" => %{"runtime" => "codex", "command" => "codex app-server"}
  }

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  test "a symphony.yml without the key reconciles every five minutes" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.linear_reconcile_interval_ms() == 300_000
    assert Config.system!().linear.reconcile_interval_ms == 300_000
  end

  test "reads the key on each call" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("linear:\n  reconcile_interval_ms: 60000\n")

    assert Config.linear_reconcile_interval_ms() == 60_000
  end

  test "refuses a value under one minute, naming the key" do
    for value <- [59_999, 0, -1] do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "linear", %{"reconcile_interval_ms" => value}))
      assert message =~ "linear.reconcile_interval_ms must be at least 60000"
    end

    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "linear", %{"reconcile_interval_ms" => "soon"}))
    assert message =~ "linear.reconcile_interval_ms"

    assert {:ok, %{linear: %{reconcile_interval_ms: 60_000}}} = SystemSchema.parse(Map.put(@base, "linear", %{"reconcile_interval_ms" => 60_000}))
  end

  test "falls back to the default while the config can't be read" do
    File.write!(Workflow.symphony_file_path(), "issues: [\n")
    Cache.clear()

    assert Config.linear_reconcile_interval_ms() == 300_000
  end

  test "is a symphony.yml setting" do
    assert "linear.reconcile_interval_ms" in SystemSchema.operator_key_paths()
  end
end
