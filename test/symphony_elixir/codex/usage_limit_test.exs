defmodule SymphonyElixir.Codex.UsageLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.UsageLimit, as: CodexUsageLimit

  @fixtures Path.expand("../../fixtures/codex_usage_limit", __DIR__)
  @five_hour_reset ~U[2026-10-03 16:00:00Z]
  @weekly_reset ~U[2026-10-09 00:00:00Z]
  @limit_error %{"message" => "You've hit your usage limit.", "codexErrorInfo" => "usageLimitExceeded"}

  defp fixture_lines(name), do: @fixtures |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)

  # Feeds the lines through the parser as the app-server does: remember each snapshot,
  # then classify the line with the windows seen so far.
  defp classify(name) do
    name
    |> fixture_lines()
    |> Enum.map_reduce(nil, fn line, snapshot ->
      payload = Jason.decode!(line)
      snapshot = CodexUsageLimit.remember(snapshot, payload)
      {CodexUsageLimit.usage_limited(payload, snapshot), snapshot}
    end)
  end

  describe "fixture lines" do
    test "a used-up five-hour window stops the turn on the error notification and the failed turn" do
      {[:error, error_result, completed_result], snapshot} = classify("five_hour_limit.jsonl")

      assert {:ok, info} = error_result
      assert completed_result == error_result

      assert info == %{
               provider: "openai",
               window: "primary",
               scope: :all,
               resets_at: @five_hour_reset,
               utilization: 1.0,
               overage: nil,
               source: :codex_error
             }

      assert snapshot == %{
               "primary" => %{used_percent: 100, resets_at: @five_hour_reset},
               "secondary" => %{used_percent: 63, resets_at: @weekly_reset}
             }
    end

    test "a used-up weekly window from the legacy token_count and error events" do
      assert {[:error, {:ok, info}], _snapshot} = classify("weekly_limit_legacy.jsonl")
      assert %{provider: "openai", window: "secondary", scope: :all, resets_at: @weekly_reset, utilization: 1.0} = info
    end

    test "a 429 throttle, retried or not, is not a usage limit" do
      assert {[:error, :error, :error, :error], %{"primary" => %{used_percent: 87}}} = classify("throttle.jsonl")
    end
  end

  test "with no used-up window the reset time is unknown, and with both the later reset wins" do
    error = %{"method" => "error", "params" => %{"willRetry" => false, "error" => @limit_error}}

    assert {:ok, %{window: nil, resets_at: nil, utilization: nil}} = CodexUsageLimit.usage_limited(error, nil)

    both = %{
      "primary" => %{used_percent: 100, resets_at: @five_hour_reset},
      "secondary" => %{used_percent: 100.0, resets_at: @weekly_reset}
    }

    assert {:ok, %{window: "secondary", resets_at: @weekly_reset}} = CodexUsageLimit.usage_limited(error, both)

    no_reset = %{"primary" => %{used_percent: 100, resets_at: nil}}
    assert {:ok, %{window: "primary", resets_at: nil, utilization: 1.0}} = CodexUsageLimit.usage_limited(error, no_reset)
  end

  test "only turn-ending methods with a limit error are usage limits" do
    turn_failed = %{"method" => "turn/failed", "params" => %{"turn" => %{"status" => "failed", "error" => @limit_error}}}
    keyed_info = %{"method" => "error", "params" => %{"error" => %{"codexErrorInfo" => %{"usageLimitExceeded" => %{}}}}}

    assert {:ok, %{provider: "openai"}} = CodexUsageLimit.usage_limited(turn_failed, nil)
    assert {:ok, %{provider: "openai"}} = CodexUsageLimit.usage_limited(keyed_info, nil)

    assert :error = CodexUsageLimit.usage_limited(%{"method" => "item/completed", "params" => %{"error" => @limit_error}}, nil)
    assert :error = CodexUsageLimit.usage_limited(%{"method" => "error", "params" => %{"willRetry" => true, "error" => @limit_error}}, nil)
    assert :error = CodexUsageLimit.usage_limited(%{"method" => "error", "params" => %{"error" => "usage"}}, nil)
    assert :error = CodexUsageLimit.usage_limited(%{"method" => "error", "params" => %{"error" => %{"codexErrorInfo" => 7}}}, nil)
    assert :error = CodexUsageLimit.usage_limited(%{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}}, nil)
  end

  describe "api_unreachable/1" do
    defp unreachable(method \\ "error", error), do: CodexUsageLimit.api_unreachable(%{"method" => method, "params" => %{"error" => error}})

    test "a DNS failure Codex gave up retrying ends the turn on the error notification and the failed turn" do
      [retried, gave_up, completed] = Enum.map(fixture_lines("api_unreachable.jsonl"), &Jason.decode!/1)

      assert CodexUsageLimit.api_unreachable(retried) == :error
      assert {:ok, info} = CodexUsageLimit.api_unreachable(gave_up)
      assert CodexUsageLimit.api_unreachable(completed) == {:ok, info}

      assert info == %{
               provider: "openai",
               window: nil,
               scope: :all,
               resets_at: nil,
               utilization: nil,
               source: :api_unreachable,
               error: "ENOTFOUND"
             }

      # Neither is a usage limit.
      assert CodexUsageLimit.usage_limited(gave_up, nil) == :error
    end

    test "names the transport error, from an error code or the message" do
      legacy = %{"method" => "codex/event/error", "params" => %{"msg" => %{"type" => "error", "message" => "tcp connect error: Connection refused (os error 61)"}}}
      assert {:ok, %{error: "ECONNREFUSED"}} = CodexUsageLimit.api_unreachable(legacy)

      assert {:ok, %{error: "ETIMEDOUT"}} = unreachable("turn/failed", %{"message" => "request failed (ETIMEDOUT)"})
      assert {:ok, %{error: "ETIMEDOUT"}} = unreachable(%{"message" => "error sending request for url (x): operation timed out"})
      assert {:ok, %{error: "ECONNRESET"}} = unreachable(%{"message" => "error sending request: connection reset by peer"})
      assert {:ok, %{error: "ENETUNREACH"}} = unreachable(%{"message" => "Network is unreachable (os error 51)"})
      assert {:ok, %{error: "connection error"}} = unreachable(%{"message" => "error sending request for url (x)"})
      assert {:ok, %{error: "connection error"}} = unreachable(%{"codexErrorInfo" => "responseStreamConnectionFailed"})
    end

    test "an error the API answered, one Codex retries, or any other error is reachable" do
      assert "throttle.jsonl" |> fixture_lines() |> Enum.map(&CodexUsageLimit.api_unreachable(Jason.decode!(&1))) == [:error, :error, :error, :error]

      assert :error = unreachable(%{"message" => "connection reset", "codexErrorInfo" => %{"responseStreamConnectionFailed" => %{"httpStatusCode" => 502}}})
      assert :error = unreachable(%{"message" => "Internal server error", "codexErrorInfo" => "internalServerError"})
      assert :error = unreachable(%{"message" => "boom", "codexErrorInfo" => %{"other" => "x"}})
      assert :error = unreachable(%{"codexErrorInfo" => 7})
      assert :error = unreachable(@limit_error)
      assert :error = unreachable("item/completed", %{"message" => "dns error"})
      assert :error = CodexUsageLimit.api_unreachable(%{"method" => "error", "params" => %{"willRetry" => true, "error" => %{"message" => "dns error"}}})
      assert :error = CodexUsageLimit.api_unreachable(%{"method" => "error", "params" => %{"error" => "dns error"}})
      assert :error = CodexUsageLimit.api_unreachable(%{"method" => "turn/completed"})
    end
  end

  test "rate_limits reads both shapes and ignores payloads without windows" do
    assert CodexUsageLimit.rate_limits(%{"params" => %{"rateLimits" => %{"primary" => %{"usedPercent" => 5}}}}) ==
             %{"primary" => %{used_percent: 5, resets_at: nil}}

    # An out-of-range or non-positive reset is unknown.
    assert CodexUsageLimit.rate_limits(%{"params" => %{"msg" => %{"rate_limits" => %{"secondary" => %{"resets_at" => 99_999_999_999_999}}}}}) ==
             %{"secondary" => %{used_percent: nil, resets_at: nil}}

    assert CodexUsageLimit.rate_limits(%{"params" => %{"rateLimits" => %{"primary" => %{"resetsAt" => 0}}}}) ==
             %{"primary" => %{used_percent: nil, resets_at: nil}}

    assert CodexUsageLimit.rate_limits(%{"params" => %{"rateLimits" => %{"primary" => nil, "credits" => nil}}}) == nil
    assert CodexUsageLimit.rate_limits(%{"params" => %{"rateLimits" => "n/a"}}) == nil
    assert CodexUsageLimit.rate_limits(%{"method" => "turn/started"}) == nil

    snapshot = %{"secondary" => %{used_percent: 99, resets_at: nil}}
    assert CodexUsageLimit.remember(snapshot, %{"method" => "turn/started"}) == snapshot
  end

  describe "Codex app-server" do
    setup do
      test_root = Path.join(System.tmp_dir!(), "symphony-codex-usage-limit-#{System.unique_integer([:positive])}")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX-LIMIT")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(test_root) end)

      issue = %Issue{
        id: "issue-codex-limit",
        identifier: "MT-CODEX-LIMIT",
        title: "Codex usage limit",
        description: "Stop on the Codex usage limit",
        state: "In Progress",
        url: "https://example.org/issues/MT-CODEX-LIMIT",
        labels: []
      }

      %{test_root: test_root, workspace_root: workspace_root, workspace: workspace, issue: issue}
    end

    # A fake Codex that answers the handshake and then prints the turn's event lines.
    defp fake_codex!(ctx, lines) do
      events = Path.join(ctx.test_root, "events-#{System.unique_integer([:positive])}.jsonl")
      File.write!(events, Enum.join(lines, "\n") <> "\n")
      codex_binary = Path.join(ctx.test_root, "fake-codex")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thr_usage"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn_usage","status":"inProgress","items":[]}}}'
            cat '#{events}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.workspace_root, agent_command: "#{codex_binary} app-server")
    end

    defp run_turn(ctx) do
      parent = self()
      AppServer.run(ctx.workspace, "Hit the limit", ctx.issue, on_message: &send(parent, {:codex_message, &1}))
    end

    test "the error notification ends the turn with the usage limit", ctx do
      fake_codex!(ctx, fixture_lines("five_hour_limit.jsonl"))

      assert {:error, {:usage_limited, %{provider: "openai", window: "primary", resets_at: @five_hour_reset}}} = run_turn(ctx)
      assert_received {:codex_message, %{event: :usage_limited, usage_limit: %{provider: "openai"}}}
    end

    test "a failed turn/completed or turn/failed ends the turn with the usage limit", ctx do
      [_rate_limits, _error, completed] = fixture_lines("five_hour_limit.jsonl")
      fake_codex!(ctx, [completed])

      assert {:error, {:usage_limited, %{provider: "openai", window: nil, resets_at: nil}}} = run_turn(ctx)

      failed = String.replace(completed, ~s("method":"turn/completed"), ~s("method":"turn/failed"))
      fake_codex!(ctx, [failed])

      assert {:error, {:usage_limited, %{provider: "openai"}}} = run_turn(ctx)
    end

    test "a turn that can't reach the model API fails as an unreachable API, on any turn-ending line", ctx do
      fake_codex!(ctx, fixture_lines("api_unreachable.jsonl"))

      assert {:error, {:model_api_unreachable, %{provider: "openai", source: :api_unreachable, error: "ENOTFOUND"}}} = run_turn(ctx)
      assert_received {:codex_message, %{event: :model_api_unreachable, usage_limit: %{error: "ENOTFOUND"}}}
      refute_received {:codex_message, %{event: :turn_completed}}

      [_retried, _gave_up, completed] = fixture_lines("api_unreachable.jsonl")
      fake_codex!(ctx, [completed])

      assert {:error, {:model_api_unreachable, %{error: "ENOTFOUND"}}} = run_turn(ctx)

      fake_codex!(ctx, [String.replace(completed, ~s("method":"turn/completed"), ~s("method":"turn/failed"))])

      assert {:error, {:model_api_unreachable, %{error: "ENOTFOUND"}}} = run_turn(ctx)
    end

    test "a turn that fails for another reason keeps today's handling", ctx do
      failed_turn = fn method ->
        Jason.encode!(%{
          "method" => method,
          "params" => %{"turn" => %{"id" => "turn_usage", "status" => "failed", "error" => %{"message" => "Internal server error", "codexErrorInfo" => "internalServerError"}}}
        })
      end

      fake_codex!(ctx, [failed_turn.("turn/completed")])
      assert {:ok, %{result: :turn_completed}} = run_turn(ctx)

      fake_codex!(ctx, [failed_turn.("turn/failed")])
      assert {:error, {:turn_failed, %{"turn" => %{"status" => "failed"}}}} = run_turn(ctx)
      refute_received {:codex_message, %{event: :model_api_unreachable}}
    end

    test "a 429 throttle keeps today's failure handling", ctx do
      [rate_limits, retried, _gave_up, completed] = fixture_lines("throttle.jsonl")
      failed = String.replace(completed, ~s("method":"turn/completed"), ~s("method":"turn/failed"))
      fake_codex!(ctx, [rate_limits, retried, failed])

      assert {:error, {:turn_failed, %{"turn" => %{"status" => "failed"}}}} = run_turn(ctx)
      assert_received {:codex_message, %{event: :notification}}
      refute_received {:codex_message, %{event: :usage_limited}}
    end
  end
end
