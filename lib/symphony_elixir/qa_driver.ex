defmodule SymphonyElixir.QaDriver do
  @moduledoc """
  Host-side driver behind the QA `qa_*` tools for the `macos_app` playbook.

  The QA agent runs sandboxed and cannot build Swift, launch GUI apps or read the
  screen, so Symphony does those few things for it on the host, one driver per QA
  pass. Every tool argument is checked here before anything runs:

  - `qa_build` runs only the configured `build` command, in the QA worktree, with
    the agent's scrubbed environment, and refuses a worktree with edits outside
    `qa-evidence/` and the folders Symphony itself creates there (see
    `SymphonyElixir.AgentEnv.owned_dirs/0`). Gitignored files count too (the
    build reads caches such as SwiftPM's `.build/`): none may exist before the first build, and after a
    build none may appear or change until the next one;
  - a successful `qa_build` copies the configured `app` bundle, which must
    resolve (symlinks included) inside the worktree, into the driver's private
    directory. Symlinks inside the bundle must be relative and must not climb
    with `..`, so the copy cannot reach back into the worktree;
  - `qa_launch_app` starts only that private copy, only while its executable
    still matches what the build produced and the worktree is as that build
    left it, so later worktree edits cannot change what runs. The app always
    gets `SYMPHONY_BAR_QA_ROOT` pointing at the private directory, so it never
    touches real settings or secrets, and `SYMPHONY_QA_OPENROUTER_URL` pointing
    at this pass's `SymphonyElixir.OpenRouter.Stub`, so its OpenRouter flows
    never need a real key (see "OpenRouter stub" below). With `api_fixtures`,
    a directory in the PR checkout (see
    `SymphonyElixir.QaDriver.Checks.read_fixture_dir/4`: regular files only, at
    most 5 MB), the launch copies its checked files into a fresh
    `api-fixtures-<n>/` in the run directory and sets
    `SYMPHONY_BAR_QA_API_FIXTURES` to that copy, so the app reads Symphony's
    local API from those JSON files;
  - `qa_quit_app`, `qa_screenshot`, `qa_ax_tree`, `qa_ax_press`,
    `qa_ax_set_value`, `qa_ax_select`, `qa_click`, `qa_hover`,
    `qa_context_menu`, `qa_key` and `qa_resize_window` accept only a PID this driver launched and that is still
    running; `qa_check_app` also reports on one that has exited;
  - `qa_ax_select` selects a table or outline row (which answers no AXPress)
    through `AXSelectedRows` or `AXSelected`; `qa_click` clicks an element's
    frame centre only when the app's window is on screen there and the
    accessibility hit test finds the app under it (the window list decides when
    the hit test has no answer), so a window that lets clicks through never
    counts as covering, and `qa_key` presses a named key with modifiers in the app's focused window.
    `qa_click` moves the real pointer to the element first (SwiftUI buttons and
    links check where it is when the mouse goes up) and presses the element
    with `AXPress` when the click changed nothing; `qa_hover` moves the pointer
    over an element or point and waits for the app to settle, and
    `qa_context_menu` right-clicks one and lists the menu that opens. They pass
    the same checks as `qa_click` before the pointer moves.
    The helper posts their mouse and key events to the app's PID alone;
  - screenshots land in `qa-evidence/` under the worktree, always as new files:
    a name that already exists, symlinks included, is refused rather than
    followed or replaced;
  - `qa_put_file` hands the app a fixture file the agent wrote (a test
    `symphony.yml`, a `WORKFLOW.md`). It reads only a regular file of at most
    1 MB that resolves inside the worktree or the pass's `$TMPDIR` (`:tmp_dir`),
    and refuses a symlink, a file with other hard links, and a file swapped
    between the check and the read. Locally it returns the file's path; on a QA
    host it copies the checked bytes into the run directory's `files/` there and
    returns that path;
  - `qa_put_checkout` hands the app a git checkout: a `git bundle` the agent
    made, read with the same checks as `qa_put_file`, is cloned (without hooks)
    into the driver's `checkouts/<name>`, locally or on the QA host, and its
    `origin` is set to the `https://github.com/<owner>/<repo>` URL the agent
    names. Nothing is fetched from GitHub;
  - `qa_open_status_menu` opens a launched app's status-bar menu on screen and
    returns its window, for `qa_screenshot`. Pressing the status item through
    Accessibility blocks until the menu closes, so the driver asks the app
    instead: it writes `status-menu/open-<pid>` under the app's QA root, which
    the app (in QA mode only) takes away before opening the menu as a click
    would, then waits for the menu's window (the pop-up menu layer, 101) in the
    helper's window list. A menu that does not open in time takes the request
    back and fails with `qa_status_menu_not_opened`;
  - `qa_api_requests` returns the requests the app logged to `api-requests.jsonl`
    in its QA root since the last call (the POSTs it answered from
    `api_fixtures`), at most the last 500, and takes the log away so the next
    call returns only newer ones. The QA root is outside the agent sandbox, on
    the QA host for a `worker_host`, so the agent cannot read the log itself.

  Release pair: `qa_build_release_pair` builds release N of the app and its
  update N+1, signed with the QA host's test signing identity, into the private
  directory where the app runs; `qa_launch_app` with `release_pair: true` starts
  a fresh copy of N with the pair's update feed beside it; `qa_relaunched_app`
  starts the app N's update helper asks for after an install or a rollback; and
  `qa_update_feed` reads and switches the feed. See
  `SymphonyElixir.QaDriver.ReleasePair`. When the driver stops it also stops the
  feed and any process whose command line names the private directory.

  Appearance: `qa_launch_app`'s optional `appearance`, `light` or `dark`, sets
  `SYMPHONY_BAR_QA_APPEARANCE`, which Symphony's own app reads, and injects the
  appearance library (`priv/qa_driver/symphony-qa-appearance.m`, built on the
  machine the app runs on) with `DYLD_INSERT_LIBRARIES`: it reads the same
  variable and sets any AppKit app's appearance as the app finishes launching,
  so the app draws in that appearance whatever the host's. AppKit reads the
  system appearance from the global defaults only, so a launch argument such as
  `-AppleInterfaceStyle Dark` cannot do it; a light launch still passes
  `-NSRequiresAquaSystemAppearance YES`, which AppKit does read from the
  arguments. The host's own appearance is never switched: a pass that dies would
  leave it switched for the next one, and switching it needs Apple Events.

  App stand-ins: besides `api_fixtures`, `qa_launch_app` takes five optional
  arguments that point the app at stand-ins instead of real services, all only
  in QA mode:

  - `gh_stub_port` (one of the pass's host ports) sets `SYMPHONY_BAR_GH` to
    Symphony's own fake `gh` script, written into the run directory's `bin/`,
    and `SYMPHONY_QA_GH_URL` to `http://localhost:<port>`. The fake sends each
    call's arguments to the agent's server there (`argc` and one `arg` form
    field per argument, in order) and prints its answer: a 200 on stdout with
    exit status 0, anything else on stderr with exit status 1. The script is
    Symphony's, so the app never runs code the agent wrote;
  - `linear_stub_port` sets `SYMPHONY_QA_LINEAR_URL` to
    `http://localhost:<port>/graphql`, where the Add Repo sheet sends its
    Linear queries;
  - `open_panel_dir` (a path `qa_put_checkout` returned in this pass) sets
    `SYMPHONY_BAR_QA_OPEN_PANEL_DIR`, the folder the app's folder picker opens
    in, so the agent can choose that checkout with the panel's Choose button;
  - `update_feed_port` (one of the pass's host ports) sets `SYMPHONY_BAR_UPDATE_URL`
    to `http://localhost:<port>/releases/latest`, the release feed the app's
    update checks read instead of GitHub's;
  - `update_check_interval_seconds` (a positive integer) sets
    `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL`, the seconds between the app's
    background update checks.

  Screenshots and accessibility calls run in the helper app,
  `SymphonyQADriver.app` (see `SymphonyElixir.QaDriver.Host`), which holds the
  Screen Recording and Accessibility grants so that Symphony and the agents it
  spawns never do. Without them the tools fail with `qa_permission_missing` and
  tell the agent to mark the app steps `blocked`, finish the other playbooks' steps
  and answer `blocked`.

  The private directory (bundle copies, screenshot staging and the app's QA
  root) is a `0700` directory under Symphony's state root, outside every path
  the agent sandbox may write.

  Wide pass: `qa_resize_window` sizes an app's window to at least 1400×900 pt,
  or the screen's usable area when that is smaller, and remembers the size it
  reached. `qa_check_app` then says whether the app still runs, answers an
  accessibility request within 10 seconds, and has left no new
  `~/Library/Logs/DiagnosticReports/<executable>*` crash report (listed at launch
  and again at each check, on the QA host for a `worker_host`), naming the page
  the agent passes and that window size in each problem. A resize on a screen
  whose usable area is under 1400×900 pt marks the pass's wide pass limited
  (`wide_pass/1`), which `SymphonyElixir.QaAgent` reports as `blocked`, as it does
  a `pass` with no resize at all (`wide_pass/1` is `nil`), unless it is an epic
  review that launched no app (`launched_app?/1`).

  OpenRouter stub: the first `qa_launch_app` starts a
  `SymphonyElixir.OpenRouter.Stub` in this BEAM, on `127.0.0.1`, and every app
  of the pass gets its URL. The app, and the Symphony it runs, use it only in QA
  mode (`SymphonyElixir.OpenRouter.base_url/1`).

  Host ports: the driver picks three free ports on this host's loopback for the
  pass (`host_ports/1`, `QA_HOST_PORTS` in the QA agent's prompt and
  environment, and in the environment of the playbook's `build`). The agent serves the app's stubs and proxies on `127.0.0.1` at
  those ports, and the app reaches them at `http://localhost:<port>`.

  When the driver stops (the QA pass ends or crashes) it quits every app it
  launched, stops the stub, closes the host-port tunnel and removes its private
  directory.

  With `:worker_host` (`auto_review.worker_host`) the build, the app and the
  helper run on that QA host instead, through `SymphonyElixir.QaDriver.Remote`.
  The worktree checks stay on the Symphony host; `qa_build` then ships the
  worktree's `HEAD` (a `git archive`, so ignored files stay behind) into a fresh
  build directory on the QA host, copies the bundle into Symphony's run
  directory there and launches it from that copy. The agent cannot write on the
  QA host, so the copy is not checked again before launch. Screenshots are
  captured there and copied back into `qa-evidence/`, and `qa_put_file` and
  `api_fixtures` copy fixtures there (`api_fixtures` as a tar of the checked
  files), because the app cannot read the Symphony host's files. Each
  app's SSH session forwards a random loopback port on the QA host back to the
  stub (`ssh -R`), and the app gets that port's URL. At start the driver also
  opens one SSH session that forwards each host port from the QA host's
  loopback to the same port here (`SymphonyElixir.QaDriver.Remote.tunnel/3`),
  so `localhost` means the same service on both machines: an app on the bridged
  QA VM cannot reach this host's NAT address, and macOS asks a person before an
  app connects to a LAN address, while loopback needs no permission. A forward
  the QA host refuses is retried on fresh ports; a tunnel that still cannot open
  makes `host_ports/1` return the reason, and the QA pass is `blocked` with it.
  A tunnel that closes during the pass is reopened at the next `qa_launch_app`,
  which fails with `qa_host_tunnel_failed` when it cannot. A QA host that can reach
  the operator's credentials or holds push credentials is refused at start,
  and every tool then fails with `qa_worker_unsafe`.

  Next, the driver looks for each executable the playbook `requires` with `command -v`, in the
  shell and environment the build gets (over SSH on a `worker_host`). `host_check/1` returns the
  ones missing, and the QA pass is `blocked` before the agent starts: the QA host needs
  provisioning (`scripts/qa-vm/provision.sh`), which is not the project's defect.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{AgentEnv, OpenRouter, PathSafety, Workspace}
  alias SymphonyElixir.QaDriver.{Checks, Host, ReleasePair, Remote}

  @evidence_dir "qa-evidence"
  @qa_root_env "SYMPHONY_BAR_QA_ROOT"
  @api_fixtures_env "SYMPHONY_BAR_QA_API_FIXTURES"
  @appearance_env "SYMPHONY_BAR_QA_APPEARANCE"
  @appearances ~w(light dark)
  # AppKit reads this default from the launch arguments too. There is none for dark: the
  # appearance library does both.
  @appearance_args %{"light" => ["-NSRequiresAquaSystemAppearance", "YES"]}
  # The window layer of a pop-up menu (`kCGPopUpMenuWindowLevel`), where the
  # status item's menu opens.
  @menu_layer 101
  # How many times, and how many ms apart, `qa_open_status_menu` looks for the menu.
  @status_menu_poll {40, 250}
  # The app logs each request it answers from API fixtures here, under its QA root.
  @api_requests_log "api-requests.jsonl"
  @max_api_requests 500
  # The QA host's loopback ports an app's SSH session may forward to the stub.
  @stub_remote_ports 20_000..59_999
  @host_port_count 3
  @tunnel_attempts 3
  @default_build_timeout_ms 900_000
  # Two Symphony releases and a release build of the app.
  @default_release_pair_timeout_ms 1_800_000
  # How many ms apart `qa_relaunched_app` looks for the update helper's request.
  @relaunch_poll_ms 1_000
  @default_relaunch_wait_s 60
  # How many times, and how many ms apart, the driver asks a starting feed for its mode.
  @feed_poll {50, 100}
  @feed_attempts 3
  @helper_timeout_ms 30_000
  # Prints each executable `command -v` cannot find, then a line that says the check ran.
  @tool_check_script ~S(for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || printf 'symphony-qa-missing-tool:%s\n' "$tool"; done; printf 'symphony-qa-tools:checked\n')
  @screenshot_timeout_ms 15_000
  @output_limit 8_000
  @app_output_limit 16_000
  @tree_bytes_limit 100_000
  @max_running_apps 3
  @max_screenshots 8
  @value_limit 10_000
  @press_actions ~w(AXPress AXRaise AXShowMenu AXConfirm AXCancel AXIncrement AXDecrement AXPick)
  # The keys `qa_key` presses: named keys, then single characters the helper
  # maps to US-layout key codes.
  @named_keys ~w(return enter tab space escape delete forward_delete up down left right home end page_up page_down)
  @character_keys String.graphemes("abcdefghijklmnopqrstuvwxyz0123456789[],./;'-=`\\")
  @modifiers ~w(command shift option control)
  @element_path ~r/\A\d{1,4}(\.\d{1,4}){0,63}\z/
  # The wide pass needs a window at least this size (points).
  @wide_width 1400
  @wide_height 900
  @max_window_size 8192
  # Screen coordinates `qa_hover` and `qa_context_menu` take, in points; a
  # display left of or above the main one has negative ones.
  @max_coordinate 32_768
  @pointer_commands %{"qa_hover" => "hover", "qa_context_menu" => "context-menu"}

  # Clones the bundle `$2` into `$1/checkouts/$3` without hooks (the empty
  # template and `core.hooksPath` keep the operator's out too) and points
  # `origin` at `$4`. The bundle is removed either way.
  @checkout_script """
  dest="$1/checkouts/$3"
  if [ -e "$dest" ] || [ -L "$dest" ]; then rm -f "$2"; echo "$dest already exists; pass another remote_name"; exit 3; fi
  mkdir -p "$1/checkouts" || exit 1
  if ! GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null clone --quiet --template= -- "$2" "$dest" 2>&1; then rm -rf "$dest"; rm -f "$2"; exit 1; fi
  rm -f "$2"
  git -C "$dest" remote set-url origin "$4" || exit 1
  printf 'symphony-qa-checkout:%s\\n' "$dest"
  """

  # Writes Symphony's fake `gh` (`$2`) to `$1/bin/gh`.
  @install_gh_script """
  mkdir -p "$1/bin" && printf '%s' "$2" > "$1/bin/gh.part" && chmod 700 "$1/bin/gh.part" && mv -f "$1/bin/gh.part" "$1/bin/gh" || exit 1
  printf 'symphony-qa-gh:%s\\n' "$1/bin/gh"
  """

  # Symphony's fake `gh` for the app: it hands each call to the QA agent's gh
  # stub and prints the answer.
  @fake_gh """
  #!/bin/sh
  # Symphony's QA stand-in for the GitHub CLI. It sends its arguments to the QA
  # agent's gh stub at $SYMPHONY_QA_GH_URL as form fields (argc, then one arg per
  # argument, in order) and prints the answer: a 200 on stdout with exit status 0,
  # anything else on stderr with exit status 1.
  url=${SYMPHONY_QA_GH_URL:-}
  if [ -z "$url" ]; then echo "gh (Symphony QA stand-in): SYMPHONY_QA_GH_URL is not set" >&2; exit 1; fi
  n=$#
  for arg do set -- "$@" --data-urlencode "arg=$arg"; done
  shift "$n"
  out=$(mktemp "${TMPDIR:-/tmp}/symphony-qa-gh.XXXXXX") || exit 1
  code=$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -d "argc=$n" "$@" "$url") || code=000
  if [ "$code" = 200 ]; then cat "$out"; status=0
  elif [ "$code" = 000 ]; then echo "gh (Symphony QA stand-in): couldn't reach the gh stub at $url" >&2; status=1
  else cat "$out" >&2; status=1; fi
  rm -f "$out"
  exit "$status"
  """

  @github_url ~r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?\z}
  @checkout_timeout_ms 60_000

  # Asks the app with PID `$2` to open its status-bar menu: an empty
  # `status-menu/open-<pid>` under its QA root (`$1`), which the app takes away.
  @status_menu_script """
  mkdir -p "$1/status-menu" && : > "$1/status-menu/open-$2"
  """

  # Lists the crash reports named after the app (`$1`, its executable) in the
  # user's DiagnosticReports, one name per line. No folder means no reports.
  @crash_reports_script """
  cd "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null || exit 0
  for report in "$1"[-_.]*; do if [ -f "$report" ]; then printf '%s\\n' "$report"; fi; done
  """

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

  @tools ~w(qa_build qa_launch_app qa_quit_app qa_screenshot qa_ax_tree qa_ax_press qa_ax_set_value qa_ax_select qa_click qa_key) ++
           ~w(qa_hover qa_context_menu qa_resize_window qa_check_app qa_put_file qa_put_checkout qa_api_requests qa_open_status_menu) ++
           ~w(qa_build_release_pair qa_relaunched_app qa_update_feed)

  @type host :: %{
          required(:cmd) => (String.t(), [String.t()], keyword() -> {:ok, {String.t(), integer()}} | {:error, term()}),
          required(:launch) => (String.t(), keyword() -> {:ok, port(), pos_integer()} | {:error, term()}),
          required(:kill) => (pos_integer() -> :ok),
          # A QA host's helper takes the pass's run directory.
          required(:helper) => (-> helper_result()) | (String.t() -> helper_result()),
          required(:call_helper) => (Path.t(), [String.t()], keyword() -> cmd_result()),
          optional(:read) => (Path.t() -> {:ok, binary()} | {:error, term()}),
          # The appearance library `qa_launch_app` injects; a QA host's takes the run directory.
          optional(:appearance_library) => (-> helper_result()) | (String.t() -> helper_result()),
          optional(:prepare) => (Path.t(), Path.t() -> {:ok, String.t()} | {:error, {atom(), String.t()}}),
          optional(:ship) => (Path.t(), String.t() -> :ok | {:error, String.t()}),
          optional(:put) => (Path.t(), String.t(), String.t() -> {:ok, String.t()} | {:error, String.t()}),
          optional(:tunnel) => ([pos_integer()] -> {:ok, port()} | {:error, {:port_taken | :failed, String.t()}}),
          optional(:cleanup) => (String.t() -> :ok)
        }
  @type helper_result :: {:ok, Path.t()} | {:error, term()}
  @type cmd_result :: {:ok, {String.t(), integer()}} | {:error, term()}
  @type tool_error :: {:qa_tool, String.t(), String.t()}
  @type host_check_error :: {:qa_host_missing_tool, [String.t()]} | {:qa_host_tool_check_failed, String.t()}

  @doc "The `qa_*` tool names this driver serves."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc """
  Starts a driver for one QA pass.

  Options: `:worktree` (required), `:playbook` (the selected `macos_app` playbook
  with `build`, `app` and optional `build_timeout_ms`), `:tmp_dir` (the pass's
  `$TMPDIR`, where `qa_put_file` may read besides the worktree), `:worker_host`
  (the SSH host QA runs on, default this host), `:log_context` (the issue's
  `issue_id=… issue_identifier=…` for the driver's logs), `:host` (overrides for the OS
  boundary, see `t:host/0`), `:git` (a `fn args, cwd -> {output, status}`) and
  `:start_stub` (a `fn -> {:ok, pid, port} | {:error, reason}` that starts the
  OpenRouter stub, default `SymphonyElixir.OpenRouter.Stub.start_link/0`) and
  `:status_menu_poll` (`{attempts, interval_ms}` for `qa_open_status_menu`,
  default `{40, 250}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The pass's wide pass: the screen, its usable area and the window size of the
  last `qa_resize_window`, and whether that screen limited it (`limited: true`
  when its usable area is under 1400×900 pt). `nil` when no window was resized
  or there is no driver.
  """
  @spec wide_pass(pid() | nil) :: map() | nil
  def wide_pass(nil), do: nil

  def wide_pass(driver) when is_pid(driver) do
    GenServer.call(driver, :wide_pass)
  catch
    :exit, _reason -> nil
  end

  @doc """
  Whether the pass launched an app with `qa_launch_app`, even one that has quit since.
  `false` when there is no driver.
  """
  @spec launched_app?(pid() | nil) :: boolean()
  def launched_app?(nil), do: false

  def launched_app?(driver) when is_pid(driver) do
    GenServer.call(driver, :launched_app?)
  catch
    :exit, _reason -> false
  end

  @doc "Stops the driver, quitting every app it launched."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(driver) when is_pid(driver) do
    GenServer.stop(driver, :normal, 30_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The ports on this host's loopback that the QA agent may serve the app's stubs
  and proxies on, which the app reaches at `http://localhost:<port>` wherever it
  runs. `{:error, reason}` when the tunnel to the QA host could not open.
  """
  @spec host_ports(pid() | nil) :: {:ok, [pos_integer()]} | {:error, String.t()}
  def host_ports(nil), do: {:ok, []}
  def host_ports(driver) when is_pid(driver), do: GenServer.call(driver, :host_ports, 30_000)

  @doc """
  Whether the QA host has every executable the playbook `requires`:
  `{:error, {:qa_host_missing_tool, names}}` names the missing ones, and
  `{:error, {:qa_host_tool_check_failed, reason}}` says the check could not run. `:ok` too
  when the driver refused the QA host, whose tools then fail with `qa_worker_unsafe`.
  """
  @spec host_check(pid() | nil) :: :ok | {:error, host_check_error()}
  def host_check(nil), do: :ok
  def host_check(driver) when is_pid(driver), do: GenServer.call(driver, :host_check, 30_000)

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
         {:ok, {output, status}} <- run_build(config, build_env(driver)) |> rebaseline_on_timeout(driver, config),
         {:ok, ignored, _dirty} <- worktree_status(config) do
      record_build(driver, config, status, tail(output, @output_limit), ignored_signatures(config, ignored))
    end
  end

  defp run_tool("qa_launch_app", driver, config, args) do
    case Map.get(args, "release_pair") do
      flag when flag in [nil, false] -> launch_build(driver, config, args)
      true -> launch_pair(driver, config, args)
      _other -> tool_error("invalid_arguments", "`release_pair` must be true or false.")
    end
  end

  defp run_tool("qa_quit_app", driver, _config, args) do
    with {:ok, pid} <- pid_argument(args) do
      GenServer.call(driver, {:quit, pid}, 30_000)
    end
  end

  defp run_tool("qa_build_release_pair", driver, config, _args) do
    with :ok <- ensure_clean_worktree(config, GenServer.call(driver, :ignored)),
         {:ok, source} <- ReleasePair.source(config),
         {:ok, identity} <- ReleasePair.identity(config, source),
         :ok <- ReleasePair.copy_feed_server(config, source),
         :ok <- GenServer.call(driver, :stop_feed, 30_000),
         {:ok, {output, status}} <- ReleasePair.build(config, source, identity) |> rebaseline_on_timeout(driver, config),
         {:ok, ignored, _dirty} <- worktree_status(config) do
      driver
      |> record_pair(config, status, tail(output, @output_limit), ignored_signatures(config, ignored))
      |> identity_installed(identity)
    end
  end

  defp run_tool("qa_relaunched_app", driver, config, args) do
    with {:ok, wait_s} <- optional_integer(args, "wait_seconds", 1, 300),
         {:ok, launches} <- pair_launches(driver),
         {:ok, bundle} <- await_relaunch(config, wait_s || @default_relaunch_wait_s),
         {:ok, info} <- relaunch_info(launches, bundle),
         {:ok, name} <- bundle_executable_name(config, bundle),
         {:ok, payload} <- GenServer.call(driver, {:launch, Path.join([bundle, "Contents", "MacOS", name]), %{info | name: name}}) do
      note = "The update helper asked to start this app again: the update it installed, or the build it rolled back to. Drive it with this PID."
      {:ok, payload |> Map.merge(ReleasePair.bundle_version(config, bundle)) |> Map.merge(%{"bundle" => bundle, "note" => note})}
    end
  end

  defp run_tool("qa_update_feed", driver, config, args) do
    with {:ok, mode} <- feed_mode(Map.get(args, "mode")),
         {:ok, feed} <- running_feed(driver),
         {:ok, _mode} <- if(mode, do: ReleasePair.set_mode(config, feed.port_number, mode), else: {:ok, nil}),
         {:ok, current} <- ReleasePair.mode(config, feed.port_number),
         {:ok, requests} <- ReleasePair.requests(config, feed.log) do
      {:ok, %{"mode" => current, "url" => ReleasePair.latest_url(feed.port_number), "requests" => requests}}
    end
  end

  defp run_tool("qa_screenshot", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, name} <- Checks.screenshot_name(Map.get(args, "name")),
         {:ok, window_id} <- optional_integer(args, "window_id", 1, 0xFFFF_FFFF),
         {:ok, helper} <- helper(driver, config),
         :ok <- require_screen_recording(config, helper),
         {:ok, %{"windows" => windows}} <- run_helper(config, helper, ["windows", Integer.to_string(pid)]),
         {:ok, targets} <- screenshot_targets(windows, window_id),
         {:ok, evidence} <- Checks.ensure_evidence_dir(config.worktree) do
      capture(config, helper, pid, targets, name, evidence)
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

  defp run_tool("qa_ax_select", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, path} <- element_path(Map.get(args, "path")),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, ["ax-select", Integer.to_string(pid), path])
    end
  end

  defp run_tool("qa_click", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, path} <- element_path(Map.get(args, "path")),
         {:ok, clicks} <- optional_integer(args, "clicks", 1, 2),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, ["click", Integer.to_string(pid), path, Integer.to_string(clicks || 1)])
    end
  end

  defp run_tool(tool, driver, config, args) when is_map_key(@pointer_commands, tool) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, target} <- pointer_target(args),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, [@pointer_commands[tool], Integer.to_string(pid), target])
    end
  end

  defp run_tool("qa_key", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, key} <- key_name(Map.get(args, "key")),
         {:ok, modifiers} <- modifiers(Map.get(args, "modifiers")),
         {:ok, helper} <- helper(driver, config) do
      run_helper(config, helper, ["key", Integer.to_string(pid), key, Enum.join(modifiers, ",")])
    end
  end

  defp run_tool("qa_resize_window", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, path} <- optional_element_path(Map.get(args, "path")),
         {:ok, width} <- optional_integer(args, "width", @wide_width, @max_window_size),
         {:ok, height} <- optional_integer(args, "height", @wide_height, @max_window_size),
         {:ok, helper} <- helper(driver, config),
         size_args = [Integer.to_string(width || @wide_width), Integer.to_string(height || @wide_height)],
         {:ok, resized} <- run_helper(config, helper, ["ax-resize", Integer.to_string(pid), path | size_args]),
         {:ok, wide_pass} <- wide_pass_of(resized) do
      GenServer.call(driver, {:resized, pid, wide_pass})
      {:ok, Map.merge(resized, %{"limited" => wide_pass.limited, "note" => resize_note(wide_pass)})}
    end
  end

  defp run_tool("qa_check_app", driver, config, args) do
    with {:ok, pid} <- pid_argument(args),
         {:ok, page} <- optional_string(args, "page", 200),
         {:ok, app} <- GenServer.call(driver, {:app, pid}),
         {:ok, reports} <- crash_reports(config, app.name),
         {:ok, responding} <- responding(driver, config, pid, app) do
      {:ok, health(pid, page, app, reports -- app.crash_reports, responding, config)}
    end
  end

  defp run_tool("qa_open_status_menu", driver, config, args) do
    with {:ok, pid} <- running_pid(driver, args),
         {:ok, helper} <- helper(driver, config),
         :ok <- request_status_menu(config, pid) do
      await_status_menu(config, helper, pid, config.status_menu_poll)
    end
  end

  defp run_tool("qa_put_file", _driver, config, args) do
    with {:ok, local_path} <- Checks.fixture_path(Map.get(args, "local_path")),
         {:ok, name} <- put_file_name(Map.get(args, "remote_name"), local_path),
         {:ok, path, bytes} <- Checks.read_fixture(config.put_roots, config.worktree, local_path, "qa_put_file") do
      put_file(config, path, bytes, name)
    end
  end

  defp run_tool("qa_api_requests", _driver, config, _args) do
    log = Path.join(config.qa_root, @api_requests_log)
    taken = Path.join(config.host_dir, "api-requests-#{System.unique_integer([:positive])}.jsonl")

    # Moved aside before it is read, so a request the app logs meanwhile lands in
    # a fresh log for the next call instead of being lost.
    case config.host.cmd.("/bin/mv", ["-f", log, taken], timeout_ms: @helper_timeout_ms, output_limit: @output_limit) do
      {:ok, {_output, 0}} ->
        read_api_requests(config, taken)

      {:ok, {output, _status}} ->
        if output =~ "No such file",
          do: api_requests([]),
          else: tool_error("qa_api_requests_failed", "The app's #{@api_requests_log} could not be taken: #{String.trim(output)}")

      {:error, reason} ->
        tool_error("qa_api_requests_failed", "The app's #{@api_requests_log} could not be taken: #{inspect(reason)}")
    end
  end

  defp run_tool("qa_put_checkout", driver, config, args) do
    with {:ok, local_path} <- Checks.fixture_path(Map.get(args, "local_path")),
         {:ok, url, repo} <- github_url(Map.get(args, "remote_url")),
         {:ok, name} <- checkout_name(Map.get(args, "remote_name"), repo),
         {:ok, _path, bytes} <- Checks.read_fixture(config.put_roots, config.worktree, local_path, "qa_put_checkout"),
         {:ok, bundle} <- stage_bundle(config, bytes, name),
         {:ok, path} <- clone_checkout(config, bundle, name, url) do
      GenServer.call(driver, {:checkout, path})
      {:ok, %{"path" => path, "remote_url" => url, "note" => "Pass this path as qa_launch_app's open_panel_dir to open the folder picker in it."}}
    end
  end

  # -- launches ---------------------------------------------------------------

  defp launch_build(driver, config, args) do
    with {:ok, fixtures} <- api_fixtures(config, args),
         {:ok, built} <- fetch_build(driver),
         {:ok, stand_ins} <- stand_ins(driver, config, args),
         :ok <- ensure_clean_worktree(config, GenServer.call(driver, :ignored)),
         :ok <- unchanged_build(config, built),
         name = Path.basename(built.executable),
         {:ok, reports} <- crash_reports(config, name),
         {:ok, library_env} <- appearance_library(config, Map.get(args, "appearance")),
         {:ok, fixtures_dir} <- copy_api_fixtures(config, fixtures) do
      app_args = appearance_args(Map.get(args, "appearance"))
      stand_ins = stand_ins ++ library_env
      info = %{name: name, crash_reports: reports, api_fixtures: fixtures_dir, stand_ins: stand_ins, args: app_args}
      GenServer.call(driver, {:launch, built.executable, info})
    end
  end

  # N of the release pair, from a fresh copy, with the pair's feed beside it and
  # Symphony's relaunch stand-in as the update helper's `open`.
  defp launch_pair(driver, config, args) do
    with :ok <- pair_feed_argument(args),
         {:ok, fixtures} <- api_fixtures(config, args),
         {:ok, _pair} <- fetch_pair(driver),
         {:ok, stand_ins} <- stand_ins(driver, config, args),
         {:ok, bundle} <- ReleasePair.copy_n(config),
         {:ok, name} <- bundle_executable_name(config, bundle),
         {:ok, reports} <- crash_reports(config, name),
         {:ok, library_env} <- appearance_library(config, Map.get(args, "appearance")),
         {:ok, relaunch} <- ReleasePair.install_relaunch(config),
         {:ok, feed_port} <- GenServer.call(driver, :ensure_feed, 300_000),
         {:ok, fixtures_dir} <- copy_api_fixtures(config, fixtures) do
      pair_env = [{"SYMPHONY_BAR_UPDATE_URL", ReleasePair.latest_url(feed_port)}, {"SYMPHONY_UPDATE_OPEN", relaunch}]
      stand_ins = stand_ins ++ library_env ++ pair_env
      info = %{name: name, crash_reports: reports, api_fixtures: fixtures_dir, stand_ins: stand_ins}
      info = Map.merge(info, %{pair_bundle: bundle, args: appearance_args(Map.get(args, "appearance"))})

      with {:ok, payload} <- GenServer.call(driver, {:launch, Path.join([bundle, "Contents", "MacOS", name]), info}) do
        note =
          "Release N of the pair runs from a fresh copy, and its update checks read the pair's feed, which offers N+1 " <>
            "(qa_update_feed switches it and shows its requests). Once N installs N+1 and quits, call qa_relaunched_app."

        {:ok, Map.merge(payload, %{"release_pair" => true, "bundle" => bundle, "note" => note})}
      end
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
        [] -> :ok
        changed -> Checks.worktree_modified(changed, "do not edit files in the worktree, including gitignored ones.")
      end
    end
  end

  # `qa-evidence/` is the agent's to write, and so are new files in the folders
  # Symphony itself writes into the QA agent's workspace, such as
  # `.gradle-daemons/`: the build does not read them.
  defp worktree_status(config) do
    Checks.worktree_status(config.git, config.worktree, ["--untracked-files=all", "--ignored=traditional"])
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
  # A pair that timed out is forgotten like a build, but the last build stays.
  defp rebaseline_on_timeout({:error, {:qa_tool, "qa_build_timeout", _message}} = error, driver, config),
    do: rebaseline(error, driver, config, &{:record_build, nil, &1})

  defp rebaseline_on_timeout({:error, {:qa_tool, "qa_release_pair_timeout", _message}} = error, driver, config) do
    GenServer.call(driver, {:record_pair, nil})
    rebaseline(error, driver, config, &{:record_ignored, &1})
  end

  defp rebaseline_on_timeout(result, _driver, _config), do: result

  defp rebaseline(error, driver, config, message) do
    with {:ok, ignored, _dirty} <- worktree_status(config) do
      GenServer.call(driver, message.(ignored_signatures(config, ignored)))
      error
    end
  end

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

  # The build gets `QA_HOST_PORTS` as the QA agent does, so a QA build can name
  # the port of a stub the agent serves; without a tunnel it gets none.
  defp build_env(driver) do
    case host_ports(driver) do
      {:ok, ports} -> %{"QA_HOST_PORTS" => Enum.join(ports, ",")}
      {:error, _reason} -> %{}
    end
  end

  # `:env` is this host's environment; on a QA host the build gets only `:remote_env`.
  defp run_build(config, extra_env) do
    opts = [
      cd: config.build_dir,
      env: AgentEnv.build_with(extra_env),
      remote_env: Enum.to_list(extra_env),
      timeout_ms: config.build_timeout_ms,
      output_limit: @output_limit
    ]

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

  # -- release pair -------------------------------------------------------------

  # Like a build, the pair's outputs in the worktree become the ignored baseline
  # whether or not it succeeded; the last qa_build's app stays launchable.
  defp record_pair(driver, config, 0, output, ignored) do
    GenServer.call(driver, {:record_ignored, ignored})

    case ReleasePair.manifest(config) do
      {:ok, manifest} ->
        GenServer.call(driver, {:record_pair, %{manifest: manifest}})
        note = "Launch release N with qa_launch_app and release_pair: true; its update checks find N+1 in the pair's feed."
        {:ok, %{"exit_status" => 0, "output" => output, "manifest" => manifest, "note" => note}}

      {:error, _reason} = error ->
        GenServer.call(driver, {:record_pair, nil})
        error
    end
  end

  defp record_pair(driver, _config, status, output, ignored) do
    GenServer.call(driver, {:record_ignored, ignored})
    GenServer.call(driver, {:record_pair, nil})
    {:ok, %{"exit_status" => status, "output" => output}}
  end

  defp identity_installed({:ok, payload}, %{installed?: true}) do
    note = "Symphony installed the QA host's QA signing identity this pass: the host had none, or did not trust it. Say so in the QA report."
    {:ok, Map.merge(payload, %{"signing_identity_installed" => true, "signing_identity_note" => note})}
  end

  defp identity_installed(result, _identity), do: result

  defp fetch_pair(driver) do
    case GenServer.call(driver, :pair) do
      nil -> tool_error("qa_release_pair_not_built", "Run qa_build_release_pair first; release_pair launches the pair its last successful run built.")
      pair -> {:ok, pair}
    end
  end

  # The pair serves its own feed, which `update_feed_port` would replace.
  defp pair_feed_argument(%{"update_feed_port" => port}) when not is_nil(port),
    do: tool_error("invalid_arguments", "`update_feed_port` cannot be combined with `release_pair`, which serves the pair's own feed.")

  defp pair_feed_argument(_args), do: :ok

  defp pair_launches(driver) do
    case GenServer.call(driver, :pair_launches) do
      launches when map_size(launches) == 0 ->
        tool_error("qa_release_pair_not_launched", "Launch release N with qa_launch_app and release_pair: true first; qa_relaunched_app starts what its update helper asks for.")

      launches ->
        {:ok, launches}
    end
  end

  defp await_relaunch(config, wait_s), do: await_relaunch(config, wait_s, div(wait_s * 1_000 + config.relaunch_poll_ms - 1, config.relaunch_poll_ms))

  defp await_relaunch(config, wait_s, attempts) do
    case ReleasePair.take_relaunch(config) do
      {:ok, bundle} when is_binary(bundle) ->
        {:ok, bundle}

      {:ok, nil} when attempts > 1 ->
        Process.sleep(config.relaunch_poll_ms)
        await_relaunch(config, wait_s, attempts - 1)

      {:ok, nil} ->
        tool_error(
          "qa_no_relaunch",
          "The update helper asked to start no app within #{wait_s} s. The update may still be downloading or waiting for " <>
            "the app to quit: check the app with qa_check_app and the feed's requests with qa_update_feed, then call this again."
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp relaunch_info(launches, bundle) do
    case Map.fetch(launches, bundle) do
      {:ok, info} -> {:ok, info}
      :error -> tool_error("qa_relaunch_unknown", "The update helper asked to start #{bundle}, which no release_pair launch in this QA pass started.")
    end
  end

  defp feed_mode(nil), do: {:ok, nil}
  defp feed_mode(mode) when is_binary(mode), do: if(mode in ReleasePair.modes(), do: {:ok, mode}, else: bad_feed_mode())
  defp feed_mode(_mode), do: bad_feed_mode()

  defp bad_feed_mode, do: tool_error("invalid_arguments", "`mode` must be one of #{Enum.join(ReleasePair.modes(), ", ")}.")

  defp running_feed(driver) do
    case GenServer.call(driver, :feed) do
      nil -> tool_error("qa_update_feed_not_running", "The pair's update feed is not running: launch release N with qa_launch_app and release_pair: true.")
      feed -> {:ok, feed}
    end
  end

  # -- fixture files -----------------------------------------------------------

  defp put_file(%{remote?: false}, path, bytes, _name), do: {:ok, %{"path" => path, "bytes" => byte_size(bytes)}}

  # The checked bytes travel, not the path, which the agent can still change.
  defp put_file(config, _path, bytes, name) do
    local = Path.join(config.scratch_dir, "put-#{System.unique_integer([:positive])}")
    File.write!(local, bytes, [:exclusive])

    result =
      case config.host.put.(local, config.host_dir, name) do
        {:ok, remote_path} -> {:ok, %{"path" => remote_path, "bytes" => byte_size(bytes)}}
        {:error, reason} -> tool_error("qa_put_file_failed", "The file could not be copied to the QA host: #{reason}")
      end

    File.rm(local)
    result
  end

  # -- API fixtures ------------------------------------------------------------

  defp api_fixtures(_config, %{"api_fixtures" => nil}), do: {:ok, nil}

  defp api_fixtures(config, %{"api_fixtures" => path}) do
    with {:ok, _dir, files} <- Checks.read_fixture_dir(config.worktree, path, "api_fixtures", "qa_launch_app") do
      {:ok, files}
    end
  end

  defp api_fixtures(_config, _args), do: {:ok, nil}

  # Each launch gets its own copy of the checked bytes, so an app still running
  # on an earlier copy keeps it, and later edits in the worktree change nothing.
  defp copy_api_fixtures(_config, nil), do: {:ok, nil}

  defp copy_api_fixtures(%{remote?: false} = config, files) do
    dest = Path.join(config.scratch_dir, "api-fixtures-#{System.unique_integer([:positive])}")
    File.mkdir!(dest)

    for {relative, bytes} <- files do
      path = Path.join(dest, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes, [:exclusive])
    end

    {:ok, dest}
  end

  defp copy_api_fixtures(config, files) do
    name = "api-fixtures-#{System.unique_integer([:positive])}"
    tar = Path.join(config.scratch_dir, name <> ".tar")
    :ok = :erl_tar.create(String.to_charlist(tar), for({relative, bytes} <- files, do: {String.to_charlist(relative), bytes}))
    dest = Path.join(config.host_dir, name)

    result =
      case config.host.ship.(tar, dest) do
        :ok -> {:ok, dest}
        {:error, reason} -> tool_error("qa_launch_failed", "The api_fixtures directory could not be copied to the QA host: #{reason}")
      end

    File.rm(tar)
    result
  end

  # The taken log is removed whether or not it could be read, so a long pass
  # leaves no copies behind in the run directory.
  defp read_api_requests(config, path) do
    result = config.host.read.(path)
    config.host.cmd.("/bin/rm", ["-f", path], timeout_ms: @helper_timeout_ms, output_limit: @output_limit)

    case result do
      {:ok, bytes} ->
        bytes |> String.split("\n", trim: true) |> Enum.map(&api_request/1) |> api_requests()

      {:error, reason} ->
        tool_error("qa_api_requests_failed", "The app's #{@api_requests_log} could not be read: #{inspect(reason)}")
    end
  end

  defp api_request(line) do
    case Jason.decode(line) do
      {:ok, request} -> request
      {:error, _reason} -> line
    end
  end

  defp api_requests(requests) do
    dropped = max(length(requests) - @max_api_requests, 0)
    {:ok, %{"requests" => Enum.drop(requests, dropped), "dropped" => dropped}}
  end

  # -- checkouts ---------------------------------------------------------------

  # The bundle goes where the clone runs: the private directory locally, the
  # run directory's `files/` on a QA host.
  defp stage_bundle(config, bytes, name) do
    local = Path.join(config.scratch_dir, "checkout-#{System.unique_integer([:positive])}.bundle")
    File.write!(local, bytes, [:exclusive])

    if config.remote? do
      result = config.host.put.(local, config.host_dir, name <> ".bundle")
      File.rm(local)

      case result do
        {:ok, remote_path} -> {:ok, remote_path}
        {:error, reason} -> tool_error("qa_put_checkout_failed", "The bundle could not be copied to the QA host: #{reason}")
      end
    else
      {:ok, local}
    end
  end

  defp clone_checkout(config, bundle, name, url) do
    args = ["-c", @checkout_script, "sh", config.host_dir, bundle, name, url]

    case config.host.cmd.("/bin/sh", args, timeout_ms: @checkout_timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        case Regex.run(~r/^symphony-qa-checkout:(.+)$/m, output) do
          [_line, path] -> {:ok, path}
          nil -> tool_error("qa_put_checkout_failed", "The checkout was not confirmed: #{tail(output, 1_000)}")
        end

      {:ok, {output, status}} ->
        tool_error("qa_put_checkout_failed", "git could not clone the bundle (exit #{status}): #{tail(output, 1_000)} Make it with `git bundle create <file> --all`.")

      {:error, reason} ->
        tool_error("qa_put_checkout_failed", "git could not clone the bundle: #{inspect(reason)}")
    end
  end

  # -- app stand-ins ------------------------------------------------------------

  # The extra environment `qa_launch_app`'s stand-in arguments give the app.
  defp stand_ins(driver, config, args) do
    %{host_ports: ports, checkouts: checkouts} = GenServer.call(driver, :stand_in_choices)

    with {:ok, gh_port} <- stub_port(args, "gh_stub_port", ports),
         {:ok, linear_port} <- stub_port(args, "linear_stub_port", ports),
         {:ok, panel_dir} <- open_panel_dir(Map.get(args, "open_panel_dir"), checkouts),
         {:ok, feed_port} <- stub_port(args, "update_feed_port", ports),
         {:ok, interval} <- update_check_interval(Map.get(args, "update_check_interval_seconds")),
         {:ok, appearance} <- appearance(Map.get(args, "appearance")),
         {:ok, gh_env} <- gh_env(config, gh_port) do
      linear_env = if linear_port, do: [{"SYMPHONY_QA_LINEAR_URL", "http://localhost:#{linear_port}/graphql"}], else: []
      panel_env = if panel_dir, do: [{"SYMPHONY_BAR_QA_OPEN_PANEL_DIR", panel_dir}], else: []
      feed_env = if feed_port, do: [{"SYMPHONY_BAR_UPDATE_URL", "http://localhost:#{feed_port}/releases/latest"}], else: []
      interval_env = if interval, do: [{"SYMPHONY_BAR_UPDATE_CHECK_INTERVAL", Integer.to_string(interval)}], else: []
      appearance_env = if appearance, do: [{@appearance_env, appearance}], else: []
      {:ok, gh_env ++ linear_env ++ panel_env ++ feed_env ++ interval_env ++ appearance_env}
    end
  end

  defp stub_port(args, key, ports) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      port when is_integer(port) -> if port in ports, do: {:ok, port}, else: bad_stub_port(key, ports)
      _other -> bad_stub_port(key, ports)
    end
  end

  defp bad_stub_port(key, ports),
    do: tool_error("invalid_arguments", "`#{key}` must be one of QA_HOST_PORTS (#{Enum.join(ports, ", ")}), where your stub listens.")

  defp open_panel_dir(nil, _checkouts), do: {:ok, nil}

  defp open_panel_dir(path, checkouts) do
    if path in checkouts,
      do: {:ok, path},
      else: tool_error("invalid_arguments", "`open_panel_dir` must be a path qa_put_checkout returned in this QA pass.")
  end

  defp update_check_interval(nil), do: {:ok, nil}
  defp update_check_interval(seconds) when is_integer(seconds) and seconds > 0, do: {:ok, seconds}

  defp update_check_interval(_other),
    do: tool_error("invalid_arguments", "`update_check_interval_seconds` must be a positive whole number of seconds.")

  defp appearance(nil), do: {:ok, nil}
  defp appearance(appearance) when appearance in @appearances, do: {:ok, appearance}
  defp appearance(_other), do: tool_error("invalid_arguments", "`appearance` must be `light` or `dark`.")

  defp appearance_args(appearance), do: Map.get(@appearance_args, appearance, [])

  # The environment that injects the appearance library, built on the machine the app runs on.
  defp appearance_library(_config, nil), do: {:ok, []}

  defp appearance_library(config, appearance) do
    case if(config.remote?, do: config.host.appearance_library.(config.host_dir), else: config.host.appearance_library.()) do
      {:ok, path} ->
        {:ok, [{"DYLD_INSERT_LIBRARIES", path}]}

      {:error, reason} ->
        tool_error(
          "qa_appearance_unavailable",
          "Symphony could not build the library that draws the app #{appearance}: #{inspect(reason)}. #{Checks.blocked_hint()}"
        )
    end
  end

  defp gh_env(_config, nil), do: {:ok, []}

  defp gh_env(config, port) do
    with {:ok, {output, 0}} <- config.host.cmd.("/bin/sh", ["-c", @install_gh_script, "sh", config.host_dir, @fake_gh], timeout_ms: @helper_timeout_ms),
         [_line, path] <- Regex.run(~r/^symphony-qa-gh:(.+)$/m, output) do
      {:ok, [{"SYMPHONY_BAR_GH", path}, {"SYMPHONY_QA_GH_URL", "http://localhost:#{port}"}]}
    else
      other -> tool_error("qa_launch_failed", "Symphony's fake gh could not be installed for the app: #{inspect(other)}")
    end
  end

  defp github_url(url) when is_binary(url) do
    case Regex.run(@github_url, url) do
      [_url, owner, repo] -> {:ok, "https://github.com/#{owner}/#{repo}.git", repo}
      nil -> bad_github_url()
    end
  end

  defp github_url(_url), do: bad_github_url()

  defp bad_github_url, do: tool_error("invalid_arguments", "`remote_url` must be a GitHub repo URL like https://github.com/acme/widgets.")

  defp checkout_name(nil, repo), do: checkout_name(repo, repo)

  defp checkout_name(name, _repo) do
    if Checks.fixture_name?(name),
      do: {:ok, name},
      else: tool_error("invalid_arguments", "`remote_name` must be 1-128 characters of letters, digits, `.`, `_` or `-`, starting with a letter or digit.")
  end

  # -- argument checks --------------------------------------------------------

  defp pid_argument(%{"pid" => pid}) when is_integer(pid) and pid > 0, do: {:ok, pid}
  defp pid_argument(_args), do: tool_error("invalid_arguments", "`pid` must be the positive integer qa_launch_app returned.")

  defp running_pid(driver, args) do
    with {:ok, pid} <- pid_argument(args) do
      GenServer.call(driver, {:running, pid})
    end
  end

  defp element_path(path) when is_binary(path) do
    if Regex.match?(@element_path, path) do
      {:ok, path}
    else
      tool_error("invalid_arguments", "`path` must be an element path from qa_ax_tree, like `0.2.1`.")
    end
  end

  defp element_path(_path), do: tool_error("invalid_arguments", "`path` is required.")

  defp optional_element_path(nil), do: {:ok, ""}
  defp optional_element_path(path), do: element_path(path)

  # An element path, or a point on screen as the helper takes it: `x,y`.
  defp pointer_target(%{"path" => _path} = args) when is_map_key(args, "x") or is_map_key(args, "y"),
    do: tool_error("invalid_arguments", "Pass an element `path` or a point's `x` and `y`, not both.")

  defp pointer_target(%{"path" => path}), do: element_path(path)

  defp pointer_target(args) do
    with {:ok, x} <- optional_integer(args, "x", -@max_coordinate, @max_coordinate),
         {:ok, y} <- optional_integer(args, "y", -@max_coordinate, @max_coordinate) do
      if x && y,
        do: {:ok, "#{x},#{y}"},
        else: tool_error("invalid_arguments", "Pass an element `path` from qa_ax_tree, or both `x` and `y` of a point on screen.")
    end
  end

  defp press_action(nil), do: {:ok, "AXPress"}
  defp press_action(action) when action in @press_actions, do: {:ok, action}
  defp press_action(_action), do: tool_error("invalid_arguments", "`action` must be one of #{Enum.join(@press_actions, ", ")}.")

  defp key_name(key) when key in @named_keys or key in @character_keys, do: {:ok, key}

  defp key_name(_key) do
    tool_error(
      "invalid_arguments",
      "`key` must be one of #{Enum.join(@named_keys, ", ")}, or one lowercase letter, digit or one of #{Enum.join(Enum.drop(@character_keys, 36), " ")}."
    )
  end

  defp modifiers(nil), do: {:ok, []}

  defp modifiers(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @modifiers)) and Enum.uniq(list) == list,
      do: {:ok, list},
      else: tool_error("invalid_arguments", "`modifiers` must list each of #{Enum.join(@modifiers, ", ")} at most once.")
  end

  defp modifiers(_list), do: tool_error("invalid_arguments", "`modifiers` must be a list such as [\"command\"].")

  defp set_value(value) when is_binary(value) and byte_size(value) <= @value_limit do
    if String.contains?(value, <<0>>), do: tool_error("invalid_arguments", "`value` must not contain NUL bytes."), else: {:ok, value}
  end

  defp set_value(_value), do: tool_error("invalid_arguments", "`value` must be a string of at most #{@value_limit} bytes.")

  defp put_file_name(nil, local_path), do: put_file_name(Path.basename(local_path), local_path)

  defp put_file_name(name, _local_path) do
    if Checks.fixture_name?(name) do
      {:ok, name}
    else
      tool_error("invalid_arguments", "`remote_name` must be 1-128 characters of letters, digits, `.`, `_` or `-`, starting with a letter or digit.")
    end
  end

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

  # -- wide pass --------------------------------------------------------------

  defp wide_pass_of(resized) do
    with {:ok, window} <- size_of(resized, "window"),
         {:ok, screen} <- size_of(resized, "screen"),
         {:ok, {vw, vh} = visible} <- size_of(resized, "visible") do
      {:ok, %{window: window, screen: screen, visible: visible, limited: vw < @wide_width or vh < @wide_height}}
    else
      :error -> tool_error("qa_helper_failed", "The QA helper returned no window size: #{inspect(resized)}")
    end
  end

  defp size_of(resized, key) do
    case resized do
      %{^key => %{"w" => w, "h" => h}} when is_integer(w) and is_integer(h) -> {:ok, {w, h}}
      _other -> :error
    end
  end

  defp resize_note(%{limited: true} = wide_pass) do
    "The QA screen is #{size(wide_pass.screen)} with #{size(wide_pass.visible)} usable, under the #{size({@wide_width, @wide_height})} " <>
      "the wide pass needs, so the window is #{size(wide_pass.window)}. Run the wide pass at this size, report the screen size, " <>
      "and mark the Wide pass step `blocked` as limited: Symphony reports a pass whose wide pass was limited as `blocked`."
  end

  defp resize_note(%{window: {w, h}} = wide_pass) when w < @wide_width or h < @wide_height do
    "The app kept its window at #{size(wide_pass.window)} on a #{size(wide_pass.screen)} screen: the window has a maximum size " <>
      "or ignored the resize. Resize the app's main window (pass its `path`) for the wide pass."
  end

  defp resize_note(wide_pass), do: "The window is #{size(wide_pass.window)} on a #{size(wide_pass.screen)} screen."

  defp size({w, h}), do: "#{w}×#{h} pt"

  defp crash_reports(config, name) do
    case config.host.cmd.("/bin/sh", ["-c", @crash_reports_script, "sh", name], timeout_ms: @helper_timeout_ms, output_limit: @tree_bytes_limit) do
      {:ok, {output, 0}} ->
        {:ok, String.split(output, "\n", trim: true)}

      {:ok, {output, status}} ->
        tool_error("qa_crash_reports_failed", "Listing the app's crash reports failed (exit #{status}): #{tail(output, 500)}")

      {:error, reason} ->
        tool_error("qa_crash_reports_failed", "Listing the app's crash reports failed: #{inspect(reason)}")
    end
  end

  # An app that exited answers nothing; a helper that gave up waiting on the app
  # means it is hung too.
  defp responding(_driver, _config, _pid, %{exit_status: status}) when is_integer(status), do: {:ok, nil}

  defp responding(driver, config, pid, _app) do
    with {:ok, helper} <- helper(driver, config) do
      case run_helper(config, helper, ["ax-ping", Integer.to_string(pid)]) do
        {:ok, _reply} -> {:ok, true}
        {:error, {:qa_tool, code, _message}} when code in ["qa_app_not_responding", "qa_helper_timeout"] -> {:ok, false}
        {:error, _reason} = error -> error
      end
    end
  end

  defp health(pid, page, app, new_reports, responding, config) do
    where = where(page, app.window)

    problems =
      Enum.reject(
        [
          app.exit_status && "The app exited with status #{app.exit_status}#{where}. Last output: #{tail(app.output, 2_000)}",
          responding == false && "The app did not answer accessibility requests for 10 seconds#{where}: it is hung.",
          new_reports != [] &&
            "New crash report#{where} in ~/Library/Logs/DiagnosticReports#{if config.remote?, do: " on the QA host"}: #{Enum.join(new_reports, ", ")}."
        ],
        &(&1 in [nil, false])
      )

    %{
      "pid" => pid,
      "page" => page,
      "window" => window_payload(app.window),
      "running" => app.exit_status == nil,
      "responding" => responding,
      "crash_reports" => new_reports,
      "healthy" => problems == [],
      "problems" => problems
    }
  end

  defp where(page, window) do
    case Enum.reject([page && "page #{inspect(page)}", window && "window #{size(window)}"], &is_nil/1) do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp window_payload(nil), do: nil
  defp window_payload({w, h}), do: %{"w" => w, "h" => h}

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
        tool_error("qa_helper_unavailable", "Symphony could not find or build its macOS QA helper: #{inspect(reason)}")
    end
  end

  defp require_screen_recording(config, helper) do
    case run_helper(config, helper, ["permissions"]) do
      {:ok, %{"screen_recording" => true}} -> :ok
      {:ok, _permissions} -> permission_missing(config, "Screen Recording")
      {:error, _reason} = error -> error
    end
  end

  defp run_helper(config, helper, args) do
    with {:ok, output} <- run_helper_raw(config, helper, args) do
      decode_helper_output(output)
    end
  end

  defp run_helper_raw(config, helper, args) do
    case config.host.call_helper.(helper, args, timeout_ms: @helper_timeout_ms, output_limit: @tree_bytes_limit + 1) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> helper_error(config, output)
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

  defp helper_error(config, output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"code" => "accessibility_permission_missing"}}} ->
        permission_missing(config, "Accessibility")

      {:ok, %{"error" => %{"code" => code, "message" => message}}} when is_binary(code) and is_binary(message) ->
        tool_error("qa_" <> code, message)

      _other ->
        tool_error("qa_helper_failed", "The QA helper failed: #{tail(output, 500)}")
    end
  end

  defp permission_missing(config, grant) do
    {holder, grantee} =
      if config.remote?,
        do: {"SSH on the QA host", "/usr/libexec/sshd-keygen-wrapper on the QA host"},
        else: {"The Symphony QA Driver helper app", "SymphonyQADriver.app"}

    tool_error(
      "qa_permission_missing",
      "#{holder} has no #{grant} permission, so QA cannot see the app. " <>
        "#{Checks.blocked_hint()} An operator grants Screen Recording and Accessibility to #{grantee} " <>
        "once in System Settings > Privacy & Security (see docs/configuration.md, macOS app QA)."
    )
  end

  # -- status-bar menu ---------------------------------------------------------

  defp request_status_menu(config, pid) do
    args = ["-c", @status_menu_script, "sh", config.qa_root, Integer.to_string(pid)]

    case config.host.cmd.("/bin/sh", args, timeout_ms: @helper_timeout_ms, output_limit: @output_limit) do
      {:ok, {_output, 0}} -> :ok
      other -> tool_error("qa_status_menu_failed", "The request to open the status-bar menu could not be written: #{inspect(other)}")
    end
  end

  defp await_status_menu(config, helper, pid, {attempts, interval_ms}) do
    case run_helper(config, helper, ["windows", Integer.to_string(pid)]) do
      {:ok, %{"windows" => windows}} when is_list(windows) ->
        case Enum.find(windows, &status_menu?/1) do
          %{} = menu ->
            {:ok, status_menu_payload(pid, menu)}

          nil when attempts > 1 ->
            Process.sleep(interval_ms)
            await_status_menu(config, helper, pid, {attempts - 1, interval_ms})

          nil ->
            cancel_status_menu(config, pid)

            tool_error(
              "qa_status_menu_not_opened",
              "The app did not open its status-bar menu within #{status_menu_wait(config)} of the request (its window list showed no menu). " <>
                "Check it is still responding with qa_check_app; an app built before qa_open_status_menu existed ignores the request."
            )
        end

      {:ok, other} ->
        cancel_status_menu(config, pid)
        tool_error("qa_helper_failed", "The QA helper returned no window list: #{inspect(other)}")

      {:error, _reason} = error ->
        cancel_status_menu(config, pid)
        error
    end
  end

  # A request the app never took would open the menu later, in the middle of
  # another step.
  defp cancel_status_menu(config, pid) do
    path = Path.join([config.qa_root, "status-menu", "open-#{pid}"])
    config.host.cmd.("/bin/rm", ["-f", path], timeout_ms: @helper_timeout_ms, output_limit: @output_limit)
  end

  defp status_menu_wait(%{status_menu_poll: {attempts, interval_ms}}), do: "#{Float.round(attempts * interval_ms / 1000, 1)} s"

  defp status_menu?(window), do: window["layer"] == @menu_layer and window["onscreen"] == true and visible?(window)

  defp status_menu_payload(pid, menu) do
    %{
      "pid" => pid,
      "window_id" => menu["id"],
      "frame" => menu["frame"],
      "note" => "The menu is open. Screenshot it with qa_screenshot and this window_id; qa_key with key `escape` closes it."
    }
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

  defp capture(config, helper, pid, targets, name, evidence) do
    numbered = length(targets) > 1

    targets
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {window, index}, {:ok, files} ->
      file = if numbered, do: "#{name}-#{index}.png", else: "#{name}.png"

      case capture_window(config, helper, pid, window, evidence, file) do
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
  defp capture_window(config, helper, pid, window, evidence, file) do
    scratch = Path.join(config.host_dir, "window-#{window["id"]}.png")
    args = ["screenshot", Integer.to_string(pid), Integer.to_string(window["id"]), scratch]

    with {:ok, {_output, 0}} <- config.host.call_helper.(helper, args, timeout_ms: @screenshot_timeout_ms, output_limit: @output_limit),
         {:ok, png} <- config.host.read.(scratch) do
      Checks.write_evidence(Path.join(evidence, file), png, file)
    else
      _failure -> tool_error("qa_screenshot_failed", "screencapture could not capture window #{window["id"]}.")
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
      requires: Map.get(playbook, :requires, []),
      scratch_dir: Checks.private_dir("qa-driver"),
      put_roots: Checks.fixture_roots(worktree, Keyword.get(opts, :tmp_dir)),
      remote?: worker_host != nil,
      worker_host: worker_host,
      log_context: Keyword.get(opts, :log_context),
      host: Map.merge(base_host, Map.new(Keyword.get(opts, :host, %{}))),
      git: Keyword.get(opts, :git, &default_git/2),
      start_stub: Keyword.get(opts, :start_stub, &OpenRouter.Stub.start_link/0),
      status_menu_poll: Keyword.get(opts, :status_menu_poll, @status_menu_poll),
      release_pair_timeout_ms: Keyword.get(opts, :release_pair_timeout_ms, @default_release_pair_timeout_ms),
      relaunch_poll_ms: Keyword.get(opts, :relaunch_poll_ms, @relaunch_poll_ms),
      feed_poll: Keyword.get(opts, :feed_poll, @feed_poll)
    }

    state = %{config: host_dirs(config, worker_host), build: nil, ignored: %{}, apps: %{}, helper: nil, stub: nil}
    state = Map.merge(state, %{wide_pass: nil, launched_app?: false, host_ports: pick_host_ports(), tunnel: nil, tunnel_error: nil, checkouts: []})
    state = Map.merge(state, %{pair: nil, pair_launches: %{}, feed: nil})
    state = Map.put(state, :host_check, check_tools(state.config))
    {:ok, open_tunnel(state, @tunnel_attempts)}
  end

  # After the credentials check, so a refused QA host runs nothing more. The check runs in the
  # build's shell and environment, so a tool it finds is one the build finds.
  defp check_tools(%{unavailable: _error}), do: :ok
  defp check_tools(%{requires: []}), do: :ok

  defp check_tools(config) do
    opts = [env: AgentEnv.build_with(%{}), remote_env: [], timeout_ms: @helper_timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", ["-c", @tool_check_script, "sh" | config.requires], opts) do
      {:ok, {output, 0}} -> tool_check_result(output)
      {:ok, {output, status}} -> {:error, {:qa_host_tool_check_failed, "exit status #{status}: #{tail(String.trim(output), 500)}"}}
      {:error, reason} -> {:error, {:qa_host_tool_check_failed, inspect(reason)}}
    end
  end

  defp tool_check_result(output) do
    lines = String.split(output, "\n", trim: true)

    case {"symphony-qa-tools:checked" in lines, for("symphony-qa-missing-tool:" <> name <- lines, do: name)} do
      {false, _missing} -> {:error, {:qa_host_tool_check_failed, "no answer: #{tail(String.trim(output), 500)}"}}
      {true, []} -> :ok
      {true, missing} -> {:error, {:qa_host_missing_tool, missing}}
    end
  end

  # Held open together, so the ports differ; the agent binds them later.
  defp pick_host_ports do
    sockets =
      for _index <- 1..@host_port_count do
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
        socket
      end

    ports = for socket <- sockets, do: elem(:inet.port(socket), 1)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end

  # A local app reaches the host ports directly, and a QA host Symphony refused
  # runs no app.
  defp open_tunnel(%{config: %{remote?: false}} = state, _attempts), do: state
  defp open_tunnel(%{config: %{unavailable: _error}} = state, _attempts), do: state

  defp open_tunnel(state, attempts) do
    case state.config.host.tunnel.(state.host_ports) do
      {:ok, tunnel} ->
        Logger.info("QA driver forwards host ports=#{Enum.join(state.host_ports, ",")} to the QA host")
        %{state | tunnel: tunnel, tunnel_error: nil}

      {:error, {:port_taken, message}} when attempts > 1 ->
        Logger.info("QA driver retries the host-port tunnel on fresh ports: #{message}")
        open_tunnel(%{state | host_ports: pick_host_ports()}, attempts - 1)

      {:error, {_kind, message}} ->
        Logger.warning("QA driver could not open the host-port tunnel ports=#{Enum.join(state.host_ports, ",")}: #{message}")
        %{state | tunnel_error: message}
    end
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
            "#{Checks.blocked_hint()} An operator fixes the QA host (see docs/configuration.md, macOS app QA)."
        )

      {:error, {:unreachable, reason}} ->
        Logger.warning("QA driver could not reach worker_host=#{worker_host}: #{reason}")
        unavailable(config, "qa_worker_unreachable", "The QA host #{worker_host} could not be prepared: #{reason}. #{Checks.blocked_hint()}")
    end
  end

  defp unavailable(config, code, message), do: Map.merge(config, %{host_dir: nil, unavailable: tool_error(code, message)})

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call(:host_ports, _from, %{tunnel_error: nil} = state), do: {:reply, {:ok, state.host_ports}, state}
  def handle_call(:host_ports, _from, state), do: {:reply, {:error, state.tunnel_error}, state}
  def handle_call(:host_check, _from, state), do: {:reply, state.host_check, state}
  def handle_call(:build, _from, state), do: {:reply, state.build, state}
  def handle_call(:ignored, _from, state), do: {:reply, state.ignored, state}
  def handle_call(:helper, _from, state), do: {:reply, state.helper, state}
  def handle_call(:wide_pass, _from, state), do: {:reply, state.wide_pass, state}
  def handle_call(:launched_app?, _from, state), do: {:reply, state.launched_app?, state}
  def handle_call({:helper, path}, _from, state), do: {:reply, :ok, %{state | helper: path}}

  def handle_call({:record_build, fingerprint, ignored}, _from, state),
    do: {:reply, :ok, %{state | build: fingerprint, ignored: ignored}}

  def handle_call({:record_ignored, ignored}, _from, state), do: {:reply, :ok, %{state | ignored: ignored}}
  def handle_call({:record_pair, pair}, _from, state), do: {:reply, :ok, %{state | pair: pair}}
  def handle_call(:pair, _from, state), do: {:reply, state.pair, state}
  def handle_call(:pair_launches, _from, state), do: {:reply, state.pair_launches, state}
  def handle_call(:feed, _from, state), do: {:reply, state.feed, state}

  # The feed serves the pair's folder, which a new build replaces.
  def handle_call(:stop_feed, _from, state) do
    stop_feed(state)
    {:reply, :ok, %{state | feed: nil}}
  end

  def handle_call(:ensure_feed, _from, state) do
    case start_feed(state, @feed_attempts) do
      {:ok, state} -> {:reply, {:ok, state.feed.port_number}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:stand_in_choices, _from, state), do: {:reply, %{host_ports: state.host_ports, checkouts: state.checkouts}, state}
  def handle_call({:checkout, path}, _from, state), do: {:reply, :ok, %{state | checkouts: [path | state.checkouts]}}

  def handle_call({:launch, executable, info}, _from, state) do
    running = Enum.count(state.apps, fn {_pid, app} -> app.exit_status == nil end)

    cond do
      running >= @max_running_apps ->
        {:reply, tool_error("qa_too_many_apps", "#{running} launched apps are still running; quit one with qa_quit_app first."), state}

      reopen_tunnel?(state) ->
        case open_tunnel(state, 1) do
          %{tunnel_error: nil} = state -> launch(executable, info, state)
          state -> {:reply, tunnel_closed_error(state), state}
        end

      true ->
        launch(executable, info, state)
    end
  end

  def handle_call({:app, pid}, _from, state) do
    case Map.fetch(state.apps, pid) do
      {:ok, app} -> {:reply, {:ok, app}, state}
      :error -> {:reply, not_launched_error(pid), state}
    end
  end

  # The app may have quit since the resize; the pass's wide pass still counts.
  def handle_call({:resized, pid, wide_pass}, _from, state) do
    state = update_in(state.apps, &Map.replace_lazy(&1, pid, fn app -> %{app | window: wide_pass.window} end))
    {:reply, :ok, %{state | wide_pass: wide_pass}}
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

  # The tunnel closed during the pass: the next launch reopens it on the same ports.
  # Its output (`ssh` warnings) matches no app above and is dropped.
  def handle_info({port, {:exit_status, status}}, %{tunnel: port} = state) do
    Logger.warning("QA driver host-port tunnel closed status=#{status}")
    {:noreply, %{state | tunnel: nil}}
  end

  # The feed stopped during the pass: the next release_pair launch starts it again.
  def handle_info({port, {:exit_status, status}}, %{feed: %{port: port}} = state) do
    Logger.warning("QA driver update feed exited status=#{status}")
    {:noreply, %{state | feed: nil}}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    {:noreply, update_app(state, port, fn app -> %{app | exit_status: status} end)}
  end

  # A stub that died is started again at the next launch.
  def handle_info({:EXIT, pid, _reason}, %{stub: %{pid: pid}} = state), do: {:noreply, %{state | stub: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {pid, %{exit_status: nil}} <- state.apps, do: state.config.host.kill.(pid)
    stop_feed(state)
    if state.pair_launches != %{}, do: stop_strays(state.config)
    if state.stub, do: OpenRouter.Stub.stop(state.stub.pid)
    if state.tunnel && Port.info(state.tunnel), do: Port.close(state.tunnel)
    if state.config.remote? and state.config.host_dir, do: state.config.host.cleanup.(state.config.host_dir)
    File.rm_rf(state.config.scratch_dir)
    :ok
  end

  defp launch(executable, info, state) do
    with {:ok, state} <- ensure_stub(state),
         {stub_url, forwards} = stub_route(state.config, state.stub.port),
         launch_opts = [cd: state.config.qa_root, env: launch_env(state.config, stub_url, app_env(info)), args: info.args, reverse_forwards: forwards],
         {:ok, port, pid} <- state.config.host.launch.(executable, launch_opts) do
      Logger.info("QA driver launched app pid=#{pid} executable=#{executable} openrouter_stub=#{stub_url}")
      app = Map.merge(info, %{port: port, output: "", exit_status: nil, window: nil})
      payload = %{"pid" => pid, "qa_mode" => true, "note" => "Wait for the window to settle before judging it."}
      payload = if info.api_fixtures, do: Map.put(payload, "api_fixtures", info.api_fixtures), else: payload
      state = if info[:pair_bundle], do: put_in(state.pair_launches[info.pair_bundle], info), else: state
      {:reply, {:ok, payload}, %{state | apps: Map.put(state.apps, pid, app), launched_app?: true}}
    else
      {:error, {:qa_tool, _code, _message}} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, tool_error("qa_launch_failed", "The app could not start: #{inspect(reason)}"), state}
    end
  end

  defp reopen_tunnel?(state),
    do: state.config.remote? and state.tunnel == nil and not Map.has_key?(state.config, :unavailable)

  defp tunnel_closed_error(state) do
    tool_error(
      "qa_host_tunnel_failed",
      "The tunnel that forwards QA_HOST_PORTS (#{Enum.join(state.host_ports, ", ")}) from the QA host closed and could not reopen: " <>
        "#{state.tunnel_error}. #{Checks.blocked_hint()}"
    )
  end

  # -- update feed --------------------------------------------------------------

  # The feed runs where the app does, on a fresh port each attempt, and is ready
  # once it answers its mode.
  defp start_feed(%{feed: %{}} = state, _attempts), do: {:ok, state}

  defp start_feed(state, attempts) do
    config = state.config
    number = feed_port(config)
    {executable, args, log} = ReleasePair.feed_command(config, number)
    env = if config.remote?, do: [], else: AgentEnv.build()

    case config.host.launch.(executable, cd: ReleasePair.feed_dir(config), env: env, args: args) do
      {:ok, port, os_pid} ->
        feed = %{port: port, os_pid: os_pid, port_number: number, log: log}

        case await_feed(config, feed, config.feed_poll, "") do
          :ok ->
            Logger.info("QA driver started the update feed port=#{number}")
            {:ok, %{state | feed: feed}}

          {:error, why} when attempts > 1 ->
            stop_feed(%{state | feed: feed})
            Logger.info("QA driver retries the update feed on a fresh port: #{why}")
            start_feed(state, attempts - 1)

          {:error, why} ->
            stop_feed(%{state | feed: feed})
            tool_error("qa_update_feed_failed", "The pair's update feed did not start: #{why}")
        end

      {:error, reason} ->
        tool_error("qa_update_feed_failed", "The pair's update feed could not start: #{inspect(reason)}")
    end
  end

  defp await_feed(config, feed, {attempts, interval_ms}, output) do
    port = feed.port

    receive do
      {^port, {:data, data}} ->
        await_feed(config, feed, {attempts, interval_ms}, tail(output <> data, 2_000))

      {^port, {:exit_status, status}} ->
        {:error, "it exited with status #{status}: #{String.trim(output)}"}
    after
      0 ->
        case ReleasePair.mode(config, feed.port_number, 1) do
          {:ok, _mode} ->
            :ok

          {:error, _reason} when attempts > 1 ->
            Process.sleep(interval_ms)
            await_feed(config, feed, {attempts - 1, interval_ms}, output)

          {:error, {:qa_tool, _code, message}} ->
            {:error, "it never answered on port #{feed.port_number}. #{message} #{String.trim(output)}"}
        end
    end
  end

  defp feed_port(%{remote?: true}), do: Enum.random(@stub_remote_ports)

  defp feed_port(_config) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp stop_feed(%{feed: nil}), do: :ok

  defp stop_feed(%{feed: feed, config: config}) do
    config.host.kill.(feed.os_pid)
    if Port.info(feed.port), do: Port.close(feed.port)
    :ok
  end

  # An app a pair launch started can leave its update helper behind, and a
  # relaunch request the pass never took leaves an app nobody started.
  defp stop_strays(config) do
    case ReleasePair.strays(config) do
      [] -> :ok
      pids -> config.host.cmd.("/bin/kill", ["-TERM" | Enum.map(pids, &Integer.to_string/1)], timeout_ms: @helper_timeout_ms, output_limit: @output_limit)
    end

    :ok
  end

  defp ensure_stub(%{stub: %{}} = state), do: {:ok, state}

  defp ensure_stub(state) do
    case state.config.start_stub.() do
      {:ok, pid, port} ->
        Logger.info("QA driver started the OpenRouter stub port=#{port}")
        {:ok, %{state | stub: %{pid: pid, port: port}}}

      {:error, reason} ->
        tool_error("qa_launch_failed", "The OpenRouter stub the app talks to in QA could not start: #{inspect(reason)}")
    end
  end

  # A local app reaches the stub directly. On a QA host the app's SSH session
  # forwards a loopback port there back to the stub; a port already taken
  # fails that launch, and the next one picks another.
  defp stub_route(%{remote?: false}, port), do: {OpenRouter.Stub.url(port), []}

  defp stub_route(%{remote?: true}, port) do
    remote_port = Enum.random(@stub_remote_ports)
    {OpenRouter.Stub.url(remote_port), [{"127.0.0.1:#{remote_port}", "127.0.0.1:#{port}"}]}
  end

  # The QA host has its own login environment; only the QA root, the stub's URL
  # and the launch's own variables (the API fixtures' copy, the stand-ins) cross over.
  defp launch_env(%{remote?: true, qa_root: qa_root}, stub_url, app_env),
    do: [{@qa_root_env, qa_root}, {OpenRouter.qa_url_env(), stub_url} | app_env]

  defp launch_env(config, stub_url, app_env),
    do: AgentEnv.build_with(Map.new([{@qa_root_env, config.qa_root}, {OpenRouter.qa_url_env(), stub_url} | app_env]))

  defp app_env(%{api_fixtures: nil, stand_ins: stand_ins}), do: stand_ins
  defp app_env(%{api_fixtures: dir, stand_ins: stand_ins}), do: [{@api_fixtures_env, dir} | stand_ins]

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
