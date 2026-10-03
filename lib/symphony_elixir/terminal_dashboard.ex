defmodule SymphonyElixir.TerminalDashboard do
  @moduledoc """
  `symphony dashboard`: draws a running Symphony's terminal dashboard by
  polling its control API, until the user presses `q` or Ctrl-C.

  The frame is rendered by the running Symphony (`GET /api/v1/state?format=terminal`),
  so it matches what Symphony draws when started from a terminal. While Symphony
  doesn't answer, the screen says so and polling carries on.
  """

  alias SymphonyElixir.ControlClient
  alias SymphonyElixir.TerminalDashboard.Terminal

  @poll_ms 1_000
  @ctrl_c <<3>>
  @quit_keys [@ctrl_c, "q", "Q"]
  # The alternate screen, without a cursor, so quitting gives back the shell's screen.
  @enter_screen "\e[?1049h\e[?25l"
  @leave_screen "\e[?25h\e[?1049l"

  @type fetch_result :: {:ok, String.t()} | :unavailable | {:error, term()}
  @type deps :: %{
          fetch_frame: (pos_integer() | nil, String.t() -> fetch_result()),
          columns: (-> pos_integer() | nil),
          write: (iodata() -> term()),
          open: (pid() -> term()),
          close: (-> term())
        }

  @doc """
  Polls and draws until a quit key arrives as `{:terminal_key, key}`, or the
  terminal closes (`{:terminal_key, :eof}`). `url_source` gives the control URL
  for each poll, so a Symphony that restarts on a new port is found again.
  """
  @spec run((-> String.t()), deps(), keyword()) :: :ok
  def run(url_source, deps, opts) do
    poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
    deps.open.(self())
    deps.write.(@enter_screen)

    try do
      loop(url_source, deps, poll_ms)
    after
      deps.write.(@leave_screen)
      deps.close.()
    end
  end

  @doc "Dependencies that talk to the real terminal and the control API."
  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      fetch_frame: &ControlClient.dashboard_frame(&1, control_url: &2),
      columns: &Terminal.columns/0,
      write: &Terminal.write/1,
      open: &Terminal.open/1,
      close: &Terminal.close/0
    }
  end

  defp loop(url_source, deps, poll_ms) do
    url = url_source.()

    frame =
      deps.columns.()
      |> deps.fetch_frame.(url)
      |> frame_for(url)

    deps.write.(frame_sequence(frame <> "\n" <> footer(url)))
    wait(url_source, deps, poll_ms)
  end

  defp wait(url_source, deps, poll_ms) do
    receive do
      {:terminal_key, key} when key in @quit_keys or key == :eof -> :ok
      {:terminal_key, _key} -> wait(url_source, deps, poll_ms)
    after
      poll_ms -> loop(url_source, deps, poll_ms)
    end
  end

  # A raw-mode terminal doesn't return the carriage on a line feed.
  defp frame_sequence(frame) do
    [IO.ANSI.home(), IO.ANSI.clear(), String.replace(frame, "\n", "\r\n"), "\r\n"]
  end

  defp frame_for({:ok, frame}, _url), do: frame
  defp frame_for(:unavailable, url), do: problem_frame("Symphony at #{url} is starting or has no dashboard yet")
  defp frame_for({:error, reason}, url), do: problem_frame(problem(reason, url))

  defp problem(:control_token_unavailable, _url),
    do: "No control token found; is Symphony running? (set SYMPHONY_STATE_ROOT to its state directory)"

  defp problem({:http_status, 401, _payload}, url), do: "Symphony at #{url} refused the control token"
  defp problem({:http_status, status, _payload}, url), do: "Symphony at #{url} answered HTTP #{status}"
  defp problem({:connection_failed, _reason}, url), do: "Symphony isn't answering at #{url}"
  defp problem(reason, url), do: "Couldn't read the dashboard from #{url}: #{inspect(reason)}"

  defp problem_frame(message) do
    Enum.join(
      [
        IO.ANSI.bright() <> "╭─ SYMPHONY STATUS" <> IO.ANSI.reset(),
        IO.ANSI.red() <> "│ " <> message <> IO.ANSI.reset(),
        IO.ANSI.light_black() <> "│ Trying again every second." <> IO.ANSI.reset(),
        "╰─"
      ],
      "\n"
    )
  end

  defp footer(url), do: IO.ANSI.light_black() <> "#{url} · q or Ctrl-C to quit" <> IO.ANSI.reset()
end
