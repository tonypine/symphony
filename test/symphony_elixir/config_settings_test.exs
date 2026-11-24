defmodule SymphonyElixir.ConfigSettingsTest do
  use SymphonyElixir.TestSupport
  import SymphonyElixir.WorkspaceTestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Execution, StringOrMap}
  alias SymphonyElixir.Config.Schema.Verification.DevServer, as: DevServerConfig
  alias SymphonyElixir.Config.Schema.Workspace.Attachments
  alias SymphonyElixir.Config.Schema.Workspace.Lifecycle, as: WorkspaceLifecycle
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Secret

  test "workspace lifecycle config has conservative defaults and parses overrides" do
    lifecycle = Config.settings!().workspace.lifecycle

    assert lifecycle.age_gc_enabled == true
    assert lifecycle.max_age_days == 14
    assert lifecycle.gc_interval_ms == 3_600_000
    assert lifecycle.min_free_bytes == nil
    assert lifecycle.orphan_action == "log"
    assert lifecycle.trash_dir == ".trash"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_lifecycle: %{
        age_gc_enabled: false,
        max_age_days: 3,
        gc_interval_ms: 5_000,
        min_free_bytes: 1_048_576,
        orphan_action: "trash",
        trash_dir: ".workspace-trash"
      }
    )

    lifecycle = Config.settings!().workspace.lifecycle

    assert lifecycle.age_gc_enabled == false
    assert lifecycle.max_age_days == 3
    assert lifecycle.gc_interval_ms == 5_000
    assert lifecycle.min_free_bytes == 1_048_576
    assert lifecycle.orphan_action == "trash"
    assert lifecycle.trash_dir == ".workspace-trash"

    blank_trash_dir =
      %WorkspaceLifecycle{}
      |> WorkspaceLifecycle.changeset(%{trash_dir: " "})
      |> Changeset.apply_changes()

    assert blank_trash_dir.trash_dir == ".trash"

    nil_trash_dir =
      %WorkspaceLifecycle{}
      |> WorkspaceLifecycle.changeset(%{trash_dir: nil})
      |> Changeset.apply_changes()

    assert nil_trash_dir.trash_dir == ".trash"
  end

  test "workspace attachment allowed hosts default and normalize overrides" do
    assert Config.settings!().workspace.attachments.allowed_hosts == ["github.com"]

    assert {:ok, settings} =
             Schema.parse(%{
               "workspace" => %{
                 "attachments" => %{
                   "allowed_hosts" => [" GitHub.COM ", "", "gist.github.com", "GITHUB.com"]
                 }
               }
             })

    assert settings.workspace.attachments.allowed_hosts == ["github.com", "gist.github.com"]

    attachments =
      %Attachments{allowed_hosts: ["old.example"]}
      |> Attachments.changeset(%{allowed_hosts: []})
      |> Changeset.apply_changes()

    assert attachments.allowed_hosts == ["github.com"]
  end

  test "github config defaults and validates failed run log ceiling" do
    assert Config.settings!().github.failed_run_log_max_bytes == 65_536

    assert {:ok, settings} =
             Schema.parse(%{
               "github" => %{
                 "failed_run_log_max_bytes" => 12_345
               }
             })

    assert settings.github.failed_run_log_max_bytes == 12_345

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "github" => %{
                 "failed_run_log_max_bytes" => 0
               }
             })

    assert message =~ "github.failed_run_log_max_bytes"
    assert message =~ "must be greater than 0"
  end

  test "github opens pull requests as draft by default and parses the opt-out" do
    assert Config.settings!().github.open_pull_requests_as_draft == true

    assert {:ok, settings} =
             Schema.parse(%{
               "github" => %{
                 "open_pull_requests_as_draft" => false
               }
             })

    assert settings.github.open_pull_requests_as_draft == false
  end

  test "dependency allow-list config defaults and normalizes entries" do
    assert Config.settings!().dependencies.allow_registries == []
    assert Config.settings!().dependencies.allow_git_sources == []
    assert Config.settings!().dependencies.allow_path_sources == []

    write_workflow_file!(Workflow.workflow_file_path(),
      dependencies: %{
        allow_registries: [" private-hex.internal ", "", "private-hex.internal"],
        allow_git_sources: [" github.com/acme/* ", "github.com/acme/*"],
        allow_path_sources: nil
      }
    )

    dependencies = Config.settings!().dependencies

    assert dependencies.allow_registries == ["private-hex.internal"]
    assert dependencies.allow_git_sources == ["github.com/acme/*"]
    assert dependencies.allow_path_sources == []

    nil_allow_list =
      %Schema.Dependencies{allow_path_sources: ["../old"]}
      |> Schema.Dependencies.changeset(%{allow_path_sources: nil})
      |> Changeset.apply_changes()

    assert nil_allow_list.allow_path_sources == []
  end

  test "workspace lifecycle rejects unsafe trash directories" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_lifecycle: %{orphan_action: "trash", trash_dir: "../outside"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "trash_dir"
    assert message =~ "must not contain parent directory segments"
  end

  test "symphony.yml can turn the stray process check off with a null threshold" do
    assert {:ok, system_config} =
             SystemSchema.parse(%{
               "watchdog" => %{"stray_process_cpu_minutes" => nil},
               "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
               "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}},
               "repositories" => [%{"key" => "default", "workflow" => "WORKFLOW.md"}]
             })

    assert system_config.watchdog.stray_process_cpu_minutes == nil
    watchdog = SystemSchema.to_config_map(system_config)["watchdog"]
    assert {:ok, %Schema{watchdog: parsed}} = Schema.parse(%{"watchdog" => watchdog})
    assert parsed.stray_process_cpu_minutes == nil
  end

  test "the git network and MCP tool timeouts come from symphony.yml, then the app env, then the defaults" do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :git_network_timeout_ms)
      Application.delete_env(:symphony_elixir, :mcp_tool_timeout_ms)
    end)

    assert Config.git_network_timeout_ms() == 300_000
    assert Config.mcp_tool_timeout_ms() == 600_000

    Application.put_env(:symphony_elixir, :git_network_timeout_ms, 1_000)
    Application.put_env(:symphony_elixir, :mcp_tool_timeout_ms, 2_000)
    assert Config.git_network_timeout_ms() == 1_000
    assert Config.mcp_tool_timeout_ms() == 2_000

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_git_network_timeout_ms: 120_000,
      agent_mcp_tool_timeout_ms: 900_000
    )

    assert Config.git_network_timeout_ms() == 120_000
    assert Config.mcp_tool_timeout_ms() == 900_000
    assert Config.settings!().workspace.git_network_timeout_ms == 120_000
    assert Config.settings!().execution.mcp_tool_timeout_ms == 900_000

    # A symphony.yml that doesn't validate falls back to the app env.
    write_workflow_file!(Workflow.workflow_file_path(), workspace_git_network_timeout_ms: 0)
    assert Config.git_network_timeout_ms() == 1_000
    assert Config.mcp_tool_timeout_ms() == 2_000
  end

  test "symphony check names an invalid git network or MCP tool timeout" do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_git_network_timeout_ms: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workspaces.git_network_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_mcp_tool_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution.timeouts.mcp_tool_ms"
  end

  test "the pending tool report threshold comes from symphony.yml and must be a positive integer" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Config.settings!().watchdog.pending_tool_report_after_ms == 60_000

    watchdog = %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 600_000}

    write_workflow_file!(Workflow.workflow_file_path(), watchdog: Map.put(watchdog, :pending_tool_report_after_ms, 300_000))
    assert Config.settings!().watchdog.pending_tool_report_after_ms == 300_000

    for bad <- [0, -1, "soon"] do
      write_workflow_file!(Workflow.workflow_file_path(), watchdog: Map.put(watchdog, :pending_tool_report_after_ms, bad))
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "watchdog.pending_tool_report_after_ms"
    end
  end

  test "the dispatch-loop limits come from symphony.yml, positive and runs at most 50" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert %{
             dispatch_loop_runs: 4,
             dispatch_loop_window_ms: 600_000,
             dispatch_loop_long_runs: 8,
             dispatch_loop_long_window_ms: 3_600_000
           } = Config.settings!().watchdog

    watchdog = %{enabled: true, tick_interval_ms: 60_000, no_progress_threshold_ms: 600_000}

    limits = %{
      dispatch_loop_runs: 3,
      dispatch_loop_window_ms: 300_000,
      dispatch_loop_long_runs: 6,
      dispatch_loop_long_window_ms: 7_200_000
    }

    write_workflow_file!(Workflow.workflow_file_path(), watchdog: Map.merge(watchdog, limits))
    assert ^limits = Map.take(Config.settings!().watchdog, Map.keys(limits))

    bad_values = for key <- Map.keys(limits), bad <- [0, "often"], do: {key, bad}

    for {key, bad} <- bad_values ++ [{:dispatch_loop_runs, 51}, {:dispatch_loop_long_runs, 51}] do
      write_workflow_file!(Workflow.workflow_file_path(), watchdog: Map.put(watchdog, key, bad))
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "watchdog.#{key}"
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    # Config.validate!/0 logs each budget warning once per node; clear the flags so an
    # earlier run or test cannot swallow the warnings asserted below.
    for {{Config, :warned_once, _message} = key, _value} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      agent_approval_policy: nil,
      agent_thread_sandbox: nil,
      agent_turn_sandbox_policy: nil,
      agent_turn_timeout_ms: nil,
      agent_read_timeout_ms: nil,
      agent_stall_timeout_ms: nil,
      agent_command_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.workspace.strategy == "clone"
    assert config.workspace.repo == nil
    assert config.workspace.fetch_before_dispatch

    assert config.workspace.attachments.public_upload_extensions == [
             ".png",
             ".jpg",
             ".jpeg",
             ".gif",
             ".webp",
             ".svg",
             ".pdf"
           ]

    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.execution.max_concurrent_agents == 10
    assert config.execution.max_tokens_per_issue == nil
    assert config.execution.max_tokens_per_day == nil
    assert config.execution.command == nil
    assert Config.run(config, :implementation).command == "codex app-server"

    # Unset, the approval policy is the run's harness's default, on the run's settings only.
    assert config.execution.approval_policy == nil

    assert Config.for_run(config, Config.run(config, :implementation)).execution.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.execution.thread_sandbox == "workspace-write"
    assert config.execution.network_access.mode == "allowlist"
    assert config.execution.network_access.allowed_domains == []
    assert config.execution.network_access.denied_domains == []
    assert config.execution.sandbox_runtime.kind == "none"
    assert config.execution.sandbox_runtime.command == "srt"
    assert config.execution.sandbox_runtime.enable_weaker_network_isolation == false

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.execution.turn_timeout_ms == 3_600_000
    assert config.execution.read_timeout_ms == 30_000
    assert config.execution.stall_timeout_ms == 300_000
    assert config.execution.command_timeout_ms == 600_000
    assert config.watchdog.enabled
    assert config.watchdog.tick_interval_ms == 60_000
    assert config.watchdog.no_progress_threshold_ms == 600_000
    assert config.watchdog.stray_process_cpu_minutes == 10
    assert config.server.port == nil
    assert config.server.host == "127.0.0.1"
    assert Config.server_port() == 0
    assert Config.server_host() == "127.0.0.1"
    assert config.verification.enabled == false
    assert config.verification.port_allocation.range == [4100, 4199]
    assert config.verification.dev_server.start_cmd == nil
    assert config.verification.dev_server.health_check_url == nil
    assert config.verification.dev_server.health_timeout_ms == 30_000
    assert config.verification.dev_server.stop_signal == "TERM"
    assert config.verification.dev_server.stop_timeout_ms == 10_000
    refute SymphonyElixir.Verification.PortPool in SymphonyElixir.Application.child_specs_for_runtime(%{})

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.run(Config.settings!(), :implementation).command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        port_allocation: %{range: [4100, 4102]},
        dev_server: %{
          start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT",
          health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz",
          health_timeout_ms: 100,
          stop_signal: "sigterm",
          stop_timeout_ms: 50
        }
      }
    )

    assert Config.settings!().verification.enabled == true
    assert Config.settings!().verification.port_allocation.range == [4100, 4102]
    assert Config.settings!().verification.dev_server.stop_signal == "TERM"
    verification_children = SymphonyElixir.Application.child_specs_for_runtime(%{})

    dev_server_supervisor_child = {
      DynamicSupervisor,
      strategy: :one_for_one, name: SymphonyElixir.Verification.DevServerSupervisor
    }

    assert SymphonyElixir.Verification.PortPool in verification_children
    assert dev_server_supervisor_child in verification_children

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [4102, 4100]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.port_allocation.range"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [4100]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "must contain exactly two port integers"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [0, 70_000]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "must contain two port integers between 1 and 65535"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"}
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.dev_server.start_cmd is set"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{
          start_cmd: " ",
          health_check_url: " ",
          stop_signal: "sigint",
          stop_timeout_ms: 0
        }
      }
    )

    assert Config.settings!().verification.dev_server.start_cmd == nil
    assert Config.settings!().verification.dev_server.health_check_url == nil
    assert Config.settings!().verification.dev_server.stop_signal == "INT"
    assert Config.settings!().verification.dev_server.stop_timeout_ms == 0

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{stop_signal: "USR1"}
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.dev_server.stop_signal"

    dev_server_changeset =
      DevServerConfig.changeset(%DevServerConfig{}, %{
        start_cmd: nil,
        health_check_url: nil,
        stop_signal: nil
      })

    assert dev_server_changeset.valid?

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: 500_000,
      max_tokens_per_day: 5_000_000
    )

    config = Config.settings!()
    assert config.execution.max_tokens_per_issue == 500_000
    assert config.execution.max_tokens_per_day == 5_000_000
    assert config.execution.max_consecutive_identical_tool_failures == 5

    write_workflow_file!(Workflow.workflow_file_path(), server_port: 4123)
    assert Config.server_port() == 4123

    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0")
    assert Config.server_host() == "0.0.0.0"

    Application.put_env(:symphony_elixir, :server_host_override, "localhost")
    assert Config.server_host() == "localhost"
    Application.delete_env(:symphony_elixir, :server_host_override)

    # `dashboard.enabled: false` turns off only the terminal dashboard, not the control API.
    write_workflow_file!(Workflow.workflow_file_path(), observability_enabled: false)
    assert Config.server_port() == 0

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: 500_000,
      agent_command: "codex run"
    )

    warning =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert warning =~ "agent.max_tokens_per_issue is configured"
    assert warning =~ "may not report token usage"

    refute capture_log(fn -> assert :ok = Config.validate!() end) =~ "may not report token usage"

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_day: 5_000_000,
      agent_command: "codex run"
    )

    warning =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert warning =~ "agent.max_tokens_per_day is configured"
    assert warning =~ "may not report token usage"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      agent_approval_policy: "on-request",
      agent_thread_sandbox: "workspace-write",
      agent_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.execution.approval_policy == "on-request"
    assert config.execution.thread_sandbox == "workspace-write"

    assert {:ok, canonical_explicit_workspace} =
             SymphonyElixir.PathSafety.canonicalize(explicit_workspace)

    assert {:ok, canonical_explicit_workspace_git} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(explicit_workspace, ".git"))

    assert {:ok, canonical_explicit_cache} =
             SymphonyElixir.PathSafety.canonicalize(explicit_cache)

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [
               canonical_explicit_workspace,
               canonical_explicit_workspace_git,
               canonical_explicit_cache
             ],
             "networkAccess" => true
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "issues.states.active"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.concurrency.max_total"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_per_issue: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.limits.tokens_per_issue"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_per_day: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.limits.tokens_per_day"

    write_workflow_file!(Workflow.workflow_file_path(), max_consecutive_identical_tool_failures: -1)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.limits.max_consecutive_identical_tool_failures"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "workers.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), agent_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.timeouts.turn_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.timeouts.read_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.timeouts.stall_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_command_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.timeouts.command_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      watchdog: %{enabled: true, tick_interval_ms: 0, no_progress_threshold_ms: "bad", stray_process_cpu_minutes: 0}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "watchdog.tick_interval_ms"
    assert message =~ "watchdog.no_progress_threshold_ms"
    assert message =~ "watchdog.stray_process_cpu_minutes"

    write_workflow_file!(Workflow.workflow_file_path(),
      watchdog: %{
        enabled: true,
        tick_interval_ms: 60_000,
        no_progress_threshold_ms: 600_000,
        stray_process_cpu_minutes: nil
      }
    )

    assert Config.settings!().watchdog.stray_process_cpu_minutes == nil

    write_workflow_file!(Workflow.workflow_file_path(), workspace_strategy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "workspaces.strategy"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      observability_snapshot_publish_ms: 0,
      observability_transcript_buffer_size: -1,
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate_repo_workflows()

    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().execution.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), agent_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().execution.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), agent_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "execution.permissions.filesystem.turn_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_approval_policy: "future-policy",
      agent_thread_sandbox: "future-sandbox",
      agent_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.execution.approval_policy == "future-policy"
    assert config.execution.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), agent_command: "codex app-server")
    assert Config.run(Config.settings!(), :implementation).command == "codex app-server"
  end

  test "codex runtime approval policy maps auto approve all to Codex wire value" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "auto_approve_all")

    assert Config.settings!().execution.approval_policy == "auto_approve_all"
    assert {:ok, runtime_settings} = Config.codex_runtime_settings()
    assert runtime_settings.approval_policy == "never"
    assert runtime_settings.auto_approve_requests == true
  end

  test "config parses project guide controls and rejects unsafe guide paths" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_include_project_guides: false,
      agent_project_guide_files: ["CLAUDE.md", "docs/AGENTS.md"]
    )

    config = Config.settings!()
    assert config.execution.include_project_guides == false
    assert config.execution.project_guide_files == ["CLAUDE.md", "docs/AGENTS.md"]

    write_workflow_file!(Workflow.workflow_file_path(), agent_include_project_guides: "yes")
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "include_project_guides"

    write_workflow_file!(Workflow.workflow_file_path(), agent_project_guide_files: ["/tmp/CLAUDE.md"])
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "project_guide_files"

    write_workflow_file!(Workflow.workflow_file_path(), agent_project_guide_files: ["../AGENTS.md"])
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "project_guide_files"

    write_workflow_file!(Workflow.workflow_file_path(), agent_project_guide_files: [""])
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "project_guide_files"

    write_workflow_file!(Workflow.workflow_file_path(), agent_project_guide_files: ["~/CLAUDE.md"])
    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "project_guide_files"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_project_guide_files: ["bad\nentry.md"]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "project_guide_files"
  end

  test "codex runtime delegates turn sandboxing to SRT when sandbox runtime is enabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_sandbox_runtime: %{kind: "srt"},
      agent_thread_sandbox: "workspace-write",
      agent_turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: true}
    )

    assert Config.settings!().execution.sandbox_runtime.kind == "srt"
    assert {:ok, runtime_settings} = Config.codex_runtime_settings()
    assert runtime_settings.thread_sandbox == "workspace-write"
    assert runtime_settings.turn_sandbox_policy == %{"type" => "externalSandbox"}
  end

  test "config rejects legacy Codex approval policy never" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "never")

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ ~s(execution.permissions.approval_policy="never" is not supported on the codex harness)
    assert message =~ "auto_approve_all"
  end

  test "config defaults omitted Claude approval policy to never" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_approval_policy: nil
    )

    config = Config.settings!()
    assert config.execution.harness == nil
    assert config.execution.approval_policy == nil

    run_config = Config.for_run(config, Config.run(config, :implementation))
    assert run_config.execution.harness == "claude"
    assert run_config.execution.approval_policy == "never"
  end

  test "config validates local worktree repository settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-config-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      not_git_repo = Path.join(test_root, "not-git")
      missing_repo = Path.join(test_root, "missing")

      File.mkdir_p!(not_git_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: nil
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspaces.repo is required"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: missing_repo
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspaces.repo does not exist"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: not_git_repo
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspaces.repo is not a valid git repository"

      create_primary_repo!(primary_repo)
      File.write!(Path.join(primary_repo, "dirty.txt"), "dirty\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      assert log =~ "Worktree primary clone has uncommitted changes"
      assert log =~ primary_repo

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: "~/remote-primary",
        worker_ssh_hosts: ["worker-01"]
      )

      assert :ok = Config.validate!()
      assert Config.settings!().workspace.repo == "~/remote-primary"
    after
      File.rm_rf(test_root)
    end
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      agent_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert Secret.unwrap(config.tracker.api_key) == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert Config.run(config, :implementation).command == "#{codex_bin} app-server"
  end

  test "config parses workspace public upload extension overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_attachments: %{public_upload_extensions: [".PNG", "log", " .pdf ", " "]}
    )

    assert Config.settings!().workspace.attachments.public_upload_extensions == [".png", ".log", ".pdf"]
  end

  test "config rejects invalid workspace public upload extension overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_attachments: %{public_upload_extensions: [".png", ".", "bad/path"]}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "workspaces.attachments.public_upload_extensions"
    assert message =~ "must contain only file extensions like .png"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert Secret.unwrap(config.tracker.api_key) == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "symphony.yml no longer takes the finishing allowance, the per-state limits or the epic lanes" do
    base = %{
      "execution" => %{"harnesses" => %{"codex" => %{"command" => "codex app-server"}}},
      "runs" => %{"default" => %{"harness" => "codex", "provider" => "openai", "model" => "gpt-test"}},
      "repositories" => [%{"key" => "default", "workflow" => "WORKFLOW.md"}]
    }

    assert {:ok, system_config} = SystemSchema.parse(put_in(base, ["execution", "concurrency"], %{"max_total" => 3}))
    assert system_config.execution.max_concurrent_agents == 3

    for {key, value} <- [{"finishing_max", 2}, {"max_by_issue_state", %{"todo" => 1}}, {"epic_lanes", 1}] do
      config = put_in(base, ["execution", "concurrency"], %{"max_total" => 3, key => value})

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(config)
      assert message =~ "execution.concurrency.#{key}"
    end

    # The old name of the per-state limits is no longer known either.
    assert {:error, {:invalid_symphony_config, message}} =
             SystemSchema.parse(put_in(base, ["execution", "max_concurrent_agents_by_state"], %{"todo" => 1}))

    assert message =~ "max_concurrent_agents_by_state"

    for field <- [:finishing_max, :max_concurrent_agents_by_state, :epic_lanes] do
      refute field in Execution.__schema__(:fields)
    end

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 10)
    assert Config.settings!().execution.max_concurrent_agents == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover the custom type" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               execution: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.execution.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert Secret.unwrap(settings.tracker.api_key) == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             execution: %Execution{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == Map.put(explicit_policy, "networkAccess", true)

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             execution: %Execution{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               execution: %Execution{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema resolves codex network allowlist config" do
    assert {:ok, settings} =
             Schema.parse(%{
               execution: %{
                 network_access: %{
                   mode: "allowlist",
                   allowed_domains: ["API.MyCompany.com", " registry.npmjs.org "],
                   denied_domains: ["REGISTRY.NPMJS.ORG", "api.github.com"]
                 }
               }
             })

    built_in_domains = Schema.codex_built_in_network_allowed_domains()
    assert "github.com" in built_in_domains
    assert "registry.npmjs.org" in built_in_domains

    for domain <- ["dl.google.com", "maven.google.com", "release-assets.githubusercontent.com", "uploads.linear.app"] do
      assert domain in built_in_domains
      assert domain in Schema.claude_built_in_network_allowed_domains()
    end

    assert settings.execution.network_access.mode == "allowlist"
    assert settings.execution.network_access.allowed_domains == ["api.mycompany.com", "registry.npmjs.org"]
    assert settings.execution.network_access.denied_domains == ["registry.npmjs.org", "api.github.com"]

    effective_domains = Schema.codex_effective_network_allowed_domains(settings)
    assert "github.com" in effective_domains
    assert "api.mycompany.com" in effective_domains
    refute "api.github.com" in effective_domains
    refute "registry.npmjs.org" in effective_domains

    thread_config = Schema.resolve_codex_thread_config(settings)
    experimental_network = thread_config["experimental_network"]

    assert experimental_network["enabled"] == true
    assert experimental_network["managedAllowedDomainsOnly"] == true
    assert experimental_network["domains"]["github.com"] == "allow"
    assert experimental_network["domains"]["api.mycompany.com"] == "allow"
    refute Map.has_key?(experimental_network["domains"], "api.github.com")
    refute Map.has_key?(experimental_network["domains"], "registry.npmjs.org")
  end

  test "schema maps codex network modes to sandbox policy and thread config" do
    assert {:ok, block_settings} =
             Schema.parse(%{
               execution: %{
                 network_access: %{mode: "block"},
                 turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: true}
               }
             })

    assert Schema.resolve_turn_sandbox_policy(block_settings)["networkAccess"] == false
    assert Schema.resolve_codex_thread_config(block_settings) == nil

    assert {:ok, open_settings} =
             Schema.parse(%{
               execution: %{
                 network_access: %{mode: "open"},
                 turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: false}
               }
             })

    assert Schema.resolve_turn_sandbox_policy(open_settings)["networkAccess"] == true
    assert Schema.resolve_codex_thread_config(open_settings) == nil
  end

  test "schema parses codex sandbox runtime config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_sandbox_runtime: %{
        kind: "srt",
        command: "/usr/local/bin/srt",
        enable_weaker_network_isolation: true
      }
    )

    runtime = Config.settings!().execution.sandbox_runtime
    assert runtime.kind == "srt"
    assert runtime.command == "/usr/local/bin/srt"
    assert runtime.enable_weaker_network_isolation == true

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_network_access: %{mode: "open"},
      agent_sandbox_runtime: %{kind: "srt"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()

    assert message =~
             "execution.permissions.outer_sandbox.kind=\"srt\" does not support execution.permissions.network.mode=\"open\""

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_sandbox_runtime: %{kind: "srt"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "execution.permissions.outer_sandbox.kind=\"srt\" is only supported on the codex harness"
  end

  test "schema parses agent MCP defaults and declared servers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{
        servers: %{
          "example-server" => %{
            transport: "stdio",
            command: "node",
            args: ["/srv/example-server/server.js"],
            env: %{LOG_LEVEL: "info"},
            harnesses: ["claude", "codex"]
          },
          "docs" => %{
            transport: "http",
            url: "https://docs.example/mcp",
            headers: %{Authorization: "Bearer token"},
            harnesses: ["claude"]
          }
        }
      }
    )

    mcp = Config.settings!().execution.mcp
    assert mcp.inherit == "none"
    assert mcp.allowed_servers == []
    assert mcp.servers["example-server"].transport == "stdio"
    assert mcp.servers["example-server"].command == "node"
    assert mcp.servers["example-server"].args == ["/srv/example-server/server.js"]
    assert mcp.servers["example-server"].env == %{"LOG_LEVEL" => "info"}
    assert mcp.servers["docs"].transport == "http"
    assert mcp.servers["docs"].harnesses == ["claude"]
  end

  test "schema validates agent MCP inheritance and Codex transport restrictions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{inherit: "allowlist", allowed_servers: []}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "execution.mcp.allowed_servers"
    assert message =~ "must not be empty"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_mcp: %{inherit: "all"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ ~s(execution.mcp.inherit="all" is not supported on the claude harness)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{
        servers: %{
          "browser" => %{
            transport: "sse",
            url: "https://browser.example/sse",
            harnesses: ["codex"]
          }
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "browser is invalid"
    assert message =~ ~s(transport=\\"sse\\" is not supported on the codex harness; its MCP servers must use transport=\\"stdio\\")

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{
        servers: %{
          "browser-default-harnesses" => %{
            transport: "sse",
            url: "https://browser.example/sse"
          }
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "browser-default-harnesses is invalid"
    assert message =~ ~s(transport=\\"sse\\" is not supported on the codex harness; its MCP servers must use transport=\\"stdio\\")

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{inherit: "none", allowed_servers: ["example-server"]}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "execution.mcp.allowed_servers"
    assert message =~ "must be empty unless execution.mcp.inherit is allowlist"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{
        inherit: "allowlist",
        allowed_servers: ["example-server"],
        servers: %{
          "invalid-runtime" => %{
            command: "node",
            env: [],
            harnesses: ["unknown"]
          }
        }
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "invalid-runtime is invalid"
    assert message =~ "unsupported runtime"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{servers: %{"invalid-transport" => %{transport: "websocket", command: "node"}}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "invalid-transport is invalid"
    assert message =~ "is invalid"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{servers: %{"symphony" => %{command: "shadow"}}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "must not declare reserved MCP server names"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mcp: %{servers: []}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "execution.mcp.servers"
  end

  test "schema network helpers tolerate missing embedded network config" do
    settings = %Schema{
      execution: %Execution{network_access: nil},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert "github.com" in Schema.codex_effective_network_allowed_domains(settings)
    assert get_in(Schema.resolve_codex_thread_config(settings), ["experimental_network", "domains", "github.com"]) == "allow"

    nil_domains_settings = %Schema{
      execution: %Execution{
        network_access: %Execution.NetworkAccess{allowed_domains: nil, denied_domains: nil}
      },
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert Schema.codex_effective_network_allowed_domains(nil_domains_settings) ==
             Schema.codex_built_in_network_allowed_domains()
  end

  test "schema network helpers fail on malformed embedded network config" do
    settings = %Schema{
      execution: %Execution{network_access: %{mode: "open"}},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert_raise FunctionClauseError, fn ->
      Schema.codex_effective_network_allowed_domains(settings)
    end
  end

  test "runtime sandbox policy keeps workspaceWrite policy rootless when no workspace is available" do
    settings = %Schema{
      execution: %Execution{
        network_access: %Execution.NetworkAccess{mode: "block"},
        turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => []}
      },
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert {:ok, policy} = Schema.resolve_runtime_turn_sandbox_policy(settings, nil)
    assert policy == %{"type" => "workspaceWrite", "writableRoots" => [], "networkAccess" => false}
  end

  test "runtime sandbox policy resolution keeps clone workspace writable with explicit roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, "relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy discovers regular clone git metadata roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-clone-git-roots-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-CLONE")

      create_primary_repo!(source_repo)
      File.mkdir_p!(workspace_root)
      {_output, 0} = System.cmd("git", ["clone", source_repo, issue_workspace], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, "relative/path"],
               "networkAccess" => true
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy discovers linked worktree git metadata roots from workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-discovered-worktree-roots-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-DISCOVER")

      create_primary_repo!(primary_repo)
      File.mkdir_p!(workspace_root)
      git!(primary_repo, ["worktree", "add", "-b", "auto/MT-DISCOVER", issue_workspace])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "clone",
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      git_dir =
        issue_workspace
        |> git!(["rev-parse", "--path-format=absolute", "--git-dir"])
        |> String.trim()

      git_common_dir =
        issue_workspace
        |> git!(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        |> String.trim()

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, canonical_git_dir} = SymphonyElixir.PathSafety.canonicalize(git_dir)
      assert {:ok, canonical_git_common_dir} = SymphonyElixir.PathSafety.canonicalize(git_common_dir)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [
                 canonical_issue_workspace,
                 canonical_issue_workspace_git,
                 canonical_git_dir,
                 canonical_git_common_dir,
                 "relative/path"
               ],
               "networkAccess" => true
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution adds worktree git metadata root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-worktree-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")
      repo = Path.join(test_root, "repo")
      repo_git = Path.join(repo, ".git")

      File.mkdir_p!(issue_workspace)
      File.mkdir_p!(repo_git)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, canonical_repo_git} = SymphonyElixir.PathSafety.canonicalize(repo_git)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [
                 canonical_issue_workspace,
                 canonical_issue_workspace_git,
                 canonical_repo_git,
                 "relative/path"
               ],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: nil
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, canonical_repo_git],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => true,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, canonical_repo_git],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => true,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution filters non-string writableRoots entries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-nonstring-roots-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-NS")
      invalid_root = Path.join(test_root, String.duplicate("a", 300))
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      policy_settings = %{
        settings
        | execution: %{
            settings.execution
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => ["relative/path", invalid_root, 8080, %{"nested" => true}]
              }
          }
      }

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, policy} =
               Schema.resolve_runtime_turn_sandbox_policy(policy_settings, issue_workspace)

      assert policy["writableRoots"] == [canonical_workspace, canonical_workspace_git, "relative/path"]

      invalid_root_settings = %{
        settings
        | execution: %{
            settings.execution
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => [invalid_root]
              }
          }
      }

      assert {:ok, invalid_root_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(invalid_root_settings, issue_workspace)

      assert invalid_root_policy["writableRoots"] == [canonical_workspace, canonical_workspace_git]

      invalid_roots_settings = %{
        settings
        | execution: %{
            settings.execution
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => "not-a-list"
              }
          }
      }

      assert {:ok, invalid_roots_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(invalid_roots_settings, issue_workspace)

      assert invalid_roots_policy["writableRoots"] == [canonical_workspace, canonical_workspace_git]
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution keeps explicit absolute roots raw in remote mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-remote-roots-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      policy_settings = %{
        settings
        | execution: %{
            settings.execution
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => ["/remote/absolute/path", "relative/path"]
              }
          }
      }

      assert {:ok, policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 policy_settings,
                 "/remote/workspace",
                 remote: true
               )

      assert policy["writableRoots"] == [
               "/remote/workspace",
               "/remote/workspace/.git",
               "/remote/absolute/path",
               "relative/path"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | execution: %{settings.execution | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | execution: %{settings.execution | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget defaults apply when omitted and explicit null disables caps" do
    write_workflow_without_token_budget_keys!()

    config = Config.settings!()
    assert config.execution.max_tokens_per_issue == 500_000
    assert config.execution.max_tokens_per_day == 5_000_000

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: nil,
      max_tokens_per_day: nil
    )

    config = Config.settings!()
    assert config.execution.max_tokens_per_issue == nil
    assert config.execution.max_tokens_per_day == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      max_consecutive_identical_tool_failures: 0
    )

    config = Config.settings!()
    assert config.execution.max_consecutive_identical_tool_failures == 0
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  defp write_workflow_without_token_budget_keys! do
    File.write!(Workflow.workflow_file_path(), "Prompt\n")

    File.write!(Workflow.symphony_file_path(), """
    issues:
      provider: memory
    execution:
      harnesses:
        codex:
          command: codex app-server
    runs:
      default: {harness: codex, provider: openai, model: gpt-test}
    repositories:
      - key: default
        workflow: #{Workflow.workflow_file_path()}
        route:
          team: Test
    """)

    reload_workflow_store()
  end

  defp reload_workflow_store do
    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
