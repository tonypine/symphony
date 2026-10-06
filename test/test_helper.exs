ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

System.put_env(
  "SYMPHONY_SECRET_KEY_BASE",
  System.get_env("SYMPHONY_SECRET_KEY_BASE", String.duplicate("s", 64))
)

# Include the OS pid so concurrent `mix test` runs sharing TMPDIR cannot
# collide on the same suite-global directories (unique_integer/1 sequences are
# nearly identical across separate VM boots).
audit_dir = Path.join(System.tmp_dir!(), "symphony-elixir-test-audit-#{System.pid()}-#{System.unique_integer([:positive])}")
state_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-state-#{System.pid()}-#{System.unique_integer([:positive])}")
logs_root = Path.join(System.tmp_dir!(), "symphony-elixir-test-logs-#{System.pid()}-#{System.unique_integer([:positive])}")
run_store_dir = Application.fetch_env!(:symphony_elixir, :run_store_dir)
# Agent runs and dev servers make their temp folders here, removed at exit, so the ones failed
# runs keep don't stay behind. Its name is short, and it is in `/tmp` where that is writable
# (not macOS's long `/var/folders/...` TMPDIR), so a dev server's unix socket in it still fits
# the 104-byte `sun_path` limit; sandboxed agent runs, which can't write `/tmp`, have a short
# TMPDIR of their own.
agent_run_tmp_root =
  ["/tmp", System.tmp_dir!()]
  |> Enum.map(&Path.join(&1, "st-#{System.pid()}"))
  |> Enum.find(&(File.mkdir_p(&1) == :ok))

Application.put_env(:symphony_elixir, :agent_run_tmp_bases, [agent_run_tmp_root])
Application.put_env(:symphony_elixir, :state_root, state_root)
Application.put_env(:symphony_elixir, :logs_root, logs_root)
Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

# Agents launched in tests keep their tool caches here, seeded from host caches that don't
# exist, so a test never writes the operator's cache folder or copies their Hex packages.
agent_cache_dir = Path.join(System.tmp_dir!(), "symphony-elixir-test-agent-cache-#{System.pid()}-#{System.unique_integer([:positive])}")

Application.put_env(:symphony_elixir, :agent_caches,
  root: Path.join(agent_cache_dir, "agent"),
  host_hex_home: Path.join(agent_cache_dir, "host-hex"),
  host_elixir_make_cache: Path.join(agent_cache_dir, "host-elixir-make")
)

# Verification dev servers in tests start through a stand-in for `sandbox-exec` that drops the
# profile and runs the command, so they also start on Linux and inside the agent sandbox, where
# Seatbelt can't nest. The `:seatbelt` tests use the real one, and only run where it works; the
# `seatbelt` workflow runs them on a macOS runner.
fake_sandbox_exec = Path.join(agent_run_tmp_root, "fake-sandbox-exec")
File.write!(fake_sandbox_exec, "#!/bin/sh\n# Drops `-p <profile>` and runs the command unsandboxed.\nshift 2\nexec \"$@\"\n")
File.chmod!(fake_sandbox_exec, 0o755)

Application.put_env(:symphony_elixir, :verification_dev_server_sandbox,
  os_type: {:unix, :darwin},
  executable: fake_sandbox_exec,
  check_confinement: false
)

with true <- File.exists?("/usr/bin/sandbox-exec"),
     {_output, 0} <- System.cmd("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)", "/usr/bin/true"], stderr_to_stdout: true) do
  :ok
