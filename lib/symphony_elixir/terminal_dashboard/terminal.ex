defmodule SymphonyElixir.TerminalDashboard.Terminal do
  @moduledoc """
  The real terminal behind `symphony dashboard`: its width, output, and single
  key presses. Kept apart from `SymphonyElixir.TerminalDashboard` so the loop can
  be tested without a terminal.
  """

  @spec columns() :: pos_integer() | nil
  def columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 -> columns
      _ -> nil
    end
  end

  @spec write(iodata()) :: :ok
  def write(data), do: IO.write(data)

  @doc """
  Puts the terminal in raw mode and sends each key press to `owner` as
  `{:terminal_key, key}`, then `{:terminal_key, :eof}` once input closes.
  Without a terminal, keys aren't read.
  """
  @spec open(pid()) :: :ok
  def open(owner) do
    # Closing the Terminal window hangs up the process: stop instead of polling on.
    :os.set_signal(:sighup, :default)

    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        # Ctrl-C then reaches the key reader instead of the runtime's break menu.
        stty("-isig")
        spawn_link(fn -> read_keys(owner) end)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @spec close() :: :ok
  def close do
    stty("isig")
    :ok
  end

  defp read_keys(owner) do
    case IO.getn("", 1) do
      key when is_binary(key) ->
        send(owner, {:terminal_key, key})
        read_keys(owner)

      _eof_or_error ->
        send(owner, {:terminal_key, :eof})
    end
  end

  defp stty(setting) do
    System.cmd("/bin/sh", ["-c", "stty #{setting} < /dev/tty"], stderr_to_stdout: true)
    :ok
  end
end
