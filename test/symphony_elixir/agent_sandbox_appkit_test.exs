defmodule SymphonyElixir.AgentSandboxAppKitTest do
  # Whether an AppKit program an agent starts can put a window or a "quit unexpectedly" dialog on
  # the desktop. It runs a minimal `NSApplication` + `NSWindow` program (`test/support/appkit_probe`)
  # under the agent profile: the one an SRT install generates from Symphony's SRT settings. Claude
  # Code runs SRT's profile too, and neither runtime gets extra mach services from Symphony, so both
  # allow LaunchServices and deny the window server. Two control runs outside the sandbox first show
  # that this machine draws the probe's window and shows a crash dialog, so a clean sandboxed run
  # means the sandbox stopped them.
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

    crash_control = observe(windows, 30_000, fn -> System.cmd(control, ["crash"], stderr_to_stdout: true) end, &dialog?/1)
    screenshot(artifacts, "control-dialog.png")
    dismiss_dialogs(windows)

    assert Enum.any?(crash_control.owners, &dialog?/1),
           "the control crash showed no dialog, so this machine can't answer the check: #{inspect(crash_control.owners)}"

    reports_before = crash_reports("probe-")
    sandboxed = observe(windows, 30_000, fn -> srt_run(srt, settings, root, probe) end)
    screenshot(artifacts, "sandboxed.png")
    reports = crash_reports("probe-") -- reports_before
    dismiss_dialogs(windows)

    {output, status} = sandboxed.result
    window? = "probe" in sandboxed.owners
    dialog? = Enum.any?(sandboxed.owners, &dialog?/1)

    report(artifacts, [
      {"Control: window outside the sandbox", yes_no("control-probe" in window_control.owners)},
      {"Control: crash dialog outside the sandbox", yes_no(Enum.any?(crash_control.owners, &dialog?/1))},
      {"Sandboxed: probe window", yes_no(window?)},
      {"Sandboxed: crash dialog", yes_no(dialog?)},
      {"Sandboxed: new crash report", if(reports == [], do: "no", else: Enum.join(reports, ", "))},
      {"Sandboxed: exit status", to_string(status)},
      {"Sandboxed: new window owners", Enum.join(sandboxed.owners -- sandboxed.baseline, ", ")},
      {"Sandboxed: output (tail)", output |> String.split("\n", trim: true) |> Enum.take(-6) |> Enum.join(" / ")}
    ])

    refute window?, "the sandboxed probe drew a window: #{output}"
    refute dialog?, "the sandboxed probe's crash showed a dialog: #{inspect(sandboxed.owners)}"
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

  # Runs `fun` and lists the owners of the windows on screen every 250 ms, for `duration_ms` and
  # until `fun` returns, or until an owner matches `stop?`.
  defp observe(windows, duration_ms, fun, stop? \\ fn _owner -> false end) do
    baseline = window_owners(windows)
    task = Task.async(fun)
    deadline = System.monotonic_time(:millisecond) + duration_ms
    owners = poll(windows, task, deadline, stop?, MapSet.new())
    result = Task.await(task, 60_000)

    %{baseline: baseline, owners: Enum.sort(MapSet.to_list(owners)), result: result}
  end

  defp poll(windows, task, deadline, stop?, seen) do
    seen = MapSet.union(seen, MapSet.new(window_owners(windows)))
    done? = System.monotonic_time(:millisecond) >= deadline and not Process.alive?(task.pid)

    if done? or Enum.any?(seen, stop?) do
      seen
    else
      Process.sleep(250)
      poll(windows, task, deadline, stop?, seen)
    end
  end

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
