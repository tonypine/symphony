defmodule SymphonyElixir.QaBuildTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaBuild

  @repo_key "demo"
  @sha "1111111111111111111111111111111111111111"
  @sha2 "2222222222222222222222222222222222222222"
  @tree "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @tree2 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @plan %{worker_host: "qa-vm", build: "make app", app: "build/Demo.app", build_timeout_ms: 60_000}
  @ticket %{identifier: "TP-1", issue_id: "issue-1"}
  @held Map.put(@ticket, :held, true)
  @app "/Users/qa/.symphony-qa/store/demo/builds/#{@tree}/Demo.app"

  defmodule DownStore do
    @moduledoc false
    def get_github_updates(_key), do: {:error, :down}
    def put_github_updates(_key, _value), do: {:error, :down}
    def delete_github_updates(_key), do: {:error, :down}
  end

  # The run store, but one that forgets nothing.
  defmodule KeepingStore do
    @moduledoc false
    defdelegate get_github_updates(key), to: SymphonyElixir.RunStore
    defdelegate put_github_updates(key, value), to: SymphonyElixir.RunStore
    def delete_github_updates(_key), do: {:error, :read_only}
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
  end

  # The builder with every boundary faked. A tree read answers from `trees` (a commit mapped to
  # `:wait` blocks until the test sends the reader its answer), and a build tells the test it
  # started and blocks until the test sends its outcome.
  defp start_builder!(opts \\ []) do
    test = self()
    trees = Keyword.get(opts, :trees, %{@sha => @tree, @sha2 => @tree2})

    tree = fn workspace, sha ->
      send(test, {:reading, workspace, sha, self()})

      case Map.get(trees, sha) do
        nil -> {:error, "unknown commit"}
        :crash -> exit(:boom)
        :wait -> receive(do: ({:tree, answer} -> answer))
        tree -> {:ok, tree}
      end
    end

    build = fn job, [] ->
      send(test, {:building, job, self()})

      receive do
        {:outcome, outcome} -> outcome
        :crash -> exit(:boom)
      end
    end

    defaults = [
      name: Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}"),
      plan: fn
        @repo_key -> {:ok, @plan}
        "other" -> {:ok, %{@plan | worker_host: "qa-vm-2"}}
        _repo_key -> :none
      end,
      workspace: fn repo_key, identifier -> {:ok, "/workspaces/#{repo_key}/#{identifier}"} end,
      tree: tree,
      build: build,
      cancel: fn repo_key, plan, [] ->
        send(test, {:cancelling, repo_key, plan.worker_host, self()})
        receive(do: ({:stopped, outcome} -> outcome))
      end,
      release: fn repo_key, issue_id, identifier -> send(test, {:released, repo_key, issue_id, identifier}) end
    ]

    # An option given as nil leaves the builder its own default.
    opts = defaults |> Keyword.merge(Keyword.drop(opts, [:trees])) |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    start_supervised!({QaBuild, opts}, id: opts[:name])
    opts[:name]
  end

  defp settled(server), do: :sys.get_state(server)

  describe "request/4" do
    test "reads the commit's tree, builds it once and records the stored app" do
      server = start_builder!()

      log =
        capture_log(fn ->
          assert :ok = QaBuild.request(@repo_key, @sha, @held, server: server)
          assert_receive {:reading, "/workspaces/demo/TP-1", @sha, _reader}
          assert_receive {:building, job, builder}
          assert job == %{repo_key: @repo_key, tree: @tree, sha: @sha, plan: @plan, workspace: "/workspaces/demo/TP-1"}

          assert %{status: :building, repo_key: @repo_key, tree: @tree, sha: @sha, identifier: "TP-1"} = QaBuild.lookup(@repo_key, @sha)
          assert RunStore.get_github_updates({:qa_build, :building}) == %{keys: [{@repo_key, @tree}]}
          refute_received {:released, _repo_key, _issue_id, _identifier}

          # Asking again while it builds starts nothing.
          assert :ok = QaBuild.request(@repo_key, @sha, @ticket, server: server)
          settled(server)
          refute_received {:building, _job, _builder}

          send(builder, {:outcome, {:ready, @app}})
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build queued repo_key=demo tree=#{@tree} head_sha=#{@sha} issue_id=issue-1 issue_identifier=TP-1 worker_host=qa-vm"
      assert log =~ "QA build started repo_key=demo tree=#{@tree}"
      assert log =~ "QA build ready repo_key=demo tree=#{@tree} head_sha=#{@sha} issue_identifier=TP-1 app=#{@app}"

      assert %{status: :ready, app: @app, tree: @tree, sha: @sha} = QaBuild.get(@repo_key, @tree)
      assert QaBuild.lookup(@repo_key, @sha) == QaBuild.get(@repo_key, @tree)
      assert RunStore.get_github_updates({:qa_build, :building}) == %{keys: []}
    end

    test "a head whose tree was already built is ready at once, and a final record is never built again" do
      server = start_builder!(trees: %{@sha => @tree, @sha2 => @tree})
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:reading, _workspace, @sha, _reader}
      assert_receive {:building, _job, builder}
      send(builder, {:outcome, {:ready, @app}})
      settled(server)
      refute_received {:released, _repo_key, _issue_id, _identifier}

      QaBuild.request(@repo_key, @sha2, @held, server: server)
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      assert %{status: :ready, sha: @sha} = QaBuild.lookup(@repo_key, @sha2)

      # By the commit, with no tree read this time.
      assert_received {:reading, _workspace, @sha2, _reader}
      QaBuild.request(@repo_key, @sha2, @held, server: server)
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      refute_received {:reading, _workspace, _sha, _reader}
      refute_received {:building, _job, _builder}
    end

    test "requests for one commit while its tree is read share the read, and each held ticket is released" do
      server = start_builder!(trees: %{@sha => :wait})
      QaBuild.request(@repo_key, @sha, @held, server: server)
      QaBuild.request(@repo_key, @sha, %{identifier: "TP-2", issue_id: "issue-2", held: true}, server: server)
      QaBuild.request(@repo_key, @sha, %{identifier: "TP-3"}, server: server)
      assert_receive {:reading, _workspace, @sha, reader}
      settled(server)
      refute_received {:reading, _workspace, _sha, _reader}

      send(reader, {:tree, {:ok, @tree}})
      assert_receive {:building, _job, builder}
      refute_receive {:building, _job, _builder}, 20

      send(builder, {:outcome, {:unavailable, "ssh: connection refused"}})
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      assert_receive {:released, @repo_key, "issue-2", "TP-2"}
      assert %{status: :unavailable, reason: "ssh: connection refused"} = QaBuild.lookup(@repo_key, @sha)
    end

    test "one build at a time on a QA host, oldest first, while another host builds beside it" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, %{tree: @tree}, first}
      QaBuild.request(@repo_key, @sha2, %{identifier: "TP-2", issue_id: "issue-2"}, server: server)
      QaBuild.request("other", @sha, %{identifier: "TP-3", issue_id: "issue-3"}, server: server)
      assert_receive {:building, %{repo_key: "other", plan: %{worker_host: "qa-vm-2"}}, other}
      assert_receive {:reading, _workspace, @sha2, _reader}
      refute_receive {:building, %{tree: @tree2}, _builder}, 20
      assert %{status: :building} = QaBuild.get(@repo_key, @tree2)

      send(first, {:outcome, {:ready, @app}})
      assert_receive {:building, %{tree: @tree2}, second}
      send(second, {:outcome, {:ready, @app}})
      send(other, {:outcome, {:ready, @app}})
      assert %{status: :ready} = QaBuild.fetch("other", @sha, @ticket, server: server)
      assert %{status: :ready} = QaBuild.fetch(@repo_key, @sha2, @ticket, server: server)
    end

    test "a build command that failed is recorded with its command and output" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @held, server: server)
      assert_receive {:building, _job, builder}

      log =
        capture_log(fn ->
          send(builder, {:outcome, {:failed, 65, "error: no such module 'Foo'\n"}})
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build failed repo_key=demo tree=#{@tree} head_sha=#{@sha} issue_identifier=TP-1 exit_status=65"

      assert %{status: :failed, command: "make app", exit_status: 65, output: "error: no such module 'Foo'\n", reworked: %{}} =
               QaBuild.lookup(@repo_key, @sha)
    end

    test "a build task that dies, or whose workspace is gone, ends as unavailable" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @held, server: server)
      assert_receive {:building, _job, builder}

      log =
        capture_log(fn ->
          send(builder, :crash)
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build unavailable repo_key=demo tree=#{@tree}"
      assert %{status: :unavailable, reason: "the build task exited: :boom"} = QaBuild.get(@repo_key, @tree)

      # The tree is read while the workspace is there; it is gone when the build starts.
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      workspace = fn _repo_key, _identifier ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: {:ok, "/workspaces/demo/TP-1"}, else: {:error, :enoent}
      end

      gone = start_builder!(workspace: workspace)
      QaBuild.request(@repo_key, @sha2, @held, server: gone)
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      assert %{status: :unavailable, reason: "the ticket's workspace could not be found: :enoent"} = QaBuild.get(@repo_key, @tree2)
    end

    test "a commit whose tree can't be read is unavailable by commit, and is not read again" do
      server = start_builder!(trees: %{@sha2 => :crash})

      log =
        capture_log(fn ->
          QaBuild.request(@repo_key, @sha, @held, server: server)
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
          QaBuild.request(@repo_key, @sha2, @held, server: server)
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build unavailable: the tree of the commit could not be read repo_key=demo head_sha=#{@sha} issue_id=issue-1 issue_identifier=TP-1 reason=unknown commit"
      assert QaBuild.lookup(@repo_key, @sha) == %{status: :unavailable, reason: "the commit's tree could not be read: unknown commit"}
      assert %{status: :unavailable, reason: "the commit's tree could not be read: the task exited: :boom"} = QaBuild.lookup(@repo_key, @sha2)

      assert_received {:reading, _workspace, @sha, _reader}
      QaBuild.request(@repo_key, @sha, @held, server: server)
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      refute_received {:reading, _workspace, @sha, _reader}

      # A workspace that can't be found reads no tree either.
      lost = start_builder!(workspace: fn _repo_key, _identifier -> {:error, :enoent} end)
      capture_log(fn -> QaBuild.request("other", @sha, @held, server: lost) && assert_receive {:released, "other", "issue-1", "TP-1"} end)
      assert %{status: :unavailable, reason: "the commit's tree could not be read: :enoent"} = QaBuild.lookup("other", @sha)
    end

    test "a task that can't start ends the read or the build as unavailable" do
      missing = Module.concat(__MODULE__, "NoSupervisor")
      server = start_builder!(task_supervisor: missing)

      capture_log(fn ->
        QaBuild.request(@repo_key, @sha, @held, server: server)
        assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      end)

      assert %{status: :unavailable, reason: "the commit's tree could not be read: the task could not start: " <> _exit} = QaBuild.lookup(@repo_key, @sha)

      # A tree already read, on a builder whose task supervisor is gone.
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha2}, %{tree: @tree2})

      capture_log(fn ->
        QaBuild.request(@repo_key, @sha2, @held, server: server)
        assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      end)

      assert %{status: :unavailable, reason: "the build task could not start: " <> _exit} = QaBuild.get(@repo_key, @tree2)
    end

    test "a repository with nothing to build gets no build, and a held ticket is released" do
      server = start_builder!()
      QaBuild.request("no-playbook", @sha, @held, server: server)
      assert_receive {:released, "no-playbook", "issue-1", "TP-1"}
      QaBuild.request("no-playbook", @sha, @ticket, server: server)
      settled(server)
      refute_received {:reading, _workspace, _sha, _reader}
      assert QaBuild.lookup("no-playbook", @sha) == nil

      # The playbook went while the tree was read.
      {:ok, plans} = Agent.start_link(fn -> {:ok, @plan} end)
      changing = start_builder!(plan: fn _repo_key -> Agent.get(plans, & &1) end, trees: %{@sha => :wait})
      QaBuild.request(@repo_key, @sha, @held, server: changing)
      assert_receive {:reading, _workspace, @sha, reader}
      Agent.update(plans, fn _plan -> :none end)
      send(reader, {:tree, {:ok, @tree}})
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      assert QaBuild.lookup(@repo_key, @sha) == nil
    end

    test "reads the tree in the ticket's own workspace" do
      server = start_builder!(workspace: nil)
      {:ok, workspace} = Workspace.local_path_for_issue("TP-1", @repo_key)

      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:reading, ^workspace, @sha, _reader}
      assert_receive {:building, %{workspace: ^workspace}, builder}
      send(builder, {:outcome, {:ready, @app}})
      assert %{status: :ready} = QaBuild.fetch(@repo_key, @sha, @ticket, server: server)
    end

    test "does nothing without the builder" do
      assert :ok = QaBuild.request(@repo_key, @sha, @ticket, server: Module.concat(__MODULE__, "NotRunning"))
      assert QaBuild.lookup(@repo_key, @sha) == nil
    end
  end

  describe "at startup" do
    test "asks again for the builds a previous Symphony left building" do
      building = %{repo_key: @repo_key, tree: @tree, status: :building, sha: @sha, identifier: "TP-1"}
      building = Map.put(building, :at, DateTime.utc_now())
      :ok = RunStore.put_github_updates({:qa_build, @repo_key, @tree}, building)
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha}, %{tree: @tree})
      :ok = RunStore.put_github_updates({:qa_build, @repo_key, @tree2}, %{building | tree: @tree2, status: :ready})
      :ok = RunStore.put_github_updates({:qa_build, "no-playbook", @tree}, %{building | repo_key: "no-playbook"})
      keys = [{@repo_key, @tree}, {@repo_key, @tree2}, {"no-playbook", @tree}, {"gone", @tree}]
      :ok = RunStore.put_github_updates({:qa_build, :building}, %{keys: keys})
      unavailable = "cccccccccccccccccccccccccccccccccccccccc"
      :ok = RunStore.put_github_updates({:qa_build, @repo_key, unavailable}, Map.merge(building, %{tree: unavailable, status: :unavailable, reason: "ssh"}))
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha2}, %{status: :unavailable, reason: "bad object"})
      gone = [{:qa_build, @repo_key, unavailable}, {:qa_build_head, @repo_key, @sha2}]
      :ok = RunStore.put_github_updates({:qa_build, :unavailable}, %{keys: gone})

      log =
        capture_log(fn ->
          server = start_builder!()
          assert_receive {:building, %{tree: @tree, sha: @sha, workspace: "/workspaces/demo/TP-1"}, builder}
          refute_receive {:building, _job, _builder}, 20

          # The dispatch gate's request names who waits again.
          QaBuild.request(@repo_key, @sha, @held, server: server)
          send(builder, {:outcome, {:ready, @app}})
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build asked for again after a restart repo_key=demo tree=#{@tree} issue_identifier=TP-1"
      # The builds that could not run before the restart are forgotten, so the gate asks again.
      assert QaBuild.get(@repo_key, "cccccccccccccccccccccccccccccccccccccccc") == nil
      assert QaBuild.lookup(@repo_key, @sha2) == nil
      assert RunStore.get_github_updates({:qa_build, :unavailable}) == %{keys: [{:qa_build, "no-playbook", @tree}]}
      assert %{status: :ready} = QaBuild.get(@repo_key, @tree)
      assert %{status: :unavailable, reason: "the repository no longer has a macos_app playbook" <> _rest} = QaBuild.get("no-playbook", @tree)
    end
  end

  describe "fetch/4" do
    test "waits for the build, asking for it first, and calls the heartbeat while it waits" do
      server = start_builder!()
      test = self()
      heartbeat = fn -> send(test, :heartbeat) end
      waiter = Task.async(fn -> QaBuild.fetch(@repo_key, @sha, @ticket, server: server, heartbeat: heartbeat, heartbeat_ms: 10) end)

      assert_receive {:building, %{tree: @tree}, builder}
      assert_receive :heartbeat
      send(builder, {:outcome, {:ready, @app}})
      assert %{status: :ready, app: @app} = Task.await(waiter)

      # A final record answers at once, by commit; so does a repository with nothing to build.
      assert %{status: :ready} = QaBuild.fetch(@repo_key, @sha, @ticket, server: server)
      assert QaBuild.fetch("no-playbook", @sha, @ticket, server: server) == nil
      assert QaBuild.fetch(@repo_key, @sha, @ticket, server: Module.concat(__MODULE__, "NotRunning")) == nil
    end

    test "a pass that waits while the tree is read gets the record, or the commit's own" do
      server = start_builder!(trees: %{@sha => :wait, @sha2 => :wait})
      first = Task.async(fn -> QaBuild.fetch(@repo_key, @sha, @ticket, server: server) end)
      assert_receive {:reading, _workspace, @sha, reader}
      send(reader, {:tree, {:ok, @tree}})
      assert_receive {:building, _job, builder}
      send(builder, {:outcome, {:failed, 2, "error"}})
      assert %{status: :failed} = Task.await(first)

      second = Task.async(fn -> QaBuild.fetch(@repo_key, @sha2, @ticket, server: server) end)
      assert_receive {:reading, _workspace, @sha2, reader}
      capture_log(fn -> send(reader, {:tree, {:error, "bad object"}}) && assert(%{status: :unavailable} = Task.await(second)) end)
    end

    test "a builder that goes down while a pass waits answers nil" do
      server = start_builder!()
      waiter = Task.async(fn -> QaBuild.fetch(@repo_key, @sha, @ticket, server: server) end)
      assert_receive {:building, _job, _builder}
      stop_supervised!(server)
      assert Task.await(waiter) == nil
    end

    test "rebuild: true builds again a ready tree whose stored app is gone, and only that" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, _job, builder}
      send(builder, {:outcome, {:ready, @app}})
      assert %{status: :ready} = QaBuild.fetch(@repo_key, @sha, @ticket, server: server)

      log =
        capture_log(fn ->
          waiter = Task.async(fn -> QaBuild.fetch(@repo_key, @sha, @ticket, server: server, rebuild: true) end)
          assert_receive {:building, %{tree: @tree}, builder}
          send(builder, {:outcome, {:ready, @app <> "-2"}})
          assert %{status: :ready, app: app} = Task.await(waiter)
          assert app == @app <> "-2"
        end)

      assert log =~ "QA build asked for again: its stored app is gone repo_key=demo tree=#{@tree} head_sha=#{@sha}"

      # A failed tree, or a commit with no record, is not built again for it.
      QaBuild.request(@repo_key, @sha2, @ticket, server: server)
      assert_receive {:building, %{tree: @tree2}, builder}
      send(builder, {:outcome, {:failed, 1, "error"}})
      assert %{status: :failed} = QaBuild.fetch(@repo_key, @sha2, @ticket, server: server, rebuild: true)
      refute_receive {:building, _job, _builder}, 20
    end
  end

  describe "a head that moves" do
    test "cancels the build of the tree no other head needs, kills it on the QA host, and starts the new one after" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @held, server: server)
      assert_receive {:building, %{tree: @tree}, old}
      old_monitor = Process.monitor(old)

      log =
        capture_log(fn ->
          QaBuild.request(@repo_key, @sha2, @ticket, server: server)
          assert_receive {:cancelling, @repo_key, "qa-vm", stopper}
          assert_receive {:DOWN, ^old_monitor, :process, ^old, _reason}
          # The old tree is left with no record, and the ticket waiting on it is let go.
          assert QaBuild.get(@repo_key, @tree) == nil
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
          # The new build waits until the old one is dead on the QA host.
          refute_receive {:building, _job, _builder}, 20
          send(stopper, {:stopped, :ok})
          assert_receive {:building, %{tree: @tree2}, new}
          send(new, {:outcome, {:ready, @app}})
          assert %{status: :ready} = QaBuild.fetch(@repo_key, @sha2, @ticket, server: server)
        end)

      assert log =~ "QA build cancelled: the head moved repo_key=demo tree=#{@tree}"
      assert log =~ "QA build stopped on the QA host repo_key=demo tree=#{@tree} worker_host=qa-vm outcome=:ok"
      assert RunStore.get_github_updates({:qa_build, :building}) == %{keys: []}
    end

    test "keeps a build another ticket's head or a waiting pass needs, and drops a queued one at once" do
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha}, %{tree: @tree})
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha2}, %{tree: @tree2})
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      QaBuild.request(@repo_key, @sha, %{identifier: "TP-2", issue_id: "issue-2"}, server: server)
      assert_receive {:building, %{tree: @tree}, running}

      # TP-1 moves on, TP-2 still needs the tree.
      QaBuild.request(@repo_key, @sha2, @ticket, server: server)
      settled(server)
      refute_received {:cancelling, _repo_key, _host, _stopper}
      assert %{status: :building} = QaBuild.get(@repo_key, @tree2)

      # TP-1 moves again: its queued build of @tree2 goes without a kill; @tree stays for TP-2.
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, "3333333333333333333333333333333333333333"}, %{tree: @tree})
      capture_log(fn -> QaBuild.request(@repo_key, "3333333333333333333333333333333333333333", @ticket, server: server) && settled(server) end)
      refute_received {:cancelling, _repo_key, _host, _stopper}
      assert QaBuild.get(@repo_key, @tree2) == nil

      # A pass waiting on the running build keeps it too.
      waiter = Task.async(fn -> QaBuild.fetch(@repo_key, @sha, %{identifier: "TP-3"}, server: server) end)
      eventually(fn -> settled(server).jobs[{@repo_key, @tree}].awaiting != [] end)
      QaBuild.request(@repo_key, @sha2, %{identifier: "TP-2", issue_id: "issue-2"}, server: server)
      QaBuild.request(@repo_key, @sha2, @ticket, server: server)
      settled(server)
      refute_received {:cancelling, _repo_key, _host, _stopper}
      send(running, {:outcome, {:ready, @app}})
      assert %{status: :ready} = Task.await(waiter)
    end

    test "a cancel whose stop dies, or can't start, lets the next build go" do
      name = Module.concat(__MODULE__, "Builds#{System.unique_integer([:positive])}")
      {:ok, _supervisor} = Task.Supervisor.start_link(name: name)
      server = start_builder!(task_supervisor: name)
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, %{tree: @tree}, _old}

      # The stop task itself dies: the QA host is free again.
      capture_log(fn ->
        QaBuild.request(@repo_key, @sha2, @ticket, server: server)
        assert_receive {:cancelling, @repo_key, "qa-vm", stopper}
        Process.exit(stopper, :kill)
        assert_receive {:building, %{tree: @tree2}, _new}
      end)

      # No task can start for the stop: the build is dropped all the same.
      Process.unregister(name)
      Process.register(spawn(fn -> receive(do: (_call -> :ok)) end), name)
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, "3333333333333333333333333333333333333333"}, %{tree: @tree})
      log = capture_log(fn -> QaBuild.request(@repo_key, "3333333333333333333333333333333333333333", @ticket, server: server) && settled(server) end)
      assert log =~ "QA build cancelled: the head moved repo_key=demo tree=#{@tree2}"
      assert QaBuild.get(@repo_key, @tree2) == nil
      refute_received {:cancelling, _repo_key, _host, _stopper}
    end
  end

  describe "retry/4" do
    test "forgets a build that could not run and asks for it again, for a person's Unblock" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, _job, builder}
      capture_log(fn -> send(builder, {:outcome, {:unavailable, "ssh: timeout"}}) && settled(server) end)
      assert %{status: :unavailable} = QaBuild.lookup(@repo_key, @sha)

      # A gate request does not build it again.
      QaBuild.request(@repo_key, @sha, @held, server: server)
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
      refute_receive {:building, _job, _builder}, 20

      log = capture_log(fn -> assert :ok = QaBuild.retry(@repo_key, @sha, @ticket, server: server) end)
      assert log =~ "QA build asked for again by a person repo_key=demo head_sha=#{@sha} issue_id=issue-1 issue_identifier=TP-1"
      assert %{status: :building} = QaBuild.lookup(@repo_key, @sha)
      assert_receive {:building, %{tree: @tree}, builder}
      send(builder, {:outcome, {:ready, @app}})
      assert_receive {:released, @repo_key, "issue-1", "TP-1"}
    end

    test "reads again a commit whose tree could not be read, and leaves a final build as it is" do
      server = start_builder!(trees: %{@sha2 => @tree2})
      capture_log(fn -> QaBuild.request(@repo_key, @sha, @ticket, server: server) && settled(server) end)
      assert %{status: :unavailable} = QaBuild.lookup(@repo_key, @sha)

      capture_log(fn -> assert :ok = QaBuild.retry(@repo_key, @sha, @ticket, server: server) end)
      assert_receive {:reading, _workspace, @sha, _reader}

      QaBuild.request(@repo_key, @sha2, @ticket, server: server)
      assert_receive {:building, _job, builder}
      send(builder, {:outcome, {:failed, 1, "error"}})
      settled(server)
      capture_log(fn -> assert :ok = QaBuild.retry(@repo_key, @sha2, @ticket, server: server) end)
      assert %{status: :failed} = QaBuild.lookup(@repo_key, @sha2)

      capture_log(fn -> assert :ok = QaBuild.retry(@repo_key, "4444444444444444444444444444444444444444", @ticket, server: server) end)
      assert :ok = QaBuild.retry(@repo_key, @sha, @ticket, server: Module.concat(__MODULE__, "NotRunning"))
    end

    test "a new head asks again for a tree or a commit that could not be built" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, _job, builder}
      capture_log(fn -> send(builder, {:outcome, {:unavailable, "ssh: timeout"}}) && settled(server) end)

      QaBuild.request(@repo_key, @sha, Map.put(@ticket, :new_head, true), server: server)
      assert_receive {:building, %{tree: @tree}, builder}
      send(builder, {:outcome, {:ready, @app}})

      broken = start_builder!(trees: %{})

      capture_log(fn ->
        QaBuild.request("other", @sha, @ticket, server: broken)
        assert_receive {:reading, _workspace, @sha, _reader}
      end)

      capture_log(fn -> settled(broken) && Process.sleep(20) end)
      assert %{status: :unavailable} = QaBuild.lookup("other", @sha)
      capture_log(fn -> QaBuild.request("other", @sha, Map.put(@ticket, :new_head, true), server: broken) && settled(broken) end)
      assert_receive {:reading, _workspace, @sha, _reader}
    end
  end

  describe "mark_reworked/5" do
    test "is :ok once for each arrival of a ticket in QA on a failed tree" do
      server = start_builder!()
      QaBuild.request(@repo_key, @sha, @ticket, server: server)
      assert_receive {:building, _job, builder}
      send(builder, {:outcome, {:failed, 1, "error"}})
      assert %{status: :failed} = QaBuild.fetch(@repo_key, @sha, @ticket, server: server)
      first = ~U[2026-11-13 10:00:00Z]

      assert :ok = QaBuild.mark_reworked(@repo_key, @tree, "issue-1", first, server: server)
      assert :already = QaBuild.mark_reworked(@repo_key, @tree, "issue-1", first, server: server)
      assert :ok = QaBuild.mark_reworked(@repo_key, @tree, "issue-2", first, server: server)
      # Back in QA later on the same tree: sent back again.
      assert :ok = QaBuild.mark_reworked(@repo_key, @tree, "issue-1", ~U[2026-11-13 11:00:00Z], server: server)
      assert %{reworked: %{"issue-1" => ~U[2026-11-13 11:00:00Z], "issue-2" => ^first}} = QaBuild.get(@repo_key, @tree)

      assert :already = QaBuild.mark_reworked(@repo_key, @tree2, "issue-1", first, server: server)
      assert :already = QaBuild.mark_reworked(@repo_key, @tree, "issue-3", first, server: Module.concat(__MODULE__, "NotRunning"))
    end
  end

  describe "builds?/2 and plan/1" do
    test "builds for a repository with a macos_app build, an app and a QA host, while the builder runs" do
      macos_app = %{build: "make app", app: "build/Demo.app", build_timeout_ms: 120_000}
      auto_review = %{worker_host: "qa-vm", playbooks: %{macos_app: macos_app}}
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: auto_review)
      assert QaBuild.plan("default") == {:ok, %{worker_host: "qa-vm", build: "make app", app: "build/Demo.app", build_timeout_ms: 120_000}}

      auto_review = put_in(auto_review, [:playbooks, :macos_app], Map.delete(macos_app, :build_timeout_ms))
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: auto_review)
      assert {:ok, %{build_timeout_ms: 900_000}} = QaBuild.plan("default")

      server = start_builder!(plan: &QaBuild.plan/1)
      assert QaBuild.builds?("default", server: server)
      refute QaBuild.builds?("default", server: Module.concat(__MODULE__, "NotRunning"))
      refute QaBuild.builds?("default", server: server, plan: fn "default" -> :none end)

      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{playbooks: %{macos_app: macos_app}})
      assert QaBuild.plan("default") == :none
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{worker_host: "qa-vm"})
      assert QaBuild.plan("default") == :none
      assert QaBuild.plan("no-such-repo") == :none
    end
  end

  describe "tree/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "qa-build-test-#{System.unique_integer([:positive])}")
      origin = Path.join(root, "origin")
      File.mkdir_p!(origin)
      on_exit(fn -> File.rm_rf(root) end)
      git!(origin, ["init", "--quiet"])
      git!(origin, ["config", "uploadpack.allowAnySHA1InWant", "true"])
      File.write!(Path.join(origin, "a.txt"), "one\n")
      git!(origin, ["add", "--all"])
      git!(origin, ["commit", "--quiet", "-m", "one"])
      clone = Path.join(root, "clone")
      {_output, 0} = System.cmd("git", ["clone", "--quiet", origin, clone], stderr_to_stdout: true)
      %{origin: origin, clone: clone}
    end

    defp git!(repo, args) do
      {output, 0} = System.cmd("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" | args], stderr_to_stdout: true)
      String.trim(output)
    end

    test "reads the tree of a commit the workspace holds", %{clone: clone} do
      assert QaBuild.tree(clone, git!(clone, ["rev-parse", "HEAD"])) == {:ok, git!(clone, ["rev-parse", "HEAD^{tree}"])}
    end

    test "fetches a commit the workspace does not hold", %{origin: origin, clone: clone} do
      File.write!(Path.join(origin, "a.txt"), "two\n")
      git!(origin, ["commit", "--quiet", "-am", "two"])
      sha = git!(origin, ["rev-parse", "HEAD"])

      assert QaBuild.tree(clone, sha) == {:ok, git!(origin, ["rev-parse", "HEAD^{tree}"])}
    end

    test "says why a commit nobody holds has no tree", %{clone: clone} do
      assert {:error, "git fetch origin " <> reason} = QaBuild.tree(clone, String.duplicate("0", 40))
      assert reason =~ "failed (exit "

      fetched_nothing = fn
        ["fetch" | _rest], _cwd -> {"", 0}
        ["rev-parse" | _rest], _cwd -> {"", 1}
      end

      assert QaBuild.tree(clone, @sha, fetched_nothing) == {:error, "git rev-parse #{@sha}^{tree} failed (exit 1)"}
    end
  end

  describe "the run store" do
    test "a store that is down reads as no record, and a write that fails is logged" do
      assert QaBuild.get(@repo_key, @tree, run_store: DownStore) == nil
      assert QaBuild.lookup(@repo_key, @sha, run_store: DownStore) == nil

      server = start_builder!(run_store: DownStore)

      log =
        capture_log(fn ->
          QaBuild.request(@repo_key, @sha, @held, server: server)
          assert_receive {:building, _job, builder}
          send(builder, {:outcome, {:ready, @app}})
          assert_receive {:released, @repo_key, "issue-1", "TP-1"}
        end)

      assert log =~ "QA build could not write its record key={:qa_build, \"demo\", \"#{@tree}\"} reason=:down"

      # A record it can't forget is logged too.
      :ok = RunStore.put_github_updates({:qa_build_head, @repo_key, @sha}, %{status: :unavailable, reason: "bad object"})
      kept = start_builder!(run_store: KeepingStore)
      log = capture_log(fn -> QaBuild.retry(@repo_key, @sha, @ticket, server: kept) end)
      assert log =~ "QA build could not forget its record key={:qa_build_head, \"demo\", \"#{@sha}\"} reason=:read_only"
    end

    test "ignores messages that are not its tasks'" do
      server = start_builder!()
      send(server, :unrelated)
      assert %QaBuild{} = settled(server)
    end
  end
end
