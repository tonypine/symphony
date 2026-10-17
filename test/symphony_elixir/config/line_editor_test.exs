defmodule SymphonyElixir.Config.LineEditorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.LineEditor

  @path ["github", "webhooks", "enabled"]

  test "replaces the one line that holds the key, keeping its comment and every other line" do
    text = """
    # Symphony
    github:
      enterprise_hosts: []
      webhooks:
        enabled: false   # off for now
        relay: smee
    dashboard:
      port: 4040
    """

    assert {:ok, updated} = LineEditor.put(text, @path, "true")
    assert updated == String.replace(text, "enabled: false   # off for now", "enabled: true   # off for now")
  end

  test "inserts a missing key under its section, indented like its siblings" do
    text = "github:\n    webhooks:\n        relay: smee\n"

    assert LineEditor.put(text, @path, "true") == {:ok, "github:\n    webhooks:\n        enabled: true\n        relay: smee\n"}
  end

  test "inserts missing sections, after their parent or at the end of the file" do
    assert LineEditor.put("dashboard:\n  port: 4040\n", @path, "true") == {:ok, "dashboard:\n  port: 4040\ngithub:\n  webhooks:\n    enabled: true\n"}
    assert LineEditor.put("github:\n  enterprise_hosts: []\n", @path, "true") == {:ok, "github:\n  webhooks:\n    enabled: true\n  enterprise_hosts: []\n"}
    assert LineEditor.put("github:\n", @path, "true") == {:ok, "github:\n  webhooks:\n    enabled: true\n"}
    assert LineEditor.put("tickets: {}", ["dashboard", "port"], "4040") == {:ok, "tickets: {}\ndashboard:\n  port: 4040"}
  end

  test "a block ends at the next key no deeper than its own, past blank lines and comments" do
    text = "github:\n  webhooks:\n\n  # a comment\n    relay: smee\npull_requests:\n  enabled: true\n"

    assert {:ok, updated} = LineEditor.put(text, ["github", "webhooks", "relay"], "gh_webhook_forward")
    assert updated == String.replace(text, "relay: smee", "relay: gh_webhook_forward")
  end

  test "fills an empty file" do
    assert LineEditor.put("", @path, "true") == {:ok, "github:\n  webhooks:\n    enabled: true\n"}
    assert LineEditor.put("# only a comment", ["dashboard", "port"], "1") == {:ok, "# only a comment\ndashboard:\n  port: 1"}
  end

  test "refuses a section above the key that holds an inline value" do
    assert LineEditor.put(~s(github: {"webhooks": {"enabled": true}}\n), @path, "false") == {:error, {:not_a_block, "github"}}
  end

  describe "write/2" do
    setup do
      file = Path.join(System.tmp_dir!(), "line-editor-#{System.unique_integer([:positive])}.yml")
      on_exit(fn -> File.rm(file) end)
      %{yml: file}
    end

    test "rewrites the file whole, keeping its permissions", %{yml: file} do
      File.write!(file, "dashboard:\n  port: 4040\n")
      File.chmod!(file, 0o640)

      assert LineEditor.write(file, [{@path, "true"}, {["github", "webhooks", "secret"], "$SYMPHONY_GITHUB_WEBHOOK_SECRET"}]) == :ok

      assert YamlElixir.read_from_file!(file) == %{
               "dashboard" => %{"port" => 4040},
               "github" => %{"webhooks" => %{"enabled" => true, "secret" => "$SYMPHONY_GITHUB_WEBHOOK_SECRET"}}
             }

      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o640
      assert file |> Path.dirname() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "." <> Path.basename(file))) == []
    end

    test "leaves the file alone when nothing changes, or the result wouldn't hold the values", %{yml: file} do
      File.write!(file, "github:\n  webhooks:\n    enabled: true\n")
      %File.Stat{mtime: mtime} = File.stat!(file, time: :posix)

      assert LineEditor.write(file, [{@path, "true"}]) == :ok
      assert File.stat!(file, time: :posix).mtime == mtime

      assert {:error, {:unreadable, _reason}} = LineEditor.write(file, [{@path, "[unclosed"}])
      assert LineEditor.write(file, [{@path, "false"}, {@path, "1"}]) == {:error, {:not_written, "github.webhooks.enabled"}}
      assert File.read!(file) == "github:\n  webhooks:\n    enabled: true\n"
    end

    test "leaves no copy behind when its folder can't be written", %{yml: file} do
      dir = Path.join(Path.dirname(file), "locked-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      locked = Path.join(dir, "symphony.yml")
      File.write!(locked, "dashboard:\n  port: 4040\n")
      File.chmod!(dir, 0o500)

      on_exit(fn ->
        File.chmod(dir, 0o700)
        File.rm_rf(dir)
      end)

      assert LineEditor.write(locked, [{@path, "true"}]) == {:error, :eacces}
      assert File.ls!(dir) == ["symphony.yml"]
    end

    test "a later change that replaces a section holds no value at the earlier path", %{yml: file} do
      File.write!(file, "github: 1\n")
      assert LineEditor.write(file, [{["github"], "{}"}, {["github"], "2"}]) == {:error, {:not_written, "github"}}
    end

    test "reports a file it can't read or a section it can't edit", %{yml: file} do
      assert LineEditor.write(file, [{@path, "true"}]) == {:error, :enoent}

      File.write!(file, "github: {}\n")
      assert LineEditor.write(file, [{@path, "true"}]) == {:error, {:not_a_block, "github"}}
    end
  end
end
