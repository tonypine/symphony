defmodule SymphonyElixir.LinearRateLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.RateLimit
  alias SymphonyElixir.StatusDashboard.Renderer

  @now_ms 1_790_000_000_000
  @query "query Viewer { viewer { id } }"
  @empty_codex_totals %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
  @rate_limited_body %{
    "errors" => [
      %{"message" => "Rate limit exceeded", "extensions" => %{"code" => "RATELIMITED"}}
    ]
  }

  setup do
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_endpoint: "http://127.0.0.1:9/graphql"
    )

    :ok
  end

  describe "Linear.Client.graphql/3 under a RATELIMITED response" do
    test "pauses every Linear call until the reset time, then resumes" do
      {:ok, clock} = Agent.start_link(fn -> @now_ms end)
      now_ms_fun = fn -> Agent.get(clock, & &1) end
      reset_ms = @now_ms + 120_000
      parent = self()

      request_fun = fn _payload, _headers ->
        send(parent, :linear_request)

        case Process.get(:linear_response) do
          :rate_limited ->
            {:ok,
             %{
               status: 400,
               headers: %{
                 "x-ratelimit-requests-remaining" => ["0"],
                 "x-ratelimit-requests-limit" => ["2500"],
                 "x-ratelimit-requests-reset" => [Integer.to_string(reset_ms)]
               },
               body: @rate_limited_body
             }}

          :ok ->
            {:ok, %{status: 200, headers: %{"x-ratelimit-requests-remaining" => ["2499"]}, body: %{"data" => %{}}}}
        end
      end

      call = fn -> Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: now_ms_fun) end

      Process.put(:linear_response, :rate_limited)

      log =
        capture_log(fn ->
          assert {:error, {:linear_rate_limited, ^reset_ms}} = call.()
        end)

      assert log =~ "Linear rate limit reached; pausing Linear requests until"
      assert_received :linear_request
      assert RateLimit.requests_total() == 1

      # Linear would answer normally now, but the window has not reset yet:
      # no request may leave until it does.
      Process.put(:linear_response, :ok)

      for offset_ms <- [0, 1_000, 119_999] do
        Agent.update(clock, fn _ -> @now_ms + offset_ms end)
        assert {:error, {:linear_rate_limited, ^reset_ms}} = call.()
      end

      refute_received :linear_request
      assert RateLimit.requests_total() == 1
      assert %{paused_until_ms: ^reset_ms, requests_remaining: 0, requests_limit: 2500} = RateLimit.status(@now_ms)

      Agent.update(clock, fn _ -> reset_ms end)

      assert {:ok, %{"data" => %{}}} = call.()
      assert_received :linear_request
      assert RateLimit.requests_total() == 2
      assert %{paused_until_ms: nil, requests_remaining: 2499} = RateLimit.status(reset_ms)
    end

    test "treats HTTP 429 as a rate limit and accepts list-style headers" do
      reset_ms = @now_ms + 5_000

      request_fun = fn _payload, _headers ->
        {:ok, %{status: 429, headers: [{"X-RateLimit-Requests-Reset", Integer.to_string(reset_ms)}], body: "slow down"}}
      end

      capture_log(fn ->
        assert {:error, {:linear_rate_limited, ^reset_ms}} =
                 Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: fn -> @now_ms end)
      end)

      assert RateLimit.paused_until(@now_ms) == reset_ms
      assert RateLimit.remaining_pause_ms(@now_ms) == 5_000
      assert RateLimit.remaining_pause_ms(reset_ms) == 0
    end

    test "keeps non-rate-limit errors as ordinary Linear API failures" do
      body = %{"errors" => [%{"message" => "nope", "extensions" => %{"code" => "BAD_USER_INPUT"}}, "odd"]}

      request_fun = fn _payload, _headers -> {:ok, %{status: 400, body: body}} end

      capture_log(fn ->
        assert {:error, {:linear_api_status, 400, ^body}} = Client.graphql(@query, %{}, request_fun: request_fun)
      end)

      assert RateLimit.paused_until() == nil
      assert RateLimit.check(RateLimit.now_ms()) == :ok
    end
  end

  describe "RateLimit.record_response/2 reset selection" do
    test "falls back to a one minute pause without reset headers" do
      assert {:rate_limited, reset_ms} = RateLimit.record_response(%{status: 400, body: @rate_limited_body}, @now_ms)
      assert reset_ms == @now_ms + 60_000
    end

    test "ignores unparseable and past reset headers" do
      headers = %{
        "x-ratelimit-requests-reset" => "soon",
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms - 1)
      }

      assert {:rate_limited, reset_ms} = RateLimit.record_response(%{status: 429, headers: headers}, @now_ms)
      assert reset_ms == @now_ms + 60_000
    end

    test "waits for the spent bucket rather than a later healthy one" do
      headers = %{
        "x-ratelimit-requests-remaining" => "1200",
        "x-ratelimit-requests-reset" => Integer.to_string(@now_ms + 50_000),
        "x-ratelimit-complexity-remaining" => "0",
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms + 10_000)
      }

      response = %{status: 400, headers: headers, body: @rate_limited_body}
      assert {:rate_limited, reset_ms} = RateLimit.record_response(response, @now_ms)
      assert reset_ms == @now_ms + 10_000
    end

    test "waits for the latest reset when no bucket reports as spent, capped at an hour" do
      headers = %{
        "x-ratelimit-requests-reset" => Integer.to_string(@now_ms + 30_000),
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms + 90_000)
      }

      assert {:rate_limited, reset_ms} = RateLimit.record_response(%{status: 429, headers: headers}, @now_ms)
      assert reset_ms == @now_ms + 90_000

      far_headers = %{"x-ratelimit-requests-reset" => Integer.to_string(@now_ms + 10 * 3_600_000)}
      assert {:rate_limited, capped_ms} = RateLimit.record_response(%{status: 429, headers: far_headers}, @now_ms)
      assert capped_ms == @now_ms + 3_600_000
    end

    test "records the remaining budget from successful responses" do
      assert %{requests_remaining: nil, requests_limit: nil} = RateLimit.status()

      assert :ok =
               RateLimit.record_response(
                 %{status: 200, headers: %{"x-ratelimit-requests-remaining" => " 42 ", "x-ratelimit-requests-limit" => "2500"}},
                 @now_ms
               )

      assert :ok = RateLimit.record_response(%{status: 200, headers: nil}, @now_ms)
      assert %{requests_remaining: 42, requests_limit: 2500} = RateLimit.status()
    end
  end

  describe "orchestrator while Linear is rate-limited" do
    test "skips the poll cycle without any Linear call and schedules the next tick at the reset" do
      reset_ms = pause_linear_for(600_000)

      orchestrator_name = Module.concat(__MODULE__, :RateLimitedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: stop_process(pid)
      end)

      requests_before = RateLimit.requests_total()

      snapshot =
        wait_for_snapshot(pid, fn
          %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}} when is_integer(due_in_ms) -> due_in_ms > 60_000
          _ -> false
        end)

      assert %{polling: %{next_poll_in_ms: due_in_ms, linear: linear}} = snapshot
      assert due_in_ms > 500_000
      assert %{paused_until_ms: ^reset_ms, rate_limited_for_ms: pause_ms, requests_last_poll: 0} = linear
      assert pause_ms > 500_000
      assert RateLimit.requests_total() == requests_before

      plain = snapshot |> then(&Renderer.format_snapshot_content({:ok, &1}, 0.0)) |> strip_ansi()
      assert plain =~ ~r/Next refresh: Linear rate-limited; resuming in \d+s \(Linear: 0 req last poll\)/
    end

    test "a rate-limited retry refresh keeps its attempt and waits for the reset" do
      reset_ms = pause_linear_for(300_000)

      issue_id = "issue-rate-limited-retry"
      state = %Orchestrator.State{repo_key: "default", max_concurrent_agents: 1, claimed: MapSet.new([issue_id])}

      capture_log(fn ->
        assert {:noreply, updated_state} =
                 Orchestrator.handle_retry_issue_for_test(state, issue_id, 3, %{identifier: "MT-224"}, fn [^issue_id] ->
                   {:error, {:linear_rate_limited, reset_ms}}
                 end)

        assert %{attempt: 3, due_at_ms: due_at_ms, timer_ref: timer_ref} = updated_state.retry_attempts[issue_id]
        assert due_at_ms - System.monotonic_time(:millisecond) > 250_000
        Process.cancel_timer(timer_ref)
      end)
    end

    test "a rate-limited dispatch refresh is skipped quietly with no Linear call" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "token",
        tracker_endpoint: "http://127.0.0.1:9/graphql",
        max_concurrent_agents: 1,
        quality_gate: %{enabled: false}
      )

      pause_linear_for(300_000)
      requests_before = RateLimit.requests_total()

      issue_id = "issue-rate-limited-dispatch"
      issue = %Issue{id: issue_id, identifier: "MT-225", title: "Dispatch", state: "Todo", assigned_to_worker: true}

      state = %Orchestrator.State{
        repo_key: "default",
        max_concurrent_agents: 1,
        claimed: MapSet.new([issue_id]),
        codex_totals: @empty_codex_totals
      }

      log =
        capture_log(fn ->
          assert {:noreply, %Orchestrator.State{running: running}} =
                   Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{identifier: "MT-225"}, fn [^issue_id] ->
                     {:ok, [issue]}
                   end)

          assert running == %{}
        end)

      refute log =~ "issue refresh failed"
      assert RateLimit.requests_total() == requests_before
    end
  end

  test "agent tools explain the pause and when it ends" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Done"},
        issue: %Issue{id: "issue-current"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_rate_limited, @now_ms}} end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "linear_rate_limited", "message" => message, "reset_at" => reset_at}} =
             Jason.decode!(response["output"])

    assert message =~ "Linear is rate-limiting Symphony"
    assert reset_at == @now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  test "dashboard shows the Linear budget next to the poll countdown" do
    polling = %{
      checking?: false,
      next_poll_in_ms: 4_000,
      poll_interval_ms: 30_000,
      linear: %{rate_limited_for_ms: 0, requests_last_poll: 7, requests_remaining: 2_100, requests_limit: 2_500}
    }

    plain =
      {:ok, %{running: [], retrying: [], codex_totals: @empty_codex_totals, polling: polling}}
      |> Renderer.format_snapshot_content(0.0)
      |> strip_ansi()

    assert plain =~ "Next refresh: 4s (Linear: 7 req last poll, 2100/2500 left this hour)"
  end

  defp pause_linear_for(pause_ms) do
    now_ms = RateLimit.now_ms()
    reset_ms = now_ms + pause_ms
    response = %{status: 429, headers: %{"x-ratelimit-requests-reset" => Integer.to_string(reset_ms)}}
    {:rate_limited, ^reset_ms} = RateLimit.record_response(response, now_ms)
    reset_ms
  end

  defp strip_ansi(content), do: Regex.replace(~r/\e\[[0-9;]*m/, content, "")

  defp wait_for_snapshot(pid, predicate, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_snapshot(pid, predicate, deadline)
  end

  defp do_wait_for_snapshot(pid, predicate, deadline) do
    snapshot = GenServer.call(pid, :snapshot)

    cond do
      predicate.(snapshot) ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("snapshot never matched: #{inspect(snapshot.polling)}")

      true ->
        Process.sleep(10)
        do_wait_for_snapshot(pid, predicate, deadline)
    end
  end
end
