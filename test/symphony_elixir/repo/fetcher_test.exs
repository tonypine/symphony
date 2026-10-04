defmodule SymphonyElixir.Repo.FetcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Repo.Fetcher

  @lock_error "error: cannot lock ref 'refs/remotes/origin/main': is at 784f59f4 but expected a2d3de89\n"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-elixir-fetcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    server = :"fetcher_test_#{System.unique_integer([:positive])}"
    start_supervised!({Fetcher, name: server})

    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))

    %{root: root, repo: repo, git: fake_git!(root), server: server}
  end

  test "fetches origin in the repo and returns git's output and status", %{root: root, repo: repo, git: git, server: server} do
    File.write!(Path.join(root, "out-1"), "From origin\n")

    assert Fetcher.fetch_origin(repo, server: server, git: git) == {"From origin\n", 0}
    assert [call] = calls(root)
    assert call =~ "-C #{repo} fetch origin"
  end

  test "a fetch asked for while one of the same repo runs waits for it and gets its result", %{
    root: root,
    repo: repo,
    git: git,
    server: server
  } do
    File.write!(Path.join(root, "gate"), "")
    File.write!(Path.join(root, "out-1"), "From origin\n")

    first = Task.async(fn -> Fetcher.fetch_origin(repo, server: server, git: git) end)
    key = key(repo)
    wait_for_state(server, &match?(%{^key => {{:fetch, _ref, [_first]}, []}}, &1))

    others = for _ <- 1..2, do: Task.async(fn -> Fetcher.fetch_origin(Path.join(repo, "."), server: server, git: git) end)
    wait_for_state(server, &match?(%{^key => {{:fetch, _ref, [_, _, _]}, []}}, &1))

    File.write!(Path.join(root, "release"), "")

    assert Enum.map([first | others], &Task.await(&1, 10_000)) == List.duplicate({"From origin\n", 0}, 3)
    assert length(calls(root)) == 1
    assert :sys.get_state(server) == %{}

    assert Fetcher.fetch_origin(repo, server: server, git: git) == {"", 0}
    assert length(calls(root)) == 2
  end

  test "a fetch that cannot lock a ref is run once more", %{root: root, repo: repo, git: git, server: server} do
    File.write!(Path.join(root, "out-1"), @lock_error)
    File.write!(Path.join(root, "status-1"), "1")

    log =
      capture_log(fn ->
        assert Fetcher.fetch_origin(repo, server: server, git: git, retry_delay_ms: 0) == {"", 0}
      end)

    assert length(calls(root)) == 2
    assert log =~ "git fetch could not lock a ref repo=#{repo}"
  end

  test "a fetch that still cannot lock a ref returns the retry's failure", %{root: root, repo: repo, git: git, server: server} do
    for n <- 1..3 do
      File.write!(Path.join(root, "out-#{n}"), @lock_error)
      File.write!(Path.join(root, "status-#{n}"), "1")
    end

    capture_log(fn ->
      assert Fetcher.fetch_origin(repo, server: server, git: git, retry_delay_ms: 0) == {@lock_error, 1}
    end)

    assert length(calls(root)) == 2
  end

  test "other fetch failures are not retried", %{root: root, repo: repo, git: git, server: server} do
    File.write!(Path.join(root, "out-1"), "fatal: Could not read from remote repository.\n")
    File.write!(Path.join(root, "status-1"), "128")

    assert Fetcher.fetch_origin(repo, server: server, git: git, retry_delay_ms: 0) ==
             {"fatal: Could not read from remote repository.\n", 128}

    assert length(calls(root)) == 1
  end

  test "a fetch that crashes exits its callers and leaves the server running", %{root: root, repo: repo, server: server} do
    missing_git = Path.join(root, "missing-git")

    capture_log(fn ->
      assert {:enoent, [{:erlang, :open_port, _args, _info} | _stacktrace]} =
               catch_exit(Fetcher.fetch_origin(repo, server: server, git: missing_git))
    end)

    assert :sys.get_state(server) == %{}
  end

  test "without the server the fetch runs in the caller", %{root: root, repo: repo, git: git} do
    assert Fetcher.fetch_origin(repo, server: :no_fetcher_running, git: git) == {"", 0}
    assert length(calls(root)) == 1
  end

  describe "the repo lock" do
    setup %{root: root, repo: repo} do
      worktree = Path.join(root, "worktree")
      gitdir = Path.join([repo, ".git", "worktrees", "worktree"])
      File.mkdir_p!(gitdir)
      File.write!(Path.join(gitdir, "commondir"), "../..\n")
      File.mkdir_p!(worktree)
      File.write!(Path.join(worktree, ".git"), "gitdir: #{gitdir}\n")

      %{worktree: worktree}
    end

    test "a targeted fetch in a worktree waits for a full fetch of its source checkout", %{
      root: root,
      repo: repo,
      worktree: worktree,
      git: git,
      server: server
    } do
      File.write!(Path.join(root, "gate"), "")
      full = Task.async(fn -> Fetcher.fetch_origin(repo, server: server, git: git) end)
      key = key(repo)
      wait_for_state(server, &match?(%{^key => {{:fetch, _ref, [_]}, []}}, &1))

      test_pid = self()

      fetch = fn ->
        send(test_pid, :targeted_fetch)
        {"fetched", 0}
      end

      targeted = Task.async(fn -> Fetcher.fetch(worktree, fetch, server: server) end)
      wait_for_state(server, &match?(%{^key => {{:fetch, _ref, [_]}, [{:lock, _from}]}}, &1))
      refute_received :targeted_fetch

      File.write!(Path.join(root, "release"), "")

      assert Task.await(full, 10_000) == {"", 0}
      assert Task.await(targeted, 10_000) == {"fetched", 0}
      assert_received :targeted_fetch
      assert :sys.get_state(server) == %{}
    end

    test "full fetches wait for a held lock and share the queued fetch", %{
      root: root,
      repo: repo,
      worktree: worktree,
      git: git,
      server: server
    } do
      key = key(repo)
      holder = hold_lock(worktree, server)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, []}}, &1))

      second = hold_lock(repo, server)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, [{:lock, _from}]}}, &1))

      fulls = for _ <- 1..2, do: Task.async(fn -> Fetcher.fetch_origin(repo, server: server, git: git) end)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, [{:lock, _from}, {:fetch, _fetch, [_, _]}]}}, &1))
      assert calls(root) == []

      release_lock(holder)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, [{:fetch, _fetch, [_, _]}]}}, &1))
      release_lock(second)

      assert Enum.map(fulls, &Task.await(&1, 10_000)) == [{"", 0}, {"", 0}]
      assert length(calls(root)) == 1
      assert :sys.get_state(server) == %{}
    end

    test "a caller that dies holding the lock hands it on", %{repo: repo, worktree: worktree, server: server} do
      holder = hold_lock(worktree, server)
      key = key(repo)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, []}}, &1))

      next = Task.async(fn -> Fetcher.fetch(worktree, fn -> {"next", 0} end, server: server) end)
      wait_for_state(server, &match?(%{^key => {{:lock, _ref}, [_next]}}, &1))

      Process.exit(holder, :kill)

      assert Task.await(next, 10_000) == {"next", 0}
      assert :sys.get_state(server) == %{}
    end

    test "a targeted fetch that raises releases the lock", %{worktree: worktree, server: server} do
      assert_raise RuntimeError, "boom", fn -> Fetcher.fetch(worktree, fn -> raise "boom" end, server: server) end
      assert :sys.get_state(server) == %{}
    end

    test "a gitdir without a commondir, and a dir that is no checkout, are their own repos", %{root: root, server: server} do
      submodule = Path.join(root, "submodule")
      modules = Path.join(root, "modules/sub")
      File.mkdir_p!(submodule)
      File.mkdir_p!(modules)
      File.write!(Path.join(submodule, ".git"), "gitdir: ../modules/sub\n")
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      holders = for dir <- [submodule, plain], do: hold_lock(dir, server)
      [modules_key, plain_key] = Enum.map([modules, plain], &canonical/1)
      wait_for_state(server, &match?(%{^modules_key => {{:lock, _}, []}, ^plain_key => {{:lock, _}, []}}, &1))

      Enum.each(holders, &release_lock/1)
      wait_for_state(server, &(&1 == %{}))
    end

    test "a path it cannot resolve is keyed as given", %{root: root, server: server} do
      locked = Path.join(root, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)
      dir = Path.join(locked, "repo")

      holder = hold_lock(dir, server)
      wait_for_state(server, &match?(%{^dir => {{:lock, _ref}, []}}, &1))

      release_lock(holder)
      wait_for_state(server, &(&1 == %{}))
    end
  end

  describe "a targeted fetch" do
    test "runs in the caller under the lock and returns the fetch's result", %{repo: repo, server: server} do
      assert Fetcher.fetch(repo, fn -> {self(), 0} end, server: server) == {self(), 0}
      assert Fetcher.fetch(repo, fn -> {:ok, "fetched"} end, server: server) == {:ok, "fetched"}
    end

    test "is run once more after cannot lock ref, without waiting by default", %{repo: repo, server: server} do
      {:ok, attempts} = Agent.start_link(fn -> [{@lock_error, 1}, {"", 0}] end)
      fetch = fn -> Agent.get_and_update(attempts, fn [result | rest] -> {result, rest} end) end

      log = capture_log(fn -> assert Fetcher.fetch(repo, fetch, server: server) == {"", 0} end)

      assert Agent.get(attempts, & &1) == []
      assert log =~ "git fetch could not lock a ref repo=#{repo}"
    end

    test "other failures are returned as they are", %{repo: repo, server: server} do
      assert Fetcher.fetch(repo, fn -> {"fatal: no remote\n", 128} end, server: server) == {"fatal: no remote\n", 128}
    end

    test "without the server it runs unlocked in the caller", %{repo: repo} do
      assert Fetcher.fetch(repo, fn -> {"", 0} end, server: :no_fetcher_running) == {"", 0}
    end
  end

  describe "remote_fetch_origin_script/0" do
    setup %{root: root, git: git} do
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      File.cp!(git, Path.join(bin, "git"))
      %{bin: bin}
    end

    test "fetches origin in $repo", %{root: root, repo: repo, bin: bin} do
      assert {_output, 0} = run_remote_script(bin, repo)
      assert calls(root) == ["-C #{repo} fetch origin"]
    end

    test "runs the fetch once more after cannot lock ref", %{root: root, repo: repo, bin: bin} do
      File.write!(Path.join(root, "out-1"), @lock_error)
      File.write!(Path.join(root, "status-1"), "1")

      assert {output, 0} = run_remote_script(bin, repo)
      assert output =~ "cannot lock ref"
      assert length(calls(root)) == 2
    end

    test "exits with the status of a fetch that fails otherwise", %{root: root, repo: repo, bin: bin} do
      File.write!(Path.join(root, "out-1"), "fatal: no remote\n")
      File.write!(Path.join(root, "status-1"), "128")

      assert {"fatal: no remote\n", 128} = run_remote_script(bin, repo)
      assert length(calls(root)) == 1
    end
  end

  defp run_remote_script(bin, repo) do
    script = Enum.join(["set -eu", "repo=#{repo}", Fetcher.remote_fetch_origin_script()], "\n")
    System.cmd("sh", ["-c", script], env: [{"PATH", bin <> ":" <> System.get_env("PATH")}], stderr_to_stdout: true)
  end

  defp hold_lock(dir, server) do
    spawn(fn ->
      Fetcher.fetch(
        dir,
        fn ->
          receive do
            :release -> {"", 0}
          end
        end,
        server: server
      )
    end)
  end

  defp release_lock(holder), do: send(holder, :release)

  defp key(checkout), do: canonical(Path.join(checkout, ".git"))

  defp canonical(path) do
    {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(path)
    canonical
  end

  defp fake_git!(root) do
    git = Path.join(root, "fake-git")

    File.write!(git, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{root}/calls"
    n=$(wc -l < "#{root}/calls" | tr -d ' ')
    if [ -f "#{root}/gate" ]; then
      i=0
      while [ ! -f "#{root}/release" ] && [ "$i" -lt 500 ]; do
        sleep 0.02
        i=$((i + 1))
      done
    fi
    if [ -f "#{root}/out-$n" ]; then cat "#{root}/out-$n"; fi
    if [ -f "#{root}/status-$n" ]; then exit "$(cat "#{root}/status-$n")"; fi
    exit 0
    """)

    File.chmod!(git, 0o755)
    git
  end

  defp calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp wait_for_state(server, done?, attempts \\ 500) do
    state = :sys.get_state(server)

    cond do
      done?.(state) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_for_state(server, done?, attempts - 1)

      true ->
        flunk("the fetcher never reached the expected state: #{inspect(state)}")
    end
  end
end
