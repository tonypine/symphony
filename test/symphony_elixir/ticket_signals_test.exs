defmodule SymphonyElixir.TicketSignalsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Orchestrator, Questions, TicketEvents, TicketSignals, TicketState}

  @repo_key "repo-a"

  setup do
    :ok = RunStore.clear()
  end

  test "records a signal in the ticket's ledger" do
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{to: "Code Review"})

    assert %{signals: [%{name: "handoff", details: %{to: "Code Review"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "a pending projection is marked and cleared on a record only; a ticket with no record or no repo key, or a store failure, writes none" do
    repo_key = Config.repo_key!()
    :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "issue-projected"))

    assert :ok = TicketSignals.mark_projection(repo_key, "issue-projected", :phase, :boom)
    assert [%{type: :phase, error: ":boom"} = mark] = RunStore.get_ticket_state(repo_key, "issue-projected").pending_projection
    assert :ok = TicketSignals.clear_projection(repo_key, "issue-projected", mark)
    assert RunStore.get_ticket_state(repo_key, "issue-projected").pending_projection == []

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = TicketSignals.clear_projection("", "issue-projected", mark) end)
    assert log =~ "Failed to clear a pending projection on issue_id=issue-projected"

    assert :ok = TicketSignals.mark_projection(repo_key, "issue-unknown", :phase, :boom)
    assert RunStore.get_ticket_state(repo_key, "issue-unknown") == nil
    assert :ok = TicketSignals.mark_projection(nil, "issue-projected", :phase, :boom)

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = TicketSignals.mark_projection("", "issue-projected", :phase, :boom) end)
    assert log =~ "Failed to mark a pending projection on issue_id=issue-projected"
  end

  test "records a signal with no details" do
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "merge settled", %{})

    assert %{signals: [%{name: "merge settled", details: %{}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "records a verdict bound to the head it judged" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "pass")

    assert %{verdicts: [%{kind: "qa", head_sha: "abc123", outcome: "pass"}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "records the details a verdict carries" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "blocked", %{reason: "no emulator", model: "claude-opus"})

    assert %{verdicts: [%{outcome: "blocked", details: %{reason: "no emulator", model: "claude-opus"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "no-ops when the ticket carries no repo key" do
    assert :ok = TicketSignals.record(nil, "issue-1", "handoff", %{})
    assert :ok = TicketSignals.record(@repo_key, nil, "handoff", %{})
    assert :ok = TicketSignals.record_verdict(nil, "issue-1", "qa", nil, "pass")
    assert :ok = TicketSignals.record_verdict(@repo_key, nil, "qa", nil, "pass")

    assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil
  end

  test "a move asks the orchestrator for a cycle on the ticket's repo at once; a signal that moves nothing does not" do
    stand_in_for_orchestrator()

    assert :ok = TicketSignals.record(@repo_key, "issue-1", "merge settled", %{})
    assert_received {:"$gen_cast", {:request_refresh, @repo_key, :now}}

    assert :ok = TicketSignals.record(@repo_key, "issue-1", "review verdict", %{outcome: "pass", to: "QA"})
    assert_received {:"$gen_cast", {:request_refresh, @repo_key, :now}}

    assert :ok = TicketSignals.record(@repo_key, "issue-1", "ci_wait_started", %{})
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "unblocked", %{})
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{head: "abc123"})
    refute_received {:"$gen_cast", _request}
  end

  test "a merge Symphony settled polls the ticket's repo on the very next cycle, so the ticket it unblocked is a candidate at once" do
    stand_in_for_orchestrator()
    repos = [%{name: @repo_key, team: "ACME", labels: []}, %{name: "repo-b", team: "ACME", labels: []}]
    next = %Issue{id: "issue-b", identifier: "ACME-2", title: "Next in the chain", state: "Todo"}
    test_pid = self()

    fetcher = fn repo ->
      send(test_pid, {:polled, repo.name})
      {:ok, if(repo.name == @repo_key, do: [%{next | blocked_by: [%{id: "issue-1", identifier: "ACME-1", state: "Done"}]}], else: [])}
    end

    # Both repos polled once, back to back as at boot; the repo's next timed poll is far off.
    state = %Orchestrator.State{poll_interval_ms: 600_000}
    {:ok, _buckets, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)
    {:ok, _buckets, state} = Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 300_000)
    assert_received {:polled, @repo_key}
    assert_received {:polled, "repo-b"}

    assert :ok = TicketSignals.record(@repo_key, "issue-1", "merge settled", %{})
    assert_received {:"$gen_cast", request}
    assert {:noreply, state} = Orchestrator.handle_cast(request, state)
    assert_receive {:tick, _tick_token}

    assert {:ok, %{dispatchable: [%{identifier: "ACME-2", blocked_by: [%{state: "Done"}]}]}, _state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 300_010)

    assert_received {:polled, @repo_key}
    refute_received {:polled, "repo-b"}
  end

  describe "record_phase/3" do
    test "creates the record in the phase when the ticket has none" do
      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "In Progress")
      assert %{phase: "In Progress", updated_at: %DateTime{}} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "moves an existing record and leaves what a read of Linear wrote, so a later read still wins" do
      seen = ~U[2026-10-29 10:00:00Z]
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Todo", issue_identifier: "MT-1", title: "Add checkout", linear_updated_at: seen}))

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "In Progress")

      assert %{phase: "In Progress", issue_identifier: "MT-1", title: "Add checkout", linear_updated_at: ^seen, phase_at: %DateTime{} = phase_at} =
               RunStore.get_ticket_state(@repo_key, "issue-1")

      assert DateTime.compare(phase_at, seen) == :gt
    end

    test "a record already in the phase Symphony wrote is left as it was" do
      record = TicketState.new(@repo_key, "issue-1") |> TicketState.put_phase("QA", ~U[2026-10-29 10:00:00Z])
      :ok = RunStore.put_ticket_state(record)
      before = RunStore.get_ticket_state(@repo_key, "issue-1")

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "QA")
      assert RunStore.get_ticket_state(@repo_key, "issue-1") == before
    end

    test "a move writes the phase as Symphony's; one into the phase an observation wrote only takes it over, unannounced" do
      at = ~U[2026-10-29 10:00:00Z]
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Todo", phase_at: at, updated_at: at}))
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "Todo")
      assert %{phase: "Todo", phase_at: ^at, phase_owner: :symphony} = RunStore.get_ticket_state(@repo_key, "issue-1")
      refute_received {:ticket_record, @repo_key, "issue-1", :changed, _fields}

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-2", "In Progress")
      assert %{phase: "In Progress", phase_owner: :symphony} = RunStore.get_ticket_state(@repo_key, "issue-2")
    end

    test "a phase written is announced as a change of the record's phase; one already there is not" do
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "In Progress")
      assert_received {:ticket_record, @repo_key, "issue-1", :changed, [:phase]}

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "Code Review")
      assert_received {:ticket_record, @repo_key, "issue-1", :changed, [:phase]}

      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", "Code Review")
      refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}
    end

    test "a move into Plan Review, and a revision's move back into it, read the plan's brief onto the record; a move elsewhere reads nothing" do
      test_pid = self()
      {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})
      linear = fn _query, %{id: id}, _opts -> send(test_pid, {:plan_read, id}) && {:error, :offline} end
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      Application.put_env(:symphony_elixir, :plan_brief_opts, linear_client: linear, settings: settings)

      on_exit(fn ->
        Application.put_env(:symphony_elixir, :plan_brief_capture, false)
        Application.delete_env(:symphony_elixir, :plan_brief_opts)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = TicketSignals.record_phase(@repo_key, "plan-1", "In Progress")
        refute_received {:plan_read, _id}

        assert :ok = TicketSignals.record_phase(@repo_key, "plan-1", "Plan Review")
        assert_receive {:plan_read, "plan-1"}, 5_000

        assert :ok = TicketSignals.record_phase(@repo_key, "plan-1", "Rework")
        assert :ok = TicketSignals.record_phase(@repo_key, "plan-1", "Plan Review")
        assert_receive {:plan_read, "plan-1"}, 5_000

        eventually(fn -> match?(%{plan_brief: nil, plan_brief_error: ":offline"}, RunStore.get_ticket_state(@repo_key, "plan-1")) end)
      end)
    end

    test "no-ops without a repo key, an issue id or a phase" do
      assert :ok = TicketSignals.record_phase(nil, "issue-1", "QA")
      assert :ok = TicketSignals.record_phase(@repo_key, nil, "QA")
      assert :ok = TicketSignals.record_phase(@repo_key, "issue-1", nil)
      assert RunStore.get_ticket_state(@repo_key, "issue-1") == nil
    end

    test "logs and swallows a store failure" do
      log = capture_log(fn -> assert :ok = TicketSignals.record_phase("  ", "issue-1", "QA") end)
      assert log =~ "Failed to write the record's phase QA on issue_id=issue-1"
    end

    test "the phase read before a move is the one restore_phase/3 puts back" do
      assert TicketSignals.recorded_phase(@repo_key, "issue-1") == {:ok, nil}
      assert TicketSignals.recorded_phase(nil, "issue-1") == :unknown
      assert TicketSignals.recorded_phase("  ", "issue-1") == :unknown

      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "issue-1", %{phase: "Backlog", issue_identifier: "MT-1"}))
      before = TicketSignals.recorded_phase(@repo_key, "issue-1")
      assert before == {:ok, "Backlog"}

      :ok = TicketSignals.record_phase(@repo_key, "issue-1", "Canceled")
      assert :ok = TicketSignals.restore_phase(@repo_key, "issue-1", before)
      assert %{phase: "Backlog", issue_identifier: "MT-1"} = RunStore.get_ticket_state(@repo_key, "issue-1")

      # A phase nobody could read is left as the move wrote it; a record that had none goes back to none.
      :ok = TicketSignals.record_phase(@repo_key, "issue-1", "Canceled")
      assert :ok = TicketSignals.restore_phase(@repo_key, "issue-1", :unknown)
      assert %{phase: "Canceled"} = RunStore.get_ticket_state(@repo_key, "issue-1")
      assert :ok = TicketSignals.restore_phase(@repo_key, "issue-1", {:ok, nil})
      assert %{phase: nil} = RunStore.get_ticket_state(@repo_key, "issue-1")
    end

    test "a move's signal writes the phase it entered, with its phase.entered event" do
      assert :ok = TicketSignals.record(@repo_key, "issue-1", "claim", %{from: "Todo", to: "In Progress"})

      assert %{phase: "In Progress"} = RunStore.get_ticket_state(@repo_key, "issue-1")
      assert [%{type: "phase.entered", phase: "In Progress"}] = RunStore.list_ticket_events(@repo_key, "issue-1", types: ["phase.entered"])
    end
  end

  describe "the event each signal maps to" do
    # Every signal name in use, with the details its writers record, and the event it yields — or
    # `:mirrored` when the `Hold` or `Decisions` event for the same change records it.
    @signals [
      {"claim", %{from: "Todo", to: "In Progress"}, "phase.entered"},
      {"handoff", %{head: "abc123", pr_url: "https://github.com/acme/repo/pull/1", source: "pushed_pr_head"}, "attempt.pushed"},
      {"handoff", %{to: "Code Review", reason: "after the run", head: "abc123", move: true}, "phase.entered"},
      {"ci fix return", %{to: "Code Review", kind: :ci_fix, head: "abc123", move: true}, "phase.entered"},
      {"review verdict", %{outcome: "conflict", to: "Rework", reason: "merge conflict"}, "phase.entered"},
      {"merge settled", %{to: "Waiting on sub-tickets"}, "phase.entered"},
      {"merge settled", %{sub_issues: 2}, "phase.entered"},
      {"restart", %{move: "restart", from: "Rework", to: "In Progress"}, "phase.entered"},
      {"blocked", %{to: "Backlog", reason: "idle_park"}, "phase.entered"},
      {"blocked", %{reason: "no access", held: true}, :mirrored},
      {"code_review", %{target: "QA", signal: "approve", head: "abc123"}, "phase.entered"},
      {"code_review", %{target: "Merging", signal: "merge_confirmation"}, :mirrored},
      {"code_review", %{reason: "stuck", head: "abc123", signal: "code_review_escalate"}, :mirrored},
      {"qa", %{target: "Rework", signal: "fail"}, "phase.entered"},
      {"qa", %{target: "Merging", signal: "merge_confirmation"}, :mirrored},
      {"epic_review", %{target: "Done", signal: "pass"}, "phase.entered"},
      {"fix verdict", %{outcome: "rework", to: "Rework"}, "verdict.recorded"},
      {"plan verdict", %{outcome: "approve", to: "Waiting on sub-tickets"}, "verdict.recorded"},
      {"plan verdict", %{outcome: "approve", sub_issue: "TP-2", to: "Todo"}, "phase.entered"},
      {"deprioritized", %{outcome: "changes", sub_issue: "TP-2", to: "Canceled"}, "phase.entered"},
      {"decision returned", %{move: "decide", from: "Code Review", to: "Code Review"}, :mirrored},
      {"decision returned", %{move: "decide", from: "Code Review", to: "Rework"}, "phase.entered"},
      {"decision returned", %{move: "confirm", to: "Merging"}, "phase.entered"},
      {"decision returned", %{move: "rework", from: "QA", to: "Rework"}, "phase.entered"},
      {"decision requested", %{to: "Code Review", reason: "dependency"}, :mirrored},
      {"unblocked", %{by: "the Director"}, :mirrored},
      {"dispatch_loop", %{kind: "quiet", count: 3, window_ms: 60_000}, :mirrored},
      {"ci_wait", %{sha: "abc123"}, :mirrored},
      {"handoff_missing", %{head: "abc123", quiet_runs: 2, held: true}, :mirrored},
      {"handoff_missing", %{to: "Code Review", reason: "after the run"}, "note"},
      {"ci_wait_started", %{sha: "abc123"}, "note"},
      {"code_review_carried", %{head: "abc123"}, "note"},
      {"code_review_reviewer_disabled", %{}, "note"},
      {"code_review_head_not_green", %{head: "abc123", status: :red}, "note"},
      {"qa_head_not_green", %{head: "abc123", status: :pending}, "note"},
      {"qa_head_unreadable", %{}, "note"},
      {"ci_rerun", %{sha: "abc123", runs: []}, "note"},
      {"ci_flake", %{sha: "abc123", runs: ["https://ci/1"], workflows: ["ci"], jobs: [], tests: []}, "note"}
    ]

    test "every signal name in use yields its event, or is mirrored by a hold or decision event" do
      for {{name, details, expected}, index} <- Enum.with_index(@signals) do
        issue_id = "issue-signal-#{index}"
        assert :ok = TicketSignals.record(@repo_key, issue_id, name, details)

        assert %{signals: [%{name: ^name, details: ^details}]} = RunStore.get_ticket_state(@repo_key, issue_id)

        case expected do
          :mirrored ->
            assert TicketSignals.event(name, details) == :mirrored
            assert ticket_events(@repo_key, issue_id) == [], name

          type ->
            assert [{^type, payload}] = ticket_events(@repo_key, issue_id), "#{name} #{inspect(details)}"
            if type == "note", do: assert(payload.text =~ "(#{name})"), else: assert(payload.signal == name)
        end
      end
    end

    test "a phase move enters the state it names, in that phase" do
      assert {"phase.entered", %{to: "Rework", reason: "conflict", signal: "review verdict"}, [phase: "Rework"]} =
               TicketSignals.event("review verdict", %{outcome: "conflict", to: "Rework", reason: "merge conflict"})

      assert {"phase.entered", %{to: "QA", via: "approve", signal: "code_review"}, [phase: "QA", head_sha: "abc123"]} =
               TicketSignals.event("code_review", %{target: "QA", signal: "approve", head: "abc123"})

      assert {"phase.entered", %{to: "Rework", from: "QA", via: "rework"}, _opts} =
               TicketSignals.event("decision returned", %{"move" => "rework", "from" => "QA", "to" => "Rework"})

      assert {"phase.entered", %{to: "Rework", via: "rework", reason: "conflict"}, _opts} =
               TicketSignals.event("decision returned", %{move: :rework, to: "Rework", reason: :conflict, from: true})

      assert {"phase.entered", %{to: "Done", signal: "merge settled"}, [phase: "Done"]} = TicketSignals.event("merge settled", %{sub_issues: 2})
      assert {"phase.entered", %{to: "Backlog", reason: "idle_park"}, _opts} = TicketSignals.event("blocked", %{to: "Backlog", reason: "idle_park"})
    end

    test "a signal that names no state, and an unknown one, is a note rendered from its name and details" do
      assert {"note", %{text: "claim (claim)"}, []} = TicketSignals.event("claim", %{})
      assert {"note", %{text: "brand_new (brand_new)"}, []} = TicketSignals.event("brand_new", :not_a_map)

      assert {"note", %{text: "Code Review waits for a green head · head abc123 · status red (code_review_head_not_green)"}, []} =
               TicketSignals.event("code_review_head_not_green", %{head: "abc123", status: :red, runs: [1], at: nil})

      assert {"note", %{text: text}, []} = TicketSignals.event("ci_wait_started", %{sha: String.duplicate("a", 5_000)})
      assert String.length(text) == 4_000
    end

    test "a handoff with no head is a note, not an attempt" do
      assert {"note", %{text: "handoff · source pushed_pr_head (handoff)"}, []} = TicketSignals.event("handoff", %{source: "pushed_pr_head"})
    end
  end

  test "a handoff records one numbered attempt per head" do
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{head: "aaa111", pr_url: "https://github.com/acme/repo/pull/1"})
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{head: "aaa111"})
    assert :ok = TicketSignals.record(@repo_key, "issue-1", "handoff", %{head: "bbb222"})

    assert [
             {"attempt.pushed", %{head: "aaa111", attempt: 1, pr_url: "https://github.com/acme/repo/pull/1", signal: "handoff"}},
             {"attempt.pushed", %{head: "bbb222", attempt: 2}}
           ] = ticket_events(@repo_key, "issue-1")

    assert %{signals: [_, _, _]} = RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "a QA fail verdict records its event with its head, in QA, and stays in the verdicts" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "fail", %{reason: "clipped"})

    assert [%{type: "verdict.recorded", phase: "QA", head_sha: "abc123", payload: %{kind: "qa", outcome: "fail", head: "abc123"}}] =
             RunStore.list_ticket_events(@repo_key, "issue-1", [])

    assert %{verdicts: [%{kind: "qa", head_sha: "abc123", outcome: "fail", details: %{reason: "clipped"}}]} =
             RunStore.get_ticket_state(@repo_key, "issue-1")
  end

  test "a verdict a run gave names that run; one without a run id names none, and the verdicts are the same" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "pass", %{}, run_id: "run-qa-1")
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "code_review", "abc123", "approve")
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "epic_review", "abc123", "pass", %{}, run_id: " ")

    assert [
             %{type: "verdict.recorded", run_id: "run-qa-1", actor: %{kind: :machine}, phase: "QA", payload: qa_payload},
             %{type: "verdict.recorded", run_id: nil, phase: "Code Review"},
             %{type: "verdict.recorded", run_id: nil, phase: "Epic Review"}
           ] = RunStore.list_ticket_events(@repo_key, "issue-1", [])

    assert qa_payload == %{kind: "qa", outcome: "pass", head: "abc123"}

    %{verdicts: verdicts} = RunStore.get_ticket_state(@repo_key, "issue-1")
    assert verdicts |> Enum.map(&{&1.kind, &1.outcome, &1.details}) |> Enum.sort() == [{"code_review", "approve", %{}}, {"epic_review", "pass", %{}}, {"qa", "pass", %{}}]
  end

  test "verdict_event/4 binds the event to the run it names, and to none without one" do
    assert {"verdict.recorded", %{kind: "qa", outcome: "fail"}, opts} = TicketSignals.verdict_event("qa", "fail", "abc123", run_id: "run-qa-1")
    assert opts[:run_id] == "run-qa-1"
    assert opts[:head_sha] == "abc123"

    assert {"verdict.recorded", _payload, opts} = TicketSignals.verdict_event("qa", "fail", "abc123")
    refute Keyword.has_key?(opts, :run_id)
  end

  test "verdict_event/4 carries the verdict's summary as its reason, and none when it is blank" do
    assert {"verdict.recorded", %{reason: "adds 3, changes 0, removes 0 lines. ok"}, _opts} =
             TicketSignals.verdict_event("code_review", "approve", "abc123", reason: "adds 3, changes 0, removes 0 lines. ok")

    assert {"verdict.recorded", payload, _opts} = TicketSignals.verdict_event("code_review", "approve", "abc123", reason: " ")
    refute Map.has_key?(payload, :reason)
  end

  test "repeated verdicts on one head stay separate events" do
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "code_review", "abc123", "inconclusive")
    assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "code_review", "abc123", "inconclusive")

    assert [{"verdict.recorded", %{outcome: "inconclusive"}}, {"verdict.recorded", %{outcome: "inconclusive"}}] =
             ticket_events(@repo_key, "issue-1")
  end

  test "the snapshot fields are the same with the events as without them" do
    TicketSignals.record(@repo_key, "issue-1", "claim", %{from: "Todo", to: "In Progress"})
    TicketSignals.record_verdict(@repo_key, "issue-1", "qa", "abc123", "pass")
    RunStore.record_ticket_signal(@repo_key, "issue-2", "claim", %{from: "Todo", to: "In Progress"})
    RunStore.record_ticket_verdict(@repo_key, "issue-2", "qa", "abc123", "pass")

    snapshot = fn issue_id ->
      @repo_key |> RunStore.get_ticket_state(issue_id) |> Map.take([:signals, :verdicts, :holds, :decisions]) |> strip_times()
    end

    assert snapshot.("issue-1") == snapshot.("issue-2")
    assert length(ticket_events(@repo_key, "issue-1")) == 2
  end

  test "a refused event is logged and swallowed: the signal and the verdict are still recorded" do
    log =
      capture_log(fn ->
        assert :ok = TicketSignals.record_verdict(@repo_key, "issue-1", "pre_push_review", "abc123", "pass")
        assert :ok = TicketSignals.record(@repo_key, "issue-1", "fix verdict", %{to: "Rework"})
      end)

    assert log =~ "Failed to record the verdict.recorded event on issue_id=issue-1: {:invalid_payload, [:kind]}"
    assert log =~ "Failed to record the verdict.recorded event on issue_id=issue-1: {:invalid_payload, [:outcome]}"
    assert %{verdicts: [%{kind: "pre_push_review"}], signals: [%{name: "fix verdict"}]} = RunStore.get_ticket_state(@repo_key, "issue-1")
    assert ticket_events(@repo_key, "issue-1") == []
  end

  describe "the questions an event ends (TP-1241)" do
    @request %{
      title: "Pick a layout",
      question: "Which of the two layouts should the settings pane use?",
      why: "The run built both. Only you can pick.",
      if_unanswered: "The run waits for your pick.",
      recommendation_reason: "The list fits the laptop screen.",
      options: [%{label: "The list", effect: "The pane shows a list.", recommended: true}, %{label: "The grid", effect: "The pane shows a grid."}]
    }
    @confirmation %{@request | title: "Merge the pull request", question: "Should Symphony merge the pull request now?"}
    @run %{kind: :run, name: "The run"}
    @started ~U[2026-10-30 04:00:00Z]

    defp start_run(repo_key, issue_id, phase) do
      :ok = TicketSignals.record_phase(repo_key, issue_id, phase)
      payload = %{run_id: "run-1", run_kind: "implementation", run_number: 1, state: phase}
      :ok = TicketSignals.record_event(repo_key, issue_id, "run.started", payload, phase: phase, run_id: "run-1", at: @started)
    end

    defp end_run(repo_key, issue_id) do
      payload = %{run_id: "run-1", exit: "success"}
      TicketSignals.record_event(repo_key, issue_id, "run.ended", payload, run_id: "run-1", at: DateTime.utc_now())
    end

    defp ask(ticket, request, asked_by) do
      {:ok, question} = Questions.ask(ticket, request, asked_by: asked_by, at: ~U[2026-10-30 04:10:00Z])
      question
    end

    test "a run ending withdraws the question it asked once the ticket moved on, and never a question about the ticket itself" do
      repo_key = Config.repo_key!()
      ticket = {:ticket, repo_key, "issue-run"}
      start_run(repo_key, "issue-run", "In Progress")
      asked = ask(ticket, @request, @run)
      confirmation = ask(ticket, @confirmation, %{kind: :symphony, name: "Symphony"})

      # The run ends with the ticket where it started: the question still waits.
      assert :ok = end_run(repo_key, "issue-run")
      assert %{state: :open} = Questions.find(ticket, asked.id)

      :ok = TicketSignals.record_phase(repo_key, "issue-run", "Rework")
      assert :ok = end_run(repo_key, "issue-run")
      assert %{state: :withdrawn, withdrawn: %{reason: "The run that asked ended and the ticket moved on to Rework."}} = Questions.find(ticket, asked.id)
      assert %{state: :open} = Questions.find(ticket, confirmation.id)
    end

    test "a protected-path request outlives the run that asked it, which claimed the ticket; a cancel withdraws it (TP-1321)" do
      repo_key = Config.repo_key!()
      ticket = {:ticket, repo_key, "issue-protected"}
      # The run starts in Todo and claims the ticket into In Progress, then asks through the Inbox path.
      start_run(repo_key, "issue-protected", "Todo")
      :ok = TicketSignals.record_phase(repo_key, "issue-protected", "In Progress")
      {:ok, asked} = Questions.ask(ticket, @request, asked_by: @run, request: true, asked_in: "In Progress", at: ~U[2026-10-30 04:10:00Z])

      # The run ends to wait on the answer, and five minutes on nothing has withdrawn it.
      assert :ok = end_run(repo_key, "issue-protected")
      payload = %{run_id: "run-1", exit: "success"}
      assert :ok = TicketSignals.record_event(repo_key, "issue-protected", "run.ended", payload, run_id: "run-1", at: DateTime.add(DateTime.utc_now(), 300))
      assert [%{id: id, state: :open}] = Questions.open(ticket)
      assert id == asked.id

      # Asking it again is the one question.
      assert {:ok, %{id: ^id}} = Questions.ask(ticket, @request, asked_by: @run, request: true, asked_in: "In Progress")

      assert :ok = TicketSignals.record(repo_key, "issue-protected", "decision returned", %{move: "cancel", from: "In Progress", to: "Canceled"})
      assert %{withdrawn: %{reason: "The ticket was cancelled."}} = Questions.find(ticket, id)
      assert [%{payload: %{cause: "ticket_moved"}}] = RunStore.list_ticket_events(repo_key, "issue-protected", types: ["question.withdrawn"])
    end

    test "a run that ended on a cancelled ticket withdraws every question; one with no start withdraws nothing" do
      repo_key = Config.repo_key!()
      ticket = {:ticket, repo_key, "issue-cancel"}
      asked = ask(ticket, @request, @run)

      assert :ok = end_run(repo_key, "issue-cancel")
      assert %{state: :open} = Questions.find(ticket, asked.id)

      :ok = TicketSignals.record_phase(repo_key, "issue-cancel", "Canceled")
      assert :ok = end_run(repo_key, "issue-cancel")
      assert %{withdrawn: %{reason: "The ticket was cancelled."}} = Questions.find(ticket, asked.id)
    end

    test "a merge settled withdraws a merge confirmation nobody answered" do
      ticket = {:ticket, @repo_key, "issue-merge"}
      question = ask(ticket, @confirmation, %{kind: :symphony, name: "Symphony"})

      assert :ok = TicketSignals.record(@repo_key, "issue-merge", "merge settled", %{to: "Done"})
      assert %{state: :withdrawn, withdrawn: %{reason: "The pull request merged before you answered."}} = Questions.find(ticket, question.id)
    end

    test "a move into a terminal state withdraws every open question; a move into an open phase withdraws none" do
      repo_key = Config.repo_key!()
      ticket = {:ticket, repo_key, "issue-done"}
      question = ask(ticket, @confirmation, %{kind: :symphony, name: "Symphony"})

      assert :ok = TicketSignals.record(repo_key, "issue-done", "decision returned", %{move: "rework", from: "QA", to: "Rework"})
      assert %{state: :open} = Questions.find(ticket, question.id)

      assert :ok = TicketSignals.record(repo_key, "issue-done", "decision returned", %{move: "cancel", from: "Rework", to: "Canceled"})
      assert %{withdrawn: %{reason: "The ticket was cancelled."}} = Questions.find(ticket, question.id)
    end
  end

  describe "open_decision/4" do
    test "finds the newest open request by its title, else its question" do
      {:ok, older} = TicketEvents.record(@repo_key, "issue-1", "decision.requested", %{title: "Pick one", question: "A or B?"})
      {:ok, newer} = TicketEvents.record(@repo_key, "issue-1", "decision.requested", %{title: "Pick one", question: "A, B or C?"})
      {:ok, _closed} = TicketEvents.record(@repo_key, "issue-1", "decision.withdrawn", %{title: "Gone", request: "nope"})

      assert TicketSignals.open_decision(@repo_key, "issue-1", "  pick ONE ", nil).id == newer.id
      assert TicketSignals.open_decision(@repo_key, "issue-1", nil, "a or b?").id == older.id
      assert TicketSignals.open_decision(@repo_key, "issue-1", "Other", nil) == nil
      assert TicketSignals.open_decision(@repo_key, "issue-1", nil, " ") == nil
      assert TicketSignals.open_decision(" ", "issue-1", "Pick one", nil) == nil
    end
  end

  describe "open_decision/4 and Questions" do
    test "finds an open Question's request as it finds a decision request, until the Question ends" do
      {:ok, asked} = TicketEvents.record(@repo_key, "issue-1", "question.asked", %{question_id: "q-1", title: "Pick one", question: "A or B?"})
      assert TicketSignals.open_decision(@repo_key, "issue-1", "pick one", nil).id == asked.id

      {:ok, _answered} = TicketEvents.record(@repo_key, "issue-1", "question.answered", %{question_id: "q-1", answer: "A"})
      assert TicketSignals.open_decision(@repo_key, "issue-1", "Pick one", nil) == nil
    end
  end

  test "same_text?/2 ignores case and spacing, and a blank text matches nothing" do
    assert TicketSignals.same_text?(" A  or\nb? ", "a or B?")
    refute TicketSignals.same_text?("A or B?", "A, B or C?")
    refute TicketSignals.same_text?(" ", " ")
    refute TicketSignals.same_text?(nil, nil)
  end

  # The test takes the orchestrator's name, so the cast a move sends comes to it; the application's
  # orchestrator, when it runs, is stopped meanwhile and started again after.
  defp stand_in_for_orchestrator do
    if Process.whereis(Orchestrator) do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)
      on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator) end)
    end

    Process.register(self(), Orchestrator)
  end

  defp strip_times(snapshot) do
    Map.new(snapshot, fn {key, entries} -> {key, Enum.map(entries, &Map.drop(&1, [:at, :recorded_at]))} end)
  end

  test "logs and swallows a store failure" do
    log =
      capture_log(fn ->
        assert :ok = TicketSignals.record("  ", "issue-1", "handoff", %{})
        assert :ok = TicketSignals.record_verdict("  ", "issue-1", "qa", nil, "pass")
      end)

    assert log =~ "Failed to record handoff signal"
    assert log =~ "Failed to record qa verdict"
  end
end
