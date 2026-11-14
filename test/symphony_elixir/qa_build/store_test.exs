defmodule SymphonyElixir.QaBuild.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.QaBuild.Store
  alias SymphonyElixir.QaDriver.Host

  @app "build/Demo.app"
  @qa_vm "99999999-8888-7777-6666-555544443333"
  @symphony_mac "1A2B3C4D-0000-1111-2222-333344445555"
  # Writes the bundle, and says whether the checkout still held what the last build left.
  @build ~s(if [ -f .cache ]; then echo incremental; else echo clean; fi > built.log; : > .cache; mkdir -p build/Demo.app/Contents && cp app.txt build/Demo.app/Contents/app.txt)

  setup do
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "qa-build-store-test-#{System.unique_integer([:positive])}")
    home = Path.join(root, "qa-home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(root) end)

    git!(repo, ["init", "--quiet"])
    first = commit!(repo, %{"app.txt" => "one\n", "kept.txt" => "kept\n", "gone.txt" => "gone\n"}, [])
    %{home: home, repo: repo, first: first}
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp commit!(repo, files, removed) do
    for {name, content} <- files, do: File.write!(Path.join(repo, name), content)
    for name <- removed, do: File.rm!(Path.join(repo, name))
    git!(repo, ["add", "--all"])
    git!(repo, ["commit", "--quiet", "-m", "change"])
    %{sha: git!(repo, ["rev-parse", "HEAD"]), tree: git!(repo, ["rev-parse", "HEAD^{tree}"])}
  end

  # A fake QA VM whose home is a temporary directory: the store script runs there for real, the
  # run directory is a real `runs/run.*` folder, and `ioreg` names another machine than this one.
  defp host(home, overrides) do
    test = self()

    cmd = fn
      "/usr/sbin/ioreg", _args, _opts ->
        Map.get(overrides, :ioreg, ioreg(@qa_vm))

      executable, args, opts ->
        send(test, {:cmd, args, opts})
        run = fn -> Host.cmd(executable, args, [env: [{~c"HOME", String.to_charlist(home)}]] ++ Keyword.take(opts, [:cd, :timeout_ms, :output_limit])) end
        Map.get(overrides, :cmd, fn _args, run -> run.() end).(args, run)
    end

    %{
      cmd: cmd,
      prepare:
        Map.get(overrides, :prepare, fn _operator_home, _canary ->
          dir = Path.join(home, ".symphony-qa/runs/run.#{System.unique_integer([:positive])}")
          File.mkdir_p!(dir)
          send(test, {:run_dir, dir})
          {:ok, dir}
        end),
      ship:
        Map.get(overrides, :ship, fn tar, dest ->
          File.rm_rf!(dest)
          File.mkdir_p!(dest)
          :ok = :erl_tar.extract(String.to_charlist(tar), cwd: String.to_charlist(dest))
        end),
      cleanup: fn dir ->
        send(test, {:cleaned, dir})
        File.rm_rf!(dir)
        :ok
      end
    }
  end

  defp ioreg(uuid), do: {:ok, {~s(    "IOPlatformUUID" = "#{uuid}"\n), 0}}

  defp job(ctx, commit, overrides) do
    plan = Map.merge(%{worker_host: "qa-vm", build: @build, app: @app, build_timeout_ms: 60_000}, Map.get(overrides, :plan, %{}))
    Map.merge(%{repo_key: "demo", tree: commit.tree, sha: commit.sha, workspace: ctx.repo, plan: plan}, Map.delete(overrides, :plan))
  end

  defp build(ctx, commit, overrides \\ %{}, host_overrides \\ %{}) do
    Store.build(job(ctx, commit, overrides), host: fn "qa-vm" -> host(ctx.home, host_overrides) end, local_uuid: fn -> {:ok, @symphony_mac} end)
  end

  defp store(ctx), do: Path.join(ctx.home, ".symphony-qa/store/demo")

  test "builds the commit in the kept checkout and stores the app under its tree", ctx do
    log = capture_log(fn -> assert {:ready, _app} = build(ctx, ctx.first) end)
    assert log =~ "QA build runs on worker_host=qa-vm"

    assert {:ready, app} = build(ctx, ctx.first)
    assert app == Path.join(store(ctx), "builds/#{ctx.first.tree}/Demo.app")
    assert File.read!(Path.join(app, "Contents/app.txt")) == "one\n"
    assert File.exists?(Path.join(store(ctx), "builds/#{ctx.first.tree}/.complete"))
    assert File.read!(Path.join(store(ctx), "work/kept.txt")) == "kept\n"

    # The build ran in `work/` (its log is there), with the playbook's timeout, no pid file is left
    # and the run directory is gone.
    assert_received {:cmd, ["-c", _script, "sh", "build", "demo", @build], opts}
    assert opts[:timeout_ms] == 60_000
    assert File.exists?(Path.join(store(ctx), "work/built.log"))
    refute File.exists?(Path.join(store(ctx), "build.pid"))
    assert_received {:run_dir, dir}
    assert_received {:cleaned, ^dir}
    refute File.exists?(dir)
  end

  test "the next commit touches only the files that changed and keeps what the build left", ctx do
    assert {:ready, _app} = build(ctx, ctx.first)
    work = Path.join(store(ctx), "work")
    assert File.read!(Path.join(work, "built.log")) == "clean\n"
    File.touch!(Path.join(work, "kept.txt"), {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(Path.join(work, "app.txt"), {{2020, 1, 1}, {0, 0, 0}})

    second = commit!(ctx.repo, %{"app.txt" => "two\n", "new.txt" => "new\n"}, ["gone.txt"])
    assert {:ready, app} = build(ctx, second)

    assert File.read!(Path.join(app, "Contents/app.txt")) == "two\n"
    assert File.read!(Path.join(work, "built.log")) == "incremental\n"
    assert File.read!(Path.join(work, "new.txt")) == "new\n"
    refute File.exists?(Path.join(work, "gone.txt"))
    # The unchanged file was not written, the changed one was.
    assert File.stat!(Path.join(work, "kept.txt")).mtime == {{2020, 1, 1}, {0, 0, 0}}
    refute File.stat!(Path.join(work, "app.txt")).mtime == {{2020, 1, 1}, {0, 0, 0}}
    # Both trees are stored.
    assert File.exists?(Path.join(store(ctx), "builds/#{ctx.first.tree}/.complete"))
    assert File.exists?(Path.join(store(ctx), "builds/#{second.tree}/.complete"))
  end

  test "keeps the newest five trees", ctx do
    builds = Path.join(store(ctx), "builds")

    for n <- 1..6 do
      old = Path.join(builds, String.duplicate("#{n}", 40))
      File.mkdir_p!(old)
      File.touch!(old, {{2020, 1, n}, {0, 0, 0}})
    end

    File.mkdir_p!(Path.join(builds, "not-a-tree"))
    File.touch!(Path.join(builds, "not-a-tree"), {{2019, 1, 1}, {0, 0, 0}})

    assert {:ready, _app} = build(ctx, ctx.first)

    kept = builds |> File.ls!() |> Enum.sort()
    assert kept == Enum.sort([ctx.first.tree, "not-a-tree" | for(n <- 3..6, do: String.duplicate("#{n}", 40))])
  end

  test "a build command that exits non-zero is a failed build, with the end of its output", ctx do
    assert {:failed, 3, output} = build(ctx, ctx.first, %{plan: %{build: "echo 'error: no such module'; exit 3"}})
    assert output == "error: no such module\n"
    refute File.exists?(Path.join(store(ctx), "builds/#{ctx.first.tree}"))
    assert_received {:cleaned, _dir}

    long = "printf '%05000d' 0; exit 1"
    assert {:failed, 1, "…" <> tail} = build(ctx, ctx.first, %{plan: %{build: long}})
    assert byte_size(tail) == 4_000
  end

  test "a build that timed out is killed on the QA host, and one that could not start is unavailable", ctx do
    fail = fn reason ->
      fn
        ["-c", _script, "sh", "build" | _rest], _run -> {:error, reason}
        _args, run -> run.()
      end
    end

    assert {:unavailable, "the build did not finish within 60000 ms"} = build(ctx, ctx.first, %{}, %{cmd: fail.(:timeout)})
    assert_received {:cmd, ["-c", _script, "sh", "cancel", "demo"], _opts}
    assert {:unavailable, "the build command could not start: :enoent"} = build(ctx, ctx.first, %{}, %{cmd: fail.(:enoent)})
    refute_received {:cmd, ["-c", _script, "sh", "cancel", "demo"], _opts}

    # The script itself refused to run it, or ended without its exit line.
    refused = fn
      ["-c", _script, "sh", "build" | _rest], _run -> {:ok, {"cd: no such directory\n", 1}}
      _args, run -> run.()
    end

    assert {:unavailable, "the build could not start on the QA host (exit 1): cd: no such directory"} = build(ctx, ctx.first, %{}, %{cmd: refused})

    cut = fn
      ["-c", _script, "sh", "build" | _rest], _run -> {:ok, {"compiling\n", 0}}
      _args, run -> run.()
    end

    assert {:unavailable, "the build ended on the QA host without saying how: compiling"} = build(ctx, ctx.first, %{}, %{cmd: cut})
  end

  # A process group as a build leaves it: its leader's pid, which `build.pid` names with its start
  # time.
  defp leftover_build!(ctx) do
    File.mkdir_p!(store(ctx))
    group = ~S|perl -e 'setpgrp(0, 0); exec @ARGV' /bin/sh -c 'sleep 60; sleep 60' > /dev/null 2>&1 & echo $!|
    {output, 0} = System.cmd("/bin/sh", ["-c", group])
    pid = String.trim(output)
    on_exit(fn -> System.cmd("/bin/sh", ["-c", "kill -s KILL -- -#{pid} 2>/dev/null; true"]) end)
    {started, 0} = System.cmd("/bin/sh", ["-c", "set -- $(ps -o lstart= -p #{pid}); echo \"$*\""])
    File.write!(Path.join(store(ctx), "build.pid"), "#{pid} #{String.trim(started)}\n")
    pid
  end

  defp running?(pid), do: match?({_output, 0}, System.cmd("/bin/sh", ["-c", "kill -0 -- -#{pid} 2>/dev/null"]))

  test "a build still running in the checkout is killed before the next one touches it", ctx do
    pid = leftover_build!(ctx)
    assert running?(pid)

    assert {:ready, _app} = build(ctx, ctx.first)
    refute running?(pid)
    refute File.exists?(Path.join(store(ctx), "build.pid"))
  end

  test "a pid file whose process is gone, or another process now, kills nothing", ctx do
    pid = leftover_build!(ctx)
    File.write!(Path.join(store(ctx), "build.pid"), "#{pid} Mon Jan  1 00:00:00 2001\n")
    assert {:ready, _app} = build(ctx, ctx.first)
    assert running?(pid)

    File.write!(Path.join(store(ctx), "build.pid"), "not-a-pid\n")
    assert {:ready, _app} = build(ctx, ctx.first)
    refute File.exists?(Path.join(store(ctx), "build.pid"))
  end

  test "cancel/3 kills the running build's whole process group on the QA host", ctx do
    host = fn "qa-vm" -> host(ctx.home, %{}) end
    slow = "sleep 30 & sleep 31; echo late"
    builder = Task.async(fn -> Store.build(job(ctx, ctx.first, %{plan: %{build: slow}}), host: host, local_uuid: fn -> {:ok, @symphony_mac} end) end)

    pid_file = Path.join(store(ctx), "build.pid")
    wait_until(fn -> File.exists?(pid_file) end)
    [pid | _started] = pid_file |> File.read!() |> String.split(" ", parts: 2)
    assert running?(pid)

    plan = %{worker_host: "qa-vm", build: slow, app: @app, build_timeout_ms: 60_000}
    assert :ok = Store.cancel("demo", plan, host: host)
    refute running?(pid)
    assert {:failed, 143, _output} = Task.await(builder, 10_000)
    refute File.exists?(pid_file)

    # Nothing running: nothing to kill. A QA host that does not answer says so.
    assert :ok = Store.cancel("demo", plan, host: host)

    down = fn "qa-vm" -> host(ctx.home, %{cmd: fn _args, _run -> {:error, :closed} end}) end
    assert {:unavailable, "the QA host could not stop the build: :closed"} = Store.cancel("demo", plan, host: down)
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(fun, attempts - 1)
    end
  end

  test "a QA host Symphony refuses builds nothing", ctx do
    log =
      capture_log(fn ->
        assert {:unavailable, "qa_worker_same_machine: " <> _message} = build(ctx, ctx.first, %{}, %{ioreg: ioreg(@symphony_mac)})
      end)

    assert log =~ "QA build refused worker_host=qa-vm: it is the Symphony host"
    refute_received {:cmd, _args, _opts}
    refute File.exists?(store(ctx))
  end

  test "a commit that can't be archived or copied is unavailable", ctx do
    missing = %{sha: String.duplicate("0", 40), tree: String.duplicate("1", 40)}
    assert {:unavailable, "git archive of " <> _reason} = build(ctx, missing)
    assert_received {:cleaned, _dir}

    assert {:unavailable, "the commit could not be copied to the QA host: exit 1: no space"} =
             build(ctx, ctx.first, %{}, %{ship: fn _tar, _dest -> {:error, "exit 1: no space"} end})
  end

  test "the store script works in the repository's store folder only", ctx do
    assert {:unavailable, "the QA host could not bring the checkout to the commit (exit 2): invalid repo key"} =
             build(ctx, ctx.first, %{repo_key: "../escape"})

    refute File.exists?(Path.join(ctx.home, ".symphony-qa/store"))

    # A source folder outside a run directory is refused.
    outside = fn _operator_home, _canary -> {:ok, Path.join(ctx.home, "elsewhere") |> tap(&File.mkdir_p!/1)} end
    assert {:unavailable, reason} = build(ctx, ctx.first, %{}, %{prepare: outside})
    assert reason =~ "is not in a run directory"

    assert {:unavailable, "the QA host could not store the built app (exit 2): invalid tree"} = build(ctx, %{ctx.first | tree: "not a tree"})
  end

  test "a build that exits 0 but leaves no usable app failed, and says so", ctx do
    assert {:failed, 0, "The build command finished, but it made no app at build/Demo.app: build/Demo.app is not a directory after the build."} =
             build(ctx, ctx.first, %{plan: %{build: "true"}})

    assert {:failed, 0, "The build command finished, but it made no app at build/Demo: build/Demo is not an .app bundle."} =
             build(ctx, ctx.first, %{plan: %{app: "build/Demo"}})

    outside = "mkdir -p ../../outside/Demo.app && ln -s ../../outside out"
    assert {:failed, 0, output} = build(ctx, ctx.first, %{plan: %{build: outside, app: "out/Demo.app"}})
    assert output =~ "out/Demo.app resolves outside the checkout"
  end

  test "a script the QA host does not answer is unavailable", ctx do
    silent = fn
      ["-c", _script, "sh", "sync" | _rest], _run -> {:ok, {"", 0}}
      _args, run -> run.()
    end

    assert {:unavailable, "the QA host could not bring the checkout to the commit: no answer: "} = build(ctx, ctx.first, %{}, %{cmd: silent})

    down = fn
      ["-c", _script, "sh", "store" | _rest], _run -> {:error, :closed}
      _args, run -> run.()
    end

    assert {:unavailable, "the QA host could not store the built app: :closed"} = build(ctx, ctx.first, %{}, %{cmd: down})
  end
end
