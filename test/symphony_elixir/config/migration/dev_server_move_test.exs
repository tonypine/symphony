defmodule SymphonyElixir.Config.Migration.DevServerMoveTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BuildInfo
  alias SymphonyElixir.Config.{Migration, RepoWorkflowSchema, Schema, SystemSchema}
  alias SymphonyElixir.Config.Migration.DevServerMove
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.{Verification, Workflow}

  @backup "symphony.yml.before-v1"
  @fixtures Path.expand("../../../fixtures/previous_release", __DIR__)
  @repo_root Path.expand("../../../..", __DIR__)
  @live_url "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"

  # A repository's WORKFLOW.md as the new code loads it, turned into the settings a run reads.
  defp workflow_settings!(path) do
    assert {:ok, {front_matter, _body}} = path |> File.read!() |> Workflow.parse_document()
    assert {:ok, workflow} = RepoWorkflowSchema.parse(front_matter)
    config = RepoWorkflowSchema.to_config_map(workflow)
    assert {:ok, settings} = Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}}, config))
    settings
  end

  # The build command and the app bundle sit in the operator's symphony.yml, so they are added here.
  defp macos_app(settings) do
    playbooks = Map.update(settings.auto_review.playbooks, "macos_app", %{}, &Map.merge(%{"build" => "make app", "app" => "build/App.app"}, &1))

    %{settings.auto_review | playbooks: playbooks}
    |> Selection.playbooks(Verification.selection_opts(settings))
    |> Enum.find(&(&1.kind == "macos_app"))
  end

  describe "migrate/1" do
    test "a macos_app playbook with dev_server: true runs the server on every QA pass, keeping its port" do
      document = %{
        "verification" => %{"dev_server" => %{"start_cmd" => "start", "health_check_url" => "http://x"}},
        "auto_review" => %{"playbooks" => %{"macos_app" => %{"app" => "A.app", "dev_server" => true, "dev_server_port" => 8091}, "cli" => nil}}
      }

      assert DevServerMove.migrate(document) == %{
               "verification" => %{"dev_server" => %{"start_cmd" => "start", "health_check_url" => "http://x", "runs" => "every_qa_pass"}},
               "auto_review" => %{"playbooks" => %{"macos_app" => %{"app" => "A.app", "dev_server_port" => 8091}, "cli" => nil}}
             }
    end

    test "a live block becomes the server, with the defaults it had, run on live passes; a recipe beside it goes" do
      document = %{
        "verification" => %{"dev_server" => %{"build_cmd" => "dash-build", "start_cmd" => "dash-start", "health_timeout_ms" => 5, "stop_signal" => "INT"}},
        "auto_review" => %{"playbooks" => %{"macos_app" => %{"live" => %{start_cmd: "live-start", paths: ["lib/**"], walkthrough_mentions: ["Director"]}}}}
      }

      assert DevServerMove.migrate(document) == %{
               "verification" => %{
                 "dev_server" => %{
                   "start_cmd" => "live-start",
                   "health_check_url" => @live_url,
                   "health_timeout_ms" => 600_000,
                   "stop_signal" => "INT",
                   "runs" => "live_qa_pass"
                 }
               },
               "auto_review" => %{"playbooks" => %{"macos_app" => %{}}}
             }
    end

    test "drops the keys from every playbook, and leaves a file without them as it is" do
      document = %{"auto_review" => %{"playbooks" => %{"macos_app" => %{"dev_server" => false, "live" => "on"}, "server" => %{"dev_server" => true}}}}
      assert DevServerMove.migrate(document) == %{"auto_review" => %{"playbooks" => %{"macos_app" => %{}, "server" => %{}}}}

      for unchanged <- [%{}, %{"auto_review" => "x"}, %{"auto_review" => %{"playbooks" => %{"macos_app" => %{"app" => "A.app"}}}}] do
        refute DevServerMove.needed?(unchanged)
        assert DevServerMove.migrate(unchanged) == unchanged
      end
    end
  end

  describe "a symphony.yml rewritten in place" do
    test "takes the live recipe, names the one it drops, keeps comments, and has nothing left to move" do
      text = """
      # The project's server.
      verification:
        dev_server:
          build_cmd: scripts/qa-dashboard-build.sh
          start_cmd: scripts/qa-dashboard-server.sh
          health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
          health_timeout_ms: 600000
      auto_review:
        playbooks:
          macos_app:
            requires: [mise]
            live:
              build_cmd: scripts/qa-server-build.sh
              start_cmd: scripts/qa-server-start.sh
              paths: ["lib/**"]
              walkthrough_mentions: [Director, Inbox]
      """

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)
      version = BuildInfo.current().version

      assert note ==
               "v#{version} described the project's server once, in `verification.dev_server`, which now runs on `runs: live_qa_pass`; " <>
                 "the commands it held before (`scripts/qa-dashboard-server.sh`) are dropped"

      assert migrated =~ "# The project's server.\n"
      assert migrated =~ "      # Symphony: #{note} (TP-1663). The file as it was: #{@backup}.\n"
      refute migrated =~ "walkthrough_mentions"

      assert {:ok, document} = YamlElixir.read_from_string(migrated)

      assert document["verification"]["dev_server"] == %{
               "build_cmd" => "scripts/qa-server-build.sh",
               "start_cmd" => "scripts/qa-server-start.sh",
               "health_check_url" => @live_url,
               "health_timeout_ms" => 600_000,
               "runs" => "live_qa_pass"
             }

      assert document["auto_review"]["playbooks"]["macos_app"] == %{"requires" => ["mise"]}
      assert Migration.plan(migrated, @backup) == {:ok, migrated, []}
    end

    test "writes the rule for dev_server: true, drops an old command the live recipe lacks, and leaves an emptied playbook as {}" do
      text = """
      verification:
        dev_server:
          start_cmd: bin/hub
      auto_review:
        playbooks:
          macos_app:
            dev_server: true
            dev_server_port: 8090
      """

      assert {:ok, migrated, [_note]} = Migration.plan(text, @backup)
      assert {:ok, %{"verification" => %{"dev_server" => %{"start_cmd" => "bin/hub", "runs" => "every_qa_pass"}}} = document} = YamlElixir.read_from_string(migrated)
      assert document["auto_review"]["playbooks"]["macos_app"] == %{"dev_server_port" => 8090}

      live_only = """
      verification:
        dev_server:
          build_cmd: old-build
          start_cmd: old-start
      auto_review:
        playbooks:
          macos_app:
            live:
              start_cmd: live-start
      """

      assert {:ok, migrated, [_note]} = Migration.plan(live_only, @backup)
      assert migrated =~ "macos_app: {}"
      assert {:ok, document} = YamlElixir.read_from_string(migrated)
      assert document["verification"]["dev_server"] == %{"start_cmd" => "live-start", "health_check_url" => @live_url, "health_timeout_ms" => 600_000, "runs" => "live_qa_pass"}
      assert document["auto_review"]["playbooks"]["macos_app"] == %{}
    end

    test "writes verification.dev_server when the file has none, and a removed false flag says so" do
      text = """
      auto_review:
        playbooks:
          macos_app:
            app: A.app
            dev_server: false
      """

      assert {:ok, migrated, [note]} = Migration.plan(text, @backup)
      assert note =~ "removed the macos_app playbook's `dev_server` and `live` keys"
      assert {:ok, %{"auto_review" => %{"playbooks" => %{"macos_app" => %{"app" => "A.app"}}}} = document} = YamlElixir.read_from_string(migrated)
      refute Map.has_key?(document, "verification")

      flag = "auto_review:\n  playbooks:\n    macos_app:\n      dev_server: true\n"
      assert {:ok, migrated, [_note]} = Migration.plan(flag, @backup)
      assert {:ok, %{"verification" => %{"dev_server" => %{"runs" => "every_qa_pass"}}}} = YamlElixir.read_from_string(migrated)
    end

    test "names a key it can't rewrite, written inside {...}" do
      text = "auto_review:\n  playbooks:\n    macos_app: {app: A.app, dev_server: true}\n"
      assert {:error, {:not_migrated, [{"auto_review.playbooks.macos_app.dev_server", 3}]}} = Migration.plan(text, @backup)

      inline = "verification: {enabled: false}\nauto_review:\n  playbooks:\n    macos_app:\n      dev_server: true\n"
      assert {:error, {:not_migrated, [{"auto_review.playbooks.macos_app.dev_server", 5}]}} = Migration.plan(inline, @backup)
    end

    test "an earlier migration's error stands" do
      text = "ledger: {artifact_retention_days: 3}\nauto_review:\n  playbooks:\n    macos_app:\n      dev_server: true\n"
      assert Migration.plan(text, @backup) == {:error, {:not_migrated, [{"ledger.artifact_retention_days", 1}]}}
    end
  end

  describe "a previous release's files load with the new code, with no edit by a person" do
    test "Symphony's WORKFLOW.md runs its live recipe on live passes, as before" do
      settings = workflow_settings!(Path.join(@fixtures, "symphony_workflow.md"))
      dev_server = settings.verification.dev_server

      assert {dev_server.build_cmd, dev_server.start_cmd} == {"scripts/qa-server-build.sh", "scripts/qa-server-start.sh"}
      assert {dev_server.health_check_url, dev_server.health_timeout_ms, dev_server.runs} == {@live_url, 600_000, "live_qa_pass"}
      assert %{live_server: true, dev_server_port: 8090, requires: ["mise"]} = macos_app = macos_app(settings)
      refute Map.has_key?(macos_app, :dev_server)
      refute Verification.dev_server_configured?(%{settings | verification: %{settings.verification | enabled: true}})
    end

    test "Job Search Hub's WORKFLOW.md runs its server beside every Mac app pass, on the same port" do
      settings = workflow_settings!(Path.join(@fixtures, "job_search_hub_workflow.md"))
      dev_server = settings.verification.dev_server

      assert {dev_server.build_cmd, dev_server.start_cmd} == {"server/scripts/dev-server.sh build", "server/scripts/dev-server.sh start"}
      assert {dev_server.health_check_url, dev_server.health_timeout_ms, dev_server.runs} == {"http://127.0.0.1:8090/v1/health", 180_000, "every_qa_pass"}
      assert %{dev_server: true, dev_server_port: 8090, requires: ["go", "pg_ctl", "initdb", "jq"]} = macos_app = macos_app(settings)
      refute Map.has_key?(macos_app, :live_server)
      refute settings.verification.enabled
    end

    test "Symphony's symphony.yml migrates and loads" do
      text = File.read!(Path.join(@fixtures, "symphony_config.yml"))
      assert {:ok, migrated, _notes} = Migration.plan(text, @backup)
      assert {:ok, %{} = document} = YamlElixir.read_from_string(migrated)
      assert {:ok, _config} = SystemSchema.parse(document)
    end
  end

  describe "Symphony's own files" do
    test "describe the server once, in the new shape, with nothing left for the migration to change" do
      assert {:ok, {front_matter, _body}} = @repo_root |> Path.join("WORKFLOW.md") |> File.read!() |> Workflow.parse_document()
      refute DevServerMove.needed?(front_matter)
      assert front_matter["verification"]["dev_server"]["runs"] == "live_qa_pass"
      assert front_matter["verification"]["dev_server"]["start_cmd"] == "scripts/qa-server-start.sh"

      text = @repo_root |> Path.join("symphony.yml") |> File.read!()
      assert Migration.plan(text, @backup) == {:ok, text, []}
      refute text =~ "walkthrough_mentions"
      refute text =~ ~r/^#\s+dev_server: true/m
    end
  end
end
