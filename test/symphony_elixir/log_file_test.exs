defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  require Logger

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the resolved logs root" do
    assert LogFile.default_log_file() == SymphonyElixir.Paths.log_file()
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/symphony.log"
  end

  test "flush/0 writes the entries the log file handler holds to disk" do
    {:ok, %{config: %{file: file}}} = :logger.get_handler_config(:symphony_disk_log)
    marker = "log file flush #{System.unique_integer([:positive])}"

    Logger.error(marker)
    assert LogFile.flush() == :ok

    assert "#{file}.*" |> Path.wildcard() |> Enum.any?(&(File.read!(&1) =~ marker))
  end
end
