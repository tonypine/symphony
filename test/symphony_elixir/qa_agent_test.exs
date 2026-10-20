defmodule SymphonyElixir.QaAgentTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AgentSandboxConfig
  alias SymphonyElixir.LeftoverProcesses.Table
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.{Report, Selection}
  alias SymphonyElixir.QaAndroid.Driver, as: AndroidDriver
  alias SymphonyElixir.QaDriver.DevServerLease
  alias SymphonyElixir.SelfHeal
  alias SymphonyElixir.Verification

  @sha "0123456789abcdef0123456789abcdef01234567"
  @env_keys [
    :qa_test_recipient,
    :qa_test_start_result,
    :qa_test_messages,
    :qa_test_turn_result,
    :qa_test_turn_results,
    :qa_test_dev_server_result
  ]

  defmodule FakeSession do
    def start_session(workspace, opts) do
      send(recipient(), {:qa_session_started, workspace, opts})

      case Application.get_env(:symphony_elixir, :qa_test_start_result) do
        nil -> {:ok, %{workspace: workspace}}
        result -> result
      end
    end

    def run_turn(session, prompt, issue, opts) do
      send(recipient(), {:qa_turn, session, prompt, issue, opts})
      on_message = Keyword.fetch!(opts, :on_message)
      Enum.each(Application.get_env(:symphony_elixir, :qa_test_messages, []), on_message)

      # `:qa_test_turn_results` answers successive turns; the last answer repeats.
      case Application.get_env(:symphony_elixir, :qa_test_turn_results) do
        [result | [_ | _] = rest] ->
          Application.put_env(:symphony_elixir, :qa_test_turn_results, rest)
          result

        [result] ->
          result

        nil ->
          Application.get_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: pass_json()}})
      end
    end

    def stop_session(session) do
      send(recipient(), {:qa_session_stopped, session})
      :ok
    end

    def pass_json do
      Jason.encode!(%{
        verdict: "pass",
        summary: "The CLI behaves as described.",
        steps: [%{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}]
      })
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_test_recipient)
  end

  # Writes a fixture under the pass's `$TMPDIR` and hands it to `qa_put_file`, as a
  # macos_app QA agent does, then answers like `FakeSession`.
  defmodule PutFileSession do
    defdelegate start_session(workspace, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession

    def run_turn(session, prompt, issue, opts) do
      [tmp_dir] = opts[:extra_env] |> Map.delete("QA_HOST_PORTS") |> Map.values()
      fixture = Path.join(tmp_dir, "symphony.yml")
      File.write!(fixture, "repos: []\n")
      result = SymphonyElixir.QaDriver.call_tool(opts[:qa_driver], "qa_put_file", %{"local_path" => fixture})
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:put_file, tmp_dir, result})
      FakeSession.run_turn(session, prompt, issue, opts)
    end
  end

  # Builds and launches the macos_app and resizes its window for the wide pass, as a
  # macos_app QA agent does, then answers like `FakeSession`.
  defmodule WidePassSession do
    alias SymphonyElixir.QaDriver

    defdelegate start_session(workspace, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession

    def run_turn(session, prompt, issue, opts) do
      driver = opts[:qa_driver]
      {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {:ok, %{"pid" => pid}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
      {:ok, %{"limited" => _limited}} = QaDriver.call_tool(driver, "qa_resize_window", %{"pid" => pid})
      FakeSession.run_turn(session, prompt, issue, opts)
    end
  end

  # Builds and launches the macos_app but never resizes its window, then answers like `FakeSession`.
  defmodule LaunchOnlySession do
    alias SymphonyElixir.QaDriver

    defdelegate start_session(workspace, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession

    def run_turn(session, prompt, issue, opts) do
      driver = opts[:qa_driver]
      {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {:ok, %{"pid" => _pid}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
      FakeSession.run_turn(session, prompt, issue, opts)
    end
  end

  # Builds, launches and checks the macos_app without a wide pass, as a QA agent does for a change
  # with nothing on screen to judge, then answers like `FakeSession`.
  defmodule AppCheckSession do
    alias SymphonyElixir.QaDriver

    defdelegate start_session(workspace, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession

    def run_turn(session, prompt, issue, opts) do
      driver = opts[:qa_driver]
      {:ok, %{"exit_status" => 0}} = QaDriver.call_tool(driver, "qa_build", %{})
      {:ok, %{"pid" => pid}} = QaDriver.call_tool(driver, "qa_launch_app", %{})
      {:ok, %{"healthy" => true}} = QaDriver.call_tool(driver, "qa_check_app", %{"pid" => pid})
      FakeSession.run_turn(session, prompt, issue, opts)
    end
  end

  defmodule AndroidPutFileSession do
    defdelegate start_session(workspace, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession

    def run_turn(session, prompt, issue, opts) do
      [tmp_dir] = Map.values(opts[:extra_env])
      fixture = Path.join(tmp_dir, "rows.csv")
      File.write!(fixture, "date,minutes\n")
      result = AndroidDriver.call_tool(opts[:qa_android_driver], "qa_android_put_file", %{"local_path" => fixture})
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:put_file, tmp_dir, result})
      FakeSession.run_turn(session, prompt, issue, opts)
    end
  end

  # Stands in for `SymphonyElixir.Verification` in web passes.
  defmodule FakeVerification do
    def start_qa_dev_server(issue, run_id, worktree, opts) do
      send(recipient(), {:dev_server_started, issue.identifier, run_id, worktree, opts})

      case Application.get_env(:symphony_elixir, :qa_test_dev_server_result) do
        nil -> {:ok, %{context: %{run_id: run_id}, pid: self(), port: 4321, url: "http://localhost:4321/"}}
        result -> result
      end
    end

    def stop_qa_dev_server(dev_server) do
      send(recipient(), {:dev_server_stopped, dev_server.port})
      :ok
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_test_recipient)
  end

  # Starts `setsid nohup sleep` in the worktree, outside the agent's process group.
  defmodule DetachingSession do
    def start_session(workspace, opts) do
      pid = SymphonyElixir.QaAgentTest.detached_sleep(workspace)
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:detached, pid})
      FakeSession.start_session(workspace, opts)
    end

    defdelegate run_turn(session, prompt, issue, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession
  end

  # Exports the PR to `$TMPDIR/qa/checkout` and starts a detached `sleep` there, outside the
  # worktree, as the TP-413 pass did with `./bin/symphony`.
  defmodule TmpDirDetachingSession do
    def start_session(workspace, opts) do
      tmp_dir = Path.join(Map.fetch!(opts[:extra_env], "TMPDIR"), "qa")
      checkout = Path.join(tmp_dir, "checkout")
      File.mkdir_p!(checkout)
      pid = SymphonyElixir.QaAgentTest.detached_sleep(checkout)
      send(Application.fetch_env!(:symphony_elixir, :qa_test_recipient), {:detached, pid, checkout})
      FakeSession.start_session(workspace, opts)
    end

    defdelegate run_turn(session, prompt, issue, opts), to: FakeSession
    defdelegate stop_session(session), to: FakeSession
  end

  @doc false
  def detached_sleep(cwd) do
    script = ~S"""
    nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!"; exec "sleep", "600"' >/dev/null 2>&1 &
    echo $!
    """

    {pid, 0} = System.cmd("sh", ["-c", script], cd: cwd)
    String.to_integer(String.trim(pid))
  end

  defp base_tmp_dir(base) do
    [tmp_dir] = QaAgent.tmp_dirs(QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha), [base])
    tmp_dir
  end

  # A zombie waiting for init to reap it counts as gone.
  defp running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      {_output, _status} -> false
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :qa_test_recipient, self())

    on_exit(fn ->
      for key <- @env_keys do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-qa",
        identifier: "TP-900",
        title: "Add a check command",
        description: "Adds `symphony check`.",
        state: "Auto Review",
        labels: []
      },
      attrs
    )
  end

  defp playbooks, do: Selection.playbooks(%{playbooks: %{}})

  # A QA host whose build writes the playbook's `build/App.app` and whose screen is `{w, h}`
  # points, 93 pt of its height taken by the menu bar and the Dock; the window reaches at most 1400×900.
  defp wide_pass_host({w, h}) do
    usable = h - 93
    window = %{x: 0, y: 25, w: min(w, 1400), h: min(usable, 900)}
    resized = Jason.encode!(%{ok: true, window: window, screen: %{w: w, h: h}, visible: %{x: 0, y: 25, w: w, h: usable}})

    cmd = fn
      "/bin/sh", ["-c", "make app"], opts ->
        macos = Path.join(opts[:cd], "build/App.app/Contents/MacOS")
        File.mkdir_p!(macos)
        File.write!(Path.join(macos, "App"), "binary")
        {:ok, {"built", 0}}

      "/bin/sh", ["-c", _script, "sh", "App"], _opts ->
        {:ok, {"", 0}}

      "/bin/sh", ["-c", _script, "sh", _build_dir, "build/App.app", dest], _opts ->
        {:ok, {"symphony-qa-app:#{dest}/App.app/Contents/MacOS/App\n", 0}}

      "/usr/bin/plutil", _args, _opts ->
        {:ok, {"App\n", 0}}

      "/fake/helper", ["ax-resize" | _args], _opts ->
        {:ok, {resized, 0}}

      "/fake/helper", ["ax-ping" | _args], _opts ->
        {:ok, {~s({"ok":true,"responding":true,"ms":2}), 0}}
    end

    %{
      cmd: cmd,
      call_helper: cmd,
      helper: fn _dir -> {:ok, "/fake/helper"} end,
      launch: fn _executable, _opts -> {:ok, Port.open({:spawn, "cat"}, [:binary]), System.unique_integer([:positive]) + 100_000} end,
      kill: fn _pid -> :ok end
    }
  end

  # QA driver options for a fake QA VM, another machine than this one, whose run directory is a
  # temporary directory. `host` overrides its functions.
  defp qa_vm_opts(host \\ %{}) do
    run_dir = Path.join(System.tmp_dir!(), "qa-agent-run-#{System.unique_integer([:positive])}")
    cmd = Map.get(host, :cmd, fn _executable, _args, _opts -> {:ok, {"", 0}} end)

    vm = %{
      prepare: fn _operator_home, _canary -> File.mkdir_p!(run_dir) && {:ok, run_dir} end,
      tunnel: fn _ports -> {:ok, Port.open({:spawn, "cat"}, [:binary])} end,
      ship: fn _tar, dest -> File.mkdir_p!(dest) end,
      put: fn local, dir, name ->
        dest = Path.join([dir, "files", name])
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(local, dest)
        {:ok, dest}
      end,
      cleanup: fn dir -> File.rm_rf!(dir) && :ok end,
      kill: fn _pid -> :ok end
    }

    ioreg = fn
      "/usr/sbin/ioreg", _args, _opts -> {:ok, {~s(  "IOPlatformUUID" = "99999999-8888-7777-6666-555544443333"\n), 0}}
      executable, args, opts -> cmd.(executable, args, opts)
    end

    [worker_host: "qa-vm", host: vm |> Map.merge(host) |> Map.put(:cmd, ioreg), local_uuid: fn -> {:ok, "1A2B3C4D-0000-1111-2222-333344445555"} end]
  end

  defp job(attrs \\ %{}) do
    Map.merge(
      %{
        issue: issue(),
        sha: @sha,
        workspace_path: Path.join(System.tmp_dir!(), "qa-agent-test-workspace"),
        worker_host: nil,
        repo_key: "default",
        run_id: "qa-run-1",
        playbooks: playbooks(),
        token_limit: nil
      },
      attrs
    )
  end

  # Records each git call and creates the worktree directory on `worktree add`.
  defp fake_git(overrides \\ %{}) do
    recipient = self()

    fn args, cwd ->
      send(recipient, {:git, args, cwd})

      case {args, overrides} do
        {["worktree", "add", "--detach", path, _sha], %{add_dev_server: result}} ->
          add_unless_dev_server(path, result)

        {["worktree", "add", "--detach", path, _sha], %{add: result}} ->
          File.mkdir_p!(path)
          result

        {["worktree", "add", "--detach", path, _sha], _overrides} ->
          File.mkdir_p!(path)
          {"", 0}

        {["cat-file" | _rest], %{cat_file: result}} ->
          result

        {["fetch" | _rest], %{fetch: fetch}} when is_function(fetch, 0) ->
          fetch.()

        {["fetch" | _rest], %{fetch: result}} ->
          result

        _other ->
          {"", 0}
      end
    end
  end

  defp add_unless_dev_server(path, result) do
    if String.ends_with?(path, "-dev-server") do
      result
    else
      File.mkdir_p!(path)
      {"", 0}
    end
  end

  describe "Selection.decide/4" do
    test "skips an internal lib refactor with no walkthrough or entry-point change" do
      assert {:skip, reason} =
               Selection.decide(issue(), ["lib/symphony_elixir/orchestrator.ex", "lib/symphony_elixir/run_store.ex"], %{playbooks: %{}})

      assert reason =~ "no QA playbook applies"
    end

    test "skips docs-only and test-only changes, including configured skip globs" do
      assert {:skip, reason} = Selection.decide(issue(), ["README.md", "docs/configuration.md", "test/foo_test.exs"], %{})
      assert reason =~ "only changes docs, tests"

      assert {:skip, _reason} = Selection.decide(issue(), ["priv/static/app.css"], %{skip_globs: ["priv/static/**"]})
      assert {:skip, "the PR changes no files"} = Selection.decide(issue(), [], %{})
    end

    test "selects the cli playbook for entry points and for a user walkthrough" do
      for path <- ["bin/symphony", "lib/symphony_elixir/cli.ex", "lib/mix/tasks/symphony.init.ex"] do
        assert {:run, [%{kind: "cli", prompt: prompt}]} = Selection.decide(issue(), [path], %{playbooks: %{}})
        assert prompt =~ "### Playbook: cli"
      end

      walkthrough = issue(%{description: "Intro\n\n## User walkthrough\n\n1. Run `symphony check`."})
      assert Selection.user_walkthrough?(walkthrough)
      refute Selection.user_walkthrough?(issue(%{description: nil}))
      assert {:run, [%{kind: "cli"}]} = Selection.decide(walkthrough, ["lib/symphony_elixir/orchestrator.ex"], %{})
    end

    test "labels skip QA or force a playbook" do
      assert {:skip, "the issue has the `qa:skip` label"} =
               Selection.decide(issue(%{labels: [" QA:Skip "]}), ["lib/symphony_elixir/cli.ex"], %{})

      assert {:run, [%{kind: "cli"}]} = Selection.decide(issue(%{labels: ["qa:cli"]}), ["README.md"], %{})
    end

    test "config overrides built-in paths, disables playbooks and adds new kinds" do
      config = %{
        playbooks: %{
          :cli => %{"paths" => ["scripts/**"]},
          "api" => %{paths: ["api/**"], prompt: "### Playbook: api"},
          "empty" => %{paths: ["x/**"], prompt: "  "},
          "odd" => "not a map"
        }
      }

      assert [%{kind: "cli", paths: ["scripts/**"]}, %{kind: "api", paths: ["api/**"]}] = Selection.playbooks(config)
      assert {:run, [%{kind: "api"}]} = Selection.decide(issue(), ["api/app.js"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["lib/symphony_elixir/cli.ex"], config)

      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false, "paths" => "bin/**"}}})
    end

    test "the macos_app playbook runs only when its build command and app bundle are configured" do
      swift = ["macos/Sources/SymphonyBar/SettingsView.swift"]

      refute Enum.any?(Selection.playbooks(%{playbooks: %{}}), &(&1.kind == "macos_app"))
      assert {:skip, _reason} = Selection.decide(issue(), swift, %{playbooks: %{}})
      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app"}}})

      config = %{
        playbooks: %{
          "macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app", "build_timeout_ms" => 600_000}
        }
      }

      assert {:run, [%{kind: "macos_app", build: "make -C macos app", app: "macos/build/Symphony.app", build_timeout_ms: 600_000, prompt: prompt}]} =
               Selection.decide(issue(), swift, config)

      assert prompt =~ "### Playbook: macos_app"
      assert prompt =~ "wait about 10 seconds"
      assert prompt =~ "qa_permission_missing"

      assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue(%{labels: ["qa:macos_app"]}), ["README.md"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["macos/Tests/SymphonyBarCoreTests/QAModeTests.swift"], config)

      odd_timeout = put_in(config, [:playbooks, "macos_app", "build_timeout_ms"], "soon")
      assert [_cli, %{kind: "macos_app", build_timeout_ms: nil}] = Selection.playbooks(odd_timeout)
    end

    test "a playbook carries the executables its pass needs on the QA host, trimmed and without repeats" do
      config = %{playbooks: %{"macos_app" => %{"build" => "make app", "app" => "A.app", "requires" => [" go ", "pg_ctl", "go", "", 7]}}}
      assert [cli, %{kind: "macos_app", requires: ["go", "pg_ctl"]}] = Selection.playbooks(config)
      refute Map.has_key?(cli, :requires)

      for unset <- [[], "go", nil] do
        assert [_cli, macos_app] = Selection.playbooks(put_in(config, [:playbooks, "macos_app", "requires"], unset))
        refute Map.has_key?(macos_app, :requires)
      end
    end

    test "a change to a playbook's own instructions or to the host driver behind its tools selects that playbook" do
      config = %{playbooks: %{"macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app"}}}

      # TP-1043: the macOS playbook and a tool description changed, with no Swift file, and the
      # ticket's walkthrough asks QA to drive the app.
      walkthrough = issue(%{description: "## User walkthrough\n\n1. On the Add Repo sheet, pick a repository."})
      changed = ["lib/symphony_elixir/codex/dynamic_tool.ex", "priv/qa_playbooks/macos_app.md", "test/support/stubs/gh.py"]
      assert {:run, [%{kind: "cli"}, %{kind: "macos_app"}]} = Selection.decide(walkthrough, changed, config)

      for path <- ["lib/symphony_elixir/qa_driver.ex", "lib/symphony_elixir/qa_driver/host.ex", "priv/qa_driver/Info.plist"] do
        assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue(), [path], config)
      end

      assert {:run, [%{kind: "cli"}]} = Selection.decide(issue(), ["priv/qa_playbooks/cli.md", "lib/symphony_elixir/qa_agent.ex"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["priv/qa_playbooks/macos_app.md", "lib/symphony_elixir/qa_agent.ex"], %{})

      android = %{"build" => "./gradlew assembleDebug", "apk_path" => "app.apk", "application_ids" => ["com.example.app"]}
      android_config = %{android: %{avd: "Pixel"}, playbooks: %{"android_app" => android}}

      for path <- ["priv/qa_playbooks/android_app.md", "lib/symphony_elixir/qa_android/driver.ex"] do
        assert {:run, [%{kind: "android_app"}]} = Selection.decide(issue(), [path, "lib/symphony_elixir/qa_agent.ex"], android_config)
      end

      assert {:run, [%{kind: "web"}]} =
               Selection.decide(issue(), ["priv/qa_playbooks/web.md", "lib/symphony_elixir/qa_agent.ex"], %{}, dev_server?: true)

      # A kind from config has no instructions file: it triggers on its `paths` or its label only.
      assert [_cli, %{kind: "api", paths: []}] = Selection.playbooks(%{playbooks: %{"api" => %{"prompt" => "### Playbook: api"}}})
    end

    test "the android_app playbook runs only when the repo names its build, APK and app IDs and the host names an AVD" do
      kotlin = ["app/src/main/java/com/example/app/LoginActivity.kt"]
      android = %{"build" => "./gradlew :app:assembleDebug", "apk_path" => "app/build/outputs/apk/debug/app-debug.apk", "application_ids" => ["com.example.app"]}
      config = %{android: %{avd: "Pixel_3a_API_34"}, playbooks: %{"android_app" => android}}

      assert {:run, [%{kind: "android_app", prompt: prompt} = playbook]} = Selection.decide(issue(), kotlin, config)
      # `apk_path` alone is a one-item `apk_paths`.
      assert %{build: "./gradlew :app:assembleDebug", apk_paths: ["app/build/outputs/apk/debug/app-debug.apk"], application_ids: ["com.example.app"]} = playbook
      assert prompt =~ "### Playbook: android_app"
      assert prompt =~ "qa_android_unavailable"
      assert prompt =~ "qa_app_exited"
      # Import steps get their file from qa_android_put_file.
      assert prompt =~ "put it in\n   `Download/` with `qa_android_put_file`"

      for path <- ["app/src/main/AndroidManifest.xml", "app/src/main/res/layout/login.xml", "app/build.gradle.kts", "build.gradle", "lib/src/main/java/Util.java"] do
        assert {:run, [%{kind: "android_app"}]} = Selection.decide(issue(), [path], config)
      end

      assert {:run, [%{kind: "android_app"}]} = Selection.decide(issue(%{labels: ["qa:android_app"]}), ["README.md"], config)

      for path <- ["app/src/test/java/com/example/app/LoginTest.kt", "app/src/androidTest/java/com/example/app/LoginUiTest.kt"] do
        assert {:skip, reason} = Selection.decide(issue(), [path], config)
        assert reason =~ "only changes docs, tests"
      end

      assert {:skip, _reason} = Selection.decide(issue(), kotlin, %{android: %{avd: "Pixel_3a_API_34"}, playbooks: %{}})
      assert {:skip, _reason} = Selection.decide(issue(), kotlin, %{playbooks: %{"android_app" => android}})

      for android_settings <- [nil, %{avd: nil}, %{avd: " "}] do
        assert {:skip, _reason} = Selection.decide(issue(), kotlin, %{config | android: android_settings})
      end

      for missing <- [
            Map.delete(android, "build"),
            Map.put(android, "apk_path", " "),
            android |> Map.delete("apk_path") |> Map.put("apk_paths", []),
            android |> Map.delete("apk_path") |> Map.put("apk_paths", "app.apk"),
            android |> Map.delete("apk_path") |> Map.put("apk_paths", [" ", 7]),
            Map.put(android, "application_ids", []),
            Map.put(android, "application_ids", "com.example.app"),
            Map.put(android, "application_ids", [" ", 7])
          ] do
        assert [_cli] = Selection.playbooks(%{config | playbooks: %{"android_app" => missing}})
      end

      assert [_cli, %{kind: "android_app", application_ids: ["com.example.app"]}] =
               Selection.playbooks(%{config | playbooks: %{android_app: %{android | "application_ids" => ["com.example.app", " ", 7]}}})

      # `apk_paths` lists more than one APK, and `apk_path` joins it first, once.
      catalog = "app-catalog/build/outputs/apk/debug/app-catalog-debug.apk"
      apk = android["apk_path"]

      for {settings, apk_paths} <- [
            {android |> Map.delete("apk_path") |> Map.put("apk_paths", [apk, catalog]), [apk, catalog]},
            {Map.put(android, "apk_paths", [catalog, apk, " ", 7]), [apk, catalog]}
          ] do
        playbooks = Selection.playbooks(%{config | playbooks: %{"android_app" => settings}})
        assert [_cli, %{kind: "android_app", apk_paths: ^apk_paths}] = playbooks
      end
    end

    test "the web playbook runs only when the verification dev server is configured" do
      dashboard = ["lib/symphony_elixir_web/live/dashboard_live.ex", "priv/static/dashboard.css"]

      refute Enum.any?(Selection.playbooks(%{playbooks: %{}}), &(&1.kind == "web"))
      assert {:skip, _reason} = Selection.decide(issue(), dashboard, %{playbooks: %{}})

      assert {:run, [%{kind: "web", prompt: prompt} = web]} = Selection.decide(issue(), dashboard, %{playbooks: %{}}, dev_server?: true)
      refute Map.has_key?(web, :browser_mcp)
      assert prompt =~ "### Playbook: web"
      assert prompt =~ "browser_console_messages"
      assert prompt =~ "qa-evidence/console.md"

      for path <- ["lib/my_app_web.ex", "assets/js/app.tsx", "src/components/Card.vue"] do
        assert {:run, [%{kind: "web"}]} = Selection.decide(issue(), [path], %{}, dev_server?: true)
      end

      assert {:run, [%{kind: "web"}]} = Selection.decide(issue(%{labels: ["qa:web"]}), ["README.md"], %{}, dev_server?: true)

      glance = %{playbooks: %{"web" => %{browser_mcp: %{command: "glance-mcp", args: ["--headless"]}}}}

      assert [_cli, %{kind: "web", browser_mcp: %{"command" => "glance-mcp", "args" => ["--headless"]}}] =
               Selection.playbooks(glance, dev_server?: true)

      assert [_cli] = Selection.playbooks(%{playbooks: %{"web" => %{"enabled" => false}}}, dev_server?: true)
    end

    test "a playbook with dev_server: true carries it and runs only when the verification dev server is configured" do
      server = %{"paths" => ["server/**"], "prompt" => "### Playbook: server", "dev_server" => true}
      api = %{"paths" => ["api/**"], "prompt" => "### Playbook: api"}
      config = %{playbooks: %{"cli" => %{"enabled" => false}, "server" => server, "api" => api}}

      assert {:run, [%{kind: "server", dev_server: true}]} = Selection.decide(issue(), ["server/main.go"], config, dev_server?: true)
      assert {:run, [%{kind: "api"} = api_playbook]} = Selection.decide(issue(), ["api/a.go"], config, dev_server?: true)
      refute Map.has_key?(api_playbook, :dev_server)
      assert {:run, [%{kind: "web", dev_server: true}]} = Selection.decide(issue(), ["assets/app.css"], config, dev_server?: true)

      assert {:skip, _reason} = Selection.decide(issue(), ["server/main.go"], config)
      assert {"server", "needs `verification.dev_server`"} in Selection.unavailable(config)
      refute Enum.any?(Selection.unavailable(config, dev_server?: true), &(elem(&1, 0) == "server"))

      # A start command with verification off starts no server on this host, so the kind stays off.
      command_only = [dev_server?: false, dev_server_command?: true]
      assert {:skip, _reason} = Selection.decide(issue(), ["server/main.go"], config, command_only)
      assert {"server", "needs `verification.enabled`"} in Selection.unavailable(config, command_only)
      assert {"web", "needs `verification.enabled`"} in Selection.unavailable(config, command_only)
    end

    test "a macos_app playbook with dev_server: true needs only verification.dev_server, with or without a worker_host" do
      macos_app = %{"build" => "make app", "app" => "build/App.app", "dev_server" => true}
      config = %{worker_host: "qa-vm", playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}}
      command_only = [dev_server?: false, dev_server_command?: true]

      assert [%{kind: "macos_app", dev_server: true}] = Selection.playbooks(config, command_only)
      refute Enum.any?(Selection.unavailable(config, command_only), &(elem(&1, 0) == "macos_app"))
      assert {"web", "needs `verification.enabled`"} in Selection.unavailable(config, command_only)
      assert {"macos_app", "needs `verification.dev_server`"} in Selection.unavailable(config)

      # Without a worker_host it still never runs its server on this host, so it does not need
      # verification.enabled either: the pass runs, and the QA driver's tools say to set up the QA VM.
      assert [%{kind: "macos_app", dev_server: true}] = Selection.playbooks(%{config | worker_host: nil}, command_only)
      assert [%{kind: "macos_app"}, %{kind: "web"}] = Selection.playbooks(%{config | worker_host: nil}, dev_server?: true)
    end

    test "unavailable/2 says why each playbook is off" do
      assert Selection.unavailable(%{playbooks: %{}}) == [
               {"macos_app", "needs `auto_review.playbooks.macos_app.build`, `auto_review.playbooks.macos_app.app`"},
               {"android_app",
                "needs `auto_review.playbooks.android_app.build`, `auto_review.playbooks.android_app.apk_path` or `auto_review.playbooks.android_app.apk_paths`, " <>
                  "`auto_review.playbooks.android_app.application_ids`, `auto_review.android.avd`"},
               {"web", "needs `verification.dev_server`"}
             ]

      config = %{
        android: %{avd: "Pixel_3a_API_34"},
        playbooks: %{
          "cli" => %{"enabled" => false},
          "macos_app" => %{"build" => "make app", "app" => "build/App.app"},
          "android_app" => %{"build" => "./gradlew assembleDebug", "apk_path" => "app.apk", "application_ids" => ["com.example.app"]},
          "api" => %{"paths" => ["api/**"]}
        }
      }

      assert Selection.unavailable(config, dev_server?: true) == [{"cli", "`enabled: false`"}, {"api", "no `prompt`"}]
      assert config |> Selection.playbooks(dev_server?: true) |> Enum.map(& &1.kind) == ["macos_app", "android_app", "web"]
      assert Selection.unavailable(%{config | android: nil}, dev_server?: true) -- [{"cli", "`enabled: false`"}, {"api", "no `prompt`"}] == [{"android_app", "needs `auto_review.android.avd`"}]
    end

    test "glob matching keeps single stars inside one directory" do
      assert Selection.glob_match?("lib/mix/tasks/a/b.ex", "lib/mix/tasks/**")
      assert Selection.glob_match?("a.md", "**/*.md")
      assert Selection.glob_match?("docs/x/a.md", "**/*.md")
      refute Selection.glob_match?("lib/a/b.ex", "lib/*.ex")
      assert Selection.glob_match?("lib/a.ex", "lib/?.ex")
      refute Selection.glob_match?("lib/a+b.ex", "lib/a.b.ex")
    end
  end

  describe "usage_limit/1 and blocked_reason/1" do
    test "usage_limit/1 reads the hold info of a usage limit or an unreachable model API" do
      info = %{provider: "anthropic", scope: :all}

      assert QaAgent.usage_limit({:qa_agent_failed, {:usage_limited, info}}) == info
      assert QaAgent.usage_limit({:model_api_unreachable, info}) == info
      assert QaAgent.usage_limit({:qa_agent_failed, :timeout}) == nil
    end

    test "blocked_reason/1 says what blocked QA, one line per error" do
      reasons =
        Enum.map(
          [
            {:qa_token_limit, 9, 5},
            {:remote_worker_unsupported, "worker-1"},
            {:qa_dev_server_failed, {:verification_failed, :health_timeout}},
            {:qa_dev_server_failed, {:verification_failed, {:dev_server_sandbox_unconfined, :tcp_bind_allowed}}},
            {:qa_dev_server_failed, {:verification_failed, {:dev_server_not_on_socket, "/tmp/serve.sock"}}},
            {:qa_dev_server_failed, :eaddrinuse},
            {:qa_dev_server_failed, {:dev_server_build_failed, 3}, "go: missing module"},
            {:qa_dev_server_failed, {:dev_server_build_failed, :timeout}, "build_cmd did not finish within 15 minutes"},
            {:qa_dev_server_failed, {:dev_server_exit, 1}, ""},
            {:qa_dev_server_failed, {:dev_server_unreachable, "ssh: Connection refused"}, ""},
            {:qa_dev_server_failed, {:dev_server_port_busy, 8090, 6557, "TP-1124"}, ""},
            {:qa_dev_server_failed, {:dev_server_port_busy, 8090, nil, nil}, ""},
            {:qa_host_tunnel_failed, "ssh exited with status 255"},
            {:qa_host_missing_tool, ["go", "pg_ctl"]},
            {:qa_host_tool_check_failed, "exit status 255: Connection refused"},
            {:qa_browser_mcp_unavailable, :no_npx},
            {:qa_browser_mcp_unavailable, "@playwright/mcp"},
            {:qa_browser_mcp_invalid, "command is required"},
            {:malformed_qa_response, :no_json},
            {:changed_files_unlisted, {:git_failed, 128, "fatal: bad object"}},
            {:git_failed, 128}
          ],
          &QaAgent.blocked_reason/1
        )

      assert [
               "the QA agent reached the per-issue token limit (9 of 5 tokens)",
               "QA does not run on remote workers yet (worker-1)",
               "the dev server failed its health check" <> _,
               "the dev server did not start: Seatbelt" <> _,
               "the dev server never listened on $SYMPHONY_VERIFICATION_SOCKET (/tmp/serve.sock)" <> _,
               "the dev server did not start: :eaddrinuse",
               "qa_dev_server_failed: the dev server on the QA host failed its build_cmd (exit 3); its last log lines:\ngo: missing module",
               "qa_dev_server_failed: the dev server on the QA host did not finish its build_cmd in time; its last log lines:\n" <> _,
               "qa_dev_server_failed: the dev server on the QA host exited (status 1) before its health check answered 200",
               "qa_dev_server_failed: the dev server on the QA host could not be started over SSH: ssh: Connection refused",
               "qa_dev_server_port_busy: 8090 held by pid 6557 (TP-1124), so the dev server on the QA host did not start",
               "qa_dev_server_port_busy: 8090 held by a process lsof could not name (not a QA pass's server), so the dev server on the QA host did not start",
               "the tunnel that forwards QA_HOST_PORTS" <> _,
               "qa_host_missing_tool: go, pg_ctl: the QA host has no `go`, `pg_ctl` on the build's PATH" <> missing_tool,
               "qa_host_tool_check_failed: could not check the QA host" <> _,
               "`npx` (Node.js) is not on Symphony's PATH" <> _,
               "`@playwright/mcp` is not installed on the Symphony host" <> _,
               "`auto_review.playbooks.web.browser_mcp` is invalid: command is required",
               "the QA agent's answer could not be read: :no_json",
               "could not list the PR's changed files: " <> _,
               "the QA agent could not finish: {:git_failed, 128}"
             ] = reasons

      assert missing_tool =~ "scripts/qa-vm/provision.sh"
    end
  end

  describe "parse_response/1" do
    test "reads pass, fail and blocked verdicts with steps" do
      assert {:ok, %{verdict: :pass, summary: "The CLI behaves as described.", steps: [step], findings: []}} =
               QaAgent.parse_response("Done.\n```json\n" <> FakeSession.pass_json() <> "\n```")

      assert step == %{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}

      fail = ~s({"verdict":"fail","steps":[{"name":"bad config","status":"fail","details":"exit 0"}]})
      assert {:ok, %{verdict: :fail, summary: "", findings: []} = result} = QaAgent.parse_response(fail)
      assert QaAgent.failure_findings(result) == ["bad config: exit 0"]

      with_findings = ~s({"verdict":"fail","findings":["exit status is 0", " "],"steps":null})
      assert {:ok, %{findings: ["exit status is 0"], steps: []} = result} = QaAgent.parse_response(with_findings)
      assert QaAgent.failure_findings(result) == ["exit status is 0"]

      assert {:ok, %{verdict: :blocked, reason: "mix is missing"} = blocked} = QaAgent.parse_response(~s({"verdict":"blocked","reason":" mix is missing "}))
      refute Map.has_key?(blocked, :needs_person)

      assert {:ok, %{verdict: :blocked, reason: "no API key", needs_person: true}} =
               QaAgent.parse_response(~s({"verdict":"blocked","reason":"no API key","needs_person":true}))

      assert {:ok, blocked} = QaAgent.parse_response(~s({"verdict":"blocked","reason":"no simulator","needs_person":"yes"}))
      refute Map.has_key?(blocked, :needs_person)

      assert {:ok, %{verdict: :blocked, needs_dev_server: true} = blocked} =
               QaAgent.parse_response(~s({"verdict":"blocked","reason":"no hub running","needs_dev_server":true}))

      refute Map.has_key?(blocked, :needs_person)

      assert {:ok, blocked} = QaAgent.parse_response(~s({"verdict":"blocked","reason":"no hub running","needs_dev_server":"yes"}))
      refute Map.has_key?(blocked, :needs_dev_server)
    end

    test "reads a pass with nothing on screen to judge, and ignores any other scope" do
      assert {:ok, %{verdict: :pass, scope: :none, reason: "the change touches no screen"}} =
               QaAgent.parse_response(~s({"verdict":"pass","scope":" None ","reason":"the change touches no screen"}))

      for scope <- [~s("journeys"), ~s(""), "true", "null"] do
        assert {:ok, pass} = QaAgent.parse_response(~s({"verdict":"pass","scope":#{scope}}))
        refute Map.has_key?(pass, :scope)
      end
    end

    test "keeps a covering ticket the blocked answer names, and drops anything that is not an identifier" do
      assert {:ok, %{verdict: :blocked, covered_by: "TP-716"} = blocked} =
               QaAgent.parse_response(~s({"verdict":"blocked","reason":"no fake gh","covered_by":" tp-716 "}))

      refute Map.has_key?(blocked, :needs_person)

      for covered_by <- [~s("TP-716 and TP-694"), ~s(""), "716", "null"] do
        assert {:ok, blocked} = QaAgent.parse_response(~s({"verdict":"blocked","reason":"no fake gh","covered_by":#{covered_by}}))
        refute Map.has_key?(blocked, :covered_by)
      end
    end

    test "marks the steps a parent walkthrough reports for its verification checklist" do
      text =
        ~s({"verdict":"pass","steps":[{"name":"UC1","status":"pass","checklist":true},{"name":"Open Settings","status":"pass","checklist":"yes"},{"name":"Quit","status":"pass"}]})

      assert {:ok, %{steps: [row, walkthrough, plain]}} = QaAgent.parse_response(text)
      assert row == %{name: "UC1", status: "pass", details: "", evidence: [], checklist: true}
      refute Map.has_key?(walkthrough, :checklist)
      refute Map.has_key?(plain, :checklist)
    end

    test "keeps the gap label and the blockers a failing step names" do
      text =
        Jason.encode!(%{
          "verdict" => "fail",
          "steps" => [
            %{"name" => "Make the tool", "status" => "fail", "gap" => " G1 "},
            %{"name" => "Check with it", "status" => "fail", "gap" => "G2", "blocked_by" => [" G1 ", "TP-824", "", 7]},
            %{"name" => "One blocker", "status" => "fail", "blocked_by" => "TP-824"},
            %{"name" => "Nothing named", "status" => "fail", "gap" => " ", "blocked_by" => []}
          ]
        })

      assert {:ok, %{steps: [tool, check, single, plain]}} = QaAgent.parse_response(text)
      assert tool.gap == "G1"
      refute Map.has_key?(tool, :blocked_by)
      assert %{gap: "G2", blocked_by: ["G1", "TP-824"]} = check
      assert single.blocked_by == ["TP-824"]
      refute Map.has_key?(plain, :gap)
      refute Map.has_key?(plain, :blocked_by)
    end

    test "keeps the defect a failing step names" do
      text =
        Jason.encode!(%{
          "verdict" => "fail",
          "steps" => [
            %{"name" => "Design check: Companies table", "status" => "fail", "defect" => " People column empty "},
            %{"name" => "Plan level: pages", "status" => "fail", "defect" => "People column empty"},
            %{"name" => "Nothing named", "status" => "fail", "defect" => " "}
          ]
        })

      assert {:ok, %{steps: [design, plan, plain]}} = QaAgent.parse_response(text)
      assert design.defect == "People column empty"
      assert plan.defect == "People column empty"
      refute Map.has_key?(plain, :defect)
    end

    test "rejects answers that do not follow the contract" do
      for {text, reason} <- [
            {"no json here", :no_verdict_object},
            {~s({"other": 1}), :no_verdict_object},
            {~s({"verdict":"maybe"}), :invalid_verdict},
            {~s({"verdict":"pass","steps":"all good"}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":"x","status":"great"}]}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":" ","status":"pass"}]}), :invalid_steps},
            {~s({"verdict":"fail","findings":[]}), :missing_fail_findings},
            {~s({"verdict":"blocked","reason":""}), :missing_blocked_reason}
          ] do
        assert {:error, {:malformed_qa_response, ^reason}} = QaAgent.parse_response(text)
      end

      assert {:error, {:malformed_qa_response, :empty_response}} = QaAgent.parse_response(nil)
    end
  end

  describe "prompt/2 and settings" do
    test "a missing QA tool is never needs_person, and an open ticket covering it is named in covered_by" do
      prompt = QaAgent.prompt(job(), nil) |> String.replace(~r/\s+/, " ")

      assert prompt =~
               "A missing QA tool or QA host capability is never `needs_person`, even when a person could check the step by hand"

      assert prompt =~ "a missing secret or API key, an account, or a real device this QA host lacks"
      refute prompt =~ "check a step by hand or on a real device"
      assert prompt =~ "put that ticket's identifier in `covered_by`, so Symphony waits on that ticket instead of filing another"
    end

    test "a step waiting on a QA tool or host setup the PR itself adds is skipped, not blocked, outside the epic review" do
      prompt = QaAgent.prompt(job(), nil)
      flat = String.replace(prompt, ~r/\s+/, " ")

      assert flat =~
               "A step that needs a QA tool or tool option this PR itself adds, or a one-time QA host setup the ticket lists under `After release`, cannot be walked in this pass"

      assert flat =~ "Then mark the step `skipped`, and in `details` name the tool or setup it waits on"
      assert flat =~ "It never makes the verdict `blocked`: a fix ticket could only repeat this PR."
      assert flat =~ "A tool the PR does not add is missing as above."
      assert prompt =~ ~r/Leave `covered_by` out otherwise\.\n\nA step that needs.*\n\nWhen one playbook/s

      epic = QaAgent.prompt(job(%{epic_review: true, base_ref: "origin/main"}), nil)
      refute epic =~ "this PR itself adds"
      assert epic =~ "Leave `covered_by` out otherwise.\n\nWhen one playbook"
    end

    test "a step needing paid AI, real credentials or an outside service is judged through a stand-in, not blocked" do
      prompt = QaAgent.prompt(job(), nil) |> String.replace(~r/\s+/, " ")

      assert prompt =~
               "needs a paid AI service, real credentials or another outside service (a third-party API, GitHub, Linear) is never `blocked` for want of them, and never gets a real key"

      assert prompt =~ "run the app against a stand-in you serve where the playbook lets a server listen"
      assert prompt =~ "name what the stand-in replaced and the CI check that covers the real path"
      assert prompt =~ "Mark the step `blocked` only when the app cannot be pointed at a stand-in."
      refute prompt =~ "a stub of the project's API"
    end

    test "the system under test is never stubbed: a server that cannot start makes its steps blocked" do
      prompt = QaAgent.prompt(job(), nil) |> String.replace(~r/\s+/, " ")

      assert prompt =~
               "Never stand in for the system under test: the project's own server, API or CLI, and the database it stores in"

      assert prompt =~ "Run the real one built from this PR head"
      assert prompt =~ "mark each step that needs it `blocked` with the error in `details`: that is never a reason to write a stub of it"
      assert prompt =~ "a database such as Postgres cannot start inside it"
      assert prompt =~ "A playbook with `dev_server: true` has Symphony run the project's server, and its database, outside your sandbox."

      assert prompt =~
               "When Symphony started no dev server for this pass and a step is blocked because the project's own server or database is not running, set `needs_dev_server` to true"
    end

    test "includes the ticket, the parent's criteria and the playbooks" do
      prompt = QaAgent.prompt(job(), %{"identifier" => "TP-243", "title" => "Parent", "description" => "- [ ] parent criterion"})

      assert prompt =~ "TP-900"
      assert prompt =~ "Adds `symphony check`."
      assert prompt =~ "Parent issue (this is a sub-ticket"
      assert prompt =~ "- [ ] parent criterion"
      assert prompt =~ ~r/<linear_issue_title>\s*Parent\s*<\/linear_issue_title>/
      assert prompt =~ ~r/<linear_issue_body>\s*- \[ \] parent criterion\s*<\/linear_issue_body>/
      assert prompt =~ "### Playbook: cli"
      assert prompt =~ @sha
      assert prompt =~ ~s("verdict": "pass" | "fail" | "blocked")
      assert prompt =~ ~s("needs_person": true | false)
      assert prompt =~ ~s("needs_dev_server": true | false)
      assert prompt =~ "Set `needs_person` to true only when the block is something only a person can hand over"
      assert prompt =~ ~s("covered_by": )
      assert prompt =~ "Ending your turn ends the session"
      assert prompt =~ ~r/Do not leave\s+work running in the background/
      # The gap rule and its fields are the epic review's alone.
      refute prompt =~ "Each gap must be checkable"
      refute prompt =~ ~s("blocked_by")

      refute QaAgent.prompt(job(%{issue: issue(%{title: nil, description: nil})}), nil) =~ "Parent issue"
    end

    test "names the downloaded design files and the design docs, or says none are attached" do
      parent = %{"identifier" => "TP-243", "title" => "Parent", "description" => "plan"}
      screens = %{issue: "TP-243", title: "screens.html", path: "/tmp/symphony-qa-x/design/TP-243-screens.html"}
      prompt = QaAgent.prompt(job(%{design_files: [screens]}), parent)

      assert prompt =~ "Design (judge every screen and UI change against it, in this order):"
      assert prompt =~ "this ticket's and the parent's documents with `linear_get_document`"
      assert prompt =~ "the parent's are under `parentDocuments`"
      assert prompt =~ "2. `docs/design/design-system.md` and `docs/design/director-app-screens.md` in this worktree."
      assert prompt =~ "- `/tmp/symphony-qa-x/design/TP-243-screens.html` (attached to TP-243)"
      refute prompt =~ "No HTML screens or image files are attached"

      prompt = QaAgent.prompt(job(), nil)
      assert prompt =~ "1. The Screens documents and HTML screens: this ticket's documents"
      assert prompt =~ "No HTML screens or image files are attached to this ticket or its parent"
      assert prompt =~ "`docs/design/design-system.md`"

      epic = QaAgent.prompt(job(%{epic_review: true, base_ref: "origin/main"}), nil)
      assert epic =~ "No HTML screens or image files are attached to this ticket or its parent"
    end

    test "lists QA's three jobs in order, with a Design check per UI deliverable in light and dark" do
      prompt = QaAgent.prompt(job(), nil) |> String.replace(~r/\s+/, " ")

      [_before, jobs] = String.split(prompt, "QA's three jobs, in this order: ", parts: 2)
      [jobs, _playbooks] = String.split(jobs, "Playbooks to follow:", parts: 2)

      assert jobs =~ ~r/^1\. Walk the walkthrough steps marked `Proved by: QA`.* 2\. Judge every UI deliverable by sight\..* 3\. The wide pass/
      assert jobs =~ "Screenshot it in the real app in light and in dark, at the sizes the design names"
      assert jobs =~ "layout, spacing, alignment, truncation, contrast, symbols, wording, and whether it looks finished"
      assert jobs =~ "Report one step per UI deliverable named `Design check: <deliverable>`, with both screenshots in `evidence`"
      assert jobs =~ "the design it compared with"
      assert jobs =~ "When no Screens cover the deliverable, judge it against `docs/design/design-system.md` alone and say so"
      assert jobs =~ "A visible mismatch is `fail`, even when every structural check passes"
      assert prompt =~ "A `Design check` whose screenshots visibly differ from the design is such a defect."

      epic = QaAgent.prompt(job(%{epic_review: true, base_ref: "origin/main"}), nil)
      assert epic =~ "QA's three jobs, in this order:"
    end

    test "the viewport passes name the layout defect rule and the finding format" do
      [_before, jobs] = QaAgent.prompt(job(), nil) |> String.replace(~r/\s+/, " ") |> String.split("3. The wide pass", parts: 2)

      assert jobs =~ "One pass per viewport the repo names (today: the wide pass)."

      assert jobs =~
               "A defect is content clipped with no way to reach it, or a mechanism (scroll, collapse, resize) that doesn't work."

      assert jobs =~ "Horizontal scroll or a collapsed pane at a `functional` viewport is not a defect."
      assert jobs =~ "A finding names the viewport, the screen, the mechanism expected, the actual, and the evidence file."

      epic = QaAgent.prompt(job(%{epic_review: true, base_ref: "origin/main"}), nil) |> String.replace(~r/\s+/, " ")
      assert epic =~ "A finding names the viewport, the screen, the mechanism expected, the actual, and the evidence file."
    end

    test "each UI playbook runs the Design check in light and dark between the walkthrough and its other checks" do
      macos_app = %{build: "make app", app: "build/App.app"}
      android_app = %{build: "./gradlew assembleDebug", apk_path: "app.apk", application_ids: ["com.example.app"]}
      config = %{android: %{avd: "Pixel_3a_API_34"}, playbooks: %{macos_app: macos_app, android_app: android_app}}
      playbooks = Map.new(Selection.playbooks(config, dev_server?: true), &{&1.kind, String.replace(&1.prompt, ~r/\s+/, " ")})

      for kind <- ["macos_app", "web", "android_app"] do
        prompt = Map.fetch!(playbooks, kind)

        assert prompt =~
                 ~r/QA does three things, in this order: \(a\) the walkthrough steps marked `Proved by: QA`.*\(b\) the `Design check` of every UI deliverable, by sight, in light and dark.*\(c\)/

        assert prompt =~ "named `Design check: <deliverable>`", "#{kind} playbook must name the Design check step"
        assert prompt =~ "the design it compared with", "#{kind} playbook must name the design compared with"
        assert prompt =~ "the design system alone", "#{kind} playbook must fall back to the design system"
        assert prompt =~ ~r/A `Design check` whose light or dark screenshot visibly differs from the design .* is a failing step/
      end

      macos = Map.fetch!(playbooks, "macos_app")
      assert macos =~ ~s(`qa_launch_app` with `appearance: "dark"`)
      assert macos =~ ~s(do the same with `appearance: "light"`)
      assert macos =~ "Judge the menu from that screenshot, not only from the tree"
      assert macos =~ "`qa_open_status_menu`, then `qa_screenshot` with the `window_id` it returned"
      assert macos =~ ~r/8\. \*\*Design check\.\*\*.* 9\. \*\*Wide pass\.\*\*/

      assert Map.fetch!(playbooks, "android_app") =~ "Dark: `qa_android_dark_mode` `on`"
      assert Map.fetch!(playbooks, "web") =~ "await page.emulateMedia({ colorScheme: 'dark' })"
      assert Map.fetch!(playbooks, "web") =~ "dark is not applicable: judge light alone and say so in the step"
      refute Map.fetch!(playbooks, "cli") =~ "Design check"
    end

    test "carries the ticket's recorded decisions, which QA never fails the change for" do
      decision = SymphonyElixir.Decisions.entry("comment-1", ~D[2026-10-13], "Keep the old flag", "Drop the old flag here?", "Defer to TP-891")
      {:ok, description} = SymphonyElixir.Decisions.put("Adds `symphony check`.", [decision])

      prompt = QaAgent.prompt(job(%{issue: issue(%{id: "issue-qa-decided", description: description})}), nil)

      assert prompt =~ ~r/<linear_issue_body>\s*Adds `symphony check`.\s*<\/linear_issue_body>/
      assert prompt =~ "D1: Drop the old flag here? Answer: Defer to TP-891 Scope: Deferred to TP-891."
      assert prompt =~ "Do not fail the change for work a recorded decision put out of scope or deferred"
      refute QaAgent.prompt(job(), nil) =~ "Recorded decisions"
    end

    test "reads the recorded decisions from the store, not from the description" do
      decision = SymphonyElixir.Decisions.entry("comment-1", ~D[2026-10-13], "Keep the old flag", "Drop the old flag here?", "Defer to TP-891")
      assert {:ok, [_decision]} = SymphonyElixir.RunStore.record_ticket_decisions("default", "issue-qa-stored", [decision], [])

      prompt = QaAgent.prompt(job(%{issue: issue(%{id: "issue-qa-stored"})}), nil)

      assert prompt =~ "D1: Drop the old flag here? Answer: Defer to TP-891 Scope: Deferred to TP-891."
    end

    test "an epic review judges the epic itself at the base branch head against its own checklist" do
      epic =
        issue(%{
          id: "issue-epic",
          identifier: "TP-823",
          title: "Land the epic path",
          description: "## Acceptance criteria\n\n- [ ] The settings window opens\n"
        })

      prompt =
        QaAgent.prompt(
          job(%{
            issue: epic,
            epic_review: true,
            base_ref: "origin/main",
            journey: %{
              source: "the epic's acceptance criteria",
              text: "- [ ] The settings window opens",
              steps: SymphonyElixir.Walkthrough.steps("1. Open the settings window. Proved by: `test/settings_test.exs`", "make-all")
            }
          }),
          nil
        )

      assert prompt =~ "You are the QA agent in Symphony's epic review"
      assert prompt =~ "Every sub-ticket of this epic has merged, and the epic now has to close itself"
      assert prompt =~ "the head of `origin/main`"
      assert prompt =~ "files every gap as a follow-up sub-ticket in `Todo`"
      assert prompt =~ "Epic checklist (TP-823, this epic's own acceptance criteria and user walkthrough)"
      assert prompt =~ "You are verifying the epic itself, not running a script"
      assert prompt =~ "It never fails or blocks the ticket."
      assert prompt =~ "Journeys to verify, from the epic's acceptance criteria:\n- [ ] The settings window opens"
      assert String.replace(prompt, ~r/\s+/, " ") =~ "Read the check the way the CI rule above reads CI's runs."
      assert prompt =~ ~s("checklist": true | false)

      flat = String.replace(prompt, ~r/\s+/, " ")

      assert flat =~
               ~s(Every row of the epic's checklist is a required step. Report each row as its own step with `"checklist": true` and the status `pass` or `fail`)

      assert flat =~ "Symphony does not accept `pass` when no checklist row is reported or most of them are skipped"
      assert flat =~ "a follow-up sub-ticket"

      # A follow-up must be checkable on its own PR; one that needs another merge first is two.
      assert flat =~ "Each gap must be checkable on its own PR, before that PR merges"
      assert flat =~ "the QA tools are served by the running Symphony app, not by that head"

      assert flat =~
               "A gap whose check needs another ticket that has not merged, or needs the change running in Symphony " <>
                 "(a new QA tool, or orchestrator behaviour on Symphony's own repository), is two gaps: " <>
                 "the first makes the change, the second checks it and is blocked by the first."

      assert flat =~ "name what a gap waits on in its `\"blocked_by\"`: the `gap` labels of failing steps in this answer, or the identifiers of this epic's sub-tickets"
      assert prompt =~ ~s("gap": "<optional: a short label for a failing step>")
      assert prompt =~ ~s("blocked_by": [)

      # One follow-up per defect: steps that fail for one cause name the same defect.
      assert prompt =~ ~s("defect": "<for a failing step: a few words naming the defect it rests on>")
      assert flat =~ "Symphony files one follow-up per defect, titled after it, listing every step that rests on it."

      assert flat =~
               "a plan-level step that fails only because another step (a design check, say) failed names that step's defect, not a defect of its own"

      # The epic is its own parent: no parent section and no verification ticket.
      refute prompt =~ "Parent issue (this is a sub-ticket"
      refute prompt =~ "Verification checklist"
      refute prompt =~ "running the parent walkthrough"
      refute prompt =~ "so the executor can fix it"

      # An epic whose plan names no journeys: the review derives them itself.
      derived = QaAgent.prompt(job(%{issue: epic, epic_review: true, base_ref: "origin/main"}), nil)

      assert derived =~
               "Journeys to verify: derive them from the epic's description, its acceptance criteria and its plan documents."
    end

    test "a walkthrough with cli and macos_app keeps running the CLI checks when the app part is blocked" do
      config = %{playbooks: %{"macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app"}}}
      assert [%{kind: "cli"}, %{kind: "macos_app"}] = playbooks = Selection.playbooks(config)

      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] child criterion"})
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "- [ ] parent criterion"})
      prompt = QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main", playbooks: playbooks}), nil)

      assert prompt =~ "### Playbook: cli"
      assert prompt =~ ~r/When one playbook is blocked, mark its steps `blocked` and continue with the other playbooks'\s+steps: report `pass` or `fail` for every step that could run\./
      assert prompt =~ ~r/The verdict stays `blocked` while\s+any step is blocked/
      assert prompt =~ ~r/When a tool returns `qa_permission_missing`, stop this playbook: mark each app step you\s+could not check `blocked`/
      assert prompt =~ ~r/continue with the\s+steps of the other playbooks offered to you \(such as `cli` or `web`\) and report each of\s+them as `pass` or `fail`/
      refute prompt =~ "stop and answer `blocked`"
    end

    test "an android_app pass gets the playbook, its build settings and the ticket's walkthrough" do
      android = %{
        "build" => "./gradlew :app:assembleDebug :app-catalog:assembleDebug",
        "apk_paths" => ["app/build/outputs/apk/debug/app-debug.apk", "app-catalog/build/outputs/apk/debug/app-catalog-debug.apk"],
        "application_ids" => ["com.example.app", "com.example.app.catalog"]
      }

      {:run, playbooks} =
        Selection.decide(
          issue(%{description: "## User walkthrough\n\n1. Open the app and tap Sign in.\n   The login form shows."}),
          ["app/src/main/java/com/example/app/LoginActivity.kt"],
          %{android: %{avd: "Pixel_3a_API_34"}, playbooks: %{"cli" => %{"enabled" => false}, "android_app" => android}}
        )

      prompt = QaAgent.prompt(job(%{issue: issue(%{description: "## User walkthrough\n\n1. Open the app and tap Sign in.\n   The login form shows."}), playbooks: playbooks}), nil)

      assert prompt =~ "### Playbook: android_app"
      assert prompt =~ "1. Open the app and tap Sign in."
      assert prompt =~ "Build command (run it in your shell from the worktree root): `./gradlew :app:assembleDebug :app-catalog:assembleDebug`"

      assert prompt =~
               "APK paths (relative to the worktree root), each one an `apk` that `qa_android_install` takes:\n" <>
                 "- `app/build/outputs/apk/debug/app-debug.apk`\n- `app-catalog/build/outputs/apk/debug/app-catalog-debug.apk`\n" <>
                 "Application IDs: `com.example.app`, `com.example.app.catalog`\n" <>
                 "`qa_android_install` reports the application IDs each APK installed"

      assert prompt =~ "Pass `apk` to install only one of them."
      assert prompt =~ ~r/wait 3 to 5 seconds after each\s+navigation or action/
      assert prompt =~ "`make_public: false`"
      refute QaAgent.prompt(job(), nil) =~ "Android app:"
    end

    test "a job carrying the ticket's journey states the journeys to verify" do
      journey = %{source: "the ticket's `## User walkthrough`", text: "1. Run `symphony check`."}
      prompt = QaAgent.prompt(job(%{journey: journey}), nil)

      assert prompt =~ "You are verifying user journeys, not running a script."
      assert prompt =~ "Automated end-to-end suites (Playwright and friends) belong to CI"
      assert prompt =~ "read the parent issue and its plan documents with your Linear tools"
      assert prompt =~ "Journeys to verify, from the ticket's `## User walkthrough`:"
      assert prompt =~ "1. Run `symphony check`."
      assert prompt =~ "anything under an `After release` heading, is not yours to run"
      assert prompt =~ "It never fails or blocks the ticket."
    end

    test "a walkthrough that mixes named-test and QA steps lists the steps to link and the steps to walk" do
      description = """
      ## User walkthrough

      Nothing changes on screen.

      1. Preview the workflow → it states the rule. Proved by: `make-all` › the workflow preview tests.
      2. Open the window in light mode
         → it looks finished. Proved by: QA
      3. Click Save → saved.
      """

      ticket = issue(%{description: description})
      prompt = QaAgent.prompt(job(%{issue: ticket, journey: SymphonyElixir.QaVerification.journey(ticket, "make-all")}), nil)
      flat = String.replace(prompt, ~r/\s+/, " ")

      assert flat =~
               "A step ending in `Proved by: <test>` (run by the repo's proof check) or `Proved by: <check> › <test>` is proved by that named automated test, run by the check listed with it below: do not walk it."

      assert flat =~ "Walk every step that says `Proved by: QA` or names no proof."
      assert flat =~ "and walk yourself every step that no named test proves"
      assert flat =~ "gh run list --commit #{job().sha}"
      assert flat =~ "It failed, or never ran on `#{job().sha}`: `fail`, naming the step and the check in `findings`"

      assert prompt =~
               "Steps a named test proves (link the check run, do not walk them):\n" <>
                 "- 1. Preview the workflow → it states the rule. Proved by: `make-all` › the workflow preview tests\n"

      assert prompt =~
               "Steps to walk (`Proved by: QA`, or no proof named):\n" <>
                 "- 2. Open the window in light mode → it looks finished.\n" <>
                 "- 3. Click Save → saved.\n"

      refute flat =~ "but walk the journeys yourself"
    end

    test "a walkthrough whose steps a named test proves all has no steps to walk" do
      journey = %{
        source: "the ticket's `## User walkthrough`",
        text: "1. Parse it. Proved by: `make-all`",
        steps: SymphonyElixir.Walkthrough.steps("1. Parse it. Proved by: `make-all`", "make-all")
      }

      prompt = QaAgent.prompt(job(%{journey: journey}), nil)

      assert prompt =~ "- 1. Parse it. Proved by: `make-all`\n"
      assert prompt =~ "Steps to walk (`Proved by: QA`, or no proof named):\n- none\n"
    end

    test "a walkthrough with no named-test step is walked whole, whatever its Proved by: lines say" do
      text = "1. Run `symphony check`. Proved by: test/check_test.exs"
      journey = %{source: "the ticket's `## User walkthrough`", text: text, steps: SymphonyElixir.Walkthrough.steps(text, nil)}
      prompt = QaAgent.prompt(job(%{journey: journey}), nil)

      assert prompt =~ "No walkthrough step names a test that a check of this repo runs: walk every step, whatever its `Proved by:` line says."
      refute prompt =~ "gh run list --commit"
      refute prompt =~ "Steps a named test proves"
      refute prompt =~ "Steps to walk"
    end

    test "a journey with no text asks the run to derive it from the ticket" do
      journey = %{source: "the ticket's walkthrough and acceptance criteria", text: nil}
      prompt = QaAgent.prompt(job(%{journey: journey}), nil)

      assert prompt =~
               "Journeys to verify: derive them from this ticket's walkthrough and acceptance criteria below."
    end

    test "a job with no journey renders no journey section, so the Auto Review prompts are unchanged" do
      prompt = QaAgent.prompt(job(), nil)

      refute prompt =~ "You are verifying user journeys"
      refute prompt =~ "Journeys to verify"
    end

    test "every QA prompt forbids starting an emulator or simulator and blocks device steps without the android_app playbook" do
      parent = issue(%{id: "issue-parent", identifier: "TP-243", title: "Parent", description: "- [ ] parent criterion"})
      verification = issue(%{id: "issue-fv", identifier: "TP-910", title: "Final verification: Parent", description: "- [ ] child criterion"})
      android_app = %{kind: "android_app", paths: [], prompt: "Test the Android app.", build: "./gradlew assembleDebug", apk_paths: ["app.apk"], application_ids: ["com.example.app"]}

      for prompt <- [
            QaAgent.prompt(job(), nil),
            QaAgent.prompt(job(%{issue: parent, verification_issue: verification, base_ref: "origin/main"}), nil),
            QaAgent.prompt(job(%{playbooks: [android_app]}), nil)
          ] do
        assert prompt =~ ~r/Never start an emulator, a simulator or a device tool yourself \(`emulator`, `qemu-\*`,\s+`xcrun simctl boot`, `adb start-server`/

        assert prompt =~
                 ~r/When a step needs an\s+Android device and no `android_app` playbook is offered to you below, mark that step `blocked`\s+with "no Android QA playbook configured for this repo"/
      end
    end

    test "QA prompts and built-in playbooks leave the test suite to CI" do
      epic = issue(%{id: "issue-epic", identifier: "TP-243", title: "Epic", description: "- [ ] epic criterion"})

      pr_prompt = QaAgent.prompt(job(), nil)
      assert pr_prompt =~ ~r/Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI already\s+ran them green on this PR head/

      walkthrough = QaAgent.prompt(job(%{issue: epic, epic_review: true, base_ref: "origin/main"}), nil)
      assert walkthrough =~ ~r/Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI runs\s+them on every merge to `origin\/main`/
      refute walkthrough =~ "covered by CI on"
      refute walkthrough =~ "ran them green on this PR head"

      macos_app = %{build: "make app", app: "build/App.app"}
      android_app = %{build: "./gradlew assembleDebug", apk_path: "app.apk", application_ids: ["com.example.app"]}
      config = %{android: %{avd: "Pixel_3a_API_34"}, playbooks: %{macos_app: macos_app, android_app: android_app}}
      built_ins = Selection.playbooks(config, dev_server?: true)
      assert Enum.map(built_ins, & &1.kind) == ["cli", "macos_app", "android_app", "web"]

      for %{kind: kind, prompt: prompt} <- built_ins do
        assert prompt =~ ~r/Do not run the project's test suite, `make all`, coverage or (Dialyzer|static analysis): CI already\s+ran them/,
               "#{kind} playbook must leave the test suite to CI"
      end
    end

    test "an epic review judges test, coverage and CI criteria by CI's run on the base branch head" do
      epic = issue(%{id: "issue-epic", identifier: "TP-243", title: "Epic", description: "- [ ] make all is green"})
      walkthrough = QaAgent.prompt(job(%{issue: epic, epic_review: true, base_ref: "origin/main"}), nil)

      [_intro, rule] = String.split(walkthrough, "Do not run the test suite", parts: 2)
      [rule, _rest] = String.split(rule, "\nYou are verifying the epic itself", parts: 2)

      assert String.trim_trailing("Do not run the test suite" <> rule) <> "\n" == """
             Do not run the test suite, `make all`, coverage or static analysis such as Dialyzer: CI runs
             them on every merge to `origin/main`. Judge a criterion that asks for tests, coverage or CI to
             pass by CI's runs on `#{@sha}`, the commit you are on:

             - Read the runs with `gh run list --commit #{@sha} --json databaseId,workflowName,status,conclusion,url`
               where `gh` is allowed, else through GitHub's public API:
               `curl -fsS "https://api.github.com/repos/<owner>/<repo>/actions/runs?head_sha=#{@sha}"`, with
               `<owner>/<repo>` from `git remote get-url origin`.
             - Every run completed with conclusion `success`: mark the criterion `pass` and put each run's URL
               and conclusion in `details`.
             - A run failed (any conclusion other than `success`, `skipped` or `neutral`): mark the criterion
               `fail`, and in `details` and `findings` name the failing workflow and job (`gh run view <id>
               --json jobs`, or the run's `jobs_url`) with the run URL. A red `origin/main` is a defect.
               Read the failed job's log with the `github_ci_log` tool (`run_id`, or `job_id`) before you
               say why it failed, and quote the lines that name the cause (the failing step's last lines and
               its annotations): never guess the cause from the job's name or the diff. Symphony quotes the
               same log in the follow-up it files for the run you name.
             - Mark it `skipped` only when no run can be read (the commands are refused, or CI has no run for
               this commit) or a run is still in progress, and say which in `details`, with the run URL when
               there is one.

             Build only what you need to use the feature, and judge it by what a user sees.
             """

      refute QaAgent.prompt(job(), nil) =~ "actions/runs"
    end

    test "a PR pass skips a criterion only an agent-protected path can meet once it is handed off, and fails a missing unprotected change" do
      ticket = issue(%{description: "- [ ] WORKFLOW.md Step 3 describes the re-review\n- [ ] docs/configuration.md describes the re-review"})
      prompt = QaAgent.prompt(job(%{issue: ticket}), nil)

      assert prompt =~ ~r/Agents cannot change these paths: the sandbox denies the writes and CI fails a PR whose own\s+commits touch them: `WORKFLOW.md`, /
      assert prompt =~ "`.agents/skills`"
      assert prompt =~ "`.claude/settings.json`"
      assert prompt =~ ~r/it files a sub-issue \(read them with `linear_get_subissues`\)/

      assert prompt =~
               ~r/When\s+such a hand-off exists, the criterion is out of this PR's scope: mark its step `skipped`, name the\s+follow-up ticket's identifier in `details`, and do not fail the verdict on it\./

      assert prompt =~ ~r/Without a hand-off,\s+mark it `fail`/
      assert prompt =~ ~r/Never skip a criterion that a\s+change outside these paths could meet, such as one under `docs\/` or to `README.md`: a missing\s+change there is `fail`\./
      assert prompt =~ ~r/A failed `protected paths` check on the PR is not a defect and not a\s+block: only a person clears it, and Symphony asks them before the merge\./

      for path <- AgentSandboxConfig.workspace_protected_paths(), do: assert(prompt =~ "`#{path}`")

      refute QaAgent.prompt(job(%{issue: ticket, epic_review: true, base_ref: "origin/main"}), nil) =~ "Agents cannot change these paths"

      handed_off = %{"name" => "Docs: WORKFLOW.md Step 3 describes the re-review", "status" => "skipped", "details" => "Protected path; handed off to TP-521."}
      docs = %{"name" => "Docs: docs/configuration.md describes the re-review", "status" => "pass", "details" => "git diff shows the paragraph"}

      assert {:ok, %{verdict: :pass, steps: [%{status: "skipped", details: "Protected path; handed off to TP-521."}, %{status: "pass"}]} = passed} =
               QaAgent.parse_response(Jason.encode!(%{"verdict" => "pass", "steps" => [handed_off, docs]}))

      assert QaAgent.failure_findings(passed) == []

      missing_docs = %{docs | "status" => "fail", "details" => "git diff --quiet origin/main HEAD -- docs/ shows no change"}

      assert {:ok, %{verdict: :fail} = failed} = QaAgent.parse_response(Jason.encode!(%{"verdict" => "fail", "steps" => [handed_off, missing_docs]}))

      assert QaAgent.failure_findings(failed) == [
               "Docs: docs/configuration.md describes the re-review: git diff --quiet origin/main HEAD -- docs/ shows no change"
             ]
    end

    test "QA settings take the auto_review runtime, turns and timeout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        auto_review: %{runtime: "codex", command: "codex app-server", max_turns: 3, timeout_ms: 5_000}
      )

      settings = QaAgent.qa_settings(Config.settings!())

      assert %{kind: "codex", command: "codex app-server", max_turns: 3, turn_timeout_ms: 5_000} = settings.agent

      write_workflow_file!(Workflow.workflow_file_path())
      base = Config.settings!()
      assert QaAgent.qa_settings(base).agent.command == base.agent.command
    end

    test "worktrees live under the workspace root, outside the repository directories" do
      settings = Config.settings!()
      path = QaAgent.worktree_path(settings, nil, nil, @sha)

      assert path == Path.join([Path.expand(settings.workspace.root), ".qa", "default", "issue-0123456789ab"])
    end
  end

  describe "run/3" do
    test "runs the agent in a detached worktree with the QA tool scope and cleans up" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120}}},
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 300, "output_tokens" => 50, "total_tokens" => 350}}},
        %{event: :notification, payload: %{"method" => "other"}}
      ])

      forwarded = self()
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      workspace = job().workspace_path

      assert {:ok, %{result: %{verdict: :pass}, tokens: tokens}} =
               QaAgent.run(job(), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 on_message: &send(forwarded, {:forwarded, &1})
               )

      assert tokens.total_tokens == 350
      assert tokens.output_tokens == 50
      assert_receive {:git, ["worktree", "remove", "--force", ^worktree], ^workspace}
      assert_receive {:git, ["cat-file", "-e", _object], ^workspace}
      assert_receive {:git, ["worktree", "add", "--detach", ^worktree, @sha], ^workspace}
      assert_receive {:qa_session_started, ^worktree, session_opts}
      assert session_opts[:tool_scope] == :qa
      assert_receive {:qa_turn, _session, prompt, %Issue{id: "issue-qa"}, _opts}
      assert prompt =~ "### Playbook: cli"
      assert_receive {:forwarded, _message}
      assert_receive {:qa_session_stopped, _session}
      refute File.exists?(worktree)
    end

    test "stops processes left running under the worktree before removing it" do
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      test_pid = self()
      left = %{pid: 4242, start_time: "Sat Oct  3 08:00:00 2026", command: "sleep 600", cwd: worktree}
      unrelated = %{left | pid: 4343, cwd: System.tmp_dir!()}
      {:ok, reads} = Agent.start_link(fn -> [{:ok, [left, unrelated]}, {:ok, [unrelated]}] end)

      leftover_processes = [
        table: fn -> Agent.get_and_update(reads, fn [next | rest] -> {next, rest} end) end,
        signal: fn pid, signal -> send(test_pid, {:signal, pid, signal, File.exists?(worktree)}) end
      ]

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, leftover_processes: leftover_processes)
        end)

      assert_received {:signal, 4242, "TERM", true}
      refute_received {:signal, 4343, _signal, _exists}
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=4242 cwd=#{worktree}"
    end

    @tag :process_table
    test "a detached process started in the worktree is gone once the pass ends" do
      unrelated = detached_sleep(System.tmp_dir!())
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(unrelated)]) end)

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), Config.settings!(),
                     git: fake_git(),
                     qa_agent_module: DetachingSession,
                     leftover_processes: [table: &Table.read/0, grace_ms: 2_000]
                   )
        end)

      assert_received {:detached, left}
      refute running?(left)
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=#{left} "
      assert running?(unrelated)
      refute log =~ "pid=#{unrelated} "
    end

    @tag :process_table
    test "a detached process started under the pass's $TMPDIR, outside the worktree, is gone once the pass ends" do
      # Another session's process in the shared temp folder, as another run or Tony's own.
      shared = Path.join(System.tmp_dir!(), "qa-agent-test-shared/qa/checkout")
      File.mkdir_p!(shared)
      unrelated = detached_sleep(shared)

      on_exit(fn ->
        System.cmd("kill", ["-KILL", Integer.to_string(unrelated)])
        File.rm_rf(Path.join(System.tmp_dir!(), "qa-agent-test-shared"))
      end)

      worktree = QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha)

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass}}} =
                   QaAgent.run(job(), Config.settings!(),
                     git: fake_git(),
                     qa_agent_module: TmpDirDetachingSession,
                     leftover_processes: [table: &Table.read/0, grace_ms: 2_000]
                   )
        end)

      assert_received {:detached, left, checkout}
      refute String.starts_with?(checkout, worktree)
      refute running?(left)
      assert log =~ "Stopping leftover process issue_id=issue-qa issue_identifier=TP-900 pid=#{left} "
      assert running?(unrelated)
      refute log =~ "pid=#{unrelated} "
      refute File.exists?(checkout)
    end

    test "gives the agent a private temp folder of its own, stops what runs under it and removes it" do
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      [tmp_dir] = QaAgent.tmp_dirs(worktree, [base])
      # A folder left by an interrupted pass doesn't carry over.
      File.mkdir_p!(Path.join(tmp_dir, "stale"))
      test_pid = self()
      left = %{pid: 4242, start_time: "Sun Oct  4 08:00:00 2026", command: "./bin/symphony --port 47413", cwd: Path.join(tmp_dir, "qa/checkout")}
      shared = %{left | pid: 4343, cwd: Path.join(System.tmp_dir!(), "qa/checkout")}
      {:ok, reads} = Agent.start_link(fn -> [{:ok, [left, shared]}, {:ok, [shared]}] end)

      leftover_processes = [
        table: fn -> Agent.get_and_update(reads, fn [next | rest] -> {next, rest} end) end,
        signal: fn pid, signal -> send(test_pid, {:signal, pid, signal}) end
      ]

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [base], leftover_processes: leftover_processes)

      assert_received {:qa_session_started, ^worktree, session_opts}
      assert session_opts[:extra_env] == %{"TMPDIR" => tmp_dir}
      assert List.last(session_opts[:settings].workspace.sandbox.allow_write_paths) == tmp_dir
      assert String.length(tmp_dir) == String.length(base) + String.length("/symphony-qa-") + 12
      assert_received {:signal, 4242, "TERM"}
      refute_received {:signal, 4343, _signal}
      refute File.exists?(tmp_dir)
    end

    test "makes the temp folder private and falls back to the next base when one can't hold it" do
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      not_a_dir = Path.join(base, "file")
      File.write!(not_a_dir, "")
      test_pid = self()

      assert {:ok, _result} =
               QaAgent.run(job(), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 tmp_bases: [not_a_dir, base],
                 leftover_processes: [
                   table: fn ->
                     send(test_pid, {:mode, File.stat!(base_tmp_dir(base)).mode})
                     {:ok, []}
                   end
                 ]
               )

      assert_received {:qa_session_started, _worktree, session_opts}
      assert %{"TMPDIR" => tmp_dir} = session_opts[:extra_env]
      assert Path.dirname(tmp_dir) == base
      assert_received {:mode, mode}
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "gives a Claude pass its temp folder as CLAUDE_CODE_TMPDIR" do
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{runtime: "claude"})
      base = Path.join(System.tmp_dir!(), "qa-agent-test-tmp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      assert {:ok, _result} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [base], leftover_processes: [table: fn -> {:ok, []} end])

      assert_received {:qa_session_started, _worktree, session_opts}
      assert %{"CLAUDE_CODE_TMPDIR" => tmp_dir} = session_opts[:extra_env]
      refute Map.has_key?(session_opts[:extra_env], "TMPDIR")
      assert Path.dirname(tmp_dir) == base
    end

    test "is blocked without starting the agent when no temp folder can be made" do
      not_a_dir = Path.join(System.tmp_dir!(), "qa-agent-test-file-#{System.unique_integer([:positive])}")
      File.write!(not_a_dir, "")
      on_exit(fn -> File.rm(not_a_dir) end)
      worktree = QaAgent.worktree_path(Config.settings!(), "default", "TP-900", @sha)
      [tmp_dir] = QaAgent.tmp_dirs(worktree, [not_a_dir])

      assert {:error, {:qa_tmp_dir_failed, [^tmp_dir]}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession, tmp_bases: [not_a_dir])

      refute_received {:qa_session_started, _worktree, _opts}
      refute File.exists?(worktree)
    end

    test "gives a macos_app pass a QA driver and stops it when the pass ends" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      assert {:ok, %{result: %{verdict: :inconclusive}}} =
               QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 qa_driver_opts: qa_vm_opts()
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      driver = session_opts[:qa_driver]
      assert is_pid(driver)
      assert_receive {:qa_turn, _session, prompt, _issue, turn_opts}
      assert turn_opts[:qa_driver] == driver
      assert prompt =~ "### Playbook: macos_app"
      assert %{"QA_HOST_PORTS" => ports} = session_opts[:extra_env]
      assert [_one, _two, _three] = String.split(ports, ",")
      assert prompt =~ "Host ports:\nQA_HOST_PORTS = #{ports} (also in your `QA_HOST_PORTS` environment variable)."
      assert prompt =~ "the app reaches them at\n`http://localhost:<port>`"
      refute Process.alive?(driver)

      assert {:ok, _result} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      assert_receive {:qa_session_started, _worktree, cli_opts}
      assert cli_opts[:qa_driver] == nil
      refute Map.has_key?(cli_opts[:extra_env], "QA_HOST_PORTS")
      assert_receive {:qa_turn, _session, cli_prompt, _issue, _turn_opts}
      refute cli_prompt =~ "QA_HOST_PORTS"
    end

    test "blocks a macos_app pass whose host-port tunnel to the QA host cannot open, before the agent starts" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      host = %{tunnel: fn _ports -> {:error, {:failed, "ssh exited with status 255: Connection refused"}} end}

      {result, log} =
        with_log(fn ->
          QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
            git: fake_git(),
            qa_agent_module: FakeSession,
            qa_driver_opts: qa_vm_opts(host)
          )
        end)

      assert {:error, {:qa_host_tunnel_failed, "ssh exited with status 255: Connection refused"}, %{total_tokens: 0}} = result
      assert log =~ "QA driver could not open the host-port tunnel"
      refute_received {:qa_session_started, _worktree, _opts}
    end

    # Settings for a macos_app pass on a QA host, with the project's dev server configured.
    defp qa_host_settings do
      settings = Config.settings!()

      dev_server = %{
        settings.verification.dev_server
        | build_cmd: "make server",
          start_cmd: "server/scripts/dev-server.sh",
          health_check_url: "http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT/health"
      }

      # Verification stays off: the QA-host server reads only `verification.dev_server` (TP-1115).
      verification = %{settings.verification | enabled: false, dev_server: dev_server}
      %{settings | auto_review: %{settings.auto_review | worker_host: "qa-vm"}, verification: verification}
    end

    # A QA host whose dev-server scripts answer from `health` and tell the test what ran.
    defp qa_host_dev_server_host(health) do
      test = self()

      cmd = fn "/bin/bash", ["-c", script, "sh", _dir | args], _opts -> qa_host_script(test, script, args, health) end

      %{
        cmd: cmd,
        kill: fn _pid -> :ok end,
        prepare: fn _operator_home, _canary -> {:ok, "/Users/qa/.symphony-qa/runs/run.abc"} end,
        tunnel: fn _ports -> {:ok, Port.open({:spawn, "cat"}, [:binary])} end,
        ship: fn _tar, dest -> send(test, {:qa_host_shipped, dest}) && :ok end,
        cleanup: fn dir -> send(test, {:qa_host_cleanup, dir}) && :ok end
      }
    end

    # Whichever of the dev server's health check and the session's start reached the mailbox first.
    defp health_or_session do
      receive do
        {:qa_host_dev_server, :health} = message -> message
        {:qa_session_started, _worktree, _opts} -> :qa_session_started
      after
        0 -> :none
      end
    end

    defp qa_host_script(test, script, args, health) do
      cond do
        script =~ ~s(rm -rf "$dir") ->
          {:ok, {"symphony-qa-dev-server-dir:/Users/qa/.symphony-qa/runs/run.abc/dev-server\n", 0}}

        script =~ "lsof -nP" ->
          {:ok, {"symphony-qa-dev-server-port:free\n", 0}}

        script =~ ~s(case "$3") ->
          send(test, {:qa_host_dev_server, args})
          if Enum.at(args, 1) == "start", do: {:ok, {"symphony-qa-dev-server-pid:4242\n", 0}}, else: {:ok, {"", 0}}

        script =~ "end=" ->
          send(test, {:qa_host_dev_server, :health})
          health

        script =~ ~s(kill -s "$3") ->
          send(test, {:qa_host_dev_server, :stopped})
          {:ok, {"symphony-qa-dev-server:stopped\n", 0}}
      end
    end

    # A QA host's dev-server scripts for one of two passes: each tells the test what ran and when,
    # and the first pass's health check waits for the test's `:go`, so that pass holds the lease.
    defp leased_host_cmd(test, pass) do
      fn "/bin/bash", ["-c", script, "sh", _dir | _args], _opts ->
        at = System.unique_integer([:monotonic])

        cond do
          script =~ ~s(rm -rf "$dir") ->
            send(test, {pass, :prepare, at})
            {:ok, {"symphony-qa-dev-server-dir:/Users/qa/.symphony-qa/runs/run.abc/dev-server\n", 0}}

          script =~ "lsof -nP" ->
            {:ok, {"symphony-qa-dev-server-port:free\n", 0}}

          script =~ ~s(case "$3") ->
            {:ok, {"symphony-qa-dev-server-pid:4242\n", 0}}

          script =~ "end=" ->
            hold_health_check(test, pass)
            {:ok, {"symphony-qa-dev-server:healthy\n", 0}}

          script =~ ~s(kill -s "$3") ->
            send(test, {pass, :stopped, at})
            {:ok, {"symphony-qa-dev-server:stopped\n", 0}}
        end
      end
    end

    defp hold_health_check(test, :first) do
      send(test, {:first, :health_check, self()})
      receive(do: (:go -> :ok))
    end

    defp hold_health_check(_test, _pass), do: :ok

    defp qa_host_macos_app(settings \\ qa_host_settings()) do
      macos_app = %{"build" => "make app", "app" => "build/App.app", "dev_server" => true}
      config = %{settings.auto_review | playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}}
      [macos_app] = Selection.playbooks(config, Verification.selection_opts(settings))
      macos_app
    end

    test "starts a macos_app pass's dev server on the QA host before the agent, names its URL and stops it after" do
      health = {:ok, {"symphony-qa-dev-server:healthy\n", 0}}

      {result, log} =
        with_log(fn ->
          QaAgent.run(job(%{playbooks: [qa_host_macos_app()]}), qa_host_settings(),
            git: fake_git(),
            qa_agent_module: FakeSession,
            verification: FakeVerification,
            qa_driver_opts: qa_vm_opts(qa_host_dev_server_host(health))
          )
        end)

      assert {:ok, %{result: %{verdict: :inconclusive}}} = result
      assert log =~ ~r/QA dev server started issue_id=\S+ issue_identifier=TP-900 worker_host=qa-vm port=8090 pid=4242 lease=qa-vm:8090/
      assert log =~ "QA dev server stopped issue_id="
      assert_received {:qa_host_shipped, "/Users/qa/.symphony-qa/runs/run.abc/dev-server/src"}
      assert_received {:qa_host_dev_server, ["8090", "build", "make server"]}
      assert_received {:qa_host_dev_server, ["8090", "start", "server/scripts/dev-server.sh"]}

      # The server answered its health check before the agent's session started.
      assert health_or_session() == {:qa_host_dev_server, :health}
      assert_received {:qa_turn, _session, prompt, _issue, _opts}
      flat = String.replace(prompt, ~r/\s+/, " ")
      assert flat =~ "dev server for this PR head on the QA host, beside the app under test, at http://127.0.0.1:8090/"
      assert flat =~ "it is not on this machine, so your shell cannot"

      assert_received {:qa_host_dev_server, :stopped}
      assert_received {:qa_host_cleanup, "/Users/qa/.symphony-qa/runs/run.abc"}
      # This host starts no dev server of its own for the pass.
      refute_received {:dev_server_started, _identifier, _run_id, _worktree, _opts}
    end

    test "starts no dev server for a macos_app pass without a QA host, on this host or another, and reports it blocked" do
      settings = put_in(qa_host_settings().auto_review.worker_host, nil)
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: FakeSession.pass_json()}})

      {result, _log} =
        with_log(fn ->
          QaAgent.run(job(%{playbooks: [qa_host_macos_app(settings)]}), settings,
            git: fake_git(),
            qa_agent_module: FakeSession,
            verification: FakeVerification
          )
        end)

      assert {:ok, %{result: %{verdict: :blocked, cause: {:qa_worker, "qa_worker_missing"}, reason: reason}}} = result
      assert reason =~ "No QA VM is set up"
      refute_received {:dev_server_started, _identifier, _run_id, _worktree, _opts}
      refute_received {:qa_host_dev_server, _args}
    end

    test "blocks a macos_app pass whose QA-host dev server fails its health check, before the agent starts" do
      health = {:ok, {"symphony-qa-dev-server:timeout\npostgres: could not bind\n", 0}}

      {result, _log} =
        with_log(fn ->
          QaAgent.run(job(%{playbooks: [qa_host_macos_app()]}), qa_host_settings(),
            git: fake_git(),
            qa_agent_module: FakeSession,
            verification: FakeVerification,
            qa_driver_opts: qa_vm_opts(qa_host_dev_server_host(health))
          )
        end)

      assert {:error, {:qa_dev_server_failed, :health_timeout, "postgres: could not bind"} = cause, %{total_tokens: 0}} = result
      refute_received {:qa_session_started, _worktree, _opts}
      assert_received {:qa_host_dev_server, :stopped}
      assert SelfHeal.component(%{cause: cause}) == "dev_server"

      assert QaAgent.blocked_reason(cause) ==
               "qa_dev_server_failed: the dev server on the QA host did not answer its health check with 200 in time; its last log lines:\npostgres: could not bind"
    end

    # TP-1123 and TP-1124 ran on one QA host at once: the second's server could not bind the port
    # the first's held. A second pass now waits for the port's lease, and starts its server only
    # once the first pass stopped its own.
    test "a second pass on the same QA host and port starts its server only after the first pass stopped its own" do
      lease = :"qa_agent_dev_server_lease_#{System.unique_integer([:positive])}"
      start_supervised!({DevServerLease, name: lease})
      test = self()

      run = fn pass, issue, opts ->
        host = %{qa_host_dev_server_host(nil) | cmd: leased_host_cmd(test, pass)}

        QaAgent.run(
          job(%{issue: issue, playbooks: [qa_host_macos_app()]}),
          qa_host_settings(),
          [
            git: fake_git(),
            qa_agent_module: FakeSession,
            verification: FakeVerification,
            qa_driver_opts: qa_vm_opts(host) ++ [dev_server_lease: lease]
          ] ++ opts
        )
      end

      first = Task.async(fn -> run.(:first, issue(), []) end)
      assert_receive {:first, :health_check, health_check}, 5_000

      second_issue = issue(%{id: "issue-qa-2", identifier: "TP-901"})
      heartbeat = fn message -> send(test, {:second, :message, message}) end
      second = Task.async(fn -> run.(:second, second_issue, on_message: heartbeat, dev_server_lease_opts: [heartbeat_ms: 10]) end)

      # The second pass waits, never silently: its heartbeat keeps it from looking stalled, and the
      # orchestrator can say whom it waits for.
      assert_receive {:second, :message, %{event: :tool_progress, timestamp: %DateTime{}}}, 5_000
      assert DevServerLease.waiting(lease, "issue-qa-2") == %{worker_host: "qa-vm", port: 8090, held_by: "TP-900"}
      refute_received {:second, :prepare, _at}

      send(health_check, :go)
      assert {:ok, _first} = Task.await(first)
      assert {:ok, _second} = Task.await(second)

      assert_received {:first, :stopped, stopped_at}
      assert_received {:second, :prepare, prepared_at}
      assert stopped_at < prepared_at
      assert_received {:second, :stopped, _at}
      assert DevServerLease.waiting(lease, "issue-qa-2") == nil
    end

    test "blocks a macos_app pass whose QA host lacks a tool the playbook requires, before the agent starts" do
      [macos_app] =
        Selection.playbooks(%{
          playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app", "requires" => ["go", "pg_ctl"]}}
        })

      test_pid = self()

      host = %{
        kill: fn _pid -> :ok end,
        prepare: fn _operator_home, _canary -> {:ok, "/Users/qa/symphony-qa/run-1"} end,
        cmd: fn "/bin/sh", ["-c", _script, "sh" | tools], _opts ->
          send(test_pid, {:tool_check, tools})
          {:ok, {"symphony-qa-missing-tool:go\nsymphony-qa-tools:checked\n", 0}}
        end,
        tunnel: fn _ports -> {:ok, nil} end,
        cleanup: fn _dir -> :ok end
      }

      result =
        QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
          git: fake_git(),
          qa_agent_module: FakeSession,
          qa_driver_opts: qa_vm_opts(host)
        )

      assert {:error, {:qa_host_missing_tool, ["go"]} = cause, %{total_tokens: 0}} = result
      assert_received {:tool_check, ["go", "pg_ctl"]}
      assert QaAgent.blocked_reason(cause) =~ "qa_host_missing_tool: go"
      assert SelfHeal.component(%{verdict: :blocked, cause: cause, reason: QaAgent.blocked_reason(cause)}) == "worker_host"
      refute_received {:qa_session_started, _worktree, _opts}
    end

    test "reports a pass whose wide pass the QA screen limited as blocked, for a person" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      run = fn screen, turn_result ->
        Application.put_env(:symphony_elixir, :qa_test_turn_result, turn_result)

        {result, _log} =
          with_log(fn ->
            QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
              git: fake_git(),
              qa_agent_module: WidePassSession,
              qa_driver_opts: qa_vm_opts(wide_pass_host(screen)) ++ [git: fn _args, _cwd -> {"", 0} end]
            )
          end)

        result
      end

      assert {:ok, %{result: %{verdict: :blocked, reason: reason, needs_person: true, steps: [%{name: "symphony check"}]}}} =
               run.({1024, 768}, {:ok, %{result: FakeSession.pass_json()}})

      assert reason =~ "the wide pass was limited: the QA screen is 1024×768 pt (1024×675 pt usable)"
      assert reason =~ "reached only 1024×675 pt, under the 1400×900 pt the wide pass needs"
      assert Report.render(%{verdict: :blocked, reason: reason, sha: @sha, target_state: "Human Review"}) =~ "Reason: the wide pass was limited"

      assert {:ok, %{result: %{verdict: :pass}}} = run.({1920, 1200}, {:ok, %{result: FakeSession.pass_json()}})

      blocked_json =
        Jason.encode!(%{
          verdict: "blocked",
          summary: "The wide pass was limited.",
          reason: "the Wide pass step is blocked: the screen is 1024×768",
          steps: [%{name: "Wide pass", status: "blocked", details: "qa_resize_window returned limited: true at 1024×675 pt."}],
          findings: []
        })

      assert {:ok, %{result: %{verdict: :blocked, reason: blocked_reason, needs_person: true, steps: [%{name: "Wide pass"}]}}} =
               run.({1024, 768}, {:ok, %{result: blocked_json}})

      assert blocked_reason =~ "the Wide pass step is blocked: the screen is 1024×768; the wide pass was limited: the QA screen is 1024×768 pt"

      fail_json = Jason.encode!(%{verdict: "fail", summary: "Decide crashed.", steps: [], findings: ["Decide crashes at 1024 pt"]})
      assert {:ok, %{result: %{verdict: :fail} = failed}} = run.({1024, 768}, {:ok, %{result: fail_json}})
      refute Map.has_key?(failed, :needs_person)
    end

    test "reports a macos_app pass that never resized a window as inconclusive, since its wide pass did not run" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      run = fn turn_result ->
        Application.put_env(:symphony_elixir, :qa_test_turn_result, turn_result)

        QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
          git: fake_git(),
          qa_agent_module: FakeSession,
          qa_driver_opts: qa_vm_opts()
        )
      end

      assert {:ok, %{result: %{verdict: :inconclusive, reason: reason, steps: [%{name: "symphony check"}]} = inconclusive}} =
               run.({:ok, %{result: FakeSession.pass_json()}})

      assert reason =~ "the wide pass did not run: no `qa_resize_window` call resized the app's window"
      refute Map.has_key?(inconclusive, :needs_person)
      assert Report.render(%{verdict: :inconclusive, reason: reason, sha: @sha, target_state: "QA"}) =~ "Reason: the wide pass did not run"

      fail_json = Jason.encode!(%{verdict: "fail", summary: "The app crashed at launch.", steps: [], findings: ["App exits at launch"]})
      assert {:ok, %{result: %{verdict: :fail}}} = run.({:ok, %{result: fail_json}})

      Application.delete_env(:symphony_elixir, :qa_test_turn_result)
      assert {:ok, %{result: %{verdict: :pass}}} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "a macos_app pass with nothing on screen to judge owes no wide pass and carries what it did with the app" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      scope_none = Jason.encode!(%{verdict: "pass", summary: "Nothing to judge.", scope: "none", reason: "the change touches no screen; the app built and launched"})
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: scope_none}})

      run = fn session ->
        {result, _log} =
          with_log(fn ->
            QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
              git: fake_git(),
              qa_agent_module: session,
              qa_driver_opts: qa_vm_opts(wide_pass_host({1920, 1200})) ++ [git: fn _args, _cwd -> {"", 0} end]
            )
          end)

        result
      end

      assert {:ok, %{result: %{verdict: :pass, scope: :none, reason: "the change touches no screen; the app built and launched", app_check: app_check}}} =
               run.(AppCheckSession)

      assert app_check == %{built: true, launched: true, checked: true}

      # The agent is told when such a pass applies, and what Symphony accepts it on.
      assert_received {:qa_turn, _session, prompt, _issue, _turn_opts}
      assert prompt =~ "Nothing on screen to judge:"
      assert prompt =~ ~r/Symphony accepts that pass only when the build, the launch and a healthy `qa_check_app` all\s+ran/
      assert prompt =~ ~s("scope": "<optional: none, on a pass with nothing to judge on screen>")

      # A pass that never checked the app, or never started it, carries that too; QA verification
      # does not accept it (`SymphonyElixir.QaVerification`).
      assert {:ok, %{result: %{verdict: :pass, scope: :none, app_check: launched}}} = run.(LaunchOnlySession)
      assert launched == %{built: true, launched: true, checked: false}
      assert {:ok, %{result: %{verdict: :pass, scope: :none, app_check: nothing}}} = run.(FakeSession)
      assert nothing == %{built: false, launched: false, checked: false}
      assert_received {:qa_turn, _session, _prompt, _issue, _turn_opts}
      assert_received {:qa_turn, _session, _prompt, _issue, _turn_opts}

      # The QA policy found nothing on screen: the agent is told build and launch are the whole
      # check, and its pass is one with nothing to judge, whatever its answer said.
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: FakeSession.pass_json()}})

      {result, _log} =
        with_log(fn ->
          QaAgent.run(job(%{playbooks: [Map.put(macos_app, :scope, :none)]}), Config.settings!(),
            git: fake_git(),
            qa_agent_module: AppCheckSession,
            qa_driver_opts: qa_vm_opts(wide_pass_host({1920, 1200})) ++ [git: fn _args, _cwd -> {"", 0} end]
          )
        end)

      assert {:ok, %{result: %{verdict: :pass, scope: :none, reason: reason, app_check: checked}}} = result
      assert checked == %{built: true, launched: true, checked: true}
      assert reason =~ "Symphony's QA policy found nothing on screen to judge"
      assert_received {:qa_turn, _session, policy_prompt, _issue, _turn_opts}
      assert policy_prompt =~ "so build and launch are the whole check"

      # A pass without the macos_app playbook is told nothing of the kind.
      Application.delete_env(:symphony_elixir, :qa_test_turn_result)
      assert {:ok, %{result: %{verdict: :pass} = cli_pass}} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      refute Map.has_key?(cli_pass, :scope)
      assert_received {:qa_turn, _session, cli_prompt, _issue, _turn_opts}
      refute cli_prompt =~ "Nothing on screen to judge"
      refute cli_prompt =~ ~s("scope")
    end

    test "reports a pass whose QA host Symphony refused as blocked by the QA host, keeping a fail" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      host = %{
        kill: fn _pid -> :ok end,
        prepare: fn _operator_home, _canary -> {:error, {:unsafe, "has a private key ~/.ssh/id_ed25519"}} end,
        cleanup: fn _dir -> :ok end
      }

      run = fn turn_result ->
        Application.put_env(:symphony_elixir, :qa_test_turn_result, turn_result)

        {result, _log} =
          with_log(fn ->
            QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
              git: fake_git(),
              qa_agent_module: FakeSession,
              qa_driver_opts: qa_vm_opts(host)
            )
          end)

        result
      end

      assert {:ok, %{result: %{verdict: :blocked, cause: {:qa_worker, "qa_worker_unsafe"}, reason: reason}}} =
               run.({:ok, %{result: FakeSession.pass_json()}})

      assert reason =~ "The QA host qa-vm has a private key ~/.ssh/id_ed25519."

      blocked_json = Jason.encode!(%{verdict: "blocked", summary: "", reason: "every qa_* tool refused the QA host"})

      assert {:ok, %{result: %{verdict: :blocked, cause: {:qa_worker, "qa_worker_unsafe"}, reason: "every qa_* tool refused the QA host"}}} =
               run.({:ok, %{result: blocked_json}})

      fail_json = Jason.encode!(%{verdict: "fail", summary: "The CLI failed.", steps: [], findings: ["exit 1"]})
      assert {:ok, %{result: %{verdict: :fail} = failed}} = run.({:ok, %{result: fail_json}})
      refute Map.has_key?(failed, :cause)
    end

    test "holds an epic review to the wide pass only when it launched an app" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: FakeSession.pass_json()}})
      epic_job = job(%{playbooks: [macos_app], epic_review: true, base_ref: "origin/main"})

      run = fn session ->
        {result, _log} =
          with_log(fn ->
            QaAgent.run(epic_job, Config.settings!(),
              git: fake_git(),
              qa_agent_module: session,
              qa_driver_opts: qa_vm_opts(wide_pass_host({1920, 1200})) ++ [git: fn _args, _cwd -> {"", 0} end]
            )
          end)

        result
      end

      # A backend-only epic: the review never launched the app, so there was no window to widen.
      assert {:ok, %{result: %{verdict: :pass}}} = run.(FakeSession)

      assert {:ok, %{result: %{verdict: :blocked, reason: reason}}} = run.(LaunchOnlySession)
      assert reason =~ "the wide pass did not run: no `qa_resize_window` call resized the app's window"

      assert {:ok, %{result: %{verdict: :pass}}} = run.(WidePassSession)

      # The epic review judges the merged result: an answer of nothing to judge on screen does not
      # excuse its wide pass, and its prompt does not offer one.
      scope_none = Jason.encode!(%{verdict: "pass", summary: "Nothing to judge.", scope: "none", reason: "no screen"})
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: scope_none}})
      assert {:ok, %{result: %{verdict: :blocked, reason: reason}}} = run.(LaunchOnlySession)
      assert reason =~ "the wide pass did not run"

      assert {:ok, %{result: %{verdict: :pass}}} =
               (fn ->
                  {result, _log} =
                    with_log(fn ->
                      QaAgent.run(%{epic_job | playbooks: [Map.put(macos_app, :scope, :none)]}, Config.settings!(),
                        git: fake_git(),
                        qa_agent_module: FakeSession,
                        qa_driver_opts: qa_vm_opts(wide_pass_host({1920, 1200})) ++ [git: fn _args, _cwd -> {"", 0} end]
                      )
                    end)

                  result
                end).()

      assert_received {:qa_turn, _session, epic_prompt, _issue, _turn_opts}
      refute epic_prompt =~ "Nothing on screen to judge:"
      refute epic_prompt =~ ~s("scope": "<optional)
    end

    test "lets the QA driver read fixtures from the pass's own $TMPDIR" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      assert {:ok, %{result: %{verdict: :inconclusive}}} =
               QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: PutFileSession,
                 qa_driver_opts: qa_vm_opts()
               )

      # The QA host gets a copy of the checked file in its run directory.
      assert_receive {:put_file, tmp_dir, {:ok, %{"path" => path, "bytes" => 10}}}
      assert String.ends_with?(path, "/files/symphony.yml")
      refute String.starts_with?(path, tmp_dir)
    end

    test "gives an android_app pass an Android QA driver and stops it when the pass ends" do
      test = self()
      lease = %{lease: make_ref(), serial: "emulator-5600", adb: "/sdk/platform-tools/adb", adb_server_port: 15_037}
      android_app = %{kind: "android_app", paths: [], prompt: "Test the Android app.", build: "./gradlew assembleDebug", apk_paths: ["app.apk"], application_ids: ["com.example.app"]}

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [android_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 qa_android_driver_opts: [
                   checkout: fn -> {:ok, lease} end,
                   checkin: fn lease -> send(test, {:checked_in, lease}) && :ok end,
                   cmd: fn executable, args, _opts -> send(test, {:cmd, executable, args}) && {:ok, {"Success", 0}} end
                 ]
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      driver = session_opts[:qa_android_driver]
      assert is_pid(driver)
      assert session_opts[:qa_driver] == nil
      assert_receive {:qa_turn, _session, _prompt, _issue, turn_opts}
      assert turn_opts[:qa_android_driver] == driver
      refute Process.alive?(driver)
      assert_received {:checked_in, ^lease}
      assert_received {:cmd, "/sdk/platform-tools/adb", [_port_flag, _port, "-s", "emulator-5600", "uninstall", "com.example.app"]}

      assert {:ok, _result} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      assert_receive {:qa_session_started, _worktree, cli_opts}
      assert cli_opts[:qa_android_driver] == nil
    end

    test "lets the Android QA driver put fixtures from the pass's own $TMPDIR into Downloads" do
      test = self()
      lease = %{lease: make_ref(), serial: "emulator-5600", adb: "/sdk/platform-tools/adb", adb_server_port: 15_037}
      android_app = %{kind: "android_app", paths: [], prompt: "Test the Android app.", build: "./gradlew assembleDebug", apk_paths: ["app.apk"], application_ids: ["com.example.app"]}

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [android_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: AndroidPutFileSession,
                 qa_android_driver_opts: [
                   checkout: fn -> {:ok, lease} end,
                   checkin: fn _lease -> :ok end,
                   cmd: fn _executable, args, _opts -> send(test, {:adb, Enum.drop(args, 4)}) && {:ok, {"", 0}} end
                 ]
               )

      assert_receive {:put_file, _tmp_dir, {:ok, %{"path" => "Download/rows.csv", "bytes" => 13}}}
      assert_received {:adb, ["push", _copy, "/sdcard/Download/rows.csv"]}
    end

    test "an Android change in a repo without the android_app playbook gets its device steps blocked, not an emulator" do
      walkthrough = "## User walkthrough\n\n1. Open the app on a foldable.\n   The list and detail panes show side by side."
      android_change = issue(%{description: walkthrough})

      assert {:run, playbooks} =
               Selection.decide(android_change, ["app/src/main/java/com/example/app/AdaptiveLayout.kt"], %{playbooks: %{}})

      refute Enum.any?(playbooks, &(&1.kind == "android_app"))

      # A compliant agent: the qa_android_* tools refuse without the playbook, so it marks the
      # device step blocked with the reason the prompt and the tool error give.
      {:error, {:qa_tool, "qa_android_driver_unavailable", tool_message}} = AndroidDriver.call_tool(nil, "qa_android_install", %{})
      assert tool_message =~ "Do not start an emulator or adb yourself"
      assert tool_message =~ AndroidDriver.no_playbook_reason()

      blocked =
        Jason.encode!(%{
          verdict: "blocked",
          summary: "The device steps need an Android emulator this repo does not configure.",
          steps: [%{name: "Open the app on a foldable", status: "blocked", details: AndroidDriver.no_playbook_reason(), evidence: []}],
          reason: AndroidDriver.no_playbook_reason()
        })

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: blocked}})

      assert {:ok, %{result: %{verdict: :blocked, reason: "no Android QA playbook configured for this repo", steps: [%{status: "blocked"}]}}} =
               QaAgent.run(job(%{issue: android_change, playbooks: playbooks}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 qa_android_driver_opts: [checkout: fn -> flunk("a pass without the android_app playbook must not boot an emulator") end]
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      assert session_opts[:qa_android_driver] == nil
      assert_receive {:qa_turn, _session, prompt, _issue, _turn_opts}
      assert prompt =~ "Never start an emulator, a simulator or a device tool yourself"
      assert prompt =~ ~r/mark that step `blocked`\s+with "no Android QA playbook configured for this repo"/
      refute prompt =~ "### Playbook: android_app"
    end

    test "gives a web pass the dev server and a browser MCP server limited to localhost, then stops the server" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [web]}), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification,
                 npx: fake_npx({"Version 0.0.83\n", 0})
               )

      assert_receive {:npx, ["--no", "@playwright/mcp@0.0.83", "--version"]}
      server_worktree = worktree <> "-dev-server"
      workspace = job().workspace_path
      assert_receive {:git, ["worktree", "add", "--detach", ^server_worktree, @sha], ^workspace}
      assert_receive {:dev_server_started, "TP-900", "qa-run-1", ^server_worktree, start_opts}
      assert start_opts[:repo_key] == "default"
      assert start_opts[:settings] == settings
      assert_receive {:qa_session_started, ^worktree, session_opts}
      assert %{servers: %{"browser" => browser}} = session_opts[:settings].agent.mcp
      assert browser.command == "npx"
      assert browser.runtimes == [settings.agent.kind]

      assert ["--no", "@playwright/mcp@0.0.83", "--browser", "chromium", "--headless", "--isolated", "--allowed-origins", origins, "--output-dir", output] =
               browser.args

      assert origins == "http://localhost:4321;http://127.0.0.1:4321"
      assert QaAgent.playwright_mcp_package() == "@playwright/mcp@0.0.83"
      refute Enum.any?(browser.args, &String.contains?(&1, "@latest"))
      assert output == Path.join(worktree, "qa-evidence")
      assert settings.agent.network_access.mode == "allowlist"
      assert ["localhost", "127.0.0.1"] -- session_opts[:settings].agent.network_access.allowed_domains == []
      refute "localhost" in settings.agent.network_access.allowed_domains

      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "### Playbook: web"
      assert prompt =~ "dev server for this PR head at http://localhost:4321/"
      assert_receive {:dev_server_stopped, 4321}
      assert_receive {:git, ["worktree", "remove", "--force", ^server_worktree], ^workspace}
      refute File.exists?(server_worktree)

      # Executor-style passes get neither the dev server nor the browser.
      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, verification: FakeVerification)
      refute_receive {:dev_server_started, _identifier, _run_id, _worktree, _opts}
      assert_receive {:qa_session_started, _worktree, cli_opts}
      refute Map.has_key?(cli_opts[:settings].agent.mcp.servers, "browser")
      refute QaAgent.prompt(job(), nil) =~ "Dev server:"
    end

    test "gives a dev_server playbook's pass the real server outside the agent sandbox, without a browser" do
      config = %{playbooks: %{"cli" => %{"enabled" => false}, "server" => %{"paths" => ["server/**"], "prompt" => "### Playbook: server", "dev_server" => true}}}
      [web, server] = Selection.playbooks(config, dev_server?: true)
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [server]}), settings, git: fake_git(), qa_agent_module: FakeSession, verification: FakeVerification)

      server_worktree = worktree <> "-dev-server"
      assert_receive {:dev_server_started, "TP-900", "qa-run-1", ^server_worktree, _start_opts}
      assert_receive {:qa_session_started, ^worktree, session_opts}
      refute Map.has_key?(session_opts[:settings].agent.mcp.servers || %{}, "browser")
      assert ["localhost", "127.0.0.1"] -- session_opts[:settings].agent.network_access.allowed_domains == []

      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      flat = String.replace(prompt, ~r/\s+/, " ")
      assert flat =~ "dev server for this PR head at http://localhost:4321/, from its own worktree and outside your sandbox"
      assert flat =~ "Your shell can reach it. It is the real server built from this PR"
      refute flat =~ "The `browser` MCP server and your shell can reach it."
      assert_receive {:dev_server_stopped, 4321}
      refute File.exists?(server_worktree)

      web_prompt = QaAgent.prompt(job(%{playbooks: [web], dev_server_url: "http://localhost:4321/"}), nil)
      assert String.replace(web_prompt, ~r/\s+/, " ") =~ "The `browser` MCP server and your shell can reach it."
    end

    test "uses the operator's browser MCP server and leaves other network modes alone" do
      glance = %{playbooks: %{"cli" => %{"enabled" => false}, "web" => %{"browser_mcp" => %{"command" => "glance-mcp", "args" => ["--stdio"]}}}}
      [web] = Selection.playbooks(glance, dev_server?: true)
      settings = Config.settings!()
      open_settings = put_in(settings.agent.network_access.mode, "open")

      assert {:ok, _result} =
               QaAgent.run(job(%{playbooks: [web], run_id: nil, repo_key: nil}), open_settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification
               )

      assert_receive {:dev_server_started, "TP-900", "qa-TP-900-0123456789ab", server_worktree, start_opts}
      assert String.ends_with?(server_worktree, "-dev-server")
      refute Keyword.has_key?(start_opts, :repo_key)
      assert_receive {:qa_session_started, _worktree, session_opts}
      assert %{command: "glance-mcp", args: ["--stdio"]} = session_opts[:settings].agent.mcp.servers["browser"]
      assert session_opts[:settings].agent.network_access == open_settings.agent.network_access
      assert_receive {:dev_server_stopped, 4321}
    end

    test "a dev server that does not start, or an invalid browser server, ends the pass before the agent runs" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)
      unhealthy = {:verification_failed, :health_timeout}
      Application.put_env(:symphony_elixir, :qa_test_dev_server_result, {:error, unhealthy})

      assert {:error, {:qa_dev_server_failed, ^unhealthy}, %{total_tokens: 0}} =
               run_web(web)

      assert_receive {:dev_server_started, "TP-900", _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
      refute_receive {:dev_server_stopped, _port}

      Application.delete_env(:symphony_elixir, :qa_test_dev_server_result)
      remote = %{"web" => %{"browser_mcp" => %{"transport" => "http", "url" => "http://glance.test/mcp", "runtimes" => ["codex"]}}}
      [web] = Selection.playbooks(%{playbooks: Map.put(remote, "cli", %{"enabled" => false})}, dev_server?: true)

      assert {:error, {:qa_browser_mcp_invalid, errors}, _tokens} =
               run_web(web)

      assert errors =~ "runtimes"
      assert_receive {:dev_server_started, "TP-900", _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
      assert_receive {:dev_server_stopped, 4321}

      assert {:error, {:qa_dev_server_failed, {:qa_worktree_failed, 128, "fatal: no space"}}, _tokens} =
               QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
                 git: fake_git(%{add_dev_server: {"fatal: no space\n", 128}}),
                 qa_agent_module: FakeSession,
                 verification: FakeVerification
               )

      refute_receive {:dev_server_started, _identifier, _run_id, _worktree, _opts}
      refute_receive {:qa_session_started, _worktree, _opts}
    end

    test "a missing npx or pinned Playwright MCP package ends the pass before the agent runs, without fetching it" do
      [web] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}}}, dev_server?: true)

      for {npx_result, reason} <- [
            {{:error, :enoent}, :no_npx},
            {{"npx canceled due to missing packages and no YES option\n", 1}, "@playwright/mcp@0.0.83"}
          ] do
        assert {:error, {:qa_browser_mcp_unavailable, ^reason}, %{total_tokens: 0}} =
                 QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
                   git: fake_git(),
                   qa_agent_module: FakeSession,
                   verification: FakeVerification,
                   npx: fake_npx(npx_result)
                 )

        assert_receive {:npx, ["--no", "@playwright/mcp@0.0.83", "--version"]}
        refute_receive {:qa_session_started, _worktree, _opts}
        assert_receive {:dev_server_stopped, 4321}
      end
    end

    test "npx runs the npx found on PATH and reports when there is none" do
      assert QaAgent.npx(["--version"], fn "npx" -> nil end) == {:error, :enoent}
      assert {_output, 0} = QaAgent.npx(["--version"], fn "npx" -> System.find_executable("true") end)

      case System.find_executable("npx") do
        nil -> assert QaAgent.npx(["--version"]) == {:error, :enoent}
        _npx -> assert {_output, 0} = QaAgent.npx(["--version"])
      end
    end

    test "falls back to the streamed agent text when the turn result has no verdict" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, FakeSession.pass_json()}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: "I tested it."}})

      assert {:ok, %{result: %{verdict: :pass}}} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "asks for the verdict in a follow-up turn of the same session when the answer has none" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:session_started, "sess-qa"}, {:agent_text, "Testing."}])

      Application.put_env(:symphony_elixir, :qa_test_turn_results, [
        {:ok, %{result: "I'll wait for the live run to finish before writing the transcript."}},
        {:ok, %{result: FakeSession.pass_json()}}
      ])

      log =
        capture_log(fn ->
          assert {:ok, %{result: %{verdict: :pass, follow_ups: 1}}} =
                   QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
        end)

      assert log =~ "QA agent answered without a verdict for TP-900"
      assert_receive {:qa_turn, session, first_prompt, _issue, first_opts}
      assert first_prompt =~ "### Playbook: cli"
      assert first_opts[:resume_session_id] == nil
      assert_receive {:qa_turn, ^session, follow_up, _issue, follow_up_opts}
      assert follow_up == QaAgent.follow_up_prompt()
      assert follow_up =~ ~r/Return only the JSON\s+verdict object/
      assert follow_up_opts[:resume_session_id] == "sess-qa"
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}
      assert_receive {:qa_session_stopped, ^session}
    end

    test "records blocked with no_verdict_object when the follow-up has no verdict either" do
      Application.put_env(:symphony_elixir, :qa_test_turn_results, [{:ok, %{result: "Still waiting."}}, {:ok, %{result: "Still waiting."}}])

      capture_log(fn ->
        assert {:error, {:malformed_qa_response, :no_verdict_object}, _tokens} =
                 QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      end)

      assert_receive {:qa_turn, _session, _prompt, _issue, _opts}
      assert_receive {:qa_turn, _session, follow_up, _issue, follow_up_opts}
      assert follow_up == QaAgent.follow_up_prompt()
      assert follow_up_opts[:resume_session_id] == nil
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}

      Application.put_env(:symphony_elixir, :qa_test_turn_results, [{:ok, %{result: "Still waiting."}}, {:error, :turn_timeout}])

      capture_log(fn ->
        assert {:error, {:qa_agent_failed, :turn_timeout}, _tokens} =
                 QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      end)
    end

    test "reports malformed answers and agent failures as errors with the tokens spent" do
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      # Only a missing verdict object earns a follow-up; a malformed one does not.
      assert_receive {:qa_turn, _session, _prompt, _issue, _opts}
      refute_receive {:qa_turn, _session, _prompt, _issue, _opts}

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{}})

      assert {:error, {:malformed_qa_response, :empty_response}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:error, :turn_timeout})

      assert {:error, {:qa_agent_failed, :turn_timeout}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_start_result, {:error, :port_failed})

      assert {:error, {:qa_agent_failed, :port_failed}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "stops the turn at the per-issue token limit" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 900, "output_tokens" => 200, "total_tokens" => 1_100}}}
      ])

      assert {:error, {:qa_token_limit, 1_100, 1_000}, %{total_tokens: 1_100}} =
               QaAgent.run(job(%{token_limit: 1_000}), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      assert_receive {:qa_session_stopped, _session}
    end

    test "runs the commit fetch once more after cannot lock ref" do
      {:ok, fetches} = Agent.start_link(fn -> [{"error: cannot lock ref 'refs/remotes/origin/main': is at 784f59f4 but expected a2d3de89\n", 1}, {"fatal: no such ref", 128}] end)
      fetch = fn -> Agent.get_and_update(fetches, fn [result | rest] -> {result, rest} end) end
      git = fake_git(%{cat_file: {"missing", 1}, fetch: fetch})

      assert {:error, {:qa_commit_unavailable, @sha, 128, "fatal: no such ref"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      assert Agent.get(fetches, & &1) == []
      assert_received {:git, ["fetch", "--quiet", "origin", @sha], _workspace}
      assert_received {:git, ["fetch", "--quiet", "origin", @sha], _workspace}
    end

    test "fetches a missing commit and reports worktree failures" do
      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"fatal: no such ref", 128}})

      assert {:error, {:qa_commit_unavailable, @sha, 128, "fatal: no such ref"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"", 0}, add: {"fatal: busy\n", 128}})

      assert {:error, {:qa_worktree_failed, 128, "fatal: busy"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      assert_receive {:git, ["fetch", "--quiet", "origin", @sha], _workspace}
    end

    test "keeps the first parse error when every candidate is malformed" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, ~s({"verdict":"pass","steps":"x"})}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "runs against a real git workspace without a parent lookup on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      repo = Path.join(System.tmp_dir!(), "qa-agent-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      git! = fn args ->
        {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
        String.trim(output)
      end

      git!.(["init", "--quiet"])
      git!.(["config", "user.email", "qa@example.test"])
      git!.(["config", "user.name", "QA"])
      File.write!(Path.join(repo, "a.txt"), "a\n")
      git!.(["add", "."])
      git!.(["commit", "--quiet", "-m", "a"])
      head = git!.(["rev-parse", "HEAD"])
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", head)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{workspace_path: repo, sha: head}), settings, qa_agent_module: FakeSession)

      assert_receive {:qa_session_started, ^worktree, _opts}
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      refute prompt =~ "Parent issue"
      refute File.exists?(worktree)
      assert git!.(["worktree", "list"]) =~ repo
      refute git!.(["worktree", "list"]) =~ worktree
    end

    test "maps runtimes to agent modules" do
      assert {:ok, SymphonyElixir.Codex.AppServer} = QaAgent.agent_module("codex")
      assert {:ok, SymphonyElixir.ClaudeCode.AppServer} = QaAgent.agent_module("claude")
      assert {:error, {:unsupported_qa_agent_kind, nil}} = QaAgent.agent_module(nil)
    end

    test "does not run on remote workers or unknown runtimes" do
      assert {:error, {:remote_worker_unsupported, "worker-1"}, %{total_tokens: 0}} =
               QaAgent.run(job(%{worker_host: "worker-1"}), Config.settings!())

      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{runtime: "claude"})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | kind: "gpt"}}

      assert {:error, {:unsupported_qa_agent_kind, "gpt"}, _tokens} = QaAgent.run(job(), settings, git: fake_git())
    end

    test "reads the parent issue from Linear for sub-tickets and survives a failed read" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      settings = Config.settings!()
      recipient = self()

      linear_client = fn query, _variables, _opts ->
        send(recipient, {:linear_query, query})
        {:ok, %{"data" => %{"issue" => %{"parent" => %{"identifier" => "TP-243", "title" => "Parent", "description" => "parent criterion"}}}}}
      end

      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: linear_client)
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "parent criterion"

      failing_client = fn _query, _variables, _opts -> {:error, :linear_down} end

      log =
        capture_log(fn ->
          assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: failing_client)
        end)

      assert log =~ "QA could not read the parent issue for TP-900"

      no_parent = fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => %{"parent" => nil}}}} end
      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: no_parent)
    end

    test "downloads the parent's screens into the pass's own folder and names them in the prompt" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      settings = Config.settings!()
      screens = %{"title" => "screens.html", "url" => "https://uploads.linear.app/org/asset/screens", "createdAt" => "2026-10-03T00:00:00Z"}

      linear_client = fn query, _variables, _opts ->
        if query =~ "SymphonyQaDesignAttachments",
          do: {:ok, %{"data" => %{"issue" => %{"identifier" => "TP-900", "parent" => %{"identifier" => "TP-243", "attachments" => %{"nodes" => [screens]}}}}}},
          else: {:ok, %{"data" => %{"issue" => %{"parent" => %{"identifier" => "TP-243", "title" => "Parent", "description" => "plan"}}}}}
      end

      download_client = fn _url, _opts -> {:ok, %{status: 200, body: "<html>screens</html>"}} end

      assert {:ok, _result} =
               QaAgent.run(job(), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 linear_client: linear_client,
                 download_client: download_client
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      tmp_dir = session_opts[:extra_env] |> Map.values() |> Enum.find(&String.contains?(&1, "symphony-qa-"))
      assert prompt =~ "- `#{Path.join([tmp_dir, "design", "TP-243-screens.html"])}` (attached to TP-243)"
      refute File.exists?(tmp_dir)
    end
  end

  defp run_web(web) do
    QaAgent.run(job(%{playbooks: [web]}), Config.settings!(),
      git: fake_git(),
      qa_agent_module: FakeSession,
      verification: FakeVerification,
      npx: fake_npx({"Version 0.0.83\n", 0})
    )
  end

  defp fake_npx(result) do
    test_pid = self()

    fn args ->
      send(test_pid, {:npx, args})
      result
    end
  end

  describe "Report" do
    test "renders a passing report with steps, evidence and accounting" do
      body =
        Report.render(%{
          verdict: :pass,
          sha: @sha,
          target_state: "In Review",
          summary: "All good.",
          steps: [
            %{name: "check", status: "pass", details: "$ bin/symphony check\n```\nexit: 0", evidence: ["https://u/t.md"]},
            %{name: "help", status: "skipped", details: " ", evidence: []}
          ],
          findings: [],
          playbooks: ["cli"],
          runtime_seconds: 83,
          tokens: %{total_tokens: 85_412}
        })

      assert body =~ "## Symphony QA Report"
      assert body =~ "**Verdict:** pass → In Review"
      assert body =~ "`0123456789ab` · playbooks: cli · 1m 23s · 85412 tokens"
      assert body =~ "All good."
      assert body =~ "- **pass** check (evidence: https://u/t.md)"
      assert body =~ "  exit: 0"
      assert body =~ "'''"
      assert body =~ "- **skipped** help\n"
    end

    test "renders fail, escalation, skip and blocked outcomes" do
      fail =
        Report.render(%{verdict: :fail, sha: @sha, target_state: "In Progress", fix_attempt: 1, max_fix_attempts: 2, findings: ["exit 0 on bad config"]})

      assert fail =~ "fail (fix attempt 1 of 2) → In Progress"
      assert fail =~ "### Findings\n\n- exit 0 on bad config"

      escalated = Report.render(%{verdict: :fail, sha: @sha, target_state: "In Review", escalated: true, tokens: %{}, runtime_seconds: 0})
      assert escalated =~ "fix attempts used up"
      refute escalated =~ "follow-up"

      followed_up = Report.render(%{verdict: :fail, sha: @sha, target_state: "In Progress", findings: ["x"], follow_ups: 2})
      assert followed_up =~ "`0123456789ab` · verdict after 2 follow-ups"

      assert Report.render(%{verdict: :pass, sha: @sha, target_state: "Merging", follow_ups: 1}) =~ "verdict after 1 follow-up"

      skip = Report.render(%{verdict: :skip, sha: nil, target_state: "In Review", reason: "docs only"})
      assert skip =~ "**Verdict:** skipped → In Review"
      assert skip =~ "Reason: docs only"

      blocked = Report.render(%{verdict: :blocked, sha: @sha, target_state: "In Review", reason: "no mix", summary: "ignored"})
      assert blocked =~ "Reason: no mix"
      refute blocked =~ "ignored"

      inconclusive = Report.render(%{verdict: :inconclusive, sha: @sha, target_state: "QA (inconclusive, rerunning)", reason: "no wide pass", summary: "ignored"})
      assert inconclusive =~ "**Verdict:** inconclusive → QA (inconclusive, rerunning)"
      assert inconclusive =~ "Reason: no wide pass"
      refute inconclusive =~ "ignored"

      nothing = Report.render(%{verdict: :pass, scope: :none, sha: @sha, target_state: "Merging", reason: "the change touches no screen", summary: ""})
      assert nothing =~ "**Verdict:** pass (nothing on screen to judge; the app built and launched) → Merging"
      assert nothing =~ "\nWhy nothing was judged on screen: the change touches no screen\n"

      long = Report.render(%{verdict: :pass, sha: @sha, target_state: "In Review", steps: [%{name: "x", status: "pass", details: String.duplicate("a", 2_100), evidence: []}]})
      assert long =~ "[... truncated ...]"
    end

    test "renders a parent walkthrough with the base branch commit, the verification ticket and filed tickets" do
      body =
        Report.render(%{
          verdict: :fail,
          sha: @sha,
          ref: "origin/main",
          target_state: "Backlog",
          target_issue: "TP-910",
          findings: ["Settings is empty"],
          filed: [%{identifier: "TP-912", title: "Parent walkthrough fails: open Settings"}]
        })

      assert body =~ "**Verdict:** fail → TP-910 Backlog"
      assert body =~ "**Commit:** `0123456789ab` (head of `origin/main`)"
      refute body =~ "PR head"
      assert body =~ "### Filed tickets\n\n- TP-912 Parent walkthrough fails: open Settings"
    end

    test "renders the epic review's pre-checks, and nothing when a run carries none" do
      body =
        Report.render(%{
          verdict: :pass,
          sha: @sha,
          target_state: "Done",
          checks: [
            %{name: :artifacts, status: :ok, detail: "all 2 sub-issue(s) terminal"},
            %{name: :comments, status: :attention, detail: "1 comment(s) to account for, the newest from kim"}
          ]
        })

      assert body =~
               "### Pre-checks\n\n- **ok** artifacts: all 2 sub-issue(s) terminal\n" <>
                 "- **attention** comments: 1 comment(s) to account for, the newest from kim"

      # The QA and walkthrough reports carry no pre-checks, so their format is unchanged.
      refute Report.render(%{verdict: :pass, sha: @sha, target_state: "In Review"}) =~ "### Pre-checks"
      refute Report.render(%{verdict: :pass, sha: @sha, target_state: "In Review", checks: []}) =~ "### Pre-checks"
    end

    test "creates the report comment on Linear and then rewrites it in place" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      recipient = self()

      client = fn comments ->
        fn query, variables, _opts ->
          send(recipient, {:linear, query, variables})

          cond do
            query =~ "comments(" ->
              {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => comments}}}}}

            query =~ "commentCreate" ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-new"}}}}}

            query =~ "commentUpdate" ->
              {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
          end
        end
      end

      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nnew", linear_client: client.([%{"id" => "w", "body" => "## Symphony Workpad"}, %{"body" => nil}]))
      assert_receive {:linear, create, %{body: "## Symphony QA Report\n\nnew"}}
      assert create =~ "commentCreate"

      existing = [%{"id" => "c-qa", "body" => "## Symphony QA Report\n\nold"}]
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nv2", linear_client: client.(existing))
      assert_receive {:linear, update, %{id: "c-qa", body: "## Symphony QA Report\n\nv2"}}
      assert update =~ "commentUpdate"

      failing = fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}, "x" => 1}} end
      assert {:error, _reason} = Report.publish(issue(), "## Symphony QA Report", linear_client: failing)
    end

    test "posts a new comment on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n")
      assert_receive {:memory_tracker_comment, "issue-qa", "## Symphony QA Report\n"}
      assert Report.heading() == "## Symphony QA Report"
    end
  end
end
