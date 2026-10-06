defmodule SymphonyElixir.AuditLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AuditLog

  @linear_secret "linear-secret-123456"
  @gh_secret "gho-secret-123456"
  @github_secret "ghp-secret-123456"

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-log-#{System.unique_integer([:positive])}"
      )

    audit_dir = Path.join(test_root, "audit")
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)

    System.put_env("LINEAR_API_KEY", @linear_secret)
    System.put_env("GH_TOKEN", @gh_secret)
    System.put_env("GITHUB_TOKEN", @github_secret)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_app_env(:audit_log_dir, previous_audit_dir)
      File.rm_rf(test_root)
    end)

    {:ok, audit_dir: audit_dir}
  end

  test "writes append-only redacted NDJSON and lists by issue/date", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]
    issue = %Issue{id: "issue-1", identifier: "ACME-1"}
    prompt = "Handle this issue with #{@linear_secret} but do not leak it."

    assert :ok =
             AuditLog.record_prompt_sent(issue, "run-1", prompt,
               timestamp: timestamp,
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-2",
                 run_id: "run-2",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 args: %{"api_key" => @linear_secret}
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)
    lines = String.split(contents, "\n", trim: true)

    assert length(lines) == 2
    refute contents =~ @linear_secret
    assert Enum.all?(Enum.map(lines, &Jason.decode!/1), &(&1["repo_key"] == "default"))

    assert {:ok, [%{"event_type" => "prompt_sent"} = event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert event["repo_key"] == "default"
    assert event["run_id"] == "run-1"
    assert event["prompt_preview"] =~ "[REDACTED]"
    assert String.length(event["prompt_hash"]) == 64
    refute Map.has_key?(event, "prompt")
    assert is_binary(event["record_hash"])
    assert {:ok, 2} = AuditLog.verify_file(path)
  end

  test "redacts common GitHub token env values from command output", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 result: %{
                   "output" => "GH_TOKEN=#{@gh_secret}\nGITHUB_TOKEN=#{@github_secret}"
                 }
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)

    refute contents =~ @gh_secret
    refute contents =~ @github_secret
    assert contents =~ "[REDACTED]"
  end

  test "keeps GH_TOKEN canary literal unredacted when no value is present in output", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 command: "printf '%s\\n' '$GH_TOKEN'",
                 result: %{"output" => "$GH_TOKEN\n"}
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)

    assert contents =~ "$GH_TOKEN"
    refute contents =~ "GH_TOKEN=[REDACTED]"
  end

  test "lists events chronologically across date ranges", %{audit_dir: audit_dir} do
    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-08 10:00:00Z],
                 event_type: "tool_call",
                 sequence: "second"
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-07 09:00:00Z],
                 event_type: "tool_call",
                 sequence: "first"
               },
               dir: audit_dir
             )

    assert {:ok, events} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-08], dir: audit_dir)

    assert Enum.map(events, & &1["sequence"]) == ["first", "second"]
  end

  test "queries filtered redacted events as a stream", %{audit_dir: audit_dir} do
    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-1",
                 issue_identifier: "ACME-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-07 09:00:00Z],
                 event_type: "tool_call",
                 args: %{"api_key" => @linear_secret}
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "other",
                 issue_id: "issue-2",
                 issue_identifier: "ACME-2",
                 run_id: "run-2",
                 timestamp: ~U[2026-05-07 10:00:00Z],
                 event_type: "file_change",
                 paths: ["lib/example.ex"]
               },
               dir: audit_dir
             )

    assert {:ok, stream} =
             AuditLog.query(%{
               "issue" => "ACME-1",
               "repo" => "default",
               "type" => "tool_call",
               "from" => "2026-05-07",
               "to" => "2026-05-07",
               "dir" => audit_dir
             })

    assert [%{"issue_id" => "issue-1", "args" => %{"api_key" => "[REDACTED]"}}] = Enum.to_list(stream)
  end

  test "query supports date and record-hash cursor pagination", %{audit_dir: audit_dir} do
    for sequence <- 1..3 do
      assert :ok =
               AuditLog.record(
                 %{
                   issue_id: "issue-1",
                   timestamp: ~U[2026-05-07 09:00:00Z],
                   event_type: "tool_call",
                   sequence: sequence
                 },
                 dir: audit_dir
               )
    end

    assert {:ok, first_page} =
             AuditLog.query(issue_id: "issue-1", from: "2026-05-07", to: "2026-05-07", limit: 2, dir: audit_dir)

    [first, second] = Enum.to_list(first_page)
    cursor = "#{second["date"]}:#{second["record_hash"]}"

    assert {:ok, second_page} =
             AuditLog.query(issue_id: "issue-1", from: "2026-05-07", to: "2026-05-07", cursor: cursor, dir: audit_dir)

    assert [%{"sequence" => 3}] = Enum.to_list(second_page)
    assert first["sequence"] == 1
  end

  test "records refused agent actions", %{audit_dir: audit_dir} do
    issue = %Issue{id: "issue-refused", identifier: "ACME-3010"}

    assert :ok =
             AuditLog.record_refused_agent_action(
               issue,
               %{
                 action: "git_push",
                 reason: "git_remote_not_allowed",
                 command: "git push git@github.com:attacker/x.git HEAD",
                 details: %{target: "git@github.com:attacker/x.git"}
               },
               timestamp: ~U[2026-05-13 07:00:00Z],
               dir: audit_dir,
               repo_key: "default"
             )

    assert {:ok, [%{"event_type" => "refused_agent_action"} = event]} =
             AuditLog.list_events("issue-refused", ~D[2026-05-13], ~D[2026-05-13], dir: audit_dir)

    assert event["issue_identifier"] == "ACME-3010"
    assert event["repo_key"] == "default"
    assert event["action"] == "git_push"
    assert event["reason"] == "git_remote_not_allowed"
    assert event["details"] == %{"target" => "git@github.com:attacker/x.git"}
  end

  test "verify_file detects edited records", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "tool_call"},
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "file_change"},
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    tampered = path |> File.read!() |> String.replace("tool_call", "tool_call_edited", global: false)
    File.write!(path, tampered)

    assert {:error, {:hash_mismatch, 1}} = AuditLog.verify_file(path)
  end

  test "verify_chain returns ok for a clean day and break record after tamper", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "tool_call"},
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "file_change"},
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    [first_line, second_line] = path |> File.read!() |> String.split("\n", trim: true)
    second = Jason.decode!(second_line)
    second_record_hash = second["record_hash"]

    assert :ok = AuditLog.verify_chain(~D[2026-05-07], dir: audit_dir)

    tampered_second =
      second
      |> Map.put("previous_hash", "tampered")
      |> Jason.encode!()

    File.write!(path, Enum.join([first_line, tampered_second], "\n") <> "\n")

    assert {:error, {:chain_break, %{line: 2, record_hash: ^second_record_hash}}} =
             AuditLog.verify_chain("2026-05-07", dir: audit_dir)
  end

  test "chains a record to the last hashed record from the end of the day's file", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-08 12:00:00Z]
    path = Path.join(audit_dir, "2026-05-08.ndjson")
    event = fn type -> %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: type} end
    last_line = fn -> path |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode!() end

    # A day whose file is empty, or holds no hashed record, starts the chain.
    File.mkdir_p!(audit_dir)
    File.write!(path, "")
    assert :ok = AuditLog.record(event.("tool_call"), dir: audit_dir)
    refute Map.has_key?(last_line.(), "previous_hash")

    File.write!(path, "not json\n")
    assert :ok = AuditLog.record(event.("tool_call"), dir: audit_dir)
    first = last_line.()
    refute Map.has_key?(first, "previous_hash")

    assert :ok = AuditLog.record(event.("file_change"), dir: audit_dir)
    second = last_line.()
    assert second["previous_hash"] == first["record_hash"]

    # Unhashed lines after the last record, one of them longer than a read chunk, are skipped back over.
    File.write!(path, ~s({"no_hash":true}\n) <> String.duplicate("x", 150_000) <> "\n\n", [:append])
    assert :ok = AuditLog.record(event.("token_usage_delta"), dir: audit_dir)
    assert last_line.()["previous_hash"] == second["record_hash"]
  end

  test "verify_chain reports invalid_date for non-parseable input", %{audit_dir: audit_dir} do
    assert {:error, :invalid_date} = AuditLog.verify_chain("not-a-date", dir: audit_dir)
  end

  test "verify_chain returns ok when the daily file does not exist", %{audit_dir: audit_dir} do
    assert :ok = AuditLog.verify_chain(~D[2099-01-01], dir: audit_dir)
  end

  test "query/1 rejects malformed cursors", %{audit_dir: audit_dir} do
    assert {:error, :invalid_cursor} =
             AuditLog.query(cursor: "bad", from: "2026-05-07", to: "2026-05-07", dir: audit_dir)

    assert {:error, :invalid_cursor} =
             AuditLog.query(cursor: 42, from: "2026-05-07", to: "2026-05-07", dir: audit_dir)
  end

  test "query/1 rejects malformed since timestamps", %{audit_dir: audit_dir} do
    assert {:error, :invalid_since} =
             AuditLog.query(since: "not-a-timestamp", from: "2026-05-07", to: "2026-05-07", dir: audit_dir)
  end

  test "query/1 cursor positioning is preserved when filters change", %{audit_dir: audit_dir} do
    for sequence <- 1..3 do
      assert :ok =
               AuditLog.record(
                 %{
                   issue_id: "issue-1",
                   repo_key: "default",
                   timestamp: ~U[2026-05-07 09:00:00Z],
                   event_type: "tool_call",
                   sequence: sequence
                 },
                 dir: audit_dir
               )
    end

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-2",
                 repo_key: "other",
                 timestamp: ~U[2026-05-07 09:00:00Z],
                 event_type: "tool_call",
                 sequence: 99
               },
               dir: audit_dir
             )

    {:ok, page} = AuditLog.query(from: "2026-05-07", to: "2026-05-07", limit: 2, dir: audit_dir)
    [_first, second] = Enum.to_list(page)
    cursor = "#{second["date"]}:#{second["record_hash"]}"

    # Reuse the cursor with a tighter filter that excludes the cursor record's repo.
    {:ok, next_page} =
      AuditLog.query(
        from: "2026-05-07",
        to: "2026-05-07",
        cursor: cursor,
        repo: "other",
        dir: audit_dir
      )

    assert [%{"sequence" => 99, "repo_key" => "other"}] = Enum.to_list(next_page)
  end

  test "records tool, Linear, file-change, PR, and token side-effect events", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]
    issue = %Issue{id: "issue-1", identifier: "ACME-1"}
    running_entry = %{issue: issue, run_id: "run-1", session_id: "thread-1-turn-1"}

    assert :ok =
             AuditLog.record_agent_update(
               running_entry,
               %{
                 event: :tool_call_completed,
                 timestamp: timestamp,
                 payload: %{
                   "method" => "item/tool/call",
                   "params" => %{
                     "tool" => "linear_graphql",
                     "arguments" => %{
                       "query" => "mutation CreateComment { commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id url } } }",
                       "variables" => %{"issueId" => "linear-issue-1"}
                     }
                   }
                 },
                 result: %{
                   "success" => true,
                   "output" =>
                     Jason.encode!(%{
                       "data" => %{
                         "commentCreate" => %{
                           "comment" => %{"id" => "comment-1", "url" => "https://linear.test/comment-1"}
                         }
                       }
                     })
                 }
               },
               %{
                 input_tokens: 3,
                 output_tokens: 2,
                 total_tokens: 5,
                 input_reported: 3,
                 output_reported: 2,
                 total_reported: 5
               }
             )

    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@
    -old
    +new
    """

    assert :ok =
             AuditLog.record_agent_update(
               running_entry,
               %{
                 event: :notification,
                 timestamp: DateTime.add(timestamp, 1, :second),
                 payload: %{"method" => "turn/diff/updated", "params" => %{"diff" => diff}}
               },
               %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
             )

    assert :ok =
             AuditLog.record_pr_opened(Map.put(running_entry, :pull_request_url, nil), "https://github.com/acme/repo/pull/42",
               timestamp: DateTime.add(timestamp, 2, :second),
               dir: audit_dir
             )

    assert {:ok, events} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert Enum.map(events, & &1["event_type"]) == [
             "tool_call",
             "linear_comment",
             "token_usage_delta",
             "file_change",
             "pr_opened"
           ]

    assert Enum.all?(events, &(&1["repo_key"] == "default"))
    assert Enum.find(events, &(&1["event_type"] == "linear_comment"))["comment_id"] == "comment-1"
    assert Enum.find(events, &(&1["event_type"] == "token_usage_delta"))["token_usage_delta"]["total_tokens"] == 5

    file_change = Enum.find(events, &(&1["event_type"] == "file_change"))
    assert file_change["paths"] == ["lib/example.ex"]
    assert file_change["diff_stats"] == %{"additions" => 1, "deletions" => 1, "files_changed" => 1}

    pr_opened = Enum.find(events, &(&1["event_type"] == "pr_opened"))

    assert pr_opened["pr"] == %{
             "number" => 42,
             "repo" => "acme/repo",
             "url" => "https://github.com/acme/repo/pull/42"
           }
  end

  test "records observed Linear state transitions", %{audit_dir: audit_dir} do
    previous = %Issue{id: "issue-1", identifier: "ACME-1", state: "In Progress"}
    refreshed = %Issue{id: "issue-1", identifier: "ACME-1", state: "In Review"}

    assert :ok =
             AuditLog.record_linear_state_transition(previous, refreshed, "run-1",
               timestamp: ~U[2026-05-07 12:00:00Z],
               dir: audit_dir
             )

    assert {:ok, [event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert event["event_type"] == "linear_state_change"
    assert event["from_state"] == "In Progress"
    assert event["to_state"] == "In Review"
  end

  describe "redact_for_log/2" do
    test "renders exception structs without raising" do
      error = %Req.TransportError{reason: :timeout}

      result = AuditLog.redact_for_log(error)

      assert is_binary(result)
      assert result =~ "Req.TransportError"
      assert result =~ "timeout"
    end

    test "redacts secrets nested inside struct fields" do
      error = %RuntimeError{message: "boom with #{@linear_secret} inside"}

      result = AuditLog.redact_for_log(error)

      refute result =~ @linear_secret
      assert result =~ "[REDACTED]"
      assert result =~ "RuntimeError"
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
