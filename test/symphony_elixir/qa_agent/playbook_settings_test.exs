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

  describe "live" do
    @live %{"start_cmd" => "scripts/qa-server-start.sh"}

    test "accepts a live server with only its start command, or with every setting" do
      assert PlaybookSettings.validate(macos_app(%{"live" => @live})) == :ok
      assert PlaybookSettings.validate(macos_app(%{"live" => nil})) == :ok

      full = %{
        start_cmd: "scripts/qa-server-start.sh",
        build_cmd: "scripts/qa-server-build.sh",
        health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/healthz",
        health_timeout_ms: 300_000,
        paths: ["lib/**", "config/**"],
        walkthrough_mentions: ["Director"]
      }

      assert PlaybookSettings.validate(macos_app(%{"live" => full})) == :ok
    end

    test "names the live setting that is wrong" do
      path = "auto_review.playbooks.macos_app.live"

      for {settings, message} <- [
            {%{"live" => "on"}, "#{path} must be a map with at least start_cmd"},
            {%{"live" => @live, "dev_server" => true}, "#{path} and auto_review.playbooks.macos_app.dev_server: true both run a server on its one port; keep one"},
            {%{"live" => %{"start" => "x"}}, "#{path}.start is not a live setting"},
            {%{"live" => %{}}, "#{path}.start_cmd must name the command that starts the server"},
            {%{"live" => %{"start_cmd" => " "}}, "#{path}.start_cmd must name the command that starts the server"},
            {%{"live" => Map.put(@live, "build_cmd", 1)}, "#{path}.build_cmd must be a command"},
            {%{"live" => Map.put(@live, "health_check_url", "")}, "#{path}.health_check_url must be a URL"},
            {%{"live" => Map.put(@live, "health_timeout_ms", 0)}, "#{path}.health_timeout_ms must be a positive number of milliseconds"},
            {%{"live" => Map.put(@live, "paths", "lib/**")}, "#{path}.paths must be a list of path globs"},
            {%{"live" => Map.put(@live, "walkthrough_mentions", [""])}, "#{path}.walkthrough_mentions must be a list of words"}
          ] do
        assert {:error, error} = PlaybookSettings.validate(macos_app(settings))
        assert String.starts_with?(error, message)
      end

      assert PlaybookSettings.validate(%{"cli" => %{"live" => @live}}) == {:error, "auto_review.playbooks.cli.live is only read on the macos_app playbook"}
    end

    test "refuses the control URL and token in launch_env: a live server sets them" do
      for name <- ~w(SYMPHONY_BAR_CONTROL_URL SYMPHONY_BAR_CONTROL_TOKEN), do: assert(PlaybookSettings.refused_env?(name))
    end

    test "the macos_app playbook carries its live server with the defaults filled in" do
      [macos_app] = %{playbooks: macos_app(%{"live" => @live})} |> Selection.playbooks() |> Enum.filter(&(&1.kind == "macos_app"))

      assert macos_app.live_server == %{
               build_cmd: nil,
               start_cmd: "scripts/qa-server-start.sh",
               health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state",
               health_timeout_ms: 600_000,
               paths: [],
               walkthrough_mentions: []
             }

      live = %{start_cmd: "start", paths: ["lib/**"], walkthrough_mentions: ["Director"], health_timeout_ms: 1000}

      assert %{paths: ["lib/**"], walkthrough_mentions: ["Director"], health_timeout_ms: 1000} =
               PlaybookSettings.live_server(%{"live" => live})

      for playbook <- [%{}, %{"live" => nil}, %{"live" => %{}}, %{"live" => @live, "dev_server" => true}] do
        assert PlaybookSettings.live_server(playbook) == nil
      end

      [macos_app] = %{playbooks: macos_app(%{})} |> Selection.playbooks() |> Enum.filter(&(&1.kind == "macos_app"))
      refute Map.has_key?(macos_app, :live_server)
    end
  end
end
