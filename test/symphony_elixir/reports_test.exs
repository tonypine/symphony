defmodule SymphonyElixir.ReportsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Report
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Config.Schema.Reports.Triggers
  alias SymphonyElixir.{Questions, Reports, Situation, TicketEvents}
  alias SymphonyElixir.Reports.{Anthropic, Material, Period}

  @repo "fixture"
  @period %{from: ~U[2026-11-09 08:00:00Z], to: ~U[2026-11-09 12:00:00Z]}

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "two", issue_identifier: "FIX-2", title: "Sign-in page", phase: "QA"})
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "three", issue_identifier: "FIX-3", phase: "Rework"})
    :ok
  end

  defp at(hour), do: DateTime.new!(~D[2026-11-09], Time.new!(hour, 0, 0))

  # The fixture period: two tickets' notable events between 08:00 and 12:00, one event that is not
  # notable inside it and one notable event after it.
  defp fixture_period! do
    {:ok, _quiet} = TicketEvents.record(@repo, "two", "run.started", %{run_id: "run-1", run_kind: "implementation"}, at: at(8))
    {:ok, entered} = TicketEvents.record(@repo, "two", "phase.entered", %{to: "QA", from: "Code Review"}, at: at(9))
    {:ok, approved} = TicketEvents.record(@repo, "two", "verdict.recorded", %{kind: "code_review", outcome: "approve"}, at: at(10), run_id: "run-2")
    {:ok, moved} = TicketEvents.record(@repo, "three", "ticket.moved", %{from: "QA", to: "Rework"}, at: at(11), actor: {:person, "Director"})
    {:ok, _later} = TicketEvents.record(@repo, "three", "phase.entered", %{to: "Rework"}, at: at(13))
    %{entered: entered.id, approved: approved.id, moved: moved.id}
  end

  defp material! do
    {:ok, material} = Reports.material(@period, live: Situation.live_facts(%{}))
    material
  end

  defp state(material, extra \\ %{}), do: Map.merge(%{run_id: "report-1", model: "claude-haiku-5-5", material: material, question_id: nil, published: nil}, extra)

  defp sentence(text, events), do: %{"text" => text, "events" => events}

  # A model that answers each turn with the next of `turns`, a function of the request.
  defp scripted(turns) do
    {:ok, script} = Agent.start_link(fn -> turns end)

    fn request, _opts ->
      send(self(), {:request, request})

      script |> Agent.get_and_update(&next_turn/1) |> answer_turn(request)
    end
  end

  defp next_turn([turn | rest]), do: {turn, rest}

  defp answer_turn({:error, reason}, _request), do: {:error, reason}
  defp answer_turn(turn, request), do: {:ok, turn.(request)}

  defp tool_use(id, name, input), do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  defp decision_input do
    %{
      "title" => "Let a person look at the sign-in page before QA",
      "why" => "Code Review approved the sign-in page this morning. QA has not started on it.",
      "if_unanswered" => "The sign-in page waits in QA as it does now.",
      "decision" => %{
        "question" => "Should the sign-in page wait for your own look before QA?",
        "recommendation_reason" => "QA covers the same steps today.",
        "options" => [
          %{"label" => "Let QA go on", "effect" => "QA walks the page as planned.", "recommended" => true},
          %{"label" => "Wait for my look", "effect" => "The page waits until you look at it."}
        ]
      }
    }
  end

  describe "a period" do
    test "reads the times a person types, on this host's clock" do
      now = ~U[2026-11-12 09:30:00Z]
      opts = [now: now, utc_offset: -3 * 3_600]

      assert Period.parse("now", opts) == {:ok, now}
      assert Period.parse(" Yesterday 18:00 ", opts) == {:ok, ~U[2026-11-11 21:00:00Z]}
      assert Period.parse("today 09:15", opts) == {:ok, ~U[2026-11-12 12:15:00Z]}
      assert Period.parse("06:00", opts) == {:ok, ~U[2026-11-12 09:00:00Z]}
      assert Period.parse("today", opts) == {:ok, ~U[2026-11-12 03:00:00Z]}
      assert Period.parse("yesterday", opts) == {:ok, ~U[2026-11-11 03:00:00Z]}
      assert Period.parse("2 hours ago", opts) == {:ok, ~U[2026-11-12 07:30:00Z]}
      assert Period.parse("1 day ago", opts) == {:ok, ~U[2026-11-11 09:30:00Z]}
      assert Period.parse("2026-11-11T18:00:00Z", opts) == {:ok, ~U[2026-11-11 18:00:00Z]}
      assert Period.parse("2026-11-11T18:00:00+01:00", opts) == {:ok, ~U[2026-11-11 17:00:00Z]}

      for text <- ["later", "yesterday 25:00", "today 9", "tomorrow 10:00", "3 weeks ago"] do
        assert Period.parse(text, opts) == :error, text
      end

      assert {:ok, %DateTime{}} = Period.parse("today 00:00")
    end

    test "starts before it ends, and says what is wrong in plain words" do
      opts = [now: ~U[2026-11-12 09:30:00Z], utc_offset: 0]

      assert Period.new("yesterday 18:00", "now", opts) == {:ok, %{from: ~U[2026-11-11 18:00:00Z], to: ~U[2026-11-12 09:30:00Z]}}
      assert Period.new(@period.from, @period.to) == {:ok, @period}
      assert Period.new("now", "yesterday", opts) == {:error, "The start of the period must come before its end."}
      assert {:error, "--from \"soon\" is not a time" <> _rest} = Period.new("soon", "now", opts)
      assert {:error, "--to \"never\" is not a time" <> _rest} = Period.new("now", "never", opts)
      assert Period.new(nil, "now", opts) == {:error, "--from is required."}
    end
  end

  describe "the material" do
    test "is the period's notable events, oldest first, and where each ticket they concern stands" do
      ids = fixture_period!()
      {:ok, _question} = Questions.ask(:symphony, question_request(), at: ~U[2026-11-09 11:30:00Z])

      material = material!()

      assert Material.event_ids(material) |> Enum.take(3) == [ids.entered, ids.approved, ids.moved]
      assert [_entered, _approved, _moved, %{ticket: nil, type: "question.asked"}] = material.events
      assert [%{identifier: "FIX-2", title: "Sign-in page", phase: "QA"}, %{identifier: "FIX-3", title: nil}] = material.tickets
      assert Material.ticket_identifiers(material) == ["FIX-2", "FIX-3"]
      assert Material.tickets_of(material, [ids.moved, ids.approved, "evt-unknown"]) == ["FIX-2", "FIX-3"]

      prompt = Material.prompt(material)
      assert prompt =~ "Period: 2026-11-09T08:00:00Z to 2026-11-09T12:00:00Z"
      assert prompt =~ "- [#{ids.moved}] 2026-11-09T11:00:00Z FIX-3 (untitled), by person Director:"
      assert prompt =~ "- [#{ids.approved}] 2026-11-09T10:00:00Z FIX-2 (Sign-in page), by run:"
      assert prompt =~ "Symphony, by"
      assert prompt =~ "- FIX-2 (Sign-in page), in QA: "
      refute prompt =~ "run-1"
    end

    test "of a period with no notable event leaves nothing to cite" do
      fixture_period!()
      assert Reports.material(%{from: ~U[2026-11-10 00:00:00Z], to: ~U[2026-11-10 12:00:00Z]}) == {:error, :no_events}
      assert Material.prompt(%{period: @period, events: [], tickets: []}) =~ "- none"
      assert {:ok, %{events: [], tickets: []}} = Material.read(%{from: ~U[2026-11-10 00:00:00Z], to: ~U[2026-11-10 12:00:00Z]})
      assert Reports.start(%{from: ~U[2026-11-10 00:00:00Z], to: ~U[2026-11-10 12:00:00Z]}) == {:error, :no_events}
    end
  end

  # A question asked on Symphony itself, as the decision path takes it.
  defp question_request do
    %{
      title: "Turn the night shift on",
      why: "The factory idled all night.",
      if_unanswered: "The factory keeps idling at night.",
      question: "Should the factory work at night?",
      recommendation_reason: "The queue is long.",
      options: [%{label: "Work at night", effect: "Runs start at night.", recommended: true}, %{label: "Stay idle", effect: "Nothing changes."}]
    }
  end

  defp publish_at!(run_id, at, event_id) do
    payload = %{
      run_id: run_id,
      model: "claude-haiku-5-5",
      period: %{from: "2026-11-09T08:00:00Z", to: "2026-11-09T12:00:00Z"},
      tickets: ["FIX-3"],
      events: [event_id],
      sentences: ["You sent FIX-3 back."],
      text: "You sent FIX-3 back.",
      citations: [%{sentence: 0, events: [event_id]}]
    }

    {:ok, event} = TicketEvents.build(nil, "reports", "report.published", payload, run_id: run_id, at: at)
    {:ok, _stored} = RunStore.append_report_event(event)
  end

  describe "symphony_publish_report" do
    setup do
      %{ids: fixture_period!(), material: material!()}
    end

    test "refuses a sentence that cites no event, naming it, and publishes nothing", %{ids: ids, material: material} do
      input = %{"sentences" => [sentence("FIX-2 passed Code Review.", [ids.approved]), sentence("Things went well overall.", [])]}

      assert {:error, message, %{published: nil}} = Report.execute("symphony_publish_report", input, state(material))
      assert message == ~s[Sentence 2 ("Things went well overall.") cites no event: every sentence must cite the events of the period it rests on, or go.]
      assert {:ok, []} = Reports.list()
    end

    test "refuses what it cannot take as a cited report, with the reason", %{ids: ids, material: material} do
      for {input, message} <- [
            {%{}, "The report needs at least one sentence."},
            {%{"sentences" => []}, "The report needs at least one sentence."},
            {%{"sentences" => [sentence("  ", [ids.moved])]}, "Each sentence needs a non-blank text and a list of event ids."},
            {%{"sentences" => [%{"text" => "FIX-3 went back.", "events" => "all"}]}, "Each sentence needs a non-blank text and a list of event ids."},
            {%{"sentences" => ["FIX-3 went back."]}, "Each sentence needs a non-blank text and a list of event ids."},
            {%{"sentences" => [sentence("FIX-3 went back.", ["evt-elsewhere"])]}, "Sentence 1 cites evt-elsewhere, which is no event of the period."},
            {%{"sentences" => [sentence("FIX-3 went back. FIX-2 moved on.", [ids.moved])]},
             ~s[Sentence 1 ("FIX-3 went back. FIX-2 moved on.") holds more than one sentence: give each its own entry, with its own events.]},
            {%{"sentences" => [sentence(String.duplicate("a", 20_001), [ids.moved])]}, "The report was not published: The report is longer than 20000 characters: say it in fewer words."}
          ] do
        assert {:error, ^message, _state} = Report.execute("symphony_publish_report", input, state(material)), inspect(input)
      end

      assert {:error, "The report was not published: " <> reason, _state} =
               Report.execute("symphony_publish_report", %{"sentences" => [sentence("FIX-3 went back.", [ids.moved])]}, state(material, %{model: ""}))

      assert reason =~ "invalid_payload"
      assert {:error, "shell is not a tool of a report run: it has symphony_publish_report and request_decision only.", _state} = Report.execute("shell", %{}, state(material))
      assert Report.names() == Enum.map(Report.specs(), & &1["name"])
    end

    test "publishes one report on the reports ledger, never on a ticket's", %{ids: ids, material: material} do
      input = %{"sentences" => [sentence("FIX-2 passed Code Review and is in QA.", [ids.approved, ids.entered, ids.approved]), sentence("You sent FIX-3 back to Rework.", [ids.moved])]}

      assert {:ok, "Published the report " <> _id, %{published: event} = state} = Report.execute("symphony_publish_report", input, state(material))

      assert %{type: "report.published", repo_key: nil, issue_id: "reports", run_id: "report-1"} = event

      assert event.payload == %{
               run_id: "report-1",
               model: "claude-haiku-5-5",
               period: %{from: "2026-11-09T08:00:00Z", to: "2026-11-09T12:00:00Z"},
               tickets: ["FIX-2", "FIX-3"],
               events: [ids.approved, ids.entered, ids.moved],
               sentences: ["FIX-2 passed Code Review and is in QA.", "You sent FIX-3 back to Rework."],
               text: "FIX-2 passed Code Review and is in QA. You sent FIX-3 back to Rework.",
               citations: [%{sentence: 0, events: [ids.approved, ids.entered]}, %{sentence: 1, events: [ids.moved]}]
             }

      assert event.summary.title == "Report published"
      assert {:ok, [^event]} = Reports.list()
      assert Enum.all?(RunStore.list_ticket_events("two", []), &(&1.type != "report.published"))
      assert {:error, "The report is already published.", _state} = Report.execute("symphony_publish_report", input, state)
    end
  end

  describe "request_decision" do
    setup do
      %{ids: fixture_period!(), material: material!()}
    end

    test "asks the Director once through the one decision path, with the report as its context, and the report carries it", %{ids: ids, material: material} do
      assert {:ok, "Asked the Director: question " <> _rest, %{question_id: id} = asked} = Report.execute("request_decision", decision_input(), state(material))

      assert [question] = Questions.open(:symphony)
      assert question.id == id
      assert question.title == "Let a person look at the sign-in page before QA"
      assert question.asked_by == %{kind: :run, name: "Report run", run_id: "report-1"}
      assert question.step == "report:report-1"
      assert question.why =~ "It comes from the status report on 9 November 08:00 to 9 November 12:00 UTC."
      assert Enum.any?(Questions.open_on_subjects(), fn {subject, open} -> subject == :symphony and open.id == id end)

      assert {:error, "A report asks at most one question, and this one asked already.", _state} = Report.execute("request_decision", decision_input(), asked)

      assert {:ok, _text, %{published: report} = published} =
               Report.execute("symphony_publish_report", %{"sentences" => [sentence("FIX-2 passed Code Review.", [ids.approved])]}, asked)

      assert report.payload.question_id == id
      assert {:error, "Ask before you publish: the report carries the question it raised.", _state} = Report.execute("request_decision", decision_input(), published)
    end

    test "refuses a question the writing standard refuses, and asks nothing", %{material: material} do
      input = Map.put(decision_input(), "decision", %{"question" => "Which one?", "options" => [%{"label" => "Only", "effect" => "It."}]})

      assert {:error, "The question was not asked: `decision.options` must list 2 to 4 options" <> _rest, %{question_id: nil}} =
               Report.execute("request_decision", input, state(material))

      assert {:error, "The question was not asked: `decision.question` must ask" <> _rest, _state} =
               Report.execute("request_decision", Map.delete(decision_input(), "decision"), state(material))

      assert Questions.open(:symphony) == []
    end
  end

  describe "a report run" do
    setup do
      %{ids: fixture_period!(), material: material!()}
    end

    test "over the fixture period publishes a report whose citations resolve to the period's events, after a refusal", %{ids: ids, material: material} do
      turn =
        scripted([
          fn _request -> [%{"type" => "text", "text" => "Drafting."}, tool_use("t1", "symphony_publish_report", %{"sentences" => [sentence("All good.", [])]})] end,
          fn request ->
            [cited] = Regex.run(~r/\[(\w+)\] \S+ FIX-3/, request.messages |> hd() |> Map.fetch!("content"), capture: :all_but_first)
            [tool_use("t2", "symphony_publish_report", %{"sentences" => [sentence("You sent FIX-3 back to Rework.", [cited])]})]
          end
        ])

      assert {:ok, event} = Reports.run(material, run_id: "report-7", model: "claude-haiku-5-5", turn: turn)

      assert_received {:request, %{model: "claude-haiku-5-5", tools: tools, messages: [%{"role" => "user"}], system: system}}
      assert Enum.map(tools, & &1["name"]) == ["symphony_publish_report", "request_decision"]
      assert system =~ "Every sentence rests on events of the period."

      assert_received {:request, %{messages: [_prompt, %{"role" => "assistant"}, %{"role" => "user", "content" => [refusal]}]}}
      assert %{"type" => "tool_result", "tool_use_id" => "t1", "is_error" => true, "content" => "Sentence 1 (\"All good.\") cites no event" <> _} = refusal

      period_ids = MapSet.new(Material.event_ids(material))
      assert [%{sentence: 0, events: [cited]}] = event.payload.citations
      assert cited == ids.moved and MapSet.member?(period_ids, cited)
      assert event.payload.tickets == ["FIX-3"]
      assert {:ok, [^event]} = Reports.list()
    end

    test "publishes nothing when the model calls no tool, fails, or never gets a report taken", %{material: material} do
      opts = [run_id: "report-8", model: "claude-haiku-5-5"]

      assert {:error, :no_tool_call} = Reports.run(material, [turn: scripted([fn _request -> [%{"type" => "text", "text" => "Hi."}] end])] ++ opts)
      assert {:error, :overloaded} = Reports.run(material, [turn: scripted([{:error, :overloaded}])] ++ opts)

      refusing = fn _request -> [tool_use("t", "symphony_publish_report", %{"sentences" => []})] end
      assert {:error, :not_published} = Reports.run(material, [turn: scripted(List.duplicate(refusing, 6))] ++ opts)
      assert {:ok, []} = Reports.list()
    end
  end

  describe "start/2" do
    test "starts a run in the background with the configured model, and refuses a period with nothing to cite" do
      ids = fixture_period!()
      parent = self()
      turn = fn _request, _opts -> {:ok, [tool_use("t", "symphony_publish_report", %{"sentences" => [sentence("You sent FIX-3 back.", [ids.moved])]})]} end
      start_task = fn fun -> send(parent, {:run, fun}) end

      assert {:ok, %{run_id: "report-" <> _ulid = run_id, model: "claude-haiku-5-5", from: from, to: to, events: 3}} =
               Reports.start(@period, turn: turn, start_task: start_task, live: Situation.live_facts(%{}))

      assert {from, to} == {@period.from, @period.to}
      assert_received {:run, run}
      assert {:ok, %{run_id: ^run_id}} = run.()

      assert Reports.start(%{from: ~U[2026-11-01 00:00:00Z], to: ~U[2026-11-02 00:00:00Z]}, start_task: start_task) == {:error, :no_events}
      refute_received {:run, _run}
    end
  end

  describe "list/1" do
    test "reads the published reports newest first, bounded by since and until" do
      ids = fixture_period!()
      publish_at!("report-a", at(12), ids.moved)
      publish_at!("report-b", at(14), ids.moved)
      # A second write of one run's report is the report the ledger holds.
      assert {:ok, %{at: kept}} = publish_at!("report-a", at(15), ids.moved)
      assert kept == at(12)

      assert {:ok, [%{payload: %{run_id: "report-b"}}, %{payload: %{run_id: "report-a"}}] = reports} = Reports.list()
      assert {:ok, [%{payload: %{run_id: "report-b"}}]} = Reports.list(since: at(13))
      assert {:ok, [%{payload: %{run_id: "report-a"}}]} = Reports.list(until: at(13))

      json = reports |> hd() |> Reports.json()
      assert %{run_id: "report-b", model: "claude-haiku-5-5", tickets: ["FIX-3"], question_id: nil, text: "You sent FIX-3 back."} = json
      assert json.at == "2026-11-09T14:00:00Z"
    end
  end

  describe "the reports.model setting" do
    @base %{
      "issues" => %{"provider" => "memory"},
      "repositories" => [%{"key" => "web"}],
      "agent" => %{"runtime" => "codex", "command" => "codex app-server"}
    }

    test "is the cheapest capable model when missing, and the model symphony.yml names otherwise" do
      assert Config.report_model() == "claude-haiku-5-5"
      assert {:ok, %{reports: %{model: "claude-haiku-5-5"}}} = SystemSchema.parse(@base)

      path = Workflow.symphony_file_path()
      original = File.read!(path)
      File.write!(path, original <> "reports:\n  model: claude-sonnet-5-5\n")
      Cache.clear()
      assert Config.report_model() == "claude-sonnet-5-5"

      # A symphony.yml Symphony can't load leaves the default.
      File.write!(path, original <> "reports: 7\n")
      Cache.clear()
      assert Config.report_model() == "claude-haiku-5-5"
    end

    test "refuses a blank model and an unknown key, and is a setting the macOS app must edit" do
      assert {:error, {:invalid_symphony_config, "reports.model must name a model"}} = SystemSchema.parse(Map.put(@base, "reports", %{"model" => " "}))
      assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `reports.weekly`"}} = SystemSchema.parse(Map.put(@base, "reports", %{"weekly" => true}))
      assert {:error, {:invalid_symphony_config, "`reports` must be an object"}} = SystemSchema.parse(Map.put(@base, "reports", 7))
      assert "reports.model" in SystemSchema.operator_key_paths()
    end
  end

  describe "the reports.cadence and reports.triggers settings" do
    test "default to every six hours, with a ticket shipped and the factory paused by a rule on" do
      assert {:ok, %{reports: %{cadence: "six_hours", triggers: triggers}}} = SystemSchema.parse(@base)

      assert Map.take(triggers, Triggers.names()) == %{
               ticket_shipped: true,
               epic_closed: false,
               ci_fix_loop: false,
               self_heal_filed: false,
               release_installed: false,
               paused_by_rule: true
             }

      assert Schema.Reports.cadences() == ~w(none hourly six_hours daily)
      assert %Schema.Reports{cadence: "six_hours"} = Config.report_settings()

      path = Workflow.symphony_file_path()
      original = File.read!(path)
      File.write!(path, original <> "reports:\n  cadence: hourly\n  triggers:\n    epic_closed: true\n")
      Cache.clear()
      assert %{cadence: "hourly", triggers: %{epic_closed: true, ticket_shipped: true}} = Config.report_settings()

      File.write!(path, original <> "reports: 7\n")
      Cache.clear()
      assert Config.report_settings() == %Schema.Reports{}
    end

    test "take a null triggers section as the defaults, and refuse an unknown cadence or trigger" do
      assert {:ok, %{reports: %{triggers: %{ticket_shipped: true}}}} = SystemSchema.parse(Map.put(@base, "reports", %{"triggers" => nil}))

      assert {:error, {:invalid_symphony_config, "reports.cadence must be one of none, hourly, six_hours, daily"}} =
               SystemSchema.parse(Map.put(@base, "reports", %{"cadence" => "weekly"}))

      assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `reports.triggers.weekly`"}} =
               SystemSchema.parse(Map.put(@base, "reports", %{"triggers" => %{"weekly" => true}}))

      assert {:error, {:invalid_symphony_config, "`reports.triggers` must be an object"}} = SystemSchema.parse(Map.put(@base, "reports", %{"triggers" => 1}))
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(Map.put(@base, "reports", %{"triggers" => %{"epic_closed" => "maybe"}}))
      assert message =~ "reports.triggers.epic_closed"

      for key <- ~w(cadence triggers.ticket_shipped triggers.epic_closed triggers.ci_fix_loop triggers.self_heal_filed triggers.release_installed triggers.paused_by_rule) do
        assert "reports.#{key}" in SystemSchema.operator_key_paths()
      end
    end
  end

  describe "latest/0, launch/2 and cited_tickets/1" do
    test "the newest report, the run's task, and each cited event's ticket with its Linear URL" do
      assert Reports.latest() == nil
      ids = fixture_period!()
      :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "three", issue_identifier: "FIX-3", phase: "Rework", url: "https://linear.app/acme/issue/FIX-3"})
      {:ok, _older} = publish_at!("report-a", at(12), ids.moved)
      {:ok, newest} = publish_at!("report-b", at(14), ids.moved)
      assert Reports.latest().id == newest.id

      {:ok, _pause} = SymphonyElixir.Pauses.set(:symphony, SymphonyElixir.Pauses.dispatch_reason("deploy window"), at: at(10))
      [symphony | _rest] = RunStore.list_subject_events(:symphony, [])
      report = %{newest | payload: %{newest.payload | events: [ids.moved, ids.approved, symphony.id]}}

      assert Reports.cited_tickets(report) == %{
               ids.moved => %{identifier: "FIX-3", url: "https://linear.app/acme/issue/FIX-3"},
               ids.approved => %{identifier: "FIX-2", url: nil}
             }

      assert {:ok, %{events: 4}, :the_task} = Reports.launch(@period, start_task: fn _fun -> :the_task end, live: Situation.live_facts(%{}))
    end
  end

  describe "the model's turn" do
    test "sends the conversation and the tools, made to call one, and reads the content blocks" do
      request = %{system: "s", messages: [%{"role" => "user", "content" => "p"}], tools: Report.specs(), model: "claude-haiku-5-5"}
      parent = self()

      request_fun = fn payload, headers, _timeout ->
        send(parent, {:post, payload, headers})
        {:ok, %{status: 200, body: %{"content" => [%{"type" => "text", "text" => "ok"}]}}}
      end

      assert Anthropic.turn(request, api_key: "key", request_fun: request_fun) == {:ok, [%{"type" => "text", "text" => "ok"}]}
      assert_received {:post, %{"model" => "claude-haiku-5-5", "tool_choice" => %{"type" => "any"}, "tools" => [_publish, _decision]}, headers}
      assert {"x-api-key", "key"} in headers

      assert Anthropic.turn(request, api_key: "key", request_fun: fn _p, _h, _t -> {:ok, %{status: 529, body: %{}}} end) == {:error, {:provider_http_status, 529, %{}}}
      assert Anthropic.turn(request, api_key: "key", request_fun: fn _p, _h, _t -> {:error, :timeout} end) == {:error, {:provider_request_failed, :timeout}}
      assert Anthropic.turn(request, api_key: "", request_fun: request_fun) == {:error, :missing_anthropic_api_key}
    end
  end
end
