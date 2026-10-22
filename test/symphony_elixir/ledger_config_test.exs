defmodule SymphonyElixir.LedgerConfigTest do
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

  test "keeps artifact files 14 days and takes files up to 25 MB when the section is missing" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{artifact_retention_days: 14, artifact_max_bytes: 26_214_400} = Config.system!().ledger
    assert Config.artifact_retention_days() == 14
    assert Config.artifact_max_bytes() == 26_214_400

    assert {:ok, %{ledger: %{artifact_retention_days: 14, artifact_max_bytes: 26_214_400}}} =
             SystemSchema.parse(Map.put(@base, "ledger", %{"artifact_retention_days" => nil}))
  end

  test "reads the ledger section of symphony.yml on each call, so a change applies without a restart" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.artifact_retention_days() == 14

    append_symphony_yml!("ledger:\n  artifact_retention_days: 7\n  artifact_max_bytes: 52428800\n")

    assert Config.artifact_retention_days() == 7
    assert Config.artifact_max_bytes() == 52_428_800
  end

  test "refuses a retention or cap of 0, a negative number or a non-integer, naming the key" do
    for {key, value, error} <- [
          {"artifact_retention_days", 0, "must be greater than 0"},
          {"artifact_retention_days", -3, "must be greater than 0"},
          {"artifact_retention_days", 1.5, "is invalid"},
          {"artifact_retention_days", "two weeks", "is invalid"},
          {"artifact_max_bytes", 0, "must be greater than 0"},
          {"artifact_max_bytes", -1, "must be greater than 0"},
          {"artifact_max_bytes", 2.5, "is invalid"},
          {"artifact_max_bytes", "25MB", "is invalid"}
        ] do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "ledger", %{key => value}))
      assert message == "ledger.#{key} #{error}"
    end
  end

  test "refuses an unknown key and a section that isn't an object" do
    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `ledger.retention_days`"}} =
             SystemSchema.parse(Map.put(@base, "ledger", %{"retention_days" => 7}))

    assert {:error, {:invalid_symphony_config, "`ledger` must be an object"}} = SystemSchema.parse(Map.put(@base, "ledger", 7))
  end

  test "both keys are symphony.yml settings, which the macOS app must edit" do
    keys = SystemSchema.operator_key_paths()

    assert "ledger.artifact_retention_days" in keys
    assert "ledger.artifact_max_bytes" in keys
    assert "ledger.prompt_brief_enabled" in keys
    assert "ledger.prompt_brief_max_tokens" in keys
  end

  test "gives agents the ticket's history summary, guarded at 50,000 tokens, when the section is missing" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{prompt_brief_enabled: true, prompt_brief_max_tokens: 50_000} = Config.system!().ledger
    assert Config.prompt_brief_enabled?()
    assert Config.prompt_brief_max_tokens() == 50_000

    assert {:ok, %{ledger: %{prompt_brief_enabled: true, prompt_brief_max_tokens: 50_000}}} =
             SystemSchema.parse(Map.put(@base, "ledger", %{"prompt_brief_enabled" => nil, "prompt_brief_max_tokens" => nil}))
  end

  test "reads the summary settings on each call, so a change applies without a restart" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.prompt_brief_enabled?()

    append_symphony_yml!("ledger:\n  prompt_brief_enabled: false\n  prompt_brief_max_tokens: 2000\n")

    refute Config.prompt_brief_enabled?()
    assert Config.prompt_brief_max_tokens() == 2_000
  end

  test "refuses a summary switch that isn't true or false and a limit that isn't a positive whole number, naming the key" do
    for {key, value, error} <- [
          {"prompt_brief_enabled", "sometimes", "is invalid"},
          {"prompt_brief_enabled", 3, "is invalid"},
          {"prompt_brief_max_tokens", 0, "must be greater than 0"},
          {"prompt_brief_max_tokens", -50, "must be greater than 0"},
          {"prompt_brief_max_tokens", 1.5, "is invalid"},
          {"prompt_brief_max_tokens", "50k", "is invalid"}
        ] do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "ledger", %{key => value}))
      assert message == "ledger.#{key} #{error}"
    end
  end
end
