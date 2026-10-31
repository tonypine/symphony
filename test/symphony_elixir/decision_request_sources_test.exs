defmodule SymphonyElixir.DecisionRequestSourcesTest do
  @moduledoc """
  Every question a person is asked goes through the one writer, `SymphonyElixir.DecisionRequest`:
  each source below raises its requests with `DecisionRequest.ask/4`, and no other code renders a
  request comment or records a `decision.*` event (legacy types: only the history backfill writes
  `decision.recorded`, for decisions stored before). The writer asks each one as a Question
  (`SymphonyElixir.Questions.ask/3`). A new source must call the writer and be named
  here, or this test fails.

  Symphony's own questions with nobody to answer them but a person's pick of what happens next ask
  through the Question service (`SymphonyElixir.Questions.ask/3`) directly; those are named here too.
  """
  use ExUnit.Case, async: true

  # Each source, and what it asks.
  @sources %{
    # A ticket summary over its size limit, before the run's agent starts.
    "lib/symphony_elixir/agent_runner.ex" => [:ask],
    # An agent's `linear_request_human_action`: a run's own question, a plan's open choices, a
    # rework that failed the same way twice.
    "lib/symphony_elixir/agent_tools/linear.ex" => [:ask],
    # A closed, missing or empty pull request.
    "lib/symphony_elixir/closed_pull_request.ex" => [:ask],
    # A Code Review escalation.
    "lib/symphony_elixir/code_review.ex" => [:ask],
    # A dependency change the package check keeps out.
    "lib/symphony_elixir/dependency_gate.ex" => [:ask],
    # The step into Merging with manual review on.
    "lib/symphony_elixir/merge_confirmation.ex" => [:ask],
    # The PR and CI watcher's questions: a protected file, a missing pull request, another base
    # branch, a check that never reported or keeps being cancelled.
    "lib/symphony_elixir/pr_decision/apply.ex" => [:ask],
    # The QA server's seed: the held ticket's open Question, over the memory tracker.
    "lib/symphony_elixir/qa_seed.ex" => [:ask],
    # A QA pass that ends without a result.
    "lib/symphony_elixir/qa_verification.ex" => [:ask],
    # A release build GitHub keeps cancelling for lack of a machine, or one that failed.
    "lib/symphony_elixir/release_build.ex" => [:ask],
    # A self-heal with no next step.
    "lib/symphony_elixir/self_heal.ex" => [:ask]
  }

  # Each module that asks a Question directly, and what it asks.
  @question_sources %{
    # A ticket parked in Backlog after turns with no new commit or state change
    # (`SymphonyElixir.IdlePark`): "<id> is parked: its last N turns changed nothing".
    "lib/symphony_elixir/agent_runner.ex" => [:idle_park],
    # The dispatch-loop guard (`SymphonyElixir.DispatchLoop`) and the quiet handoff: "<id> ran N
    # times in M minutes without finishing" and "<id>'s last two runs ended without a handoff".
    "lib/symphony_elixir/orchestrator.ex" => [:dispatch_loop, :quiet_handoff],
    # The questions the backfill finds in the holds and decisions already recorded.
    "lib/symphony_elixir/pauses/backfill.ex" => [:backfill],
    # A run's block report that names no blocker: "The run on <id> cannot continue on its own".
    "lib/symphony_elixir/transition_guard.ex" => [:block_report]
  }

  @writer "lib/symphony_elixir/decision_request.ex"
  # The history backfill rebuilds the decisions a record stored before as `decision.recorded`.
  @recorded_writers ["lib/symphony_elixir/ticket_events/backfill.ex"]

  defp lib_files do
    root = Path.expand("../..", __DIR__)
    for path <- Path.wildcard(Path.join(root, "lib/**/*.ex")), do: {Path.relative_to(path, root), File.read!(path)}
  end

  test "every source raises its questions through the writer" do
    files = Map.new(lib_files())

    for {source, calls} <- @sources, call <- calls do
      assert files[source] =~ "DecisionRequest.#{call}(", "#{source} should call DecisionRequest.#{call}/4"
    end
  end

  test "the sources named here are every module that calls the writer" do
    callers = for {path, text} <- lib_files(), path != @writer, text =~ ~r/DecisionRequest\.ask\(/, into: MapSet.new(), do: path
    assert callers == MapSet.new(Map.keys(@sources))
  end

  test "the writer asks every request as a Question before its comment" do
    writer = Map.new(lib_files())[@writer]
    assert writer =~ "Questions.ask({:ticket, repo_key, issue_id}, request,"
  end

  test "the modules named here are every one that asks a Question directly" do
    writers = ["lib/symphony_elixir/questions.ex", @writer]
    callers = for {path, text} <- lib_files(), path not in writers, text =~ "Questions.ask(", into: MapSet.new(), do: path
    assert callers == MapSet.new(Map.keys(@question_sources))

    orchestrator = Map.new(lib_files())["lib/symphony_elixir/orchestrator.ex"]
    assert orchestrator =~ "DispatchLoop.question_attrs(loop,"
    assert orchestrator =~ "DispatchLoop.question_attrs({:quiet_handoff,"

    runner = Map.new(lib_files())["lib/symphony_elixir/agent_runner.ex"]
    assert runner =~ "IdlePark.question_attrs("

    guard = Map.new(lib_files())["lib/symphony_elixir/transition_guard.ex"]
    assert guard =~ "Questions.ask(ticket, block_report_question("
  end

  test "no code but the writer renders a request comment" do
    for {path, text} <- lib_files(), path != @writer do
      refute text =~ ~r/Request\.render_hold\(/, "#{path} renders a request comment outside the writer"
    end
  end

  test "no code records a legacy decision event, but the history backfill its stored decisions" do
    for {path, text} <- lib_files() do
      refute text =~ ~r/(record_event|built)\([^\n]*"decision\.(requested|withdrawn)"/, "#{path} records a legacy decision event"
      if path not in @recorded_writers, do: refute(text =~ ~r/(record_event|built)\([^\n]*"decision\.recorded"/, "#{path} records decision.recorded")
    end
  end
end
