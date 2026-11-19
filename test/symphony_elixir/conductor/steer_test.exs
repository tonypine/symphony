defmodule SymphonyElixir.Conductor.SteerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.{Facts, Steer}

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-steer-#{n}"
    :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: issue_id, issue_identifier: "STEER-#{n}", phase: "In Progress"})
    Steer.create_table()
    run_id = "run-steer-#{n}"
    steer = %{text: "Read the build error before you change the code again.", when: "next_turn", trigger: "step_failed", repo_key: "default", issue_id: issue_id}
    %{issue_id: issue_id, run_id: run_id, steer: steer}
  end

  defp watch_on! do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "conductor:\n  enabled: true\n  watch:\n    enabled: true\n")
    Cache.clear()
  end

  defp steers(issue_id), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == "conductor.steer"))

  test "with the watch off, a turn's prompt is its own and nothing is taken", ctx do
    Steer.queue(ctx.run_id, ctx.steer)
    refute Steer.enabled?()
    assert Steer.turn_prompt(ctx.run_id, false, fn -> "the step's prompt" end) == "the step's prompt"
    assert Steer.during_turn(ctx.run_id, fn -> :turned end) == :turned
    assert Steer.interrupt(ctx.run_id) == :no_turn
  end

  test "a queued steer opens the run's next turn and is recorded as delivered there", ctx do
    watch_on!()
    assert Steer.enabled?()
    Steer.queue(ctx.run_id, ctx.steer)
    Steer.queue(ctx.run_id, %{ctx.steer | text: "Then run only the failing test."})

    prompt = Steer.turn_prompt(ctx.run_id, false, fn -> "the step's prompt" end)
    assert prompt =~ ~r/\AGuidance from the Conductor/
    assert prompt =~ "<conductor_guidance>\nRead the build error before you change the code again.\n\nThen run only the failing test.\n</conductor_guidance>"
    assert String.ends_with?(prompt, "\n\nthe step's prompt")

    assert [%{run_id: run_id, payload: %{when: "next_turn", trigger: "step_failed", delivered: %{how: "next_turn", at: _at}}}, _second] = steers(ctx.issue_id)
    assert run_id == ctx.run_id
    assert Steer.turn_prompt(ctx.run_id, false, fn -> "again" end) == "again"
    assert Steer.turn_prompt(nil, false, fn -> "no run" end) == "no run"
  end

  test "a turn resumed after an interrupt is the steer alone, recorded as delivered now", ctx do
    watch_on!()
    Steer.queue(ctx.run_id, %{ctx.steer | when: "now"})
    prompt = Steer.turn_prompt(ctx.run_id, true, fn -> flunk("the resumed turn carries the steer alone") end)
    assert prompt =~ "Guidance from the Conductor"
    assert [%{payload: %{when: "now", delivered: %{how: "now"}}}] = steers(ctx.issue_id)
  end

  test "an interrupt reaches the run's live agent turn only while it runs", ctx do
    watch_on!()
    test = self()

    assert Steer.during_turn(ctx.run_id, fn ->
             assert Steer.interrupt(ctx.run_id) == :sent
             assert_received {:conductor_interrupt, run_id, sent_ms}
             send(test, {:fresh, run_id, Steer.fresh?(sent_ms), Steer.fresh?(sent_ms - 60_000)})
             :turned
           end) == :turned

    assert_received {:fresh, run_id, true, false}
    assert run_id == ctx.run_id
    assert Steer.interrupt(ctx.run_id) == :no_turn
  end

  test "a steer the run never reached is recorded with no delivery when the run ends", ctx do
    Steer.queue(ctx.run_id, ctx.steer)
    assert Steer.drop(ctx.run_id) == :ok
    assert [%{payload: payload}] = steers(ctx.issue_id)
    refute Map.has_key?(payload, :delivered)
    assert Steer.drop(ctx.run_id) == :ok

    log = capture_log(fn -> Steer.record(%{ctx.steer | trigger: "whenever"}, ctx.run_id, nil) end)
    assert log =~ "Conductor could not record its steer"
  end
end
