defmodule SymphonyElixir.ProviderUsageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.ProviderUsage

  @now ~U[2026-11-25 12:00:00Z]
  @windows %{"seven_day" => %{status: "allowed", utilization: 0.5, resets_at: ~U[2026-11-28 00:00:00Z]}}

  defp reader do
    test = self()

    fn provider ->
      send(test, {:read, provider})
      {:ok, @windows}
    end
  end

  test "Symphony reads OpenCode Go's usage from the provider, and Anthropic's from its runs" do
    assert ProviderUsage.providers() == ["opencode-go"]
  end

  test "a read runs in a task that answers the recipient, at most once a minute unless forced" do
    read_at = ProviderUsage.request(%{}, "opencode-go", @now, reader: reader())
    assert read_at == %{"opencode-go" => @now}
    assert_receive {:read, "opencode-go"}, 1_000
    assert_receive {:provider_usage_read, "opencode-go", {:ok, @windows}}, 1_000

    # A worker update 30 seconds later reads nothing; a minute later it reads again.
    assert ProviderUsage.request(read_at, "opencode-go", DateTime.add(@now, 30), reader: reader()) == read_at
    refute_receive {:read, _provider}, 100
    later = DateTime.add(@now, 60)
    assert ProviderUsage.request(read_at, "opencode-go", later, reader: reader()) == %{"opencode-go" => later}
    assert_receive {:read, "opencode-go"}, 1_000

    # A run starting or ending always reads.
    soon = DateTime.add(@now, 5)
    assert ProviderUsage.request(read_at, "opencode-go", soon, reader: reader(), force: true) == %{"opencode-go" => soon}
    assert_receive {:read, "opencode-go"}, 1_000
  end

  test "a provider whose usage Symphony doesn't read from the provider starts no read" do
    for provider <- ["anthropic", "openai", nil] do
      assert ProviderUsage.request(%{}, provider, @now, reader: reader(), force: true) == %{}
    end

    refute_receive {:read, _provider}, 100
  end

  test "the reader the app env names is used when none is passed" do
    Application.put_env(:symphony_elixir, :provider_usage_reader, reader())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :provider_usage_reader) end)

    ProviderUsage.request(%{}, "opencode-go", @now)
    assert_receive {:read, "opencode-go"}, 1_000
  end

  test "with no reader set, the read is OpenCode Go's usage API, offline in tests" do
    previous = System.get_env("OPENCODE_API_KEY")
    on_exit(fn -> if previous, do: System.put_env("OPENCODE_API_KEY", previous), else: System.delete_env("OPENCODE_API_KEY") end)
    System.put_env("OPENCODE_API_KEY", "sk-go-test-key")

    assert ProviderUsage.read("opencode-go") == {:error, :network_disabled_in_tests}
  end

  test "a read that can't start is logged and the next trigger tries again" do
    log =
      capture_log(fn ->
        assert ProviderUsage.request(%{}, "opencode-go", @now, reader: reader(), supervisor: :no_such_task_supervisor) == %{"opencode-go" => @now}
      end)

    assert log =~ "Provider usage read not started provider=opencode-go"
    refute_receive {:read, _provider}, 100
  end

  test "a failed read is a warning naming the provider and why; no key is only a debug line" do
    log = capture_log(fn -> ProviderUsage.log_failure("opencode-go", {:http_status, 401}) end)
    assert log =~ "Provider usage read failed; keeping the last windows provider=opencode-go"
    assert log =~ "HTTP 401 (the key is not valid)"

    assert ProviderUsage.log_failure("opencode-go", :no_key) == :ok
    log = capture_log([level: :debug], fn -> ProviderUsage.log_failure("opencode-go", :no_key) end)
    refute log =~ "[warning]"
  end
end
