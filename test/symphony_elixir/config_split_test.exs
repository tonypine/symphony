defmodule SymphonyElixir.ConfigSplitTest do
  use ExUnit.Case

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Config.{RepoWorkflowSchema, Schema}
  alias SymphonyElixir.Config.Schema.Hooks
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.QaAgent.Selection
  alias SymphonyElixir.Repo.Supervisor, as: RepoSupervisor

  setup do
    original_symphony_path = SymphonyElixir.Workflow.symphony_file_path()
    original_workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    original_primary_repo = Application.get_env(:symphony_elixir, :primary_repo_name)
    original_cache_reader = Application.get_env(:symphony_elixir, :config_cache_file_reader)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-config-split-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    ensure_repo_registry_started!()
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      SymphonyElixir.Workflow.set_symphony_file_path(original_symphony_path)
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)
      restore_app_env(:primary_repo_name, original_primary_repo)
      restore_app_env(:config_cache_file_reader, original_cache_reader)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "settings caches symphony.yml reads after warmup", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony!(root, [repo])
    symphony_path = Path.join(root, "symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(symphony_path)

    counter = :counters.new(1, [])

    Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
      if Path.expand(path) == Path.expand(symphony_path) do
        :counters.add(counter, 1, 1)
      end

      File.read(path)
    end)

    assert {:ok, first} = Config.settings()

    for _ <- 1..5 do
      assert {:ok, ^first} = Config.settings()
    end

    assert :counters.get(counter, 1) == 1
  end

  test "settings reloads when symphony.yml changes", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 11_111))
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert Config.settings!().polling.interval_ms == 11_111

    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 222_222))

    assert Config.settings!().polling.interval_ms == 222_222
  end

  test "symphony_file_path override isolates cached settings", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    first_path = Path.join(root, "first-symphony.yml")
    second_path = Path.join(root, "second-symphony.yml")

    File.write!(first_path, symphony_text([repo], poll_interval_ms: 12_345))
    File.write!(second_path, symphony_text([repo], poll_interval_ms: 54_321))

    SymphonyElixir.Workflow.set_symphony_file_path(first_path)
    assert Config.settings!().polling.interval_ms == 12_345

    SymphonyElixir.Workflow.set_symphony_file_path(second_path)
    assert Config.settings!().polling.interval_ms == 54_321
  end

  test "settings serves last good symphony config after parse error", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 33_333))
    symphony_path = Path.join(root, "symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(symphony_path)

    assert Config.settings!().polling.interval_ms == 33_333

    File.write!(symphony_path, "tracker: [unterminated\n")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Config.settings!().polling.interval_ms == 33_333
      end)

    assert log =~ "keeping last known good value"
  end

  test "missing symphony.yml keeps existing error shape", %{root: root} do
    missing_path = Path.join(root, "missing-symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(missing_path)

    assert {:error, {:missing_symphony_file, ^missing_path, :enoent}} = Config.system()
  end

  test "repo workflow files are cached and reloaded by absolute path", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")

    api_repo =
      write_repo!(root, "api", """
      ---
      hooks:
        before_run: echo api
      ---
      API prompt
      """)

    write_symphony_text!(root, symphony_text([web_repo, api_repo], poll_interval_ms: 30_000))
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    api_workflow_path = Path.join(api_repo.path, "WORKFLOW.md")
    counter = :counters.new(1, [])

    Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
      if Path.expand(path) == Path.expand(api_workflow_path) do
        :counters.add(counter, 1, 1)
      end

      File.read(path)
    end)

    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert :counters.get(counter, 1) == 1

    File.write!(api_workflow_path, """
    ---
    hooks:
      before_run: echo api changed
    ---
    API prompt changed
    """)

    assert Config.settings_for_repo!("api").hooks.before_run == "echo api changed"
  end

  test "symphony.yml is required before application children can be built", %{root: root} do
    missing_path = Path.join(root, "missing-symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(missing_path)

    assert_raise ArgumentError, ~r/Missing symphony.yml/, fn ->
      SymphonyElixir.Application.child_specs_for_runtime(%{"SYMPHONY_DISABLE_ORCHESTRATOR" => "1"})
    end
  end

  test "application runtime validation reports missing modules and functions compactly" do
    assert :ok =
             SymphonyElixir.Application.validate_runtime_modules!([
               {SymphonyElixir.ProjectGuidePrompt, :append_to_prompt, 4},
               {SymphonyElixir.ProjectGuides, :append_to_prompt, 4}
             ])

    assert_raise ArgumentError, ~r/runtime module unavailable: SymphonyElixir.MissingRuntimeModule/, fn ->
      SymphonyElixir.Application.validate_runtime_modules!([
        {SymphonyElixir.MissingRuntimeModule, :run, 1}
      ])
    end

    assert_raise ArgumentError, ~r/runtime function unavailable: SymphonyElixir.ProjectGuides.missing\/4/, fn ->
      SymphonyElixir.Application.validate_runtime_modules!([
        {SymphonyElixir.ProjectGuides, :missing, 4}
      ])
    end
  end

  test "repo WORKFLOW.md rejects operator-level config and points at symphony.yml", %{root: root} do
    repo =
      write_repo!(root, "app", """
      ---
      agent:
        kind: codex
        command: codex app-server
      ---
      Repo prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert_raise ArgumentError, ~r/operator-level key `agent`.*symphony.yml/, fn ->
      Config.settings!()
    end
  end

  test "system schema accepts operator config and repo workflow accepts only repo-local keys", %{root: root} do
    repo =
      write_repo!(root, "app", """
      ---
      hooks:
        after_create: echo setup
      verification:
        enabled: true
      validation:
        - mix test
      ---
      Repo prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, %SystemSchema{repos: [loaded_repo]}} = Config.system()
    assert loaded_repo.name == "app"
    assert SystemSchema.repo_workflow_path(loaded_repo) == Path.join(repo.path, "WORKFLOW.md")

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.kind == "memory"
    assert settings.hooks.after_create == "echo setup"
    assert settings.verification.enabled == true
    assert settings.push_check == %Schema.PushCheck{}
  end

  test "repo workflow configures the push check", %{root: root} do
    repo =
      write_repo!(root, "app", """
      ---
      push_check:
        command: .githooks/pre-push --head
        paths: ["*.ex", "mix.lock"]
      ---
      Repo prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, settings} = Config.settings()

    assert settings.push_check == %Schema.PushCheck{
             command: ".githooks/pre-push --head",
             result_file: "tmp/push-check",
             paths: ["*.ex", "mix.lock"]
           }
  end

  test "repo workflow rejects a push check result file outside the workspace and blank paths" do
    for result_file <- ["/tmp/push-check", "../push-check", "tmp/../../push-check"] do
      assert {:error, {:invalid_repo_workflow_config, message}} =
               RepoWorkflowSchema.parse(%{"push_check" => %{"command" => "check", "result_file" => result_file}})

      assert message =~ "push_check.result_file must be a path inside the workspace"
    end

    assert {:error, {:invalid_repo_workflow_config, message}} =
             RepoWorkflowSchema.parse(%{"push_check" => %{"command" => "check", "result_file" => ""}})

    assert message =~ "push_check.result_file can't be blank"

    assert {:error, {:invalid_repo_workflow_config, message}} =
             RepoWorkflowSchema.parse(%{"push_check" => %{"command" => "check", "paths" => ["*.ex", " "]}})

    assert message =~ "push_check.paths must contain only non-empty strings"
  end

  test "repo workflow auto_review.playbooks merge per kind over operator playbooks for that repo only", %{root: root} do
    mac_repo =
      write_repo!(root, "mac", """
      ---
      auto_review:
        playbooks:
          macos_app:
            paths: ["app/**"]
          api:
            paths: ["api/**"]
            prompt: "### Playbook: api"
      ---
      Mac prompt
      """)

    other_repo = write_repo!(root, "other", "Other prompt\n")

    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    auto_review:
      enabled: true
      playbooks:
        macos_app:
          build: make app
          app: build/App.app
        cli:
          paths: ["bin/**"]
    repositories:
      - key: mac
        workflow: #{Path.join(mac_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: other
        workflow: #{Path.join(other_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels:
            - other
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    mac_settings = Config.settings_for_repo!("mac")
    other_settings = Config.settings_for_repo!("other")

    assert mac_settings.auto_review.enabled
    assert mac_settings.auto_review.playbooks["macos_app"] == %{"build" => "make app", "app" => "build/App.app", "paths" => ["app/**"]}
    assert mac_settings.auto_review.playbooks["cli"] == %{"paths" => ["bin/**"]}
    assert other_settings.auto_review.playbooks == %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}, "cli" => %{"paths" => ["bin/**"]}}

    mac_playbooks = Map.new(Selection.playbooks(mac_settings.auto_review), &{&1.kind, &1})
    other_playbooks = Map.new(Selection.playbooks(other_settings.auto_review), &{&1.kind, &1})

    assert %{paths: ["app/**"], build: "make app", app: "build/App.app"} = mac_playbooks["macos_app"]
    assert %{paths: ["api/**"], prompt: "### Playbook: api"} = mac_playbooks["api"]
    assert other_playbooks["macos_app"].paths != ["app/**"]
    refute Map.has_key?(other_playbooks, "api")

    issue = %Issue{id: "issue-1", identifier: "TP-1", title: "Change", labels: []}
    assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue, ["app/Main.kt"], mac_settings.auto_review)
    assert {:skip, _reason} = Selection.decide(issue, ["app/Main.kt"], other_settings.auto_review)
  end

  test "repo workflow auto_review accepts only playbooks maps", %{root: root} do
    for {front_matter, expected} <- [
          {"auto_review:\n  enabled: true", ~r/operator-level key `auto_review.enabled`.*only `auto_review.playbooks`.*symphony.yml/},
          {"auto_review: true", ~r/auto_review must be a map/},
          {"auto_review:\n  playbooks: [macos_app]", ~r/auto_review.playbooks must be a map of playbook kinds/},
          {"auto_review:\n  playbooks:\n    macos_app: on", ~r/auto_review.playbooks.macos_app must be a map/}
        ] do
      repo = write_repo!(root, "app", "---\n#{front_matter}\n---\nRepo prompt\n")
      write_symphony!(root, [repo])
      SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))
      Cache.clear()

      assert_raise ArgumentError, expected, fn -> Config.settings!() end
    end

    for front_matter <- ["auto_review:", "auto_review:\n  playbooks:", "auto_review:\n  playbooks:\n    macos_app:"] do
      repo = write_repo!(root, "app", "---\n#{front_matter}\n---\nRepo prompt\n")
      write_symphony!(root, [repo])
      Cache.clear()

      assert Config.settings!().auto_review.playbooks == %{}
    end
  end

  test "system schema accepts operator-level verification defaults" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "verification" => %{
                   "enabled" => true,
                   "port_allocation" => %{"range" => [4400, 4402]}
                 }
               })
             )

    config_map = SystemSchema.to_config_map(system_config)
    assert get_in(config_map, ["verification", "enabled"]) == true
    assert get_in(config_map, ["verification", "port_allocation", "range"]) == [4400, 4402]
  end

  test "startup config accepts single repo without repo-level routing selectors", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")

    write_symphony_text!(root, """
    issues:
      provider: linear
      linear:
        api_key: token
        scope:
          project_slug: project
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: app
        workflow: #{Path.join(repo.path, "WORKFLOW.md")}
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, system_config} = Config.system()
    assert [%SystemSchema.Repo{name: "app", team: nil}] = system_config.repos
  end

  test "startup config rejects identical routing match rules", %{root: root} do
    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: web
        workflow: #{Path.join(root, "web/WORKFLOW.md")}
        route:
          team: ACME
          labels: [backend]
      - key: api
        workflow: #{Path.join(root, "api/WORKFLOW.md")}
        route:
          team: ACME
          labels: [backend]
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_symphony_config, message}} = Config.system()
    assert message =~ "repositories routing rules are invalid"
    assert message =~ "identical match rules"
    assert message =~ "web"
    assert message =~ "api"
  end

  test "startup config rejects ambiguous non-default catch-all routing", %{root: root} do
    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: fallback
        workflow: #{Path.join(root, "fallback/WORKFLOW.md")}
        route:
          team: ACME
      - key: api
        workflow: #{Path.join(root, "api/WORKFLOW.md")}
        route:
          team: ACME
          labels: [api]
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_symphony_config, message}} = Config.system()
    assert message =~ "repositories routing rules are invalid"
    assert message =~ "ambiguous team-only catch-all"
    assert message =~ "fallback"
  end

  test "system schema uses explicit default repo as primary" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "repositories" => [
                   repo_config("secondary"),
                   repo_config("primary", %{"default" => true})
                 ]
               })
             )

    assert SystemSchema.primary_repo(system_config).name == "primary"
  end

  test "system schema rejects duplicate repo names and multiple defaults" do
    assert {:error, {:invalid_symphony_config, duplicate_message}} =
             SystemSchema.parse(
               system_config(%{
                 "repositories" => [
                   repo_config("app"),
                   repo_config("app")
                 ]
               })
             )

    assert duplicate_message =~ "repositories keys must be unique"

    assert {:error, {:invalid_symphony_config, normalized_duplicate_message}} =
             SystemSchema.parse(
               system_config(%{
                 "repositories" => [
                   repo_config("api/main"),
                   repo_config("api_main")
                 ]
               })
             )

    assert normalized_duplicate_message =~ "repositories keys must not collide after workspace normalization"

    assert {:error, {:invalid_symphony_config, default_message}} =
             SystemSchema.parse(
               system_config(%{
                 "repositories" => [
                   repo_config("first", %{"default" => true}),
                   repo_config("second", %{"default" => true})
                 ]
               })
             )

    assert default_message =~ "repositories can include at most one default repo"
  end

  test "system schema reads issues.memory.issues_file relative to symphony.yml and rejects other keys" do
    assert {:ok, %{tracker: %{memory_issues_file: "/abs/issues.json"}}} =
             SystemSchema.parse(system_config(%{"issues" => %{"provider" => "memory", "memory" => %{"issues_file" => "/abs/issues.json"}}}))

    assert {:ok, %{tracker: %{memory_issues_file: relative}}} =
             SystemSchema.parse(system_config(%{"issues" => %{"provider" => "memory", "memory" => %{"issues_file" => "issues.json"}}}))

    assert relative == Path.join(Path.dirname(SymphonyElixir.Workflow.symphony_file_path()), "issues.json")

    assert {:error, {:invalid_symphony_config, message}} =
             SystemSchema.parse(system_config(%{"issues" => %{"provider" => "memory", "memory" => %{"issues_path" => "x"}}}))

    assert message =~ "issues.memory"

    assert {:error, {:invalid_symphony_config, "`issues.memory` must be an object"}} =
             SystemSchema.parse(system_config(%{"issues" => %{"provider" => "memory", "memory" => "issues.json"}}))
  end

  test "system schema rejects unknown top-level keys and empty repos" do
    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `unknown`"}} =
             SystemSchema.parse(system_config(%{"unknown" => true}))

    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `routing`"}} =
             SystemSchema.parse(system_config(%{"routing" => []}))

    assert {:error, {:invalid_symphony_config, empty_repos_message}} =
             SystemSchema.parse(system_config(%{"repositories" => []}))

    assert empty_repos_message =~ "repositories"
    assert empty_repos_message =~ "can't be blank"
  end

  test "system schema validation errors use operator config paths" do
    assert {:error, {:invalid_symphony_config, message}} =
             SystemSchema.parse(
               system_config(%{
                 "issues" => %{
                   "provider" => "memory",
                   "poll_interval_ms" => 0
                 },
                 "agent" => %{
                   "runtime" => "future-runtime",
                   "command" => "codex app-server",
                   "concurrency" => %{"max_total" => 0}
                 },
                 "pull_requests" => %{
                   "enabled" => true,
                   "checks" => %{"enabled" => true, "max_fix_attempts" => 0}
                 },
                 "repositories" => [
                   %{
                     "workflow" => "",
                     "route" => %{"team" => "Test"}
                   }
                 ]
               })
             )

    assert message =~ "issues.poll_interval_ms"
    assert message =~ "agent.runtime"
    assert message =~ "agent.concurrency.max_total"
    assert message =~ "pull_requests.checks.max_fix_attempts"
    assert message =~ "repositories.key"
    assert message =~ "repositories.workflow"

    refute message =~ "tracker"
    refute message =~ "polling"
    refute message =~ ~r/\brepos\b/
    refute message =~ "pr_review"
    refute message =~ "ci."
    refute message =~ "max_concurrent_agents"
  end

  test "system schema maps nested operator config and resolves repo workflow paths" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "agent" => %{
                   "runtime" => "codex",
                   "command" => "codex app-server",
                   "concurrency" => %{"max_total" => 3},
                   "limits" => %{"tokens_per_issue" => 100, "tokens_per_day" => 200}
                 },
                 "repositories" => [repo_config("app", %{"workflow" => "relative/app/config/Workflow.md"})]
               })
             )

    assert %SystemSchema{repos: [repo]} = system_config
    assert is_nil(repo.path)
    assert SystemSchema.repo_workflow_path(repo) == Path.expand("relative/app/config/Workflow.md", SymphonyElixir.Workflow.symphony_file_path() |> Path.dirname())

    config_map = SystemSchema.to_config_map(system_config)
    assert get_in(config_map, ["agent", "max_concurrent_agents"]) == 3
    assert get_in(config_map, ["agent", "max_tokens_per_issue"]) == 100
    assert get_in(config_map, ["agent", "max_tokens_per_day"]) == 200
  end

  test "repo workflow path can be declared without a repo checkout path", %{root: root} do
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "repositories" => [
                   %{
                     "key" => "app",
                     "workflow" => "workflows/app.md",
                     "route" => %{"team" => "Test"}
                   }
                 ]
               })
             )

    assert %SystemSchema{repos: [repo]} = system_config
    assert is_nil(repo.path)
    assert SystemSchema.repo_workflow_path(repo) == Path.join(root, "workflows/app.md")
  end

  test "repo workspace overrides global workspace population settings", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")
    workspace_root = Path.join(root, "workspaces")
    primary_clone = Path.join(root, "primary")

    write_symphony_text!(root, """
    issues:
      provider: memory
    workspaces:
      root: #{workspace_root}
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: app
        workflow: #{SystemSchema.repo_workflow_path(repo)}
        route:
          team: Test
        workspace:
          strategy: worktree
          repo: #{primary_clone}
          fetch_before_dispatch: false
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    settings = Config.settings_for_repo!("app")
    assert settings.workspace.root == workspace_root
    assert settings.workspace.strategy == "worktree"
    assert settings.workspace.repo == primary_clone
    refute settings.workspace.fetch_before_dispatch
  end

  test "multi-repo config rejects global worktree strategy without repo overrides", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")
    api_repo = write_repo!(root, "api", "API prompt\n")

    write_symphony_text!(root, """
    issues:
      provider: memory
    workspaces:
      strategy: worktree
      repo: #{Path.join(root, "primary")}
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: web
        workflow: #{Path.join(web_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels: ["api"]
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workspaces.strategy is global"
    assert message =~ "repositories[].workspace"
    assert message =~ "web"
    assert message =~ "api"
  end

  test "repo supervisors isolate invalid repo workflow failures", %{root: root} do
    valid_repo = write_repo!(root, "valid", "Valid prompt\n")

    invalid_repo =
      write_repo!(root, "invalid", """
      ---
      tracker:
        kind: memory
      ---
      Invalid prompt
      """)

    start_repo_supervisor!(valid_repo)
    start_repo_supervisor!(invalid_repo)

    assert {:ok, %{prompt: "Valid prompt"}} = RepoSupervisor.current_workflow("valid")
    assert {:error, {:invalid_repo_workflow_config, message}} = RepoSupervisor.current_workflow("invalid")
    assert message =~ "symphony.yml"
  end

  test "runtime validation uses cached repo workflows after invalid reload", %{root: root} do
    valid_repo = write_repo!(root, "valid", "Valid prompt\n")
    api_repo = write_repo!(root, "api", "API prompt\n")

    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: valid
        workflow: #{Path.join(valid_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels:
            - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    start_repo_supervisor!(valid_repo)
    start_repo_supervisor!(api_repo)

    assert :ok = Config.validate!()
    assert {:ok, %{prompt: "API prompt"}} = RepoSupervisor.current_workflow("api")

    File.write!(SystemSchema.repo_workflow_path(api_repo), """
    ---
    tracker:
      kind: memory
    ---
    Invalid prompt
    """)

    assert {:ok, %{prompt: "API prompt"}} = RepoSupervisor.current_workflow("api")
    assert :ok = Config.validate!()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "WORKFLOW.md: repo api"
    assert message =~ "symphony.yml"
  end

  test "repo-specific workflow is used for prompt and repo-local settings", %{root: root} do
    web_repo =
      write_repo!(root, "web", """
      ---
      hooks:
        before_run: echo web
      ---
      Web {{ repo_key }} {{ issue.identifier }}
      """)

    api_repo =
      write_repo!(root, "api", """
      ---
      hooks:
        before_run: echo api
        after_create_timeout_ms: 900000
      verification:
        enabled: true
        port_allocation:
          range: [4300, 4301]
      ---
      API {{ repo_key }} {{ issue.identifier }}
      """)

    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: web
        workflow: #{Path.join(web_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels:
            - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, %{prompt: "Web {{ repo_key }} {{ issue.identifier }}"}} =
             Config.workflow_for_repo("web")

    assert {:ok, %{prompt: "API {{ repo_key }} {{ issue.identifier }}"}} =
             Config.workflow_for_repo("api")

    assert Config.settings_for_repo!("web").hooks.before_run == "echo web"
    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert Config.settings_for_repo!("api").verification.port_allocation.range == [4300, 4301]
    assert Hooks.after_create_timeout_ms(Config.settings_for_repo!("web").hooks) == 600_000
    assert Hooks.after_create_timeout_ms(Config.settings_for_repo!("api").hooks) == 900_000

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-api",
      identifier: "ACME-API",
      title: "Route to API",
      state: "Todo",
      repo_key: "api",
      labels: ["api"]
    }

    prompt = SymphonyElixir.PromptBuilder.build_prompt(issue)

    assert prompt =~ "Symphony runtime context:"
    assert prompt =~ "Repo key: `api`."
    assert prompt =~ "API api ACME-API"
  end

  test "repo workflow with an empty prompt falls back to the default prompt", %{root: root} do
    api_repo =
      write_repo!(root, "api", """
      ---
      ---
      """)

    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    issue = %Issue{
      id: "issue-api-fallback",
      identifier: "ACME-FALLBACK",
      title: "Use default prompt",
      state: "Todo",
      repo_key: "api"
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: ACME-FALLBACK"
    assert prompt =~ "Title: <linear_issue_title>\nUse default prompt\n</linear_issue_title>"
  end

  test "repo workflow verification deep merges over operator defaults", %{root: root} do
    web_repo =
      write_repo!(root, "web", """
      ---
      verification:
        enabled: false
      ---
      Web prompt
      """)

    api_repo =
      write_repo!(root, "api", """
      ---
      verification:
        dev_server:
          start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
          health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"
      ---
      API prompt
      """)

    write_symphony_text!(root, """
    issues:
      provider: memory
    verification:
      enabled: true
      port_allocation:
        range: [4400, 4402]
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: web
        workflow: #{Path.join(web_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels:
            - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    web_settings = Config.settings_for_repo!("web")
    api_settings = Config.settings_for_repo!("api")

    refute web_settings.verification.enabled
    assert api_settings.verification.enabled
    assert api_settings.verification.port_allocation.range == [4400, 4402]
    assert api_settings.verification.dev_server.start_cmd == "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    assert api_settings.verification.dev_server.health_check_url == "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"
  end

  test "application starts verification supervisors when any repo enables verification", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")

    api_repo =
      write_repo!(root, "api", """
      ---
      verification:
        enabled: true
      ---
      API prompt
      """)

    write_symphony_text!(root, """
    issues:
      provider: memory
    agent:
      runtime: codex
      command: codex app-server
    repositories:
      - key: web
        workflow: #{Path.join(web_repo.path, "WORKFLOW.md")}
        route:
          team: Test
        default: true
      - key: api
        workflow: #{Path.join(api_repo.path, "WORKFLOW.md")}
        route:
          team: Test
          labels:
            - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    verification_children = SymphonyElixir.Application.child_specs_for_runtime(%{})

    dev_server_supervisor_child = {
      DynamicSupervisor,
      strategy: :one_for_one, name: SymphonyElixir.Verification.DevServerSupervisor
    }

    assert SymphonyElixir.Verification.PortPool in verification_children
    assert dev_server_supervisor_child in verification_children
  end

  test "reloading one repo workflow restarts only that repo subtree", %{root: root} do
    first_repo = write_repo!(root, "first", "First prompt\n")
    second_repo = write_repo!(root, "second", "Second prompt\n")

    start_repo_supervisor!(first_repo)
    start_repo_supervisor!(second_repo)

    first_before = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_before = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    File.write!(SystemSchema.repo_workflow_path(first_repo), "Updated first prompt\n")

    assert :ok = RepoSupervisor.reload("first")

    first_after = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_after = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    assert is_pid(first_after)
    assert first_after != first_before
    assert second_after == second_before
    assert {:ok, %{prompt: "Updated first prompt"}} = RepoSupervisor.current_workflow("first")
    assert {:ok, %{prompt: "Second prompt"}} = RepoSupervisor.current_workflow("second")
  end

  test "repo supervisor reload returns a clear error for unknown repos" do
    assert {:error, :repo_supervisor_not_found} = RepoSupervisor.reload("missing-repo")
  end

  test "repo supervisor rejects repo structs without workflow data" do
    Application.put_env(:symphony_elixir, :primary_repo_name, nil)

    repo = %SystemSchema.Repo{name: "broken", workflow: nil, team: "Test"}

    assert_raise ArgumentError, ~r/repo workflow path requires non-empty `workflow`/, fn ->
      RepoSupervisor.start_link(repo)
    end
  end

  test "application child specs clear bootstrap env when later config loading fails", %{root: root} do
    repo =
      write_repo!(root, "invalid", """
      ---
      tracker:
        kind: memory
      ---
      Invalid prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))
    Application.put_env(:symphony_elixir, :primary_repo_name, "stale")
    Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/stale-workflow.md")

    assert_raise ArgumentError, ~r/WORKFLOW.md:.*symphony.yml/, fn ->
      SymphonyElixir.Application.child_specs_for_runtime(%{})
    end

    refute Application.get_env(:symphony_elixir, :primary_repo_name)
    refute Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  test "application start clears bootstrap env when supervisor start fails", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")
    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    blocker = ensure_supervisor_name_blocked!()
    assert is_pid(blocker)

    assert {:error, {:already_started, ^blocker}} = SymphonyElixir.Application.start(:normal, [])
    refute Application.get_env(:symphony_elixir, :primary_repo_name)
    refute Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  defp write_symphony!(root, repos) do
    File.write!(
      Path.join(root, "symphony.yml"),
      """
      issues:
        provider: memory
      agent:
        runtime: codex
        command: codex app-server
      repositories:
      """ <> repos_yaml(repos)
    )
  end

  defp write_symphony_text!(root, content) do
    File.write!(Path.join(root, "symphony.yml"), content)
  end

  defp symphony_text(repos, opts) do
    poll_interval_ms = Keyword.fetch!(opts, :poll_interval_ms)

    """
    issues:
      provider: memory
      poll_interval_ms: #{poll_interval_ms}
    agent:
      runtime: codex
      command: codex app-server
    repositories:
    """ <> repos_yaml(repos)
  end

  defp repos_yaml(repos) do
    repos
    |> Enum.with_index()
    |> Enum.map_join("", fn {repo, index} ->
      routing_yaml =
        if index == 0 do
          ["    default: true"]
        else
          ["      labels:", "        - #{repo.name}"]
        end

      [
        "  - key: #{repo.name}",
        "    workflow: #{Path.join(repo.path, "WORKFLOW.md")}",
        "    route:",
        "      team: Test"
      ]
      |> Kernel.++(routing_yaml)
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    end)
  end

  defp system_config(overrides) do
    Map.merge(
      %{
        "issues" => %{"provider" => "memory"},
        "agent" => %{"runtime" => "codex", "command" => "codex app-server"},
        "repositories" => [repo_config("app")]
      },
      overrides
    )
  end

  defp repo_config(name, overrides \\ %{}) do
    path = Map.get(overrides, "path")
    workflow = Map.get(overrides, "workflow", "tmp/#{name}/WORKFLOW.md")

    workflow = if is_binary(path) and Path.type(workflow) != :absolute, do: Path.join(path, workflow), else: workflow

    %{
      "key" => name,
      "workflow" => workflow,
      "route" => %{"team" => "Test"}
    }
    |> Map.merge(Map.drop(overrides, ["name", "path", "team", "projects", "labels", "assignee"]))
    |> maybe_put_route("team", Map.get(overrides, "team"))
    |> maybe_put_route("projects", Map.get(overrides, "projects"))
    |> maybe_put_route("labels", Map.get(overrides, "labels"))
    |> maybe_put_route("assignee", Map.get(overrides, "assignee"))
  end

  defp maybe_put_route(repo, _key, nil), do: repo

  defp maybe_put_route(repo, key, value) do
    Map.update(repo, "route", %{key => value}, &Map.put(&1, key, value))
  end

  defp write_repo!(root, name, workflow_content) do
    repo_path = Path.join(root, name)
    workflow_path = Path.join(repo_path, "WORKFLOW.md")
    File.mkdir_p!(repo_path)
    File.write!(workflow_path, workflow_content)

    %SystemSchema.Repo{
      name: name,
      path: repo_path,
      workflow: "WORKFLOW.md",
      team: "Test"
    }
  end

  defp start_repo_supervisor!(repo) do
    Application.put_env(:symphony_elixir, :primary_repo_name, nil)
    {:ok, pid} = RepoSupervisor.start_link(repo)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    pid
  end

  defp ensure_repo_registry_started! do
    case Process.whereis(SymphonyElixir.Repo.Registry) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        start_supervised!({Registry, keys: :unique, name: SymphonyElixir.Repo.Registry})
        :ok
    end
  end

  defp ensure_supervisor_name_blocked! do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        pid

      _ ->
        {:ok, pid} = Agent.start_link(fn -> :blocked end, name: SymphonyElixir.Supervisor)

        on_exit(fn -> stop_supervisor_name_blocker(pid) end)

        pid
    end
  end

  defp stop_supervisor_name_blocker(pid) do
    if Process.alive?(pid) do
      Agent.stop(pid)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
