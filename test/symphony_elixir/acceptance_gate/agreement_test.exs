defmodule SymphonyElixir.AcceptanceGate.AgreementTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AcceptanceGate.Agreement
  alias SymphonyElixir.Linear.Issue

  @judged_at ~U[2026-10-04 10:00:00Z]
  @now ~U[2026-10-04 12:00:00Z]
  @waiting ["In Review", "Auto Review", "Human Review"]

  defmodule FakeTracker do
    def fetch_issue_states_by_ids(ids) do
      send(self(), {:fetched_states, ids})

      case Process.get(:tracker_states) do
        {:error, _reason} = error -> error
        states -> {:ok, for(id <- ids, Map.has_key?(states, id), do: %Issue{id: id, state: Map.fetch!(states, id)})}
      end
    end
  end

  defmodule RaisingTracker do
    def fetch_issue_states_by_ids(_ids), do: raise("no pending verdict should ask the tracker")
  end

  defmodule FailingStore do
    def list_pr_reviews(_repo_key), do: {:error, :disk_full}
    def update_run(_repo_key, _run_id, _attrs), do: {:error, :disk_full}
    def list_all_runs(:all), do: {:error, :disk_full}
    def list_runs(_repo_key, :all), do: {:error, :disk_full}
  end

  defp gate_run(issue_id, verdict, attrs \\ %{}) do
    Map.merge(
      %{
        run_id: "gate-#{issue_id}-#{System.unique_integer([:positive])}",
        repo_key: "default",
        kind: "acceptance_gate",
        issue_id: issue_id,
        issue_identifier: String.upcase(issue_id),
        pr_url: "https://github.com/org/app/pull/1",
        head_sha: "sha-#{issue_id}",
        mode: "shadow",
        verdict: verdict,
        agent_verdict: verdict,
        reasons: [],
        criteria: %{met: 2, unmet: 0, unclear: 0},
        tokens: %{total_tokens: 1_000},
        started_at: @judged_at,
        judged_at: @judged_at
      },
      attrs
    )
  end

  defp decided(verdict, decision, attrs \\ %{}) do
    gate_run("issue-#{System.unique_integer([:positive])}", verdict, Map.merge(%{human_decision: decision, human_decided_at: @now, unchanged: true}, attrs))
  end

  defp put_runs(runs), do: Enum.each(runs, &(:ok = RunStore.put_run(&1)))

  defp stored(issue_id), do: Enum.find(RunStore.list_runs("default", :all), &(&1.issue_id == issue_id and is_map_key(&1, :human_decision)))

  defp agreement_events(dir) do
    {:ok, events} = SymphonyElixir.AuditLog.query(event_type: "acceptance_gate_agreement", dir: dir)
    Enum.sort_by(Enum.to_list(events), & &1["issue_identifier"])
  end

  describe "human_decision/4" do
    test "reads the decision from the state the issue left In Review for" do
      run = gate_run("issue-1", "approve")
      review = fn action, at -> %{last_action: action, last_action_at: at} end

      assert Agreement.human_decision(run, "Merging", nil, @waiting) == "approve"
      assert Agreement.human_decision(run, " done ", nil, @waiting) == "approve"
      assert Agreement.human_decision(run, "Rework", nil, @waiting) == "rework"
      assert Agreement.human_decision(run, "In Progress", review.("rework", @now), @waiting) == "rework"
      assert Agreement.human_decision(run, "In Progress", review.("rework", @judged_at), @waiting) == "rework"

      # Waiting: still in review, or back in progress without review comments since the verdict.
      assert Agreement.human_decision(run, "In Review", nil, @waiting) == nil
      assert Agreement.human_decision(run, "Human Review", nil, @waiting) == nil
      assert Agreement.human_decision(run, "QA Review", nil, ["QA Review", "In Review"]) == nil
      assert Agreement.human_decision(run, "Auto Review", nil, ["QA Review", "In Review"]) == "none"
      assert Agreement.human_decision(run, "In Progress", nil, @waiting) == nil
      assert Agreement.human_decision(run, "In Progress", review.("rework", ~U[2026-10-04 09:00:00Z]), @waiting) == nil
      assert Agreement.human_decision(run, "In Progress", review.("conflict", @now), @waiting) == nil
      assert Agreement.human_decision(run, "In Progress", review.("merge", @now), @waiting) == nil
      assert Agreement.human_decision(run, nil, nil, @waiting) == nil

      assert Agreement.human_decision(run, "Canceled", nil, @waiting) == "none"
    end
  end

  describe "observe/5" do
    setup do
      dir = Path.join(System.tmp_dir!(), "gate-agreement-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "records approve, rework and none on each issue's latest verdict, with a fake tracker", %{dir: dir} do
      runs = [
        gate_run("merged", "approve"),
        gate_run("sent-back", "rework", %{agent_verdict: "rework"}),
        gate_run("commented", "approve"),
        gate_run("escalated", "escalate", %{agent_verdict: "approve"}),
        gate_run("with-person", "approve"),
        gate_run("canceled", "approve"),
        gate_run("superseded", "rework", %{judged_at: ~U[2026-10-04 08:00:00Z]}),
        gate_run("superseded", "approve", %{head_sha: "sha-new"}),
        gate_run("decided", "approve", %{human_decision: "approve"}),
        %{run_id: "impl-1", repo_key: "default", kind: "implementation", issue_id: "merged", started_at: @judged_at}
      ]

      put_runs(runs)
      :ok = RunStore.put_pr_review(%{repo_key: "default", issue_id: "commented", last_action: "rework", last_action_at: @now})

      Process.put(:tracker_states, %{"sent-back" => "Rework", "commented" => "In Progress", "canceled" => "Canceled", "superseded" => "Merging"})

      issues = [
        %Issue{id: "merged", state: "Merging"},
        %Issue{id: "escalated", state: "In Review"},
        %Issue{id: "with-person", state: "Human Review"},
        %Issue{id: "unrelated", state: "In Review"}
      ]

      ci_checks = [%{issue_id: "sent-back", last_observed_sha: "sha-pushed"}, %{issue_id: "merged", last_observed_sha: "sha-merged"}]

      opts = [tracker: FakeTracker, now: @now, audit_dir: dir]
      decisions = Agreement.observe("default", issues, RunStore.list_runs("default", :all), ci_checks, opts)

      assert Enum.sort(decisions) == [{"canceled", "none"}, {"commented", "rework"}, {"merged", "approve"}, {"sent-back", "rework"}, {"superseded", "approve"}]
      assert_received {:fetched_states, fetched}
      assert Enum.sort(fetched) == ["canceled", "commented", "sent-back", "superseded"]

      assert %{human_decision: "approve", human_decision_state: "Merging", human_decision_sha: "sha-merged"} = stored("merged")
      assert %{human_decided_at: @now, unchanged: true, agreed: true} = stored("merged")

      assert %{human_decision: "rework", human_decision_sha: "sha-pushed", unchanged: false, agreed: true} = stored("sent-back")
      assert %{human_decision: "rework", human_decision_state: "In Progress", agreed: false} = stored("commented")
      assert %{human_decision: "none", agreed: nil} = stored("canceled")
      assert %{human_decision: "approve", head_sha: "sha-new", agreed: true} = stored("superseded")
      assert stored("escalated") == nil
      assert stored("with-person") == nil

      assert [
               %{"issue_identifier" => "COMMENTED", "verdict" => "approve", "decision" => "rework", "agreed" => false},
               %{"issue_identifier" => "MERGED", "decision" => "approve", "sha" => "sha-merged", "decision_sha" => "sha-merged", "unchanged" => true},
               %{"issue_identifier" => "SENT-BACK", "decision" => "rework", "agreed" => true, "unchanged" => false},
               %{"issue_identifier" => "SUPERSEDED", "decision" => "approve"}
             ] = agreement_events(dir)

      # A second poll finds only the verdicts still in review waiting, and they are watched.
      assert Agreement.observe("default", issues, RunStore.list_runs("default", :all), ci_checks, tracker: RaisingTracker) == []
    end

    test "undecided/2 is each issue's latest undecided verdict of the repository" do
      put_runs([
        gate_run("waiting", "approve"),
        gate_run("decided", "approve", %{human_decision: "approve"}),
        gate_run("moved", "approve", %{moved_by_gate: "Merging"}),
        gate_run("other-repo", "approve", %{repo_key: "other"})
      ])

      assert ["waiting"] = Enum.map(Agreement.undecided("default"), & &1.issue_id)

      # A newer verdict on the issue replaces the kept one.
      assert :ok = RunStore.put_run(gate_run("waiting", "rework", %{judged_at: @now}))
      assert [%{issue_id: "waiting", verdict: "rework"}] = Agreement.undecided("default")

      assert Agreement.undecided("default", run_store: FailingStore) == []
    end

    test "an escalated verdict the human merges unchanged has no agreement", %{dir: dir} do
      put_runs([gate_run("escalated", "escalate")])
      issues = [%Issue{id: "escalated", state: "Merging"}]

      runs = RunStore.list_runs("default", :all)
      assert [{"escalated", "approve"}] = Agreement.observe("default", issues, runs, [], tracker: RaisingTracker, audit_dir: dir)
      assert %{human_decision: "approve", unchanged: true, agreed: nil} = stored("escalated")
    end

    test "no pending verdict asks nothing" do
      runs = [gate_run("decided", "approve", %{human_decision: "rework"}), gate_run("inconclusive", nil)]
      assert Agreement.observe("default", [], runs, [], tracker: RaisingTracker, run_store: FailingStore) == []
    end

    test "logs a tracker, store or audit failure and records nothing it could not store", %{dir: dir} do
      runs = [gate_run("watched", "approve"), gate_run("unwatched", "approve"), gate_run("back", "approve")]
      issues = [%Issue{id: "watched", state: "Merging"}, %Issue{id: "back", state: "In Progress"}]
      Process.put(:tracker_states, {:error, :linear_down})

      log =
        capture_log(fn ->
          assert Agreement.observe("default", issues, runs, [], tracker: FakeTracker, run_store: FailingStore) == []
        end)

      assert log =~ "Acceptance gate agreement could not read issue states: :linear_down"
      assert log =~ "Failed to store the human decision on the acceptance gate run run_id=gate-watched-"

      put_runs([gate_run("audited", "approve")])
      File.write!(dir, "not a directory")

      log =
        capture_log(fn ->
          issues = [%Issue{id: "audited", state: "Done"}]
          runs = RunStore.list_runs("default", :all)
          assert [{"audited", "approve"}] = Agreement.observe("default", issues, runs, [], tracker: RaisingTracker, audit_dir: dir)
        end)

      assert log =~ "Failed to audit the acceptance gate agreement for AUDITED"
    end
  end

  describe "stats/1" do
    test "counts the last 50 decisions: agreed, unsafe approvals, false reworks, escalations and tokens" do
      runs = [
        decided("approve", "approve", %{tokens: %{total_tokens: 100}}),
        decided("rework", "rework", %{tokens: %{total_tokens: 200}}),
        decided("approve", "rework", %{tokens: %{total_tokens: 300}}),
        decided("rework", "approve", %{tokens: %{total_tokens: 400}}),
        decided("rework", "approve", %{unchanged: false, tokens: %{total_tokens: 500}}),
        decided("escalate", "approve", %{tokens: %{total_tokens: 600}}),
        decided("escalate", "approve", %{unchanged: false, tokens: %{total_tokens: 700}}),
        decided("escalate", "rework", %{tokens: %{total_tokens: 800}}),
        decided("approve", "approve", %{tokens: %{total_tokens: 900}}),
        decided("approve", "approve", %{tokens: nil}),
        decided("approve", "none"),
        gate_run("waiting", "approve"),
        gate_run("inconclusive", nil)
      ]

      assert Agreement.stats(runs) == %{
               judged: 10,
               agreed: 4,
               agreement_rate: 0.571,
               unsafe_approvals: 1,
               false_reworks: 1,
               escalations: 3,
               escalations_merged_unchanged: 1,
               tokens: %{median: 400, p90: 800},
               ready_to_enforce: false,
               unmet_condition: "at least 20 judged tickets (10 so far)"
             }
    end

    test "keeps only the 50 newest decisions" do
      # A decision without a time sorts oldest.
      old = for _ <- 1..5, do: decided("approve", "rework", %{human_decided_at: nil})
      recent = for _ <- 1..50, do: decided("approve", "approve")

      assert %{judged: 50, agreed: 50, agreement_rate: 1.0, unsafe_approvals: 0, ready_to_enforce: true, unmet_condition: nil} = Agreement.stats(old ++ recent)
    end

    test "no decision yet has no rates or tokens" do
      assert %{judged: 0, agreement_rate: nil, tokens: %{median: nil, p90: nil}, unmet_condition: "at least 20 judged tickets (0 so far)"} = Agreement.stats([])
    end
  end

  describe "ready_to_enforce/1" do
    defp counts(attrs), do: Map.merge(%{judged: 20, agreed: 20, unsafe_approvals: 0, false_reworks: 0, not_escalated: 20}, attrs)

    test "names the first unmet condition" do
      assert Agreement.ready_to_enforce(counts(%{})) == :ok
      assert Agreement.ready_to_enforce(counts(%{agreed: 18})) == :ok
      assert Agreement.ready_to_enforce(counts(%{judged: 19, unsafe_approvals: 1})) == {:unmet, "at least 20 judged tickets (19 so far)"}
      assert Agreement.ready_to_enforce(counts(%{unsafe_approvals: 1, false_reworks: 5})) == {:unmet, "no unsafe approvals (1)"}
      assert Agreement.ready_to_enforce(counts(%{false_reworks: 2})) == :ok
      assert Agreement.ready_to_enforce(counts(%{false_reworks: 3, agreed: 0})) == {:unmet, "false reworks at 10% or less (15%)"}

      assert Agreement.ready_to_enforce(counts(%{agreed: 0, not_escalated: 0})) ==
               {:unmet, "at least 90% agreement on the tickets the gate didn't escalate (none yet)"}

      assert Agreement.ready_to_enforce(counts(%{agreed: 17})) == {:unmet, "at least 90% agreement on the tickets the gate didn't escalate (85%)"}
    end
  end

  describe "snapshot/1 and latest/3" do
    test "lists the latest verdict per issue, newest first, and the agreement per repo" do
      put_runs([
        gate_run("one", "rework", %{judged_at: ~U[2026-10-04 08:00:00Z]}),
        gate_run("one", "approve", %{judged_at: ~U[2026-10-04 09:00:00Z]}),
        gate_run("two", "escalate", %{repo_key: "api", human_decision: "approve", human_decided_at: @now, unchanged: true}),
        gate_run("three", nil)
      ])

      snapshot = Agreement.snapshot(runner: Module.concat(__MODULE__, :NoRunner))

      assert %{running: [], queued: [], recent: [%{issue_id: "two"}, %{issue_id: "one", verdict: "approve"}]} = snapshot
      assert %{"api" => %{judged: 1, escalations: 1, escalations_merged_unchanged: 1}} = snapshot.agreement
      assert %{"default" => %{judged: 0}} = snapshot.agreement

      assert %{verdict: "approve"} = Agreement.latest("default", "one")
      assert Agreement.latest("default", "three") == nil
      assert Agreement.latest(nil, "one") == nil
      assert Agreement.latest("default", "one", run_store: FailingStore) == nil
    end

    test "reads the run store again only after a gate run is written" do
      put_runs([gate_run("one", "approve", %{judged_at: ~U[2026-10-04 08:00:00Z]})])
      no_runner = [runner: Module.concat(__MODULE__, :NoRunner)]
      assert %{recent: [%{issue_id: "one"}]} = Agreement.snapshot(no_runner)
      assert %{issue_id: "one"} = Agreement.latest("default", "one")

      # Written behind RunStore's back: the kept verdicts don't see it.
      hidden = gate_run("hidden", "rework", %{judged_at: ~U[2026-10-04 09:00:00Z]})

      assert {:atomic, :ok} =
               :mnesia.transaction(fn ->
                 :mnesia.write({:symphony_run_store_runs, {"default", hidden.run_id}, "default", hidden.run_id, hidden})
               end)

      assert :ok = RunStore.put_run(%{repo_key: "default", run_id: "agent-run", kind: "agent", issue_id: "one"})
      assert %{recent: [%{issue_id: "one"}]} = Agreement.snapshot(no_runner)
      assert Agreement.latest("default", "hidden") == nil

      put_runs([gate_run("two", "approve", %{judged_at: ~U[2026-10-04 10:00:00Z]})])
      assert %{recent: [%{issue_id: "two"}, %{issue_id: "hidden"}, %{issue_id: "one"}]} = Agreement.snapshot(no_runner)
      assert %{verdict: "rework"} = Agreement.latest("default", "hidden")
    end

    test "an unreadable store or a dead runner shows an empty gate" do
      runner = spawn(fn -> :ok end)
      ref = Process.monitor(runner)
      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}

      empty = %{running: [], queued: [], recent: [], agreement: %{}}
      assert Agreement.snapshot(run_store: FailingStore, runner: runner) == empty
    end
  end
end
