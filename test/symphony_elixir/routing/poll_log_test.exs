defmodule SymphonyElixir.Routing.PollLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.PollLog

  @t0 ~U[2026-10-19 09:00:00Z]
  @t1 ~U[2026-10-19 10:00:00Z]

  @repo %{name: "poll-log-app", team: "TP", projects: ["b", "a"], labels: nil, assignee: nil}

  setup do
    :ets.delete_all_objects(PollLog)
    on_exit(fn -> :ets.delete_all_objects(PollLog) end)
  end

  test "keeps each repo's last poll, slimmed to what routing reads, and returns the result it records" do
    issue = %Issue{id: "i1", identifier: "TP-1", description: "Long", comments: [%{body: "hi"}], project: %{id: "p1"}}

    assert PollLog.record(@repo, {:ok, [issue]}, @t0) == {:ok, [issue]}
    assert %{route: {"TP", ["a", "b"], [], nil}, issues: [slim], at: @t0, idle_since: nil} = PollLog.last(@repo)
    assert %Issue{id: "i1", project: %{id: "p1"}, description: nil, comments: []} = slim

    # A failed poll keeps the last one.
    assert PollLog.record(@repo, {:error, :timeout}, @t1) == {:error, :timeout}
    assert %{at: @t0} = PollLog.last(@repo)

    assert PollLog.record(%{name: nil}, {:ok, []}) == {:ok, []}
    assert PollLog.last(%{@repo | name: "poll-log-never"}) == nil
  end

  test "counts a route idle from its first empty poll until one finds an issue" do
    PollLog.record(@repo, {:ok, []}, @t0)
    PollLog.record(@repo, {:ok, []}, @t1)
    assert %{idle_since: @t0, at: @t1} = PollLog.last(@repo)

    PollLog.record(@repo, {:ok, [%Issue{id: "i1"}]}, @t1)
    assert %{idle_since: nil} = PollLog.last(@repo)

    PollLog.record(@repo, {:ok, []}, @t1)
    assert %{idle_since: @t1} = PollLog.last(@repo)
  end

  test "a poll under a changed route starts again, and the old route's poll is not answered" do
    PollLog.record(@repo, {:ok, []}, @t0)
    changed = %{@repo | projects: ["c"]}

    assert PollLog.last(changed) == nil

    PollLog.record(changed, {:ok, []}, @t1)
    assert %{idle_since: @t1} = PollLog.last(changed)
    assert PollLog.last(@repo) == nil
  end

  test "keeps any other issue shape as it is" do
    PollLog.record(@repo, {:ok, [%{id: "raw"}]}, @t0)
    assert %{issues: [%{id: "raw"}]} = PollLog.last(@repo)
  end

  test "records nothing and reports no poll without its server" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, PollLog)
    on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, PollLog) end)

    assert PollLog.record(@repo, {:ok, []}, @t0) == {:ok, []}
    assert PollLog.last(@repo) == nil
  end
end
