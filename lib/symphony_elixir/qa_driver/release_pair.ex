defmodule SymphonyElixir.QaDriver.ReleasePair do
  @moduledoc """
  The signed release pair behind `SymphonyElixir.QaDriver`'s `qa_build_release_pair`,
  `qa_launch_app`'s `release_pair`, `qa_relaunched_app` and `qa_update_feed`: release
  N of Symphony.app and its update N+1, built from the QA worktree's `HEAD` by
  `make -C macos release-pair` (`test/support/README.md`) on the QA host, where
  the app runs, so a QA pass can watch N find, verify and install N+1.

  Both are signed with the QA host's persistent test identity, which
  `scripts/qa/install-test-signing-identity.sh` installs and trusts once per QA
  host: a self-signed identity named for QA tests in a keychain of its own, never
  Symphony's release certificate. The build runs that script's `--use` first,
  which unlocks the keychain and prints the identity. On a `worker_host` with
  passwordless sudo (`sudo -n true`) a missing or untrusted identity is installed
  there and then: Symphony runs its own copy of the script, embedded at compile
  time, never the checkout's, which the PR under test may change. Anywhere else
  the tool fails with `qa_signing_identity_missing` or
  `qa_signing_identity_untrusted`, which the QA agent reports as `blocked`:
  Symphony never trusts a code-signing root in the operator's own System keychain
  with a key the PR's build can read. The minisign key is the throwaway one the
  build makes.

  Everything lives in the pass's run directory on the QA host (`host_dir`), never
  in the worktree: the pair in `release-pair/`, a fresh copy of N for each launch in
  `pair-launches/<n>/`, the feed server's code (copied from the checkout's
  `test/support/stubs/`) and its request log in `update-feed/`. The
  build runs in `pair-src/`, a clone of a `git bundle` of the worktree's `HEAD`
  and tags, because the pair's release notes and manifest read git history,
  which a `git archive` leaves out.

  Relaunch: after an install, or a rollback, the app's update helper starts the
  app again. In QA mode it runs `SYMPHONY_UPDATE_OPEN` instead of the app when it
  is set, and the driver sets it to Symphony's own `bin/relaunch`, which leaves
  the bundle's path in `relaunch/` under the app's QA root. `qa_relaunched_app`
  takes that request and starts the bundle itself: an app the helper started
  would run outside Symphony's process tree, where the QA helper app does not
  drive it, and would outlive the pass.
  """

  require Logger

  alias SymphonyElixir.AgentEnv
  alias SymphonyElixir.QaDriver.Checks

  @identity_script "scripts/qa/install-test-signing-identity.sh"
  @installer_path Path.expand(Path.join([__DIR__, "..", "..", "..", @identity_script]))
  @external_resource @installer_path
  @installer File.read!(@installer_path)
  @install_timeout_ms 120_000
  @build_command ~s(make -C macos release-pair RELEASE_PAIR_OUT="$1")
  @python "/usr/bin/python3"
  @timeout_ms 30_000
  @output_limit 8_000
  @manifest_limit 100_000
  @log_lines 200
  @max_requests 200
  @modes ~w(publish none forbidden)

  # Clones the bundle `$1/head.bundle` into a fresh `$2` without hooks and
  # removes the bundle's folder either way.
  @clone_script """
  rm -rf "$2" || exit 1
  if ! GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null -c advice.detachedHead=false clone --quiet --template= -- "$1/head.bundle" "$2" 2>&1; then rm -rf "$1" "$2"; exit 1; fi
  rm -rf "$1"
  printf 'symphony-qa-pair-src:%s\\n' "$2"
  """

  # Copies the update feed's code from the checkout `$1` into `$2/stubs`, so the
  # feed runs what the build saw rather than what the worktree holds later.
  @feed_server_script """
  src="$1/test/support/stubs"
  for file in __init__.py _server.py update_feed.py; do
    if [ ! -f "$src/$file" ] || [ -L "$src/$file" ]; then echo "$src/$file is not a regular file"; exit 1; fi
  done
  rm -rf "$2/stubs" && mkdir -p "$2/stubs" && cp "$src/__init__.py" "$src/_server.py" "$src/update_feed.py" "$2/stubs/" || exit 1
  printf 'symphony-qa-feed-server:%s\\n' "$2/stubs/update_feed.py"
  """

  # Copies release N (`$1/N/Symphony.app`) into a fresh `$2` for one launch.
  @copy_n_script """
  if [ ! -d "$1/N/Symphony.app" ] || [ -L "$1/N/Symphony.app" ]; then echo "$1 holds no N/Symphony.app; run qa_build_release_pair again"; exit 1; fi
  mkdir -p "$2" && ditto "$1/N/Symphony.app" "$2/Symphony.app" || exit 1
  printf 'symphony-qa-pair-app:%s\\n' "$2/Symphony.app"
  """

  # Symphony's stand-in for `open`, which a release pair's update helper runs
  # (`SYMPHONY_UPDATE_OPEN`) with the app to relaunch.
  @relaunch """
  #!/bin/sh
  # Symphony's QA stand-in for `open`. A release pair's update helper runs it with
  # the app to relaunch; it leaves that path in relaunch/ under the app's QA root,
  # and the QA driver starts the app (qa_relaunched_app).
  dir="${SYMPHONY_BAR_QA_ROOT:?}/relaunch"
  mkdir -p "$dir" || exit 1
  part="$dir/.request.$$"
  printf '%s\\n' "$1" > "$part" && mv -f "$part" "$dir/$(date +%s)-$$"
  """

  # Writes the stand-in (`$2`) to `$1/bin/relaunch`.
  @install_relaunch_script """
  mkdir -p "$1/bin" && printf '%s' "$2" > "$1/bin/relaunch.part" && chmod 700 "$1/bin/relaunch.part" && mv -f "$1/bin/relaunch.part" "$1/bin/relaunch" || exit 1
  printf 'symphony-qa-relaunch-script:%s\\n' "$1/bin/relaunch"
  """

  # Takes the oldest relaunch request under the first of the QA roots (`$@`) that has one.
  @take_relaunch_script """
  for root in "$@"; do
    for request in "$root"/relaunch/[0-9]*; do
      if [ -f "$request" ]; then printf 'symphony-qa-relaunch:%s\\n' "$(head -n 1 "$request")"; rm -f "$request"; exit 0; fi
    done
  done
  exit 0
  """

  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}
  @type identity :: %{sha: String.t(), keychain: String.t(), installed?: boolean()}

  @doc "The modes `qa_update_feed` switches the feed to."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "The pair's folder in the pass's private directory."
  @spec root(map()) :: Path.t()
  def root(config), do: Path.join(config.host_dir, "release-pair")

  @doc "The feed server's folder: its code and its request log."
  @spec feed_dir(map()) :: Path.t()
  def feed_dir(config), do: Path.join(config.host_dir, "update-feed")

  @doc """
  The checkout the pair builds from: a clone on the QA host of a `git bundle` of
  the worktree's `HEAD` and tags, in `pair-src/`.
  """
  @spec source(map()) :: {:ok, Path.t()} | tool_error()
  def source(config) do
    staging = Path.join(config.scratch_dir, "pair-bundle")
    tar = Path.join(config.scratch_dir, "pair-bundle.tar")
    File.mkdir_p!(staging)

    result =
      with :ok <- bundle_head(config, Path.join(staging, "head.bundle")),
           :ok <- tar_bundle(staging, tar),
           :ok <- ship_bundle(config, tar) do
        clone_source(config)
      end

    File.rm_rf(staging)
    File.rm(tar)
    result
  end

  defp bundle_head(config, bundle) do
    case config.git.(["bundle", "create", bundle, "HEAD", "--tags"], config.worktree) do
      {_output, 0} -> :ok
      {output, status} -> tool_error("qa_git_failed", "git bundle failed (exit #{status}): #{tail(to_string(output), 500)}")
    end
  end

  defp tar_bundle(staging, tar) do
    case :erl_tar.create(String.to_charlist(tar), [{~c"head.bundle", String.to_charlist(Path.join(staging, "head.bundle"))}]) do
      :ok -> :ok
      {:error, reason} -> tool_error("qa_release_pair_failed", "The checkout could not be packed for the QA host: #{inspect(reason)}")
    end
  end

  defp ship_bundle(config, tar) do
    case config.host.ship.(tar, Path.join(config.host_dir, "pair-bundle")) do
      :ok -> :ok
      {:error, reason} -> tool_error("qa_release_pair_failed", "The checkout could not be copied to the QA host: #{reason}")
    end
  end

  defp clone_source(config) do
    args = ["-c", @clone_script, "sh", Path.join(config.host_dir, "pair-bundle"), Path.join(config.host_dir, "pair-src")]

    case config.host.cmd.("/bin/sh", args, timeout_ms: 300_000, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        case marker(output, "symphony-qa-pair-src") do
          nil -> tool_error("qa_release_pair_failed", "The checkout on the QA host was not confirmed: #{tail(output, 500)}")
          path -> {:ok, path}
        end

      other ->
        tool_error("qa_release_pair_failed", "git could not clone the checkout on the QA host: #{describe(other)}")
    end
  end

  @doc """
  Runs the checkout's `#{@identity_script} --use` where the app runs: it unlocks
  the QA signing identity's keychain and prints the identity, or fails with exit
  status 3 (not installed) or 4 (not trusted for code signing). On a
  `worker_host` with passwordless sudo, either failure installs the identity
  with Symphony's own copy of the script and runs `--use` once more;
  `installed?` says it did.
  """
  @spec identity(map(), Path.t()) :: {:ok, identity()} | tool_error()
  def identity(config, source) do
    case use_identity(config, source) do
      {:absent, code, message} -> install_identity(config, source, code, message)
      result -> result
    end
  end

  @doc "Symphony's own copy of `#{@identity_script}`, which installs the identity on a QA host."
  @spec installer() :: String.t()
  def installer, do: @installer

  defp use_identity(config, source) do
    opts = [cd: source, env: AgentEnv.build(), timeout_ms: @timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", [Path.join(source, @identity_script), "--use"], opts) do
      {:ok, {output, 0}} ->
        with sha when is_binary(sha) <- marker(output, "symphony-qa-signing-identity"),
             true <- Regex.match?(~r/\A[0-9A-F]{40}\z/, sha),
             keychain when is_binary(keychain) and keychain != "" <- marker(output, "symphony-qa-signing-keychain") do
          {:ok, %{sha: sha, keychain: keychain, installed?: false}}
        else
          _other -> identity_error("qa_signing_identity_check_failed", "The QA signing identity check printed no identity: #{tail(output, 500)}")
        end

      {:ok, {output, 3}} ->
        {:absent, "qa_signing_identity_missing", "The QA host has no QA signing identity: #{String.trim(tail(output, 500))}"}

      {:ok, {output, 4}} ->
        {:absent, "qa_signing_identity_untrusted", "The QA host's QA signing identity is not trusted for code signing: #{String.trim(tail(output, 500))}"}

      other ->
        identity_error("qa_signing_identity_check_failed", "The QA signing identity check failed: #{describe(other)}")
    end
  end

  defp install_identity(config, source, code, message) do
    if passwordless_sudo?(config) do
      case run_installer(config) do
        :ok ->
          Logger.info("QA driver installed the QA signing identity #{log_context(config)} outcome=completed")
          installed_identity(config, source)

        {:error, reason} ->
          Logger.warning("QA driver could not install the QA signing identity #{log_context(config)} outcome=failed reason=#{inspect(reason)}")
          identity_error(code, "#{message} Symphony could not install it on the QA host: #{reason}.")
      end
    else
      Logger.info("QA driver left the QA signing identity to an operator #{log_context(config)} reason=no_passwordless_sudo")
      identity_error(code, message)
    end
  end

  defp passwordless_sudo?(config),
    do: match?({:ok, {_output, 0}}, config.host.cmd.("/usr/bin/sudo", ["-n", "true"], timeout_ms: @timeout_ms, output_limit: 1_000))

  # `sudo -n`: the trust step fails rather than waits for a password no one types.
  defp run_installer(config) do
    opts = [cd: config.host_dir, remote_env: [{"SYMPHONY_QA_SIGNING_SUDO", "sudo -n"}], timeout_ms: @install_timeout_ms, output_limit: @output_limit]

    case config.host.cmd.("/bin/sh", ["-c", @installer, "sh"], opts) do
      {:ok, {_output, 0}} -> :ok
      other -> {:error, describe(other)}
    end
  end

  defp installed_identity(config, source) do
    case use_identity(config, source) do
      {:ok, identity} -> {:ok, %{identity | installed?: true}}
      {:absent, code, message} -> identity_error(code, "#{message} Symphony installed it on the QA host this pass, and the check still fails.")
      error -> error
    end
  end

  defp log_context(config), do: String.trim("#{config.log_context} worker_host=#{config.worker_host}")

  defp identity_error(code, message) do
    tool_error(
      code,
      "#{message} #{Checks.blocked_hint()} An operator runs #{@identity_script} once on the QA host " <>
        "(see docs/configuration.md, macOS app QA)."
    )
  end

  @doc "Copies the checkout's update feed code into the feed server's folder."
  @spec copy_feed_server(map(), Path.t()) :: :ok | tool_error()
  def copy_feed_server(config, source) do
    args = ["-c", @feed_server_script, "sh", source, feed_dir(config)]

    case config.host.cmd.("/bin/sh", args, timeout_ms: @timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        if marker(output, "symphony-qa-feed-server"), do: :ok, else: feed_server_missing(output)

      other ->
        feed_server_missing(describe(other))
    end
  end

  defp feed_server_missing(output),
    do: tool_error("qa_release_pair_failed", "The update feed's code could not be copied from the checkout: #{tail(String.trim(output), 500)}")

  @doc """
  Runs `make -C macos release-pair` in `source`, signing with `identity`, into the
  pair's folder. Returns the build's output and exit status like `qa_build`.
  """
  @spec build(map(), Path.t(), identity()) :: {:ok, {String.t(), integer()}} | tool_error()
  def build(config, source, identity) do
    env = %{"SYMPHONY_E2E_SIGNING_IDENTITY" => identity.sha, "SYMPHONY_E2E_KEYCHAIN" => identity.keychain}

    opts = [
      cd: source,
      env: AgentEnv.build_with(env),
      remote_env: Enum.to_list(env),
      timeout_ms: config.release_pair_timeout_ms,
      output_limit: @output_limit
    ]

    case config.host.cmd.("/bin/sh", ["-c", @build_command, "sh", root(config)], opts) do
      {:ok, {output, status}} ->
        {:ok, {output, status}}

      {:error, :timeout} ->
        tool_error("qa_release_pair_timeout", "The release pair did not build within #{config.release_pair_timeout_ms} ms.")

      {:error, reason} ->
        tool_error("qa_release_pair_failed", "The release pair build could not start: #{inspect(reason)}")
    end
  end

  @doc "The `manifest.json` the build wrote, decoded."
  @spec manifest(map()) :: {:ok, map()} | tool_error()
  def manifest(config) do
    path = Path.join(root(config), "manifest.json")

    with {:ok, {output, 0}} <- config.host.cmd.("/bin/cat", [path], timeout_ms: @timeout_ms, output_limit: @manifest_limit),
         {:ok, %{"n" => %{}, "n1" => %{}} = manifest} <- Jason.decode(output) do
      {:ok, manifest}
    else
      other -> tool_error("qa_release_pair_failed", "The release pair's manifest.json could not be read: #{describe(other)}")
    end
  end

  @doc "Copies release N into a fresh folder for one launch and returns the copy's bundle."
  @spec copy_n(map()) :: {:ok, Path.t()} | tool_error()
  def copy_n(config) do
    dest = Path.join([config.host_dir, "pair-launches", Integer.to_string(System.unique_integer([:positive]))])

    case config.host.cmd.("/bin/sh", ["-c", @copy_n_script, "sh", root(config), dest], timeout_ms: 120_000, output_limit: @output_limit) do
      {:ok, {output, 0}} ->
        case marker(output, "symphony-qa-pair-app") do
          nil -> tool_error("qa_launch_failed", "The copy of release N was not confirmed: #{tail(output, 500)}")
          bundle -> {:ok, bundle}
        end

      other ->
        tool_error("qa_launch_failed", "Release N could not be copied for the launch: #{describe(other)}")
    end
  end

  @doc "Writes Symphony's relaunch stand-in into the pass's `bin/` and returns its path."
  @spec install_relaunch(map()) :: {:ok, Path.t()} | tool_error()
  def install_relaunch(config) do
    args = ["-c", @install_relaunch_script, "sh", config.host_dir, @relaunch]

    with {:ok, {output, 0}} <- config.host.cmd.("/bin/sh", args, timeout_ms: @timeout_ms, output_limit: @output_limit),
         path when is_binary(path) <- marker(output, "symphony-qa-relaunch-script") do
      {:ok, path}
    else
      other -> tool_error("qa_launch_failed", "Symphony's relaunch stand-in could not be installed for the app: #{describe(other)}")
    end
  end

  @doc """
  Takes the oldest relaunch request the update helper left in one of the QA roots of the pass's
  release_pair launches: the bundle to start, or `nil`.
  """
  @spec take_relaunch(map(), [Path.t()]) :: {:ok, Path.t() | nil} | tool_error()
  def take_relaunch(config, qa_roots) do
    case config.host.cmd.("/bin/sh", ["-c", @take_relaunch_script, "sh" | qa_roots], timeout_ms: @timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} -> {:ok, marker(output, "symphony-qa-relaunch")}
      other -> tool_error("qa_relaunch_failed", "The update helper's relaunch requests could not be read: #{describe(other)}")
    end
  end

  @doc "The bundle's version and build number from its Info.plist, `nil` for one it cannot read."
  @spec bundle_version(map(), Path.t()) :: %{String.t() => String.t() | nil}
  def bundle_version(config, bundle) do
    info_plist = Path.join([bundle, "Contents", "Info.plist"])

    for {name, key} <- [{"version", "CFBundleShortVersionString"}, {"build", "CFBundleVersion"}], into: %{} do
      case config.host.cmd.("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", info_plist], timeout_ms: @timeout_ms, output_limit: 1_000) do
        {:ok, {output, 0}} -> {name, String.trim(output)}
        _other -> {name, nil}
      end
    end
  end

  @doc "The feed server's executable, arguments and request log, serving the pair's feed on `port`."
  @spec feed_command(map(), pos_integer()) :: {String.t(), [String.t()], Path.t()}
  def feed_command(config, port) do
    dir = feed_dir(config)
    log = Path.join(dir, "feed.log")
    args = [Path.join([dir, "stubs", "update_feed.py"]), "--dir", Path.join(root(config), "feed"), "--port", Integer.to_string(port), "--log", log]
    {@python, args, log}
  end

  @doc "The feed's URL for the app, which runs on the same machine as the feed."
  @spec latest_url(pos_integer()) :: String.t()
  def latest_url(port), do: "http://127.0.0.1:#{port}/releases/latest"

  @doc "The feed's current mode, asked over HTTP where it runs, waiting at most `max_time_s` for the answer."
  @spec mode(map(), pos_integer(), pos_integer()) :: {:ok, String.t()} | tool_error()
  def mode(config, port, max_time_s \\ 5), do: curl(config, max_time_s, ["http://127.0.0.1:#{port}/_feed/mode"])

  @doc "Switches the feed's mode."
  @spec set_mode(map(), pos_integer(), String.t()) :: {:ok, String.t()} | tool_error()
  def set_mode(config, port, mode) when mode in @modes, do: curl(config, 5, ["-X", "POST", "--data", mode, "http://127.0.0.1:#{port}/_feed/mode"])

  defp curl(config, max_time_s, args) do
    case config.host.cmd.("/usr/bin/curl", ["-sS", "-f", "--max-time", Integer.to_string(max_time_s) | args], timeout_ms: @timeout_ms, output_limit: 1_000) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      other -> tool_error("qa_update_feed_failed", "The update feed did not answer: #{describe(other)}")
    end
  end

  @doc """
  The last #{@max_requests} requests in the feed's log, oldest first, without the
  driver's own `/_feed/` calls. A feed that answered nothing yet has no log.
  """
  @spec requests(map(), Path.t()) :: {:ok, [map()]} | tool_error()
  def requests(config, log) do
    case config.host.cmd.("/usr/bin/tail", ["-n", Integer.to_string(@log_lines), log], timeout_ms: @timeout_ms, output_limit: 200_000) do
      {:ok, {output, 0}} ->
        requests =
          for line <- String.split(output, "\n", trim: true),
              {:ok, %{"path" => path} = request} <- [Jason.decode(line)],
              not String.starts_with?(path, "/_feed/"),
              do: request

        {:ok, Enum.take(requests, -@max_requests)}

      {:ok, {output, _status}} ->
        if output =~ "No such file", do: {:ok, []}, else: requests_error(output)

      other ->
        requests_error(describe(other))
    end
  end

  defp requests_error(output), do: tool_error("qa_update_feed_failed", "The update feed's request log could not be read: #{tail(String.trim(output), 500)}")

  @doc """
  The PIDs of processes whose command line names the pass's private directory
  (`host_dir`): apps, update helpers and the feed a pass left behind.
  """
  @spec strays(map()) :: [pos_integer()]
  def strays(config) do
    case config.host.cmd.("/bin/ps", ["-axww", "-o", "pid=,command="], timeout_ms: @timeout_ms, output_limit: 1_000_000) do
      {:ok, {output, 0}} ->
        for line <- String.split(output, "\n", trim: true),
            [pid, command] <- [String.split(String.trim_leading(line), " ", parts: 2)],
            String.contains?(command, config.host_dir),
            {pid, ""} <- [Integer.parse(pid)],
            do: pid

      _other ->
        []
    end
  end

  defp marker(output, name) do
    case Regex.run(~r/^#{name}:(.+)$/m, output) do
      [_line, value] -> value
      nil -> nil
    end
  end

  defp describe({:ok, {output, status}}) when is_binary(output), do: "exit #{status}: #{tail(String.trim(output), 500)}"
  defp describe({:error, reason}), do: inspect(reason)
  defp describe(other), do: inspect(other)

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
