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
    test "pauses every Linear call for a short backoff, then probes once and resumes" do
      {:ok, clock} = Agent.start_link(fn -> @now_ms end)
      now_ms_fun = fn -> Agent.get(clock, & &1) end
      # Linear's window is a rolling hour: while saturated the reset reads about an hour ahead.
      window_reset_ms = @now_ms + 3_600_000
      probe_at_ms = @now_ms + 60_000

      Process.put(:linear_response, rate_limited_response(window_reset_ms))
      call = linear_call(now_ms_fun)

      log =
        capture_log(fn ->
          assert {:error, {:linear_rate_limited, ^probe_at_ms}} = call.()
        end)

      assert log =~ "Linear rate limit reached; pausing Linear requests until"
      assert_received :linear_request
      assert RateLimit.requests_total() == 1

      # Linear would answer normally now, but the pause has not ended yet:
      # no request may leave until it does.
      Process.put(:linear_response, ok_response("2499"))

      for offset_ms <- [0, 1_000, 59_999] do
        Agent.update(clock, fn _ -> @now_ms + offset_ms end)
        assert {:error, {:linear_rate_limited, ^probe_at_ms}} = call.()
      end

      refute_received :linear_request
      assert RateLimit.requests_total() == 1

      assert %{
               paused_until_ms: ^probe_at_ms,
               backoff_ms: 60_000,
               window_reset_ms: ^window_reset_ms,
               requests_remaining: 0,
               requests_limit: 2500
             } = RateLimit.status(@now_ms)

      Agent.update(clock, fn _ -> probe_at_ms end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, %{"data" => %{}}} = call.()
        end)

      assert log =~ "Linear rate-limit probe succeeded; resuming Linear requests"
      assert_received :linear_request

      assert %{paused_until_ms: nil, backoff_ms: 0, window_reset_ms: nil, requests_remaining: 2499} =
               RateLimit.status(probe_at_ms)

      # Back to normal: no probe gate, every call goes out.
      assert {:ok, %{"data" => %{}}} = call.()
      assert_received :linear_request
      assert RateLimit.requests_total() == 3
    end

    test "a rate-limited probe doubles the pause up to five minutes" do
      {:ok, clock} = Agent.start_link(fn -> @now_ms end)
      now_ms_fun = fn -> Agent.get(clock, & &1) end
      Process.put(:linear_response, rate_limited_response(@now_ms + 3_600_000))
      call = linear_call(now_ms_fun)

      capture_log(fn ->
        pauses =
          Enum.map_reduce(1..6, @now_ms, fn _n, at_ms ->
            Agent.update(clock, fn _ -> at_ms end)
            assert {:error, {:linear_rate_limited, retry_ms}} = call.()
            assert_received :linear_request

            # Nothing leaves until the next probe is due.
            Agent.update(clock, fn _ -> retry_ms - 1 end)
            assert {:error, {:linear_rate_limited, ^retry_ms}} = call.()
            refute_received :linear_request

            {retry_ms - at_ms, retry_ms}
          end)
          |> elem(0)

        assert pauses == [60_000, 120_000, 240_000, 300_000, 300_000, 300_000]
      end)

      assert RateLimit.requests_total() == 6
    end

    test "only one caller probes; a probe that never answers frees the next probe after its lease" do
      pause_linear_for(@now_ms)
      probe_at_ms = @now_ms + 60_000
      lease_ends_ms = probe_at_ms + 30_000

      assert RateLimit.check(probe_at_ms) == :probe
      assert RateLimit.check(probe_at_ms) == {:error, {:linear_rate_limited, lease_ends_ms}}

      # A caller that read the expired pause before the winner swapped it loses the claim.
      assert RateLimit.claim_probe_for_test(probe_at_ms, probe_at_ms) ==
               {:error, {:linear_rate_limited, lease_ends_ms}}

      # The probe's transport fails: no response, so the pause stands until the lease ends.
      request_fun = fn _payload, _headers -> {:error, :timeout} end

      capture_log(fn ->
        assert {:error, {:linear_rate_limited, ^lease_ends_ms}} =
                 Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: fn -> lease_ends_ms - 1 end)

        assert {:error, {:linear_api_request, :timeout}} =
                 Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: fn -> lease_ends_ms end)
      end)

      # That call was itself the next probe; it failed too, so the next lease holds.
      assert RateLimit.paused_until(lease_ends_ms) == lease_ends_ms + 30_000
      assert RateLimit.check(lease_ends_ms + 30_000) == :probe
    end

    test "any answer to a probe that is not a rate limit resumes traffic" do
      pause_linear_for(@now_ms)
      body = %{"errors" => [%{"message" => "nope", "extensions" => %{"code" => "BAD_USER_INPUT"}}]}
      request_fun = fn _payload, _headers -> {:ok, %{status: 400, body: body}} end

      capture_log(fn ->
        assert {:error, {:linear_api_status, 400, ^body}} =
                 Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: fn -> @now_ms + 60_000 end)
      end)

      assert RateLimit.check(@now_ms + 60_000) == :ok
    end

    test "a request already in flight that comes back rate-limited keeps the current pause" do
      assert pause_linear_for(@now_ms) == @now_ms + 60_000

      assert {:rate_limited, retry_ms} = RateLimit.record_response(%{status: 429}, @now_ms + 5_000)
      assert retry_ms == @now_ms + 60_000
      assert %{backoff_ms: 60_000} = RateLimit.status(@now_ms)
    end

    test "treats HTTP 429 as a rate limit and accepts list-style headers" do
      window_reset_ms = @now_ms + 3_000_000

      request_fun = fn _payload, _headers ->
        {:ok, %{status: 429, headers: [{"X-RateLimit-Requests-Reset", Integer.to_string(window_reset_ms)}], body: "slow down"}}
      end

      capture_log(fn ->
        assert {:error, {:linear_rate_limited, retry_ms}} =
                 Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: fn -> @now_ms end)

        assert retry_ms == @now_ms + 60_000
      end)

      assert RateLimit.remaining_pause_ms(@now_ms) == 60_000
      assert RateLimit.remaining_pause_ms(@now_ms + 60_000) == 0
      assert %{window_reset_ms: ^window_reset_ms} = RateLimit.status(@now_ms)
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

  describe "RateLimit window reset (display only)" do
    test "is unknown without usable reset headers" do
      headers = %{
        "x-ratelimit-requests-reset" => "soon",
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms - 1)
      }

      assert {:rate_limited, retry_ms} = RateLimit.record_response(%{status: 429, headers: headers}, @now_ms)
      assert retry_ms == @now_ms + 60_000
      assert %{window_reset_ms: nil} = RateLimit.status(@now_ms)
    end

    test "prefers the spent bucket over a later healthy one" do
      headers = %{
        "x-ratelimit-requests-remaining" => "1200",
        "x-ratelimit-requests-reset" => Integer.to_string(@now_ms + 50_000),
        "x-ratelimit-complexity-remaining" => "0",
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms + 10_000)
      }

      response = %{status: 400, headers: headers, body: @rate_limited_body}
      assert {:rate_limited, _retry_ms} = RateLimit.record_response(response, @now_ms)
      assert %{window_reset_ms: window_reset_ms} = RateLimit.status(@now_ms)
      assert window_reset_ms == @now_ms + 10_000
    end

    test "takes the latest reset when no bucket reports as spent, without changing the pause" do
      headers = %{
        "x-ratelimit-requests-reset" => Integer.to_string(@now_ms + 30_000),
        "x-ratelimit-complexity-reset" => Integer.to_string(@now_ms + 10 * 3_600_000)
      }

      assert {:rate_limited, retry_ms} = RateLimit.record_response(%{status: 429, headers: headers}, @now_ms)
      assert retry_ms == @now_ms + 60_000
      assert %{window_reset_ms: window_reset_ms} = RateLimit.status(@now_ms)
      assert window_reset_ms == @now_ms + 10 * 3_600_000
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

  describe "soft brake" do
    test "stretches the poll interval below 10% of the limit and lifts it once the budget recovers" do
      assert RateLimit.poll_interval_multiplier() == 1

      multipliers =
        for remaining <- [2500, 250, 249, 125, 124, 0, 1000] do
          :ok = record_budget(remaining, 2500)
          RateLimit.poll_interval_multiplier()
        end

      assert multipliers == [1, 1, 2, 2, 4, 4, 1]

      :ok = record_budget(10, 0)
      assert RateLimit.poll_interval_multiplier() == 1
    end

    test "the orchestrator schedules the next repo poll with the stretched interval" do
      repos = [%{name: "web", team: "ACME", labels: ["web"]}]
      fetcher_ok = fn %{name: "web"} -> {:ok, []} end
      fetcher_error = fn %{name: "web"} -> {:error, :linear_unavailable} end
      state = %Orchestrator.State{poll_interval_ms: 100}

      :ok = record_budget(2000, 2500)
      assert {:ok, _buckets, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher_ok, 0)
      assert state.repo_poll_due_at_ms["web"] == 100

      :ok = record_budget(200, 2500)
      assert {:ok, _buckets, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher_ok, 100)
      assert state.repo_poll_due_at_ms["web"] == 300

      :ok = record_budget(100, 2500)

      capture_log(fn ->
        # A failed poll of a warmed repo serves the cache and retries after the stretched interval.
        assert {:ok, _buckets, state} =
                 Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher_error, 300)

        assert state.repo_poll_due_at_ms["web"] == 700
      end)

      :ok = record_budget(1500, 2500)
      assert {:ok, _buckets, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher_ok, 700)
      assert state.repo_poll_due_at_ms["web"] == 800
    end
  end

  describe "orchestrator while Linear is rate-limited" do
    test "skips the poll cycle without any Linear call and schedules the next tick for the probe" do
      reset_ms = pause_linear_for(RateLimit.now_ms())

      orchestrator_name = Module.concat(__MODULE__, :RateLimitedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: stop_process(pid)
      end)

      requests_before = RateLimit.requests_total()

      snapshot =
        wait_for_snapshot(pid, fn
          %{polling: %{checking?: false, next_poll_in_ms: due_in_ms}} when is_integer(due_in_ms) -> due_in_ms > 30_000
          _ -> false
        end)

      assert %{polling: %{next_poll_in_ms: due_in_ms, linear: linear}} = snapshot
      assert due_in_ms > 50_000
      assert %{paused_until_ms: ^reset_ms, rate_limited_for_ms: pause_ms, requests_last_poll: 0} = linear
      assert pause_ms > 50_000
      assert %{window_resets_in_ms: window_resets_in_ms} = linear
      assert window_resets_in_ms > 3_000_000
      assert %{usage: %{window_ms: 3_600_000, total: total, callers: callers}} = linear
      assert total == callers |> Enum.map(& &1.requests) |> Enum.sum()
      assert RateLimit.requests_total() == requests_before

      plain = snapshot |> then(&Renderer.format_snapshot_content({:ok, &1}, 0.0)) |> strip_ansi()
      assert plain =~ ~r/Next refresh: Linear rate-limited; probing in \d+s \(full budget in \d+m\) \(Linear: 0 req last poll, 0\/2500 left this hour, polling slowed 4x\)/
    end

    test "a rate-limited retry refresh keeps its attempt and waits for the reset" do
      reset_ms = pause_linear_for(RateLimit.now_ms())

      issue_id = "issue-rate-limited-retry"
      state = %Orchestrator.State{repo_key: "default", max_concurrent_agents: 1, claimed: MapSet.new([issue_id])}

      capture_log(fn ->
        assert {:noreply, updated_state} =
                 Orchestrator.handle_retry_issue_for_test(state, issue_id, 3, %{identifier: "MT-224"}, fn [^issue_id] ->
                   {:error, {:linear_rate_limited, reset_ms}}
                 end)

        assert %{attempt: 3, due_at_ms: due_at_ms, timer_ref: timer_ref} = updated_state.retry_attempts[issue_id]
        assert due_at_ms - System.monotonic_time(:millisecond) > 50_000
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

      pause_linear_for(RateLimit.now_ms())
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
          assert {:noreply, %Orchestrator.State{running: running} = updated_state} =
                   Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{identifier: "MT-225"}, fn [^issue_id] ->
                     {:ok, [issue]}
                   end)

          assert running == %{}

          # The retry stays queued for when the pause ends, at the same attempt.
          assert %{attempt: 1, due_at_ms: due_at_ms, timer_ref: timer_ref, error: "waiting for Linear before dispatch: " <> _} =
                   updated_state.retry_attempts[issue_id]

          assert due_at_ms - System.monotonic_time(:millisecond) > 50_000
          Process.cancel_timer(timer_ref)
        end)

      refute log =~ "issue refresh failed"
      assert RateLimit.requests_total() == requests_before
    end

    test "a retry whose dispatch refresh times out stays queued at the same attempt" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "token",
        tracker_endpoint: "http://127.0.0.1:9/graphql",
        max_concurrent_agents: 1,
        quality_gate: %{enabled: false}
      )

      {state, issue_id, retry} = retry_after_dispatch_refresh(2)

      assert %{attempt: 2, due_at_ms: due_at_ms, delay_type: :linear_wait, error: error} = retry
      assert error =~ "waiting for Linear before dispatch: {:linear_api_request, %Req.TransportError{"
      assert_in_delta due_at_ms - System.monotonic_time(:millisecond), 5_000, 1_000
      assert MapSet.member?(state.claimed, issue_id)
    end

    test "a retry whose dispatch refresh fails for good is rescheduled with the next attempt" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        max_concurrent_agents: 1,
        quality_gate: %{enabled: false}
      )

      {_state, _issue_id, retry} = retry_after_dispatch_refresh(2)

      assert %{attempt: 3, delay_type: nil, error: "retry issue refresh failed: " <> _} = retry
    end
  end

  # Runs a retry whose first refresh sees an active issue; the dispatch refresh
  # that follows goes to the (unreachable or unconfigured) Linear endpoint.
  defp retry_after_dispatch_refresh(attempt) do
    issue_id = "issue-dispatch-refresh-#{System.unique_integer([:positive])}"
    issue = %Issue{id: issue_id, identifier: "MT-322", title: "Dispatch", state: "Todo", assigned_to_worker: true}

    state = %Orchestrator.State{
      repo_key: "default",
      max_concurrent_agents: 1,
      claimed: MapSet.new([issue_id]),
      codex_totals: @empty_codex_totals
    }

    capture_log(fn ->
      assert {:noreply, %Orchestrator.State{running: running} = updated_state} =
               Orchestrator.handle_retry_issue_for_test(state, issue_id, attempt, %{identifier: "MT-322"}, fn [^issue_id] ->
                 {:ok, [issue]}
               end)

      assert running == %{}
      assert %{timer_ref: timer_ref} = retry = updated_state.retry_attempts[issue_id]
      Process.cancel_timer(timer_ref)
      send(self(), {:dispatch_refresh_result, updated_state, retry})
    end)

    assert_received {:dispatch_refresh_result, updated_state, retry}
    {updated_state, issue_id, retry}
  end

  test "agent tools explain the pause and when to retry" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Done"},
        issue: %Issue{id: "issue-current"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_rate_limited, @now_ms}} end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "linear_rate_limited", "message" => message, "retry_at" => retry_at}} =
             Jason.decode!(response["output"])

    assert message =~ "Linear is rate-limiting Symphony"
    assert retry_at == @now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
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

    slowed_linear = %{
      rate_limited_for_ms: 0,
      requests_last_poll: 2,
      requests_remaining: 200,
      requests_limit: 2_500,
      poll_interval_multiplier: 2
    }

    slowed_polling = %{polling | linear: slowed_linear}

    plain =
      {:ok, %{running: [], retrying: [], codex_totals: @empty_codex_totals, polling: slowed_polling}}
      |> Renderer.format_snapshot_content(0.0)
      |> strip_ansi()

    assert plain =~ "Next refresh: 4s (Linear: 2 req last poll, 200/2500 left this hour, polling slowed 2x)"
  end

  # Pauses Linear as a first rate limit at `at_ms` would: one minute, with a
  # rolling-hour window reset about an hour ahead.
  defp pause_linear_for(at_ms) do
    {:rate_limited, retry_ms} = RateLimit.record_response(rate_limited_response(at_ms + 3_600_000), at_ms)
    retry_ms
  end

  defp rate_limited_response(window_reset_ms) do
    %{
      status: 400,
      headers: %{
        "x-ratelimit-requests-remaining" => ["0"],
        "x-ratelimit-requests-limit" => ["2500"],
        "x-ratelimit-requests-reset" => [Integer.to_string(window_reset_ms)]
      },
      body: @rate_limited_body
    }
  end

  defp ok_response(remaining) do
    %{status: 200, headers: %{"x-ratelimit-requests-remaining" => [remaining]}, body: %{"data" => %{}}}
  end

  defp linear_call(now_ms_fun) do
    parent = self()

    request_fun = fn _payload, _headers ->
      send(parent, :linear_request)
      {:ok, Process.get(:linear_response)}
    end

    fn -> Client.graphql(@query, %{}, request_fun: request_fun, now_ms_fun: now_ms_fun) end
  end

  defp record_budget(remaining, limit) do
    headers = %{
      "x-ratelimit-requests-remaining" => Integer.to_string(remaining),
      "x-ratelimit-requests-limit" => Integer.to_string(limit)
    }

    RateLimit.record_response(%{status: 200, headers: headers}, @now_ms)
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
