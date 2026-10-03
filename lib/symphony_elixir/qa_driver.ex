defmodule SymphonyElixir.QaDriver do
  @moduledoc """
  Host-side driver behind the Auto Review `qa_*` tools for the `macos_app` playbook.

  The QA agent runs sandboxed and cannot build Swift, launch GUI apps or read the
  screen, so Symphony does those few things for it on the host, one driver per QA
  pass. Every tool argument is checked here before anything runs:

  - `qa_build` runs only the configured `build` command, in the QA worktree, with
    the agent's scrubbed environment, and refuses a worktree with edits outside
    `qa-evidence/`. Gitignored files count too (the build reads caches such as
    SwiftPM's `.build/`): none may exist before the first build, and after a
    build none may appear or change until the next one;
  - a successful `qa_build` copies the configured `app` bundle, which must
    resolve (symlinks included) inside the worktree, into the driver's private
    directory. Symlinks inside the bundle must be relative and must not climb
    with `..`, so the copy cannot reach back into the worktree;
  - `qa_launch_app` starts only that private copy, only while its executable
    still matches what the build produced and the worktree is as that build
    left it, so later worktree edits cannot change what runs. The app always
    gets `SYMPHONY_BAR_QA_ROOT` pointing at the private directory, so it never
    touches real settings or secrets;
  - `qa_quit_app`, `qa_screenshot`, `qa_ax_tree`, `qa_ax_press` and
    `qa_ax_set_value` accept only a PID this driver launched and that is still
    running;
  - screenshots land in `qa-evidence/` under the worktree, always as new files:
    a name that already exists, symlinks included, is refused rather than
    followed or replaced.

  Screenshots and accessibility calls need the Screen Recording and Accessibility
  grants of the process that runs Symphony. Without them the tools fail with
  `qa_permission_missing` and tell the agent to answer `blocked`.

  The private directory (bundle copies, screenshot staging and the app's QA
  root) is a `0700` directory under Symphony's state root, outside every path
  the agent sandbox may write.

  When the driver stops (the QA pass ends or crashes) it quits every app it
  launched and removes its private directory.

  With `:worker_host` (`auto_review.worker_host`) the build, the app and the
  helper run on that QA host instead, through `SymphonyElixir.QaDriver.Remote`.
  The worktree checks stay on the Symphony host; `qa_build` then ships the
  worktree's `HEAD` (a `git archive`, so ignored files stay behind) into a fresh
  build directory on the QA host, copies the bundle into Symphony's run
  directory there and launches it from that copy. The agent cannot write on the
  QA host, so the copy is not checked again before launch. Screenshots are
  captured there and copied back into `qa-evidence/`. A QA host that can reach
  the operator's credentials or holds push credentials is refused at start,
  and every tool then fails with `qa_worker_unsafe`.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{AgentEnv, Paths, PathSafety, Workspace}
  alias SymphonyElixir.QaDriver.{Host, Remote}

  @evidence_dir "qa-evidence"
  @qa_root_env "SYMPHONY_BAR_QA_ROOT"
  @default_build_timeout_ms 900_000
  @helper_timeout_ms 30_000
  @screenshot_timeout_ms 15_000
  @output_limit 8_000
  @app_output_limit 16_000
  @tree_bytes_limit 100_000
  @max_running_apps 3
  @max_screenshots 8
  @value_limit 10_000
  @press_actions ~w(AXPress AXRaise AXShowMenu AXConfirm AXCancel AXIncrement AXDecrement AXPick)
  @screenshot_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @element_path ~r/\A\d{1,4}(\.\d{1,4}){0,63}\z/

  # Checks and copies the bundle on a QA host: `$1` build dir, `$2` app path,
  # `$3` destination. The bundle must be a real `.app` directory inside the build
  # dir; prints the copied executable.
  @remote_bundle_script """
  case "$2" in *.app) ;; *) echo "not an .app bundle"; exit 1 ;; esac
  bundle="$1/$2"
  if [ ! -d "$bundle" ] || [ -L "$bundle" ]; then echo "$2 is not a directory; run qa_build and check its output"; exit 1; fi
  case "$(cd "$bundle" && pwd -P)/" in "$(cd "$1" && pwd -P)/"*) ;; *) echo "$2 resolves outside the build directory"; exit 1 ;; esac
  name=$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist") || exit 1
  case "$name" in ""|.|..|*/*) echo "invalid CFBundleExecutable"; exit 1 ;; esac
  mkdir -p "$3" && cp -R "$bundle" "$3/" || exit 1
  executable="$3/${bundle##*/}/Contents/MacOS/$name"
  if [ ! -f "$executable" ]; then echo "$executable is missing"; exit 1; fi
  printf 'symphony-qa-app:%s\\n' "$executable"
  """

  @tools ~w(qa_build qa_launch_app qa_quit_app qa_screenshot qa_ax_tree qa_ax_press qa_ax_set_value)

  @type host :: %{
          required(:cmd) => (String.t(), [String.t()], keyword() -> {:ok, {String.t(), integer()}} | {:error, term()}),
          required(:launch) => (String.t(), keyword() -> {:ok, port(), pos_integer()} | {:error, term()}),
          required(:kill) => (pos_integer() -> :ok),
          # A QA host's helper takes the pass's run directory.
          required(:helper) => (-> helper_result()) | (String.t() -> helper_result()),
          optional(:read) => (Path.t() -> {:ok, binary()} | {:error, term()}),
          optional(:prepare) => (Path.t(), Path.t() -> {:ok, String.t()} | {:error, {atom(), String.t()}}),
          optional(:ship) => (Path.t(), String.t() -> :ok | {:error, String.t()}),
          optional(:cleanup) => (String.t() -> :ok)
        }
  @type helper_result :: {:ok, Path.t()} | {:error, term()}
  @type tool_error :: {:qa_tool, String.t(), String.t()}

  @doc "The `qa_*` tool names this driver serves."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc """
  Starts a driver for one QA pass.

  Options: `:worktree` (required), `:playbook` (the selected `macos_app` playbook
  with `build`, `app` and optional `build_timeout_ms`), `:worker_host` (the SSH
  host QA runs on, default this host), `:host` (overrides for the OS boundary,
  see `t:host/0`) and `:git` (a `fn args, cwd -> {output, status}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Stops the driver, quitting every app it launched."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(driver) when is_pid(driver) do
    GenServer.stop(driver, :normal, 30_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Runs one `qa_*` tool with the agent's arguments. Returns the tool payload or a
  `{:qa_tool, code, message}` error for the agent.
  """
  @spec call_tool(pid() | nil, String.t(), map()) :: {:ok, map()} | {:error, tool_error()}
  def call_tool(nil, _tool, _args) do
    tool_error(
      "qa_driver_unavailable",
      "The qa_* tools drive a macOS app and are only available when the macos_app playbook runs in this QA pass."
    )
  end

  def call_tool(driver, tool, args) when is_pid(driver) and tool in @tools and is_map(args) do
    case GenServer.call(driver, :config) do
      %{unavailable: {:error, _reason} = error} -> error
      config -> run_tool(tool, driver, config, args)
    end
  catch
    :exit, _reason -> tool_error("qa_driver_unavailable", "The QA driver for this pass has stopped.")
  end

  # -- tools ------------------------------------------------------------------

  defp run_tool("qa_build", driver, config, _args) do
    with :ok <- ensure_clean_worktree(config, GenServer.call(driver, :ignored)),
         :ok <- ship(config),
         {:ok, {output, status}} <- run_build(config) |> rebaseline_on_timeout(driver, config),
         {:ok, ignored, _dirty} <- worktree_status(config) do
      record_build(driver, config, status, tail(output, @output_limit), ignored_signatures(config, ignored))
    end
  end

  defp run_tool("qa_launch_app", driver, config, _args) do
    with {:ok, built} <- fetch_build(driver),
         :ok <- ensure_clean_worktree(config, GenServer.call(driver, :ignored)),
         :ok <- unchanged_build(config, built) do
      GenServer.call(driver, {:launch, built.executable})
    end
  end

  defp run_tool("qa_quit_app", driver, _config, args) do
    with {:ok, pid} <- pid_argument(args) do
      GenServer.call(driver, {:quit, pid}, 30_000)
    end
  end

  defp run_tool("qa_screenshot", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, name} <- screenshot_name(Map.get(args, "name")),
         {:ok, window_id} <- optional_integer(args, "window_id", 1, 0xFFFF_FFFF),
         {:ok, helper} <- helper(driver, config),
         :ok <- require_screen_recording(config, helper),
         {:ok, %{"windows" => windows}} <- run_helper(config, helper, ["windows", Integer.to_string(pid)]),
         {:ok, targets} <- screenshot_targets(windows, window_id),
         {:ok, evidence} <- evidence_dir(config) do
      capture(config, targets, name, evidence)
    end
  end

  defp run_tool("qa_ax_tree", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, role} <- optional_string(args, "role", 64),
         {:ok, text} <- optional_string(args, "text", 200),
         {:ok, max_depth} <- optional_integer(args, "max_depth", 1, 40),
         {:ok, max_nodes} <- optional_integer(args, "max_nodes", 1, 1000),
         {:ok, helper} <- helper(driver, config),
         helper_args = [
           "ax-tree",
           Integer.to_string(pid),
           Integer.to_string(max_depth || 12),
           Integer.to_string(max_nodes || 300),
           role || "",
           text || ""
         ],
         {:ok, output} <- run_helper_raw(config, helper, helper_args) do
      if byte_size(output) > @tree_bytes_limit do
        tool_error(
          "qa_ax_tree_too_large",
          "The accessibility tree is over #{@tree_bytes_limit} bytes. Narrow it with `role` or `text`, or lower `max_depth` or `max_nodes`."
        )
      else
        decode_helper_output(output)
      end
    end
  end

  defp run_tool("qa_ax_press", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, path} <- element_path(Map.get(args, "path")),
         {:ok, action} <- press_action(Map.get(args, "action")),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, ["ax-press", Integer.to_string(pid), path, action])
    end
  end

  defp run_tool("qa_ax_set_value", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, path} <- element_path(Map.get(args, "path")),
         {:ok, value} <- set_value(Map.get(args, "value")),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, ["ax-set-value", Integer.to_string(pid), path, value])
    end
  end

  # -- build and bundle checks ------------------------------------------------

  # Ignored files are inputs too: the host build reads caches such as SwiftPM's
  # `.build/`, which the sandboxed agent can write. `baseline` holds the ignored
  # files the last build left (empty before the first build); any other ignored
  # file, or one whose signature changed, means the agent touched it.
  defp ensure_clean_worktree(config, baseline) do
    with {:ok, ignored, dirty} <- worktree_status(config) do
      planted =
        config
        |> ignored_signatures(ignored)
        |> Enum.reject(fn {path, signature} -> Map.get(baseline, path) == signature end)
        |> Enum.map(fn {path, _signature} -> path end)
        |> Enum.sort()

      case dirty ++ planted do
        [] ->
          :ok

        changed ->
          tool_error(
            "qa_worktree_modified",
            "The QA worktree has changes outside #{@evidence_dir}/ (#{Enum.join(Enum.take(changed, 5), ", ")}). QA tests the PR head as pushed; do not edit files in the worktree, including gitignored ones."
          )
      end
    end
  end

  defp worktree_status(config) do
    args = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"]

    case config.git.(args, config.worktree) do
      {output, 0} ->
        {ignored, dirty} =
          output
          |> to_string()
          |> String.split(<<0>>, trim: true)
          |> Enum.reject(&String.starts_with?(String.slice(&1, 3..-1//1), @evidence_dir <> "/"))
          |> Enum.split_with(&String.starts_with?(&1, "!! "))

        {:ok, Enum.map(ignored, &String.slice(&1, 3..-1//1)), Enum.map(dirty, &String.slice(&1, 3..-1//1))}

      {output, status} ->
        tool_error("qa_git_failed", "git status failed (exit #{status}): #{tail(to_string(output), 500)}")
    end
  end

  # ctime and inode cannot be set back by an unprivileged process, so a rewrite
  # shows even when size and mtime are restored.
  defp ignored_signatures(config, paths) do
    for path <- paths,
        {:ok, stat} <- [File.lstat(Path.join(config.worktree, path), time: :posix)],
        into: %{} do
      {path, {stat.type, stat.size, stat.mtime, stat.ctime, stat.inode}}
    end
  end

  # The build's own outputs become the baseline whether or not it succeeded, so
  # a failed build's partial outputs do not block the next attempt.
  defp record_build(driver, config, 0, output, ignored) do
    case built_app(config) do
      {:ok, fingerprint} ->
        GenServer.call(driver, {:record_build, fingerprint, ignored})
        {:ok, %{"exit_status" => 0, "output" => output, "app" => config.app}}

      {:error, _reason} = error ->
        GenServer.call(driver, {:record_build, nil, ignored})
        error
    end
  end

  defp record_build(driver, _config, status, output, ignored) do
    GenServer.call(driver, {:record_build, nil, ignored})
    {:ok, %{"exit_status" => status, "output" => output}}
  end

  # A killed build has usually written part of its outputs already. The worktree
  # was clean when it started, so those outputs become the baseline too.
  defp rebaseline_on_timeout({:error, {:qa_tool, "qa_build_timeout", _message}} = error, driver, config) do
    with {:ok, ignored, _dirty} <- worktree_status(config) do
      GenServer.call(driver, {:record_build, nil, ignored_signatures(config, ignored)})
      error
    end
  end

  defp rebaseline_on_timeout(result, _driver, _config), do: result

  # On a QA host the build gets a fresh copy of the worktree's HEAD. The worktree
  # is clean at this point, so HEAD is exactly what it holds.
  defp ship(%{remote?: false}), do: :ok

  defp ship(config) do
    tar = Path.join(config.scratch_dir, "src.tar")

    result =
      case config.git.(["archive", "--format=tar", "-o", tar, "HEAD"], config.worktree) do
        {_output, 0} ->
          with {:error, reason} <- config.host.ship.(tar, config.build_dir) do
            tool_error("qa_build_failed", "The worktree could not be copied to the QA host: #{reason}")
          end

        {output, status} ->
          tool_error("qa_git_failed", "git archive failed (exit #{status}): #{tail(to_string(output), 500)}")
      end

    File.rm(tar)
    result
  end

  defp run_build(config) do
    opts = [cd: config.build_dir, env: AgentEnv.build(), timeout_ms: config.build_timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", ["-c", config.build], opts) do
      {:ok, {output, status}} ->
        {:ok, {output, status}}

      {:error, :timeout} ->
        tool_error("qa_build_timeout", "The build did not finish within #{config.build_timeout_ms} ms.")

      {:error, reason} ->
        tool_error("qa_build_failed", "The build command could not start: #{inspect(reason)}")
    end
  end

  defp built_app(%{remote?: false} = config) do
    with {:ok, built} <- fingerprint_app(config),
         {:ok, copy} <- copy_bundle(config, built.bundle),
         {:ok, fingerprint} <- fingerprint_bundle(config, copy),
         :ok <- same_build(built.digest, fingerprint.digest) do
      {:ok, fingerprint}
    end
  end

  # On a QA host only Symphony writes the build directory, so the bundle is
  # checked and copied by one script there.
  defp built_app(config) do
    destination = Path.join(config.host_dir, "builds/#{System.unique_integer([:positive])}")
    args = ["-c", @remote_bundle_script, "sh", config.build_dir, config.app, destination]

    case config.host.cmd.("/bin/sh", args, timeout_ms: @helper_timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        case Regex.run(~r/^symphony-qa-app:(.+)$/m, output) do
          [_line, executable] -> {:ok, %{executable: executable, digest: nil}}
          nil -> remote_app_missing(config, output)
        end

      {:ok, {output, _status}} ->
        remote_app_missing(config, output)

      {:error, reason} ->
        remote_app_missing(config, inspect(reason))
    end
  end

  defp remote_app_missing(config, output) do
    tool_error("qa_app_missing", "The configured app bundle #{config.app} is not a usable .app on the QA host: #{tail(String.trim(output), 500)}")
  end

  defp unchanged_build(%{remote?: true}, _built), do: :ok

  defp unchanged_build(_config, built) do
    with {:ok, digest} <- file_digest(built.executable) do
      same_build(built.digest, digest)
    end
  end

  defp fingerprint_app(config) do
    with {:ok, bundle} <- resolve_inside(Path.expand(config.app, config.worktree), config.worktree, "qa_bundle_outside_worktree"),
         :ok <- bundle_directory(bundle, config.app) do
      fingerprint_bundle(config, bundle)
    end
  end

  defp fingerprint_bundle(config, bundle) do
    with {:ok, name} <- bundle_executable_name(config, bundle),
         {:ok, executable} <- resolve_inside(Path.join([bundle, "Contents", "MacOS", name]), bundle, "qa_executable_outside_bundle"),
         {:ok, digest} <- file_digest(executable) do
      {:ok, %{bundle: bundle, executable: executable, digest: digest}}
    end
  end

  # The worktree stays agent-writable after the build, so QA launches a copy in
  # the driver's private directory. Each build gets its own copy because apps
  # launched from an earlier one may still be running.
  defp copy_bundle(config, bundle) do
    destination = Path.join([config.scratch_dir, "builds", Integer.to_string(System.unique_integer([:positive])), Path.basename(bundle)])
    File.mkdir_p!(Path.dirname(destination))

    case copy_tree(bundle, destination) do
      :ok ->
        {:ok, destination}

      {:error, reason} ->
        File.rm_rf(Path.dirname(destination))
        tool_error("qa_bundle_unsafe", "The app bundle could not be copied for launch: #{reason}.")
    end
  end

  defp copy_tree(source, destination) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :directory}} ->
        source |> copy_dir(destination) |> copy_result(source)

      {:ok, %File.Stat{type: :regular}} ->
        source |> File.cp(destination) |> copy_result(source)

      {:ok, %File.Stat{type: :symlink}} ->
        copy_symlink(source, destination)

      {:ok, %File.Stat{}} ->
        {:error, "#{source} is not a file, directory or symlink"}

      error ->
        copy_result(error, source)
    end
  end

  defp copy_dir(source, destination) do
    with :ok <- File.mkdir(destination),
         {:ok, entries} <- File.ls(source) do
      copy_entries(Enum.sort(entries), source, destination)
    end
  end

  defp copy_entries([], _source, _destination), do: :ok

  defp copy_entries([entry | rest], source, destination) do
    case copy_tree(Path.join(source, entry), Path.join(destination, entry)) do
      :ok -> copy_entries(rest, source, destination)
      error -> error
    end
  end

  defp copy_result({:error, reason}, source) when not is_binary(reason), do: {:error, "#{source}: #{inspect(reason)}"}
  defp copy_result(result, _source), do: result

  # A relative target without `..` only descends from the link's own directory,
  # and every other link in the copy obeys the same rule, so it stays inside it.
  defp copy_symlink(source, destination) do
    with {:ok, target} <- copy_result(File.read_link(source), source) do
      if Path.type(target) == :relative and ".." not in Path.split(target) do
        target |> File.ln_s(destination) |> copy_result(source)
      else
        {:error, "#{source} links to #{target}; links in the bundle must be relative and stay inside it"}
      end
    end
  end

  defp resolve_inside(path, root, code) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} ->
        if String.starts_with?(canonical, root <> "/") do
          {:ok, canonical}
        else
          tool_error(code, "#{path} resolves to #{canonical}, outside #{root}. QA launches only the configured app bundle built in the QA worktree.")
        end

      {:error, reason} ->
        tool_error(code, "#{path} could not be resolved: #{inspect(reason)}")
    end
  end

  defp bundle_directory(bundle, app) do
    if String.ends_with?(bundle, ".app") and File.dir?(bundle) do
      :ok
    else
      tool_error("qa_app_missing", "The configured app bundle #{app} is not an .app directory in the QA worktree. Run qa_build and check its output.")
    end
  end

  defp bundle_executable_name(config, bundle) do
    info_plist = Path.join([bundle, "Contents", "Info.plist"])
    args = ["-extract", "CFBundleExecutable", "raw", "-o", "-", info_plist]

    case config.host.cmd.("/usr/bin/plutil", args, timeout_ms: @helper_timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        name = String.trim(output)

        if name != "" and not String.contains?(name, ["/", <<0>>]) and name not in [".", ".."] do
          {:ok, name}
        else
          tool_error("qa_app_missing", "#{info_plist} has an invalid CFBundleExecutable.")
        end

      _other ->
        tool_error("qa_app_missing", "Could not read CFBundleExecutable from #{info_plist}.")
    end
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, :crypto.hash(:sha256, bytes)}
      {:error, reason} -> tool_error("qa_app_missing", "Could not read the app executable #{path}: #{inspect(reason)}")
    end
  end

  defp fetch_build(driver) do
    case GenServer.call(driver, :build) do
      nil -> tool_error("qa_not_built", "Run qa_build first; qa_launch_app launches only the app the last successful qa_build produced.")
      built -> {:ok, built}
    end
  end

  defp same_build(built_digest, digest) do
    if built_digest == digest do
      :ok
    else
      tool_error("qa_app_changed", "The app executable changed after the last qa_build. Run qa_build again; QA launches only what the build produced.")
    end
  end

  # -- argument checks --------------------------------------------------------

  defp pid_argument(%{"pid" => pid}) when is_integer(pid) and pid > 0, do: {:ok, pid}
  defp pid_argument(_args), do: tool_error("invalid_arguments", "`pid` must be the positive integer qa_launch_app returned.")

  defp running_pid(driver, args) do
    with {:ok, pid} <- pid_argument(args) do
      GenServer.call(driver, {:running, pid})
    end
  end

  defp screenshot_name(name) when is_binary(name) do
    name = String.replace_suffix(name, ".png", "")

    if Regex.match?(@screenshot_name, name) do
      {:ok, name}
    else
      tool_error("invalid_arguments", "`name` must be 1-64 characters of letters, digits, `.`, `_` or `-`, starting with a letter or digit.")
    end
  end

  defp screenshot_name(_name), do: tool_error("invalid_arguments", "`name` is required.")

  defp element_path(path) when is_binary(path) do
    if Regex.match?(@element_path, path) do
      {:ok, path}
    else
      tool_error("invalid_arguments", "`path` must be an element path from qa_ax_tree, like `0.2.1`.")
    end
  end

  defp element_path(_path), do: tool_error("invalid_arguments", "`path` is required.")

  defp press_action(nil), do: {:ok, "AXPress"}
  defp press_action(action) when action in @press_actions, do: {:ok, action}
  defp press_action(_action), do: tool_error("invalid_arguments", "`action` must be one of #{Enum.join(@press_actions, ", ")}.")

  defp set_value(value) when is_binary(value) and byte_size(value) <= @value_limit do
    if String.contains?(value, <<0>>), do: tool_error("invalid_arguments", "`value` must not contain NUL bytes."), else: {:ok, value}
  end

  defp set_value(_value), do: tool_error("invalid_arguments", "`value` must be a string of at most #{@value_limit} bytes.")

  defp optional_string(args, key, limit) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= limit -> {:ok, value}
      _value -> tool_error("invalid_arguments", "`#{key}` must be a string of at most #{limit} bytes.")
    end
  end

  defp optional_integer(args, key, min, max) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _value -> tool_error("invalid_arguments", "`#{key}` must be an integer from #{min} to #{max}.")
    end
  end

  # -- helper -----------------------------------------------------------------

  # A QA host gets its own helper in each pass's run directory; the driver
  # remembers the path so later calls skip the round trip.
  defp helper(driver, config) do
    case GenServer.call(driver, :helper) do
      nil -> build_helper(driver, config)
      path -> {:ok, path}
    end
  end

  defp build_helper(driver, config) do
    case if(config.remote?, do: config.host.helper.(config.host_dir), else: config.host.helper.()) do
      {:ok, path} ->
        GenServer.call(driver, {:helper, path})
        {:ok, path}

      {:error, reason} ->
        tool_error("qa_helper_unavailable", "Symphony could not build its macOS QA helper with swiftc: #{inspect(reason)}")
    end
  end

  defp require_screen_recording(config, helper) do
    case run_helper(config, helper, ["permissions"]) do
      {:ok, %{"screen_recording" => true}} -> :ok
      {:ok, _permissions} -> permission_missing("Screen Recording")
      {:error, _reason} = error -> error
    end
  end

  defp run_helper(config, helper, args) do
    with {:ok, output} <- run_helper_raw(config, helper, args) do
      decode_helper_output(output)
    end
  end

  defp run_helper_raw(config, helper, args) do
    case config.host.cmd.(helper, args, timeout_ms: @helper_timeout_ms, output_limit: @tree_bytes_limit + 1) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> helper_error(output)
      {:error, :timeout} -> tool_error("qa_helper_timeout", "The app did not answer the accessibility request within #{@helper_timeout_ms} ms.")
      {:error, reason} -> tool_error("qa_helper_failed", "The QA helper could not run: #{inspect(reason)}")
    end
  end

  defp decode_helper_output(output) do
    case Jason.decode(output) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> tool_error("qa_helper_failed", "The QA helper returned unreadable output: #{tail(output, 500)}")
    end
  end

  defp helper_error(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"code" => "accessibility_permission_missing"}}} ->
        permission_missing("Accessibility")

      {:ok, %{"error" => %{"code" => code, "message" => message}}} when is_binary(code) and is_binary(message) ->
        tool_error("qa_" <> code, message)

      _other ->
        tool_error("qa_helper_failed", "The QA helper failed: #{tail(output, 500)}")
    end
  end

  defp permission_missing(grant) do
    tool_error(
      "qa_permission_missing",
      "The process that runs Symphony has no #{grant} permission, so QA cannot see the app. " <>
        "Answer with verdict `blocked` and this reason; an operator grants Screen Recording and Accessibility once in " <>
        "System Settings > Privacy & Security (see docs/configuration.md, Auto Review macOS app QA)."
    )
  end

  # -- screenshots ------------------------------------------------------------

  defp screenshot_targets(windows, nil) do
    case Enum.filter(windows, &(&1["onscreen"] == true and &1["layer"] == 0 and visible?(&1))) do
      [] -> tool_error("qa_no_window", "The app has no window on screen. Open one first, or pass `window_id` for a menu or panel.")
      targets -> {:ok, Enum.take(targets, @max_screenshots)}
    end
  end

  defp screenshot_targets(windows, window_id) do
    case Enum.find(windows, &(&1["id"] == window_id)) do
      nil -> tool_error("qa_window_not_found", "Window #{window_id} does not belong to the launched app.")
      window -> {:ok, [window]}
    end
  end

  defp visible?(%{"frame" => %{"w" => width, "h" => height}}), do: width > 1 and height > 1
  defp visible?(_window), do: false

  defp evidence_dir(config) do
    dir = Path.join(config.worktree, @evidence_dir)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, dir}

      {:error, :enoent} ->
        case File.mkdir(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> tool_error("qa_evidence_unsafe", "#{@evidence_dir}/ could not be created in the QA worktree: #{inspect(reason)}.")
        end

      _other ->
        tool_error("qa_evidence_unsafe", "#{@evidence_dir}/ in the QA worktree must be a plain directory, not a symlink or file.")
    end
  end

  defp capture(config, targets, name, evidence) do
    numbered = length(targets) > 1

    targets
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {window, index}, {:ok, files} ->
      file = if numbered, do: "#{name}-#{index}.png", else: "#{name}.png"

      case capture_window(config, window, evidence, file) do
        :ok ->
          entry = %{"path" => Path.join(@evidence_dir, file), "window_id" => window["id"], "title" => window["title"], "frame" => window["frame"]}
          {:cont, {:ok, [entry | files]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, %{"files" => Enum.reverse(files)}}
      error -> error
    end
  end

  # The host's `read` removes the capture, so a later capture of the same window
  # never finds a stale file.
  defp capture_window(config, window, evidence, file) do
    scratch = Path.join(config.host_dir, "window-#{window["id"]}.png")
    args = ["-x", "-o", "-l", Integer.to_string(window["id"]), scratch]

    with {:ok, {_output, 0}} <- config.host.cmd.("/usr/sbin/screencapture", args, timeout_ms: @screenshot_timeout_ms, output_limit: @output_limit),
         {:ok, png} <- config.host.read.(scratch) do
      write_evidence(Path.join(evidence, file), png, file)
    else
      _failure -> tool_error("qa_screenshot_failed", "screencapture could not capture window #{window["id"]}.")
    end
  end

  # `:exclusive` is O_CREAT|O_EXCL: it never follows, replaces or removes a
  # symlink or file the agent left at the name, so a screenshot cannot be
  # redirected outside `qa-evidence/`.
  defp write_evidence(destination, png, file) do
    case File.write(destination, png, [:exclusive]) do
      :ok ->
        :ok

      {:error, :eexist} ->
        tool_error("qa_screenshot_exists", "#{@evidence_dir}/#{file} already exists. Give each screenshot a new name.")

      {:error, reason} ->
        tool_error("qa_screenshot_failed", "Could not save #{@evidence_dir}/#{file}: #{inspect(reason)}.")
    end
  end

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit do
    "…" <> binary_part(output, byte_size(output) - limit, limit)
  end

  defp tail(output, _limit), do: output

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    playbook = Keyword.fetch!(opts, :playbook)
    {:ok, worktree} = PathSafety.canonicalize(Keyword.fetch!(opts, :worktree))
    worker_host = Keyword.get(opts, :worker_host)
    base_host = if worker_host, do: Remote.host(worker_host), else: Host.default()

    config = %{
      worktree: worktree,
      build: Map.fetch!(playbook, :build),
      app: Map.fetch!(playbook, :app),
      build_timeout_ms: Map.get(playbook, :build_timeout_ms) || @default_build_timeout_ms,
      scratch_dir: private_dir(),
      remote?: worker_host != nil,
      host: Map.merge(base_host, Map.new(Keyword.get(opts, :host, %{}))),
      git: Keyword.get(opts, :git, &default_git/2)
    }

    {:ok, %{config: host_dirs(config, worker_host), build: nil, ignored: %{}, apps: %{}, helper: nil}}
  end

  # `host_dir` holds the bundle copies, screenshot staging and the app's QA root
  # wherever the app runs; `build_dir` is where the build runs.
  defp host_dirs(%{remote?: false} = config, _worker_host) do
    qa_root = Path.join(config.scratch_dir, "app-root")
    File.mkdir!(qa_root)
    Map.merge(config, %{host_dir: config.scratch_dir, build_dir: config.worktree, qa_root: qa_root})
  end

  # Only the operator can read the canary, so a QA host that reads it runs as the operator.
  defp host_dirs(config, worker_host) do
    canary = Path.join(config.scratch_dir, "canary")
    File.write!(canary, "")
    File.chmod!(canary, 0o600)

    case config.host.prepare.(System.user_home!(), canary) do
      {:ok, dir} ->
        Logger.info("QA driver runs on worker_host=#{worker_host} dir=#{dir}")
        Map.merge(config, %{host_dir: dir, build_dir: Path.join(dir, "src"), qa_root: Path.join(dir, "app-root")})

      {:error, {:unsafe, problems}} ->
        Logger.warning("QA driver refused worker_host=#{worker_host}: #{problems}")

        unavailable(
          config,
          "qa_worker_unsafe",
          "The QA host #{worker_host} #{problems}. QA must not run where PR code can reach push credentials. " <>
            "Answer with verdict `blocked` and this reason; an operator fixes the QA host (see docs/configuration.md, Auto Review macOS app QA)."
        )

      {:error, {:unreachable, reason}} ->
        Logger.warning("QA driver could not reach worker_host=#{worker_host}: #{reason}")
        unavailable(config, "qa_worker_unreachable", "The QA host #{worker_host} could not be prepared: #{reason}. Answer with verdict `blocked` and this reason.")
    end
  end

  defp unavailable(config, code, message), do: Map.merge(config, %{host_dir: nil, unavailable: tool_error(code, message)})

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}
  def handle_call(:build, _from, state), do: {:reply, state.build, state}
  def handle_call(:ignored, _from, state), do: {:reply, state.ignored, state}
  def handle_call(:helper, _from, state), do: {:reply, state.helper, state}
  def handle_call({:helper, path}, _from, state), do: {:reply, :ok, %{state | helper: path}}

  def handle_call({:record_build, fingerprint, ignored}, _from, state),
    do: {:reply, :ok, %{state | build: fingerprint, ignored: ignored}}

  def handle_call({:launch, executable}, _from, state) do
    running = Enum.count(state.apps, fn {_pid, app} -> app.exit_status == nil end)

    if running >= @max_running_apps do
      {:reply, tool_error("qa_too_many_apps", "#{running} launched apps are still running; quit one with qa_quit_app first."), state}
    else
      launch(executable, state)
    end
  end

  def handle_call({:running, pid}, _from, state) do
    reply =
      case Map.fetch(state.apps, pid) do
        {:ok, %{exit_status: nil}} -> {:ok, pid}
        {:ok, app} -> exited_error(pid, app)
        :error -> not_launched_error(pid)
      end

    {:reply, reply, state}
  end

  def handle_call({:quit, pid}, _from, state) do
    case Map.fetch(state.apps, pid) do
      {:ok, app} ->
        if app.exit_status == nil, do: state.config.host.kill.(pid)
        payload = %{"pid" => pid, "quit" => true, "output" => tail(app.output, @output_limit)}
        payload = if app.exit_status, do: Map.put(payload, "exit_status", app.exit_status), else: payload
        {:reply, {:ok, payload}, %{state | apps: Map.delete(state.apps, pid)}}

      :error ->
        {:reply, not_launched_error(pid), state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    {:noreply, update_app(state, port, fn app -> %{app | output: tail(app.output <> data, @app_output_limit)} end)}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    {:noreply, update_app(state, port, fn app -> %{app | exit_status: status} end)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {pid, %{exit_status: nil}} <- state.apps, do: state.config.host.kill.(pid)
    if state.config.remote? and state.config.host_dir, do: state.config.host.cleanup.(state.config.host_dir)
    File.rm_rf(state.config.scratch_dir)
    :ok
  end

  # Not under System.tmp_dir!(): the agent sandbox may write there.
  defp private_dir do
    runs = Path.join([Paths.state_root(), "qa-driver", "runs"])
    File.mkdir_p!(runs)
    File.chmod!(runs, 0o700)
    dir = Path.join(runs, "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    {:ok, canonical} = PathSafety.canonicalize(dir)
    canonical
  end

  defp launch(executable, state) do
    case state.config.host.launch.(executable, cd: state.config.qa_root, env: launch_env(state.config)) do
      {:ok, port, pid} ->
        Logger.info("QA driver launched app pid=#{pid} executable=#{executable}")
        app = %{port: port, output: "", exit_status: nil}
        payload = %{"pid" => pid, "qa_mode" => true, "note" => "Wait for the window to settle before judging it."}
        {:reply, {:ok, payload}, %{state | apps: Map.put(state.apps, pid, app)}}

      {:error, reason} ->
        {:reply, tool_error("qa_launch_failed", "The app could not start: #{inspect(reason)}"), state}
    end
  end

  # The QA host has its own login environment; only the QA root crosses over.
  defp launch_env(%{remote?: true, qa_root: qa_root}), do: [{@qa_root_env, qa_root}]
  defp launch_env(config), do: AgentEnv.build_with(%{@qa_root_env => config.qa_root})

  defp update_app(state, port, fun) do
    case Enum.find(state.apps, fn {_pid, app} -> app.port == port end) do
      {pid, app} -> %{state | apps: Map.put(state.apps, pid, fun.(app))}
      nil -> state
    end
  end

  defp exited_error(pid, app) do
    tool_error("qa_app_exited", "The app with PID #{pid} exited with status #{app.exit_status}. Last output: #{tail(app.output, 2_000)}")
  end

  defp not_launched_error(pid) do
    tool_error("qa_pid_not_launched", "PID #{pid} was not launched by qa_launch_app in this QA pass; the qa_* tools only drive apps QA launched.")
  end

  defp default_git(args, cwd), do: Workspace.safe_git(["-C", cwd | args], stderr_to_stdout: true)
end
