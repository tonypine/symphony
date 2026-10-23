defmodule SymphonyElixir.Artifacts.StoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Artifacts.Store

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-artifact-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "an id is the lowercase hex sha256 of the bytes" do
    id = Store.id("hello")

    assert id == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    assert Store.id?(id)
    refute Store.id?(String.upcase(id))
    refute Store.id?("../" <> binary_part(id, 0, 61))
    refute Store.id?(binary_part(id, 0, 63))
    refute Store.id?(nil)
  end

  test "the file of an id sits under the first two characters of its id", %{dir: dir} do
    id = Store.id("hello")

    assert Store.path(id, dir) == Path.join([dir, "2c", id])
    assert String.starts_with?(Store.path(id), SymphonyElixir.Paths.artifacts_dir())
  end

  test "write puts the bytes at their id's path, leaves no temporary file and keeps a file already there", %{dir: dir} do
    id = Store.id("hello")
    refute Store.present?(id, dir)

    assert :ok = Store.write("hello", dir)
    assert File.read!(Store.path(id, dir)) == "hello"
    assert Store.present?(id, dir)
    assert File.ls!(Path.dirname(Store.path(id, dir))) == [id]

    %File.Stat{mtime: mtime} = File.stat!(Store.path(id, dir), time: :posix)
    assert :ok = Store.write("hello", dir)
    assert %File.Stat{mtime: ^mtime} = File.stat!(Store.path(id, dir), time: :posix)
  end

  test "concurrent writes of the same bytes leave one whole file", %{dir: dir} do
    bytes = :binary.copy("x", 100_000)

    assert 1..8 |> Enum.map(fn _ -> Task.async(fn -> Store.write(bytes, dir) end) end) |> Task.await_many() |> Enum.uniq() == [:ok]
    assert File.read!(Store.path(Store.id(bytes), dir)) == bytes
    assert File.ls!(Path.dirname(Store.path(Store.id(bytes), dir))) == [Store.id(bytes)]
  end

  test "a write that can't make its folder fails and leaves nothing", %{dir: dir} do
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "a file where the folder should be")

    assert {:error, _reason} = Store.write("hello", dir)
    assert File.read!(dir) == "a file where the folder should be"
    File.rm!(dir)
  end

  test "a folder at the id's path is not a present file", %{dir: dir} do
    id = Store.id("hello")
    File.mkdir_p!(Store.path(id, dir))

    refute Store.present?(id, dir)
  end

  describe "sniff/2" do
    test "PNG and JPEG by their magic bytes, whatever the name" do
      assert Store.sniff(@png, "shot.bin") == "image/png"
      assert Store.sniff(@jpeg, "shot.png") == "image/jpeg"
    end

    test "a .jsonl file whose first line is a JSON object is JSON lines" do
      assert Store.sniff(~s({"type":"user"}\n{"type":"assistant"}\n), "run.jsonl") == "application/x-ndjson"
      assert Store.sniff(~s({"type":"user"}\r\n), "RUN.JSONL") == "application/x-ndjson"
      assert Store.sniff(~s({"type":"user"}), "run.jsonl") == "application/x-ndjson"
    end

    test "a .jsonl file whose first line is not a JSON object is octet-stream" do
      assert Store.sniff(~s([1, 2]\n), "run.jsonl") == "application/octet-stream"
      assert Store.sniff("not json\n{}", "run.jsonl") == "application/octet-stream"
      assert Store.sniff("", "run.jsonl") == "application/octet-stream"
    end

    test "UTF-8 markdown, text and logs by their extension" do
      assert Store.sniff("# Report ✓\n", "qa-report.md") == "text/markdown"
      assert Store.sniff("plain ✓\n", "notes.txt") == "text/plain"
      assert Store.sniff("12:00 started\n", "run.log") == "text/plain"
    end

    test "anything else is octet-stream" do
      assert Store.sniff("diff --git a b\n", "change.diff") == "application/octet-stream"
      assert Store.sniff(<<0xFF, 0xFE, 0x00>>, "notes.txt") == "application/octet-stream"
      assert Store.sniff(<<0xFF, 0xFE, 0x00>>, "run.jsonl") == "application/octet-stream"
    end
  end
end
