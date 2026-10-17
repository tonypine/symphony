defmodule SymphonyElixir.GitHub.FailedLogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.FailedLog

  defmodule GitHub do
    def fetch_failed_log(run_id, opts) do
      send(self(), {:fetch_failed_log, run_id, opts})

      case run_id do
        "bad" -> {:error, :gone}
        "2" -> {:ok, "setup\nall good\nFAILED: second run"}
        _run -> {:ok, "setup\nnoise\nERROR: broken\nstack\nlast"}
      end
    end
  end

  defmodule GhLog do
    def fetch_failed_log("gh", _opts) do
      {:ok, "build\tSet up job\t2026-10-16T21:02:01.1Z Current runner version: '2.329.0'\ntest\tRun mix test\t2026-10-16T21:02:11.4Z ** (ExUnit.AssertionError) expected 2, got 3"}
    end
  end

  test "excerpt/2 keeps the last lines from the first error inside the window, and survives bad bytes" do
    log = "early error\nnoise\nERROR: broken\nstack\nlast"
    assert FailedLog.excerpt(log, 3) == "ERROR: broken\nstack\nlast"
    assert FailedLog.excerpt("plain\nlines", 5) == "plain\nlines"
    assert FailedLog.excerpt("ERROR: broken\n" <> <<0xFF>> <> "\nlast", 5) == "ERROR: broken\n?\nlast"
    assert FailedLog.excerpt(nil, 5) == ""
    assert FailedLog.excerpt("log", 0) == ""
  end

  test "first_error/1 is the first error line, else the first line" do
    assert FailedLog.first_error("  \nsetup\n  ERROR: broken  \nmore") == "ERROR: broken"
    assert FailedLog.first_error("setup\nmore") == "setup"
    assert FailedLog.first_error("") == ""
  end

  test "first_error/1 drops gh's job, step and timestamp columns, so the same error reads the same each run" do
    run = fn stamp ->
      Enum.join(
        [
          "test\tRun mix test\t#{stamp} ##[group]Run mix test",
          "test\tRun mix test\t#{stamp}   1) test sums (MathTest)",
          "test\tRun mix test\t#{stamp}      ** (ExUnit.AssertionError) expected 2, got 3",
          "test\tRun mix test\t#{stamp} ##[error]Process completed with exit code 2."
        ],
        "\n"
      )
    end

    first = run.("2026-10-16T21:02:11.4410921Z")
    second = run.("\uFEFF2026-10-16T22:47:59.0000003Z")

    assert FailedLog.first_error(first) == "** (ExUnit.AssertionError) expected 2, got 3"
    assert FailedLog.first_error(second) == FailedLog.first_error(first)
    assert FailedLog.excerpt(first, 10) =~ ~r/\A[^\n]*AssertionError/
    assert {:ok, %{error: "** (ExUnit.AssertionError) expected 2, got 3"}} = FailedLog.read(["gh"], 10, github: __MODULE__.GhLog)

    # Without a timestamp the tab columns stay: only gh's prefix is dropped.
    assert FailedLog.first_error("a\tb\tERROR: kept") == "a\tb\tERROR: kept"
  end

  test "read/3 fetches each run's failed log, with its excerpt and first error line" do
    assert {:ok, %{excerpt: "ERROR: broken\nstack\nlast", error: "ERROR: broken"}} = FailedLog.read(["1"], 3, github: GitHub, repo: "acme/app")
    assert_received {:fetch_failed_log, "1", [repo: "acme/app"]}

    # Several runs head each excerpt with the run, and the first error line is the first run's that has one.
    assert {:ok, %{excerpt: excerpt, error: "FAILED: second run"}} = FailedLog.read(["1", "2"], 2, github: GitHub)
    assert excerpt == "Run 1 failed log:\nstack\nlast\n\nRun 2 failed log:\nFAILED: second run"
    assert {:ok, %{error: "ERROR: broken"}} = FailedLog.read(["1", "2"], 3, github: GitHub)
    assert {:ok, %{error: "stack"}} = FailedLog.read(["1", "1"], 2, github: GitHub)

    assert {:ok, %{excerpt: "No GitHub Actions run id was available for the failed check.", error: _error}} = FailedLog.read([], 3)
    assert {:error, {:failed_log_unavailable, "bad", :gone}} = FailedLog.read(["1", "bad"], 3, github: GitHub)
  end
end
