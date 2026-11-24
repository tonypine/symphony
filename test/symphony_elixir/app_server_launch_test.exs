defmodule SymphonyElixir.AppServerLaunchTest do
  use SymphonyElixir.TestSupport

  defmodule AlwaysErrorAudit do
    @moduledoc false

    def audit(_workspace, _opts), do: {:error, {:git_failed, ["rev-parse"], "boom"}}
  end

  defmodule AlwaysHoldAudit do
    @moduledoc false

    def audit(_workspace, _opts) do
      {:hold, [%{path: "mix.exs", package: "helper", from: nil, to: "git", reason: "untrusted_git_source"}]}
    end
  end

  test "app server normalizes nested Codex total_token_usage metadata" do
    payload = %{
      "method" => "codex/event/token_count",
      "params" => %{
        "msg" => %{
          "payload" => %{
            "info" => %{
              "total_token_usage" => %{
                "input_tokens" => 12_000,
                "cached_input_tokens" => 10_000,
                "output_tokens" => 500,
                "total_tokens" => 12_500
              }
            }
          }
        }
      }
    }

    assert %{usage: usage} = AppServer.usage_metadata_for_test(payload)
    assert usage.input_tokens == 12_000
    assert usage.uncached_input_tokens == 2_000
    assert usage.cached_input_tokens == 10_000
    assert usage.cache_creation_input_tokens == 0
    assert usage.output_tokens == 500
    assert usage.total_tokens == 12_500
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server refuses to launch when agent.command is missing the app-server token" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sandbox-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SANDBOX")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "fake-codex"
      )

      issue = %Issue{
        id: "issue-sandbox-required",
        identifier: "MT-SANDBOX",
        title: "Validate sandbox enforcement",
        description: "Ensure missing app-server token aborts the launch",
        state: "In Progress",
        url: "https://example.org/issues/MT-SANDBOX",
        labels: ["backend"]
      }

      assert {:error, {:codex_sandbox_overrides_not_applied, :missing_app_server_token}} =
               AppServer.run(workspace, "should never launch", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches Codex with generated CODEX_HOME and denies generated auth/config paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-codex-home-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-HOME")
      fake_home = Path.join(test_root, "home")
      host_codex_home = Path.join(fake_home, ".codex")
      codex_binary = Path.join(test_root, "fake-codex")
      codex_home_trace = Path.join(test_root, "codex-home.trace")
      argv_trace = Path.join(test_root, "argv.trace")
      config_copy = Path.join(test_root, "config-copy.toml")
      auth_link_trace = Path.join(test_root, "auth-link.trace")
      previous_home = System.get_env("HOME")

      File.mkdir_p!(workspace)
      File.mkdir_p!(host_codex_home)
      File.write!(Path.join(host_codex_home, "auth.json"), "test auth placeholder")
      System.put_env("HOME", fake_home)
      on_exit(fn -> restore_env("HOME", previous_home) end)

      File.write!(codex_binary, """
      #!/bin/sh
      printf '%s' "$CODEX_HOME" > "#{codex_home_trace}"
      printf '%s\\n' "$@" > "#{argv_trace}"
      cat "$CODEX_HOME/config.toml" > "#{config_copy}"
      printf '%s' '{"signed_payload":{"cached_at":"2026-05-21T10:00:00Z","expires_at":"2026-05-21T11:00:00Z","chatgpt_user_id":"user-test","account_id":"account-test","contents":null},"signature":"generated"}' > "$CODEX_HOME/cloud-requirements-cache.json"
      if [ -L "$CODEX_HOME/auth.json" ]; then
        printf 'symlink' > "#{auth_link_trace}"
      fi

      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-codex-home"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} = AppServer.start_session(workspace)

      codex_home = File.read!(codex_home_trace)
      assert String.starts_with?(codex_home, System.tmp_dir!())
      assert File.read!(auth_link_trace) == "symlink"

      config = File.read!(config_copy)
      assert config =~ "[mcp_servers.symphony]"
      assert config =~ "symphony-mcp-shim"
      refute config =~ "[mcp_servers.example-server]"

      argv = File.read!(argv_trace)
      assert argv =~ "--config"
      assert argv =~ Path.join(codex_home, "auth.json")
      assert argv =~ Path.join(codex_home, "config.toml")

      assert :ok = AppServer.stop_session(session)
      assert File.read!(Path.join(host_codex_home, "cloud-requirements-cache.json")) =~ ~s("signature":"generated")
      refute File.exists?(codex_home)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server logs the pid, command and run id of the Codex process it starts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-app-server-codex-priority-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-NICE")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-codex-nice"}}}' ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      log =
        capture_log(fn ->
          assert {:ok, session} = AppServer.start_session(workspace, run_id: "run-codex-nice")
          assert :ok = AppServer.stop_session(session)
        end)

      # Sandboxed test runs can't lower the priority, so either message is logged.
      assert log =~ ~r/Started agent (below|at) Symphony's CPU priority.* pid=\d+ run_id=run-codex-nice command="#{codex_binary} app-server"/
    after
      File.rm_rf(test_root)
    end
  end

  @tag :process_table
  @tag :setpriority
  test "app server starts Codex and the processes it starts below Symphony's CPU priority" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-app-server-codex-niceness-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-NICE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace = Path.join(test_root, "niceness.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      ps -o nice= -p $$ > "#{trace}"
      sh -c 'ps -o nice= -p $$' >> "#{trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-codex-nice"}}}' ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} = AppServer.start_session(workspace)
      assert :ok = AppServer.stop_session(session)

      {symphony, 0} = System.cmd("ps", ["-o", "nice=", "-p", System.pid()])
      assert [agent, child] = trace |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)
      assert agent > String.to_integer(String.trim(symphony))
      assert child == agent
    after
      File.rm_rf(test_root)
    end
  end

  test "app server opts out of high-volume executor notifications during initialize" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-notification-opt-out-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-NOTIFY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-notification-opt-out.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-notify"}}}'
            ;;
          *)
            :
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} = AppServer.start_session(workspace)
      assert :ok = AppServer.stop_session(session)

      [initialize_line | _rest] =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))

      initialize_payload =
        initialize_line
        |> String.trim_leading("JSON:")
        |> Jason.decode!()

      assert get_in(initialize_payload, ["params", "capabilities", "optOutNotificationMethods"]) == [
               "turn/diff/updated",
               "item/commandExecution/outputDelta",
               "item/fileChange/outputDelta",
               "item/agentMessage/delta"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "app server keeps agent message deltas enabled for read-only reviewer sessions" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-review-notification-opt-out-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-NOTIFY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-review-notification-opt-out.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-notify"}}}'
            ;;
          *)
            :
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert {:ok, session} = AppServer.start_session(workspace, tool_scope: :read_only)
      assert :ok = AppServer.stop_session(session)

      [initialize_line | _rest] =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))

      initialize_payload =
        initialize_line
        |> String.trim_leading("JSON:")
        |> Jason.decode!()

      assert get_in(initialize_payload, ["params", "capabilities", "optOutNotificationMethods"]) == [
               "turn/diff/updated",
               "item/commandExecution/outputDelta",
               "item/fileChange/outputDelta"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_command: "#{codex_binary} app-server",
          agent_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        {:ok, canonical_workspace} =
          SymphonyElixir.PathSafety.canonicalize(Path.expand(workspace))

        {:ok, canonical_workspace_git} =
          SymphonyElixir.PathSafety.canonicalize(Path.join(workspace, ".git"))

        expected_policy =
          case configured_policy do
            %{"type" => "workspaceWrite"} ->
              Map.put(
                configured_policy,
                "writableRoots",
                [canonical_workspace, canonical_workspace_git, "relative/path" | SymphonyElixir.AgentCaches.write_paths()]
              )

            _ ->
              configured_policy
          end

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == expected_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server defaults nil dependency audit module when dependency audit holds" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-dependency-pr-gate-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-PR-GATE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-pr-gate.trace")

      File.mkdir_p!(workspace)

      File.write!(Path.join(workspace, "mix.exs"), """
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: []
        def application, do: []
        defp deps, do: [{:jason, "~> 1.4"}]
      end
      """)

      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "mix.exs"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "base"])
      System.cmd("git", ["-C", workspace, "update-ref", "refs/remotes/origin/main", "HEAD"])

      File.write!(Path.join(workspace, "mix.exs"), """
      defmodule Demo.MixProject do
        use Mix.Project
        def project, do: []
        def application, do: []
        defp deps, do: [{:jason, "~> 1.4"}, {:helper, git: "https://github.com/attacker/helper.git"}]
      end
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pr-gate"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-pr-gate","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":44,"method":"item/commandExecution/requestApproval","params":{"parsedCmd":"gh pr create --title test"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      # The pause projector writes the Needs Decision label of the question the gate asks.
      Application.put_env(:symphony_elixir, :pause_projector, true)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        Application.put_env(:symphony_elixir, :pause_projector, false)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_approval_policy: "auto_approve_all"
      )

      assert :ok = SymphonyElixir.Notifications.subscribe()

      issue = %Issue{
        id: "issue-pr-gate",
        repo_key: "default",
        identifier: "MT-PR-GATE",
        title: "PR gate",
        description: "Block risky dependency PR",
        state: "In Progress"
      }

      assert {:ok, _result} = AppServer.run(workspace, "Open PR", issue, dependency_audit_module: nil)

      trace = File.read!(trace_file)
      assert trace =~ ~s("id":44)
      assert trace =~ ~s("decision":"deny")

      assert_receive {:memory_tracker_label_added, "issue-pr-gate", "Needs Decision"}, 5_000
      refute_received {:memory_tracker_state_update, "issue-pr-gate", _state}

      assert_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "dependency_pending_approval",
                        metadata: %{dependency_changes: [%{package: "helper", reason: "untrusted_git_source"}]}
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "app server denies gh pr create when dependency audit errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-dep-audit-err-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AUDIT-ERR")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-audit-err.trace")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-audit-err"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-audit-err","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":44,"method":"item/commandExecution/requestApproval","params":{"parsedCmd":"gh pr create --title test"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      # The pause projector writes the Needs Decision label of the question the gate asks.
      Application.put_env(:symphony_elixir, :pause_projector, true)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        Application.put_env(:symphony_elixir, :pause_projector, false)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_approval_policy: "auto_approve_all"
      )

      assert :ok = SymphonyElixir.Notifications.subscribe()

      issue = %Issue{
        id: "issue-audit-err",
        repo_key: "default",
        identifier: "MT-AUDIT-ERR",
        title: "Audit error",
        description: "Fail closed when audit errors",
        state: "In Progress"
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Open PR", issue, dependency_audit_module: AlwaysErrorAudit)

      trace = File.read!(trace_file)
      assert trace =~ ~s("id":44)
      assert trace =~ ~s("decision":"deny")

      assert_receive {:memory_tracker_label_added, "issue-audit-err", "Needs Decision"}, 5_000
      refute_received {:memory_tracker_state_update, "issue-audit-err", _state}

      assert_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "dependency_pending_approval",
                        reason: "dependency_audit_failed",
                        metadata: %{audit_error: audit_error}
                      }},
                     500

      assert audit_error =~ "git_failed"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server denies dynamic github_create_pull_request when dependency audit holds" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-dynamic-pr-gate-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DYN-PR-GATE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dynamic-pr-gate.trace")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dynamic-pr-gate"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dynamic-pr-gate","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":88,"method":"item/tool/call","params":{"name":"github_create_pull_request","callId":"call-dynamic-pr-gate","threadId":"thread-dynamic-pr-gate","turnId":"turn-dynamic-pr-gate","arguments":{"title":"Open PR","body":"Body"}}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      # The pause projector writes the Needs Decision label of the question the gate asks.
      Application.put_env(:symphony_elixir, :pause_projector, true)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
        Application.put_env(:symphony_elixir, :pause_projector, false)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      assert :ok = SymphonyElixir.Notifications.subscribe()

      issue = %Issue{
        id: "issue-dynamic-pr-gate",
        repo_key: "default",
        identifier: "MT-DYN-PR-GATE",
        title: "Dynamic PR gate",
        description: "Block risky dependency PR from dynamic tool",
        state: "In Progress"
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Open PR", issue, dependency_audit_module: AlwaysHoldAudit)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 88 and
                   get_in(payload, ["result", "success"]) == false and
                   get_in(payload, ["result", "output"])
                   |> Jason.decode!()
                   |> get_in(["error", "code"])
                   |> Kernel.==("dependency_source_requires_approval")
               else
                 false
               end
             end)

      assert_receive {:memory_tracker_label_added, "issue-dynamic-pr-gate", "Needs Decision"}, 5_000
      refute_received {:memory_tracker_state_update, "issue-dynamic-pr-gate", _state}

      assert_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "dependency_pending_approval",
                        metadata: %{dependency_changes: [%{package: "helper", reason: "untrusted_git_source"}]}
                      }},
                     500
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes host-qualified origin repo to dynamic GitHub tools" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-dynamic-gh-host-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DYN-GH-HOST")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dynamic-gh-host.trace")
      File.mkdir_p!(workspace)

      assert {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["remote", "add", "origin", "git@github.example.com:acme/symphony.git"],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dynamic-gh-host"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dynamic-gh-host","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"id":89,"method":"item/tool/call","params":{"name":"github_get_pull_request","callId":"call-dynamic-gh-host","threadId":"thread-dynamic-gh-host","turnId":"turn-dynamic-gh-host","arguments":{}}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        github: %{enterprise_hosts: ["github.example.com"]},
        agent_command: "#{codex_binary} app-server"
      )

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == canonical_workspace
          {"feature/topic\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "feature/topic", "--repo", "github.example.com/acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == canonical_workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 12,
             "state" => "OPEN",
             "title" => "Host-aware PR",
             "body" => "Body",
             "url" => "https://github.example.com/acme/symphony/pull/12",
             "headRefName" => "feature/topic",
             "baseRefName" => "main"
           }), 0}
      end

      issue = %Issue{
        id: "issue-dynamic-gh-host",
        identifier: "MT-DYN-GH-HOST",
        title: "Dynamic GitHub host",
        description: "Use host-qualified repo selectors",
        state: "In Progress"
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Read PR", issue, git_runner: git_runner, gh_runner: gh_runner)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 89 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"])
                   |> Jason.decode!()
                   |> get_in(["url"])
                   |> Kernel.==("https://github.example.com/acme/symphony/pull/12")
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails closed when sandbox startup is not acknowledged before turn completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sandbox-missing-ack-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SANDBOX-MISSING")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-sandbox-missing"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-sandbox-missing"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-sandbox-missing",
        identifier: "MT-SANDBOX-MISSING",
        title: "Require sandbox startup acknowledgement",
        description: "Ensure a missing sandbox startup acknowledgement fails closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-SANDBOX-MISSING",
        labels: ["backend"]
      }

      assert {:error, :sandbox_required} =
               AppServer.run(workspace, "Validate missing sandbox acknowledgement", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails closed when sandbox startup is downgraded or unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sandbox-downgraded-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SANDBOX-DOWN")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$_line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-sandbox-down"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-sandbox-down","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"sandbox/downgraded","params":{"reason":"sandbox runtime unavailable"}}'
            sleep 1
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-sandbox-down",
        identifier: "MT-SANDBOX-DOWN",
        title: "Require sandbox availability",
        description: "Ensure a downgraded sandbox fails closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-SANDBOX-DOWN",
        labels: ["backend"]
      }

      assert {:error, :sandbox_required} =
               AppServer.run(workspace, "Validate sandbox downgraded", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server maps current Codex sandboxError startup failures to sandbox required" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sandbox-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SANDBOX-ERROR")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-sandbox-error"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-sandbox-error","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"error","params":{"threadId":"thread-sandbox-error","turnId":"turn-sandbox-error","willRetry":false,"error":{"message":"sandbox runtime unavailable","codexErrorInfo":"sandboxError"}}}'
            sleep 1
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-sandbox-error",
        identifier: "MT-SANDBOX-ERROR",
        title: "Require sandbox error handling",
        description: "Ensure current Codex sandbox errors fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-SANDBOX-ERROR",
        labels: ["backend"]
      }

      assert {:error, :sandbox_required} =
               AppServer.run(workspace, "Validate sandbox error", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server accepts current Codex turn-started sandbox startup acknowledgement" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-sandbox-turn-started-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SANDBOX-READY")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-sandbox-ready"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-sandbox-ready"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/started","params":{"threadId":"thread-sandbox-ready","turn":{"id":"turn-sandbox-ready","status":"inProgress","items":[]}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-sandbox-ready","turn":{"id":"turn-sandbox-ready","status":"completed","items":[]}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-sandbox-ready",
        identifier: "MT-SANDBOX-READY",
        title: "Accept sandbox startup acknowledgement",
        description: "Ensure current Codex startup acknowledgement succeeds",
        state: "In Progress",
        url: "https://example.org/issues/MT-SANDBOX-READY",
        labels: ["backend"]
      }

      assert {:ok, %{result: :turn_completed}} =
               AppServer.run(workspace, "Validate sandbox ready", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks child processes as Symphony agent runtime" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-agent-runtime-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1002")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-agent-runtime-env.trace")
      codex_config_copy = Path.join(test_root, "codex-config-copy.toml")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      config_copy="#{codex_config_copy}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf 'ENV:%s\\n' "$SYMPHONY_AGENT_RUNTIME" >> "$trace_file"

      if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ]; then
        cp "$CODEX_HOME/config.toml" "$config_copy"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1002"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1002","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-agent-runtime-env",
        identifier: "MT-1002",
        title: "Validate agent runtime marker",
        description: "Ensure Codex child processes can suppress nested orchestration",
        state: "In Progress",
        url: "https://example.org/issues/MT-1002",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate runtime marker", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      trace = File.read!(trace_file)
      assert trace =~ "ENV:1"
      assert trace =~ "--config default_permissions=\"workspace_write\""
      assert trace =~ "--config permissions.workspace_write.filesystem="
      assert trace =~ "\"~/.ssh\"=\"none\""
      refute trace =~ "\":project_roots\""
      assert trace =~ ~s("#{Path.join(canonical_workspace, "WORKFLOW.md")}"="read")
      assert trace =~ "--config permissions.workspace_write.network={\"enabled\"=true,\"mode\"=\"limited\"}"
      assert trace =~ "--config permissions.workspace_write.network.domains="
      assert trace =~ "\"github.com\"=\"allow\""
      assert trace =~ "\"api.openai.com\"=\"allow\""
      refute trace =~ "evil.example.com"
      assert trace =~ ~s("#{Path.join(canonical_workspace, "config/settings_ui_exempt.yml")}"="read")

      # A person's decision unlocked one protected path for this run.
      File.rm!(trace_file)
      assert {:ok, _result} = AppServer.run(workspace, "Validate runtime marker", issue, unlocked_paths: ["config/settings_ui_exempt.yml"])
      trace = File.read!(trace_file)
      refute trace =~ ~s("#{Path.join(canonical_workspace, "config/settings_ui_exempt.yml")}"="read")
      assert trace =~ ~s("#{Path.join(canonical_workspace, "WORKFLOW.md")}"="read")

      # Local Codex keeps the implicit symphony MCP server on a Unix socket when
      # the runner permits AF_UNIX bind; restrictive sandboxes fall back to TCP.
      codex_config = File.read!(codex_config_copy)
      assert_codex_mcp_config_matches_transport(codex_config)
    after
      File.rm_rf(test_root)
    end
  end

  test "native Codex permission profile write-protects the shared repo's git config files" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-git-metadata-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-GITMETA")
      primary_repo = Path.join(test_root, "primary")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-git-metadata.trace")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(primary_repo)

      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: primary_repo, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"],
                 cd: primary_repo,
                 stderr_to_stdout: true
               )

      assert {_output, 0} = System.cmd("git", ["worktree", "add", "-b", "auto/MT-GITMETA", workspace], cd: primary_repo, stderr_to_stdout: true)

      assert {output, 0} =
               System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], stderr_to_stdout: true)

      [git_dir, common_dir] =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn path ->
          {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(path)
          canonical
        end)

      File.write!(Path.join(git_dir, "config.worktree"), "")
      submodule_config = Path.join([common_dir, "modules", "vendor", "lib", "config"])
      File.mkdir_p!(Path.dirname(submodule_config))
      File.write!(submodule_config, "")

      File.write!(codex_binary, """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-gitmeta"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-gitmeta","status":"inProgress","items":[]}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-git-metadata",
        identifier: "MT-GITMETA",
        title: "Protect git metadata",
        description: "Deny writes to the shared repo's git config",
        state: "In Progress",
        url: "https://example.org/issues/MT-GITMETA",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Protect git metadata", issue)

      [filesystem] = Regex.run(~r/permissions\.workspace_write\.filesystem=(\{.*?\}) --config/, File.read!(trace_file), capture: :all_but_first)

      for path <- [
            Path.join(common_dir, "config"),
            Path.join(common_dir, "config.worktree"),
            Path.join(common_dir, "hooks"),
            Path.join(common_dir, "info"),
            Path.join([common_dir, "worktrees", Path.basename(git_dir), "config.worktree"]),
            submodule_config,
            Path.join(git_dir, "config")
          ] do
        assert filesystem =~ ~s("#{path}"="read")
      end

      refute filesystem =~ ~s("#{Path.join(common_dir, "objects")}")
      refute filesystem =~ "*"
      assert length(String.split(filesystem, ~s("#{Path.join(git_dir, "config.worktree")}"="read"))) == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "app server can wrap Codex app-server with srt settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-srt-wrapper-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SRT")
      primary_repo = Path.join(test_root, "primary")
      codex_binary = Path.join(test_root, "fake-codex")
      srt_binary = Path.join(test_root, "fake-srt")
      trace_file = Path.join(test_root, "codex-srt-wrapper.trace")
      settings_copy = Path.join(test_root, "srt-settings-copy.json")
      codex_config_copy = Path.join(test_root, "codex-config-copy.toml")
      previous_ssl_cert_file = System.get_env("SSL_CERT_FILE")
      on_exit(fn -> restore_env("SSL_CERT_FILE", previous_ssl_cert_file) end)
      System.put_env("SSL_CERT_FILE", "/custom/operator.pem")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(primary_repo)

      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: primary_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: primary_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: primary_repo)
      File.write!(Path.join(primary_repo, "README.md"), "test\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: primary_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: primary_repo, stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["worktree", "add", "-b", "auto/MT-SRT", workspace],
                 cd: primary_repo,
                 stderr_to_stdout: true
               )

      assert {git_dir_output, 0} =
               System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-dir"], stderr_to_stdout: true)

      assert {git_common_dir_output, 0} =
               System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-common-dir"], stderr_to_stdout: true)

      git_dir = String.trim(git_dir_output)
      git_common_dir = String.trim(git_common_dir_output)

      assert git_dir != git_common_dir,
             "expected worktree git_dir and git_common_dir to differ; test setup may have regressed"

      File.write!(srt_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      settings_copy="#{settings_copy}"
      settings_path=""

      printf 'SRT_ARGV:%s\\n' "$*" >> "$trace_file"

      if [ "${1-}" = "--settings" ]; then
        settings_path="$2"
        shift 2
      fi

      printf 'SRT_SETTINGS:%s\\n' "$settings_path" >> "$trace_file"
      cp "$settings_path" "$settings_copy"
      HTTP_PROXY=http://localhost:1111
      HTTPS_PROXY=http://localhost:2222
      http_proxy=https://localhost:3333
      https_proxy=https://localhost:4444
      export HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
      exec "$@"
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      config_copy="#{codex_config_copy}"
      printf 'CODEX_ARGV:%s\\n' "$*" >> "$trace_file"
      printf 'ENV_HTTP_PROXY:%s\\n' "${HTTP_PROXY-}" >> "$trace_file"
      printf 'ENV_HTTPS_PROXY:%s\\n' "${HTTPS_PROXY-}" >> "$trace_file"
      printf 'ENV_http_proxy:%s\\n' "${http_proxy-}" >> "$trace_file"
      printf 'ENV_https_proxy:%s\\n' "${https_proxy-}" >> "$trace_file"
      printf 'ENV_SSL_CERT_FILE:%s\\n' "${SSL_CERT_FILE-}" >> "$trace_file"

      if [ -n "${CODEX_HOME:-}" ] && [ -f "$CODEX_HOME/config.toml" ]; then
        cp "$CODEX_HOME/config.toml" "$config_copy"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$_line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-srt"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-srt","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(srt_binary, 0o755)
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_sandbox: %{allow_read_paths: ["~/.npmrc"]},
        agent_command: "#{codex_binary} app-server",
        agent_network_access: %{
          mode: "allowlist",
          allowed_domains: ["api.mycompany.com"],
          denied_domains: ["github.com"]
        },
        agent_sandbox_runtime: %{
          kind: "srt",
          command: srt_binary
        }
      )

      issue = %Issue{
        id: "issue-srt",
        identifier: "MT-SRT",
        title: "Validate srt wrapper",
        description: "Ensure Codex launch can be wrapped by sandbox-runtime",
        state: "In Progress",
        url: "https://example.org/issues/MT-SRT",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate srt wrapper", issue, unlocked_paths: ["config/settings_ui_exempt.yml"])

      trace = File.read!(trace_file)
      assert trace =~ "SRT_ARGV:--settings "
      assert trace =~ " sh -c "
      assert trace =~ "SSL_CERT_FILE=/etc/ssl/cert.pem"
      assert trace =~ "CODEX_ARGV:--config tool_output_token_limit=4096"
      assert trace =~ "ENV_HTTP_PROXY:http://127.0.0.1:1111"
      assert trace =~ "ENV_HTTPS_PROXY:http://127.0.0.1:2222"
      assert trace =~ "ENV_http_proxy:https://127.0.0.1:3333"
      assert trace =~ "ENV_https_proxy:https://127.0.0.1:4444"
      assert trace =~ "ENV_SSL_CERT_FILE:/custom/operator.pem"
      assert trace =~ "--config default_permissions=\"workspace_write\""
      assert trace =~ "--config permissions.workspace_write.filesystem="
      refute trace =~ "\":project_roots\""
      assert trace =~ "--config permissions.workspace_write.network={\"enabled\"=true,\"mode\"=\"limited\"}"
      assert trace =~ " app-server"

      json_payloads =
        trace
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn
          "JSON:" <> json -> [Jason.decode!(json)]
          _line -> []
        end)

      assert Enum.any?(json_payloads, fn payload ->
               payload["method"] == "thread/start" &&
                 get_in(payload, ["params", "sandbox"]) == "workspace-write"
             end)

      assert Enum.any?(json_payloads, fn payload ->
               payload["method"] == "turn/start" &&
                 get_in(payload, ["params", "sandboxPolicy"]) == %{"type" => "externalSandbox"}
             end)

      srt_settings_path =
        trace
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn
          "SRT_SETTINGS:" <> path -> path
          _line -> nil
        end)

      assert is_binary(srt_settings_path)
      refute File.exists?(srt_settings_path)

      settings = settings_copy |> File.read!() |> Jason.decode!()
      assert "api.mycompany.com" in settings["network"]["allowedDomains"]
      assert "api.openai.com" in settings["network"]["allowedDomains"]
      refute "github.com" in settings["network"]["allowedDomains"]
      assert settings["network"]["deniedDomains"] == ["github.com"]

      allow_unix_sockets = settings["network"]["allowUnixSockets"]

      refute "~/.npmrc" in settings["filesystem"]["denyRead"]
      assert "~/.ssh" in settings["filesystem"]["denyRead"]
      assert "." in settings["filesystem"]["allowWrite"]
      assert "~/.codex" in settings["filesystem"]["allowWrite"]
      assert git_dir in settings["filesystem"]["allowWrite"]
      assert git_common_dir in settings["filesystem"]["allowWrite"]
      assert [cache_root] = SymphonyElixir.AgentCaches.write_paths()
      assert cache_root in settings["filesystem"]["allowWrite"]
      assert "./WORKFLOW.md" in settings["filesystem"]["denyWrite"]
      refute "./config/settings_ui_exempt.yml" in settings["filesystem"]["denyWrite"]

      for root <- [git_dir, git_common_dir] do
        assert Path.join(root, "config") in settings["filesystem"]["denyWrite"]
        assert Path.join(root, "config.worktree") in settings["filesystem"]["denyWrite"]
        assert Path.join(root, "hooks") in settings["filesystem"]["denyWrite"]
        assert Path.join(root, "info") in settings["filesystem"]["denyWrite"]
        refute Path.join(root, "objects") in settings["filesystem"]["denyWrite"]
        assert Path.join(root, "packed-refs") in settings["filesystem"]["denyWrite"]
        assert Path.join([root, "worktrees", "*", "config"]) in settings["filesystem"]["denyWrite"]
        assert Path.join([root, "worktrees", "*", "config.worktree"]) in settings["filesystem"]["denyWrite"]
        assert Path.join([root, "modules", "**", "config"]) in settings["filesystem"]["denyWrite"]
      end

      assert "~/.codex/auth.json" in settings["filesystem"]["denyWrite"]
      assert "~/.codex/config.toml" in settings["filesystem"]["denyWrite"]
      assert "~/.codex/AGENTS.md" in settings["filesystem"]["denyWrite"]
      assert settings["enableWeakerNestedSandbox"] == true
      assert settings["enableWeakerNetworkIsolation"] == false

      codex_config = File.read!(codex_config_copy)

      case assert_codex_mcp_config_matches_transport(codex_config) do
        :unix ->
          assert is_list(allow_unix_sockets)
          assert Enum.any?(allow_unix_sockets, &String.contains?(&1, "symphony-mcp-"))
          refute Enum.member?(allow_unix_sockets, System.tmp_dir!())

        :tcp ->
          assert unix_socket_bind_probe() == {:error, :eperm}
          assert allow_unix_sockets in [nil, []]
      end

      assert codex_config =~ ~s(SYMPHONY_MCP_SESSION_TOKEN = )
      assert codex_config =~ "PATH = "
      refute codex_config =~ "--session"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server srt wrapper keeps clone workspace .git/objects writable for git add" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-srt-clone-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SRTCLONE")
      source_repo = Path.join(test_root, "source")
      codex_binary = Path.join(test_root, "fake-codex")
      srt_binary = Path.join(test_root, "fake-srt")
      trace_file = Path.join(test_root, "codex-srt-clone.trace")
      settings_copy = Path.join(test_root, "srt-settings-clone-copy.json")
      File.mkdir_p!(workspace_root)
      File.mkdir_p!(source_repo)

      assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: source_repo, stderr_to_stdout: true)
      assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
      File.write!(Path.join(source_repo, "README.md"), "clone\n")
      assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: source_repo)
      assert {_output, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: source_repo, stderr_to_stdout: true)

      assert {_output, 0} = System.cmd("git", ["clone", source_repo, workspace], stderr_to_stdout: true)

      assert {git_dir_output, 0} =
               System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-dir"], stderr_to_stdout: true)

      assert {git_common_dir_output, 0} =
               System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-common-dir"], stderr_to_stdout: true)

      git_dir = String.trim(git_dir_output)
      git_common_dir = String.trim(git_common_dir_output)

      assert git_dir == git_common_dir,
             "expected clone workspace git_dir and git_common_dir to be identical; test setup may have regressed"

      File.write!(srt_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      settings_copy="#{settings_copy}"
      settings_path=""

      printf 'SRT_ARGV:%s\\n' "$*" >> "$trace_file"

      if [ "${1-}" = "--settings" ]; then
        settings_path="$2"
        shift 2
      fi

      printf 'SRT_SETTINGS:%s\\n' "$settings_path" >> "$trace_file"
      cp "$settings_path" "$settings_copy"
      exec "$@"
      """)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'CODEX_ARGV:%s\\n' "$*" >> "$trace_file"

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$_line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-srt-clone"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-srt-clone","status":"inProgress","items":[]}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(srt_binary, 0o755)
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server",
        agent_sandbox_runtime: %{
          kind: "srt",
          command: srt_binary
        }
      )

      issue = %Issue{
        id: "issue-srt-clone",
        identifier: "MT-SRTCLONE",
        title: "Validate srt clone wrapper",
        description: "Ensure clone workspaces can write .git/objects under SRT",
        state: "In Progress",
        url: "https://example.org/issues/MT-SRTCLONE",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate srt clone wrapper", issue)

      settings = settings_copy |> File.read!() |> Jason.decode!()

      refute Path.join(git_dir, "objects") in settings["filesystem"]["denyWrite"],
             ".git/objects must be writable for clone workspaces so git add can stage blobs"

      assert Path.join(git_dir, "config") in settings["filesystem"]["denyWrite"]
      assert Path.join(git_dir, "config.worktree") in settings["filesystem"]["denyWrite"]
      assert Path.join(git_dir, "hooks") in settings["filesystem"]["denyWrite"]
      assert Path.join(git_dir, "info") in settings["filesystem"]["denyWrite"]
      assert Path.join(git_dir, "packed-refs") in settings["filesystem"]["denyWrite"]
      assert Path.join([git_dir, "worktrees", "*", "config"]) in settings["filesystem"]["denyWrite"]
      assert Path.join([git_dir, "worktrees", "*", "config.worktree"]) in settings["filesystem"]["denyWrite"]

      assert git_dir in settings["filesystem"]["allowWrite"]
      assert git_common_dir in settings["filesystem"]["allowWrite"]
    after
      File.rm_rf(test_root)
    end
  end

  describe "git_metadata_deny_write_paths/2" do
    test "clone workspace .git keeps objects writable while denying high-risk metadata" do
      workspace = "/workspaces/MT-CLONE"
      git_dir = "/workspaces/MT-CLONE/.git"

      denies = AppServer.git_metadata_deny_write_paths(git_dir, workspace)

      refute Path.join(git_dir, "objects") in denies
      assert Path.join(git_dir, "config") in denies
      assert Path.join(git_dir, "config.worktree") in denies
      assert Path.join(git_dir, "hooks") in denies
      assert Path.join(git_dir, "info") in denies
      assert Path.join(git_dir, "packed-refs") in denies
      assert Path.join([git_dir, "worktrees", "*", "config"]) in denies
      assert Path.join([git_dir, "worktrees", "*", "config.worktree"]) in denies
      assert Path.join([git_dir, "modules", "**", "config"]) in denies
    end

    test "linked worktree common dir keeps objects writable while denying high-risk metadata" do
      workspace = "/workspaces/MT-LINKED"
      common_dir = "/source/.git"

      denies = AppServer.git_metadata_deny_write_paths(common_dir, workspace)

      refute Path.join(common_dir, "objects") in denies
      assert Path.join(common_dir, "config") in denies
      assert Path.join(common_dir, "config.worktree") in denies
      assert Path.join(common_dir, "hooks") in denies
      assert Path.join(common_dir, "info") in denies
      assert Path.join(common_dir, "packed-refs") in denies
      assert Path.join([common_dir, "worktrees", "*", "config"]) in denies
      assert Path.join([common_dir, "worktrees", "*", "config.worktree"]) in denies
      assert Path.join([common_dir, "modules", "**", "config"]) in denies
    end

    test "linked worktree per-issue git_dir keeps objects writable while denying high-risk metadata" do
      workspace = "/workspaces/MT-LINKED"
      worktree_git_dir = "/source/.git/worktrees/MT-LINKED"

      denies = AppServer.git_metadata_deny_write_paths(worktree_git_dir, workspace)

      refute Path.join(worktree_git_dir, "objects") in denies
      assert Path.join(worktree_git_dir, "config") in denies
      assert Path.join(worktree_git_dir, "hooks") in denies
      assert Path.join(worktree_git_dir, "info") in denies
      assert Path.join(worktree_git_dir, "packed-refs") in denies
    end

    test "paths without .git segment yield no deny entries" do
      assert AppServer.git_metadata_deny_write_paths("/workspaces/MT-1", "/workspaces/MT-1") == []
      assert AppServer.git_metadata_deny_write_paths("/some/other/path", "/workspaces/MT-1") == []
    end

    test "workspace prefix match is strict and ignores partial path components" do
      workspace = "/workspaces/MT-1"
      neighbor_git_dir = "/workspaces/MT-1-suffix/.git"

      denies = AppServer.git_metadata_deny_write_paths(neighbor_git_dir, workspace)

      refute Path.join(neighbor_git_dir, "objects") in denies
      assert Path.join(neighbor_git_dir, "config") in denies
    end

    test "trailing slash on workspace does not affect the inside-workspace check" do
      workspace = "/workspaces/MT-1/"
      git_dir = "/workspaces/MT-1/.git"

      denies = AppServer.git_metadata_deny_write_paths(git_dir, workspace)

      refute Path.join(git_dir, "objects") in denies
      assert Path.join(git_dir, "config") in denies
    end

    test "non-string inputs yield no deny entries" do
      assert AppServer.git_metadata_deny_write_paths(:not_a_path, "/workspaces/MT-1") == []
      assert AppServer.git_metadata_deny_write_paths("/workspaces/MT-1/.git", nil) == []
    end
  end

  test "app server rejects srt sandbox runtime for remote workers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_sandbox_runtime: %{kind: "srt"}
    )

    assert {:error, {:unsupported_agent_sandbox_runtime, "srt", :remote_worker}} =
             AppServer.start_session("/remote/workspace", worker_host: "worker-01")
  end

  test "app server strips provider, tracker, GitHub, and SSH agent secrets from the agent subprocess env" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-env-strip-#{System.unique_integer([:positive])}"
      )

    secret_vars = %{
      "LINEAR_API_KEY" => "lin_api_REDACTED_#{System.unique_integer([:positive])}",
      "ANTHROPIC_API_KEY" => "sk-ant-REDACTED_#{System.unique_integer([:positive])}",
      "OPENAI_API_KEY" => "sk-REDACTED_#{System.unique_integer([:positive])}",
      "GH_TOKEN" => "gho_REDACTED_#{System.unique_integer([:positive])}",
      "GITHUB_TOKEN" => "ghp_REDACTED_#{System.unique_integer([:positive])}",
      "SSH_AUTH_SOCK" => "/tmp/ssh-REDACTED-#{System.unique_integer([:positive])}/agent.1"
    }

    previous = Enum.map(secret_vars, fn {name, _} -> {name, System.get_env(name)} end)
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    Enum.each(secret_vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ENVSTRIP")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-env-strip.trace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "settings.gradle.kts"), "")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'LINEAR=%s\\n' "${LINEAR_API_KEY-<unset>}" >> "$trace_file"
      printf 'ANTHROPIC=%s\\n' "${ANTHROPIC_API_KEY-<unset>}" >> "$trace_file"
      printf 'OPENAI=%s\\n' "${OPENAI_API_KEY-<unset>}" >> "$trace_file"
      printf 'GH=%s\\n' "${GH_TOKEN-<unset>}" >> "$trace_file"
      printf 'GITHUB=%s\\n' "${GITHUB_TOKEN-<unset>}" >> "$trace_file"
      printf 'SSH_AUTH_SOCK=%s\\n' "${SSH_AUTH_SOCK-<unset>}" >> "$trace_file"
      printf 'RUNTIME=%s\\n' "${SYMPHONY_AGENT_RUNTIME-<unset>}" >> "$trace_file"
      printf 'GRADLE_OPTS=%s\\n' "${GRADLE_OPTS-<unset>}" >> "$trace_file"
      printf 'HEX_HOME=%s\\n' "${HEX_HOME-<unset>}" >> "$trace_file"
      printf 'ELIXIR_MAKE_CACHE_DIR=%s\\n' "${ELIXIR_MAKE_CACHE_DIR-<unset>}" >> "$trace_file"
      printf 'SYMPHONY_AGENT_CACHE_DIR=%s\\n' "${SYMPHONY_AGENT_CACHE_DIR-<unset>}" >> "$trace_file"
      printf 'TMPDIR=%s\\n' "${TMPDIR-<unset>}" >> "$trace_file"

      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-env-strip"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-env-strip","status":"inProgress","items":[]}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-env-strip",
        identifier: "MT-ENVSTRIP",
        title: "Confirm secrets are stripped",
        description: "Agent subprocess must not inherit provider/tracker keys",
        state: "In Progress",
        url: "https://example.org/issues/MT-ENVSTRIP",
        labels: []
      }

      assert {:ok, _result} = AppServer.run(workspace, "Confirm env strip", issue)

      trace = File.read!(trace_file)
      assert trace =~ "LINEAR=<unset>"
      assert trace =~ "ANTHROPIC=<unset>"
      assert trace =~ "OPENAI=<unset>"
      assert trace =~ "GH=<unset>"
      assert trace =~ "GITHUB=<unset>"
      assert trace =~ "SSH_AUTH_SOCK=<unset>"
      assert trace =~ "RUNTIME=1"
      assert trace =~ ~r/^GRADLE_OPTS="-Dorg.gradle.daemon.registry.base=\S*\/workspaces\/[A-Z]+-ENVSTRIP\/.gradle-daemons"$/m
      cache_root = SymphonyElixir.AgentCaches.config().root
      assert trace =~ "HEX_HOME=#{cache_root}/hex\n"
      assert trace =~ "ELIXIR_MAKE_CACHE_DIR=#{cache_root}/elixir_make\n"
      assert trace =~ "SYMPHONY_AGENT_CACHE_DIR=#{cache_root}\n"

      Enum.each(secret_vars, fn {_name, value} ->
        refute trace =~ value, "secret value leaked into agent subprocess: #{value}"
      end)

      # A QA pass gives its session a temp folder of its own.
      File.rm!(trace_file)
      assert {:ok, _result} = AppServer.run(workspace, "Confirm env strip", issue, extra_env: %{"TMPDIR" => "/tmp/symphony-qa-0123456789ab"})
      qa_trace = File.read!(trace_file)
      assert qa_trace =~ "TMPDIR=/tmp/symphony-qa-0123456789ab\n"
      assert qa_trace =~ "LINEAR=<unset>"
    after
      File.rm_rf(test_root)
    end
  end

  defp assert_codex_mcp_config_matches_transport(codex_config) do
    cond do
      codex_config =~ ~s(symphony-mcp-shim", "--socket", ) ->
        refute codex_config =~ "--tcp-host"
        refute codex_config =~ "--tcp-port"
        :unix

      codex_config =~ ~s(symphony-mcp-shim", "--tcp-host", "127.0.0.1", "--tcp-port", ) ->
        assert unix_socket_bind_probe() == {:error, :eperm}
        refute codex_config =~ "--socket"
        :tcp

      true ->
        flunk("expected generated Codex MCP config to use a Unix socket or loopback TCP fallback")
    end
  end
end
