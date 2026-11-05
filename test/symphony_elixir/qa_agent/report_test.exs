defmodule SymphonyElixir.QaAgent.ReportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Artifacts, Paths, TicketEvents}
  alias SymphonyElixir.QaAgent.Report
  alias SymphonyElixir.TicketEvents.Event

  @sha "0123456789abcdef0123456789abcdef01234567"
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>

  # One real pass as events, in the shape of TP-1354's second pass (Director: add or remove a
  # ticket's blocker from its ticket page): the first pass failed step 2 on the live server with a
  # screenshot, a rework resolved the finding, and the second pass walked step 1 and step 3 on the
  # committed fixtures and step 2 on the live server again, reopening the finding with two
  # screenshots.
  @first "qa-TP-1354-first"
  @second "qa-TP-1354-second"

  @list_shot String.duplicate("1", 64)
  @first_shot String.duplicate("2", 64)
  @added_shot String.duplicate("3", 64)
  @reopened_shot String.duplicate("4", 64)
  @transcript String.duplicate("5", 64)

  @description "Step 2 at 1440×900 pt: The added blocker does not show until the ticket page is opened again. " <>
                 "Expected: the blocker appears in the Blocked by list at once. Actual: the list still shows no blockers."

  defp fixture do
    [
      evidence("e1", @first, %{step: "Step 1 Open TP-1354's page and read its blockers", status: "pass", environment: "fixture"}),
      evidence("e2", @first, %{step: "Step 2 Add TP-1352 as a blocker", status: "fail", environment: "live", details: "the list stayed empty"}, [@first_shot]),
      finding("f1", @first, @description, [@first_shot]),
      event("r1", "finding.resolved", "rework-TP-1354", %{finding_id: "f1", how: "Refresh the blockers after the move", head: "abc"}),
      evidence("e3", @second, %{step: "Step 1 Open TP-1354's page and read its blockers", status: "pass", environment: "fixture"}, [@list_shot]),
      evidence("e4", @second, %{step: "Step 2 Add TP-1352 as a blocker", status: "fail", environment: "live", details: "$ qa_screenshot\nno blocker row"}, [@added_shot, @reopened_shot]),
      evidence("e5", @second, %{step: "Step 3 Remove the blocker", status: "pass", environment: "fixture", links: ["https://ci.test/run/9"]}),
      # The QA agent's own evidence and the transcript name no step: they are not report steps.
      evidence("e6", @second, %{caption: "Step 2 on the live server, dark"}, [@added_shot]),
      evidence("e7", @second, %{caption: "QA session transcript"}, [@transcript]),
      %{finding("f2", @second, @description <> " Still.", [@added_shot, @reopened_shot]) | supersedes: "r1"},
      event("v2", "verdict.recorded", nil, %{kind: "qa", outcome: "fail"})
    ]
  end

  defp event(id, type, run_id, payload, artifacts \\ []) do
    %Event{id: id, type: type, run_id: run_id, payload: payload, artifacts: artifacts, issue_id: "issue-1354", repo_key: "default"}
  end

  defp evidence(id, run_id, fields, artifacts \\ []) do
    event(id, "evidence", run_id, Map.merge(%{caption: "#{fields[:step]}: #{fields[:status]}"}, fields), artifacts)
  end

  defp finding(id, run_id, description, artifacts) do
    event(id, "finding.recorded", run_id, %{class: "unclassified", severity: "unrated", description: description, step: "Step 2"}, artifacts)
  end

  defp url(id), do: "https://uploads.linear.app/qa/#{String.slice(id, 0, 4)}.png"

  defp links(ids), do: Map.new(ids, &{&1, %{label: "qa-evidence/#{String.slice(&1, 0, 4)}.png", url: url(&1)}})

  defp outcome(extra \\ %{}), do: Map.merge(%{verdict: :fail, sha: @sha, target_state: "Rework", summary: "Step 2 still fails."}, extra)

  defp headings(body), do: body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "#"))

  defp issue, do: %Issue{id: "issue-1354", identifier: "TP-1354", title: "Director: add or remove a ticket's blocker", state: "QA"}

  describe "render/1 from the pass's events" do
    test "renders the second pass's steps with their environment and its finding with its state and screenshots" do
      ledger = %{events: fixture(), run_id: @second, links: links([@list_shot, @added_shot, @reopened_shot])}
      body = Report.render(Map.merge(outcome(), ledger))

      assert body =~ "**Verdict:** fail → Rework"

      assert body =~
               "### Steps\n\n- **pass** Step 1 Open TP-1354's page and read its blockers (proved on the fixtures; evidence: [1111.png](#{url(@list_shot)}))\n"

      assert body =~
               "- **fail** Step 2 Add TP-1352 as a blocker (proved on the live server; evidence: [3333.png](#{url(@added_shot)}), [4444.png](#{url(@reopened_shot)}))\n\n" <>
                 "  ```text\n  $ qa_screenshot\n  no blocker row\n  ```\n"

      assert body =~ "- **pass** Step 3 Remove the blocker (proved on the fixtures; evidence: https://ci.test/run/9)\n"

      assert body =~
               "### Findings\n\n- #{@description} Still. · **reopened** · evidence: [3333.png](#{url(@added_shot)}), [4444.png](#{url(@reopened_shot)})\n"

      # Only the second pass: the first pass's steps and screenshot, the agent's own evidence and the
      # transcript are not report rows.
      refute body =~ "the list stayed empty"
      refute body =~ @first_shot
      refute body =~ "on the live server, dark"
      refute body =~ @transcript
      assert length(Regex.scan(~r/^- \*\*/m, body)) == 3
      assert length(Regex.scan(~r/· \*\*reopened\*\*/, body)) == 1
    end

    test "keeps the same sections as the report rendered from the outcome" do
      given =
        outcome(%{
          steps: [%{name: "Step 2 Add TP-1352 as a blocker", status: "fail", details: "no row", evidence: ["qa-evidence/3333.png"]}],
          findings: [@description]
        })

      ledger = %{events: fixture(), run_id: @second, links: links([@list_shot, @added_shot, @reopened_shot])}

      assert headings(Report.render(Map.merge(given, ledger))) == headings(Report.render(given))
      assert headings(Report.render(given)) == ["## Symphony QA Report", "### Steps", "### Findings"]
    end

    test "the report's findings and screenshots are the pass's finding events, as the Director's timeline reads them" do
      events = fixture()
      body = Report.render(Map.merge(outcome(), %{events: events, run_id: @second, links: links([@list_shot, @added_shot, @reopened_shot])}))
      [findings] = Regex.run(~r/### Findings\n\n(.*?)\n\n/s, body, capture: :all_but_first)

      timeline = for %Event{type: "finding.recorded", run_id: @second} = finding <- events, do: finding

      assert length(String.split(findings, "\n")) == length(timeline)

      for finding <- timeline do
        assert findings =~ finding.payload.description
        for id <- finding.artifacts, do: assert(findings =~ url(id))
      end
    end

    test "a pass that confirms the resolved finding shows it confirmed; another run's open finding is not its row" do
      confirmed =
        Enum.take(fixture(), 4) ++
          [
            evidence("e8", "qa-pass", %{step: "Step 2 Add TP-1352 as a blocker", status: "pass"}),
            event("c1", "finding.confirmed", "qa-pass", %{finding_id: "f1", resolution: "r1", head: "abc"}),
            finding("f3", "qa-other", "An open finding of another pass.", [])
          ]

      body = Report.render(Map.merge(outcome(%{verdict: :pass, target_state: "Merging"}), %{events: confirmed, run_id: "qa-pass", links: %{}}))

      assert body =~ "- **pass** Step 2 Add TP-1352 as a blocker\n"
      assert body =~ "### Findings\n\n- #{@description} · **confirmed fixed** · evidence: artifact `#{@first_shot}`\n"
      refute body =~ "another pass"
    end

    test "a finding still open, or resolved and awaiting QA, says so" do
      events = Enum.take(fixture(), 3) ++ [finding("f5", @first, "The badge is gone.", [])]
      open = Report.render(Map.merge(outcome(), %{events: events, run_id: @first, links: %{}}))
      assert open =~ "- #{@description} · **open** · evidence: artifact `#{@first_shot}`\n- The badge is gone. · **open**\n"

      resolved = Report.render(Map.merge(outcome(), %{events: Enum.take(fixture(), 4), run_id: @first, links: %{}}))
      assert resolved =~ "- #{@description} · **resolved, awaiting QA**"
    end

    test "a file with no upload names its file and artifact id; a step with no environment or status says neither" do
      events = [evidence("e1", "qa-1", %{caption: "c", step: "Step 1"}, [@list_shot, @added_shot])]

      links = %{
        @list_shot => %{label: "qa-evidence/list.png", url: nil},
        @added_shot => %{label: nil, url: "https://uploads.linear.app/qa/x.png"}
      }

      body = Report.render(Map.merge(outcome(), %{events: events, run_id: "qa-1", links: links}))
      assert body =~ "- **noted** Step 1 (evidence: qa-evidence/list.png (artifact `#{@list_shot}`), [333333333333](https://uploads.linear.app/qa/x.png))\n"
    end

    test "a pass that recorded no step or finding renders its steps and findings as given" do
      given =
        outcome(%{
          verdict: :blocked,
          reason: "the QA host failed",
          steps: [%{name: "Open the app", status: "blocked", details: "", evidence: []}],
          findings: ["no host"]
        })

      body = Report.render(Map.merge(given, %{events: [evidence("e1", "qa-1", %{caption: "QA session transcript"}, [@transcript])], run_id: "qa-1", links: %{}}))

      assert body =~ "### Steps\n\n- **blocked** Open the app\n"
      assert body =~ "### Findings\n\n- no host\n"
    end

    test "a step given with its environment names it too" do
      body = Report.render(outcome(%{steps: [%{name: "Step 1", status: "pass", details: "", environment: "live", evidence: []}]}))
      assert body =~ "- **pass** Step 1 (proved on the live server)\n"
    end
  end

  describe "ledger/4" do
    setup do
      :ok = RunStore.clear()
      File.rm_rf!(Paths.artifacts_dir())
      dir = Path.join(System.tmp_dir!(), "symphony-report-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        File.rm_rf(dir)
        File.rm_rf(Paths.artifacts_dir())
      end)

      %{dir: dir}
    end

    defp ingest!(dir, name, bytes, label) do
      path = Path.join(dir, name)
      File.write!(path, bytes)
      meta = %{repo_key: "default", issue_id: "issue-1354", run_id: @second, kind: "screenshot", label: label}
      {:ok, artifact} = Artifacts.ingest(path, meta, roots: [dir])
      artifact
    end

    defp linear_client(recipient, fail_upload? \\ false) do
      {:ok, comments} = Agent.start_link(fn -> [] end)

      fn query, variables, _opts ->
        send(recipient, {:linear, query, variables})

        cond do
          query =~ "SymphonyAgentFileUpload" and fail_upload? ->
            {:ok, %{"data" => %{"fileUpload" => %{"success" => false, "uploadFile" => %{}}}}}

          query =~ "SymphonyAgentFileUpload" ->
            send(recipient, {:file_upload, variables.filename})

            {:ok,
             %{
               "data" => %{
                 "fileUpload" => %{
                   "success" => true,
                   "uploadFile" => %{"uploadUrl" => "https://uploads.example.test/put", "assetUrl" => "https://uploads.linear.app/qa/#{variables.filename}", "headers" => []}
                 }
               }
             }}

          query =~ "SymphonyAgentAttachFile" ->
            {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true, "attachment" => %{"id" => "a-1", "url" => variables.url}}}}}

          query =~ "comments(" ->
            {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => Agent.get(comments, & &1)}}}}}

          query =~ "commentCreate" ->
            Agent.update(comments, fn _comments -> [%{"id" => "c-qa", "body" => variables.body}] end)
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-qa"}}}}}

          query =~ "commentUpdate" ->
            {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
        end
      end
    end

    defp upload_client, do: fn _url, _opts -> {:ok, %{status: 200}} end

    test "a second pass rewrites the comment and links the screenshot without uploading it twice", %{dir: dir} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      uploaded = ingest!(dir, "a.png", @png <> "a", "qa-evidence/step 2 added.png")
      agents = ingest!(dir, "b.png", @png <> "b", "qa-evidence/reopened.png")
      {:ok, _artifact} = Artifacts.put_projection(agents.id, :linear_url, "https://uploads.linear.app/qa/agent-reopened.png")

      events = [
        evidence("e4", @second, %{step: "Step 2 Add TP-1352 as a blocker", status: "fail", environment: "live"}, [uploaded.id, agents.id]),
        %{finding("f2", @second, @description, [uploaded.id, agents.id]) | supersedes: nil}
      ]

      opts = [linear_client: linear_client(self()), upload_client: upload_client()]

      ledger = Report.ledger(issue(), events, @second, opts)
      assert_received {:file_upload, "step-2-added.png"}
      refute_received {:file_upload, _other}

      link = "https://uploads.linear.app/qa/step-2-added.png"

      assert ledger.links == %{
               uploaded.id => %{label: "qa-evidence/step 2 added.png", url: link},
               agents.id => %{label: "qa-evidence/reopened.png", url: "https://uploads.linear.app/qa/agent-reopened.png"}
             }

      assert {:ok, %{projections: %{linear_url: ^link}}} = Artifacts.get(uploaded.id)

      first = Report.render(Map.merge(outcome(), ledger))
      assert first =~ "· **open** · evidence: [step 2 added.png](#{link}), [reopened.png](https://uploads.linear.app/qa/agent-reopened.png)"
      assert :ok = Report.publish(issue(), first, opts)
      assert_received {:linear, create, %{body: ^first}}
      assert create =~ "commentCreate"

      # The next pass on the same files links them again without uploading either.
      again = Report.ledger(issue(), events, @second, opts)
      refute_received {:file_upload, _name}
      assert again.links == ledger.links

      second = Report.render(Map.merge(outcome(%{summary: "Second pass."}), again))
      assert :ok = Report.publish(issue(), second, opts)
      assert_received {:linear, update, %{id: "c-qa", body: ^second}}
      assert update =~ "commentUpdate"

      # Rendering and publishing write no event.
      assert RunStore.list_ticket_events("issue-1354", []) == []
    end

    test "a file with no label is uploaded under its short id; a failed upload is logged and leaves the file unlinked", %{dir: dir} do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      unlabelled = ingest!(dir, "c.png", @png <> "c", nil)
      events = [evidence("e1", @second, %{step: "Step 1", status: "pass"}, [unlabelled.id])]

      assert %{links: %{} = links} = Report.ledger(issue(), events, @second, linear_client: linear_client(self()), upload_client: upload_client())
      name = String.slice(unlabelled.id, 0, 12) <> ".png"
      assert_received {:file_upload, ^name}
      assert links[unlabelled.id].url == "https://uploads.linear.app/qa/#{name}"

      failing = ingest!(dir, "d.png", @png <> "d", "qa-evidence/d.png")
      events = [evidence("e1", @second, %{step: "Step 1", status: "pass"}, [failing.id])]

      log =
        capture_log(fn ->
          assert %{links: links} = Report.ledger(issue(), events, @second, linear_client: linear_client(self(), true), upload_client: upload_client())
          assert links[failing.id] == %{label: "qa-evidence/d.png", url: nil}
        end)

      assert log =~ "Could not upload artifact #{failing.id} for the QA report of TP-1354"
      assert {:ok, %{projections: projections}} = Artifacts.get(failing.id)
      refute Map.has_key?(projections, :linear_url)
    end

    test "on another tracker nothing is uploaded, and a file the store does not hold is named by its id", %{dir: dir} do
      kept = ingest!(dir, "e.png", @png <> "e", "qa-evidence/e.png")
      events = [evidence("e1", @second, %{step: "Step 1", status: "pass"}, [kept.id, @transcript])]

      assert %{links: links, run_id: @second, events: ^events} = Report.ledger(issue(), events, @second, linear_client: linear_client(self()))
      refute_received {:linear, _query, _variables}
      assert links == %{kept.id => %{label: "qa-evidence/e.png", url: nil}, @transcript => %{label: nil, url: nil}}

      assert Report.render(Map.merge(outcome(), %{events: events, run_id: @second, links: links})) =~
               "(evidence: qa-evidence/e.png (artifact `#{kept.id}`), artifact `#{@transcript}`)"

      # The findings model reads the fixture's findings as the Director's timeline does.
      assert [%{state: :reopened}] = TicketEvents.findings(fixture())
    end
  end
end
