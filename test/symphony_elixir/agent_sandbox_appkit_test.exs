defmodule SymphonyElixir.AgentSandboxAppKitTest do
  # Whether an AppKit program an agent starts can put a window or a "quit unexpectedly" dialog on
  # the desktop. It runs a minimal `NSApplication` + `NSWindow` program (`test/support/appkit_probe`)
  # under the agent profile: the one an SRT install generates from Symphony's SRT settings. Claude
  # Code runs SRT's profile too, and neither runtime gets extra mach services from Symphony, so both
  # allow LaunchServices and deny the window server. Two control runs outside the sandbox first
  # show that this machine draws the probe's window and sees the probe check in with
  # LaunchServices. Then the probe runs twice in the sandbox: a plain run for the window, and a
  # `crash` run for the dialog.
  #
  # The check-in is what makes ReportCrash treat a crashed process as an app and show its "quit
  # unexpectedly" dialog. The GitHub runner showed no crash dialog even outside the sandbox, so the
  # check-in stands in for the dialog: a sandboxed probe that never checks in can't get one. The
  # dialogs on screen are still watched and recorded.
  #
  # It puts windows and dialogs on screen, so it runs only with `--only appkit_dialog`, on the
  # `appkit-dialog` workflow's disposable macOS runner. Never on the host: they would land on the
  # operator's desktop.
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentSandboxConfig

  @moduletag :appkit_dialog
  @moduletag timeout: 300_000

  @probe_source Path.expand("../support/appkit_probe/probe.swift", __DIR__)
  @windows_source Path.expand("../support/appkit_probe/windows.swift", __DIR__)
  # The processes that draw the "quit unexpectedly" dialog, by macOS release.
  @dialog_owners ["Problem Reporter", "UserNotificationCenter", "CrashReporter", "ReportCrash"]
  @reports_dir Path.expand("~/Library/Logs/DiagnosticReports")
  # What the probe prints to stderr before it touches AppKit.
  @started "TP-479 probe started"
  # An app name in `lsappinfo list` and in `lsappinfo listen` notifications.
  @app_name ~r/"([^"]+)"/

  setup do
    root = Path.join(System.tmp_dir!(), "appkit-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    probe = compile!(@probe_source, Path.join(root, "probe"))
    windows = compile!(@windows_source, Path.join(root, "windows"))
    # Its own name, so its window and crash report tell apart from the sandboxed run's.
    control = Path.join(root, "control-probe")
    File.cp!(probe, control)

    artifacts = System.get_env("APPKIT_PROBE_ARTIFACTS") || root
    File.mkdir_p!(artifacts)

    {:ok, root: root, probe: probe, control: control, windows: windows, artifacts: artifacts}
  end

  test "an AppKit program in the agent sandbox puts no window and no crash dialog on screen", context do
    %{root: root, probe: probe, control: control, windows: windows, artifacts: artifacts} = context
    srt = srt_cli!()
    settings = Path.join(root, "srt-settings.json")
    {:ok, srt_settings} = AgentSandboxConfig.srt_settings("block", [], [], [], allow_write_paths: [root])
    File.write!(settings, Jason.encode!(srt_settings))

    # The profile is the one the agents get: no window server, but LaunchServices.
    assert {"1100\n", 0} = srt_run(srt, settings, root, lookup_command("com.apple.windowserver.active"))
    assert {"0\n", 0} = srt_run(srt, settings, root, lookup_command("com.apple.coreservices.launchservicesd"))

    window_control = observe(windows, 8_000, fn -> System.cmd(control, [], stderr_to_stdout: true) end)
    screenshot(artifacts, "control-window.png")

    assert "control-probe" in window_control.owners,
           "the control run showed no window, so this machine can't answer the check: #{inspect(window_control.owners)}"

    crash_control = observe(windows, 60_000, fn -> System.cmd(control, ["crash"], stderr_to_stdout: true) end, &dialog?/1)
    screenshot(artifacts, "control-dialog.png")
    dismiss_dialogs(windows)

    sandboxed = observe(windows, 30_000, fn -> srt_run(srt, settings, root, probe) end)
    screenshot(artifacts, "sandboxed-window.png")
    dismiss_dialogs(windows)

    reports_before = crash_reports("probe-")
    crashed = observe(windows, 30_000, fn -> srt_run(srt, settings, root, "#{probe} crash") end, &dialog?/1)
    screenshot(artifacts, "sandboxed-crash.png")
    reports = crash_reports("probe-") -- reports_before
    dismiss_dialogs(windows)

    {output, status} = sandboxed.result
    {crash_output, crash_status} = crashed.result
    window? = "probe" in sandboxed.owners or "probe" in crashed.owners
    dialog? = Enum.any?(sandboxed.owners ++ crashed.owners, &dialog?/1)
    checked_in? = "probe" in sandboxed.apps or "probe" in crashed.apps
    File.write!(Path.join(artifacts, "lsappinfo-listen.txt"), Enum.join([sandboxed.notices, crashed.notices], "\n"))

    report(artifacts, [
      {"Control: window outside the sandbox", yes_no("control-probe" in window_control.owners)},
      {"Control: LaunchServices check-in outside the sandbox", yes_no("control-probe" in crash_control.apps)},
      {"Control: crash dialog outside the sandbox", yes_no(Enum.any?(crash_control.owners, &dialog?/1))},
      {"Sandboxed: probe window", yes_no(window?)},
      {"Sandboxed: LaunchServices check-in", yes_no(checked_in?)},
      {"Sandboxed: crash dialog", yes_no(dialog?)},
      {"Sandboxed: probe started", yes_no(output =~ @started)},
      {"Sandboxed crash: probe started", yes_no(crash_output =~ @started)},
      {"Sandboxed crash: new crash report", if(reports == [], do: "no", else: Enum.join(reports, ", "))},
      {"Sandboxed: exit status", to_string(status)},
      {"Sandboxed crash: exit status", to_string(crash_status)},
      {"Sandboxed: new window owners", Enum.join(Enum.uniq(sandboxed.owners ++ crashed.owners) -- sandboxed.baseline, ", ")},
      {"Sandboxed: output (tail)", tail(output)},
      {"Sandboxed crash: output (tail)", tail(crash_output)}
    ])

    # A check-in the control never shows can't be seen in the sandbox either.
    assert "control-probe" in crash_control.apps,
           "the control run never checked in with LaunchServices, so this machine can't answer the check: #{inspect(crash_control.apps)}"

    # A run that never reached AppKit shows neither, which would answer nothing.
    assert output =~ @started, "the sandboxed probe never started (exit #{status}): #{output}"
    assert crash_output =~ @started, "the sandboxed crash probe never started (exit #{crash_status}): #{crash_output}"
    assert crash_status != 0, "the sandboxed crash probe exited 0, so it never crashed: #{crash_output}"

    refute window?, "the sandboxed probe drew a window: #{output} / #{crash_output}"
    refute checked_in?, "the sandboxed probe checked in with LaunchServices, so a crash can show a dialog"
    refute dialog?, "the sandboxed probe's crash showed a dialog: #{inspect(Enum.uniq(sandboxed.owners ++ crashed.owners))}"
  end

  defp compile!(source, output) do
    {log, status} = System.cmd("swiftc", ["-O", source, "-o", output], stderr_to_stdout: true)
    assert status == 0, "swiftc #{source} failed: #{log}"
    output
  end

  defp srt_cli! do
    package = System.get_env("SRT_PACKAGE_DIR") || flunk("set SRT_PACKAGE_DIR to the SRT package folder")
    Path.join(package, "dist/cli.js")
  end

  defp srt_run(srt, settings, cwd, command) do
    System.cmd("node", [srt, "--settings", settings, "-c", command], cd: cwd, stderr_to_stdout: true)
  end

  # Prints `bootstrap_look_up`'s result for the service: 0 when found, 1100 when the sandbox
  # refuses it.
  defp lookup_command(service) do
    python = """
    import ctypes
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    port = ctypes.c_uint(0)
    bootstrap = ctypes.c_uint.in_dll(libc, "bootstrap_port").value
    print(libc.bootstrap_look_up(bootstrap, b"#{service}", ctypes.byref(port)))
    """

    "python3 -c '#{python}'"
  end

  # Runs `fun` and lists the owners of the windows on screen and the apps LaunchServices knows every
  # 250 ms, for `duration_ms` and until `fun` returns, or until an owner matches `stop?`. A
  # LaunchServices listener catches an app too short-lived for the polls.
  defp observe(windows, duration_ms, fun, stop? \\ fn _owner -> false end) do
    baseline = window_owners(windows)
    apps_before = MapSet.new(apps())
    listen_seconds = div(duration_ms, 1000) + 5
    listener = Task.async(fn -> System.cmd("lsappinfo", ["listen", "+all", "wait", "#{listen_seconds}"], stderr_to_stdout: true) end)
    Process.sleep(1_000)
    task = Task.async(fun)
    deadline = System.monotonic_time(:millisecond) + duration_ms
    {owners, apps} = poll(windows, task, deadline, stop?, {MapSet.new(), MapSet.new()})
    result = Task.await(task, 60_000)
    {notices, _status} = Task.await(listener, (listen_seconds + 30) * 1_000)
    apps = MapSet.union(apps, MapSet.new(app_names(notices)))

    %{
      baseline: baseline,
      owners: Enum.sort(MapSet.to_list(owners)),
      apps: Enum.sort(MapSet.to_list(MapSet.difference(apps, apps_before))),
      notices: notices,
      result: result
    }
  end

  defp poll(windows, task, deadline, stop?, {owners, apps}) do
    owners = MapSet.union(owners, MapSet.new(window_owners(windows)))
    apps = MapSet.union(apps, MapSet.new(apps()))
    done? = System.monotonic_time(:millisecond) >= deadline and not Process.alive?(task.pid)

    if done? or Enum.any?(owners, stop?) do
      {owners, apps}
    else
      Process.sleep(250)
      poll(windows, task, deadline, stop?, {owners, apps})
    end
  end

  defp apps do
    {output, 0} = System.cmd("lsappinfo", ["list"])
    app_names(output)
  end

  defp app_names(output), do: @app_name |> Regex.scan(output, capture: :all_but_first) |> List.flatten() |> Enum.uniq()

  defp window_owners(windows), do: windows |> windows!() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp windows!(windows) do
    {output, 0} = System.cmd(windows, [])

    for line <- String.split(output, "\n", trim: true) do
      [owner, pid, _layer] = String.split(line, "\t")
      {owner, pid}
    end
  end

  defp dialog?(owner), do: owner in @dialog_owners

  # Kills the dialogs on screen, and waits up to 5 seconds for them to go, so the next run starts
  # with none.
  defp dismiss_dialogs(windows, attempts \\ 20) do
    case for({owner, pid} <- windows!(windows), dialog?(owner), do: pid) do
      [] ->
        :ok

      pids when attempts > 0 ->
        Enum.each(pids, &System.cmd("kill", [&1], stderr_to_stdout: true))
        Process.sleep(250)
        dismiss_dialogs(windows, attempts - 1)

      pids ->
        flunk("couldn't dismiss the crash dialogs of pids #{Enum.join(pids, ", ")}")
    end
  end

  defp crash_reports(prefix) do
    case File.ls(@reports_dir) do
      {:ok, files} -> files |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  # Best effort, for 10 seconds: the runner may not let `screencapture` record the screen.
  defp screenshot(artifacts, name) do
    task = Task.async(fn -> System.cmd("screencapture", ["-x", Path.join(artifacts, name)], stderr_to_stdout: true) end)
    Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
  end

  defp tail(output), do: output |> String.split("\n", trim: true) |> Enum.take(-6) |> Enum.join(" / ")

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  # The observations, as a table in the job summary and in the artifacts folder.
  defp report(artifacts, rows) do
    table =
      Enum.map_join(rows, "\n", fn {label, value} -> "| #{label} | #{String.replace(value, "|", "\\|")} |" end)

    markdown = "### AppKit program in the agent sandbox\n\n| Observation | Result |\n| --- | --- |\n#{table}\n"
    File.write!(Path.join(artifacts, "report.md"), markdown)
    IO.puts(markdown)

    if summary = System.get_env("GITHUB_STEP_SUMMARY"), do: File.write!(summary, markdown, [:append])
  end
end
