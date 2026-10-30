defmodule SymphonyElixir.HumanActionsConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{RepoWorkflowSchema, SystemSchema}
  alias SymphonyElixir.HumanActions

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp write_repo_workflow!(front_matter) do
    File.write!(Workflow.workflow_file_path(), "---\n#{front_matter}---\nYou are working on {{ issue.identifier }}.\n")
    Cache.clear()
  end

  test "is on by default with the documented settings" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{enabled: true, interval_ms: 300_000, min_update_interval_ms: 900_000} =
             Config.settings!().human_actions
  end

  test "reads the human_actions section of symphony.yml" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("human_actions:\n  interval_ms: 60000\n  min_update_interval_ms: 0\n")

    assert %{enabled: true, interval_ms: 60_000, min_update_interval_ms: 0} =
             Config.settings!().human_actions
  end

  test "rejects the retired human_actions.label as an unknown key" do
    write_workflow_file!(Workflow.workflow_file_path())
    append_symphony_yml!("human_actions:\n  label: human-action\n")

    assert_raise ArgumentError, ~r/unknown symphony.yml key `human_actions.label`/, fn -> Config.settings!() end
  end

  test "an escalate label named human-action is an ordinary escalate label, with no warning" do
    write_workflow_file!(Workflow.workflow_file_path())

    log =
      capture_log(fn ->
        append_symphony_yml!("auto_review:\n  acceptance_gate:\n    escalate:\n      labels: [human-action]\n")
        assert "human-action" in Config.settings!().auto_review.acceptance_gate.escalate.labels
      end)

    refute log =~ "human-action"
  end

  test "rejects unknown keys and invalid values" do
    base = %{
      "issues" => %{"provider" => "memory"},
      "repositories" => [%{"key" => "web"}],
      "agent" => %{"runtime" => "codex", "command" => "codex app-server"}
    }

    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(base, "human_actions", %{"lable" => "x"}))
    assert message =~ "human_actions"

    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(base, "human_actions", %{"label" => "human-action"}))
    assert message == "unknown symphony.yml key `human_actions.label`"

    assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(base, "human_actions", %{"interval_ms" => 0}))
    assert message =~ "interval_ms"
  end

  test "a repository turns it off in its WORKFLOW.md front matter" do
    write_workflow_file!(Workflow.workflow_file_path())
    write_repo_workflow!("human_actions:\n  enabled: false\n")

    refute Config.settings_for_repo!(nil).human_actions.enabled
    refute HumanActions in SymphonyElixir.Application.child_specs_for_runtime(%{})

    assert {:ok, %RepoWorkflowSchema{human_actions: %{"enabled" => false}}} = RepoWorkflowSchema.parse(%{"human_actions" => %{"enabled" => false}})

    for invalid <- [%{"label" => "x"}, %{"enabled" => "no"}] do
      assert {:error, {:invalid_repo_workflow_config, message}} = RepoWorkflowSchema.parse(%{"human_actions" => invalid})
      assert message =~ "supports only a boolean `enabled` key"
    end
  end

  test "starts with the application only for a Linear tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker())
    assert HumanActions in SymphonyElixir.Application.child_specs_for_runtime(%{})

    write_workflow_file!(Workflow.workflow_file_path())
    refute HumanActions in SymphonyElixir.Application.child_specs_for_runtime(%{})
  end

  test "reads every enabled repository route in the scope it polls" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_project_slug: "cycle"))
    test_pid = self()

    collect = fn repos, opts ->
      send(test_pid, {:repos, repos, opts[:settings].human_actions.enabled})
      {:ok, %{}, []}
    end

    HumanActions.run_once(%{opts: [collect: collect], projects: %{}, timer: make_ref()})

    assert_received {:repos, [repo], true}
    assert {:ok, %{"project" => %{"slugId" => %{"eq" => "cycle"}}} = filter} = Client.repo_scope_filter(repo)
    refute Map.has_key?(filter, "state")

    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker(tracker_api_token: nil))
    assert {:error, :missing_linear_api_token} = Client.repo_scope_filter(repo)
  end
end
