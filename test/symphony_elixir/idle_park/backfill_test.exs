defmodule SymphonyElixir.IdlePark.BackfillTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, IdlePark, Pauses, Questions, RunStore}
  alias SymphonyElixir.IdlePark.Backfill

  @repo "repo-park"

  # The ticket's signals are its events, which only clearing the store drops.
  setup do
    :ok = RunStore.clear()
  end

  # TP-1248's record as the build before TP-1326 left it at 05:53Z: parked in Backlog by Symphony,
  # its park signal naming no phase, no question and no pause.
  defp old_park(repo_key \\ @repo, issue_id \\ "tp-1248", identifier \\ "TP-1248", overrides \\ %{}) do
    {signals, overrides} =
      Map.pop(overrides, :signals, [%{name: "blocked", details: %{to: "Backlog", reason: "idle_park"}, at: ~U[2026-10-31 05:53:00Z]}])

    record =
      Map.merge(
        %{
          repo_key: repo_key,
          issue_id: issue_id,
          issue_identifier: identifier,
          phase: "Backlog",
          phase_owner: :symphony,
          phase_at: ~U[2026-10-31 05:53:00Z]
        },
        overrides
      )

    :ok = RunStore.put_ticket_state(record)
    for signal <- signals, do: :ok = put_signal(repo_key, issue_id, signal.name, signal.details, signal.at)
    {:ticket, repo_key, issue_id}
  end

  defp no_workspace(_repo_key, _identifier), do: nil

  test "an old park gets the park's question and one park.backfilled event; a second boot adds nothing" do
    ticket = old_park()

    assert %{backfilled: ["TP-1248"]} = Backfill.run([@repo], workspace: &no_workspace/2)

    assert [%{title: "TP-1248 is parked: its last 2 turns changed nothing", id: question_id} = question] = Questions.open(ticket)
    assert Questions.held(ticket) == question
    assert Pauses.paused?(ticket)

    assert [{"park.backfilled", %{added: ["question"], question_id: ^question_id, from: "In Progress"}}] =
             ticket_events(@repo, "tp-1248", "park.backfilled")

    assert %{backfilled: []} = Backfill.run([@repo], workspace: &no_workspace/2)
    assert [^question] = Questions.open(ticket)
    assert [_one] = ticket_events(@repo, "tp-1248", "park.backfilled")
  end

  test "a park that names the phase it left keeps it, and the workspace's unpushed commits are pushed first" do
    signal = %{name: "blocked", details: %{to: "Backlog", reason: "idle_park", from: "Rework"}, at: ~U[2026-10-31 05:53:00Z]}
    old_park(@repo, "tp-1", "TP-1", %{signals: [signal]})
    test_pid = self()

    pusher = fn workspace, worker_host, source ->
      send(test_pid, {:push, workspace, worker_host, source})
      {:pushed, "auto/TP-1"}
    end

    log =
      capture_log(fn ->
        assert %{backfilled: ["TP-1"]} = Backfill.run([@repo], workspace: fn @repo, "TP-1" -> {"/ws/TP-1", "/src"} end, pusher: pusher)
      end)

    assert_received {:push, "/ws/TP-1", nil, "/src"}
    assert log =~ "Pushed TP-1's unpushed commits to origin auto/TP-1"
    assert log =~ "Brought 1 parked ticket(s) up to date: TP-1"

    assert [{"park.backfilled", %{added: ["question", "push"], branch: "auto/TP-1", from: "Rework"}}] =
             ticket_events(@repo, "tp-1", "park.backfilled")
  end

  test "a push that fails is logged and the park still gets its question; one with nothing to push adds no push" do
    old_park(@repo, "tp-1", "TP-1")
    old_park(@repo, "tp-2", "TP-2")

    pusher = fn
      "/ws/TP-1", nil, _source -> {:error, :rejected}
      "/ws/TP-2", nil, _source -> :nothing
    end

    log = capture_log(fn -> Backfill.run([@repo], workspace: fn _repo, name -> {"/ws/" <> name, nil} end, pusher: pusher) end)

    assert log =~ "Could not push TP-1's unpushed commits while bringing its park up to date; they stay in its workspace reason=:rejected"
    assert [{"park.backfilled", %{added: ["question"]}}] = ticket_events(@repo, "tp-1", "park.backfilled")
    assert [{"park.backfilled", %{added: ["question"]}}] = ticket_events(@repo, "tp-2", "park.backfilled")
  end

  test "a question the store refuses pauses the ticket on a reason Unblock releases" do
    # A title past the writing standard's bound makes the store refuse the question.
    ticket = old_park(@repo, "tp-long", String.duplicate("X", 200))

    log = capture_log(fn -> assert %{backfilled: [_name]} = Backfill.run([@repo], workspace: &no_workspace/2) end)

    assert log =~ "Failed to ask the park's question"
    assert Questions.open(ticket) == []
    assert Pauses.releasable?(ticket)
    assert {:ok, %{reasons: [%{waits_on: %{condition: "idle_park"}, text: text}]}} = Pauses.get(ticket)
    assert text =~ "2 turns in In Progress made no new commit"
    assert [{"park.backfilled", %{added: ["releasable_reason"]}}] = ticket_events(@repo, "tp-long", "park.backfilled")

    assert %{backfilled: []} = Backfill.run([@repo], workspace: &no_workspace/2)
  end

  test "a ticket not parked by an idle run, not Symphony's, out of Backlog or already asked is left alone" do
    old_park(@repo, "external", "TP-2", %{phase_owner: :external})
    old_park(@repo, "moved", "TP-3", %{phase: "In Progress"})
    old_park(@repo, "by-hand", "TP-4", %{signals: [%{name: "decision returned", details: %{move: "backlog", to: "Backlog"}, at: ~U[2026-10-31 05:53:00Z]}]})
    asked = old_park(@repo, "asked", "TP-5")
    {:ok, _question} = Questions.ask(asked, IdlePark.question_attrs("TP-5", 2))
    released = old_park(@repo, "released", "TP-6")
    {:ok, _pause} = Pauses.set(released, %{kind: :environment, waits_on: %{condition: "idle_park"}, text: "parked", releasable: true})

    assert %{backfilled: []} = Backfill.run([@repo], workspace: &no_workspace/2)
    assert ticket_events(@repo, "external", "park.backfilled") == []
  end

  test "the workspace is the ticket's under the repo's workspace root; an unknown repo has none to push" do
    {:ok, [%{name: repo_key} | _repos]} = Config.repos()
    root = Path.expand(Config.settings_for_repo!(repo_key).workspace.root)
    old_park(repo_key, "tp-ws", "TP-7")
    old_park("repo-unknown", "tp-unknown", "TP-8")
    test_pid = self()
    pusher = fn workspace, _host, _source -> send(test_pid, {:push, workspace}) && :nothing end

    assert %{backfilled: ["TP-7", "TP-8"]} = Backfill.run([repo_key, "repo-unknown"], pusher: pusher)

    expected = Path.join([root, SymphonyElixir.Workspace.safe_identifier(repo_key), "TP-7"])
    assert_received {:push, ^expected}
    refute_received {:push, _other}
  end

  test "an event the ledger refuses is logged; the ticket keeps its question" do
    signal = %{name: "blocked", details: %{to: "Backlog", reason: "idle_park", from: " "}, at: ~U[2026-10-31 05:53:00Z]}
    ticket = old_park(@repo, "tp-blank", "TP-9", %{signals: [signal]})

    log = capture_log(fn -> assert %{backfilled: ["TP-9"]} = Backfill.run([@repo], workspace: &no_workspace/2) end)

    assert log =~ "Brought TP-9's park up to date but couldn't record it"
    assert [_question] = Questions.open(ticket)
  end

  test "a repo whose tickets can't be read is logged and skipped" do
    log = capture_log(fn -> assert %{backfilled: []} = Backfill.run(["  "]) end)
    assert log =~ "Failed to read the tickets to backfill their parks"
  end

  describe "start/2" do
    test "is off unless enabled, and runs in a task of the supervisor it is given" do
      assert Backfill.start([@repo]) == :disabled

      old_park()
      {:ok, pid} = Backfill.start([@repo], enabled: true, workspace: &no_workspace/2)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      assert [_question] = Questions.open({:ticket, @repo, "tp-1248"})
    end

    test "a supervisor that is not running is logged" do
      log = capture_log(fn -> assert {:error, _reason} = Backfill.start([@repo], enabled: true, supervisor: :no_such_supervisor) end)
      assert log =~ "Failed to start the backfill of parked tickets"
    end
  end
end
