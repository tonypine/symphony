defmodule SymphonyElixir.PhaseSteps.WindowTestsTest do
  # The Window tests step (TP-1554): which tests a change selects from the manifest beside the
  # scripts, and a run of the step through the step runner against a fake QA VM whose home is a
  # temporary folder, where the step's run script runs for real.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Phases
  alias SymphonyElixir.{PathSafety, PhaseSteps, Questions, TicketEvents}
  alias SymphonyElixir.PhaseSteps.WindowTests
  alias SymphonyElixir.QaDriver.{DevServerLease, Host}

  @repo_key "default"
  @issue_id "issue-window-tests"
  @qa_vm "99999999-8888-7777-6666-555544443333"
  @symphony_mac "1A2B3C4D-0000-1111-2222-333344445555"
  @app "/Users/qa/.symphony-qa/store/default/builds/abc/Demo.app"

  @manifest %{
    "tests" => [
      %{"script" => "macos/Tests/pass-test.sh", "title" => "passing test", "run" => "sh Tests/pass-test.sh", "covers" => ["priv/qa_driver/**"]},
      %{"script" => "macos/Tests/flaky-test.sh", "title" => "breakable test", "run" => "sh Tests/flaky-test.sh", "covers" => ["macos/Sources/Window/*.swift"]},
      %{"script" => "macos/Tests/off-test.sh", "title" => "test off in the VM", "run" => "sh Tests/off-test.sh", "covers" => ["priv/off/**"], "off" => "it fails on main there"}
    ]
  }

  setup do
    :ok = RunStore.clear()
    File.mkdir_p!(System.tmp_dir!())
    {:ok, tmp} = PathSafety.canonicalize(System.tmp_dir!())
    root = Path.join(tmp, "window-tests-test-#{System.unique_integer([:positive])}")
    home = Path.join(root, "qa-home")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf(root) end)

    # The QA VM's tools, as the run script looks for them.
    for tool <- ["python3", "swiftc"] do
      File.write!(Path.join(bin, tool), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, tool), 0o755)
    end

    lease = :"window_tests_lease_#{System.unique_integer([:positive])}"
    start_supervised!({DevServerLease, name: lease})

    git!(repo, ["init", "--quiet", "-b", "main"])
    base = commit!(repo, %{"macos/Tests/pass-test.sh" => "echo all good\n", "macos/Tests/flaky-test.sh" => "echo flaky fine\n", "README.md" => "x\n"})
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    %{home: home, repo: repo, bin: bin, lease: lease, base: base}
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp commit!(repo, files) do
    for {name, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(repo, name)))
      File.write!(Path.join(repo, name), content)
    end

    git!(repo, ["add", "--all"])
    git!(repo, ["commit", "--quiet", "-m", "change"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp entries, do: @manifest |> Jason.encode!() |> WindowTests.parse() |> elem(1)

  defp changes(changed), do: %{changed: changed, existing: changed, tests: [], window_tests: {:ok, entries()}}

  # A fake QA VM: `ioreg` names another machine, the run directory is a real folder under its home,
  # and every other command runs here for real, with the VM's tools on the path and the remote
  # environment as its own.
  defp host(ctx, overrides) do
    test = self()

    cmd = fn
      "/usr/sbin/ioreg", _args, _opts ->
        {:ok, {~s(    "IOPlatformUUID" = "#{@qa_vm}"\n), 0}}

      executable, args, opts ->
        send(test, {:vm_cmd, List.last(args), opts})
        env = [{~c"HOME", String.to_charlist(ctx.home)}, {~c"PATH", String.to_charlist("#{ctx.bin}:/usr/bin:/bin")}]
        env = env ++ for({name, value} <- Keyword.get(opts, :remote_env, []), do: {String.to_charlist(name), String.to_charlist(value)})
        run = fn -> Host.cmd(executable, args, [env: env] ++ Keyword.take(opts, [:timeout_ms, :output_limit])) end
        Map.get(overrides, :cmd, fn _args, run -> run.() end).(args, run)
    end

    %{
      cmd: cmd,
      prepare:
        Map.get(overrides, :prepare, fn _operator_home, _canary ->
          dir = Path.join(ctx.home, ".symphony-qa/runs/run.#{System.unique_integer([:positive])}")
          File.mkdir_p!(dir)
          {:ok, dir}
        end),
      ship:
        Map.get(overrides, :ship, fn tar, dest ->
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

  defp built(sha), do: %{status: :ready, app: @app, sha: sha}

  defp opts(ctx, overrides \\ %{}) do
    test = self()

    [
      plan: fn @repo_key -> {:ok, %{worker_host: "qa-vm", build: "make app", app: "build/Demo.app", build_timeout_ms: 60_000}} end,
      fetch: fn @repo_key, sha, %{identifier: "TP-77", issue_id: @issue_id}, [] ->
        send(test, {:built, sha})
        Map.get(overrides, :build, &built/1).(sha)
      end,
      lease: ctx.lease,
      host: fn "qa-vm" -> host(ctx, Map.get(overrides, :host, %{})) end,
      local_uuid: fn -> {:ok, @symphony_mac} end
    ]
    |> Keyword.merge(Map.get(overrides, :opts, []))
  end

  defp context(ctx, changed, window_opts) do
    %{
      repo_key: @repo_key,
      issue_id: @issue_id,
      identifier: "TP-77",
      phase: "In Progress",
      run_id: "run-window-tests",
      workspace: ctx.repo,
      base_branch: "main",
      changes: changes(changed),
      window_tests_opts: window_opts
    }
  end

  defp walk(context) do
    steps = Phases.default_steps(:implementation)
    PhaseSteps.run_machine_steps(steps, Enum.find(steps, &(&1.id == "window_tests")), context)
  end

  defp completed, do: for(%{payload: %{step_id: "window_tests"} = payload} = event <- events("step.completed"), do: Map.put(payload, :artifacts, event.artifacts))
  defp events(type), do: @issue_id |> TicketEvents.query(types: [type], limit: 200) |> Enum.sort_by(& &1.seq)

  defp output(%{artifacts: [id | _]}) do
    {:ok, path} = SymphonyElixir.Artifacts.path(artifact_id(id))
    File.read!(path)
  end

  defp artifact_id(%{id: id}), do: id
  defp artifact_id(id) when is_binary(id), do: id

  defp change_flaky!(ctx, script), do: commit!(ctx.repo, %{"macos/Tests/flaky-test.sh" => script, "macos/Sources/Window/View.swift" => "// changed\n"})

  describe "the manifest" do
    test "reads each test's script, title, command, covered paths and why it is off" do
      assert [
               %{script: "macos/Tests/pass-test.sh", title: "passing test", run: "sh Tests/pass-test.sh", covers: ["priv/qa_driver/**"], off: nil},
               _breakable,
               %{script: "macos/Tests/off-test.sh", off: "it fails on main there"}
             ] = entries()

      assert WindowTests.parse("{") == {:error, "macos/Tests/window-tests.json is not JSON"}
      assert WindowTests.parse(~s({"scripts": []})) == {:error, "macos/Tests/window-tests.json has no `tests` list"}
      assert {:error, "macos/Tests/window-tests.json: every test needs a `script`, a `title`, a `run` and a `covers` list"} = WindowTests.parse(~s({"tests": [{"script": "a"}]}))
      assert {:error, message} = WindowTests.parse(~s({"tests": [{"script": "a", "title": "t", "run": "r", "covers": [1]}]}))
      assert message =~ "the test a has a `covers` that is not a list of paths"
      assert {:error, _off} = WindowTests.parse(~s({"tests": [{"script": "a", "title": "t", "run": "r", "covers": [], "off": true}]}))
    end

    test "the repository's own manifest declares every script the Mac CI build's driver checks run, each with a command" do
      assert {:ok, tests} = File.read!(WindowTests.manifest_path()) |> WindowTests.parse()
      assert Enum.map(tests, & &1.script) |> Enum.sort() == ["macos/Tests/qa-appearance-test.sh", "macos/Tests/qa-key-test.py", "macos/Tests/qa-scroll-test.py"]
      assert Enum.all?(tests, &File.exists?(&1.script))
      assert Enum.all?(tests, &is_nil(&1.off)), "TP-1563 turned every window test on once its Window tests step saw it pass in the QA VM"
    end
  end

  describe "which tests a change selects" do
    test "a change to a script, or to a path it covers, selects it; a change to the manifest selects every test that is on" do
      assert [%{script: "macos/Tests/flaky-test.sh"}] = WindowTests.selected(changes(["macos/Tests/flaky-test.sh"]))
      assert [%{script: "macos/Tests/pass-test.sh"}] = WindowTests.selected(changes(["priv/qa_driver/symphony-qa-driver.swift"]))
      assert [%{script: "macos/Tests/flaky-test.sh"}] = WindowTests.selected(changes(["macos/Sources/Window/View.swift"]))
      assert [_pass, _flaky] = WindowTests.selected(changes([WindowTests.manifest_path()]))
      assert WindowTests.skip_reason(changes(["priv/qa_driver/x.swift"])) == nil
    end

    test "a change nothing covers skips the step with the reason; one a test that is off in the QA VM covers does not" do
      assert WindowTests.selected(changes(["lib/symphony_elixir/foo.ex"])) == []
      assert WindowTests.skip_reason(changes(["lib/symphony_elixir/foo.ex"])) == "nothing a window test covers changed"
      assert WindowTests.off_covering(changes(["lib/symphony_elixir/foo.ex"])) == []

      assert WindowTests.selected(changes(["macos/Tests/off-test.sh"])) == []
      assert [%{script: "macos/Tests/off-test.sh"}] = WindowTests.off_covering(changes(["priv/off/driver.swift"]))
      assert WindowTests.off_covering(changes([WindowTests.manifest_path()])) == []
      assert WindowTests.skip_reason(changes(["macos/Tests/off-test.sh"])) == nil
      assert WindowTests.off_covering(%{changed: ["macos/Tests/off-test.sh"]}) == []

      assert WindowTests.selected(%{changed: ["macos/Tests/pass-test.sh"]}) == []
      assert WindowTests.skip_reason(%{changed: []}) == "the workspace declares no window tests (macos/Tests/window-tests.json)"
      assert WindowTests.skip_reason(%{changed: [], window_tests: {:error, "broken"}}) == nil
    end

    test "the step runner reads the manifest with the changed files and skips the step when nothing it covers changed", ctx do
      File.mkdir_p!(Path.join(ctx.repo, "macos/Tests"))
      File.write!(Path.join(ctx.repo, WindowTests.manifest_path()), Jason.encode!(@manifest, pretty: true))
      File.write!(Path.join(ctx.repo, "lib.ex"), "x")

      changes = PhaseSteps.changes(%{workspace: ctx.repo, base_branch: "main"})
      assert {:ok, [_pass, _flaky, _off]} = changes.window_tests
      refute Enum.any?(changes.changed, &String.starts_with?(&1, "{"))

      assert {:turn, %{id: "handoff"}, nil} = walk(%{context(ctx, [], []) | changes: Map.put(changes, :changed, ["lib.ex"])})
      assert [%{outcome: "skipped", reason: "nothing a window test covers changed"}] = completed()
      refute_received {:vm_cmd, _run, _opts}
    end

    test "a manifest the change broke fails the step back to the code, naming why", ctx do
      broken = %{changed: [WindowTests.manifest_path()], existing: [], tests: [], window_tests: {:error, "macos/Tests/window-tests.json is not JSON"}}
      context = %{context(ctx, [], []) | changes: broken}

      assert {:turn, %{id: "code"}, %{output: output}} = walk(context)
      assert output =~ "The window tests could not be read: macos/Tests/window-tests.json is not JSON."
      assert [%{outcome: "failed", returns_to: "code"}] = completed()
    end
  end

  describe "a run of the step" do
    test "builds the change with the QA build, runs each selected test in the QA VM from macos/ and passes with their output", ctx do
      head = commit!(ctx.repo, %{"macos/Tests/pass-test.sh" => "echo \"app=$SYMPHONY_QA_APP\"\necho all good\n"})

      assert {:turn, %{id: "handoff"}, nil} = walk(context(ctx, ["macos/Tests/pass-test.sh"], opts(ctx)))

      assert_received {:built, ^head}
      assert_received {:vm_cmd, "sh Tests/pass-test.sh", vm_opts}
      assert vm_opts[:remote_env] == [{"SYMPHONY_QA_APP", @app}]
      assert_received {:cleaned, _dir}

      assert [%{outcome: "passed"} = passed] = completed()
      output = output(passed)
      assert output =~ "Window tests in the QA VM, on #{String.slice(head, 0, 8)}"
      assert output =~ "== macos/Tests/pass-test.sh (in macos/: sh Tests/pass-test.sh)\n"
      assert output =~ "the QA VM lacks the pinned Xcode"
      assert output =~ "app=#{@app}\nall good\n"
      assert output =~ "(passed)"
      assert DevServerLease.holder(ctx.lease, {"qa-vm", :desktop}) == nil
    end

    test "a test the change broke fails the step back to the code with the output, and nothing goes on to the hand off", ctx do
      change_flaky!(ctx, "echo it broke\nexit 3\n")

      assert {:turn, %{id: "code"}, %{output: output}} = walk(context(ctx, ["macos/Sources/Window/View.swift"], opts(ctx)))

      base = ctx.base
      assert_received {:built, ^base}
      assert output =~ "it broke\n(failed: exit status 3)"
      assert output =~ "The failing tests again, on the base branch (#{String.slice(base, 0, 8)})"
      assert output =~ "flaky fine\n(passed)"
      assert output =~ "Broken by this change: macos/Tests/flaky-test.sh passes on the base branch."
      assert [%{outcome: "failed", returns_to: "code", reason: reason}] = completed()
      assert reason =~ "`symphony:window_tests` exited 1: Failed: macos/Tests/flaky-test.sh."
    end

    test "a test that fails on the base branch too stops the run on a question naming the VM problem, and never passes", ctx do
      commit!(ctx.repo, %{"macos/Tests/flaky-test.sh" => "echo broken everywhere\nexit 1\n"})
      git!(ctx.repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      change_flaky!(ctx, "echo broken everywhere\nexit 1\n")

      assert {:paused, %{id: "window_tests"}, question_id} = walk(context(ctx, ["macos/Sources/Window/View.swift"], opts(ctx)))
      assert [%{outcome: "paused", question_id: ^question_id} = paused] = completed()
      assert output(paused) =~ "(could not run: the breakable test also fails in the QA VM on the base branch"

      question = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      assert question.title == "TP-77: the window tests fail without this change too"
      assert question.why =~ "the QA VM or the main branch itself is broken, not this change"
      assert question.why =~ "the breakable test also fails in the QA VM on the base branch"
      assert question.recommendation_reason =~ "The fault is the QA VM's or the main branch's"
      assert [%{label: "Run it again", recommended?: true}, %{label: "Send it back to the code", recommended?: false}] = question.options
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 1, text: "Run it again"}}) == :again
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 2, text: "Send it back to the code"}}) == :words
    end

    test "a change a test that is off in the QA VM covers stops on a question naming it, and never hands off with it unrun", ctx do
      assert {:paused, %{id: "window_tests"}, question_id} = walk(context(ctx, ["macos/Tests/off-test.sh"], opts(ctx)))
      refute_received {:vm_cmd, _run, _opts}
      assert [%{outcome: "paused", question_id: ^question_id} = paused] = completed()
      assert output(paused) =~ "(could not run: the change touches what a window test covers that is off in the QA VM"
      question = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      assert question.title == "TP-77: a window test this change needs is turned off"
      assert question.why =~ "The QA VM works; the test is off"
      assert question.why =~ "the test off in the VM (it fails on main there)"
      refute question.recommendation_reason =~ "QA VM works again"
      assert question.recommendation_reason =~ "Running again stops again while the test is off"
      assert [%{label: "Run it again", recommended?: false}, %{label: "Send it back to the code", recommended?: true}] = question.options
      assert PhaseSteps.machine_resume(%{question | answer: %{option: 2, text: "Send it back to the code"}}) == :words
      refute Enum.any?(events("step.started"), &(&1.payload.step_id == "handoff"))
    end

    test "the tests that are on still run first: one the change broke goes back to the code, and passing ones stop for the off one", ctx do
      change_flaky!(ctx, "echo it broke\nexit 3\n")
      both = ["macos/Sources/Window/View.swift", "priv/off/driver.swift"]
      assert {:turn, %{id: "code"}, %{output: output}} = walk(context(ctx, both, opts(ctx)))
      assert output =~ "Broken by this change: macos/Tests/flaky-test.sh"

      :ok = RunStore.clear()
      change_flaky!(ctx, "echo fine again\n")
      assert {:paused, %{id: "window_tests"}, _question_id} = walk(context(ctx, both, opts(ctx)))
      assert [%{outcome: "paused"} = paused] = completed()
      assert output(paused) =~ "fine again\n(passed)"
      assert output(paused) =~ "(could not run: the change touches what a window test covers that is off in the QA VM"
    end

    test "an unreachable QA VM holds the run on a question, with nothing run and nothing pushed", ctx do
      change_flaky!(ctx, "echo fine\n")
      unreachable = %{cmd: fn _args, _run -> {:ok, {"ssh: connect to host qa-vm port 22: Operation timed out\n", 255}} end}

      assert {:paused, %{id: "window_tests"}, question_id} = walk(context(ctx, ["macos/Tests/flaky-test.sh"], opts(ctx, %{host: unreachable})))
      assert %{why: why} = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      assert why =~ "the QA VM could not be reached or could not run the breakable test (exit 255)"
      assert [%{outcome: "paused"}] = completed()
      refute Enum.any?(events("step.started"), &(&1.payload.step_id == "handoff"))
    end

    test "an unreachable QA VM and an off test the change needs: the VM problem leads, naming the off test beside it", ctx do
      change_flaky!(ctx, "echo fine\n")
      unreachable = %{cmd: fn _args, _run -> {:ok, {"ssh: connect to host qa-vm port 22: Operation timed out\n", 255}} end}
      both = ["macos/Tests/flaky-test.sh", "priv/off/driver.swift"]
      assert {:paused, _step, question_id} = walk(context(ctx, both, opts(ctx, %{host: unreachable})))
      question = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      assert question.title == "TP-77: the window tests could not run in the QA VM"
      assert question.why =~ "(exit 255); and the change touches what a window test covers that is off in the QA VM"
      assert [%{label: "Run it again", recommended?: true}, _back] = question.options
    end

    test "a QA VM the safety checks refuse, a commit it can't take, a tool it lacks or a test it can't say how ended all could not run", ctx do
      change_flaky!(ctx, "echo fine\n")
      changed = ["macos/Tests/flaky-test.sh"]

      no_archive = fn
        ["archive" | _rest], _cwd -> {"fatal: bad object", 128}
        args, cwd -> System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
      end

      cases = [
        {%{host: %{prepare: fn _home, _canary -> {:error, {:unsafe, "has a private key"}} end}}, "the QA VM could not be used (qa_worker_unsafe)"},
        {%{host: %{ship: fn _tar, _dest -> {:error, "no space"} end}}, "the commit could not be copied to the QA VM: no space"},
        {%{host: %{cmd: fn _args, _run -> {:ok, {"symphony-qa-window-setup:the QA VM has no swiftc\n", 0}} end}}, "the QA VM has no swiftc"},
        {%{host: %{cmd: fn _args, _run -> {:ok, {"half an answer", 0}} end}}, "the QA VM ended the breakable test without saying how"},
        {%{host: %{cmd: fn _args, _run -> {:error, :closed} end}}, "the QA VM could not run the breakable test: :closed"},
        {%{build: fn _sha -> %{status: :unavailable, reason: "the QA host was unreachable"} end}, "the QA build of this change could not run in the QA VM"},
        {%{build: fn _sha -> nil end}, "Symphony's QA builder is not running"},
        {%{opts: [plan: fn _repo -> :none end]}, "no QA VM that builds the app is set up for this repository"},
        {%{opts: [git: fn _args, _cwd -> {"fatal: not a git repository", 128} end]}, "Symphony could not read the commit to test (git exited 128"},
        {%{opts: [git: no_archive]}, "git archive of "}
      ]

      for {overrides, why} <- cases do
        :ok = RunStore.clear()
        assert {:paused, _step, question_id} = walk(context(ctx, changed, opts(ctx, overrides)))
        assert [%{outcome: "paused"} = paused] = completed()
        assert output(paused) =~ "(could not run: #{why}", why
        assert %{options: [_again, _back]} = Questions.find({:ticket, @repo_key, @issue_id}, question_id)
      end
    end

    test "a build the change broke fails back to the code; a base that can't be read or built could not run", ctx do
      change_flaky!(ctx, "exit 1\n")
      changed = ["macos/Tests/flaky-test.sh"]
      failed = %{status: :failed, command: "make app", exit_status: 2, output: "error: no such module"}

      broken_build = opts(ctx, %{build: fn _sha -> failed end})
      assert {:turn, %{id: "code"}, %{output: output}} = walk(context(ctx, changed, broken_build))
      assert output =~ "The QA build of this change"
      assert output =~ "failed: `make app` exited 2.\nerror: no such module"

      :ok = RunStore.clear()
      head = git!(ctx.repo, ["rev-parse", "HEAD"])
      base_broken = fn sha -> if sha == head, do: built(sha), else: failed end
      assert {:paused, _step, _question} = walk(context(ctx, changed, opts(ctx, %{build: base_broken})))
      assert [paused] = completed()
      assert output(paused) =~ "does not build in the QA VM"

      :ok = RunStore.clear()
      git!(ctx.repo, ["update-ref", "-d", "refs/remotes/origin/main"])
      assert {:paused, _step, _question} = walk(context(ctx, changed, opts(ctx)))
      assert [paused] = completed()
      assert output(paused) =~ "could not run: Symphony could not read the base branch's commit"
    end

    test "a test that runs past the step's time gives no result, and the step runs again", ctx do
      change_flaky!(ctx, "echo fine\n")
      slow = %{cmd: fn _args, _run -> {:error, :timeout} end}

      assert {:paused, %{id: "window_tests"}, _question} = walk(context(ctx, ["macos/Tests/flaky-test.sh"], opts(ctx, %{host: slow})))
      assert [%{outcome: "failed", returns_to: "window_tests"} = first, %{outcome: "paused"}] = completed()
      assert output(first) =~ "(macos/Tests/flaky-test.sh gave no result before the step's timeout)"
    end

    test "a failing test whose rerun on the base branch runs past the step's time gives no result", ctx do
      change_flaky!(ctx, "exit 1\n")
      test = self()

      # The change's run runs for real and fails; the base's rerun runs out of time.
      slow_base = %{
        cmd: fn args, run ->
          send(test, {:ran, args})

          if Process.get(:ran_once) do
            {:error, :timeout}
          else
            Process.put(:ran_once, true)
            run.()
          end
        end
      }

      context = context(ctx, ["macos/Tests/flaky-test.sh"], opts(ctx, %{host: slow_base}))
      assert {:paused, %{id: "window_tests"}, _question} = walk(context)
      assert [%{outcome: "failed", returns_to: "window_tests"} = first | _rest] = completed()
      assert output(first) =~ "(failed: exit status 1)"
      assert output(first) =~ "gave no result before the step's timeout"
    end
  end

  describe "the QA VM is one machine" do
    test "the step waits while a QA pass holds the VM, says whom it waits for, and a QA pass waits while the step runs", ctx do
      change_flaky!(ctx, "echo fine\n")
      test = self()
      key = {"qa-vm", :desktop}

      qa_pass = spawn_link(fn -> receive(do: (:done -> :ok)) end)
      :ok = DevServerLease.acquire(ctx.lease, key, %{pid: qa_pass, issue_id: "issue-qa", ticket: "TP-900", use: "QA pass"})

      # The step's test blocks until the test lets it go, so a second QA pass can ask for the VM meanwhile.
      hold = %{
        cmd: fn _args, run ->
          send(test, {:running, self()})
          receive(do: (:go -> run.()))
        end
      }

      step = Task.async(fn -> walk(context(ctx, ["macos/Tests/flaky-test.sh"], opts(ctx, %{host: hold}))) end)

      assert_eventually(fn -> Enum.any?(events("note"), &(&1.payload.text =~ "Window tests wait for the QA VM: TP-900's QA pass is using it.")) end)
      refute_received {:running, _pid}

      send(qa_pass, :done)
      assert_receive {:running, runner}, 5_000

      second_pass = spawn_link(fn -> receive(do: (:done -> :ok)) end)
      waiter = Task.async(fn -> DevServerLease.acquire(ctx.lease, key, %{pid: second_pass, issue_id: "issue-qa-2", ticket: "TP-901"}) end)

      assert_eventually(fn -> DevServerLease.waiting(ctx.lease, "issue-qa-2") == %{worker_host: "qa-vm", port: :desktop, held_by: "TP-77", held_for: "window tests"} end)
      assert DevServerLease.reason(DevServerLease.waiting(ctx.lease, "issue-qa-2")) == "waiting for the QA VM: qa-vm is in use by TP-77's window tests"

      send(runner, :go)
      assert {:turn, %{id: "handoff"}, nil} = Task.await(step, 10_000)
      assert :ok = Task.await(waiter, 5_000)
      assert %{ticket: "TP-901"} = DevServerLease.holder(ctx.lease, key)
      assert DevServerLease.use_of(DevServerLease.holder(ctx.lease, key)) == "QA pass"
      send(second_pass, :done)
    end

    test "without the lease manager the step goes ahead" do
      assert DevServerLease.holder(:no_such_lease_manager, {"qa-vm", :desktop}) == nil
      assert DevServerLease.holder({"no-such-vm", :desktop}) == nil
    end
  end

  defp assert_eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(10) && assert_eventually(fun, attempts - 1)
    end
  end
end
