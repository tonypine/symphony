defmodule SymphonyElixir.AuditLog.WriterTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AuditLog.Writer

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-audit-writer-#{System.unique_integer([:positive])}")
    audit_dir = Path.join(test_root, "audit")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)

    on_exit(fn ->
      if previous_audit_dir,
        do: Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir),
        else: Application.delete_env(:symphony_elixir, :audit_log_dir)

      File.rm_rf(test_root)
    end)

    entry = %{
      issue: %{id: "issue-1", identifier: "MT-1"},
      repo_key: "symphony",
      run_id: "run-1",
      session_id: "thread-1",
      transcript_buffer: :queue.from_list([%{event: :notification}])
    }

    {:ok, audit_dir: audit_dir, test_root: test_root, entry: entry}
  end

  defp token_delta do
    %{
      input_tokens: 12,
      uncached_input_tokens: 10,
      cached_input_tokens: 2,
      cache_creation_input_tokens: 0,
      output_tokens: 5,
      total_tokens: 17
    }
  end

  defp update, do: %{event: :notification, timestamp: DateTime.utc_now()}

  defp events(audit_dir) do
    audit_dir
    |> Path.join("#{Date.utc_today()}.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "writes an agent update's events and a pr_opened event in the order they came", %{entry: entry, audit_dir: audit_dir} do
    name = :"audit_writer_#{System.unique_integer([:positive])}"
    writer = start_supervised!({Writer, name: name})

    assert :ok = Writer.record_agent_update(entry, update(), token_delta(), name)
    assert :ok = Writer.record_pr_opened(entry, "https://github.com/acme/repo/pull/42", name)
    :sys.get_state(writer)

    assert [delta, opened] = events(audit_dir)
    assert %{"event_type" => "token_usage_delta", "run_id" => "run-1", "issue_identifier" => "MT-1"} = delta
    assert %{"event_type" => "pr_opened", "url" => "https://github.com/acme/repo/pull/42", "previous_hash" => previous} = opened
    assert previous == delta["record_hash"]
  end

  test "the application's writer records a pr_opened event", %{entry: entry, audit_dir: audit_dir} do
    assert :ok = Writer.record_pr_opened(entry, "https://github.com/acme/repo/pull/7")
    :sys.get_state(Writer)

    assert [%{"event_type" => "pr_opened", "url" => "https://github.com/acme/repo/pull/7"}] = events(audit_dir)
  end

  test "writes in the caller when the writer isn't running", %{entry: entry, audit_dir: audit_dir} do
    assert :ok = Writer.record_agent_update(entry, update(), token_delta(), :"missing_writer_#{System.unique_integer([:positive])}")
    assert [%{"event_type" => "token_usage_delta"}] = events(audit_dir)
  end

  test "logs a write that fails", %{entry: entry, test_root: test_root} do
    blocked_dir = Path.join(test_root, "file")
    File.mkdir_p!(test_root)
    File.write!(blocked_dir, "")
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(blocked_dir, "audit"))
    missing = :"missing_writer_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        assert :ok = Writer.record_agent_update(entry, update(), token_delta(), missing)
        assert :ok = Writer.record_pr_opened(entry, "https://github.com/acme/repo/pull/42", missing)
      end)

    assert log =~ "Audit log failed to record agent update"
    assert log =~ "Audit log failed to record pr_opened"
  end
end
