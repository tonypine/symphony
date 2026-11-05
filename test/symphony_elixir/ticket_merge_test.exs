defmodule SymphonyElixir.TicketMergeTest do
  # The one record of a ticket left under more than one repository (TP-1338, TP-1423).
  use ExUnit.Case, async: true

  alias SymphonyElixir.{TicketMerge, TicketState}
  alias SymphonyElixir.TicketEvents.Event

  @now ~U[2026-11-03 09:00:00.000000Z]
  @asked_old ~U[2026-10-20 10:00:00.000000Z]
  @asked_new ~U[2026-11-02 10:00:00.000000Z]
  @symphony %{kind: :symphony, name: "Symphony"}
  @issue_id "issue-1"

  test "a moved ticket lands on the repository that saw it last, with both questions and the old one withdrawn" do
    old = question("q-old", "Move it?", @asked_old)
    new = question("q-new", "Ship the fixtures?", @asked_new)

    merge =
      TicketMerge.merge(
        @issue_id,
        [
          entry("symphony", %{
            issue_identifier: "TP-1074",
            phase: "In Progress",
            phase_at: @asked_old,
            observed_at: @asked_old,
            linear_updated_at: @asked_old,
            updated_at: @asked_old,
            questions: [old],
            pause: pause("symphony", ["q-old"], @asked_old)
          }),
          entry("job-search-hub", %{
            issue_identifier: "TP-1074",
            phase: "Rework",
            phase_at: @asked_new,
            observed_at: @asked_new,
            linear_updated_at: @asked_new,
            updated_at: @asked_new,
            questions: [new],
            pause: pause("job-search-hub", ["q-new"], @asked_new)
          })
        ],
        @now
      )

    assert %{repo_key: "job-search-hub", folded: ["symphony"], withdrawn: [%{id: "q-old"}]} = merge
    assert %{repo_key: "job-search-hub", phase: "Rework"} = merge.record
    assert [%{id: "q-old", state: :withdrawn, withdrawn: %{at: @now}}, %{id: "q-new", state: :open}] = merge.record.questions
    assert [%{waits_on: %{question_id: "q-new"}}] = merge.record.pause.reasons
    assert merge.record.pause.subject == {:ticket, "job-search-hub", @issue_id}
    assert [%{type: :pause, at: @now}] = merge.record.pending_projection
    assert [%Event{type: "question.withdrawn", phase: "Rework", payload: %{question_id: "q-old", cause: "superseded_by_move"}}] = merge.events
  end

  test "every event once and in order, and every decision, grant and projection mark once" do
    entries =
      for {repo_key, at, times} <- [
            {"repo-a", ~U[2026-10-01 00:00:00Z], [~U[2026-10-01 01:00:00Z], ~U[2026-10-06 01:00:00Z]]},
            {"repo-b", ~U[2026-10-10 00:00:00Z], [~U[2026-10-02 01:00:00Z], ~U[2026-10-11 01:00:00Z]]},
            {"repo-c", ~U[2026-10-05 00:00:00Z], [~U[2026-10-04 01:00:00Z]]}
          ] do
        attrs = %{
          observed_at: at,
          updated_at: at,
          decisions: [decision(repo_key)],
          path_unlocks: [%{id: "grant-1", run_id: "run-1", at: at}],
          pending_projection: [%{type: :phase, error: "linear down", at: at}]
        }

        repo_key |> entry(attrs) |> Map.put(:events, Enum.map(times, &event(repo_key, &1)))
      end

    shared = event("repo-a", ~U[2026-10-01 01:00:00Z])
    [first | rest] = entries
    merge = TicketMerge.merge(@issue_id, [%{first | events: [shared, shared | first.events]} | rest], @now)

    assert %{repo_key: "repo-b", folded: ["repo-a", "repo-c"], withdrawn: []} = merge
    assert Enum.map(merge.events, & &1.at) == Enum.sort(Enum.map(merge.events, & &1.at), DateTime)
    assert length(merge.events) == 5
    assert Enum.map(merge.record.decisions, & &1.key) == ["d-repo-a", "d-repo-c", "d-repo-b"]
    assert [%{id: "grant-1"}] = merge.record.path_unlocks
    assert length(merge.record.pending_projection) == 3
  end

  test "an event without an id is kept once, by what it says" do
    no_id = %{event("repo-a", @asked_old) | id: nil}
    merge = TicketMerge.merge(@issue_id, [%{entry("repo-a", %{}) | events: [no_id]}, %{entry("repo-b", %{}) | events: [no_id]}], @now)
    assert [%Event{id: nil}] = merge.events
  end

  test "an indexed record is the route, and same-text open questions collapse to the route's" do
    same = question("q-a", "Same ask?", @asked_old)

    merge =
      TicketMerge.merge(
        @issue_id,
        [
          entry("repo-a", %{observed_at: @asked_new, updated_at: @asked_old, questions: [same], pause: pause("repo-a", ["q-a"], @asked_old)}),
          "repo-b"
          |> entry(%{
            observed_at: @asked_old,
            updated_at: @asked_new,
            questions: [%{same | id: "q-b", asked_at: @asked_new}, question("q-done", "Done?", @asked_old, :answered)],
            pause: pause("repo-b", ["q-b"], @asked_new)
          })
          |> Map.put(:indexed, true)
        ],
        @now
      )

    assert %{repo_key: "repo-b", folded: ["repo-a"], withdrawn: []} = merge
    assert [%{id: "q-done"}, %{id: "q-b", state: :open}] = merge.record.questions
    assert [%{waits_on: %{question_id: "q-b"}}] = merge.record.pause.reasons
    assert merge.record.pending_projection == []
  end

  test "a question two records hold is kept once, its ended copy" do
    open = question("q-1", "Keep it?", @asked_old)
    answered = %{open | state: :answered}

    merge = TicketMerge.merge(@issue_id, [entry("repo-a", %{questions: [open]}), entry("repo-b", %{questions: [answered]})], @now)

    assert [%{id: "q-1", state: :answered}] = merge.record.questions
    assert merge.withdrawn == []
  end

  test "every record's history from before the event stream is kept, each entry once, newest first" do
    signal = fn head, at -> %{name: "handoff", details: %{head: head}, at: at} end
    verdict = fn head, at -> %{kind: "code_review", head_sha: head, outcome: "approve", recorded_at: at, details: %{}} end
    dispatch = fn run_id, at -> %{kind: "implementation", state: "QA", head: nil, run_id: run_id, at: at, outcome: nil} end

    old = %{signals: [signal.("old", @asked_old)], verdicts: [verdict.("old", @asked_old)], dispatches: [dispatch.("run-old", @asked_old)]}
    new = %{signals: [signal.("new", @asked_new), signal.("old", @asked_old)], verdicts: [verdict.("new", @asked_new)], dispatches: []}

    merge = TicketMerge.merge(@issue_id, [history_entry("repo-a", old), history_entry("repo-b", new)], @now)

    assert %{signals: [%{details: %{head: "new"}}, %{details: %{head: "old"}}], verdicts: [%{head_sha: "new"}, %{head_sha: "old"}], dispatches: [%{run_id: "run-old"}]} =
             TicketState.legacy_history(merge.record)
  end

  test "the report counts the merges and the questions they withdrew" do
    merge =
      TicketMerge.merge(
        @issue_id,
        [entry("repo-a", %{issue_identifier: "ACME-1", questions: [question("q-1", "Move?", @asked_old)]}), entry("repo-b", %{issue_identifier: "ACME-1", observed_at: @asked_new})],
        @now
      )

    assert TicketMerge.report([{@issue_id, merge}], 4, @now) == %{
             name: "records.merged",
             at: @now,
             checked: 4,
             merged: 1,
             merges: [%{issue_id: @issue_id, issue_identifier: "ACME-1", repo_key: "repo-b", folded: ["repo-a"]}],
             withdrawn: 1
           }

    assert %{merged: 0, merges: [], withdrawn: 0} = TicketMerge.report([], 0, @now)
  end

  defp entry(repo_key, attrs), do: %{repo_key: repo_key, record: TicketState.normalize(TicketState.new(repo_key, @issue_id, attrs)), events: [], indexed: false}

  defp history_entry(repo_key, history) do
    record = repo_key |> TicketState.new(@issue_id) |> Map.delete(:legacy_history) |> Map.merge(history) |> TicketState.normalize()
    %{repo_key: repo_key, record: record, events: [], indexed: false}
  end

  defp question(id, title, asked_at, state \\ :open) do
    %{id: id, title: title, question: title, state: state, asked_at: asked_at, asked_by: %{kind: :symphony, name: "Symphony", run_id: nil}, options: []}
  end

  defp pause(repo_key, question_ids, at) do
    reasons =
      for id <- question_ids do
        %{kind: :question, waits_on: %{question_id: id}, text: "Waiting", set_by: @symphony, set_at: at, releasable: false}
      end

    %{subject: {:ticket, repo_key, @issue_id}, reasons: reasons, set_by: @symphony, since: at}
  end

  defp decision(repo_key), do: %{key: "d-#{repo_key}", date: ~D[2026-10-01], title: "Keep it", question: "Keep it?", answer: "Yes", scope: "As answered"}

  defp event(repo_key, at), do: %Event{id: "evt-#{repo_key}-#{DateTime.to_unix(at)}", repo_key: repo_key, issue_id: @issue_id, type: "phase.entered", at: at}
end
