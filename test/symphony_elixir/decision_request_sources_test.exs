defmodule SymphonyElixir.DecisionRequestSourcesTest do
  @moduledoc """
  Every question a person is asked goes through the one writer, `SymphonyElixir.DecisionRequest`:
  each source below raises its requests with `DecisionRequest.ask/4` (or sets the hold again for a
  request already posted with `DecisionRequest.project/4`), and no other code sets a Needs Decision
  hold, renders a request comment or records `decision.requested`. A new source must call the
  writer and be named here, or this test fails.
  """
  use ExUnit.Case, async: true

  # Each source, and what it asks.
  @sources %{
    # An agent's `linear_request_human_action`: a run's own question, a plan's open choices, a
    # rework that failed the same way twice.
    "lib/symphony_elixir/agent_tools/linear.ex" => [:ask, :project],
    # A closed, missing or empty pull request.
    "lib/symphony_elixir/closed_pull_request.ex" => [:ask],
    # A Code Review escalation.
    "lib/symphony_elixir/code_review.ex" => [:ask],
    # A dependency change the package check keeps out.
    "lib/symphony_elixir/dependency_gate.ex" => [:ask],
    # The step into Merging with manual review on.
    "lib/symphony_elixir/merge_confirmation.ex" => [:ask],
    # The Inbox's reconciliation of a request already on the ticket.
    "lib/symphony_elixir/needs_decision_hold.ex" => [:project],
    # The PR and CI watcher's questions: a protected file, a missing pull request, another base
    # branch, a check that never reported or keeps being cancelled.
    "lib/symphony_elixir/pr_decision/apply.ex" => [:ask],
    # A QA pass that ends without a result.
    "lib/symphony_elixir/qa_verification.ex" => [:ask],
    # A self-heal with no next step.
    "lib/symphony_elixir/self_heal.ex" => [:ask]
  }

  @writer "lib/symphony_elixir/decision_request.ex"
  # The store the writer writes through records the ledger event; the backfill rebuilds history from
  # holds already set, and asks nothing.
  @decision_event_writers ["lib/symphony_elixir/hold.ex", "lib/symphony_elixir/ticket_events/backfill.ex"]

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
    callers = for {path, text} <- lib_files(), path != @writer, text =~ ~r/DecisionRequest\.(ask|project)\(/, into: MapSet.new(), do: path
    assert callers == MapSet.new(Map.keys(@sources))
  end

  test "no code but the writer sets a Needs Decision hold or renders a request comment" do
    for {path, text} <- lib_files(), path != @writer do
      refute text =~ ~r/Hold\.set\([^\n]*needs_decision/, "#{path} sets a Needs Decision hold outside the writer"
      refute text =~ ~r/Request\.render_hold\(/, "#{path} renders a request comment outside the writer"
    end
  end

  test "no code but the writer's store and the history backfill records decision.requested" do
    for {path, text} <- lib_files(), path not in @decision_event_writers do
      refute text =~ ~r/record_event\([^\n]*"decision\.requested"/, "#{path} records decision.requested outside the writer"
      refute text =~ ~r/built\([^\n]*"decision\.requested"/, "#{path} records decision.requested outside the writer"
    end
  end
end
