defmodule SymphonyElixir.QaSeedTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{Config, DirectorMoves, Hold, Inbox, Orchestrator, Pauses, QaSeed, Questions}
  alias SymphonyElixir.{RunStore, TicketPullRequest, Tracker, Workflow}
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

  defp record(repo_key, issue_id) do
    %{} = RunStore.get_ticket_state(repo_key, issue_id)
  end

  test "loads Symphony's own seed: phases, pauses, an access hold, an open question, runs and PRs", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.load(dir, now: @now) == :ok

    # Every tracker issue's state is its record's phase.
    assert %{phase: "Code Review"} = record(repo_key, "qa-seed-103")
    assert %{phase: "Plan Review"} = record(repo_key, "qa-seed-109")

    assert {:ok, %{reasons: [%{kind: :person, text: "Paused for the QA seed: resume to let tickets start again"}]}} = Pauses.get(:symphony)
    assert {:ok, %{reasons: [%{kind: :person, text: "Paused while the release notes are written"}]}} = Pauses.get({:repository, repo_key})

    # Unblock lifts the access hold; Decide answers the open question.
    assert [%{kind: :blocked} = blocked] = record(repo_key, "qa-seed-102").holds
    assert Hold.unblockable?(blocked)
    held = record(repo_key, "qa-seed-108")
    assert [%{kind: :needs_decision, decision: %{question_id: question_id}}] = held.holds
    assert [%{id: ^question_id, title: "How long a paused repository stays paused"}] = Enum.filter(held.questions, &(&1.state == :open))

    runs = RunStore.list_runs(repo_key, :all)
    assert Enum.map(runs, & &1.issue_identifier) |> Enum.sort() == ["QA-103", "QA-105", "QA-107"]
    run = Enum.find(runs, &(&1.issue_identifier == "QA-107"))
    assert %{status: "success", runtime_seconds: 980, ended_at: ended_at, pull_request_url: "https://github.com/symphony-qa/seed/pull/452"} = run
    assert DateTime.compare(ended_at, DateTime.add(@now, -20 * 60, :second)) == :eq
    assert File.regular?(run.transcript_path) and Path.dirname(run.transcript_path) == Path.join(dir, "transcripts")

    assert %{pr_url: "https://github.com/symphony-qa/seed/pull/450", state: "open"} = TicketPullRequest.get(repo_key, "qa-seed-105")
    assert %{facts: %{ci: :red, failing_check: "make-all", phase: :rework, pr_number: 450}} = record(repo_key, "qa-seed-105").pr_watch
    assert %{facts: %{ci: :pending, phase: :qa}} = record(repo_key, "qa-seed-104").pr_watch
    assert %{facts: %{ci: :green, phase: :merging}} = record(repo_key, "qa-seed-107").pr_watch
  end

  test "the seeded server answers every move the Director makes, over the memory tracker", %{repo_key: repo_key, dir: dir} do
    assert QaSeed.load(dir, now: @now) == :ok

    # As in the application: the orchestrator starts after the seed, with its pauses, and the Inbox
    # reads the tracker's issues file.
    {:ok, orchestrator} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SeededOrchestrator))
    on_exit(fn -> stop_process(orchestrator) end)
    inbox = {:qa_seed_inbox, make_ref()}
    inbox_state = %{opts: [name: inbox, source: :memory, snapshot: fn -> %{} end], nodes: %{}, timer: make_ref()}
    read_inbox = fn -> inbox_state |> Inbox.run_once() |> then(fn _state -> rows(inbox) end) end
    moves_server = :"qa_seed_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: moves_server})
    moves = [server: moves_server, github: SeedGitHub, workspace: SeedWorkspace, inbox: inbox]
    move = &control(&1, &2, orchestrator, moves)

    # The held question is a row in the Inbox, beside the access hold and the plan in review. Decide
    # takes the row away and lifts the hold; Undo brings both back.
    [%{id: question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})

    assert [
             {"QA-102", :blocked, %{reason: "The agent can't reach the package registry: it needs a token only you can add."}},
             {"QA-108", :action, %{question_id: ^question_id, comment_id: "memory-comment-" <> _id}},
             {"QA-109", :plan, _plan}
           ] = read_inbox.()

    picks = [%{"question" => "How long a paused repository stays paused", "answer" => "Stay paused until resumed"}]
    assert %{"move" => "decide"} = move.(:decide, %{"issue_identifier" => "QA-108", "question_id" => question_id, "picks" => picks})
    refute Hold.held?(repo_key, "qa-seed-108", :needs_decision)
    assert [{"QA-102", :blocked, _hold}, {"QA-109", :plan, _plan}] = rows(inbox)
    assert [{"QA-102", :blocked, _hold}, {"QA-109", :plan, _plan}] = read_inbox.()
    assert %{"move" => "undo", "undone" => "decide"} = move.(:undo, %{"issue_identifier" => "QA-108"})
    assert [%{id: ^question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})
    assert [{"QA-102", :blocked, _hold}, {"QA-108", :action, %{question_id: ^question_id}}, {"QA-109", :plan, _plan}] = read_inbox.()

    # Unblock lifts the access hold in place, and its row goes.
    assert %{"move" => "unblock", "moved" => false} = move.(:unblock, %{"issue_identifier" => "QA-102"})
    refute Hold.held?(repo_key, "qa-seed-102", :blocked)
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

    bad_question = &Map.put(&1, "questions", [%{"issue" => "QA-108", "title" => "Too short"}])
    assert {:error, {:question, "QA-108", {:invalid_decision_request, _message}}} = QaSeed.load(seed_copy(repo_key, bad_question))

    assert {:error, {:pause, {:repository, " "}, {:invalid_subject, {:repository, " "}}}} =
             QaSeed.load(seed_copy(repo_key, &Map.merge(&1, %{"repository" => " ", "pauses" => %{"repository" => "x"}})))
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
