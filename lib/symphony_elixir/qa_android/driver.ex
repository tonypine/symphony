defmodule SymphonyElixir.QaAndroid.Driver do
  @moduledoc """
  Host-side driver behind the Auto Review `qa_android_*` tools for the
  `android_app` playbook, one per QA pass.

  The QA agent builds the APK in its own sandbox with the playbook's `build`
  command; the host never runs it, Gradle or any other repository command. The
  host only hands the APK to the emulator of `SymphonyElixir.QaAndroid.Emulator`,
  where Android sandboxes it, and every command this driver runs is an `adb` call
  to that emulator. Every tool argument is checked here first:

  - `qa_android_install` refuses a worktree with edits to tracked files outside
    `qa-evidence/` (the APK and the build's outputs are gitignored files the
    sandboxed build creates, so those are fine). The playbook's `apk_path` must
    resolve, symlinks included, inside the worktree and name a regular file, not
    a symlink, of at most 512 MB. The host
    never parses the APK: it copies it into the driver's private directory,
    uninstalls every configured `application_ids` entry (which wipes its data)
    and every package installed since the pass's first install began, and runs
    `adb install -r` from the copy. A package the install added or replaced
    that is not in `application_ids` is uninstalled again and refused, and so is
    every package a failed install may have left;
  - `qa_android_launch` and `qa_android_stop` accept only a configured
    application ID. Launch starts the app's launcher activity, only after
    `qa_android_install` installed it in this pass, and waits until it is the
    resumed activity, or reports `qa_app_exited` with recent logcat;
  - `qa_android_screenshot` saves `adb exec-out screencap -p` to a new
    `qa-evidence/<name>.png`, with the name, never-overwrite and symlink rules of
    `qa_screenshot` (see `SymphonyElixir.QaDriver.Checks`), at most 50 times
    per pass;
  - `qa_android_ui_tree`, `qa_android_tap`, `qa_android_type`, `qa_android_key`,
    `qa_android_rotate`, `qa_android_dark_mode` and `qa_android_font_scale` act
    only while `qa_android_install` has installed a configured app in this pass.
    The tree is `uiautomator dump` read back through `adb exec-out`, parsed by
    `SymphonyElixir.QaAndroid.UiTree` and capped; tap takes a node path from the
    last tree or coordinates on the display; keys, orientations, night modes and
    font scales come from fixed allowlists; typed text is printable ASCII and
    newlines only, and every chunk is single-quoted for the device's shell, so no
    character in it can run a command. Rotate locks the rotation through the
    window manager and succeeds only once the display has turned, or fails with
    `qa_android_rotate_failed`.

  The driver takes the emulator's lease when it starts. When the emulator cannot
  run (a missing SDK or AVD, a boot timeout), every tool fails with
  `qa_android_unavailable` and tells the agent to mark the Android steps
  `blocked`. When the driver stops (the QA pass ends or crashes) it uninstalls
  the configured apps and every package installed in the pass, gives the lease
  back and removes its private directory, a
  `0700` directory under Symphony's state root, outside every path the agent
  sandbox may write.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{PathSafety, Workspace}
  alias SymphonyElixir.QaAndroid.{Emulator, UiTree}
  alias SymphonyElixir.QaDriver.{Checks, Host}

  @tools ~w(qa_android_install qa_android_launch qa_android_stop qa_android_screenshot
             qa_android_ui_tree qa_android_tap qa_android_type qa_android_key qa_android_rotate
             qa_android_dark_mode qa_android_font_scale)
  @max_apk_bytes 512 * 1024 * 1024
  @max_screenshots 50
  @adb_timeout_ms 30_000
  @install_timeout_ms 300_000
  @launch_timeout_ms 60_000
  @screenshot_timeout_ms 15_000
  @stop_timeout_ms 120_000
  @output_limit 8_000
  @dumpsys_limit 2_000_000
  @screenshot_limit 64 * 1024 * 1024
  @copy_chunk_bytes 1024 * 1024
  @resume_attempts 20
  @resume_poll_ms 500
  @logcat_lines "200"
  @png_magic <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @launcher_intent ["-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"]
  @dump_limit 2_000_000
  @tree_bytes_limit 100_000
  @default_max_depth 30
  @no_playbook_reason "no Android QA playbook configured for this repo"
  @default_max_nodes 300
  @filter_limit 200
  @type_limit 500
  @keys [
    {"back", "KEYCODE_BACK"},
    {"enter", "KEYCODE_ENTER"},
    {"ime_action", "KEYCODE_NUMPAD_ENTER"},
    {"tab", "KEYCODE_TAB"},
    {"del", "KEYCODE_DEL"},
    {"dpad_up", "KEYCODE_DPAD_UP"},
    {"dpad_down", "KEYCODE_DPAD_DOWN"},
    {"dpad_left", "KEYCODE_DPAD_LEFT"},
    {"dpad_right", "KEYCODE_DPAD_RIGHT"},
    {"escape", "KEYCODE_ESCAPE"}
  ]
  @orientations [{"portrait", "0"}, {"landscape", "1"}]
  @night_modes [{"on", "yes"}, {"off", "no"}]
  @font_scales [{0.85, "0.85"}, {1.0, "1.0"}, {1.15, "1.15"}, {1.3, "1.3"}, {1.5, "1.5"}, {1.8, "1.8"}, {2.0, "2.0"}]
  @rotation_attempts 10
  @rotation_poll_ms 500
  # What a pass that changed a setting puts back when it ends: the rotation to
  # lock, or the adb command to run.
  @setting_resets [
    rotation: {:rotation, "0"},
    dark_mode: ["shell", "cmd", "uimode", "night", "no"],
    font_scale: ["shell", "settings", "put", "system", "font_scale", "1.0"]
  ]
  @application_id ~r/\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+\z/

  @type cmd :: (String.t(), [String.t()], keyword() -> {:ok, {String.t(), integer()}} | {:error, term()})
  @type tool_error :: {:qa_tool, String.t(), String.t()}

  @doc "The `qa_android_*` tool names this driver serves."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc "The `blocked` reason for a step that needs an Android device in a pass without the android_app playbook."
  @spec no_playbook_reason() :: String.t()
  def no_playbook_reason, do: @no_playbook_reason

  @doc """
  Starts a driver for one QA pass and takes the emulator's lease.

  Options: `:worktree` (required), `:playbook` (the `android_app` playbook with
  `apk_path` and `application_ids`), `:git` (a `fn args, cwd -> {output, status}`),
  and, for tests, `:cmd` (runs an adb command, as
  `SymphonyElixir.QaDriver.Host.cmd/3`), `:checkout` and `:checkin` (as
  `SymphonyElixir.QaAndroid.Emulator.checkout/2` and `checkin/2`), `:open`
  (opens the APK, as `:file.open/2`), `:sleep` and `:max_apk_bytes`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Stops the driver, uninstalling the configured apps and giving the emulator back."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(driver) when is_pid(driver) do
    GenServer.stop(driver, :normal, @stop_timeout_ms)
  catch
    # Already gone, or stuck waiting for the emulator: the manager frees a lease
    # whose holder dies.
    :exit, _reason ->
      Process.unlink(driver)
      Process.exit(driver, :kill)
      :ok
  end

  @doc """
  Runs one `qa_android_*` tool with the agent's arguments. Returns the tool
  payload or a `{:qa_tool, code, message}` error for the agent.
  """
  @spec call_tool(pid() | nil, String.t(), map()) :: {:ok, map()} | {:error, tool_error()}
  def call_tool(nil, _tool, _args) do
    tool_error(
      "qa_android_driver_unavailable",
      "The qa_android_* tools drive an Android app and are only available when the android_app playbook runs in this QA pass. " <>
        "Do not start an emulator or adb yourself: your sandbox cannot run them. " <>
        "Mark each step that needs an Android device `blocked` with \"#{@no_playbook_reason}\" in `details`."
    )
  end

  def call_tool(driver, tool, args) when is_pid(driver) and tool in @tools and is_map(args) do
    # The first call waits while the emulator boots.
    case GenServer.call(driver, :config, :infinity) do
      %{unavailable: {:error, _reason} = error} -> error
      config -> run_tool(tool, driver, config, args)
    end
  catch
    :exit, _reason -> tool_error("qa_android_driver_unavailable", "The Android QA driver for this pass has stopped.")
  end

  # -- tools ------------------------------------------------------------------

  defp run_tool("qa_android_install", driver, config, _args) do
    with :ok <- ensure_tracked_unchanged(config),
         {:ok, copy} <- copy_apk(config) do
      try do
        install(driver, config, copy)
      after
        File.rm(copy)
      end
    end
  end

  defp run_tool("qa_android_launch", driver, config, args) do
    with {:ok, id} <- application_id(config, args),
         :ok <- GenServer.call(driver, {:installed?, id}),
         {:ok, activity} <- launcher_activity(config, id),
         {:ok, output} <- adb_ok(config, ["shell", "am", "start", "-W" | @launcher_intent] ++ ["-n", activity], @launch_timeout_ms),
         :ok <- started(output, activity) do
      Logger.info("Android QA launched application_id=#{id} activity=#{activity}")
      await_resumed(config, id, activity, nil, @resume_attempts)
    end
  end

  defp run_tool("qa_android_stop", _driver, config, args) do
    with {:ok, id} <- application_id(config, args),
         {:ok, _output} <- adb_ok(config, ["shell", "am", "force-stop", id], @adb_timeout_ms) do
      {:ok, %{"application_id" => id, "stopped" => true}}
    end
  end

  defp run_tool("qa_android_screenshot", driver, config, args) do
    with {:ok, name} <- Checks.screenshot_name(Map.get(args, "name")),
         :ok <- GenServer.call(driver, :screenshot_slot),
         {:ok, evidence} <- Checks.ensure_evidence_dir(config.worktree),
         {:ok, png} <- screencap(config),
         file = name <> ".png",
         :ok <- Checks.write_evidence(Path.join(evidence, file), png, file) do
      GenServer.call(driver, :screenshot_taken)
      {:ok, %{"path" => Path.join(Checks.evidence_dir(), file)}}
    end
  end

  defp run_tool("qa_android_ui_tree", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, text} <- optional_string(args, "text"),
         {:ok, resource_id} <- optional_string(args, "resource_id"),
         {:ok, class} <- optional_string(args, "class"),
         {:ok, max_depth} <- optional_integer(args, "max_depth", 100, @default_max_depth),
         {:ok, max_nodes} <- optional_integer(args, "max_nodes", 1_000, @default_max_nodes),
         {:ok, entries} <- ui_dump(config) do
      filters = %{text: text, resource_id: resource_id, class: class}
      {nodes, notes} = UiTree.select(entries, filters, max_depth, max_nodes, @tree_bytes_limit)
      GenServer.call(driver, {:tree, Map.new(nodes, &{&1["path"], &1["bounds"]})})
      {:ok, tree_payload(config, entries, nodes, notes)}
    end
  end

  defp run_tool("qa_android_tap", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, {x, y, target}} <- tap_target(driver, args),
         {:ok, {width, height}} <- display_size(config),
         :ok <- on_screen(x, y, width, height, target),
         {:ok, _output} <- adb_ok(config, ["shell", "input", "tap", Integer.to_string(x), Integer.to_string(y)], @adb_timeout_ms) do
      {:ok, %{"x" => x, "y" => y, "note" => "Read qa_android_ui_tree again to see the result; node paths may have changed."}}
    end
  end

  defp run_tool("qa_android_type", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, text} <- type_text(Map.get(args, "text")),
         :ok <- run_all(config, type_commands(text)) do
      {:ok, %{"typed" => String.length(text)}}
    end
  end

  defp run_tool("qa_android_key", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, key, keycode} <- choice(args, "key", @keys),
         {:ok, _output} <- adb_ok(config, ["shell", "input", "keyevent", keycode], @adb_timeout_ms) do
      {:ok, %{"key" => key, "keycode" => keycode}}
    end
  end

  defp run_tool("qa_android_rotate", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, orientation, rotation} <- choice(args, "orientation", @orientations),
         :ok <- GenServer.call(driver, {:changed, :rotation}),
         :ok <- lock_rotation(config, rotation),
         {:ok, {width, height}} <- await_orientation(config, orientation, @rotation_attempts) do
      {:ok,
       %{
         "orientation" => orientation,
         "display" => "#{width}x#{height}",
         "note" => "Auto-rotate is off. Read qa_android_ui_tree again: the layout and node bounds change."
       }}
    end
  end

  defp run_tool("qa_android_dark_mode", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, mode, night} <- choice(args, "mode", @night_modes),
         :ok <- GenServer.call(driver, {:changed, :dark_mode}),
         {:ok, _output} <- adb_ok(config, ["shell", "cmd", "uimode", "night", night], @adb_timeout_ms) do
      {:ok, %{"dark_mode" => mode}}
    end
  end

  defp run_tool("qa_android_font_scale", driver, config, args) do
    with :ok <- GenServer.call(driver, :app_installed),
         {:ok, scale} <- font_scale(Map.get(args, "scale")),
         :ok <- GenServer.call(driver, {:changed, :font_scale}),
         {:ok, _output} <- adb_ok(config, ["shell", "settings", "put", "system", "font_scale", scale], @adb_timeout_ms) do
      {:ok, %{"font_scale" => String.to_float(scale)}}
    end
  end

  # -- install ----------------------------------------------------------------

  # The APK and the build's outputs are gitignored files the agent's sandboxed
  # build creates, so only tracked files count.
  defp ensure_tracked_unchanged(config) do
    case Checks.worktree_status(config.git, config.worktree, ["--untracked-files=no"]) do
      {:ok, _ignored, []} -> :ok
      {:ok, _ignored, changed} -> Checks.worktree_modified(changed, "do not edit tracked files in the worktree.")
      error -> error
    end
  end

  # The checks run on the path, then again on the file that was opened, so a
  # file swapped for a symlink in between is refused rather than copied. The
  # size cap applies to the opened file, and only that size is copied.
  defp copy_apk(config) do
    with {:ok, path, stat} <- checked_apk(config),
         {:ok, fd} <- open_apk(config, path) do
      try do
        with {:ok, size} <- same_file(fd, stat, config) do
          write_copy(config, fd, size)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp checked_apk(config) do
    path = Path.expand(config.apk_path, config.worktree)

    with {:ok, canonical} <- inside_worktree(path, config) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular} = stat} -> {:ok, canonical, stat}
        {:ok, %File.Stat{type: :symlink}} -> tool_error("qa_apk_unsafe", "#{config.apk_path} is a symlink; the APK must be the file the build wrote.")
        {:ok, %File.Stat{type: type}} -> apk_missing(config, "is a #{type}, not a file")
        {:error, reason} -> apk_missing(config, "could not be read (#{inspect(reason)})")
      end
    end
  end

  defp inside_worktree(path, config) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} ->
        if String.starts_with?(canonical, config.worktree <> "/") do
          {:ok, canonical}
        else
          tool_error("qa_apk_outside_worktree", "#{config.apk_path} resolves to #{canonical}, outside the QA worktree. QA installs only the APK built in it.")
        end

      {:error, reason} ->
        tool_error("qa_apk_outside_worktree", "#{config.apk_path} could not be resolved: #{inspect(reason)}")
    end
  end

  defp apk_missing(config, problem) do
    tool_error("qa_apk_missing", "#{config.apk_path} #{problem}. Run the playbook's build command in your sandbox first and check its output.")
  end

  defp open_apk(config, path) do
    case config.open.(path) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> apk_missing(config, "could not be opened (#{inspect(reason)})")
    end
  end

  defp same_file(fd, stat, config) do
    case :file.read_file_info(fd) do
      {:ok, info} ->
        opened = File.Stat.from_record(info)

        cond do
          {opened.type, opened.inode, opened.major_device} != {:regular, stat.inode, stat.major_device} ->
            tool_error("qa_apk_unsafe", "#{config.apk_path} changed while Symphony opened it. Run qa_android_install again once the build is done.")

          opened.size > config.max_apk_bytes ->
            tool_error("qa_apk_too_large", "#{config.apk_path} is #{opened.size} bytes; QA installs APKs of at most #{config.max_apk_bytes} bytes.")

          true ->
            {:ok, opened.size}
        end

      {:error, reason} ->
        apk_missing(config, "could not be read (#{inspect(reason)})")
    end
  end

  # Only the size the cap was checked on is copied, so a file that grows after the checks stays under it.
  defp write_copy(config, fd, size) do
    copy = Path.join(config.scratch_dir, "app-#{System.unique_integer([:positive])}.apk")
    {:ok, out} = :file.open(copy, [:write, :exclusive, :raw, :binary])
    result = copy_bytes(fd, out, size)
    :file.close(out)

    case result do
      :ok ->
        {:ok, copy}

      {:error, reason} ->
        File.rm(copy)
        apk_missing(config, "could not be copied (#{inspect(reason)})")
    end
  end

  defp copy_bytes(_fd, _out, 0), do: :ok

  defp copy_bytes(fd, out, remaining) do
    case :file.read(fd, min(remaining, @copy_chunk_bytes)) do
      {:ok, data} -> with :ok <- :file.write(out, data), do: copy_bytes(fd, out, remaining - byte_size(data))
      :eof -> {:error, :truncated}
      {:error, _reason} = error -> error
    end
  end

  # Uninstalling the configured apps first wipes their data, so every install
  # starts clean. The packages are compared with the baseline the pass's first
  # install took: a package's code path changes whenever it is installed again,
  # so a package `install -r` replaced shows up as changed, as a new one does.
  defp install(driver, config, copy) do
    with {:ok, baseline} <- GenServer.call(driver, :baseline, @adb_timeout_ms * 2) do
      remove_installed(config, baseline)
      GenServer.call(driver, {:installed, []})

      with :ok <- adb_install(config, copy),
           {:ok, now} <- third_party_packages(config) do
        installed(driver, config, changed(now, baseline))
      else
        # The install may have gone through all the same.
        error ->
          remove_installed(config, baseline)
          error
      end
    end
  end

  defp installed(_driver, config, []) do
    tool_error(
      "qa_apk_package_not_configured",
      "The APK installed none of the configured application_ids (#{Enum.join(config.application_ids, ", ")}). Check the playbook's application_ids and apk_path."
    )
  end

  defp installed(driver, config, added) do
    case added -- config.application_ids do
      [] ->
        GenServer.call(driver, {:installed, added})
        Logger.info("Android QA installed application_ids=#{Enum.join(added, ",")}")
        {:ok, %{"installed" => added, "note" => "The app data is fresh. Launch it with qa_android_launch."}}

      unconfigured ->
        uninstall(config, added)

        tool_error(
          "qa_apk_package_not_configured",
          "The APK installed #{Enum.join(unconfigured, ", ")}, which is not one of the configured application_ids (#{Enum.join(config.application_ids, ", ")}); it was uninstalled."
        )
    end
  end

  # Uninstalls the configured apps and, when the device can list them, every
  # package installed or replaced since the baseline.
  defp remove_installed(config, nil), do: uninstall(config, config.application_ids)

  defp remove_installed(config, baseline) do
    strays =
      case third_party_packages(config) do
        {:ok, now} -> changed(now, baseline)
        {:error, _reason} -> []
      end

    uninstall(config, Enum.uniq(config.application_ids ++ strays))
  end

  defp uninstall(config, ids), do: Enum.each(ids, &adb(config, ["uninstall", &1], @adb_timeout_ms))

  defp changed(packages, baseline), do: for({id, path} <- packages, Map.get(baseline, id) != path, do: id) |> Enum.sort()

  # Package ID to code path. Only IDs that are safe to pass to `adb uninstall`
  # count; Android allows no other.
  defp third_party_packages(config) do
    with {:ok, output} <- adb_ok(config, ["shell", "pm", "list", "packages", "-3", "-f"], @adb_timeout_ms, @dumpsys_limit) do
      packages =
        for [_line, path, id] <- Regex.scan(~r/^package:(\S+)=([^=\s]+)\s*$/m, output), Regex.match?(@application_id, id), into: %{} do
          {id, path}
        end

      {:ok, packages}
    end
  end

  defp adb_install(config, copy) do
    case adb(config, ["install", "-r", copy], @install_timeout_ms) do
      {:ok, {output, 0}} -> if output =~ "Success", do: :ok, else: install_failed(output)
      {:ok, {output, _status}} -> install_failed(output)
      {:error, reason} -> install_failed(inspect(reason))
    end
  end

  defp install_failed(output), do: tool_error("qa_android_install_failed", "adb install failed: #{tail(String.trim(output), 2_000)}")

  # -- launch -----------------------------------------------------------------

  defp application_id(config, %{"application_id" => id}) when is_binary(id) do
    if id in config.application_ids do
      {:ok, id}
    else
      tool_error(
        "qa_android_app_not_configured",
        "#{inspect(id)} is not one of the playbook's application_ids (#{Enum.join(config.application_ids, ", ")})."
      )
    end
  end

  defp application_id(_config, _args), do: tool_error("invalid_arguments", "`application_id` is required.")

  defp launcher_activity(config, id) do
    args = ["shell", "cmd", "package", "resolve-activity", "--brief" | @launcher_intent] ++ [id]

    with {:ok, output} <- adb_ok(config, args, @adb_timeout_ms) do
      activity = output |> String.split("\n", trim: true) |> List.last("") |> String.trim()

      if Regex.match?(~r/\A#{Regex.escape(id)}\/[A-Za-z0-9_.$]+\z/, activity) do
        {:ok, activity}
      else
        tool_error("qa_android_no_launcher", "#{id} has no launcher activity: #{tail(String.trim(output), 500)}")
      end
    end
  end

  # `am start` reports most failures on its output with exit status 0.
  defp started(output, activity) do
    if output =~ ~r/^Error/m do
      tool_error("qa_android_launch_failed", "#{activity} could not start: #{tail(String.trim(output), 2_000)}")
    else
      :ok
    end
  end

  defp await_resumed(config, id, activity, seen_pid, attempts) do
    case app_pid(config, id) do
      nil ->
        app_exited(config, id, seen_pid)

      pid ->
        cond do
          resumed?(config, id) ->
            {:ok, %{"application_id" => id, "activity" => activity, "pid" => pid}}

          attempts <= 1 ->
            tool_error(
              "qa_android_not_resumed",
              "#{id} is running (pid #{pid}) but #{activity} did not come to the foreground within #{@resume_attempts * @resume_poll_ms} ms. Take a qa_android_screenshot to see what is on screen."
            )

          true ->
            config.sleep.(@resume_poll_ms)
            await_resumed(config, id, activity, pid, attempts - 1)
        end
    end
  end

  defp app_pid(config, id) do
    with {:ok, {output, 0}} <- adb(config, ["shell", "pidof", id], @adb_timeout_ms),
         [pid | _rest] <- String.split(output),
         {pid, ""} <- Integer.parse(pid) do
      pid
    else
      _not_running -> nil
    end
  end

  defp resumed?(config, id) do
    case adb(config, ["shell", "dumpsys", "activity", "activities"], @adb_timeout_ms, @dumpsys_limit) do
      {:ok, {output, 0}} -> Regex.match?(~r/ResumedActivity[:=].*\s#{Regex.escape(id)}\//, output)
      _failed -> false
    end
  end

  # An app that died before its pid was seen has its crash in the crash buffer.
  defp app_exited(config, id, pid) do
    filter = if pid, do: ["--pid=#{pid}"], else: ["-b", "crash"]

    logcat =
      case adb(config, ["logcat", "-d", "-t", @logcat_lines | filter], @adb_timeout_ms) do
        {:ok, {output, 0}} -> tail(String.trim(output), 4_000)
        _failed -> "(logcat could not be read)"
      end

    tool_error("qa_app_exited", "#{id} is not running after launch. Recent logcat:\n#{logcat}")
  end

  # -- screenshots ------------------------------------------------------------

  defp screencap(config) do
    case adb(config, ["exec-out", "screencap", "-p"], @screenshot_timeout_ms, @screenshot_limit) do
      {:ok, {<<@png_magic, _rest::binary>> = png, 0}} -> {:ok, png}
      {:ok, {output, _status}} -> tool_error("qa_screenshot_failed", "screencap did not return a PNG: #{tail(String.trim(output), 200)}")
      {:error, reason} -> tool_error("qa_screenshot_failed", "screencap failed: #{inspect(reason)}")
    end
  end

  # -- UI tree and input --------------------------------------------------------

  # The dump goes to the adb connection, never to a file on the device.
  defp ui_dump(config) do
    case adb(config, ["exec-out", "uiautomator", "dump", "/dev/tty"], @adb_timeout_ms, @dump_limit + 1) do
      {:ok, {output, _status}} when byte_size(output) > @dump_limit ->
        tool_error("qa_android_ui_tree_failed", "The UI dump is over #{@dump_limit} bytes. Take a qa_android_screenshot instead.")

      {:ok, {output, 0}} ->
        case UiTree.parse(output) do
          {:ok, entries} -> {:ok, entries}
          :error -> tool_error("qa_android_ui_tree_failed", "uiautomator dump returned no UI hierarchy: #{tail(String.trim(output), 500)}")
        end

      {:ok, {output, status}} ->
        tool_error("qa_android_ui_tree_failed", "uiautomator dump failed with exit status #{status}: #{tail(String.trim(output), 500)}")

      {:error, reason} ->
        tool_error("qa_android_ui_tree_failed", "uiautomator dump failed: #{inspect(reason)}")
    end
  end

  defp tree_payload(config, entries, nodes, notes) do
    foreground =
      case entries do
        [{_depth, package, _node} | _rest] -> package
        [] -> nil
      end

    %{"foreground_package" => foreground, "node_count" => length(entries), "nodes" => nodes, "truncated" => notes != []}
    |> put_if(notes != [], "note", "Not every node is shown: #{Enum.join(notes, "; ")}. Narrow it with text, resource_id or class, or raise max_depth or max_nodes.")
    |> put_if(
      foreground not in config.application_ids,
      "foreground_warning",
      "#{foreground || "Nothing"} is in the foreground, not one of the configured application_ids (#{Enum.join(config.application_ids, ", ")}). The app may have crashed or left the screen: check with qa_android_screenshot and relaunch it with qa_android_launch."
    )
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp tap_target(driver, %{"path" => path} = args) when is_binary(path) and not is_map_key(args, "x") and not is_map_key(args, "y") do
    case GenServer.call(driver, {:tree_node, path}) do
      {:ok, %{"left" => left, "top" => top, "right" => right, "bottom" => bottom}} when right > left and bottom > top ->
        {:ok, {div(left + right, 2), div(top + bottom, 2), "The centre of node #{path}"}}

      {:ok, _bounds} ->
        tool_error("qa_android_tap_off_screen", "Node #{path} has no area on screen to tap.")

      :error ->
        tool_error("qa_android_unknown_path", "#{inspect(path)} is not a node path in the last qa_android_ui_tree result. Read the tree again and use one of its paths.")
    end
  end

  defp tap_target(_driver, %{"x" => x, "y" => y} = args) when is_integer(x) and is_integer(y) and not is_map_key(args, "path"),
    do: {:ok, {x, y, "(#{x}, #{y})"}}

  defp tap_target(_driver, _args),
    do: tool_error("invalid_arguments", "Pass either `path`, a node path from the last qa_android_ui_tree, or integer `x` and `y`.")

  # `cur=` is the display size in its current rotation.
  defp display_size(config) do
    with {:ok, output} <- adb_ok(config, ["shell", "dumpsys", "window", "displays"], @adb_timeout_ms, @dumpsys_limit) do
      case Regex.run(~r/\bcur=(\d+)x(\d+)/, output, capture: :all_but_first) do
        [width, height] -> {:ok, {String.to_integer(width), String.to_integer(height)}}
        nil -> tool_error("qa_android_adb_failed", "adb shell dumpsys window displays did not report the display size.")
      end
    end
  end

  # `cmd window user-rotation` (Android 10 and later) has the window manager turn
  # the display; a headless emulator may ignore a write to the `user_rotation`
  # setting, so the setting is only the fallback for older devices.
  defp lock_rotation(config, rotation) do
    args = ["shell", "cmd", "window", "user-rotation", "lock", rotation]

    case adb(config, args, @adb_timeout_ms) do
      {:ok, {output, status}} ->
        cond do
          output =~ ~r/unknown command/i ->
            run_all(config, [
              ["shell", "settings", "put", "system", "accelerometer_rotation", "0"],
              ["shell", "settings", "put", "system", "user_rotation", rotation]
            ])

          status == 0 ->
            :ok

          true ->
            adb_failed(args, "exit status #{status}: #{tail(String.trim(output), 1_000)}")
        end

      {:error, reason} ->
        adb_failed(args, inspect(reason))
    end
  end

  # Success means the display turned, not that the device took the command.
  defp await_orientation(config, orientation, attempts) do
    with {:ok, {width, height} = size} <- display_size(config) do
      cond do
        orientation?(orientation, width, height) ->
          {:ok, size}

        attempts <= 1 ->
          tool_error(
            "qa_android_rotate_failed",
            "The display is still #{width}x#{height}, not #{orientation}, #{@rotation_attempts * @rotation_poll_ms} ms after the rotation. " <>
              "If the app locks its orientation (android:screenOrientation in its manifest), that is what it does; " <>
              "otherwise mark the #{orientation} checks `blocked` with this reason."
          )

        true ->
          config.sleep.(@rotation_poll_ms)
          await_orientation(config, orientation, attempts - 1)
      end
    end
  end

  defp orientation?("landscape", width, height), do: width > height
  defp orientation?("portrait", width, height), do: height >= width

  defp on_screen(x, y, width, height, _target) when x in 0..(width - 1)//1 and y in 0..(height - 1)//1, do: :ok
  defp on_screen(_x, _y, width, height, target), do: tool_error("qa_android_tap_off_screen", "#{target} is outside the #{width}x#{height} display.")

  defp type_text(text) when is_binary(text) and text != "" do
    cond do
      String.length(text) > @type_limit ->
        tool_error("invalid_arguments", "`text` is over #{@type_limit} characters; type it in parts.")

      not Regex.match?(~r/\A[\x20-\x7E\n]*\z/, text) ->
        tool_error(
          "qa_android_text_unsupported",
          "qa_android_type types printable ASCII and newlines only: adb's `input text` cannot type other characters. Type the ASCII parts and report non-ASCII input as untested."
        )

      true ->
        {:ok, text}
    end
  end

  defp type_text(_text), do: tool_error("invalid_arguments", "`text` must be a non-empty string.")

  # `adb shell` hands its arguments to the device's shell as one command line, so
  # each chunk is single-quoted: nothing inside single quotes is special to the
  # shell but the quote itself, which ends the quoting, is escaped and reopens it.
  # A newline is the Enter key. `input text` turns `%s` into a space, so a
  # literal `%s` is split across two calls.
  defp type_commands(text) do
    text
    |> String.split("\n")
    |> Enum.map(&text_chunks/1)
    |> Enum.intersperse([:enter])
    |> List.flatten()
    |> Enum.map(fn
      :enter -> ["shell", "input", "keyevent", "KEYCODE_ENTER"]
      chunk -> ["shell", "input", "text", "'" <> String.replace(chunk, "'", "'\\''") <> "'"]
    end)
  end

  defp text_chunks(line) do
    pieces = String.split(line, "%s")
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.map(fn {piece, index} -> if(index > 0, do: "s", else: "") <> piece <> if(index < last, do: "%", else: "") end)
    |> Enum.reject(&(&1 == ""))
  end

  defp run_all(config, commands) do
    Enum.reduce_while(commands, :ok, fn args, :ok ->
      case adb_ok(config, args, @adb_timeout_ms) do
        {:ok, _output} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp choice(args, key, choices) do
    value = Map.get(args, key)

    case List.keyfind(choices, value, 0) do
      {^value, mapped} -> {:ok, value, mapped}
      nil -> tool_error("invalid_arguments", "`#{key}` must be one of #{Enum.map_join(choices, ", ", &elem(&1, 0))}.")
    end
  end

  defp font_scale(scale) when is_number(scale) do
    case Enum.find(@font_scales, fn {allowed, _setting} -> allowed == scale end) do
      {_allowed, setting} -> {:ok, setting}
      nil -> font_scale(nil)
    end
  end

  defp font_scale(_scale), do: tool_error("invalid_arguments", "`scale` must be one of #{Enum.map_join(@font_scales, ", ", &elem(&1, 1))}.")

  defp optional_string(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" and byte_size(value) <= @filter_limit -> {:ok, value}
      _value -> tool_error("invalid_arguments", "`#{key}` must be a non-empty string of at most #{@filter_limit} bytes.")
    end
  end

  defp optional_integer(args, key, max, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= 1 and value <= max -> {:ok, value}
      _value -> tool_error("invalid_arguments", "`#{key}` must be an integer from 1 to #{max}.")
    end
  end

  # -- adb --------------------------------------------------------------------

  # The only commands the driver runs: adb, against the leased emulator.
  defp adb(config, args, timeout_ms, output_limit \\ @output_limit) do
    {executable, args, env} = Emulator.adb_command(config.lease, args)
    config.cmd.(executable, args, timeout_ms: timeout_ms, env: env, output_limit: output_limit)
  end

  defp adb_ok(config, args, timeout_ms, output_limit \\ @output_limit) do
    case adb(config, args, timeout_ms, output_limit) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> adb_failed(args, "exit status #{status}: #{tail(String.trim(output), 1_000)}")
      {:error, reason} -> adb_failed(args, inspect(reason))
    end
  end

  defp adb_failed(args, detail), do: tool_error("qa_android_adb_failed", "adb #{Enum.join(args, " ")} failed: #{detail}")

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    playbook = Keyword.fetch!(opts, :playbook)
    {:ok, worktree} = PathSafety.canonicalize(Keyword.fetch!(opts, :worktree))

    config = %{
      worktree: worktree,
      apk_path: Map.fetch!(playbook, :apk_path),
      # They are passed to `adb shell`, which runs them through the device's shell.
      application_ids: playbook |> Map.fetch!(:application_ids) |> Enum.filter(&(is_binary(&1) and Regex.match?(@application_id, &1))),
      git: Keyword.get(opts, :git, &default_git/2),
      cmd: Keyword.get(opts, :cmd, &Host.cmd/3),
      checkout: Keyword.get(opts, :checkout, fn -> Emulator.checkout() end),
      checkin: Keyword.get(opts, :checkin, &Emulator.checkin/1),
      open: Keyword.get(opts, :open, &:file.open(&1, [:read, :raw, :binary])),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      max_apk_bytes: Keyword.get(opts, :max_apk_bytes, @max_apk_bytes),
      lease: nil,
      scratch_dir: nil
    }

    state = %{config: config, baseline: nil, installed: [], screenshots: 0, tree: %{}, changed: []}
    {:ok, state, {:continue, :checkout}}
  end

  # Booting can take minutes; tool calls wait for it, the session does not.
  @impl true
  def handle_continue(:checkout, %{config: config} = state) do
    case config.checkout.() do
      {:ok, lease} ->
        {:noreply, %{state | config: %{config | lease: lease, scratch_dir: Checks.private_dir("qa-android")}}}

      {:error, reason} ->
        Logger.warning("Android QA has no emulator reason=#{inspect(reason)}")
        error = tool_error("qa_android_unavailable", "#{Emulator.error_message(reason)} #{Checks.blocked_hint()}")
        {:noreply, %{state | config: Map.put(config, :unavailable, error)}}
    end
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}
  def handle_call({:installed, ids}, _from, state), do: {:reply, :ok, %{state | installed: ids}}

  # The packages on the device before the pass's first install, without the
  # configured apps, which every install replaces.
  def handle_call(:baseline, _from, %{baseline: nil} = state) do
    case third_party_packages(state.config) do
      {:ok, packages} ->
        baseline = Map.drop(packages, state.config.application_ids)
        {:reply, {:ok, baseline}, %{state | baseline: baseline}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:baseline, _from, state), do: {:reply, {:ok, state.baseline}, state}

  def handle_call({:installed?, id}, _from, state) do
    if id in state.installed do
      {:reply, :ok, state}
    else
      {:reply, tool_error("qa_android_not_installed", "#{id} is not installed in this QA pass. Run qa_android_install first."), state}
    end
  end

  def handle_call(:screenshot_slot, _from, state) do
    if state.screenshots < @max_screenshots do
      {:reply, :ok, state}
    else
      {:reply, tool_error("qa_too_many_screenshots", "This QA pass already took #{@max_screenshots} screenshots."), state}
    end
  end

  def handle_call(:screenshot_taken, _from, state), do: {:reply, :ok, %{state | screenshots: state.screenshots + 1}}

  def handle_call(:app_installed, _from, %{installed: []} = state),
    do: {:reply, tool_error("qa_android_not_installed", "No configured app is installed in this QA pass. Run qa_android_install first."), state}

  def handle_call(:app_installed, _from, state), do: {:reply, :ok, state}
  def handle_call({:tree, tree}, _from, state), do: {:reply, :ok, %{state | tree: tree}}
  def handle_call({:tree_node, path}, _from, state), do: {:reply, Map.fetch(state.tree, path), state}

  # Recorded before the setting is changed, so a change that half went through is reset too.
  def handle_call({:changed, setting}, _from, state), do: {:reply, :ok, %{state | changed: Enum.uniq([setting | state.changed])}}

  # The driver traps exits, so every adb port it opens sends an `:EXIT` when it closes.
  # The QA pass that owns the driver is its parent: GenServer stops on its exit itself.
  @impl true
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.error("Android QA driver received unexpected message=#{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{config: config} = state) do
    if config.lease do
      for {setting, reset} <- @setting_resets, setting in state.changed, do: reset_setting(config, reset)
      remove_installed(config, state.baseline)
      config.checkin.(config.lease)
    end

    if config.scratch_dir, do: File.rm_rf(config.scratch_dir)
    :ok
  end

  defp reset_setting(config, {:rotation, rotation}), do: lock_rotation(config, rotation)
  defp reset_setting(config, args), do: adb(config, args, @adb_timeout_ms)

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
