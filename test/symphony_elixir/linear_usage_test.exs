defmodule SymphonyElixir.LinearUsageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{TransientRetry, Usage}

  @now_ms 1_791_000_000_000

  describe "TransientRetry.transient?/1" do
    test "treats rate limits, transport errors and 429/5xx answers as transient" do
      assert TransientRetry.transient?({:linear_rate_limited, @now_ms})
      assert TransientRetry.transient?({:linear_api_request, %Req.TransportError{reason: :timeout}})
      assert TransientRetry.transient?({:linear_api_request, %Req.TransportError{reason: :econnrefused}})
      assert TransientRetry.transient?({:linear_api_status, 502, %{}})
      assert TransientRetry.transient?({:linear_api_status, 429, nil})

      refute TransientRetry.transient?({:linear_api_request, :missing_linear_api_token})
      refute TransientRetry.transient?({:linear_api_status, 400, %{}})
      refute TransientRetry.transient?({:linear_graphql_errors, []})
      refute TransientRetry.transient?(:rate_limited)
    end
  end

  describe "TransientRetry.run/2" do
    test "returns a result that is not an error without waiting" do
      assert TransientRetry.run(fn -> {:ok, :fresh} end) == {:ok, :fresh}
      assert TransientRetry.run(fn -> :ok end) == :ok
    end

    test "returns an error that is not transient at once" do
      parent = self()

      assert TransientRetry.run(fn -> {:error, :boom} end, sleep_fun: &send(parent, {:slept, &1})) == {:error, :boom}
      refute_received {:slept, _delay_ms}
    end

    test "waits until a rate-limit pause ends, then retries" do
      {fun, sleeps} = scripted([{:error, {:linear_rate_limited, @now_ms + 42_000}}, {:ok, :after_pause}])

      assert TransientRetry.run(fun, now_ms_fun: fn -> @now_ms end, sleep_fun: sleeps) == {:ok, :after_pause}
      assert_received {:slept, 42_000}
    end

    test "waits at least a second on a pause that already ended" do
      {fun, sleeps} = scripted([{:error, {:linear_rate_limited, @now_ms - 5}}, :ok])

      assert TransientRetry.run(fun, now_ms_fun: fn -> @now_ms end, sleep_fun: sleeps) == :ok
      assert_received {:slept, 1_000}
    end

    test "backs off a transport error from 5 s, doubling up to 60 s" do
      timeout = {:error, {:linear_api_request, %Req.TransportError{reason: :timeout}}}
      {fun, sleeps} = scripted(List.duplicate(timeout, 6) ++ [{:ok, :back}])

      assert TransientRetry.run(fun, now_ms_fun: fn -> @now_ms end, sleep_fun: sleeps) == {:ok, :back}

      for delay_ms <- [5_000, 10_000, 20_000, 40_000, 60_000, 60_000] do
        assert_received {:slept, ^delay_ms}
      end
    end

    test "gives up with the last error once the wait budget is spent" do
      {:ok, clock} = Agent.start_link(fn -> @now_ms end)
      parent = self()
      error = {:error, {:linear_api_status, 503, nil}}

      sleep_fun = fn delay_ms ->
        send(parent, {:slept, delay_ms})
        Agent.update(clock, &(&1 + delay_ms))
      end

      assert TransientRetry.run(fn -> error end,
               max_wait_ms: 12_000,
               now_ms_fun: fn -> Agent.get(clock, & &1) end,
               sleep_fun: sleep_fun,
               on_wait: fn reason, delay_ms -> send(parent, {:on_wait, reason, delay_ms}) end
             ) == error

      # 5 s, then the 7 s left of the 12 s budget, then one last try.
      assert_received {:slept, 5_000}
      assert_received {:slept, 7_000}
      refute_received {:slept, _delay_ms}
      assert_received {:on_wait, {:linear_api_status, 503, nil}, 5_000}
    end

    test "logs a warning naming the call's label before each wait, and still calls on_wait" do
      rate_limited = {:error, {:linear_rate_limited, @now_ms + 42_000}}
      {fun, sleeps} = scripted([rate_limited, :ok])

      log =
        capture_log(fn ->
          assert TransientRetry.run(fun, label: "moving TP-1 to In Progress", now_ms_fun: fn -> @now_ms end, sleep_fun: sleeps) == :ok
        end)

      assert log =~ "Linear call failed while moving TP-1 to In Progress; retrying in 42000ms reason={:linear_rate_limited, #{@now_ms + 42_000}}"

      {fun, sleeps} = scripted([rate_limited, :ok])
      parent = self()

      log =
        capture_log(fn ->
          assert TransientRetry.run(fun,
                   label: "moving TP-1 to In Progress",
                   on_wait: fn _reason, delay_ms -> send(parent, {:on_wait, delay_ms}) end,
                   now_ms_fun: fn -> @now_ms end,
                   sleep_fun: sleeps
                 ) == :ok
        end)

      assert_received {:on_wait, 42_000}
      assert log =~ "Linear call failed while moving TP-1 to In Progress; retrying in 42000ms"
    end
  end

  describe "Usage callers" do
    test "an untagged process counts as other; put_caller and with_caller tag it" do
      Process.delete({Usage, :caller})
      assert Usage.current_caller() == :other

      Usage.put_caller(:ci_poller)
      assert Usage.current_caller() == :ci_poller

      assert Usage.with_caller({:agent, "MT-1"}, fn -> Usage.current_caller() end) == {:agent, "MT-1"}
      assert Usage.current_caller() == :ci_poller

      Process.delete({Usage, :caller})
      assert Usage.with_caller(:auto_review, fn -> Usage.current_caller() end) == :auto_review
      assert Usage.current_caller() == :other
    end

    test "a task counts against the caller that started it" do
      Usage.put_caller(:pr_review_poller)

      assert Task.async(fn -> Usage.current_caller() end) |> Task.await() == :pr_review_poller

      assert Task.async(fn -> Task.async(fn -> Usage.current_caller() end) |> Task.await() end) |> Task.await() ==
               :pr_review_poller
    end

    test "a task started by an untagged process, or one whose starter is gone, counts as other" do
      Process.delete({Usage, :caller})
      assert Task.async(fn -> Usage.current_caller() end) |> Task.await() == :other

      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _reason}

      assert Task.async(fn ->
               Process.put(:"$callers", [gone])
               Usage.current_caller()
             end)
             |> Task.await() == :other
    end

    test "labels callers for display" do
      assert Usage.caller_label(:orchestrator) == "orchestrator"
      assert Usage.caller_label({:agent, "TP-1"}) == "agent:TP-1"
      assert Usage.caller_label({:agent, nil}) == "agent:unknown"
      assert Usage.caller_label({:agent, ""}) == "agent:unknown"
    end
  end

  describe "Usage counts" do
    test "counts requests per caller over the rolling hour, busiest first" do
      quiet = {:agent, "MT-USAGE-QUIET-#{System.unique_integer([:positive])}"}
      busy = {:agent, "MT-USAGE-BUSY-#{System.unique_integer([:positive])}"}
      old = {:agent, "MT-USAGE-OLD-#{System.unique_integer([:positive])}"}

      Usage.with_caller(quiet, fn -> Usage.record(nil, @now_ms - 59 * 60_000) end)
      Usage.with_caller(busy, fn -> Enum.each(1..3, fn _ -> Usage.record("SymphonyUsageBusy", @now_ms) end) end)
      Usage.with_caller(old, fn -> Usage.record("SymphonyUsageOld", @now_ms - 60 * 60_000) end)

      %{window_ms: 3_600_000, total: total, callers: callers, queries: queries} = Usage.snapshot(@now_ms)
      labels = Enum.map(callers, & &1.caller)

      assert %{caller: Usage.caller_label(busy), requests: 3} in callers
      assert %{caller: Usage.caller_label(quiet), requests: 1} in callers
      refute Usage.caller_label(old) in labels
      busy_index = Enum.find_index(labels, &(&1 == Usage.caller_label(busy)))
      assert busy_index < Enum.find_index(labels, &(&1 == Usage.caller_label(quiet)))
      assert total == callers |> Enum.map(& &1.requests) |> Enum.sum()
      assert total == queries |> Enum.map(& &1.requests) |> Enum.sum()
      assert %{query: "SymphonyUsageBusy", requests: 3} in queries
      assert Enum.any?(queries, &(&1.query == "unnamed"))
      refute "SymphonyUsageOld" in Enum.map(queries, & &1.query)

      # The bucket that left the window is gone for good.
      refute Usage.caller_label(old) in Enum.map(Usage.snapshot(@now_ms - 60 * 60_000).callers, & &1.caller)
    end

    test "records nothing and reports an empty hour while the usage server is down" do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Usage)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Usage) end)

      assert Usage.record() == :ok
      assert Usage.reset() == :ok
      assert Usage.snapshot() == %{window_ms: 3_600_000, total: 0, callers: [], queries: []}
    end

    test "reset clears every count" do
      Usage.with_caller(:orchestrator, fn -> Usage.record() end)
      assert Usage.snapshot().total > 0

      assert Usage.reset() == :ok
      assert Usage.snapshot().callers == []
      assert Usage.snapshot().queries == []
    end
  end

  defp scripted(results) do
    parent = self()
    {:ok, script} = Agent.start_link(fn -> results end)

    fun = fn -> Agent.get_and_update(script, fn [result | rest] -> {result, rest} end) end
    {fun, &send(parent, {:slept, &1})}
  end
end
