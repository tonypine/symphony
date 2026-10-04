defmodule SymphonyElixir.CLIFinishTest do
  # Removes the global log file handler, so it must not run alongside async tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SymphonyElixir.{CLI, LogFile}

  @handler_id :symphony_disk_log

  setup do
    {:ok, handler} = :logger.get_handler_config(@handler_id)
    :ok = :logger.remove_handler(@handler_id)

    on_exit(fn ->
      :ok = :logger.add_handler(@handler_id, handler.module, Map.take(handler, [:level, :formatter, :config]))
    end)
  end

  test "commands that never set up the log file keep their exit status" do
    assert LogFile.flush() == :ok
    assert CLI.finish({:halt, 0}) == 0
    assert CLI.finish({:halt, 124}) == 124
  end

  test "errors print only their message when the log file is not set up" do
    assert capture_io(:stderr, fn -> assert CLI.finish({:error, "Unknown option --bogus"}) == 1 end) ==
             "Unknown option --bogus\n"

    assert capture_io(:stderr, fn -> assert CLI.finish({:error, "Config invalid", 2}) == 2 end) ==
             "Config invalid\n"
  end
end
