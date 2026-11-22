defmodule SymphonyElixir.Config.CacheTest do
  use ExUnit.Case

  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Workflow

  setup do
    original_symphony_path = Workflow.symphony_file_path()
    original_reader = Application.get_env(:symphony_elixir, :config_cache_file_reader)
    original_watcher = Application.get_env(:symphony_elixir, :config_cache_watcher)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-cache-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    # An earlier test in the shard may have stopped the app; these tests talk to
    # the supervised Cache process directly.
    SymphonyElixir.TestSupport.ensure_config_cache_started!()
    Cache.clear()
    # The cache is global to the node, and any process may read config while a
    # test runs (the app's own, with the repo's WORKFLOW.md). A file of its own
    # stands in for that reader, so a test that asserts on the whole cache
    # instead of its own entry fails every run, not some (TP-1153).
    bystander = Path.join([root, "bystander", "symphony.yml"])
    File.mkdir_p!(Path.dirname(bystander))
    File.write!(bystander, config(9))
    assert {:ok, _value} = Cache.get_symphony(bystander)

    on_exit(fn ->
      Cache.clear()
      Workflow.set_symphony_file_path(original_symphony_path)
      restore_env(:config_cache_file_reader, original_reader)
      restore_env(:config_cache_watcher, original_watcher)
      File.rm_rf(root)
    end)

    {:ok, root: root, bystander: bystander}
  end

  describe "status/0" do
    test "exposes cached entries with stale flag and last error", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))
      Workflow.set_symphony_file_path(symphony_path)

      assert {:ok, _value} = Cache.get_symphony(symphony_path)
      entry = status_entry(symphony_path)
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

      entry = status_entry(symphony_path)
      assert entry.stale? == true
      refute entry.last_error == nil
    end
  end

  describe "clear/0 after two reads at once" do
    test "drops an entry the index lost", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      assert {:ok, _value} = Cache.get_symphony(symphony_path)
      key = {Cache, :symphony, Path.expand(symphony_path)}

      # The other read put the index back from a copy taken before this entry was added.
      index = :persistent_term.get({Cache, :index})
      :persistent_term.put({Cache, :index}, MapSet.delete(index, key))

      assert :ok = Cache.clear()
      assert :persistent_term.get(key, nil) == nil
    end
  end

  describe "a rejected reload that a clear overtakes" do
    test "returns the last good config but leaves the cleared cache empty", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)

      File.write!(symphony_path, "tracker: [unterminated\n")
      bump_mtime!(symphony_path)

      # The entry is dropped while the reload reads the rejected file, as a test's rewrite clears it.
      Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
        Cache.invalidate(path)
        File.read(path)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{"repositories" => [%{"key" => "r1"}]}, [stale: true]} = Cache.get_symphony(symphony_path)
      end)

      assert :persistent_term.get({Cache, :symphony, Path.expand(symphony_path)}, nil) == nil

      Application.delete_env(:symphony_elixir, :config_cache_file_reader)
      assert {:error, _reason} = Cache.get_symphony(symphony_path)
    end
  end

  describe "a good load that a clear overtakes" do
    test "returns what it read but leaves the cleared cache empty", %{root: root} do
      on_exit(fn -> Application.delete_env(:symphony_elixir, :config_cache_file_reader) end)
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      key = {Cache, :symphony, Path.expand(symphony_path)}

      # A test rewrites the file and clears the cache while this read has the old file in hand: the
      # read must not cache the file the clear dropped, or the next read serves it as the last good one.
      Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
        content = File.read(path)
        Cache.clear()
        content
      end)

      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
      assert :persistent_term.get(key, nil) == nil

      # The same for an invalidate.
      Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
        content = File.read(path)
        Cache.invalidate(path)
        content
      end)

      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
      assert :persistent_term.get(key, nil) == nil

      # With nothing in between, the load is cached.
      Application.delete_env(:symphony_elixir, :config_cache_file_reader)
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
      assert %Cache.Entry{} = :persistent_term.get(key, nil)
    end
  end

  describe "a symphony.yml edit the schema rejects" do
    test "keeps the last good config, says since when, and reads the rejected file only once", %{root: root} do
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(1))
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)

      test_pid = self()

      # The read that finds the file rejected marks its stamp, so the next call reads nothing.
      Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
        send(test_pid, {:read, path, self()})
        File.read(path)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Written inside the capture: a refresh on the file's event logs the rejection too.
          File.write!(symphony_path, config(1) <> "pull_request:\n  enabled: true\n")
          bump_mtime!(symphony_path)

          assert {:ok, %{"repositories" => [%{"key" => "r1"}]}, [stale: true]} = Cache.get_symphony(symphony_path)
          entry = status_entry(symphony_path)
          assert entry.last_error == {:invalid_symphony_config, "unknown symphony.yml key `pull_request`"}
          assert is_integer(entry.stale_since)
          assert_received {:read, _path, _reader}

          assert {:ok, _value, [stale: true]} = Cache.get_symphony(symphony_path)
          refute_received {:read, _path, ^test_pid}
          assert %{stale_since: stale_since} = status_entry(symphony_path)
          assert stale_since == entry.stale_since
        end)

      assert log =~ "keeping last known good value"

      File.write!(symphony_path, config(2))
      bump_mtime!(symphony_path)
      assert {:ok, %{"repositories" => [%{"key" => "r2"}]}} = Cache.get_symphony(symphony_path)
      assert %{stale?: false, stale_since: nil} = status_entry(symphony_path)
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
      assert %{stale?: false} = status_entry(symphony_path)
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
      # As for any folder the app does not watch, and under the escript, which can't start one.
      symphony_path = Path.expand(Path.join(root, "symphony.yml"))
      write_stamped!(symphony_path, config(1), 1)
      attach_reloaded!()

      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)
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

  describe "watchers" do
    test "a read starts no watcher", %{root: root} do
      stub_watcher!()
      symphony_path = Path.join(root, "symphony.yml")
      File.write!(symphony_path, config(0))

      assert {:ok, _value} = Cache.get_symphony(symphony_path)
      assert {:ok, _value} = Cache.get_symphony(symphony_path)

      assert Cache.watched_dirs() == []
      refute_received {:watch_attempt, _cache, _dir}
    end

    test "starts one watcher per folder it is given, never on a repository root", %{root: root} do
      stub_watcher!()
      dir = Path.join(root, "config")
      repo = Path.join(root, "repo")
      File.mkdir_p!(dir)
      File.mkdir_p!(Path.join(repo, ".git"))

      cache = start_supervised!({Cache, name: nil, watch: [dir, dir <> "/", repo, Path.join(root, "missing")]})
      assert Cache.watched_dirs(cache) == [Path.expand(dir)]
      assert_received {:watch_attempt, ^cache, _dir}
      refute_received {:watch_attempt, ^cache, _dir}

      assert Cache.watch(cache, dir) == :ok
      assert Cache.watch(cache, repo) == {:error, :repository_root}
      assert Cache.watch(cache, Path.join(root, "missing")) == {:error, :enoent}
      refute_received {:watch_attempt, ^cache, _dir}
    end

    test "a folder the backend can't watch is checked by stamp", %{root: root} do
      ignored = Path.join(root, "ignored")
      File.mkdir_p!(ignored)

      Application.put_env(:symphony_elixir, :config_cache_watcher, fn dir ->
        if Path.basename(dir) == "ignored", do: :ignore, else: {:error, {:failed, dir}}
      end)

      cache = start_private_cache!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Cache.watch(cache, root) == {:error, {:failed, Path.expand(root)}}
          assert Cache.watch(cache, ignored) == {:error, :unavailable}
        end)

      assert log =~ "Failed to watch config directory"
      assert log =~ "Config watcher unavailable"
      assert Cache.watched_dirs(cache) == []
    end

    test "a watcher that stops or exits is dropped", %{root: root} do
      stub_watcher!()
      first = Path.join(root, "first")
      second = Path.join(root, "second")
      File.mkdir_p!(first)
      File.mkdir_p!(second)
      cache = start_supervised!({Cache, name: nil, watch: [first, second]})
      %{watchers: %{^first => first_watcher, ^second => second_watcher}} = :sys.get_state(cache)

      ExUnit.CaptureLog.capture_log(fn ->
        send(cache, {:file_event, first_watcher, :stop})
        Process.exit(second_watcher, :kill)
        send(cache, {:file_event, self(), :stop})
        :sys.get_state(cache)
      end)

      assert Cache.watched_dirs(cache) == []
    end

    test "the watchers stop with the cache", %{root: root} do
      stub_watcher!()
      cache = start_supervised!({Cache, name: nil, watch: [root]})
      %{watchers: %{} = watchers} = :sys.get_state(cache)
      [watcher] = Map.values(watchers)
      ref = Process.monitor(watcher)

      stop_supervised!(Cache)
      assert_receive {:DOWN, ^ref, :process, ^watcher, :shutdown}
    end

    # The one test that starts the real file watcher: on its own small folder, stopped with the
    # cache when the test ends. An edit there reloads the cached file without a read.
    test "an edit in a watched folder reloads the file", %{root: root} do
      dir = Path.join(root, "watched")
      File.mkdir_p!(dir)
      symphony_path = Path.expand(Path.join(dir, "symphony.yml"))
      File.write!(symphony_path, config(1))
      assert {:ok, %{"repositories" => [%{"key" => "r1"}]}} = Cache.get_symphony(symphony_path)

      cache = start_private_cache!()

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> Cache.watch(cache, dir) end)

      case result do
        :ok ->
          attach_reloaded!()
          File.write!(symphony_path, config(2))
          bump_mtime!(symphony_path)
          assert_receive {:reloaded, ^symphony_path}, 10_000

        # No file events backend on this host (no inotify-tools on Linux): nothing to watch with.
        {:error, _reason} ->
          :ok
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
    test "removes entries", %{root: root, bystander: bystander} do
      symphony_path = Path.join(root, "symphony.yml")
      # Not set as the node's config path: another config reader would load it
      # again right after the clear.
      File.write!(symphony_path, config(0))

      assert {:ok, _} = Cache.get_symphony(symphony_path)
      assert status_entry(symphony_path)
      assert status_entry(bystander)

      assert :ok = Cache.clear()
      refute status_entry(symphony_path)
      refute status_entry(bystander)
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

  # The cached `symphony.yml` entry for `path`, or nil.
  defp status_entry(path) do
    expanded = Path.expand(path)
    Enum.find(Cache.status(), &(&1.kind == :symphony and &1.path == expanded))
  end

  defp attach_reloaded! do
    handler_id = "cache-reloaded-test-#{System.unique_integer([:positive])}"
    test_pid = self()
    :telemetry.attach(handler_id, Cache.reloaded_event(), fn _event, _measurements, metadata, _config -> send(test_pid, {:reloaded, metadata.path}) end, nil)
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Every watcher this test starts is a process of its own, linked as the real one is; each attempt is
  # reported with the cache that made it.
  defp stub_watcher! do
    test_pid = self()

    Application.put_env(:symphony_elixir, :config_cache_watcher, fn dir ->
      send(test_pid, {:watch_attempt, self(), dir})
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end)

    test_pid
  end

  defp start_private_cache! do
    start_supervised!({Cache, name: nil})
  end

  # The smallest `symphony.yml` that validates, its one repo keyed `r<n>`.
  @runs "execution:\n  harnesses:\n    codex:\n      command: codex app-server\nruns:\n  default: {harness: codex, provider: openai, model: gpt-test}\n"
  defp config(n), do: "repositories:\n  - key: r#{n}\n    route:\n      team: T\n" <> @runs

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp bump_mtime!(path) do
    # FAT/HFS+ mtime resolution is 1s. Sleep > 1s would make this brittle and
    # slow, so explicitly push the mtime forward instead.
    File.touch!(path, System.system_time(:second) + 2)
  end
end
