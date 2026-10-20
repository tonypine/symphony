defmodule SymphonyElixir.QaAgent.PlaybookSettingsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.{RepoWorkflowSchema, SystemSchema}
  alias SymphonyElixir.QaAgent.{PlaybookSettings, Selection}

  @base %{
    "issues" => %{"provider" => "memory"},
    "repositories" => [%{"key" => "web"}],
    "agent" => %{"runtime" => "codex", "command" => "codex app-server"}
  }

  defp macos_app(settings), do: %{"macos_app" => Map.merge(%{"build" => "make app", "app" => "build/App.app"}, settings)}

  describe "validate/1" do
    test "accepts the dev server settings and a launch_env of strings" do
      assert PlaybookSettings.validate(macos_app(%{"dev_server" => true, "dev_server_port" => 8090, "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}})) == :ok
      unset = %{macos_app: %{dev_server: false, dev_server_port: nil, launch_env: nil}, cli: nil, web: "on"}
      assert PlaybookSettings.validate(unset) == :ok
      assert PlaybookSettings.validate(nil) == :ok
    end

    test "names the key that is wrong" do
      for {settings, message} <- [
            {%{"dev_server" => "yes"}, "auto_review.playbooks.macos_app.dev_server must be true or false"},
            {%{"dev_server_port" => 0}, "auto_review.playbooks.macos_app.dev_server_port must be a port number from 1 to 65535"},
            {%{"dev_server_port" => "8090"}, "auto_review.playbooks.macos_app.dev_server_port must be a port number from 1 to 65535"},
            {%{"launch_env" => ["HUB_OWNER_TOKEN=abc"]}, "auto_review.playbooks.macos_app.launch_env must be a map of variable names to strings"},
            {%{"launch_env" => %{"hub_token" => "abc"}}, "auto_review.playbooks.macos_app.launch_env.hub_token is not a variable name"},
            {%{"launch_env" => %{"HUB_PORT" => 8090}}, "auto_review.playbooks.macos_app.launch_env.HUB_PORT must be a string; quote the value"}
          ] do
        assert {:error, error} = PlaybookSettings.validate(macos_app(settings))
        assert String.starts_with?(error, message)
      end
    end

    test "refuses the names Symphony sets on the app, PATH, HOME and DYLD_*" do
      for name <- ~w(SYMPHONY_BAR_QA_ROOT SYMPHONY_QA_OPENROUTER_URL SYMPHONY_BAR_QA_API_FIXTURES SYMPHONY_BAR_GH SYMPHONY_QA_GH_URL
                     SYMPHONY_QA_LINEAR_URL SYMPHONY_BAR_UPDATE_URL PATH HOME DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH) do
        assert PlaybookSettings.refused_env?(name)

        assert PlaybookSettings.validate(macos_app(%{"launch_env" => %{name => "x"}})) ==
                 {:error, "auto_review.playbooks.macos_app.launch_env.#{name} is set by Symphony or the system, so launch_env may not set it"}
      end

      refute PlaybookSettings.refused_env?("HUB_OWNER_TOKEN")
    end

    test "fails symphony.yml and a repository's WORKFLOW.md with the key it names" do
      playbooks = macos_app(%{"launch_env" => %{"PATH" => "/opt/homebrew/bin"}})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "auto_review", %{"playbooks" => playbooks}))
      assert message == "auto_review.playbooks.macos_app.launch_env.PATH is set by Symphony or the system, so launch_env may not set it"

      assert {:error, {:invalid_repo_workflow_config, message}} = RepoWorkflowSchema.parse(%{"auto_review" => %{"playbooks" => playbooks}})
      assert message == "auto_review.playbooks.macos_app.launch_env.PATH is set by Symphony or the system, so launch_env may not set it"

      good = macos_app(%{"dev_server" => true, "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}})
      assert {:ok, _config} = SystemSchema.parse(Map.put(@base, "auto_review", %{"playbooks" => good}))
      assert {:ok, _workflow} = RepoWorkflowSchema.parse(%{"auto_review" => %{"playbooks" => good}})
    end
  end

  describe "launch_env/1" do
    test "puts the dev server's port into the values, sorted by name" do
      playbook = %{dev_server_port: 8091, launch_env: %{"HUB_URL" => "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}", "HUB_OWNER_TOKEN" => "abc"}}
      assert PlaybookSettings.launch_env(playbook) == {:ok, [{"HUB_OWNER_TOKEN", "abc"}, {"HUB_URL", "http://127.0.0.1:8091"}]}
      assert PlaybookSettings.launch_env(%{launch_env: %{"HUB_PORT" => "$SYMPHONY_VERIFICATION_PORT"}}) == {:ok, [{"HUB_PORT", "8090"}]}
      assert PlaybookSettings.launch_env(%{}) == {:ok, []}
    end

    test "names a refused variable" do
      assert PlaybookSettings.launch_env(%{launch_env: %{"HOME" => "/tmp"}}) == {:error, "HOME"}
    end
  end

  test "the macos_app playbook carries its dev server port and launch_env" do
    [macos_app] =
      %{playbooks: macos_app(%{"dev_server_port" => 8091, "launch_env" => %{HUB_OWNER_TOKEN: "abc"}})}
      |> Selection.playbooks()
      |> Enum.filter(&(&1.kind == "macos_app"))

    assert %{dev_server_port: 8091, launch_env: %{"HUB_OWNER_TOKEN" => "abc"}} = macos_app

    [macos_app] = %{playbooks: macos_app(%{"launch_env" => nil})} |> Selection.playbooks() |> Enum.filter(&(&1.kind == "macos_app"))
    assert %{dev_server_port: 8090, launch_env: %{}} = macos_app
  end
end
