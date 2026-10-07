defmodule SymphonyElixir.QaDriver.Remote do
  @moduledoc """
  The OS boundary of `SymphonyElixir.QaDriver` on a separate QA host
  (`auto_review.worker_host`): a dedicated macOS VM or macOS user reached with
  `SymphonyElixir.SSH`, the transport `workers.ssh_hosts` uses.

  Every command runs on the QA host as `sh -c <script> sh <args...>`, with each
  argument shell-quoted. Symphony owns one `0700` run directory per pass under
  `~/.symphony-qa/runs/` there: the worktree's `HEAD` is unpacked into `src/`
  for the build, bundle copies go to `builds/`, fixture files `qa_put_file`
  copies go to `files/` and the app's QA root is `app-root/`. The Swift helper
  is compiled into the run directory's `helper/` on first use in each pass,
  never shared between passes: every pass's build
  runs as the QA user and could replace a shared binary, which answers the
  permission, window and accessibility calls of later passes.

  Before a pass uses the host, `prepare/3` refuses one that could reach the
  operator's credentials: one that can open the operator's `~/.ssh`, read their
  `~/.config/gh/hosts.yml` or login Keychain, or read a canary file in
  Symphony's private state (it runs as the operator), and one that holds push
  credentials of its own (a private key in `~/.ssh`, GitHub CLI credentials, a
  global git credential helper or a forwarded SSH agent).
  """

  alias SymphonyElixir.QaDriver.Host
  alias SymphonyElixir.SSH

  @timeout_ms 30_000
  @output_limit 8_000
  @ship_timeout_ms 300_000
  @compile_timeout_ms 300_000
  @read_limit 48_000_000
  @run_dir ~r{\A/.*/\.symphony-qa/runs/run\.[A-Za-z0-9]+\z}
  @file_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @prepare_script """
  operator_home=$1; canary=$2; found=""
  flag() { found="$found; $1"; }
  if [ "$HOME" != "$operator_home" ]; then
    if [ -r "$operator_home/.ssh" ] || [ -x "$operator_home/.ssh" ]; then flag "can open the operator's ~/.ssh"; fi
    if [ -r "$operator_home/.config/gh/hosts.yml" ]; then flag "can read the operator's ~/.config/gh/hosts.yml"; fi
    if [ -r "$operator_home/Library/Keychains/login.keychain-db" ]; then flag "can read the operator's login Keychain"; fi
  fi
  if [ -r "$canary" ]; then flag "can read Symphony's private state, so it runs as the operator"; fi
  for key in "$HOME"/.ssh/id_*; do
    case "$key" in *.pub) ;; *) if [ -e "$key" ]; then flag "has a private key ~/.ssh/${key##*/}"; fi ;; esac
  done
  if [ -e "$HOME/.config/gh/hosts.yml" ]; then flag "has GitHub CLI credentials in ~/.config/gh"; fi
  if [ -n "$(git config --global --get credential.helper 2>/dev/null)" ]; then flag "has a global git credential helper"; fi
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then flag "has a forwarded SSH agent"; fi
  if [ -n "$found" ]; then printf 'symphony-qa-unsafe:%s\\n' "${found#; }"; exit 3; fi
  umask 077
  mkdir -p "$HOME/.symphony-qa/runs" || exit 1
  dir=$(mktemp -d "$HOME/.symphony-qa/runs/run.XXXXXX") || exit 1
  mkdir "$dir/app-root" "$dir/builds" || exit 1
  printf 'symphony-qa-dir:%s\\n' "$(cd "$dir" && pwd -P)"
  """

  @helper_script """
  dir="$1/helper"; bin="$dir/symphony-qa-driver"
  if [ ! -x "$bin" ]; then
    umask 077
    mkdir -p "$dir" || exit 1
    printf %s "$2" | base64 --decode > "$dir/symphony-qa-driver.swift" || exit 1
    swiftc -O -D SYMPHONY_QA_SSH -o "$bin.$$" "$dir/symphony-qa-driver.swift" || exit 1
    mv "$bin.$$" "$bin" || exit 1
  fi
  printf 'symphony-qa-helper:%s\\n' "$bin"
  """

  @read_script """
  if [ ! -f "$1" ] || [ -L "$1" ]; then rm -f "$1"; exit 1; fi
  printf 'symphony-qa-file:'; base64 < "$1" | tr -d '\\n'; printf '\\n'; rm -f "$1"
  """

  # Written under a temporary name first, so the app never reads half a file;
  # `mv` would move it into a directory at the name, so that is refused.
  @put_script """
  umask 077
  mkdir -p "$1/files" || exit 1
  part="$1/files/.put.$$"; dest="$1/files/$2"
  if [ ! -d "$dest" ] && cat > "$part" && mv -f "$part" "$dest"; then printf 'symphony-qa-put:%s\\n' "$dest"; else rm -f "$part"; exit 1; fi
  """

  # Holds the tunnel's SSH session open until Symphony closes its stdin. The
  # QA host's `sshd` answers the `-R` requests before it runs this, so the
  # marker means every forward is listening.
  @tunnel_script ~s(printf 'symphony-qa-tunnel:open\\n'; exec cat > /dev/null)

  @kill_script """
  kill -TERM "$1" 2>/dev/null || exit 0
  i=0
  while [ "$i" -lt 30 ]; do kill -0 "$1" 2>/dev/null || exit 0; sleep 0.1; i=$((i + 1)); done
  pkill -KILL -P "$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; exit 0
  """

  @doc """
  The `SymphonyElixir.QaDriver.host/0` functions for `ssh_host`, plus the
  remote-only `prepare`, `ship`, `put` and `cleanup`.
  """
  @spec host(String.t()) :: map()
  def host(ssh_host) do
    %{
      cmd: &cmd(ssh_host, &1, &2, &3),
      launch: &launch(ssh_host, &1, &2),
      kill: &kill(ssh_host, &1),
      helper: &helper(ssh_host, &1),
      call_helper: &call_helper(ssh_host, &1, &2, &3),
      read: &read(ssh_host, &1),
      prepare: &prepare(ssh_host, &1, &2),
      ship: &ship(ssh_host, &1, &2),
      put: &put(ssh_host, &1, &2, &3),
      tunnel: &tunnel(ssh_host, &1),
      cleanup: &cleanup(ssh_host, &1)
    }
  end

  @doc """
  Checks that the QA host cannot reach the operator's credentials and creates
  the pass's run directory there. `operator_home` is the operator's home
  directory and `canary` a file only the operator can read.
  """
  @spec prepare(String.t(), Path.t(), Path.t()) :: {:ok, String.t()} | {:error, {:unsafe | :unreachable, String.t()}}
  def prepare(ssh_host, operator_home, canary) do
    case run(ssh_host, @prepare_script, [operator_home, canary], []) do
      {:ok, {output, status}} ->
        with nil <- marker(output, "symphony-qa-unsafe"),
             dir when is_binary(dir) <- marker(output, "symphony-qa-dir"),
             true <- Regex.match?(@run_dir, dir) do
          {:ok, dir}
        else
          problems when is_binary(problems) and status == 3 -> {:error, {:unsafe, problems}}
          _other -> {:error, {:unreachable, "ssh exited with status #{status}: #{tail(output, 500)}"}}
        end

      {:error, reason} ->
        {:error, {:unreachable, inspect(reason)}}
    end
  end

  @doc """
  Runs `executable` with `args` on the QA host. Options as `Host.cmd/3`; `:env`
  stays local, and `:remote_env` (`{name, value}` pairs) is added to the QA
  user's environment for the command.
  """
  @spec cmd(String.t(), String.t(), [String.t()], keyword()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def cmd(ssh_host, executable, args, opts) do
    env = for {name, value} <- Keyword.get(opts, :remote_env, []), do: "#{name}=#{value}"
    script = ~s(cd "$1" || exit 125; shift; exec env "$@")
    run(ssh_host, script, [Keyword.get(opts, :cd) || "." | env ++ [executable | args]], Keyword.take(opts, [:timeout_ms, :output_limit]))
  end

  @doc """
  Starts `executable` on the QA host. The returned port belongs to the caller
  and carries the app's output and exit status like a local launch. Options:
  `:cd`, `:env` (only these variables reach the app), `:reverse_forwards` (`{remote,
  local}` addresses the app's SSH session forwards back to this host while it runs;
  the launch fails when one can't be set up) and `:timeout_ms` (for the QA host to
  answer, default 30 seconds).
  """
  @spec launch(String.t(), String.t(), keyword()) :: {:ok, port(), pos_integer()} | {:error, term()}
  def launch(ssh_host, executable, opts) do
    env = for {name, value} <- Keyword.get(opts, :env) || [], value != false, do: "#{name}=#{value}"
    script = ~s(cd "$1" || exit 125; shift; printf 'symphony-qa-pid:%s\\n' "$$"; exec env "$@")

    forwards = Keyword.get(opts, :reverse_forwards, [])
    ssh_opts = if forwards == [], do: [], else: [reverse_forwards: forwards, options: ["-o", "ExitOnForwardFailure=yes"]]

    with {:ok, ssh, args} <- SSH.command(ssh_host, remote_command(script, [Keyword.get(opts, :cd) || "." | env ++ [executable]]), ssh_opts) do
      port = Port.open({:spawn_executable, ssh}, [:binary, :exit_status, :stderr_to_stdout, args: args])
      await_pid(port, "", System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @timeout_ms))
    end
  end

  # The app's own output after the PID line goes back into the mailbox, where
  # `QaDriver` reads the port's output.
  defp await_pid(port, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data

        case Regex.run(~r/symphony-qa-pid:(\d+)\n(.*)\z/s, buffer) do
          [_match, pid, rest] ->
            if rest != "", do: send(self(), {port, {:data, rest}})
            {:ok, port, String.to_integer(pid)}

          nil ->
            await_pid(port, buffer, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:error, "the QA host exited with status #{status}: #{tail(buffer, 500)}"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  @doc """
  Opens one SSH session that forwards each of `ports` on the QA host's loopback
  to the same port on this host's `127.0.0.1` (`ssh -R <port>:127.0.0.1:<port>`),
  for the services the QA agent runs on this host for the app. Loopback
  connections need no macOS Local Network permission, which a LAN address does.

  Returns once every forward listens. The returned port belongs to the caller,
  and closing it ends the session: the QA host's end sees its stdin close. A
  forward the QA host refuses (its port is taken) is `{:port_taken, message}`;
  anything else is `{:failed, message}`.
  """
  @spec tunnel(String.t(), [pos_integer()], keyword()) :: {:ok, port()} | {:error, {:port_taken | :failed, String.t()}}
  def tunnel(ssh_host, ports, opts \\ []) do
    forwards = for port <- ports, do: {Integer.to_string(port), "127.0.0.1:#{port}"}
    options = ["-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]

    case SSH.command(ssh_host, remote_command(@tunnel_script, []), reverse_forwards: forwards, options: options) do
      {:ok, ssh, args} ->
        port = Port.open({:spawn_executable, ssh}, [:binary, :exit_status, :stderr_to_stdout, args: args])
        timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
        await_tunnel(port, "", System.monotonic_time(:millisecond) + timeout_ms, timeout_ms)

      {:error, reason} ->
        {:error, {:failed, inspect(reason)}}
    end
  end

  defp await_tunnel(port, buffer, deadline, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data
        if String.contains?(buffer, "symphony-qa-tunnel:open\n"), do: {:ok, port}, else: await_tunnel(port, buffer, deadline, timeout_ms)

      {^port, {:exit_status, status}} ->
        message = "ssh exited with status #{status}: #{tail(String.trim(buffer), 500)}"
        if buffer =~ "port forwarding failed", do: {:error, {:port_taken, message}}, else: {:error, {:failed, message}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, {:failed, "the QA host did not open the forwards within #{timeout_ms} ms"}}
    end
  end

  @doc "Asks a process on the QA host to quit, then kills it and its children."
  @spec kill(String.t(), pos_integer()) :: :ok
  def kill(ssh_host, pid) do
    run(ssh_host, @kill_script, [Integer.to_string(pid)], [])
    :ok
  end

  @doc "Path of the Swift helper in the run directory `dir` on the QA host, compiling it there on first use."
  @spec helper(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def helper(ssh_host, dir) do
    {_hash, source} = Host.helper_source()

    if Regex.match?(@run_dir, dir) do
      compile_helper(ssh_host, dir, source)
    else
      {:error, {:not_a_run_dir, dir}}
    end
  end

  defp compile_helper(ssh_host, dir, source) do
    case run(ssh_host, @helper_script, [dir, Base.encode64(source)], timeout_ms: @compile_timeout_ms) do
      {:ok, {output, 0}} ->
        case marker(output, "symphony-qa-helper") do
          nil -> {:error, {:swiftc_failed, 0, tail(output, 2_000)}}
          path -> {:ok, path}
        end

      {:ok, {output, status}} ->
        {:error, {:swiftc_failed, status, tail(output, 2_000)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs one helper command on the QA host. The helper there is compiled with
  `SYMPHONY_QA_SSH`, so it runs its commands directly instead of only for its
  own `serve` process: it holds no grant of its own, and commands started over
  SSH use the grant on `sshd-keygen-wrapper`.
  """
  @spec call_helper(String.t(), String.t(), [String.t()], keyword()) :: SymphonyElixir.QaDriver.cmd_result()
  def call_helper(ssh_host, helper, args, opts), do: cmd(ssh_host, helper, args, opts)

  @doc "Copies a regular file from the QA host and removes it there."
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(ssh_host, path) do
    with {:ok, {output, 0}} <- run(ssh_host, @read_script, [path], output_limit: @read_limit),
         [_match, encoded] <- Regex.run(~r/symphony-qa-file:([A-Za-z0-9+\/=]*)\n/, output),
         {:ok, bytes} <- Base.decode64(encoded) do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unreadable}
    end
  end

  @doc "Unpacks the tar archive at `tar` into a fresh `dest` directory on the QA host."
  @spec ship(String.t(), Path.t(), String.t()) :: :ok | {:error, String.t()}
  def ship(ssh_host, tar, dest) do
    case pipe(ssh_host, tar, ~s(rm -rf "$1" && mkdir "$1" && tar -x -f - -C "$1"), [dest], @ship_timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, "exit #{status}: #{tail(output, 500)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Copies the local file `file` to `files/<name>` in the run directory `dir` on
  the QA host, replacing an earlier copy, and returns its path there.
  """
  @spec put(String.t(), Path.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def put(ssh_host, file, dir, name) do
    with true <- Regex.match?(@run_dir, dir) and Regex.match?(@file_name, name),
         {:ok, {output, 0}} <- pipe(ssh_host, file, @put_script, [dir, name], @timeout_ms),
         path when is_binary(path) <- marker(output, "symphony-qa-put") do
      {:ok, path}
    else
      false -> {:error, "#{dir}/files/#{name} is not a file in a run directory"}
      {:ok, {output, status}} -> {:error, "exit #{status}: #{tail(output, 500)}"}
      nil -> {:error, "the QA host did not confirm the copy"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Removes a run directory `prepare/3` created."
  @spec cleanup(String.t(), String.t()) :: :ok
  def cleanup(ssh_host, dir) do
    if Regex.match?(@run_dir, dir), do: run(ssh_host, ~s(rm -rf "$1"), [dir], [])
    :ok
  end

  defp run(ssh_host, script, args, opts) do
    with {:ok, ssh, ssh_args} <- SSH.command(ssh_host, remote_command(script, args)) do
      Host.cmd(ssh, ssh_args, Keyword.merge([timeout_ms: @timeout_ms, output_limit: @output_limit], opts))
    end
  end

  # Runs `script` on the QA host with the local `file` as its stdin.
  defp pipe(ssh_host, file, script, args, timeout_ms) do
    with {:ok, ssh, ssh_args} <- SSH.command(ssh_host, remote_command(script, args)) do
      Host.cmd("/bin/sh", ["-c", ~s(f=$1; shift; exec "$@" < "$f"), "sh", file, ssh | ssh_args], timeout_ms: timeout_ms)
    end
  end

  defp remote_command(script, args), do: Enum.map_join(["sh", "-c", script, "sh" | args], " ", &SSH.shell_escape/1)

  defp marker(output, name) do
    case Regex.run(~r/^#{name}:(.*)$/m, output) do
      [_line, value] -> value
      nil -> nil
    end
  end

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
