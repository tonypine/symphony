defmodule SymphonyElixir.Conductor.WatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Artifacts
  alias SymphonyElixir.Conductor.{Facts, Steer, Watch}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.TicketEvents.Event

  @watch %Schema.Conductor.Watch{
    enabled: true,
    min_interval_minutes: 10,
    max_turns_per_run: 2,
    run_minutes: 30,
    run_tokens: 1_000
  }

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-watch-#{n}"
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: issue_id, issue_identifier: "WATCH-#{n}", phase: "In Progress"})
    profile = %{kind: :implementation, model: "m", harness: "claude"}
    run = %{issue_id: issue_id, run_id: "run-watch-#{n}", started_at: DateTime.utc_now(), total_tokens: 10, run_profile: profile}
    %{issue_id: issue_id, run: run}
  end

  defp watch_on! do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "conductor:\n  enabled: true\n  watch:\n    enabled: true\n    min_interval_minutes: 0\n    max_turns_per_run: 2\n")
    Cache.clear()
  end

  defp step(id, step_id, outcome), do: %Event{id: id, type: "step.completed", payload: %{step_id: step_id, outcome: outcome}}

  defp start_watch!(opts) do
    name = :"watch_#{System.unique_integer([:positive])}"
    test = self()

    defaults = [
      name: name,
      subscribe: false,
      tick_ms: 3_600_000,
      start_turn: fn run, trigger, watch -> send(test, {:turn, run.run_id, trigger, watch}) end
    ]

    pid = start_supervised!({Watch, Keyword.merge(defaults, opts)}, id: name)
    %{pid: pid, name: name}
  end

  describe "trigger/4" do
    test "a failed step, the same step failed twice and a QA step's answer each count once", %{run: run} do
      once = Watch.trigger([step("e1", "build", "failed")], run, @watch, MapSet.new())
      assert {"step_failed", seen} = once
      assert Watch.trigger([step("e1", "build", "failed")], run, @watch, seen) == nil

      assert {"step_failed_twice", _seen} = Watch.trigger([step("e1", "build", "failed"), step("e2", "build", "failed")], run, @watch, seen)
      assert {"step_failed", _seen} = Watch.trigger([step("e1", "build", "failed"), step("e3", "tests", "failed")], run, @watch, seen)
      assert Watch.trigger([step("e4", "build", "passed")], run, @watch, MapSet.new()) == nil

      answer = fn id, status ->
        result = %{status: status, expected: "a list", actual: "nothing"}
        %Event{id: id, type: "step.completed", actor: %{kind: :machine}, payload: %{step_id: "walk_2", outcome: "passed", result: result}}
      end

      # A QA step's answer that could not be judged counts, and is no failed step.
      assert {"qa_step_answer", _seen} = Watch.trigger([answer.("n1", "plan_mismatch")], run, @watch, MapSet.new())
      assert {"qa_step_answer", _seen} = Watch.trigger([answer.("n4", "blocked")], run, @watch, MapSet.new())
      assert {"qa_step_answer", _seen} = Watch.trigger([%{answer.("n5", "blocked") | payload: %{step_id: "w", outcome: "passed", result: %{"status" => "blocked"}}}], run, @watch, MapSet.new())
      assert Watch.trigger([answer.("n2", "pass")], run, @watch, MapSet.new()) == nil
      assert Watch.trigger([answer.("n6", "fail")], run, @watch, MapSet.new()) == nil
      assert Watch.trigger([%Event{id: "n7", type: "note", payload: %{text: "A plain note."}}], run, @watch, MapSet.new()) == nil
      # An agent's step.completed that carries a result is not the pass's answer.
      agent_answer = %{answer.("n3", "blocked") | actor: %{kind: :agent, run_kind: "qa", run_id: "r"}}
      assert Watch.trigger([agent_answer], run, @watch, MapSet.new()) == nil
    end

    test "a run past its minutes or its tokens counts while it stays over", %{run: run} do
      old = %{run | started_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)}
      assert {"run_minutes", _seen} = Watch.trigger([], old, @watch, MapSet.new())
      assert {"run_tokens", _seen} = Watch.trigger([], %{run | total_tokens: 1_000}, @watch, MapSet.new())
      assert Watch.trigger([], Map.delete(run, :started_at), @watch, MapSet.new()) == nil
    end
  end

  test "the running runs come from the orchestrator's snapshot, none while it can't answer" do
    assert Watch.running_in(%{running: [%{run_id: "r"}]}) == [%{run_id: "r"}]
    assert Watch.running_in(:unavailable) == []
    assert Watch.running_in(:timeout) == []
  end

  test "a run may be looked at when no turn runs on it, it has turns left and the interval passed" do
    idle = %{turns: 0, last_ms: nil, seen: MapSet.new(), busy: false}
    assert Watch.may_look?(idle, @watch, 0)
    refute Watch.may_look?(%{idle | busy: true}, @watch, 0)
    refute Watch.may_look?(%{idle | turns: 2}, @watch, 0)
    refute Watch.may_look?(%{idle | last_ms: 0}, @watch, 60_000)
    assert Watch.may_look?(%{idle | last_ms: 0}, @watch, 600_000)
  end

  test "the live state names the run's steps, the step it is on, its newest lines, minutes and tokens", %{run: run} do
    events = [
      %Event{id: "s1", type: "step.started", payload: %{step_id: "code", title: "Write the code", mode: "delegated"}},
      step("c1", "code", "passed"),
      %Event{id: "w1", type: "step.completed", payload: %{step_id: "walk_1", outcome: "passed", result: %{"status" => "fail"}}},
      %Event{id: "s2", type: "step.started", payload: %{step_id: "build", title: "Build", mode: "machine"}}
    ]

    run = Map.put(run, :transcript_buffer, ["compiling", %{message: "error: undefined"}, {:raw, 1}])
    live = Watch.live(run, events)

    assert %{kind: "implementation", model: "m", harness: "claude", tokens: 10, elapsed_minutes: 0} = live
    assert live.steps == [%{event_id: "c1", step_id: "code", outcome: "passed"}, %{event_id: "w1", step_id: "walk_1", outcome: "failed"}]
    assert live.current_step == %{step_id: "build", title: "Build", mode: "machine"}
    assert live.newest_lines == ["compiling", "error: undefined", "{:raw, 1}"]
    assert Watch.live(%{run | run_profile: nil}, []).current_step == nil
  end

  describe "the failed step's output" do
    defp kept(ctx, kind, name, text) do
      path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
      File.write!(path, text)
      on_exit(fn -> File.rm(path) end)
      meta = %{repo_key: "default", issue_id: ctx.issue_id, run_id: ctx.run.run_id, kind: kind, label: name}
      {:ok, %{id: id}} = Artifacts.ingest(path, meta)
      id
    end

    defp failed(id, artifacts), do: %Event{id: id, type: "step.completed", payload: %{step_id: "build", title: "Build", outcome: "failed"}, artifacts: artifacts}

    test "the newest failed step carries the tail of its output", ctx do
      old = kept(ctx, "step_output", "old", "an old failure")
      output = kept(ctx, "step_output", "new", Enum.map_join(1..60, "\n", &"line #{&1}"))

      live = Watch.live(ctx.run, [failed("f1", [old]), step("c1", "code", "passed"), failed("f2", [output])])

      assert %{step_id: "build", title: "Build", output: text} = live.failed_step
      assert String.starts_with?(text, "line 21")
      assert String.ends_with?(text, "line 60")
    end

    test "an output over 3000 characters keeps its end", ctx do
      id = kept(ctx, "step_output", "long", String.duplicate("x", 5_000) <> "\nthe real error")
      %{failed_step: %{output: text}} = Watch.live(ctx.run, [failed("f1", [id])])
      assert String.length(text) <= 3_003 + String.length(" [cut by Symphony]")
      assert String.ends_with?(text, "the real error")
    end

    test "a failed step with no readable output has none, and no failure has no failed step", ctx do
      log = kept(ctx, "log", "log", "not step output")
      assert %{failed_step: %{output: nil}} = Watch.live(ctx.run, [failed("f1", [])])
      assert %{failed_step: %{output: nil}} = Watch.live(ctx.run, [failed("f2", [log, "missing"])])
      assert Watch.live(ctx.run, [step("c1", "code", "passed")]).failed_step == nil
    end
  end

  describe "the watch" do
    test "does nothing while it is off", %{run: run} do
      %{pid: pid} = start_watch!(running: fn -> [run] end)
      send(pid, :tick)
      refute_receive {:turn, _run_id, _trigger, _watch}, 100
    end

    test "looks at a run that needs it, one turn at a time and no more than its limit", %{run: run, issue_id: issue_id} do
      watch_on!()
      old = %{run | started_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)}
      %{pid: pid} = start_watch!(running: fn -> [old, %{issue_id: issue_id, run_id: nil}] end)

      send(pid, :tick)
      assert_receive {:turn, run_id, "run_minutes", ^pid}
      assert run_id == run.run_id
      send(pid, :tick)
      refute_receive {:turn, _run_id, _trigger, _watch}, 100

      send(pid, {:watch_done, run.run_id})
      send(pid, {:watch_done, "another-run"})
      send(pid, {:ticket_event, %{type: "step.completed", issue_id: issue_id}})
      assert_receive {:turn, ^run_id, "run_minutes", ^pid}

      send(pid, {:watch_done, run.run_id})
      send(pid, :tick)
      refute_receive {:turn, _run_id, _trigger, _watch}, 100, "two turns is the run's limit"
      send(pid, :unrelated)
      assert Process.alive?(pid)
    end

    test "listens to the ticket events only while it is on" do
      %{pid: pid} = start_watch!(subscribe: true, running: fn -> [] end)
      send(pid, :tick)
      refute :sys.get_state(pid).subscribed

      path = Workflow.symphony_file_path()
      original = File.read!(path)
      watch_on!()
      send(pid, :tick)
      assert :sys.get_state(pid).subscribed
      send(pid, :tick)
      assert :sys.get_state(pid).subscribed

      File.write!(path, original)
      Cache.clear()
      send(pid, :tick)
      refute :sys.get_state(pid).subscribed
    end

    test "drops what still waited for a run that ended", %{run: run, issue_id: issue_id} do
      watch_on!()
      test = self()
      Agent.start_link(fn -> [%{run | started_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)}] end, name: :watch_test_running)
      %{pid: pid} = start_watch!(running: fn -> Agent.get(:watch_test_running, & &1) end, start_turn: fn run, _trigger, _watch -> send(test, {:turn, run.run_id}) end)

      send(pid, :tick)
      assert_receive {:turn, _run_id}
      Steer.queue(run.run_id, %{text: "Never reached.", when: "next_turn", trigger: "run_minutes", repo_key: "default", issue_id: issue_id})
      Agent.update(:watch_test_running, fn _runs -> [] end)
      send(pid, :tick)
      :sys.get_state(pid)

      assert [%{type: "conductor.steer", payload: %{text: "Never reached."}}] =
               issue_id |> Facts.events() |> Enum.filter(&(&1.type == "conductor.steer"))
    end

    test "reads the orchestrator's running runs, none while it is down, and starts a turn on its own that always reports back" do
      watch_on!()
      %{pid: pid} = start_watch!([])
      send(pid, :tick)
      assert :sys.get_state(pid).runs == %{}

      # A turn on a repository Symphony doesn't know fails at once; the watch still hears it is done.
      run = %{issue_id: "issue-none", run_id: "run-none", repo_key: "no-such-repo", started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)}

      capture_log(fn ->
        %{pid: watch} = start_watch!(running: fn -> [run] end, start_turn: nil)
        send(watch, :tick)
        eventually(fn -> match?(%{"run-none" => %{turns: 1, busy: false}}, :sys.get_state(watch).runs) end)
      end)
    end
  end
end
