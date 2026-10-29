defmodule SymphonyElixir.DispatchConfigTest do
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

  test "dispatches from the poll with a window of 20 cycles when the section is missing" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{source: "poll", shadow_window: 20} = Config.system!().dispatch
    assert Config.dispatch_source() == "poll"
    assert Config.dispatch_shadow_window() == 20

    assert {:ok, %{dispatch: %{source: "poll", shadow_window: 20}}} =
             SystemSchema.parse(Map.put(@base, "dispatch", %{"source" => nil, "shadow_window" => nil}))
  end

  test "loads source record and reads the section on each call, so a change applies without a restart" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.dispatch_source() == "poll"

    append_symphony_yml!("dispatch:\n  source: record\n  shadow_window: 5\n")

    assert Config.dispatch_source() == "record"
    assert Config.dispatch_shadow_window() == 5
  end

  test "refuses an unknown source and a window that isn't a positive whole number, naming the key" do
    for {key, value, error} <- [
          {"source", "webhook", "must be one of: poll, record"},
          {"source", 3, "is invalid"},
          {"shadow_window", 0, "must be greater than 0"},
          {"shadow_window", -1, "must be greater than 0"},
          {"shadow_window", 2.5, "is invalid"},
          {"shadow_window", "twenty", "is invalid"}
        ] do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "dispatch", %{key => value}))
      assert message == "dispatch.#{key} #{error}"
    end
  end

  test "refuses an unknown key and a section that isn't an object" do
    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `dispatch.mode`"}} =
             SystemSchema.parse(Map.put(@base, "dispatch", %{"mode" => "poll"}))

    assert {:error, {:invalid_symphony_config, "`dispatch` must be an object"}} = SystemSchema.parse(Map.put(@base, "dispatch", 7))
  end

  test "still refuses the retired dispatch.max_concurrent with where its setting went" do
    assert {:error, {:invalid_symphony_config, "`dispatch.max_concurrent` is not valid; remove it; use `agent.concurrency.max_total`"}} =
             SystemSchema.parse(Map.put(@base, "dispatch", %{"max_concurrent" => 3, "source" => "poll"}))
  end

  test "falls back to the defaults while the config can't be read" do
    File.write!(Workflow.symphony_file_path(), "issues: [\n")
    Cache.clear()

    assert Config.dispatch_source() == "poll"
    assert Config.dispatch_shadow_window() == 20
  end

  test "its keys are symphony.yml settings, which the macOS app must edit or a person exempt" do
    keys = SystemSchema.operator_key_paths()

    assert "dispatch.source" in keys
    assert "dispatch.shadow_window" in keys
  end
end
