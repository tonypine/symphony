defmodule SymphonyElixir.QaSeedTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{Artifacts, Config, DirectorMoves, Inbox, Orchestrator, Paths, Pauses}
  alias SymphonyElixir.{PlanBrief, QaSeed}
  alias SymphonyElixir.{Questions, RunStore, Situation, SubIssueWait, TicketEvents, Tracker, UsageLimit}
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.ControlApiController

  # The restart's reset, which the QA server's `gh` stand-in answers for the seed's own PRs.
  defmodule SeedGitHub do
    def fetch_activity(_pr_url, _opts), do: {:ok, %{state: "OPEN"}}
    def close(_pr_url, _opts), do: :ok
  end

  defmodule SeedWorkspace do
    def remove_issue_workspaces_checked(_issue), do: :ok
  end

  @seed Path.expand("../../priv/qa_seed/symphony", __DIR__)
  @now ~U[2026-10-30 12:00:00Z]

  setup do
    # As on the QA server: the tracker reads a copy of the seed's issues, and the repository routes
    # the seed's team.
    issues_file = Path.join(Path.dirname(Workflow.symphony_file_path()), "issues.json")
    File.cp!(Path.join(@seed, "issues.json"), issues_file)
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_memory_issues_file: issues_file,
      tracker_team: "QA"
    )

    :ok = RunStore.clear()
    # The seed keeps QA-105's step outputs in the artifact store.
    on_exit(fn -> File.rm_rf(Paths.artifacts_dir()) end)
    repo_key = Config.repo_key!()
    on_exit(fn -> Application.delete_env(:symphony_elixir, :qa_seed_dir) end)
    %{repo_key: repo_key, dir: seed_copy(repo_key)}
  end

  # Symphony's own seed, for the test's configured repository.
  defp seed_copy(repo_key, change \\ & &1) do
    dir = Path.join(System.tmp_dir!(), "qa-seed-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.cp_r!(@seed, dir)
    seed = @seed |> Path.join("seed.json") |> File.read!() |> Jason.decode!() |> Map.put("repository", repo_key) |> change.()
    File.write!(Path.join(dir, "seed.json"), Jason.encode!(seed))
    dir
  end

  defp record(_repo_key, issue_id) do
    %{} = RunStore.get_ticket_state(issue_id)
  end

  test "the seeded server answers every move the Director makes, over the memory tracker", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.load(dir, now: @now) == :ok

    # Anthropic at its reserve, as the orchestrator keeps it. OpenCode Go holds nothing in the seed:
    # the live server reads its usage from the QA stub and holds it at its reserve (TP-1642).
    assert [{{"anthropic", :all}, %{phase: :headroom, reserve: 0.9, window: "five_hour", resets_at: anthropic_reset}}] =
             Map.to_list(RunStore.get_usage_limits())

    assert anthropic_reset == DateTime.add(@now, 110 * 60)

    # As in the application: the orchestrator starts after the seed, with its pauses, and the Inbox
    # reads the records the seed and each move write.
    {:ok, orchestrator} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SeededOrchestrator))
    on_exit(fn -> stop_process(orchestrator) end)
    inbox = [name: {:qa_seed_inbox, make_ref()}, github_repos: %{}]
    # The plan's move into Plan Review captures its brief, read from the issues file.
    assert {:ok, _brief} = PlanBrief.capture({repo_key, "qa-seed-109"})
    moves_server = :"qa_seed_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: moves_server})
    moves = [server: moves_server, github: SeedGitHub, workspace: SeedWorkspace, inbox: inbox]
    move = &control(&1, &2, orchestrator, moves)

    # Decide takes the held question's row away and answers the question; Undo brings both back.
    [%{id: question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})

    # The Conductor's questions are walked in their own test; this one reads around them.
    read_inbox = fn -> Enum.reject(rows(inbox), &(elem(&1, 0) in ["QA-112", "QA-113"])) end

    picks = [%{"question" => "How long a paused repository stays paused", "answer" => "Stay paused until resumed"}]
    assert %{"move" => "decide"} = move.(:decide, %{"issue_identifier" => "QA-108", "question_id" => question_id, "picks" => picks})
    refute Questions.deciding({:ticket, repo_key, "qa-seed-108"})
    assert [{"QA-102", :blocked, _hold}, {"QA-109", :plan, _plan}] = read_inbox.()
    assert %{"move" => "undo", "undone" => "decide"} = move.(:undo, %{"issue_identifier" => "QA-108"})
    assert [%{id: ^question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})
    assert [{"QA-102", :blocked, _hold}, {"QA-108", :action, %{question_id: ^question_id}}, {"QA-109", :plan, _plan}] = read_inbox.()

    # Unblock lifts the access pause in place, and its row goes.
    assert %{"move" => "unblock", "moved" => false} = move.(:unblock, %{"issue_identifier" => "QA-102"})
    refute Pauses.paused?({:ticket, repo_key, "qa-seed-102"})
    assert [{"QA-108", :action, _request}, {"QA-109", :plan, _plan}] = read_inbox.()

    # Rework, restart and backlog move the phased tickets in the tracker, and the next read sees them.
    assert %{"to_state" => "Rework"} = move.(:rework, %{"issue_identifier" => "QA-109", "reason" => "Split it differently"})
    assert {:ok, %{state: "Rework"}} = Tracker.fetch_issue_by_identifier("QA-109")
    assert %{"from_state" => "Rework", "to_state" => "In Progress"} = move.(:restart, %{"issue_identifier" => "QA-105", "reason" => "Start over"})
    assert {:ok, %{state: "In Progress"}} = Tracker.fetch_issue_by_identifier("QA-105")
    assert %{"to_state" => "Backlog"} = move.(:backlog, %{"issue_identifier" => "QA-101"})
    assert {:ok, %{state: "Backlog"}} = Tracker.fetch_issue_by_identifier("QA-101")

    # Resume and pause, Symphony-wide and for the repository; one pause holds at every step, so nothing starts.
    assert %{} = move.(:resume, %{})
    assert Pauses.get(:symphony) == {:ok, nil}
    assert %{} = move.(:pause, %{"reason" => "QA pauses it again"})
    assert {:ok, %{}} = Pauses.get(:symphony)
    assert %{"repository" => %{"repo_key" => ^repo_key, "paused" => false}} = move.(:resume_repository, %{"repo_key" => repo_key})
    refute Pauses.paused?({:repository, repo_key})
    assert %{"repository" => %{"paused" => true}} = move.(:pause_repository, %{"repo_key" => repo_key, "reason" => "QA pauses it again"})
    assert Pauses.paused?({:repository, repo_key})

    # Stop answers for a ticket with no run: the seeded server's agents never start one.
    assert %{"stopped" => false} = move.(:stop, %{"issue_identifier" => "QA-103"})
  end

  test "a Conductor question acts when picked: accepting without QA merges, going on lifts the held QA pass", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.load(dir, now: @now) == :ok
    {:ok, orchestrator} = Orchestrator.start_link(name: Module.concat(__MODULE__, :ConductorOrchestrator))
    on_exit(fn -> stop_process(orchestrator) end)
    inbox = [name: {:qa_seed_inbox, make_ref()}, github_repos: %{}]
    moves_server = :"qa_seed_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: moves_server})
    moves = [server: moves_server, github: SeedGitHub, workspace: SeedWorkspace, inbox: inbox]
    move = &control(&1, &2, orchestrator, moves)

    # QA-112: picking Accept without QA merges without QA, records the skip and takes the row away.
    [%{id: question_id} = question] = Questions.open({:ticket, repo_key, "qa-seed-112"})
    assert Enum.any?(rows(inbox), &match?({"QA-112", :action, %{question_id: ^question_id}}, &1))

    picks = [%{"question" => question.title, "answer" => "Accept without QA"}]
    assert %{"move" => "decide"} = move.(:decide, %{"issue_identifier" => "QA-112", "question_id" => question_id, "picks" => picks})
    assert {:ok, %{state: "Merging"}} = Tracker.fetch_issue_by_identifier("QA-112")
    assert [%{payload: %{outcome: "skip", details: %{reason: "skipped by decision"}}}] = TicketEvents.query("qa-seed-112", types: ["verdict.recorded"])
    refute Enum.any?(rows(inbox), &(elem(&1, 0) == "QA-112"))

    # QA-113: going on from a QA pass held on the Conductor's question closes it and lifts the pause.
    [%{id: held_id, title: title}] = Questions.open({:ticket, repo_key, "qa-seed-113"})
    assert %{id: ^held_id} = Questions.open_stage_question({:ticket, repo_key, "qa-seed-113"}, "QA")

    picks = [%{"question" => title, "answer" => "Go on as it is"}]
    assert %{"move" => "decide"} = move.(:decide, %{"issue_identifier" => "QA-113", "question_id" => held_id, "picks" => picks})
    assert {:ok, %{state: "QA"}} = Tracker.fetch_issue_by_identifier("QA-113")
    assert Questions.open({:ticket, repo_key, "qa-seed-113"}) == []
    refute Pauses.paused?({:ticket, repo_key, "qa-seed-113"})
  end

  test "TP-1560: a merged parent waits on its one sub-ticket, and closes once the Director cancels it", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.load(dir, now: @now) == :ok
    settings = Config.settings!()
    terminal_states = settings.tracker.terminal_states

    # A merged parent that is no plan, waiting on its one open sub-ticket: its status names that
    # sub-ticket and never the epic review.
    waiting = record(repo_key, "qa-seed-114")

    live = %{
      running: %{},
      retrying: %{},
      slot_waiting: %{},
      skipped: %{},
      limit: 4,
      symphony_pause: nil,
      max_tries: 3,
      terminal_states: terminal_states
    }

    status = Situation.compute(waiting, [], live)
    assert %{kind: "waiting_on_sub_tickets", waits_on: %{sub_tickets: ["QA-115"]}} = status
    refute status.cause =~ "epic review"

    # Linear's parent node counts a Done child as done and leaves a cancelled one out.
    assert {:ok, %{parent: %{done: 0, total: 1}}} = Tracker.fetch_issue_by_identifier("QA-115")
    :ok = Tracker.update_issue_state("qa-seed-115", "Done")
    assert {:ok, %{parent: %{done: 1, total: 1}}} = Tracker.fetch_issue_by_identifier("QA-115")
    :ok = Tracker.update_issue_state("qa-seed-115", "Todo")

    {:ok, orchestrator} = Orchestrator.start_link(name: Module.concat(__MODULE__, :ClosingOrchestrator))
    on_exit(fn -> stop_process(orchestrator) end)
    moves_server = :"qa_seed_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: moves_server})
    inbox = [name: {:qa_seed_inbox, make_ref()}, github_repos: %{}]
    moves = [server: moves_server, github: SeedGitHub, workspace: SeedWorkspace, inbox: inbox]

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    # The Director cancels the sub-ticket; the next poll moves QA-114 to Done, with no run, though
    # the seed keeps Symphony paused.
    assert %{"to_state" => "Canceled"} = control(:cancel, %{"issue_identifier" => "QA-115"}, orchestrator, moves)
    assert {:ok, %{parent: %{done: 0, total: 0}}} = Tracker.fetch_issue_by_identifier("QA-115")
    assert {:ok, parent} = Tracker.fetch_issue_by_identifier("QA-114")
    assert SubIssueWait.close?(parent, terminal_states, settings)

    send(orchestrator, :run_poll_cycle)
    assert_receive {:memory_tracker_state_update, "qa-seed-114", "Done"}, 5_000
    assert {:ok, %{state: "Done"}} = Tracker.fetch_issue_by_identifier("QA-114")
    refute RunStore.merged_wait?("qa-seed-114")
    assert RunStore.list_runs(repo_key, :all) |> Enum.filter(&(&1.issue_identifier == "QA-114")) == []
  end

  defp rows(inbox), do: %{} |> Inbox.items(inbox) |> Enum.map(&{&1.identifier, &1.kind, &1.review}) |> Enum.sort()

  # Posts a control API move and returns its 200 answer.
  defp control(action, params, orchestrator, moves) do
    conn =
      conn(:post, "/api/v1/control/#{action}", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
      |> assign(:director_moves, moves)
      |> assign(:orchestrator, orchestrator)
      |> Map.put(:params, params)
      |> Map.put(:body_params, params)
      |> then(&apply(ControlApiController, action, [&1, params]))

    assert {conn.status, action} == {200, action}, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  test "an event keeps the output, picture and step transcript its entry names, each as an artifact of its kind", %{repo_key: repo_key} do
    png = <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>
    lines = ~s({"kind":"say","text":"**Done.**"}\n{"kind":"tool","text":"Edit: lib/x.ex","tool":"Edit","file":"lib/x.ex"}\n)
    step = %{"issue" => "QA-104", "type" => "step.completed", "run_id" => "run-1", "actor" => "agent"}
    payload = %{"step_id" => "code", "title" => "Write the code", "mode" => "delegated", "outcome" => "passed"}

    events = [
      Map.merge(step, %{"payload" => payload, "transcript" => %{"file" => "own/code.ndjson", "label" => "Write the code transcript"}}),
      %{"issue" => "QA-104", "type" => "evidence", "payload" => %{"caption" => "After"}, "picture" => %{"file" => "own/shot.png", "label" => "After"}},
      %{"issue" => "QA-104", "type" => "note", "payload" => %{"text" => "x"}, "output" => %{"file" => "own/build.txt", "label" => "Build output"}}
    ]

    dir = seed_copy(repo_key, fn seed -> seed |> Map.take(["repository"]) |> Map.put("events", events) end)
    File.mkdir_p!(Path.join(dir, "own"))
    File.write!(Path.join(dir, "own/code.ndjson"), lines)
    File.write!(Path.join(dir, "own/shot.png"), png)
    File.write!(Path.join(dir, "own/build.txt"), "compiled\n")

    assert QaSeed.load(dir, now: @now) == :ok
    kept = for event <- RunStore.list_ticket_events("qa-seed-104", []), id <- event.artifacts, do: {event.type, Artifacts.get(id), id}

    assert [{"step.completed", {:ok, transcript}, transcript_id}, {"evidence", {:ok, shot}, _shot_id}, {"note", {:ok, output}, _output_id}] = kept
    assert %{kind: "transcript", label: "Write the code transcript"} = transcript
    assert {:ok, path} = Artifacts.path(transcript_id)
    assert File.read!(path) == lines
    assert %{kind: "screenshot", mime: "image/png", label: "After"} = shot
    assert %{kind: "step_output", label: "Build output"} = output
  end

  test "a step transcript's line times move so its last line falls at the time of the event that keeps it", %{repo_key: repo_key} do
    lines =
      ~s({"kind":"say","text":"Start","at":"2026-10-01T09:00:00Z"}\n) <>
        ~s({"kind":"tool","text":"Bash: ls","tool":"Bash"}\n) <>
        ~s({"kind":"say","text":"Done","at":"2026-10-01T09:05:30Z"}\n)

    step = %{"issue" => "QA-104", "type" => "step.completed", "run_id" => "run-1", "actor" => "agent", "minutes_ago" => 10}
    payload = %{"step_id" => "code", "title" => "Write the code", "mode" => "delegated", "outcome" => "passed"}
    events = [Map.merge(step, %{"payload" => payload, "transcript" => %{"file" => "own/code.ndjson", "label" => "Write the code transcript"}})]

    dir = seed_copy(repo_key, fn seed -> seed |> Map.take(["repository"]) |> Map.put("events", events) end)
    File.mkdir_p!(Path.join(dir, "own"))
    File.write!(Path.join(dir, "own/code.ndjson"), lines)

    assert QaSeed.load(dir, now: @now) == :ok
    assert [%{artifacts: [id]}] = RunStore.list_ticket_events("qa-seed-104", [])
    assert {:ok, path} = Artifacts.path(id)

    assert [first, untimed, last, ""] = path |> File.read!() |> String.split("\n")
    assert %{"text" => "Start", "at" => "2026-10-30T11:44:30Z"} = Jason.decode!(first)
    assert untimed == ~s({"kind":"tool","text":"Bash: ls","tool":"Bash"})
    assert %{"text" => "Done", "at" => "2026-10-30T11:50:00Z"} = Jason.decode!(last)
  end

  test "a seed with only its repository loads, and the ages count from now", %{repo_key: repo_key} do
    dir = seed_copy(repo_key, fn seed -> Map.take(seed, ["repository"]) end)
    File.write!(Path.join(dir, "seed.json"), Jason.encode!(%{"repository" => repo_key, "runs" => [%{"issue" => "QA-110"}], "pauses" => %{}}))

    # The tracker's file may list its projects and teams beside the issues.
    issues = dir |> Path.join("issues.json") |> File.read!() |> Jason.decode!()
    File.write!(Path.join(dir, "issues.json"), Jason.encode!([%{"kind" => "project", "id" => "p1", "name" => "QA"} | issues]))

    assert QaSeed.load(dir) == :ok
    assert Pauses.get(:symphony) == {:ok, nil}

    assert [%{issue_identifier: "QA-110", transcript_path: nil, pull_request_url: nil, runtime_seconds: 0}] =
             RunStore.list_runs(repo_key, :all)
  end

  test "a usage-limit hold without a reserve is the limit the provider's own message reported", %{repo_key: repo_key} do
    limit = %{"provider" => "opencode-go", "window" => "seven_day", "resets_in_minutes" => 911, "issue" => "QA-101"}
    dir = seed_copy(repo_key, &Map.put(&1, "usage_limits", [limit]))

    assert QaSeed.load(dir, now: @now) == :ok

    assert %{{"opencode-go", :all} => %{phase: :paused, reason: reason, window: "seven_day", resets_at: resets_at} = hold} =
             RunStore.get_usage_limits()

    assert resets_at == DateTime.add(@now, 911 * 60)
    refute reason =~ "claude"
    assert UsageLimit.banner(hold, @now) =~ "OpenCode Go"
  end

  test "a seed that does not load names why", %{repo_key: repo_key} do
    missing = Path.join(System.tmp_dir!(), "qa-seed-missing-#{System.unique_integer([:positive])}")
    assert {:error, {path, :enoent}} = QaSeed.load(missing)
    assert path == Path.join(missing, "seed.json")

    assert {:error, :no_repository} = QaSeed.load(seed_copy(repo_key, &Map.delete(&1, "repository")))
    no_url = &Map.put(&1, "pull_requests", [%{"issue" => "QA-103", "number" => nil}])
    assert {:error, {{:pull_request, "QA-103"}, _reason}} = QaSeed.load(seed_copy(repo_key, no_url))

    unknown_ci = &Map.put(&1, "pull_requests", [%{"issue" => "QA-103", "number" => 7, "ci" => "amber"}])
    assert {:error, {{:pull_request, "QA-103"}, {:unknown_ci, "amber"}}} = QaSeed.load(seed_copy(repo_key, unknown_ci))

    assert {:error, {:issue, "QA-999", :issue_not_found}} = QaSeed.load(seed_copy(repo_key, &Map.put(&1, "runs", [%{"issue" => "QA-999"}])))

    no_output = &Map.put(&1, "events", [%{"issue" => "QA-105", "type" => "note", "payload" => %{"text" => "x"}, "output" => %{"file" => "outputs/none.txt"}}])
    assert {:error, {{:output, "QA-105", "outputs/none.txt"}, _reason}} = QaSeed.load(seed_copy(repo_key, no_output))

    # A picture that isn't an image is refused as a screenshot.
    not_a_picture = &Map.put(&1, "events", [%{"issue" => "QA-104", "type" => "note", "payload" => %{"text" => "x"}, "picture" => %{"file" => "outputs/QA-105-build.txt"}}])
    assert {:error, {{:output, "QA-104", "outputs/QA-105-build.txt"}, :unsupported_mime}} = QaSeed.load(seed_copy(repo_key, not_a_picture))

    bad_event = &Map.put(&1, "events", [%{"issue" => "QA-105", "type" => "step.completed", "payload" => %{}}])
    assert {:error, {{:event, "QA-105", "step.completed"}, {:invalid_payload, _fields}}} = QaSeed.load(seed_copy(repo_key, bad_event))
    assert {:error, {:issue, "QA-999", :issue_not_found}} = QaSeed.load(seed_copy(repo_key, &Map.put(&1, "events", [%{"issue" => "QA-999", "type" => "note"}])))

    no_action = fn seed ->
      [conductor | _] = Enum.filter(seed["questions"], &(&1["issue"] == "QA-112"))
      Map.put(seed, "questions", [%{conductor | "issue" => "QA-103"}])
    end

    # Accepting without QA from Code Review is no action Symphony could take there.
    assert {:error, {:question, "QA-103", {:conductor_options, "option \"Accept without QA\" accepts the change without QA" <> _}}} =
             QaSeed.load(seed_copy(repo_key, no_action))

    bad_question = &Map.put(&1, "questions", [%{"issue" => "QA-108", "title" => "Too short"}])
    assert {:error, {:question, "QA-108", {:invalid_decision_request, _message}}} = QaSeed.load(seed_copy(repo_key, bad_question))

    assert {:error, {:pause, {:repository, " "}, {:invalid_subject, {:repository, " "}}}} =
             QaSeed.load(seed_copy(repo_key, &Map.merge(&1, %{"repository" => " ", "pauses" => %{"repository" => "x"}})))

    assert {:error, {{:observe, "QA-101"}, :invalid_repo_key}} = QaSeed.load(seed_copy(repo_key, &Map.merge(&1, %{"repository" => " ", "pauses" => %{}})))

    long_hold = &Map.put(&1, "holds", [%{"issue" => "QA-102", "reason" => String.duplicate("x", 400), "clearing_condition" => "never"}])
    assert {:error, {{:hold, "QA-102"}, _reason}} = QaSeed.load(seed_copy(repo_key, long_hold))
  end

  test "as the application's child it loads the seed and starts nothing, or stops the start", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.configured_dir() == nil
    Application.put_env(:symphony_elixir, :qa_seed_dir, dir)
    assert QaSeed.configured_dir() == dir

    assert QaSeed.start_link(dir: dir) == :ignore
    assert {:ok, %{}} = Pauses.get({:repository, repo_key})

    Process.flag(:trap_exit, true)
    assert {:error, {:qa_seed_failed, {_path, :enoent}}} = QaSeed.start_link(dir: Path.join(dir, "missing"))
  end
end
