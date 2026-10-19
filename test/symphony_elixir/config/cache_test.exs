defmodule SymphonyElixir.Config.CacheTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Workflow

  setup do
    original_symphony_path = Workflow.symphony_file_path()
    original_reader = Application.get_env(:symphony_elixir, :config_cache_file_reader)
    original_watch = Application.get_env(:symphony_elixir, :config_cache_watch)
    original_watcher = Application.get_env(:symphony_elixir, :config_cache_watcher)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cache-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    # Enable watch so file_event tests exercise the real GenServer plumbing.
    Application.put_env(:symphony_elixir, :config_cache_watch, true)
    # An earlier test in the shard may have stopped the app; these tests talk to
    # the supervised Cache process directly.
    SymphonyElixir.TestSupport.ensure_config_cache_started!()
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      Workflow.set_symphony_file_path(original_symphony_path)
      restore_env(:config_cache_file_reader, original_reader)
      restore_env(:config_cache_watch, original_watch)
      restore_env(:config_cache_watcher, original_watcher)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "status/0" do
    test "exposes cached entries with stale flag and last error", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, _value} = Cache.get_symphony(symphony_path)
      [entry] = Cache.status()
      assert entry.kind == :symphony
      assert entry.path == Path.expand(symphony_path)
      assert entry.stale? == false
      assert entry.last_error == nil
      assert is_integer(entry.updated_at)

      # Force a parse error -> stale fallback.
      File.write!(symphony_path, "tracker: [unterminated\n")
      bump_mtime!(symphony_path)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
      end)

      [entry] = Cache.status()
      assert entry.stale? == true
      refute entry.last_error == nil
    end
  end

  describe "a symphony.yml edit the schema rejects" do
    test "keeps the last good config, says since when, and reads the rejected file only once", %{root: root} do
      # No watcher: only this test's reads may read the file.
      Application.put_env(:symphony_elixir, :config_cache_watch, false)
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)

      test_pid = self()

      Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
        send(test_pid, {:read, path})
        File.read(path)
      end)

      File.write!(symphony_path, config(1) <> "pull_request:\n  enabled: true\n")
      bump_mtime!(symphony_path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"repositories" => [%{"key" => "r1"}]}, [stale: true]} = Cache.get_symphony(symphony_path)
          [entry] = Cache.status()
          assert entry.last_error == {:invalid_symphony_config, "unknown symphony.yml key `pull_request`"}
          assert is_integer(entry.stale_since)

          assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
          assert [%{stale_since: stale_since}] = Cache.status()
          assert stale_since == entry.stale_since
        end)

      assert log =~ "keeping last known good value"
      assert_received {:read, _path}
      refute_received {:read, _path}

      File.write!(symphony_path, config(2))
      bump_mtime!(symphony_path)
      assert {:ok, %{"repositories" => [%{"key" => "r2"}]}} = Cache.get_symphony(symphony_path)
      assert [%{stale?: false, stale_since: nil}] = Cache.status()
    end

    test "the good file coming back with its old stamp loads again", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      File.touch!(symphony_path, 1_700_000_000)
      assert {:ok, _value} = Cache.get_symphony(symphony_path)

      File.rm!(symphony_path)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
      end)

      File.write!(symphony_path, config(1))
      File.touch!(symphony_path, 1_700_000_000)
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
      assert [%{stale?: false}] = Cache.status()
    end
  end

  describe "telemetry on stale fallback" do
    test "emits [:symphony, :config, :cache, :stale] when reload fails", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, _value} = Cache.get_symphony(symphony_path)

      handler_id = "cache-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:symphony, :config, :cache, :stale],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      File.write!(symphony_path, "tracker: [unterminated\n")
      bump_mtime!(symphony_path)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
      end)

      assert_receive {:telemetry, %{count: 1}, metadata}
      assert metadata.kind == :symphony
      assert metadata.path == Path.expand(symphony_path)
      assert metadata.reason
    end
  end

  describe "file_event reload" do
    test "handle_info reloads cached entry when reload event arrives", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)

      # Write new contents that the cache must pick up only via the file_event
      # handler. We bump mtime so the stat-stamp differs from the cached entry.
      File.write!(symphony_path, config(2))
      bump_mtime!(symphony_path)

      cache = start_private_cache!()

      handler_id = "cache-reloaded-test-#{System.unique_integer([:positive])}"
      test_pid = self()
      :telemetry.attach(handler_id, Cache.reloaded_event(), fn _event, _measurements, metadata, _config -> send(test_pid, {:reloaded, metadata.path}) end, nil)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(cache, {:file_event, self(), {symphony_path, [:modified]}})
      :sys.get_state(cache)
      expanded = Path.expand(symphony_path)
      assert_received {:reloaded, ^expanded}

      # A file no cached entry reads is not a reload.
      notes = Path.join(root, "notes.txt")
      send(cache, {:file_event, self(), {notes, [:modified]}})
      :sys.get_state(cache)
      refute_received {:reloaded, ^notes}

      # Subsequent reads should see the new value via either the eager reload
      # (file_event branch) or the lazy stamp refresh.
      assert {:ok, %{"repositories" => [%{"key" => "r2"}]}} = Cache.get_symphony(symphony_path)
    end
  end

  describe "reload event without a watcher" do
    test "a read that finds an edit emits the reload once per change", %{root: root} do
      # As under the escript, which can't start the file watcher.
      Application.put_env(:symphony_elixir, :config_cache_watcher, fn _dir -> :ignore end)
      symphony_path = Path.expand(Path.join(root, "symphony.yml"))
      write_stamped!(symphony_path, config(1), 1)
      attach_reloaded!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
          :sys.get_state(Cache)
        end)

      assert log =~ "falling back to stat-based polling"
      # The first load is not a reload.
      refute_received {:reloaded, ^symphony_path}

      write_stamped!(symphony_path, config(2), 2)
      assert {:ok, %{"repositories" => [%{"key" => "r2"}]}} = Cache.get_symphony(symphony_path)
      assert {:ok, %{"repositories" => [%{"key" => "r2"}]}} = Cache.get_symphony(symphony_path)
      assert_received {:reloaded, ^symphony_path}
      refute_received {:reloaded, ^symphony_path}

      ExUnit.CaptureLog.capture_log(fn ->
        # A rejected edit, read twice.
        write_stamped!(symphony_path, config(2) <> "pull_request:\n  enabled: true\n", 3)
        assert {:ok, %{"repositories" => [%{"key" => "r2"}]}, [stale: true]} = Cache.get_symphony(symphony_path)
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
        assert_received {:reloaded, ^symphony_path}
        refute_received {:reloaded, ^symphony_path}

        # Another rejected edit.
        write_stamped!(symphony_path, config(2) <> "pull_request:\n  enabled: false\n", 4)
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
        assert_received {:reloaded, ^symphony_path}

        # The file gone, read twice.
        File.rm!(symphony_path)
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
        assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
        assert_received {:reloaded, ^symphony_path}
        refute_received {:reloaded, ^symphony_path}
      end)

      # The file fixed.
      write_stamped!(symphony_path, config(3), 5)
      assert {:ok, %{"repositories" => [%{"key" => "r3"}]}} = Cache.get_symphony(symphony_path)
      assert_received {:reloaded, ^symphony_path}
    end

    test "dropping a cached file is a reload, dropping one the cache never read is not", %{root: root} do
      symphony_path = Path.expand(Path.join(root, "symphony.yml"))
      File.write!(symphony_path, config(1))
      assert {:ok, _value} = Cache.get_symphony(symphony_path)
      attach_reloaded!()

      assert :ok = Cache.invalidate(symphony_path)
      assert_received {:reloaded, ^symphony_path}

      assert :ok = Cache.invalidate(symphony_path)
      refute_received {:reloaded, ^symphony_path}
    end
  end

  describe ":stop watcher cleanup" do
    test "does not retry unavailable watcher backend on every cache read", %{root: root} do
      # Not set as the node's config path: any process reading config would
      # then send the app's Cache to watch `dir` too, and that attempt could
      # reach the stub before this instance marks `dir` as stat-only.
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))

      test_pid = self()
      symphony_path = Path.expand(symphony_path)
      dir = Path.dirname(symphony_path)

      # Accept every dir: the app's Cache also calls this for any config read
      # on the node, and a stub that only matches `dir` would crash it. Tag
      # each attempt with the cache that made it, so only this instance's count.
      Application.put_env(:symphony_elixir, :config_cache_watcher, fn watched_dir ->
        send(test_pid, {:watch_attempt, self(), watched_dir})
        :ignore
      end)

      # A config file in another dir stands in for any other process that reads
      # config while this test runs.
      other_path = Path.join([root, "other", "symphony.yml"])
      File.mkdir_p!(Path.dirname(other_path))
      File.write!(other_path, config(0))
      other_dir = Path.dirname(other_path)

      cache = start_private_cache!()

      # Cast the watch requests a cache read sends, so each one reaches this
      # instance even after the first marked `dir` as stat-only.
      ExUnit.CaptureLog.capture_log(fn ->
        GenServer.cast(cache, {:watch, symphony_path})
        :sys.get_state(cache)

        GenServer.cast(cache, {:watch, other_path})
        :sys.get_state(cache)

        GenServer.cast(cache, {:watch, symphony_path})
        :sys.get_state(cache)
      end)

      # `:sys.get_state` above drains each cast, so every watch attempt has
      # already been delivered.
      assert_received {:watch_attempt, ^cache, ^dir}
      assert_received {:watch_attempt, ^cache, ^other_dir}
      refute_received {:watch_attempt, ^cache, ^dir}

      state = :sys.get_state(cache)
      refute Map.has_key?(state.watchers, dir)
    end

    test "drops watcher entry from state so the next access re-watches", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      cache = start_private_cache!()
      GenServer.cast(cache, {:watch, Path.expand(symphony_path)})

      state = :sys.get_state(cache)
      dir = Path.dirname(Path.expand(symphony_path))

      case Map.get(state.watchers, dir) do
        nil ->
          # FileSystem may not be available in this environment; nothing to assert.
          :ok

        watcher when is_pid(watcher) ->
          # Simulate the watcher sending its terminal :stop event.
          ExUnit.CaptureLog.capture_log(fn ->
            send(cache, {:file_event, watcher, :stop})
            :sys.get_state(cache)
          end)

          new_state = :sys.get_state(cache)
          refute Map.has_key?(new_state.watchers, dir)
      end
    end
  end

  describe "EXIT handler" do
    test "drops watcher when its process exits", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      cache = start_private_cache!()
      GenServer.cast(cache, {:watch, Path.expand(symphony_path)})

      state = :sys.get_state(cache)
      dir = Path.dirname(Path.expand(symphony_path))

      case Map.get(state.watchers, dir) do
        nil ->
          :ok

        watcher when is_pid(watcher) ->
          ExUnit.CaptureLog.capture_log(fn ->
            Process.exit(watcher, :kill)
            :sys.get_state(cache)
          end)

          new_state = :sys.get_state(cache)
          refute Map.has_key?(new_state.watchers, dir)
      end
    end
  end

  describe "workflow instruction files" do
    test "an edit to an instruction file alone reloads the workflow", %{root: root} do
      path = Path.join(root, "WORKFLOW.md")
      rules = Path.join(root, ".symphony/instructions/045-rules.md")
      File.write!(path, "Intro\n{% render \"playbook\" %}\n")
      File.mkdir_p!(Path.dirname(rules))
      File.write!(rules, "## First rules\n")

      assert {:ok, %{prompt: prompt}} = Cache.get_workflow(path)
      assert prompt =~ "## First rules"

      File.write!(rules, "## Second, longer rules\n")
      assert {:ok, %{prompt: prompt}} = Cache.get_workflow(path)
      assert prompt =~ "## Second, longer rules"
      assert {:ok, %{prompt: ^prompt}} = Cache.get_workflow(path)
    end
  end

  describe "missing file after warm cache" do
    test "returns last known good value when file disappears", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(7))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, %{"repositories" => [%{"key" => "r7"}]}} = Cache.get_symphony(symphony_path)

      File.rm!(symphony_path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"repositories" => [%{"key" => "r7"}]}, [stale: true]} = Cache.get_symphony(symphony_path)
        end)

      assert log =~ "keeping last known good value"
    end
  end

  describe "invalidate/1" do
    test "drops a symphony.yml rewritten in the same second with the same length", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(7))
      File.touch!(symphony_path, 1_700_000_000)
      assert {:ok, %{"repositories" => [%{"key" => "r7"}]}} = Cache.get_symphony(symphony_path)

      File.write!(symphony_path, config(8))
      File.touch!(symphony_path, 1_700_000_000)
      assert {:ok, %{"repositories" => [%{"key" => "r7"}]}} = Cache.get_symphony(symphony_path)

      assert Cache.invalidate(symphony_path) == :ok
      assert {:ok, %{"repositories" => [%{"key" => "r8"}]}} = Cache.get_symphony(symphony_path)
    end
  end

  describe "clear/0" do
    test "removes entries and watched-dir tracking", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, _} = Cache.get_symphony(symphony_path)
      refute Cache.status() == []

      assert :ok = Cache.clear()
      assert Cache.status() == []
    end
  end

  # The app's named Cache is a child of `SymphonyElixir.Supervisor`, which also
  # runs the orchestrator and other config readers. Other tests stop or restart
  # that supervisor's children, which can replace the named Cache mid-test
  # (TP-304, TP-382). An unnamed instance under the test supervisor lives
  # exactly as long as the test. Watch state is shared through
  # `:persistent_term`, which setup and `on_exit` clear.
  # Writes `content` with its own mtime, so each write is a new stamp even within one second.
  defp write_stamped!(path, content, n) do
    File.write!(path, content)
    File.touch!(path, 1_700_000_000 + n)
  end

  defp attach_reloaded! do
    handler_id = "cache-reloaded-test-#{System.unique_integer([:positive])}"
    test_pid = self()
    :telemetry.attach(handler_id, Cache.reloaded_event(), fn _event, _measurements, metadata, _config -> send(test_pid, {:reloaded, metadata.path}) end, nil)
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_private_cache! do
    start_supervised!({Cache, name: nil})
  end

  # The smallest `symphony.yml` that validates, its one repo keyed `r<n>`.
  defp config(n), do: "repositories:\n  - key: r#{n}\n    route:\n      team: T\n"

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp bump_mtime!(path) do
    # FAT/HFS+ mtime resolution is 1s. Sleep > 1s would make this brittle and
    # slow, so explicitly push the mtime forward instead.
    File.touch!(path, System.system_time(:second) + 2)
  end
end
