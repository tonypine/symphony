defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defp base_deps(overrides \\ %{}) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        init: fn _args -> {:ok, "Wrote symphony.yml"} end,
        set_symphony_file_path: fn _path -> :ok end,
        set_state_root: fn _path -> :ok end,
        set_state_root_from_env: fn -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_logs_root_from_env: fn -> :ok end,
        set_server_host_override: fn _host -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end,
        run_one_shot: fn _identifier, _opts -> {:ok, %{}} end,
        control_url: fn -> "http://127.0.0.1:4000" end,
        run_dashboard: fn _url -> :ok end
      },
      overrides
    )
  end

  test "legacy acknowledgement flag is silently accepted for backward compatibility" do
    assert :ok = CLI.evaluate([@ack_flag], base_deps())
  end

  test "rejects unknown positional arguments" do
    assert {:error, message} = CLI.evaluate(["WORKFLOW.md"], base_deps())
    assert message =~ "Usage: symphony"
  end

  test "init subcommand skips runtime startup" do
    parent = self()

    deps =
      base_deps(%{
        init: fn args ->
          send(parent, {:init, args})
          {:ok, "Wrote /tmp/repo/symphony.yml"}
        end,
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    output =
      capture_io(fn ->
        assert {:halt, 0} = CLI.evaluate(["init", "--force"], deps)
      end)

    assert output == "Wrote /tmp/repo/symphony.yml\n"
    assert_received {:init, ["--force"]}
    refute_received :file_checked
    refute_received :started
  end

  test "surfaces init errors verbatim without starting the runtime" do
    parent = self()

    deps =
      base_deps(%{
        init: fn _args -> {:error, "symphony.yml already exists"} end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, "symphony.yml already exists"} = CLI.evaluate(["init"], deps)
    refute_received :started
  end

  test "runs one-shot mode with issue identifier and parsed options" do
    parent = self()

    deps =
      base_deps(%{
        run_one_shot: fn identifier, opts ->
          send(parent, {:run_one_shot, identifier, opts})
          {:ok, %{run_id: "run-1"}}
        end
      })

    assert {:halt, 0} = CLI.evaluate(["run", "ACME-3603", "--timeout", "30m", "--no-retry"], deps)
    assert_received {:run_one_shot, "ACME-3603", opts}
    assert opts[:timeout_ms] == 1_800_000
    assert opts[:no_retry] == true
  end

  test "one-shot mode maps failure, config, and timeout outcomes to documented exit codes" do
    assert {:error, _message, 1} =
             CLI.evaluate(
               ["run", "ACME-3603"],
               base_deps(%{run_one_shot: fn _identifier, _opts -> {:error, :boom} end})
             )

    assert {:error, _message, 2} =
             CLI.evaluate(
               ["run", "ACME-3603"],
               base_deps(%{run_one_shot: fn _identifier, _opts -> {:config_error, :bad_config} end})
             )

    assert {:halt, 124} =
             CLI.evaluate(
               ["run", "ACME-3603"],
               base_deps(%{run_one_shot: fn _identifier, _opts -> {:timeout, :timeout_exceeded} end})
             )
  end

  test "one-shot mode returns config error code for bad timeout syntax" do
    assert {:error, message, 2} = CLI.evaluate(["run", "ACME-3603", "--timeout", "later"], base_deps())
    assert message =~ "Invalid --timeout"
  end

  test "defaults to ./symphony.yml when --config is omitted" do
    parent = self()
    expected_path = Path.expand("symphony.yml")

    deps =
      base_deps(%{
        file_regular?: fn path ->
          send(parent, {:file_checked, path})
          true
        end,
        set_symphony_file_path: fn path ->
          send(parent, {:symphony_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([], deps)
    assert_received {:file_checked, ^expected_path}
    assert_received {:symphony_set, ^expected_path}
  end

  test "uses an explicit symphony config path override when provided" do
    parent = self()
    config_path = "tmp/custom/symphony.claude.yml"
    expanded_config_path = Path.expand(config_path)

    deps =
      base_deps(%{
        file_regular?: fn path ->
          send(parent, {:file_checked, path})
          path == expanded_config_path
        end,
        set_symphony_file_path: fn path ->
          send(parent, {:symphony_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["--config", config_path], deps)
    assert_received {:file_checked, ^expanded_config_path}
    assert_received {:symphony_set, ^expanded_config_path}
  end

  test "returns not found when the symphony config does not exist" do
    deps = base_deps(%{file_regular?: fn _path -> false end})

    assert {:error, message} = CLI.evaluate(["--config", "missing.yml"], deps)
    assert message =~ "Symphony config file not found:"
  end

  test "returns not found when the default symphony.yml is missing" do
    deps = base_deps(%{file_regular?: fn _path -> false end})

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Symphony config file not found:"
    assert message =~ "symphony.yml"
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["--logs-root", "tmp/custom-logs"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "accepts --state-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["--state-root", "tmp/custom-state"], deps)
    assert_received {:state_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-state")
  end

  test "configure applies runtime inputs without starting the application" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.configure(["--state-root", "tmp/configure-state"], deps)
    assert_received {:state_root, expanded_path}
    assert expanded_path == Path.expand("tmp/configure-state")
    refute_received :started
  end

  test "dashboard draws from the running Symphony's control URL without loading config" do
    parent = self()

    deps =
      base_deps(%{
        file_regular?: fn _path -> flunk("dashboard must not read symphony.yml") end,
        control_url: fn ->
          send(parent, :resolved_control_url)
          "http://127.0.0.1:4555/"
        end,
        run_dashboard: fn url_source ->
          send(parent, {:dashboard, url_source})
          :ok
        end
      })

    # Without --url the control URL is resolved on each poll, not once at startup.
    assert {:halt, 0} = CLI.evaluate(["dashboard"], deps)
    assert_received {:dashboard, url_source}
    refute_received :resolved_control_url
    assert url_source.() == "http://127.0.0.1:4555"
    assert_received :resolved_control_url
    assert url_source.() == "http://127.0.0.1:4555"
    assert_received :resolved_control_url

    assert {:halt, 0} = CLI.evaluate(["dashboard", "--url", "http://127.0.0.1:4777/"], deps)
    assert_received {:dashboard, url_source}
    assert url_source.() == "http://127.0.0.1:4777"
    refute_received :resolved_control_url
  end

  test "dashboard rejects unknown arguments with its usage" do
    assert {:error, "Usage: symphony dashboard [--url <control-url>]"} =
             CLI.evaluate(["dashboard", "--port", "4000"], base_deps())

    assert {:error, "Usage: symphony dashboard" <> _} = CLI.evaluate(["dashboard", "extra"], base_deps())
  end

  test "maybe_configure_burrito_runtime is a no-op outside Burrito" do
    assert :ok = CLI.maybe_configure_burrito_runtime()
  end

  test "burrito_args reads the wrapper's plain arguments only inside a Burrito binary" do
    assert CLI.burrito_args(nil, [~c"--help"]) == :not_in_burrito
    assert CLI.burrito_args("", [~c"--help"]) == :not_in_burrito

    assert CLI.burrito_args("/Applications/Symphony.app/Contents/Resources/symphony", [~c"check", ~c"--config", ~c"s.yml"]) ==
             ["check", "--config", "s.yml"]
  end

  test "reads root env overrides before applying flag overrides" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root_from_env: fn ->
          send(parent, :state_root_from_env)
          :ok
        end,
        set_logs_root_from_env: fn ->
          send(parent, :logs_root_from_env)
          :ok
        end,
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end,
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end
      })

    assert :ok =
             CLI.evaluate(
               ["--state-root", "tmp/custom-state", "--logs-root", "tmp/custom-logs"],
               deps
             )

    assert_receive :state_root_from_env
    assert_receive :logs_root_from_env
    assert_receive {:state_root, state_root}
    assert_receive {:logs_root, logs_root}
    assert state_root == Path.expand("tmp/custom-state")
    assert logs_root == Path.expand("tmp/custom-logs")
  end

  test "accepts --host and passes it to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_server_host_override: fn host ->
          send(parent, {:host, host})
          :ok
        end
      })

    assert :ok = CLI.evaluate(["--host", "0.0.0.0"], deps)
    assert_received {:host, "0.0.0.0"}
  end

  test "returns startup error when app cannot start" do
    deps = base_deps(%{ensure_all_started: fn -> {:error, :boom} end})

    assert {:error, message} = CLI.evaluate([], deps)
    assert message =~ "Failed to start Symphony"
    assert message =~ ":boom"
  end

  test "returns ok when symphony.yml exists and the app starts" do
    assert :ok = CLI.evaluate([], base_deps())
  end

  test "workflow preview renders the prompt to stdout" do
    path = Path.join(System.tmp_dir!(), "cli_preview_#{System.unique_integer([:positive])}.md")
    File.write!(path, "---\nprompts: {}\n---\nYou are working on `{{ issue.identifier }}`\n")
    on_exit(fn -> File.rm_rf(path) end)

    output =
      capture_io(fn ->
        assert {:halt, 0} = CLI.evaluate(["workflow", "preview", "--file", path], base_deps())
      end)

    assert output =~ "Symphony runtime context:"
    assert output =~ "You are working on `ABC-123`"
  end

  test "workflow preview reports a friendly error for a missing file" do
    assert {:error, message} =
             CLI.evaluate(["workflow", "preview", "--file", "/no/such.md"], base_deps())

    assert message =~ "/no/such.md"
    assert message =~ "no such file or directory"
  end

  test "workflow without a known subcommand returns a usage hint, not a service start" do
    assert {:error, message} = CLI.evaluate(["workflow"], base_deps())
    assert message =~ "symphony workflow preview"

    assert {:error, message} = CLI.evaluate(["workflow", "bogus"], base_deps())
    assert message =~ "symphony workflow preview"
  end
end
