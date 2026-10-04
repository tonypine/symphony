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

    %{root: root, repo: Path.join(root, "repo"), git: fake_git!(root), server: server}
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
    wait_for_waiters(server, repo, 1)

    others = for _ <- 1..2, do: Task.async(fn -> Fetcher.fetch_origin(Path.join(repo, "."), server: server, git: git) end)
    wait_for_waiters(server, repo, 3)

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
    assert log =~ "git fetch origin could not lock a ref repo=#{repo}"
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

  defp wait_for_waiters(server, repo, count, attempts \\ 500) do
    case :sys.get_state(server) do
      %{^repo => {_ref, waiters}} when length(waiters) == count ->
        :ok

      _fetches when attempts > 0 ->
        Process.sleep(10)
        wait_for_waiters(server, repo, count, attempts - 1)
    end
  end
end
