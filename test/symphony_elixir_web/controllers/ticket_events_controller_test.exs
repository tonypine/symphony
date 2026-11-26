defmodule SymphonyElixirWeb.TicketEventsControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixir.Artifacts.Store

  @endpoint SymphonyElixirWeb.Endpoint
  @repo_key "repo-a"
  @issue_id "issue-1"
  @path "/api/v1/repos/repo-a/tickets/TP-1/events"
  @base ~U[2026-10-18 10:00:00.000000Z]
  # The `?group=run` answer for the fixture ticket: the contract the app's timeline decodes.
  @fixture Path.expand("../../fixtures/api/ticket_events_feed.json", __DIR__)
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
  # The Director's step-history fixture (TP-1413): the `?group=run` answer for the step ticket and
  # its outputs, which the app's timeline and its QA pass read.
  @steps_api Path.expand("../../../macos/Tests/Fixtures/director-app/ticket-steps/api/v1", __DIR__)
  # A QA pass whose plan walked three checks of one Settings page in one session (TP-1594): the
  # grouped walk step's `results`, one failed and two passed, as the Director's timeline reads them.
  @grouped_walk_api Path.expand("../../../macos/Tests/Fixtures/director-app/ticket-grouped-walk/api/v1", __DIR__)
  # A ticket with a fact of each kind the ticket page draws (TP-1683): a picture with its artifact,
  # measured values, QA step answers, a code review's verdict with its findings, and a run's changed
  # files and commits, as the app's core decodes them (`TicketFactsTests`).
  @facts_api Path.expand("../../../macos/Tests/Fixtures/director-app/ticket-facts/api/v1", __DIR__)
  # The QA seed's picture, so the seed and the fixture keep the same artifact.
  @picture Path.expand("../../../priv/qa_seed/symphony/pictures/QA-104-activity-filter.png", __DIR__)
  # The QA seed's step transcript read as a conversation (TP-1688), so the seed and the step fixture
  # keep the same lines.
  @conversation Path.expand("../../../priv/qa_seed/symphony/step_transcripts/QA-104-code.ndjson", __DIR__)
  @test_output "1 test, 1 failure\n\n  1) test the timeline shows the failed step (TimelineTest)\n     Assertion with == failed\n     left:  :done\n     right: :failed\n"

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

      assert %{"status" => "ended", "verdict" => nil, "exit" => "handoff", "model" => "claude-opus-5-5", "effort" => "high", "events" => impl_events} = run(timeline, "run-impl-1")
      assert Enum.map(impl_events, & &1["type"]) == ["run.started", "note", "run.ended"]

      assert %{"status" => "ended", "verdict" => %{"kind" => "qa", "outcome" => "fail", "head" => "bbb2222"}, "model" => "claude-sonnet-5-5", "effort" => nil, "events" => qa_events} =
               run(timeline, "run-qa-1")

      assert Enum.map(qa_events, & &1["type"]) == ["run.started", "finding.recorded", "finding.recorded", "verdict.recorded", "run.ended"]

      [two_shots, one_shot] = Enum.filter(qa_events, &(&1["type"] == "finding.recorded"))
      assert [%{"available" => true, "url" => url, "kind" => "screenshot", "mime" => "image/png"}, %{"available" => true}] = two_shots["artifacts"]
      assert [%{"available" => false, "url" => "/api/v1/artifacts/" <> _id}] = one_shot["artifacts"]
      assert response(get(build_conn(), url), 200) == @png <> <<1>>
    end

    test "a run that failed its build reads the failure with the step it went back to, its compiler output one click away and the next attempt below it",
         %{workspace: workspace} do
      output = Path.join(workspace, "build.log")
      File.write!(output, "error: undefined function render/2\n")
      {:ok, log} = Artifacts.ingest(output, %{repo_key: @repo_key, issue_id: @issue_id, run_id: "run-1", label: "Build output", kind: "step_output"}, roots: [workspace])
      agent = {:agent, "run-1", "implementation"}
      code = %{step_id: "code", title: "Writing the code", mode: "delegated"}
      build = %{step_id: "build", title: "Build", mode: "machine"}

      record!("run.started", %{run_id: "run-1", run_kind: "implementation", run_number: 1}, at(1), run_id: "run-1")
      record!("step.started", code, at(2), actor: agent)
      record!("step.completed", Map.put(code, :outcome, "passed"), at(10), actor: agent)
      record!("step.started", Map.put(build, :command, "mix compile --warnings-as-errors"), at(10), run_id: "run-1")

      record!("step.completed", Map.merge(build, %{outcome: "failed", returns_to: "code", returns_to_title: "writing the code", duration_ms: 240_000}), at(14),
        run_id: "run-1",
        artifacts: [log.id]
      )

      record!("step.started", code, at(14), actor: agent)

      %{"timeline" => timeline} = json_response(get(build_conn(), @path <> "?group=run"), 200)
      %{"summary" => line, "status" => "running", "events" => events} = run(timeline, "run-1")
      steps = Enum.filter(events, &String.starts_with?(&1["type"], "step."))

      assert Enum.map(steps, & &1["summary"]["title"]) == ["Step started", "Step passed", "Build started", "Build failed after 4 min: back to writing the code", "Step started"]
      failed = Enum.at(steps, 3)
      assert [%{"kind" => "step_output", "available" => true, "url" => url}] = failed["artifacts"]
      assert response(get(build_conn(), url), 200) == "error: undefined function render/2\n"
      # The next attempt is below the failure, and the run's line names the step it is on.
      assert List.last(steps)["summary"]["detail"] == "Writing the code"
      assert line == %{"title" => "Implementation run 1 running a step", "detail" => "Writing the code"}
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
               "model" => nil,
               "summary" => %{"title" => "QA run 3 started"},
               "verdict" => %{"kind" => "qa", "outcome" => "pass", "head" => "abc1234", "at" => verdict_at},
               "events" => [%{"type" => "verdict.recorded", "payload" => %{"outcome" => "pass"}}]
             } = run

      assert started_at == DateTime.to_iso8601(at(1))
      assert verdict_at == DateTime.to_iso8601(at(4))

      record!("run.ended", %{run_id: "run-1", exit: "ended normally", head: "def5678", model: "claude-sonnet-5-5", effort: "medium"}, at(5), run_id: "run-1")
      since = URI.encode_www_form(DateTime.to_iso8601(at(4)))
      %{"timeline" => [run]} = json_response(get(build_conn(), @path <> "?group=run&since=#{since}"), 200)

      assert %{"status" => "ended", "ended_at" => ended_at, "exit" => "ended normally", "head" => "def5678", "run_number" => 3} = run
      # A start that named no model leaves the run's model to its end.
      assert %{"model" => "claude-sonnet-5-5", "effort" => "medium"} = run
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

    test "the checked-in step fixture equals the answer for the step ticket, with its kept and its gone output", %{workspace: workspace} do
      {kept, gone, transcript} = steps_ticket!(workspace)

      body = json_response(get(build_conn(), @path <> "?group=run"), 200)
      text = response(get(build_conn(), "/api/v1/artifacts/#{kept}"), 200)
      lines = response(get(build_conn(), "/api/v1/artifacts/#{transcript}"), 200)
      # The 410's error, without the times the ingest stamps on the rest of its answer.
      expired = Jason.encode!(%{"error" => json_response(get(build_conn(), "/api/v1/artifacts/#{gone}"), 410)["error"]})
      events = Path.join(@steps_api, "repos/web-shop/tickets/SHOP-410/events.json")
      kept_file = Path.join(@steps_api, "artifacts/#{kept}.txt")
      gone_file = Path.join(@steps_api, "artifacts/#{gone}.410.json")
      transcript_file = Path.join(@steps_api, "artifacts/#{transcript}.txt")

      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1" do
        File.mkdir_p!(Path.dirname(events))
        File.mkdir_p!(Path.dirname(kept_file))
        File.write!(events, [Jason.encode_to_iodata!(body, pretty: true), "\n"])
        File.write!(kept_file, text)
        File.write!(gone_file, expired)
        File.write!(transcript_file, lines)
      end

      assert body == events |> File.read!() |> Jason.decode!()
      assert File.read!(kept_file) == @test_output
      assert File.read!(gone_file) == expired
      assert File.read!(transcript_file) == File.read!(@conversation)

      %{"events" => [_started, _code, %{"artifacts" => [saved]}, _ended]} = run(body["timeline"], "run-impl-2")
      assert %{"id" => ^transcript, "kind" => "transcript", "mime" => "text/x-ndjson", "available" => true} = saved
      assert %{"status" => "running", "events" => [_run_started, %{"type" => "step.started"}]} = run(body["timeline"], "run-impl-3")

      %{"events" => run_events} = run(body["timeline"], "run-impl-1")
      titles = for %{"type" => "step." <> _} = event <- run_events, do: event["summary"]["title"]
      assert "building passed in 2 min" in titles
      assert "tests failed: back to writing the code" in titles
      assert "Paused on your answer" in titles
    end

    test "the checked-in grouped walk fixture equals the answer for a QA pass that walked three checks in one session" do
      grouped_walk_ticket!()

      body = json_response(get(build_conn(), @path <> "?group=run"), 200)
      events = Path.join(@grouped_walk_api, "repos/web-shop/tickets/SHOP-410/events.json")

      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1" do
        File.mkdir_p!(Path.dirname(events))
        File.write!(events, [Jason.encode_to_iodata!(body, pretty: true), "\n"])
      end

      assert body == events |> File.read!() |> Jason.decode!()

      %{"events" => run_events} = run(body["timeline"], "run-qa-1")
      walk = Enum.find(run_events, &(&1["type"] == "step.completed" and &1["payload"]["step_id"] == "walk_1_2_3"))
      assert Enum.map(walk["payload"]["results"], &{&1["step"], &1["status"]}) == [{1, "pass"}, {2, "fail"}, {3, "pass"}]
      assert walk["summary"]["detail"] =~ "Step 2: fail"
    end

    test "the checked-in facts fixture equals the answer for a ticket with a fact of each kind, each as data", %{workspace: workspace} do
      picture = facts_ticket!(workspace)

      body = json_response(get(build_conn(), @path <> "?group=run"), 200)
      events = Path.join(@facts_api, "repos/web-shop/tickets/SHOP-410/events.json")
      picture_file = Path.join(@facts_api, "artifacts/#{picture}.png")

      if System.get_env("SYMPHONY_WRITE_FIXTURES") == "1" do
        File.mkdir_p!(Path.dirname(events))
        File.mkdir_p!(Path.dirname(picture_file))
        File.write!(events, [Jason.encode_to_iodata!(body, pretty: true), "\n"])
        File.cp!(@picture, picture_file)
      end

      assert body == events |> File.read!() |> Jason.decode!()
      assert File.read!(picture_file) == response(get(build_conn(), "/api/v1/artifacts/#{picture}"), 200)

      grouped = Enum.flat_map(body["timeline"], &Map.get(&1, "events", [&1]))
      %{"events" => flat} = json_response(get(build_conn(), @path), 200)

      # The flat answer and the grouped one carry each fact the same way.
      for events <- [grouped, flat] do
        of = fn type -> Enum.filter(events, &(&1["type"] == type)) end

        # A picture: an evidence whose artifact is a screenshot, with its address.
        assert [shot, measured] = of.("evidence")
        url = "/api/v1/artifacts/" <> picture
        assert [%{"id" => ^picture, "kind" => "screenshot", "mime" => "image/png", "available" => true, "url" => ^url}] = shot["artifacts"]
        assert %{"caption" => "Settings after the relaunch" <> _, "step" => "1", "environment" => "fixture"} = shot["payload"]
        assert %{"status" => "pass", "expected" => "The filter" <> _, "actual" => "It is" <> _} = shot["payload"]["result"]

        # A measured value: its name, number, unit and the number expected.
        assert [%{"name" => "Window width", "value" => 1440, "unit" => "pt", "expected" => 1440}, %{"value" => 0.42, "unit" => "s"} = timing] =
                 measured["payload"]["measures"]

        refute Map.has_key?(timing, "expected")

        # A QA step's answer, on a check step and per walkthrough step of a grouped walk.
        [check, walk] = Enum.filter(of.("step.completed"), &(&1["run_id"] == "run-qa-1" and &1["payload"]["step_id"] in ["check_1", "walk_2_3"]))
        assert %{"status" => "pass", "measures" => [%{"name" => "Rows shown", "value" => 3, "unit" => "rows"}]} = check["payload"]["result"]
        assert [%{"step" => 2, "status" => "pass"}, %{"step" => 3, "status" => "fail", "measures" => [%{"value" => 0, "expected" => 80}]}] = walk["payload"]["results"]

        # A review's verdict with its findings, each with its file and line range.
        assert [%{"payload" => verdict}, _qa] = of.("verdict.recorded")
        assert %{"kind" => "code_review", "outcome" => "rework", "findings" => [first, second], "unread_files" => ["docs/settings.md"]} = verdict
        assert %{"file" => "lib/web_shop/settings.ex", "line_range" => %{"start" => 42, "end" => 47}, "quoted_snippet" => "filter = " <> _, "suggested_fix" => _} = first
        assert %{"line_range" => %{"start" => 9, "end" => 9}, "decision" => "D1", "since_last_review" => "unchanged"} = second

        # A run's test result, as the counts it recorded, and the check a test proves.
        assert [%{"run_id" => "run-impl-1", "payload" => %{"passed" => 41, "failed" => 1, "skipped" => 2, "duration_ms" => 95_000}}] = of.("tests.ran")
        assert [%{"payload" => %{"check_id" => "c1", "by" => "test", "test" => "test/web_shop/filter_test.exs: " <> _}}] = of.("check.proved")

        # The files a run edited and the commits it made.
        assert [%{"payload" => changed}] = of.("run.changed")
        assert %{"start_head" => "aaa1111", "head" => "bbb2222", "commit_count" => 3, "file_count" => 3} = changed
        assert [%{"sha" => "c0ffee1" <> _, "subject" => "Keep the filter in settings"}, %{"sha" => "bbb2222" <> _}] = changed["commits"]

        assert [%{"path" => "lib/web_shop/filter.ex", "status" => "added"}, %{"status" => "modified"}, %{"status" => "renamed", "from" => "lib/web_shop/pane.ex"}] =
                 changed["files"]
      end
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

    File.rm!(Store.path(badge))
    {:error, :expired} = Artifacts.path(badge)
    implementer = {:agent, "run-impl-1", "implementation"}
    qa = {:agent, "run-qa-1", "qa"}
    qa_again = {:agent, "run-qa-2", "qa"}

    impl_ended = %{
      run_id: "run-impl-1",
      run_kind: "implementation",
      run_number: 1,
      model: "claude-opus-5-5",
      effort: "high",
      exit: "handoff",
      head: "bbb2222",
      duration_ms: 1_020_000
    }

    qa_ended = %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, model: "claude-sonnet-5-5", exit: "ended normally", head: "bbb2222", duration_ms: 900_000}
    clipped = %{class: "clipped", severity: "major", description: "The run header is cut off.", viewport: "1440×900"}
    missing = %{class: "state missing", severity: "minor", description: "The verdict badge is gone after a refresh."}

    events =
      for {id, minute, type, payload, opts} <- [
            {"ev-01", 1, "phase.entered", %{to: "In Progress", from: "Todo"}, phase: "In Progress"},
            {"ev-02", 2, "run.started", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, head: "aaa1111", model: "claude-opus-5-5", effort: "high"}, run_id: "run-impl-1"},
            {"ev-03", 3, "note", %{text: "Plan: group the feed by run."}, actor: implementer},
            {"ev-04", 20, "run.ended", impl_ended, run_id: "run-impl-1"},
            {"ev-05", 30, "phase.entered", %{to: "QA", from: "Code Review"}, phase: "QA"},
            {"ev-06", 31, "run.started", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, head: "bbb2222", model: "claude-sonnet-5-5"}, run_id: "run-qa-1"},
            {"ev-07", 40, "finding.recorded", clipped, actor: qa, artifacts: [header, narrow]},
            {"ev-08", 41, "finding.recorded", missing, actor: qa, artifacts: [badge]},
            {"ev-09", 45, "verdict.recorded", %{kind: "qa", outcome: "fail", head: "bbb2222"}, run_id: "run-qa-1"},
            {"ev-10", 46, "run.ended", qa_ended, run_id: "run-qa-1"},
            {"ev-11", 47, "phase.entered", %{to: "Rework", from: "QA"}, phase: "Rework"},
            {"ev-12", 50, "note", %{text: "Keep the run header visible when the pane is narrow."}, actor: {:person, "Director"}},
            {"ev-13", 70, "phase.entered", %{to: "QA", from: "Code Review"}, phase: "QA"},
            {"ev-14", 71, "run.started", %{run_id: "run-qa-2", run_kind: "qa", run_number: 2, head: "ccc3333", model: "claude-sonnet-5-5"}, run_id: "run-qa-2"},
            {"ev-15", 72, "note", %{text: "Walking step 1 at 1440×900."}, actor: qa_again},
            {"ev-16", 73, "note", %{text: "The run header stays visible."}, actor: qa_again, parent: "ev-15"}
          ] do
        {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
        %{event | id: id}
      end

    {:ok, _events} = RunStore.append_ticket_events(events)
  end

  # The step ticket: an implementation run whose agent wrote the code, whose build passed with an
  # output Symphony no longer keeps, whose tests failed back to writing the code with their output
  # kept, and whose next attempt paused on a question. Fixed ids, times and bytes, so its answer
  # never changes. Its second implementation run wrote the code with a saved transcript that reads as
  # a conversation (the QA seed's: notes, folded actions, a repeated failure, a silent stretch), and
  # its third is still writing the code. Returns the kept output's id, the gone one's and the
  # transcript's.
  defp steps_ticket!(workspace) do
    [kept, gone] =
      for {name, label, bytes} <- [{"tests.txt", "Test output", @test_output}, {"build.txt", "Build output", "Compiling 3 files (.ex)\nGenerated symphony app\n"}] do
        path = Path.join(workspace, name)
        File.write!(path, bytes)
        meta = %{repo_key: @repo_key, issue_id: @issue_id, run_id: "run-impl-1", label: label, kind: "step_output"}
        {:ok, artifact} = Artifacts.ingest(path, meta, roots: [workspace])
        artifact.id
      end

    File.rm!(Store.path(gone))
    {:error, :expired} = Artifacts.path(gone)
    lines_path = Path.join(workspace, "code.ndjson")
    File.cp!(@conversation, lines_path)
    lines_meta = %{repo_key: @repo_key, issue_id: @issue_id, run_id: "run-impl-2", label: "Write the code transcript", kind: "transcript"}
    {:ok, %{id: transcript}} = Artifacts.ingest(lines_path, lines_meta, roots: [workspace])
    agent = {:agent, "run-impl-1", "implementation"}
    second = {:agent, "run-impl-2", "implementation"}
    third = {:agent, "run-impl-3", "implementation"}
    write = %{step_id: "code", title: "Write the code", mode: "delegated"}
    code = %{step_id: "code", title: "writing the code", mode: "delegated"}
    build = %{step_id: "build", title: "building", mode: "machine"}
    tests = %{step_id: "tests", title: "tests", mode: "machine"}
    failed = %{outcome: "failed", returns_to: "code", returns_to_title: "writing the code"}

    events =
      for {id, minute, type, payload, opts} <- [
            {"st-01", 1, "phase.entered", %{to: "In Progress", from: "Todo"}, phase: "In Progress"},
            {"st-02", 2, "run.started", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, head: "aaa1111"}, run_id: "run-impl-1"},
            {"st-03", 3, "step.started", code, actor: agent},
            {"st-04", 10, "step.completed", Map.put(code, :outcome, "passed"), actor: agent},
            {"st-05", 10, "step.started", Map.put(build, :command, "mix compile --warnings-as-errors"), run_id: "run-impl-1"},
            {"st-06", 12, "step.completed", Map.merge(build, %{outcome: "passed", duration_ms: 120_000}), run_id: "run-impl-1", artifacts: [gone]},
            {"st-07", 12, "step.started", Map.put(tests, :command, "mix test"), run_id: "run-impl-1"},
            {"st-08", 15, "step.completed", Map.merge(tests, failed), run_id: "run-impl-1", artifacts: [kept]},
            {"st-09", 15, "step.started", code, actor: agent},
            {"st-10", 20, "step.completed", Map.merge(code, %{outcome: "paused", question_id: "question-1"}), actor: agent},
            {"st-11", 21, "run.ended", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, exit: "paused", duration_ms: 1_140_000}, run_id: "run-impl-1"},
            # The seed's transcript runs from 08:41 to 08:53 on 2026-10-30: the second run holds it.
            {"st-12", ~U[2026-10-30 08:40:00.000000Z], "run.started", %{run_id: "run-impl-2", run_kind: "implementation", run_number: 2, head: "bbb2222"}, run_id: "run-impl-2"},
            {"st-13", ~U[2026-10-30 08:40:30.000000Z], "step.started", write, actor: second},
            {"st-14", ~U[2026-10-30 08:54:00.000000Z], "step.completed", Map.put(write, :outcome, "passed"), actor: second, artifacts: [transcript]},
            {"st-15", ~U[2026-10-30 08:55:00.000000Z], "run.ended", %{run_id: "run-impl-2", run_kind: "implementation", run_number: 2, exit: "success", duration_ms: 900_000}, run_id: "run-impl-2"},
            # The third run is still writing the code: its lines are the ticket's run now (SHOP-410.json).
            {"st-16", ~U[2026-10-30 09:00:00.000000Z], "run.started", %{run_id: "run-impl-3", run_kind: "implementation", run_number: 3, head: "ccc3333"}, run_id: "run-impl-3"},
            {"st-17", ~U[2026-10-30 09:00:30.000000Z], "step.started", write, actor: third}
          ] do
        {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
        %{event | id: id}
      end

    {:ok, _events} = RunStore.append_ticket_events(events)
    {kept, gone, transcript}
  end

  # The grouped walk ticket: a QA pass that planned four checks, walked steps 1 to 3 (one Settings
  # page, one state) in one session with step 2 failed, walked step 4 (a smaller window) alone, and
  # gave its verdict.
  defp grouped_walk_ticket! do
    run = [run_id: "run-qa-1"]
    plan = %{step_id: "plan", title: "Plan the pass", mode: "orchestrated"}
    launch = %{step_id: "launch", title: "Launch the app", mode: "machine"}
    group = %{step_id: "walk_1_2_3", title: "Walk a step 1, 2, 3", mode: "orchestrated"}
    alone = %{step_id: "walk_4", title: "Walk a step 4", mode: "orchestrated"}
    review = %{step_id: "review", title: "Review and verdict", mode: "orchestrated"}

    checks = [
      %{title: "Step 1: Settings", expect: "The side list shows General first"},
      %{title: "Step 2: Settings", expect: "Agents shows its three rows"},
      %{title: "Step 3: Settings", expect: "Repos lists web-shop"},
      %{title: "Step 4: Settings, small window", expect: "The side list collapses to icons"}
    ]

    summary = "QA plan. Needs the app: yes. Steps 1 to 3 share the Settings page and are walked in one session; step 4 needs a smaller window."

    results = [
      %{step: 1, status: "pass", expected: "The side list shows General first", actual: "General is first and selected"},
      %{step: 2, status: "fail", expected: "Agents shows its three rows", actual: "Agents shows two rows; Codex is missing"},
      %{step: 3, status: "pass", expected: "Repos lists web-shop", actual: "web-shop is listed with its path"}
    ]

    events =
      for {id, minute, type, payload, opts} <- [
            {"gw-01", 1, "phase.entered", %{to: "QA", from: "Code Review"}, phase: "QA"},
            {"gw-02", 2, "run.started", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, head: "bbb2222"}, run},
            {"gw-03", 2, "step.started", Map.merge(plan, %{model: "claude-opus-5-5", session: "lead", prompt_ref: "phases.qa.playbooks.macos_app.steps.plan"}), run},
            {"gw-04", 4, "step.completed", Map.merge(plan, %{outcome: "passed", duration_ms: 120_000, plan: %{checks: checks, skips: [], summary: summary}}), run},
            {"gw-05", 4, "step.started", Map.put(launch, :command, "symphony:qa_launch"), run},
            {"gw-06", 5, "step.completed", Map.merge(launch, %{outcome: "passed", duration_ms: 60_000}), run},
            {"gw-07", 5, "step.started", Map.merge(group, %{model: "claude-sonnet-5-5", session: "fresh", prompt_ref: "phases.qa.playbooks.macos_app.steps.walk_1_2_3"}), run},
            {"gw-08", 9, "step.completed", Map.merge(group, %{outcome: "passed", duration_ms: 240_000, results: results}), run},
            {"gw-09", 9, "step.started", Map.merge(alone, %{model: "claude-sonnet-5-5", session: "fresh", prompt_ref: "phases.qa.playbooks.macos_app.steps.walk_4"}), run},
            {"gw-10", 12, "step.completed",
             Map.merge(alone, %{outcome: "passed", duration_ms: 180_000, result: %{status: "pass", expected: "The side list collapses to icons", actual: "It collapses to icons"}}), run},
            {"gw-11", 12, "step.started", Map.merge(review, %{model: "claude-opus-5-5", session: "lead", prompt_ref: "phases.qa.playbooks.macos_app.steps.review"}), run},
            {"gw-12", 14, "step.completed", Map.merge(review, %{outcome: "passed", duration_ms: 120_000, verdict_summary: "Step 2 fails: the Agents section shows two of its three rows."}), run},
            {"gw-13", 14, "verdict.recorded", %{kind: "qa", outcome: "fail", head: "bbb2222"}, run},
            {"gw-14", 15, "run.ended", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, exit: "normal", duration_ms: 780_000}, run}
          ] do
        {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
        %{event | id: id}
      end

    {:ok, _events} = RunStore.append_ticket_events(events)
    :ok
  end

  # The facts ticket: an implementation run that changed three files in two commits (of three, the
  # list cut), a code review that sent it back with two findings, and a QA pass whose check step
  # answered with a measure, whose grouped walk judged two steps, which took a picture and measured
  # the window, and which passed. Fixed ids, times and bytes, so its answer never changes. Returns
  # the picture's id.
  defp facts_ticket!(workspace) do
    path = Path.join(workspace, "settings.png")
    File.cp!(@picture, path)
    meta = %{repo_key: @repo_key, issue_id: @issue_id, run_id: "run-qa-1", label: "Settings after the relaunch", kind: "screenshot"}
    {:ok, %{id: picture}} = Artifacts.ingest(path, meta, roots: [workspace])

    impl = [run_id: "run-impl-1"]
    review = [run_id: "run-review-1"]
    qa = [run_id: "run-qa-1"]
    qa_agent = [actor: {:agent, "run-qa-1", "qa"}]
    impl_agent = [actor: {:agent, "run-impl-1", "implementation"}]
    check = %{step_id: "check_1", title: "The filter survives a relaunch", mode: "orchestrated"}
    walk = %{step_id: "walk_2_3", title: "Walk a step 2, 3", mode: "orchestrated"}
    expected = "The filter is still Failed after a relaunch"

    changed = %{
      run_id: "run-impl-1",
      start_head: "aaa1111",
      head: "bbb2222",
      commits: [%{sha: "c0ffee1a2b3c4d5e6f708192a3b4c5d6e7f80912", subject: "Keep the filter in settings"}, %{sha: "bbb2222aa41f00d", subject: "Restore the filter at launch"}],
      files: [
        %{path: "lib/web_shop/filter.ex", status: "added"},
        %{path: "lib/web_shop/settings.ex", status: "modified"},
        %{path: "lib/web_shop/tab.ex", status: "renamed", from: "lib/web_shop/pane.ex"}
      ],
      commit_count: 3,
      file_count: 3
    }

    findings = [
      %{
        summary: "The filter is read before the settings load, so a relaunch shows All.",
        file: "lib/web_shop/settings.ex",
        line_range: %{start: 42, end: 47},
        quoted_snippet: "filter = settings.filter || :all",
        suggested_fix: "Read the filter once the settings have loaded."
      },
      %{
        summary: "The default filter is not the one D1 chose.",
        file: "lib/web_shop/filter.ex",
        line_range: %{start: 9, end: 9},
        quoted_snippet: "@default :all",
        suggested_fix: "Default to :failed, as D1 says.",
        decision: "D1",
        since_last_review: "unchanged"
      }
    ]

    verdict = %{kind: "code_review", outcome: "rework", head: "bbb2222", findings: findings, comments: ["Restore the filter after the settings load."], unread_files: ["docs/settings.md"]}
    rows_shown = %{name: "Rows shown", value: 3, unit: "rows", expected: 3}
    check_result = %{status: "pass", expected: expected, actual: "It is Failed", measures: [rows_shown]}

    results = [
      %{step: 2, status: "pass", actual: "Clearing the filter shows every row"},
      %{step: 3, status: "fail", expected: "The filter menu names the filter", actual: "The menu shows no name", measures: [%{name: "Menu label width", value: 0, unit: "pt", expected: 80}]}
    ]

    shot = %{caption: "Settings after the relaunch, filter still Failed", step: "1", environment: "fixture", result: %{status: "pass", expected: expected, actual: "It is Failed"}}
    measures = [%{name: "Window width", value: 1440, unit: "pt", expected: 1440}, %{name: "Filter restored after launch", value: 0.42, unit: "s"}]

    events =
      for {id, minute, type, payload, opts} <- [
            {"fx-01", 1, "phase.entered", %{to: "In Progress", from: "Todo"}, phase: "In Progress"},
            {"fx-02", 2, "run.started", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, head: "aaa1111"}, impl},
            {"fx-03", 20, "run.ended", %{run_id: "run-impl-1", run_kind: "implementation", run_number: 1, exit: "handoff", head: "bbb2222", duration_ms: 1_080_000}, impl},
            {"fx-04", 20, "run.changed", changed, impl},
            {"fx-05", 21, "run.started", %{run_id: "run-review-1", run_kind: "code_review", run_number: 1, head: "bbb2222"}, review},
            {"fx-06", 30, "verdict.recorded", verdict, review},
            {"fx-07", 30, "run.ended", %{run_id: "run-review-1", run_kind: "code_review", run_number: 1, exit: "ended normally", duration_ms: 540_000}, review},
            {"fx-08", 40, "run.started", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, head: "bbb2222"}, qa},
            {"fx-09", 41, "step.started", Map.put(check, :prompt_ref, "phases.qa.playbooks.macos_app.steps.check_1"), qa},
            {"fx-10", 44, "evidence", shot, qa_agent ++ [artifacts: [picture]]},
            {"fx-11", 45, "evidence", %{caption: "The window and how long the filter took to come back", measures: measures}, qa_agent},
            {"fx-12", 46, "step.completed", Map.merge(check, %{outcome: "passed", duration_ms: 300_000, result: check_result}), qa},
            {"fx-13", 46, "step.started", Map.put(walk, :prompt_ref, "phases.qa.playbooks.macos_app.steps.walk_2_3"), qa},
            {"fx-14", 50, "step.completed", Map.merge(walk, %{outcome: "passed", duration_ms: 240_000, results: results}), qa},
            {"fx-15", 51, "verdict.recorded", %{kind: "qa", outcome: "pass", head: "bbb2222"}, qa},
            {"fx-16", 52, "run.ended", %{run_id: "run-qa-1", run_kind: "qa", run_number: 1, exit: "ended normally", duration_ms: 720_000}, qa},
            {"fx-17", 18, "tests.ran", %{passed: 41, failed: 1, skipped: 2, duration_ms: 95_000}, impl_agent},
            {"fx-18", 19, "check.proved", %{check_id: "c1", by: "test", test: "test/web_shop/filter_test.exs: keeps the filter after a relaunch"}, impl_agent}
          ] do
        {:ok, event} = TicketEvents.build(@repo_key, @issue_id, type, payload, Keyword.put(opts, :at, at(minute)))
        %{event | id: id}
      end

    {:ok, _events} = RunStore.append_ticket_events(events)
    picture
  end

  defp at(%DateTime{} = at), do: at
  defp at(minute), do: DateTime.add(@base, minute * 60, :second)
end
