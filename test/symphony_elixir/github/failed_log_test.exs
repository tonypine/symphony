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
