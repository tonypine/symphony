defmodule SymphonyElixir.PlaybookSettingsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.{RepoWorkflowSchema, SystemSchema}
  alias SymphonyElixir.{PlaybookSettings, QaAgent.Selection}

  @base %{
    "issues" => %{"provider" => "memory"},
    "repositories" => [%{"key" => "web"}],
    "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
    "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}}
  }

  defp macos_app(settings), do: %{"macos_app" => Map.merge(%{"build" => "make app", "app" => "build/App.app"}, settings)}

  describe "validate/1" do
    test "accepts the dev server port and a launch_env of strings" do
      assert PlaybookSettings.validate(macos_app(%{"dev_server_port" => 8090, "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}})) == :ok
      unset = %{macos_app: %{dev_server_port: nil, launch_env: nil}, cli: nil, web: "on"}
      assert PlaybookSettings.validate(unset) == :ok
      assert PlaybookSettings.validate(nil) == :ok
    end

    test "names the key that is wrong" do
      for {settings, message} <- [
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

      good = macos_app(%{"dev_server_port" => 8091, "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}})
      assert {:ok, _config} = SystemSchema.parse(Map.put(@base, "auto_review", %{"playbooks" => good}))
      assert {:ok, _workflow} = RepoWorkflowSchema.parse(%{"auto_review" => %{"playbooks" => good}})
    end
  end

  describe "the QA target" do
    test "defaults to dark at 2560×1440" do
      assert PlaybookSettings.default_window_size() == {2560, 1440}
      assert PlaybookSettings.default_appearance() == "dark"
      assert PlaybookSettings.window_size(%{}) == {2560, 1440}
      assert PlaybookSettings.appearance(%{}) == "dark"
      assert PlaybookSettings.appearance(%{"appearance" => nil}) == "dark"
      assert {PlaybookSettings.min_window_size(), PlaybookSettings.max_window_size()} == {320, 8192}
      assert PlaybookSettings.appearances() == ["light", "dark"]
    end

    test "takes a playbook's own values, with atom or string keys, and the default for one out of range" do
      assert PlaybookSettings.window_size(%{"window_width" => 1440, "window_height" => 900}) == {1440, 900}
      assert PlaybookSettings.window_size(%{window_width: 1366, window_height: 768}) == {1366, 768}
      assert PlaybookSettings.window_size(%{"window_width" => 100, "window_height" => "900"}) == {2560, 1440}
      assert PlaybookSettings.appearance(%{appearance: "light"}) == "light"
      assert PlaybookSettings.appearance(%{"appearance" => "sepia"}) == "dark"
    end

    test "accepts whole points in range and light or dark, and names the key that is wrong" do
      assert PlaybookSettings.validate(macos_app(%{"window_width" => 1440, "window_height" => 900, "appearance" => "light"})) == :ok
      assert PlaybookSettings.validate(macos_app(%{"window_width" => nil, "appearance" => nil})) == :ok

      for {settings, message} <- [
            {%{"window_width" => 319}, "auto_review.playbooks.macos_app.window_width must be a whole number of points from 320 to 8192"},
            {%{"window_height" => "768"}, "auto_review.playbooks.macos_app.window_height must be a whole number of points from 320 to 8192"},
            {%{"window_width" => 9000}, "auto_review.playbooks.macos_app.window_width must be a whole number of points from 320 to 8192"},
            {%{"appearance" => "Dark"}, "auto_review.playbooks.macos_app.appearance must be light or dark"}
          ] do
        assert PlaybookSettings.validate(macos_app(settings)) == {:error, message}
      end
    end

    test "the macos_app playbook carries it" do
      [macos_app] =
        %{playbooks: macos_app(%{"window_width" => 1440, "window_height" => 900, "appearance" => "light"})}
        |> Selection.playbooks()
        |> Enum.filter(&(&1.kind == "macos_app"))

      assert %{window_size: {1440, 900}, appearance: "light"} = macos_app
      refute Map.has_key?(macos_app, :wide_pass_size)
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

  describe "the server's two old descriptions (TP-1663)" do
    test "are refused, on any playbook, naming verification.dev_server, where the server is described once" do
      for {kind, key, value} <- [{"macos_app", "dev_server", true}, {"macos_app", "dev_server", false}, {"macos_app", "live", %{"start_cmd" => "start"}}, {"cli", "live", nil}] do
        playbooks = %{kind => Map.put(%{"build" => "make app", "app" => "build/App.app"}, key, value)}

        assert PlaybookSettings.validate(playbooks) ==
                 {:error, "auto_review.playbooks.#{kind}.#{key} is gone: the project's server is described once, in verification.dev_server, and its runs rule says when it runs"}
      end
    end

    test "a repository's WORKFLOW.md that still has them loads, described once" do
      playbooks = macos_app(%{"dev_server" => true, "launch_env" => %{"HUB_OWNER_TOKEN" => "abc"}})
      assert {:ok, workflow} = RepoWorkflowSchema.parse(%{"auto_review" => %{"playbooks" => playbooks}})
      assert workflow.verification.dev_server.runs == "every_qa_pass"
      refute Map.has_key?(workflow.auto_review["playbooks"]["macos_app"], "dev_server")
    end

    test "refuses the control URL and token in launch_env: a live server sets them" do
      for name <- ~w(SYMPHONY_BAR_CONTROL_URL SYMPHONY_BAR_CONTROL_TOKEN), do: assert(PlaybookSettings.refused_env?(name))
    end
  end
end
