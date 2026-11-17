defmodule SymphonyElixir.Opencode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Harnesses.Launcher
  alias SymphonyElixir.Opencode.AppServer

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-opencode-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "MT-OC")
    File.mkdir_p!(workspace)

    # Stands in for `sandbox-exec -p <profile>`: drops the profile and runs the command.
    sandbox = Path.join(root, "fake-sandbox")
    File.write!(sandbox, "#!/bin/sh\nshift 2\nexec \"$@\"\n")
    File.chmod!(sandbox, 0o755)
    Application.put_env(:symphony_elixir, :opencode_sandbox_opts, os_type: {:unix, :darwin}, executable: sandbox)
    Application.put_env(:symphony_elixir, :opencode_cold_catalog_pause_ms, 0)
    previous_key = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "oc-test-key")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :opencode_sandbox_opts)
      Application.delete_env(:symphony_elixir, :opencode_cold_catalog_pause_ms)
      if previous_key, do: System.put_env("OPENCODE_API_KEY", previous_key), else: System.delete_env("OPENCODE_API_KEY")
      File.rm_rf(root)
    end)

    %{root: root, workspace_root: workspace_root, workspace: workspace, fake: Path.join(root, "fake-opencode"), trace: Path.join(root, "trace")}
  end

  # An OpenCode stand-in that records its argv, the env the launcher set and its stdin, then
  # prints `lines` and exits with `status`.
  defp write_fake!(ctx, lines, status \\ 0) do
    File.write!(ctx.fake, """
    #!/bin/sh
    {
      echo "ARGV=$*"
      echo "CONFIG=$XDG_CONFIG_HOME DATA=$XDG_DATA_HOME"
      echo "PROXY=$HTTPS_PROXY KEY=$OPENCODE_API_KEY EXTRA=$EXTRA_FLAG"
      echo "STDIN=$(cat)"
    } >> "#{ctx.trace}"
    cat <<'OPENCODE_EVENTS'
    #{Enum.join(lines, "\n")}
    OPENCODE_EVENTS
    exit #{status}
    """)

    File.chmod!(ctx.fake, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.workspace_root, agent_kind: "opencode", agent_command: ctx.fake, agent_model: "kimi-k3")
  end

  defp event(type, fields), do: Jason.encode!(Map.merge(%{"type" => type, "sessionID" => "ses_1"}, fields))
  defp step_finish(reason, tokens), do: event("step_finish", %{"part" => %{"type" => "step-finish", "reason" => reason, "tokens" => tokens}})

  defp run(_ctx), do: Config.run(Config.settings!(), :implementation)
  defp issue, do: %Issue{id: "issue-oc", identifier: "MT-OC", title: "OpenCode", state: "In Progress"}

  defp trace(ctx), do: ctx.trace |> File.read!() |> String.split("\n", trim: true)

  describe "a turn" do
    test "runs opencode on the run's provider and model, in a home of its own, and reports its events", ctx do
      write_fake!(ctx, [
        event("step_start", %{"part" => %{"type" => "step-start"}}),
        event("text", %{"part" => %{"type" => "text", "text" => "Looking."}}),
        event("tool_use", %{"part" => %{"tool" => "shell", "state" => %{"status" => "completed", "output" => "done\n"}}}),
        step_finish("tool-calls", %{"input" => 100, "output" => 10, "reasoning" => 5, "cache" => %{"read" => 40, "write" => 2}}),
        event("step_start", %{"part" => %{"type" => "step-start"}}),
        event("text", %{"part" => %{"type" => "text", "text" => "Finished."}}),
        step_finish("stop", %{"input" => 20, "output" => 4, "reasoning" => 0, "cache" => %{"read" => 60, "write" => 0}})
      ])

      test_pid = self()

      opts = [run_profile: run(ctx), issue: issue(), extra_env: %{"EXTRA_FLAG" => "yes"}]
      assert {:ok, session} = AppServer.start_session(ctx.workspace, opts)
      assert session.home =~ "symphony-opencode-"
      assert File.read!(Path.join(session.home, "config/opencode/opencode.json")) =~ ~s("symphony")

      assert {:ok, result} = AppServer.run_turn(session, "Do the work", issue(), on_message: &send(test_pid, {:message, &1}))

      assert result == %{
               session_id: "ses_1",
               uncached_input_tokens: 120,
               cached_input_tokens: 100,
               cache_creation_input_tokens: 2,
               input_tokens: 222,
               output_tokens: 19,
               total_tokens: 241
             }

      assert_received {:message, {:session_started, "ses_1"}}
      refute_received {:message, {:session_started, "ses_1"}}
      assert_received {:message, {:agent_text, "Looking."}}
      assert_received {:message, {:tool_use, "shell"}}
      assert_received {:message, {:tool_result, "done\n"}}
      assert_received {:message, {:agent_text, "Finished."}}
      assert_received {:message, {:turn_completed, %{}}}

      [argv, homes, env, stdin] = trace(ctx)
      assert argv == "ARGV=run --standalone --archived --auto --format json --model opencode-go/kimi-k3"
      assert homes == "CONFIG=#{session.home}/config DATA=#{session.home}/data"
      assert env =~ ~r/^PROXY=http:\/\/127\.0\.0\.1:\d+ KEY=oc-test-key EXTRA=yes$/
      assert stdin =~ "STDIN=Do the work"

      File.rm!(ctx.trace)
      assert {:ok, %{session_id: "ses_1"}} = AppServer.run_turn(session, "Go on", issue(), resume_session_id: "ses_1")
      assert hd(trace(ctx)) == "ARGV=run --standalone --archived --auto --format json --model opencode-go/kimi-k3 --session ses_1"

      home = session.home
      assert AppServer.stop_session(session) == :ok
      refute File.exists?(home)
      assert AppServer.stop_session(%{}) == :ok
    end

    test "a caller that names no run gets the harness's command and no model", ctx do
      write_fake!(ctx, [event("step_start", %{}), step_finish("stop", %{})])
      {:ok, session} = AppServer.start_session(ctx.workspace, issue: issue())

      assert {:ok, %{session_id: "ses_1", total_tokens: 0}} = AppServer.run_turn(session, "x", issue(), [])
      assert hd(trace(ctx)) == "ARGV=run --standalone --archived --auto --format json"
      AppServer.stop_session(session)

      # A harness the file gives no command: nothing to run.
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.workspace_root, agent_kind: "codex")
      {:ok, session} = AppServer.start_session(ctx.workspace, issue: issue())
      assert AppServer.run_turn(session, "x", issue(), []) == {:error, :empty_agent_command}
      AppServer.stop_session(session)
    end

    test "an error event fails the turn with its type and message", ctx do
      write_fake!(ctx, [event("error", %{"error" => %{"type" => "provider.no-route", "message" => "Model unavailable: opencode-go/kimi-k3"}})], 1)
      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: run(ctx), issue: issue())

      assert AppServer.run_turn(session, "Do the work", issue(), []) ==
               {:error, {:turn_failed, "provider.no-route: Model unavailable: opencode-go/kimi-k3"}}

      # A model that stays unavailable is asked for again three times, then is the answer.
      assert ctx |> trace() |> Enum.count(&String.starts_with?(&1, "ARGV=")) == 4

      AppServer.stop_session(session)
    end

    test "a first turn that finds no model catalog yet is started again", ctx do
      write_fake!(ctx, [])
      no_route = event("error", %{"error" => %{"type" => "provider.no-route", "message" => "Model unavailable: opencode-go/kimi-k3"}})
      finish = step_finish("stop", %{"input" => 5, "output" => 1})

      File.write!(ctx.fake, """
      #!/bin/sh
      cat > /dev/null
      echo "ARGV=$*" >> "#{ctx.trace}"
      if [ "$(grep -c ARGV= "#{ctx.trace}")" -lt 3 ]; then
        echo '#{no_route}'
        exit 1
      fi
      echo '#{event("text", %{"part" => %{"type" => "text", "text" => "Done"}})}'
      echo '#{finish}'
      """)

      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: run(ctx), issue: issue())

      assert {:ok, %{input_tokens: 5, output_tokens: 1}} = AppServer.run_turn(session, "Do the work", issue(), [])
      assert ctx |> trace() |> length() == 3

      AppServer.stop_session(session)
    end

    test "a later turn of a session whose model is unavailable is not started again", ctx do
      write_fake!(ctx, [event("error", %{"error" => %{"type" => "provider.no-route", "message" => "Model unavailable: opencode-go/kimi-k3"}})], 1)
      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: run(ctx), issue: issue())

      result = AppServer.run_turn(session, "Go on", issue(), resume_session_id: "ses_1")
      assert {:error, {:turn_failed, "provider.no-route" <> _rest}} = result
      assert ctx |> trace() |> Enum.count(&String.starts_with?(&1, "ARGV=")) == 1

      AppServer.stop_session(session)
    end

    test "a run's effort is not passed on, and the log says so", ctx do
      write_fake!(ctx, [step_finish("stop", %{"input" => 1, "output" => 1})])
      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: %{run(ctx) | effort: "high"}, issue: issue())

      turn = fn -> assert {:ok, _result} = AppServer.run_turn(session, "Do the work", issue(), []) end
      log = ExUnit.CaptureLog.capture_log(turn)

      assert log =~ "A run's effort is not applied on the opencode harness effort=high"
      refute Enum.any?(trace(ctx), &(&1 =~ "high"))

      AppServer.stop_session(session)
    end

    test "a missing provider key fails the turn before opencode starts", ctx do
      write_fake!(ctx, [])
      System.delete_env("OPENCODE_API_KEY")
      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: run(ctx), issue: issue())

      log =
        capture_log(fn ->
          assert AppServer.run_turn(session, "x", issue(), []) ==
                   {:error, {:missing_provider_env, "OPENCODE_API_KEY", :implementation}}
        end)

      assert log =~ "OpenCode Go run cannot start: OPENCODE_API_KEY is not set run_kind=implementation"
      refute File.exists?(ctx.trace)
      AppServer.stop_session(session)
    end

    test "an empty command, or a sandbox that is not there, is an error", ctx do
      write_fake!(ctx, [])
      {:ok, session} = AppServer.start_session(ctx.workspace, run_profile: run(ctx), issue: issue())
      settings = Config.for_run(Config.settings!(), run(ctx))

      blank = %{settings | execution: %{settings.execution | command: "  "}}
      assert AppServer.run_turn(session, "x", issue(), settings: blank) == {:error, :empty_agent_command}

      Application.put_env(:symphony_elixir, :opencode_sandbox_opts, os_type: {:unix, :darwin}, executable: Path.join(ctx.root, "missing"))

      assert {:error, {:dev_server_sandbox_unavailable, {:not_found, _path}}} =
               AppServer.run_turn(session, "x", issue(), [])

      AppServer.stop_session(session)
    end
  end

  describe "start_session/2" do
    test "starts on this host only, in a workspace under the root", ctx do
      write_fake!(ctx, [])

      assert AppServer.start_session(ctx.workspace, worker_host: "worker-1") ==
               {:error, {:opencode_remote_worker_unsupported, "worker-1"}}

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _root}} = AppServer.start_session(ctx.workspace_root)
      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} = AppServer.start_session(ctx.root)

      locked = Path.join(ctx.workspace_root, "locked")
      File.mkdir_p!(Path.join(locked, "inner"))
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, _path, _reason}} = AppServer.start_session(Path.join(locked, "inner"))
    end

    test "a session folder that cannot be made stops the tool session too", ctx do
      write_fake!(ctx, [])
      blocker = Path.join(ctx.root, "blocker")
      File.write!(blocker, "a file where the folder should go")

      assert {:error, {:opencode_session_start_failed, _reason}} =
               AppServer.start_session(ctx.workspace, agent_tmp_dir: blocker, issue: issue())
    end

    test "is the launcher of the opencode harness" do
      assert Launcher.module!("opencode") == AppServer
    end
  end

  describe "parse_event/1" do
    test "reads each event of opencode's stream" do
      assert AppServer.parse_event(event("step_start", %{})) == {:session_started, "ses_1"}
      assert AppServer.parse_event(event("text", %{"part" => %{"text" => "hi"}})) == {:agent_text, "hi"}

      assert AppServer.parse_event(event("tool_use", %{"part" => %{"tool" => "shell", "state" => %{"status" => "error"}}})) ==
               {:multi, [{:tool_use, "shell"}, {:tool_result, "error"}]}

      assert AppServer.parse_event(event("tool_use", %{"part" => %{"tool" => "shell"}})) == {:multi, [{:tool_use, "shell"}, {:tool_result, ""}]}

      usage = %{
        uncached_input_tokens: 3,
        cached_input_tokens: 0,
        cache_creation_input_tokens: 0,
        output_tokens: 0
      }

      assert AppServer.parse_event(step_finish("tool-calls", %{"input" => 3, "output" => "x"})) == {:token_usage_delta, usage}

      assert AppServer.parse_event(step_finish("length", nil)) ==
               {:multi, [{:token_usage_delta, %{}}, {:turn_completed, %{}}]}

      assert AppServer.parse_event(event("error", %{"error" => %{"message" => "boom"}})) == {:turn_failed, "boom"}
      assert AppServer.parse_event(event("error", %{"error" => "boom"})) == {:turn_failed, ~s("boom")}
    end

    test "a line that is no event is kept as output" do
      assert AppServer.parse_event("/bin/sh: not permitted") == {:malformed, "/bin/sh: not permitted"}
      assert AppServer.parse_event(~s({"type":"mystery"})) == {:malformed, ~s({"type":"mystery"})}
      assert AppServer.parse_event(~s({"type":"text","part":{}})) == {:malformed, ~s({"type":"text","part":{}})}
      assert AppServer.parse_event(~s({"no":"type"})) == {:malformed, ~s({"no":"type"})}
    end
  end

  describe "the session's config and network" do
    test "holds Symphony's tools and the MCP servers declared for this harness", ctx do
      write_fake!(ctx, [])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: ctx.workspace_root,
        agent_kind: "opencode",
        agent_command: ctx.fake,
        agent_mcp: %{
          servers: %{
            "docs" => %{transport: "http", url: "https://docs.example/mcp", headers: %{"A" => "b"}, harnesses: ["opencode"]},
            "tool" => %{transport: "stdio", command: "tool", args: ["--x"], env: %{"K" => "v"}, harnesses: ["opencode"]},
            "claude-only" => %{transport: "stdio", command: "c", harnesses: ["claude"]}
          }
        },
        agent_network_access: %{mode: "allowlist", allowed_domains: ["example.org"], denied_domains: ["models.dev"]}
      )

      settings = Config.settings!()
      config = AppServer.config(settings, %{id: "s1", socket_path: "/tmp/s/mcp.sock", shim_path: "/tmp/shim", token: "t"})

      assert config["mcp"]["servers"]["docs"] == %{"type" => "remote", "url" => "https://docs.example/mcp", "headers" => %{"A" => "b"}, "enabled" => true}
      assert config["mcp"]["servers"]["tool"] == %{"type" => "local", "command" => ["tool", "--x"], "environment" => %{"K" => "v"}, "enabled" => true}
      assert %{"type" => "local", "command" => [_shim | _args], "environment" => %{"SYMPHONY_MCP_SESSION_TOKEN" => "t"}} = config["mcp"]["servers"]["symphony"]
      refute Map.has_key?(config["mcp"]["servers"], "claude-only")
      refute Map.has_key?(config, "small_model")

      # The run's small model, as OpenCode names a model.
      run = Config.run(settings, :implementation)
      assert AppServer.config(settings, %{id: "s1", socket_path: "/tmp/s/mcp.sock", shim_path: "/tmp/shim", token: "t"}, run)["small_model"] == "opencode-go/#{run.small_model}"

      domains = AppServer.allowed_domains(settings)
      assert "opencode.ai" in domains
      assert "example.org" in domains
      refute "models.dev" in domains
    end
  end
end
