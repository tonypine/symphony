defmodule SymphonyElixir.TerminalDashboardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TerminalDashboard

  @url "http://127.0.0.1:4555"

  # Answers each poll with the next result, then repeats the last one.
  defp deps(parent, results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    %{
      fetch_frame: fn columns, url ->
        send(parent, {:fetched, columns, url})

        Agent.get_and_update(agent, fn
          [result] -> {result, [result]}
          [result | rest] -> {result, rest}
        end)
      end,
      columns: fn -> 120 end,
      write: fn data -> send(parent, {:wrote, IO.iodata_to_binary(data)}) end,
      open: fn owner -> send(parent, {:opened, owner}) end,
      close: fn -> send(parent, :closed) end
    }
  end

  defp run_until_key(deps, key, opts \\ []) do
    dashboard = Task.async(fn -> TerminalDashboard.run(fn -> @url end, deps, Keyword.put_new(opts, :poll_ms, 10)) end)
    assert_receive {:opened, owner}
    assert_receive {:wrote, "\e[?1049h\e[?25l"}
    assert_receive {:wrote, frame}
    send(owner, {:terminal_key, key})
    assert :ok = Task.await(dashboard)
    frame
  end

  test "draws the frame Symphony renders for the terminal's width, and quits on Ctrl-C" do
    frame = run_until_key(deps(self(), [{:ok, "╭─ SYMPHONY STATUS\n│ Agents: 1/3"}]), <<3>>)

    assert_received {:fetched, 120, @url}
    assert frame =~ "\e[H\e[2J╭─ SYMPHONY STATUS\r\n│ Agents: 1/3\r\n"
    assert frame =~ "#{@url} · q or Ctrl-C to quit"
    assert_receive {:wrote, "\e[?25h\e[?1049l"}
    assert_receive :closed
  end

  test "polls again until q, ignoring other keys" do
    parent = self()
    deps = deps(parent, [{:ok, "first"}, {:ok, "second"}])
    dashboard = Task.async(fn -> TerminalDashboard.run(fn -> @url end, deps, poll_ms: 10) end)
    assert_receive {:opened, owner}
    send(owner, {:terminal_key, "x"})
    assert_receive {:wrote, "\e[H\e[2Jsecond" <> _}, 1_000
    send(owner, {:terminal_key, "q"})
    assert :ok = Task.await(dashboard)
  end

  test "stops when the terminal closes" do
    run_until_key(deps(self(), [{:ok, "frame"}]), :eof)
    assert_receive :closed
  end

  test "says why Symphony can't be read and keeps polling" do
    cases = [
      {:unavailable, "Symphony at #{@url} is starting or has no dashboard yet"},
      {{:error, :control_token_unavailable}, "No control token found; is Symphony running?"},
      {{:error, {:http_status, 401, %{}}}, "Symphony at #{@url} refused the control token"},
      {{:error, {:http_status, 500, "boom"}}, "Symphony at #{@url} answered HTTP 500"},
      {{:error, {:connection_failed, :econnrefused}}, "Symphony isn't answering at #{@url}"},
      {{:error, :weird}, "Couldn't read the dashboard from #{@url}: :weird"}
    ]

    for {result, message} <- cases do
      frame = run_until_key(deps(self(), [result]), "Q")
      assert frame =~ message
      assert frame =~ "Trying again every second."
      flush_mailbox()
    end
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  test "looks the control URL up again on every poll" do
    parent = self()
    {:ok, urls} = Agent.start_link(fn -> ["http://127.0.0.1:4555", "http://127.0.0.1:4777"] end)

    url_source = fn ->
      Agent.get_and_update(urls, fn
        [url] -> {url, [url]}
        [url | rest] -> {url, rest}
      end)
    end

    dashboard = Task.async(fn -> TerminalDashboard.run(url_source, deps(parent, [{:ok, "frame"}]), poll_ms: 10) end)
    assert_receive {:opened, owner}
    assert_receive {:fetched, 120, "http://127.0.0.1:4555"}
    assert_receive {:wrote, "\e[H\e[2Jframe\r\n" <> first_footer}
    assert first_footer =~ "http://127.0.0.1:4555 · q or Ctrl-C to quit"
    assert_receive {:fetched, 120, "http://127.0.0.1:4777"}, 1_000
    assert_receive {:wrote, "\e[H\e[2Jframe\r\n" <> second_footer}, 1_000
    assert second_footer =~ "http://127.0.0.1:4777 · q or Ctrl-C to quit"
    send(owner, {:terminal_key, "q"})
    assert :ok = Task.await(dashboard)
  end

  test "runtime deps fetch from the given control URL" do
    deps = TerminalDashboard.runtime_deps()
    assert is_function(deps.open, 1)

    # Nothing listens on port 1; without a control token the client stops before connecting.
    assert {:error, reason} = deps.fetch_frame.(80, "http://127.0.0.1:1")
    assert reason == :control_token_unavailable or match?({:connection_failed, _}, reason)
  end
end