else
  _unavailable -> ExUnit.configure(exclude: [:seatbelt | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# The `:bwrap` tests run the Linux sandbox for real, where bwrap can make its namespaces.
with bwrap when is_binary(bwrap) <- System.find_executable("bwrap"),
     socat when is_binary(socat) <- System.find_executable("socat"),
     {_output, 0} <-
       System.cmd(bwrap, ~w(--die-with-parent --unshare-all --ro-bind / / --dev /dev --proc /proc /bin/sh -c :), stderr_to_stdout: true) do
  :ok
else
  _unavailable -> ExUnit.configure(exclude: [:bwrap | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# The `:unix_socket` tests listen on a unix socket in the temp folder, as a verification dev
# server does on macOS. The agent sandbox refuses that bind, so they run in CI.
unix_socket_probe = Path.join(System.tmp_dir!(), "unix-socket-probe-#{System.pid()}.sock")

case :gen_tcp.listen(0, ip: {:local, unix_socket_probe}) do
  {:ok, socket} ->
    :gen_tcp.close(socket)
    File.rm(unix_socket_probe)

  {:error, _reason} ->
    ExUnit.configure(exclude: [:unix_socket | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# The qa-dashboard end-to-end test fetches deps and builds this checkout; it runs only on
# `mix test --include qa_dashboard_e2e`.
ExUnit.configure(exclude: [:qa_dashboard_e2e | Keyword.get(ExUnit.configuration(), :exclude, [])])

# Tests never reach openrouter.ai: a test that needs the models API stubs this itself.
offline_models_request = fn _url, _opts -> {:error, :network_disabled_in_tests} end
Application.put_env(:symphony_elixir, :openrouter_models_request, offline_models_request)

# QA passes in tests find no leftover processes; a test that needs the real
# process table passes `:table` itself.
Application.put_env(:symphony_elixir, :leftover_process_table, fn -> {:ok, []} end)

# Tests that stop real detached processes need `ps`, which sandboxed agent runs
# (macOS Seatbelt) deny.
case SymphonyElixir.LeftoverProcesses.Table.read() do
  {:ok, [_ | _]} -> :ok
  _denied -> ExUnit.configure(exclude: [:process_table | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# Tests that start the real `claude` binary run only with `--only real_claude`, so no default run
# (CI's, `mix cover.changed`'s) depends on whether or which `claude` is installed.
ExUnit.configure(exclude: [:real_claude | Keyword.get(ExUnit.configuration(), :exclude, [])])

# The test that checks the dev server's record of the agent profiles' mach services against an SRT
# install runs only with `--only srt_profile`; the `agent-profile` workflow runs it.
ExUnit.configure(exclude: [:srt_profile | Keyword.get(ExUnit.configuration(), :exclude, [])])

# Tests that measure an agent's niceness need `setpriority`, which sandboxed
# agent runs deny; `nice` then warns and runs the command unchanged.
case System.cmd("nice", ["-n", "1", "true"], stderr_to_stdout: true) do
  {"", 0} -> :ok
  _denied -> ExUnit.configure(exclude: [:setpriority | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# Sandboxed agent runs (Claude Code, SRT) deny writes to `/tmp` itself but
# expose a writable TMPDIR such as `/tmp/claude-501`, or a run's own
# `/tmp/symphony-run-<hash>/claude-501`. Keep MCP socket dirs there when it is
# short, so `<root>/symphony-mcp-<id>/sock` still fits the 104-byte Unix
# `sun_path` limit; use `/tmp` when TMPDIR is long (macOS `/var/folders/...`)
# and `/tmp` is writable, else TMPDIR, where sessions name their socket dir
# after a short hash. An explicit `SYMPHONY_MCP_SOCKET_ROOT` still wins.
mcp_test_socket_root =
  case System.tmp_dir!() |> String.trim_trailing("/") do
    short when byte_size(short) <= 32 ->
      short

    long ->
      probe = Path.join("/tmp", "symphony-mcp-probe-#{System.pid()}")

      case File.mkdir(probe) do
        :ok ->
          File.rmdir(probe)
          "/tmp"

        {:error, _reason} ->
          long
      end
  end

Application.put_env(:symphony_elixir, :mcp_socket_root, mcp_test_socket_root)

# Clean up at VM exit, not in `ExUnit.after_suite/1`: with
# `mix test --repeat-until-failure` the after-suite callbacks run after every
# repetition, and deleting the run store under a live Mnesia breaks the next one.
System.at_exit(fn _status ->
  File.rm_rf(audit_dir)
  File.rm_rf(state_root)
  File.rm_rf(logs_root)
  File.rm_rf(run_store_dir)
  File.rm_rf(agent_cache_dir)
  File.rm_rf(agent_run_tmp_root)
end)
