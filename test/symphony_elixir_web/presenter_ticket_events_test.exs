defmodule SymphonyElixirWeb.PresenterTicketEventsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixirWeb.Presenter

  @repo_key "repo-a"
  @issue_id "issue-1"
  @base ~U[2026-10-18 10:00:00.000000Z]
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
  @unknown String.duplicate("0", 64)

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())
    workspace = Path.join(System.tmp_dir!(), "symphony-presenter-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(Paths.artifacts_dir())
    end)

    %{workspace: workspace}
  end

  describe "ticket_events_json/3" do
    test "expands each artifact, and says one the store expired or doesn't know is unavailable", %{workspace: workspace} do
      shown = ingest!(workspace, 1, "Home screen")
      expired = ingest!(workspace, 2, "Settings")
      {:ok, _expired} = Artifacts.expire(expired)
      elsewhere = ingest!(workspace, 3, "Another ticket's", issue_id: "issue-2")

      event = event("note", %{text: "shots"}, 1, artifacts: [shown, expired, elsewhere, @unknown])

      assert [%{type: "note", summary: %{title: "Note added"}, artifacts: artifacts}] =
               Presenter.ticket_events_json(@repo_key, @issue_id, [event])

      assert [
               %{id: ^shown, kind: "screenshot", mime: "image/png", label: "Home screen", available: true, url: shown_url},
               %{id: ^expired, label: "Settings", available: false, url: expired_url},
               %{id: ^elsewhere, kind: nil, mime: nil, label: nil, available: false, url: nil},
               %{id: @unknown, kind: nil, mime: nil, label: nil, available: false, url: nil}
             ] = artifacts

      assert shown_url == "/api/v1/artifacts/" <> shown
      assert expired_url == "/api/v1/artifacts/" <> expired
    end
  end

  describe "ticket_timeline_json/4" do
    test "nests an event only under a parent that comes earlier on the page" do
      later = event("note", %{text: "later"}, 2)
      early = event("note", %{text: "early"}, 1, parent: later.id)

      timeline = Presenter.ticket_timeline_json(@repo_key, @issue_id, [early, later], [])

      assert [%{id: early_id, children: []}, %{id: later_id, children: []}] = timeline
      assert {early_id, later_id} == {early.id, later.id}
    end

    test "reads a run known only by its end, and a verdict's head from the event when its payload names none" do
      ended = event("run.ended", %{run_id: "run-1", run_kind: "qa", run_number: 2, exit: "ended normally"}, 2, run_id: "run-1")
      verdict = event("verdict.recorded", %{kind: "qa", outcome: "pass"}, 1, run_id: "run-1", head_sha: "abc1234")

      assert [%{kind: "run", run_id: "run-1", events: [%{type: "run.ended"}]} = run] =
               Presenter.ticket_timeline_json(@repo_key, @issue_id, [ended], [verdict, ended])

      assert %{run_kind: "qa", run_number: 2, status: "ended", started_at: nil, head: nil, summary: %{title: "QA run 2 ended: ended normally"}} = run
      assert %{kind: "qa", outcome: "pass", head: "abc1234"} = run.verdict
    end
  end

  defp event(type, payload, second, opts \\ []) do
    {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, DateTime.add(@base, second, :second)))
    event
  end

  defp ingest!(workspace, n, label, opts \\ []) do
    path = Path.join(workspace, "shot-#{n}.png")
    File.write!(path, @png <> <<n>>)
    meta = %{repo_key: @repo_key, issue_id: Keyword.get(opts, :issue_id, @issue_id), kind: "screenshot", label: label}
    {:ok, artifact} = Artifacts.ingest(path, meta, roots: [workspace])
    artifact.id
  end
end
