defmodule SymphonyElixirWeb.TicketEventsControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "repo-a"
  @issue_id "issue-1"
  @path "/api/v1/repos/repo-a/tickets/TP-1/events"
  @base ~U[2026-10-18 10:00:00.000000Z]
  # The `?group=run` answer for the fixture ticket: the contract the app's timeline decodes.
  @fixture Path.expand("../../fixtures/api/ticket_events_feed.json", __DIR__)
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())
    workspace = Path.join(System.tmp_dir!(), "symphony-ticket-events-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(Paths.artifacts_dir())
    end)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, issue_identifier: "TP-1"})
    %{workspace: workspace}
  end

  describe "the operator's walkthrough" do
    test "a finished implementation run and a failed QA run come back with their events, the QA run's verdict and findings, and screenshot URLs that open",
         %{workspace: workspace} do
      fixture_ticket!(workspace)

      %{"timeline" => timeline} = json_response(get(build_conn(), @path <> "?group=run"), 200)

      assert %{"status" => "ended", "verdict" => nil, "exit" => "handoff", "events" => impl_events} = run(timeline, "run-impl-1")
      assert Enum.map(impl_events, & &1["type"]) == ["run.started", "note", "run.ended"]

      assert %{"status" => "ended", "verdict" => %{"kind" => "qa", "outcome" => "fail", "head" => "bbb2222"}, "events" => qa_events} = run(timeline, "run-qa-1")
      assert Enum.map(qa_events, & &1["type"]) == ["run.started", "finding.recorded", "finding.recorded", "verdict.recorded", "run.ended"]

      [two_shots, one_shot] = Enum.filter(qa_events, &(&1["type"] == "finding.recorded"))
      assert [%{"available" => true, "url" => url, "kind" => "screenshot", "mime" => "image/png"}, %{"available" => true}] = two_shots["artifacts"]
      assert [%{"available" => false, "url" => "/api/v1/artifacts/" <> _id}] = one_shot["artifacts"]
      assert response(get(build_conn(), url), 200) == @png <> <<1>>
    end

    test "a QA run still under way says it is running", %{workspace: workspace} do
      fixture_ticket!(workspace)

      %{"timeline" => timeline} = json_response(get(build_conn(), @path <> "?group=run"), 200)

      assert %{"status" => "running", "verdict" => nil, "ended_at" => nil, "exit" => nil, "run_kind" => "qa", "run_number" => 2} = run(timeline, "run-qa-2")
    end
  end

  describe "?group=run" do
    test "nests events under their run and under their parent, at any depth, and keeps the rest at the top level in time order" do
      started = record!("run.started", %{run_id: "run-1", run_kind: "qa", run_number: 1}, at(1), run_id: "run-1")
      record!("phase.entered", %{to: "QA", from: "Code Review"}, at(2))
      parent = record!("note", %{text: "step 1"}, at(3), run_id: "run-1")
      child = record!("note", %{text: "step 1.1"}, at(4), run_id: "run-1", parent: parent.id)
      record!("note", %{text: "step 1.1.1"}, at(5), parent: child.id)
      record!("note", %{text: "no such run"}, at(6), run_id: "run-unknown")
      record!("note", %{text: "no such parent"}, at(7), parent: "missing")

      %{"timeline" => timeline, "next_since" => next_since} = json_response(get(build_conn(), @path <> "?group=run"), 200)

      assert [
               %{"kind" => "run", "run_id" => "run-1", "status" => "running", "events" => [run_started, step]},
               %{"type" => "phase.entered", "children" => []},
               %{"payload" => %{"text" => "no such run"}, "run_id" => "run-unknown", "children" => []},
               %{"payload" => %{"text" => "no such parent"}, "children" => []}
             ] = timeline

      assert run_started["id"] == started.id
      assert %{"payload" => %{"text" => "step 1"}, "children" => [%{"payload" => %{"text" => "step 1.1"}, "children" => [deepest]}]} = step
      assert %{"payload" => %{"text" => "step 1.1.1"}, "children" => []} = deepest
      assert next_since == DateTime.to_iso8601(at(7))
    end

    test "a run's header comes from the ticket's whole history, not the page" do
      record!("run.started", %{run_id: "run-1", run_kind: "qa", run_number: 3, head: "abc1234"}, at(1), run_id: "run-1")
      record!("note", %{text: "walking"}, at(2), run_id: "run-1")
      record!("verdict.recorded", %{kind: "qa", outcome: "fail", head: "abc1234"}, at(3), run_id: "run-1")
      record!("verdict.recorded", %{kind: "qa", outcome: "pass", head: "abc1234"}, at(4), run_id: "run-1")

      since = URI.encode_www_form(DateTime.to_iso8601(at(3)))
      %{"timeline" => [run]} = json_response(get(build_conn(), @path <> "?group=run&since=#{since}"), 200)

      assert %{
               "kind" => "run",
               "run_id" => "run-1",
               "run_kind" => "qa",
               "run_number" => 3,
               "status" => "running",
               "started_at" => started_at,
               "ended_at" => nil,
               "head" => "abc1234",
               "summary" => %{"title" => "QA run 3 started"},
               "verdict" => %{"kind" => "qa", "outcome" => "pass", "head" => "abc1234", "at" => verdict_at},
               "events" => [%{"type" => "verdict.recorded", "payload" => %{"outcome" => "pass"}}]
             } = run

      assert started_at == DateTime.to_iso8601(at(1))
      assert verdict_at == DateTime.to_iso8601(at(4))

      record!("run.ended", %{run_id: "run-1", exit: "ended normally", head: "def5678"}, at(5), run_id: "run-1")
      since = URI.encode_www_form(DateTime.to_iso8601(at(4)))
      %{"timeline" => [run]} = json_response(get(build_conn(), @path <> "?group=run&since=#{since}"), 200)

      assert %{"status" => "ended", "ended_at" => ended_at, "exit" => "ended normally", "head" => "def5678", "run_number" => 3} = run
      assert ended_at == DateTime.to_iso8601(at(5))
      assert %{"verdict" => %{"outcome" => "pass"}, "events" => [%{"type" => "run.ended"}]} = run
    end

    test "a run that spans two pages shows on each with that page's events" do
      record!("run.started", %{run_id: "run-1", run_kind: "implementation"}, at(1), run_id: "run-1")
      record!("note", %{text: "one"}, at(2), run_id: "run-1")
      record!("note", %{text: "two"}, at(3), run_id: "run-1")

      %{"timeline" => [first], "next_since" => since} = json_response(get(build_conn(), @path <> "?group=run&limit=2"), 200)
      %{"timeline" => [second]} = json_response(get(build_conn(), @path <> "?group=run&limit=2&since=#{URI.encode_www_form(since)}"), 200)

      assert %{"run_id" => "run-1", "events" => [%{"type" => "run.started"}, %{"type" => "note"}]} = first
      assert %{"run_id" => "run-1", "started_at" => started_at, "events" => [%{"payload" => %{"text" => "two"}}]} = second
      assert started_at == first["started_at"]
    end

    test "the checked-in fixture equals the answer for the fixture ticket", %{workspace: workspace} do
      fixture_ticket!(workspace)

      body = json_response(get(build_conn(), @path <> "?group=run"), 200)

      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1", do: File.write!(@fixture, [Jason.encode_to_iodata!(body, pretty: true), "\n"])
      assert body == @fixture |> File.read!() |> Jason.decode!()
    end

    test "a ticket with 10,000 events answers one page in under 200 ms" do
      events =
        for n <- 1..10_000 do
          run_id = "run-#{div(n - 1, 100)}"

          {type, payload, opts} =
            case rem(n - 1, 100) do
              0 -> {"run.started", %{run_id: run_id, run_kind: "qa"}, [run_id: run_id]}
              99 -> {"run.ended", %{run_id: run_id, exit: "ended normally"}, [run_id: run_id]}
              _step -> {"note", %{text: "note #{n}"}, [run_id: run_id]}
            end

          {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, DateTime.add(@base, n, :second)))
          event
        end

      {:ok, _events} = RunStore.append_ticket_events(events)

      {micros, conn} = :timer.tc(fn -> get(build_conn(), @path <> "?group=run&limit=500") end)

      assert %{"timeline" => [%{"kind" => "run", "events" => run_events} | _] = timeline} = json_response(conn, 200)
      assert length(run_events) == 100
      assert timeline |> Enum.map(&length(&1["events"])) |> Enum.sum() == 200
      assert micros < 200_000, "one page took #{div(micros, 1000)} ms"
    end
  end

  test "lists a ticket's events oldest first, each with its summary, and filters them by type" do
    record!("verdict.recorded", %{kind: "qa", outcome: "pass", head: "abc1234"}, at(3))
    record!("phase.entered", %{to: "QA", from: "Code Review"}, at(1))
    record!("run.started", %{run_id: "run-1", run_kind: "qa", run_number: 1}, at(2), run_id: "run-1")

    body = json_response(get(build_conn(), @path), 200)

    assert [entered, started, verdict] = body["events"]
    assert %{"type" => "phase.entered", "seq" => 2, "summary" => %{"title" => "Entered QA from Code Review"}, "actor" => %{"kind" => "machine"}} = entered
    assert %{"type" => "run.started", "run_id" => "run-1", "summary" => %{"title" => "QA run 1 started"}} = started
    assert %{"type" => "verdict.recorded", "payload" => %{"kind" => "qa", "outcome" => "pass"}, "summary" => %{"title" => "QA verdict: pass"}} = verdict
    assert verdict["at"] == DateTime.to_iso8601(at(3))
    assert body["next_since"] == verdict["at"]

    assert %{"events" => [%{"type" => "verdict.recorded"}]} = json_response(get(build_conn(), @path <> "?types=verdict.recorded"), 200)

    assert %{"events" => [%{"type" => "phase.entered"}, %{"type" => "verdict.recorded"}]} =
             json_response(get(build_conn(), @path <> "?types=verdict.recorded,%20phase.entered"), 200)

    assert %{"events" => [%{"run_id" => "run-1"}]} = json_response(get(build_conn(), @path <> "?run_id=run-1"), 200)
    assert %{"events" => [_, _, _]} = json_response(get(build_conn(), @path <> "?run_id[]=run-1&types=&since=&limit="), 200)
  end

  test "paging with next_since returns every event exactly once" do
    for minute <- [1, 2, 2, 2, 3, 4, 5], do: record!("note", %{text: "at #{minute}"}, at(minute))

    pages = page([], nil)

    assert Enum.map(pages, &length/1) == [4, 2, 1]
    assert pages |> List.flatten() |> Enum.map(& &1["seq"]) |> Enum.sort() == Enum.to_list(1..7)

    since = DateTime.to_iso8601(at(5))
    assert %{"events" => [], "next_since" => ^since} = json_response(get(build_conn(), @path <> "?since=#{since}"), 200)
  end

  test "caps a page at 200 events" do
    for n <- 1..201, do: record!("note", %{text: "note #{n}"}, DateTime.add(@base, n, :second))

    assert %{"events" => events} = json_response(get(build_conn(), @path <> "?limit=500"), 200)
    assert length(events) == 200
    assert %{"events" => events} = json_response(get(build_conn(), @path), 200)
    assert length(events) == 50
  end

  test "an unknown ticket is 404" do
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/repo-a/tickets/TP-404/events"), 404)
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/repo-b/tickets/TP-1/events"), 404)
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/%20/tickets/TP-1/events"), 404)
  end

  test "an unknown type, a bad since or a bad limit is 400, and other methods are 405" do
    queries = ["types=verdict.recorded,bogus", "types[]=note", "since=yesterday", "since[]=x", "limit=0", "limit=ten", "limit[]=1", "group=day", "group[]=run"]

    for query <- queries do
      assert %{"error" => %{"code" => "invalid_query", "message" => message}} = json_response(get(build_conn(), @path <> "?" <> query), 400)
      assert is_binary(message)
    end

    assert %{"error" => %{"message" => "Unknown event type(s): bogus"}} = json_response(get(build_conn(), @path <> "?types=bogus"), 400)
    assert %{"error" => %{"message" => "group must be run"}} = json_response(get(build_conn(), @path <> "?group=day"), 400)
    assert %{"error" => %{"code" => "ticket_not_found"}} = json_response(get(build_conn(), "/api/v1/repos/repo-a/tickets/TP-404/events?group=run"), 404)
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(post(build_conn(), @path, %{}), 405)
  end

  defp page(pages, since) do
    query = if since, do: "?limit=2&since=#{URI.encode_www_form(since)}", else: "?limit=2"

    case json_response(get(build_conn(), @path <> query), 200) do
      %{"events" => []} -> Enum.reverse(pages)
      %{"events" => events, "next_since" => next_since} -> page([events | pages], next_since)
    end
  end

  defp record!(type, payload, at, opts \\ []) do
    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at))
    event
  end

  defp run(timeline, run_id), do: Enum.find(timeline, &(&1["kind"] == "run" and &1["run_id"] == run_id))

  # The fixture ticket: an implementation run that ended; a QA run that failed, with its verdict and
  # two findings, one with two screenshots and one whose screenshot expired; a QA run still running,
  # with a note nested under another by `parent`; phase moves and a person's note. Its events have
  # fixed ids and times, and its screenshots fixed bytes, so its answer never changes.
  defp fixture_ticket!(workspace) do
    [header, narrow, badge] =
      for {n, label} <- [{1, "Run header at 1440×900"}, {2, "Run header at 1100×800"}, {3, "Verdict badge after refresh"}] do
        path = Path.join(workspace, "shot-#{n}.png")
        File.write!(path, @png <> <<n>>)
        {:ok, artifact} = Artifacts.ingest(path, %{repo_key: @repo_key, issue_id: @issue_id, run_id: "run-qa-1", label: label, kind: "screenshot"}, roots: [workspace])
        artifact.id
      end

    {:ok, _expired} = Artifacts.expire(badge)
    implementer = {:agent, "run-impl-1", "implementation"}
    qa = {:agent, "run-qa-1", "qa"}
    qa_again = {:agent, "run-qa-2", "qa"}
    impl_ended = %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, exit: "handoff", head: "bbb2222", duration_ms: 1_020_000}
    qa_ended = %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, exit: "ended normally", head: "bbb2222", duration_ms: 900_000}
    clipped = %{class: "clipped", severity: "major", description: "The run header is cut off.", viewport: "1440×900"}
    missing = %{class: "state missing", severity: "minor", description: "The verdict badge is gone after a refresh."}

    events =
      for {id, minute, type, payload, opts} <- [
            {"ev-01", 1, "phase.entered", %{to: "In Progress", from: "Todo"}, phase: "In Progress"},
            {"ev-02", 2, "run.started", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, head: "aaa1111"}, run_id: "run-impl-1"},
            {"ev-03", 3, "note", %{text: "Plan: group the feed by run."}, actor: implementer},
            {"ev-04", 20, "run.ended", impl_ended, run_id: "run-impl-1"},
            {"ev-05", 30, "phase.entered", %{to: "QA", from: "Code Review"}, phase: "QA"},
            {"ev-06", 31, "run.started", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, head: "bbb2222"}, run_id: "run-qa-1"},
            {"ev-07", 40, "finding.recorded", clipped, actor: qa, artifacts: [header, narrow]},
            {"ev-08", 41, "finding.recorded", missing, actor: qa, artifacts: [badge]},
            {"ev-09", 45, "verdict.recorded", %{kind: "qa", outcome: "fail", head: "bbb2222"}, run_id: "run-qa-1"},
            {"ev-10", 46, "run.ended", qa_ended, run_id: "run-qa-1"},
            {"ev-11", 47, "phase.entered", %{to: "Rework", from: "QA"}, phase: "Rework"},
            {"ev-12", 50, "note", %{text: "Keep the run header visible when the pane is narrow."}, actor: {:person, "Director"}},
            {"ev-13", 70, "phase.entered", %{to: "QA", from: "Code Review"}, phase: "QA"},
            {"ev-14", 71, "run.started", %{run_id: "run-qa-2", run_kind: "qa", run_number: 2, head: "ccc3333"}, run_id: "run-qa-2"},
            {"ev-15", 72, "note", %{text: "Walking step 1 at 1440×900."}, actor: qa_again},
            {"ev-16", 73, "note", %{text: "The run header stays visible."}, actor: qa_again, parent: "ev-15"}
          ] do
        {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
        %{event | id: id}
      end

    {:ok, _events} = RunStore.append_ticket_events(events)
  end

  defp at(minute), do: DateTime.add(@base, minute * 60, :second)
end
