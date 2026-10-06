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
      File.write!(symphony_path, "tracker:\n  kind: memory\n")
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

  describe "telemetry on stale fallback" do
    test "emits [:symphony, :config, :cache, :stale] when reload fails", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, "tracker:\n  kind: memory\n")
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
      File.write!(symphony_path, "tracker:\n  kind: memory\nfoo: 1\n")
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, %{"foo" => 1}} = Cache.get_symphony(symphony_path)

      # Write new contents that the cache must pick up only via the file_event
      # handler. We bump mtime so the stat-stamp differs from the cached entry.
      File.write!(symphony_path, "tracker:\n  kind: memory\nfoo: 2\n")
      bump_mtime!(symphony_path)

      cache = start_private_cache!()

      send(cache, {:file_event, self(), {symphony_path, [:modified]}})
      :sys.get_state(cache)

      # Subsequent reads should see the new value via either the eager reload
      # (file_event branch) or the lazy stamp refresh.
      assert {:ok, %{"foo" => 2}} = Cache.get_symphony(symphony_path)
    end
  end

  describe ":stop watcher cleanup" do
    test "does not retry unavailable watcher backend on every cache read", %{root: root} do
      # Not set as the node's config path: any process reading config would
      # then send the app's Cache to watch `dir` too, and that attempt could
      # reach the stub before this instance marks `dir` as stat-only.
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, "tracker:\n  kind: memory\n")

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
      File.write!(other_path, "tracker:\n  kind: memory\n")
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
      File.write!(symphony_path, "tracker:\n  kind: memory\n")
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
      File.write!(symphony_path, "tracker:\n  kind: memory\n")
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

  describe "missing file after warm cache" do
    test "returns last known good value when file disappears", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, "tracker:\n  kind: memory\nfoo: 7\n")
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, %{"foo" => 7}} = Cache.get_symphony(symphony_path)

      File.rm!(symphony_path)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"foo" => 7}, [stale: true]} = Cache.get_symphony(symphony_path)
        end)

      assert log =~ "keeping last known good value"
    end
  end

  describe "clear/0" do
    test "removes entries and watched-dir tracking", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, "tracker:\n  kind: memory\n")
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
  defp start_private_cache! do
    start_supervised!({Cache, name: nil})
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp bump_mtime!(path) do
    # FAT/HFS+ mtime resolution is 1s. Sleep > 1s would make this brittle and
    # slow, so explicitly push the mtime forward instead.
    File.touch!(path, System.system_time(:second) + 2)
  end
end
