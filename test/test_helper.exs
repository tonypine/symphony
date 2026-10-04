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
Application.put_env(:symphony_elixir, :state_root, state_root)
Application.put_env(:symphony_elixir, :logs_root, logs_root)
Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

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

# Tests that measure an agent's niceness need `setpriority`, which sandboxed
# agent runs deny; `nice` then warns and runs the command unchanged.
case System.cmd("nice", ["-n", "1", "true"], stderr_to_stdout: true) do
  {"", 0} -> :ok
  _denied -> ExUnit.configure(exclude: [:setpriority | Keyword.get(ExUnit.configuration(), :exclude, [])])
end

# Sandboxed agent runs (Claude Code, SRT) deny writes to `/tmp` itself but
# expose a short writable TMPDIR such as `/tmp/claude-501`. Keep MCP socket
# dirs there so `<root>/symphony-mcp-<id>/sock` still fits the 104-byte Unix
# `sun_path` limit; fall back to `/tmp` when TMPDIR is long (macOS
# `/var/folders/...`). An explicit `SYMPHONY_MCP_SOCKET_ROOT` still wins.
mcp_test_socket_root =
  case System.tmp_dir!() |> String.trim_trailing("/") do
    short when byte_size(short) <= 32 -> short
    _long -> "/tmp"
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
end)
