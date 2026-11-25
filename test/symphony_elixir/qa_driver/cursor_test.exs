defmodule SymphonyElixir.QaDriver.CursorTest do
  # TP-1678: the app's cursor report, read for qa_hover.
  use ExUnit.Case, async: true

  alias SymphonyElixir.QaDriver.{Cursor, Host}

  setup do
    dir = Path.join(System.tmp_dir!(), "qa-cursor-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, "app-root", "cursor"]))
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, qa_root: Path.join(dir, "app-root")}
  end

  defp config(dir, overrides \\ %{}) do
    host = %{
      cmd: Map.get(overrides, :cmd, &Host.cmd/3),
      # As `Remote.read/2`: the copy is taken away once read.
      read:
        Map.get(overrides, :read, fn path ->
          bytes = File.read!(path)
          File.rm!(path)
          {:ok, bytes}
        end)
    }

    %{host: host, host_dir: dir, sleep: fn _ms -> :ok end}
  end

  defp write!(qa_root, report), do: File.write!(Path.join([qa_root, "cursor", "42.json"]), Jason.encode!(report))

  test "the folder is the one the app writes into" do
    assert Cursor.folder() == "cursor"
  end

  test "reads the report and takes its copy away", %{dir: dir, qa_root: qa_root} do
    assert Cursor.read(config(dir), qa_root, 42) == :missing

    write!(qa_root, %{"version" => 1, "cursor" => "arrow", "source" => "none", "pointer" => %{"x" => 1, "y" => 2}})
    assert {:ok, %{"cursor" => "arrow"}} = Cursor.read(config(dir), qa_root, 42)
    assert Path.wildcard(Path.join(dir, "cursor-*.json")) == []
    assert File.exists?(Path.join([qa_root, "cursor", "42.json"]))
  end

  test "says why a report cannot be read", %{dir: dir, qa_root: qa_root} do
    odd = config(dir, %{cmd: fn _cmd, _args, _opts -> {:ok, {"something else\n", 0}} end})
    assert {:error, "the copy said \"something else\""} = Cursor.read(odd, qa_root, 42)

    failed = config(dir, %{cmd: fn _cmd, _args, _opts -> {:ok, {"cp: denied\n", 1}} end})
    assert {:error, "the copy failed (exit 1): cp: denied"} = Cursor.read(failed, qa_root, 42)

    down = config(dir, %{cmd: fn _cmd, _args, _opts -> {:error, :timeout} end})
    assert {:error, ":timeout"} = Cursor.read(down, qa_root, 42)

    write!(qa_root, %{"version" => 1, "cursor" => "arrow", "source" => "none"})
    unread = config(dir, %{read: fn _path -> {:error, :enoent} end})
    assert {:error, ":enoent"} = Cursor.read(unread, qa_root, 42)

    assert %{"cursor" => nil, "cursor_source" => "bad_report", "cursor_note" => "The app's cursor report could not be read: :enoent."} =
             Cursor.hover_fields(unread, qa_root, 42, %{"x" => 1, "y" => 2})
  end

  test "an answer without a hovered point is the app's last word, unsettled", %{dir: dir, qa_root: qa_root} do
    write!(qa_root, %{"version" => 1, "cursor" => "pointing_hand", "element" => "open-button", "source" => "recorded", "pointer" => %{"x" => 1, "y" => 2}})

    assert %{"cursor" => "pointing_hand", "cursor_element" => "open-button", "cursor_settled" => false} =
             Cursor.hover_fields(config(dir), qa_root, 42, nil)
  end
end
