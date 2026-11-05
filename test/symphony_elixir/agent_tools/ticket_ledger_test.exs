defmodule SymphonyElixir.AgentTools.TicketLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.TicketLedger
  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.TicketEvents.Types
  alias SymphonyElixirWeb.Presenter

  @repo_key "repo-a"
  @issue_id "issue-1"
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>

  setup do
    :ok = RunStore.clear()
    File.rm_rf!(Paths.artifacts_dir())

    base = Path.join(System.tmp_dir!(), "symphony-ticket-ledger-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    tmp_dir = Path.join(base, "tmp")
    outside = Path.join(base, "outside")
    Enum.each([workspace, tmp_dir, outside], &File.mkdir_p!/1)

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(Paths.artifacts_dir())
    end)

    %{workspace: workspace, tmp_dir: tmp_dir, outside: outside}
  end

  defp session(ctx, extra \\ []) do
    [
      issue: %Issue{id: @issue_id, identifier: "TP-1", repo_key: @repo_key},
      workspace: ctx.workspace,
      agent_tmp_dir: ctx.tmp_dir,
      run_id: "run-1",
      run_kind: "rework"
    ]
    |> Keyword.merge(extra)
  end

  defp call(tool, args, opts) do
    response = DynamicTool.execute(tool, args, opts)
    {response["success"], Jason.decode!(response["output"])}
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp record!(type, payload, opts) do
    {:ok, event} = TicketEvents.record(@repo_key, @issue_id, type, payload, opts)
    event
  end

  defp nothing_written do
    assert RunStore.list_ticket_events(@issue_id, []) == []
    assert Artifacts.list() == []
  end

  describe "the user walkthrough" do
    test "a rework run asks for its open findings across heads and gets them with their screenshot links, naming no ticket", ctx do
      qa = [actor: {:agent, "qa-1", "qa"}]

      {:ok, shot} =
        Artifacts.ingest(write!(ctx.workspace, "qa-evidence/clipped.png", @png), %{repo_key: @repo_key, issue_id: @issue_id, kind: "screenshot", label: "clipped.png"}, roots: [ctx.workspace])

      first = record!("finding.recorded", %{class: "clipped", severity: "major", description: "Totals hidden"}, qa ++ [head_sha: "aaa", artifacts: [shot.id]])
      fixed = record!("finding.recorded", %{class: "truncated", severity: "minor", description: "Title cut"}, qa ++ [head_sha: "aaa"])
      second = record!("finding.recorded", %{class: "mechanism", severity: "major", description: "Scroll broken"}, qa ++ [head_sha: "bbb"])

      assert {true, %{"event" => %{"type" => "finding.resolved", "head_sha" => nil, "id" => resolution, "payload" => %{"head" => "ccc"}}}} =
               call("ticket_record", %{"type" => "finding.resolved", "payload" => %{"finding_id" => fixed.id, "how" => "Wrapped the title", "head" => "ccc"}}, session(ctx))

      assert {true, %{"events" => events}} = call("ticket_events", %{"open_findings" => true}, session(ctx))
      assert Enum.map(events, & &1["id"]) == [first.id, fixed.id, second.id]
      assert Enum.map(events, & &1["head_sha"]) == ["aaa", "aaa", "bbb"]
      assert Enum.map(events, & &1["finding"]["state"]) == ["open", "resolved_awaiting_qa", "open"]

      assert %{"resolution" => ^resolution, "resolved_on" => "ccc", "reopened_by" => nil, "superseded" => nil, "confirmed_by" => nil} =
               Enum.at(events, 1)["finding"]

      # QA's next fail on the same step reopens it, pointing at the resolution it supersedes.
      reopen = record!("finding.recorded", %{class: "truncated", severity: "minor", description: "Title still cut"}, qa ++ [supersedes: resolution])
      assert {true, %{"events" => events}} = call("ticket_events", %{"open_findings" => true}, session(ctx))
      assert Enum.map(events, & &1["id"]) == [first.id, fixed.id, second.id]
      reopen_id = reopen.id
      assert %{"state" => "reopened", "reopened_by" => ^reopen_id, "superseded" => ^resolution, "resolution" => nil} = Enum.at(events, 1)["finding"]

      # The reopening reads as an event, not a finding of its own.
      assert {true, %{"events" => all}} = call("ticket_events", %{"types" => ["finding.recorded"]}, session(ctx))
      refute Map.has_key?(List.last(all), "finding")

      assert [%{"id" => id, "kind" => "screenshot", "label" => "clipped.png", "url" => url}] = hd(events)["artifacts"]
      assert id == shot.id
      assert url == "/api/v1/artifacts/" <> shot.id
    end

    test "a run that tries to record a verdict is refused, with the list of what it may record", ctx do
      assert {false, %{"error" => error}} =
               call("ticket_record", %{"type" => "verdict.recorded", "payload" => %{"kind" => "qa", "outcome" => "pass"}}, session(ctx))

      assert %{"reason" => "not_allowed", "allowed" => allowed, "schema" => %{"required" => [_ | _]}} = error
      assert allowed == Types.agent_types("rework")
      assert error["message"] =~ "may not record verdict.recorded"
      nothing_written()
    end

    test "a note recorded with a screenshot from the workspace reaches the ticket's timeline with the image", ctx do
      write!(ctx.workspace, "shots/home.png", @png)

      assert {true, %{"event" => event}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "Home looks right"}, "artifacts" => ["shots/home.png"]}, session(ctx))

      assert %{"type" => "note", "actor" => %{"kind" => "agent", "run_id" => "run-1", "run_kind" => "rework"}, "run_id" => "run-1"} = event
      assert %{"summary" => %{"title" => _}, "seq" => 1} = event
      assert [%{"kind" => "screenshot", "label" => "home.png"}] = event["artifacts"]

      stored = RunStore.list_ticket_events(@issue_id, [])

      assert [%{type: "note", artifacts: [%{kind: "screenshot", available: true, url: "/api/v1/artifacts/" <> _}]}] =
               Presenter.ticket_timeline_json(@repo_key, @issue_id, stored, stored)
    end
  end

  describe "ticket_record's refusals" do
    test "verdict.recorded is refused for every agent run kind", ctx do
      for kind <- Types.agent_run_kinds() do
        assert {false, %{"error" => %{"reason" => "not_allowed", "allowed" => allowed}}} =
                 call("ticket_record", %{"type" => "verdict.recorded", "payload" => %{"kind" => "qa", "outcome" => "pass"}}, session(ctx, run_kind: kind))

        refute "verdict.recorded" in allowed
      end

      nothing_written()
    end

    test "finding.recorded is refused for an implementation run and taken from a QA run", ctx do
      payload = %{"class" => "clipped", "severity" => "major", "description" => "Totals hidden"}

      assert {false, %{"error" => %{"reason" => "not_allowed", "allowed" => allowed}}} =
               call("ticket_record", %{"type" => "finding.recorded", "payload" => payload}, session(ctx, run_kind: "implementation"))

      refute "finding.recorded" in allowed
      nothing_written()

      assert {true, %{"event" => %{"type" => "finding.recorded"}}} = call("ticket_record", %{"type" => "finding.recorded", "payload" => payload}, session(ctx, run_kind: "qa"))
    end

    test "a legacy or machine type is never an agent's, and an unknown type names what the run may record", ctx do
      for type <- ["decision.requested", "phase.entered", "pause.set", "question.asked", "run.started", "attempt.pushed", "person.action", "workspace.synced"] do
        assert {false, %{"error" => %{"reason" => "not_allowed"}}} = call("ticket_record", %{"type" => type, "payload" => %{}}, session(ctx))
      end

      assert {false, %{"error" => error}} = call("ticket_record", %{"type" => "nope", "payload" => %{}}, session(ctx))
      assert %{"reason" => "unknown_type", "allowed" => allowed} = error
      assert allowed == Types.agent_types("rework")
      refute Map.has_key?(error, "schema")
      nothing_written()
    end

    test "a note over 4,000 characters is invalid_payload naming text, and nothing is written", ctx do
      assert {false, %{"error" => error}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => String.duplicate("a", 4_001)}, "artifacts" => []}, session(ctx))

      assert %{"reason" => "invalid_payload", "fields" => ["text"], "schema" => %{"required" => [%{"name" => "text", "max" => 4_000}]}} = error
      nothing_written()
    end

    test "an evidence's proof must name the step and the test", ctx do
      bad = %{"caption" => "Step 2 proved", "proof" => %{"step" => 2}}

      assert {false, %{"error" => %{"reason" => "invalid_payload", "fields" => ["proof"]}}} =
               call("ticket_record", %{"type" => "evidence", "payload" => bad}, session(ctx))

      good = %{"caption" => "Step 2 proved", "proof" => %{"step" => 2, "test" => "ticket_ledger_test.exs"}}

      assert {true, %{"event" => %{"payload" => %{"proof" => %{"step" => 2, "test" => "ticket_ledger_test.exs"}}}}} =
               call("ticket_record", %{"type" => "evidence", "payload" => good}, session(ctx))
    end

    test "an artifact outside the workspace and $TMPDIR is refused, and nothing is written", ctx do
      write!(ctx.workspace, "ok.png", @png)
      outside = write!(ctx.outside, "secret.png", @png)

      assert {false, %{"error" => error}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "artifacts" => ["ok.png", outside]}, session(ctx))

      assert %{"reason" => "invalid_artifact", "path" => ^outside, "schema" => %{}} = error
      assert error["message"] =~ "outside the workspace and $TMPDIR"
      nothing_written()
    end

    test "a link in the workspace to a file outside it, a folder, a missing file and a non-path are refused", ctx do
      target = write!(ctx.outside, "secret.png", @png)
      File.ln_s!(target, Path.join(ctx.workspace, "link.png"))
      File.mkdir_p!(Path.join(ctx.workspace, "folder"))
      file = write!(ctx.workspace, "plain.txt", "x")

      for {path, why} <- [
            {"link.png", "outside the workspace"},
            {"folder", "not a regular file"},
            {"missing.png", "cannot be read"},
            {Path.join(file, "below"), "cannot be read"},
            {"", "not a path"},
            {7, "not a path"}
          ] do
        assert {false, %{"error" => %{"reason" => "invalid_artifact", "message" => message}}} =
                 call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "artifacts" => [path]}, session(ctx))

        assert message =~ why
      end

      assert {false, %{"error" => %{"reason" => "invalid_artifact", "message" => message}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "artifacts" => "a.png"}, session(ctx))

      assert message =~ "must be a list"
      nothing_written()
    end

    test "a file over the store's cap is refused", ctx do
      path = Workflow.symphony_file_path()
      File.write!(path, File.read!(path) <> "ledger:\n  artifact_max_bytes: 4\n")
      Cache.clear()
      write!(ctx.tmp_dir, "big.log", "too many bytes")

      assert {false, %{"error" => %{"reason" => "invalid_artifact", "message" => message}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "artifacts" => [Path.join(ctx.tmp_dir, "big.log")]}, session(ctx))

      assert message =~ "could not be kept (:too_large)"
      nothing_written()
    end

    test "files from $TMPDIR are kept with their kind; a .png that is no image is a plain file", ctx do
      log = write!(ctx.tmp_dir, "run.log", "line")
      fake = write!(ctx.tmp_dir, "fake.png", "not an image")
      other = write!(ctx.workspace, "report.html", "<p>")

      assert {true, %{"event" => %{"artifacts" => artifacts}}} =
               call("ticket_record", %{"type" => "evidence", "payload" => %{"caption" => "Logs"}, "artifacts" => [log, fake, other]}, session(ctx))

      assert Enum.map(artifacts, & &1["kind"]) == ["log", "file", "file"]
    end

    test "a $TMPDIR that cannot be resolved adds no root", ctx do
      file = write!(ctx.outside, "plain.txt", "x")
      log = write!(ctx.outside, "run.log", "line")

      assert {false, %{"error" => %{"reason" => "invalid_artifact"}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "artifacts" => [log]}, session(ctx, agent_tmp_dir: Path.join(file, "tmp")))
    end

    test "a resolution must name a finding of the ticket, and a parent an event of the ticket", ctx do
      note = record!("note", %{text: "first"}, [])

      assert {false, %{"error" => %{"reason" => "unknown_finding", "schema" => _}}} =
               call("ticket_record", %{"type" => "finding.resolved", "payload" => %{"finding_id" => note.id, "how" => "x"}}, session(ctx))

      finding = record!("finding.recorded", %{class: "clipped", severity: "major", description: "Cut"}, actor: {:agent, "qa-1", "qa"})

      assert {false, %{"error" => %{"reason" => "no_head", "message" => message}}} =
               call("ticket_record", %{"type" => "finding.resolved", "payload" => %{"finding_id" => finding.id, "how" => "x"}}, session(ctx))

      assert message =~ "head"

      assert {true, %{"event" => %{"id" => resolution}}} =
               call("ticket_record", %{"type" => "finding.resolved", "payload" => %{"finding_id" => finding.id, "how" => "x", "head" => "abc"}}, session(ctx))

      assert {false, %{"error" => %{"reason" => "already_resolved", "resolution" => ^resolution}}} =
               call("ticket_record", %{"type" => "finding.resolved", "payload" => %{"finding_id" => finding.id, "how" => "again", "head" => "abc"}}, session(ctx))

      assert {false, %{"error" => %{"reason" => "unknown_parent"}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "parent" => "01NOPE"}, session(ctx))

      assert {false, %{"error" => %{"reason" => "unknown_parent"}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}, "parent" => 5}, session(ctx))

      assert {true, %{"event" => %{"parent" => parent}}} =
               call("ticket_record", %{"type" => "step.started", "payload" => %{"title" => "Walk step 1", "mode" => "orchestrated"}, "parent" => note.id}, session(ctx))

      assert parent == note.id
    end

    test "a session with no ticket is refused by both tools", ctx do
      for {tool, args} <- [{"ticket_events", %{}}, {"ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}}}] do
        assert {false, %{"error" => %{"reason" => "no_ticket"}}} = call(tool, args, session(ctx, issue: nil))
        assert {false, %{"error" => %{"reason" => "no_ticket"}}} = call(tool, args, session(ctx, issue: %Issue{id: @issue_id}))
      end
    end

    test "Symphony fills the head from the workspace and the phase from the ticket's record; issue_id and repo_key may come from the session", ctx do
      git = fn args -> {_out, 0} = System.cmd("git", ["-c", "user.name=T", "-c", "user.email=t@x", "-C", ctx.workspace | args], stderr_to_stdout: true) end
      git.(["init", "-q"])
      git.(["commit", "-q", "--allow-empty", "-m", "start"])
      {head, 0} = System.cmd("git", ["-C", ctx.workspace, "rev-parse", "HEAD"])
      head = String.trim(head)
      from_session_ids = session(ctx, issue: nil, issue_id: @issue_id, repo_key: @repo_key)
      :ok = RunStore.put_ticket_state(%{repo_key: @repo_key, issue_id: @issue_id, phase: "Rework"})

      assert {true, %{"event" => %{"head_sha" => ^head}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "x"}}, from_session_ids)

      assert [%{phase: "Rework", head_sha: ^head}] = RunStore.list_ticket_events(@issue_id, [])

      assert {true, %{"event" => %{"head_sha" => nil}}} =
               call("ticket_record", %{"type" => "note", "payload" => %{"text" => "y"}}, session(ctx, workspace: nil))
    end
  end

  describe "the run kind a session records as" do
    test "is the runner's, else the run profile's, else the scope's, else an implementation run's", ctx do
      base = Keyword.delete(session(ctx), :run_kind)

      for {opts, kind} <- [
            {[run_kind: :ci_fix], "ci_fix"},
            {[run_profile: %{kind: :breakdown}], "breakdown"},
            {[tool_scope: :read_only], "code_review"},
            {[tool_scope: :qa], "qa"},
            {[], "implementation"}
          ] do
        assert {false, %{"error" => %{"allowed" => allowed}}} =
                 call("ticket_record", %{"type" => "verdict.recorded", "payload" => %{}}, Keyword.merge(base, opts))

        assert allowed == Types.agent_types(kind)
      end
    end
  end

  describe "ticket_events' filters" do
    setup ctx do
      older = record!("note", %{text: "one"}, at: ~U[2026-11-01 10:00:00.000000Z], actor: {:agent, "run-a", "implementation"})
      newer = record!("note", %{text: "two"}, at: ~U[2026-11-02 10:00:00.000000Z], actor: {:agent, "run-b", "rework"})
      step = record!("step.started", %{title: "Walk", mode: "orchestrated"}, at: ~U[2026-11-03 10:00:00.000000Z], actor: {:agent, "run-b", "rework"}, artifacts: ["missing-id"])
      Map.merge(ctx, %{older: older, newer: newer, step: step})
    end

    test "types, since, run_id and limit narrow the read", ctx do
      ids = fn args ->
        {true, %{"events" => events}} = call("ticket_events", args, session(ctx))
        Enum.map(events, & &1["id"])
      end

      assert ids.(%{}) == [ctx.older.id, ctx.newer.id, ctx.step.id]
      assert ids.(%{"types" => ["note"]}) == [ctx.older.id, ctx.newer.id]
      assert ids.(%{"since" => "2026-11-01T12:00:00Z"}) == [ctx.newer.id, ctx.step.id]
      assert ids.(%{"run_id" => "run-a"}) == [ctx.older.id]
      assert ids.(%{"limit" => 1}) == [ctx.older.id]
      assert ids.(%{"open_findings" => false, "types" => nil}) == [ctx.older.id, ctx.newer.id, ctx.step.id]
    end

    test "an artifact the store no longer knows reads with no kind and no url", ctx do
      {true, %{"events" => events}} = call("ticket_events", %{"types" => ["step.started"]}, session(ctx))
      assert [%{"artifacts" => [%{"id" => "missing-id", "kind" => nil, "label" => nil, "url" => nil}]}] = events
    end

    test "an argument out of shape is refused, naming it", ctx do
      for {key, value} <- [{"since", "yesterday"}, {"limit", 500}, {"limit", 0}, {"types", [1]}, {"types", "note"}, {"open_findings", "yes"}, {"run_id", 3}] do
        assert {false, %{"error" => %{"reason" => "invalid_argument", "message" => message}}} = call("ticket_events", %{key => value}, session(ctx))
        assert message =~ "`#{key}`"
      end
    end
  end

  describe "the tools in every scope" do
    test "declare their arguments, which DynamicTool takes and nothing else" do
      assert TicketLedger.tool_arguments() == %{
               "ticket_events" => ["types", "since", "run_id", "open_findings", "limit"],
               "ticket_record" => ["type", "payload", "artifacts", "parent"]
             }

      for %{"name" => name, "inputSchema" => %{"properties" => properties}} <- TicketLedger.tool_specs() do
        assert properties |> Map.keys() |> Enum.sort() == Enum.sort(TicketLedger.tool_arguments()[name])
      end
    end

    test "are listed for implementation, review and QA sessions" do
      for scope <- [nil, :read_only, :qa] do
        names = Enum.map(DynamicTool.tool_specs(scope), & &1["name"])
        assert "ticket_events" in names
        assert "ticket_record" in names
      end
    end
  end
end
