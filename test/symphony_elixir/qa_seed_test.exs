defmodule SymphonyElixir.QaSeedTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{Config, DirectorMoves, Hold, Orchestrator, Pauses, QaSeed, Questions}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{RunStore, TicketPullRequest, Workflow}
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
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok = RunStore.clear()
    repo_key = Config.repo_key!()

    issues =
      for entry <- @seed |> Path.join("issues.json") |> File.read!() |> Jason.decode!() do
        # The QA server routes the seed's team to its one repository; here the issues carry its key.
        %Issue{
          id: entry["id"],
          identifier: entry["identifier"],
          state: entry["state"],
          title: entry["title"],
          labels: entry["labels"],
          repo_key: repo_key
        }
      end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
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
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    assert QaSeed.load(dir, now: @now) == :ok

    # As in the application: the orchestrator starts after the seed, with its pauses.
    {:ok, orchestrator} = Orchestrator.start_link(name: Module.concat(__MODULE__, :SeededOrchestrator))
    on_exit(fn -> stop_process(orchestrator) end)
    moves_server = :"qa_seed_moves_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: moves_server})
    moves = [server: moves_server, github: SeedGitHub, workspace: SeedWorkspace]
    move = &control(&1, &2, orchestrator, moves)

    # Decide answers the seeded question and lifts its hold; Undo brings both back.
    [%{id: question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})
    picks = [%{"question" => "How long a paused repository stays paused", "answer" => "Stay paused until resumed"}]
    assert %{"move" => "decide"} = move.(:decide, %{"issue_identifier" => "QA-108", "question_id" => question_id, "picks" => picks})
    refute Hold.held?(repo_key, "qa-seed-108", :needs_decision)
    assert %{"move" => "undo", "undone" => "decide"} = move.(:undo, %{"issue_identifier" => "QA-108"})
    assert [%{id: ^question_id}] = Questions.open({:ticket, repo_key, "qa-seed-108"})

    # Unblock lifts the access hold in place.
    assert %{"move" => "unblock", "moved" => false} = move.(:unblock, %{"issue_identifier" => "QA-102"})
    refute Hold.held?(repo_key, "qa-seed-102", :blocked)

    # Rework, restart and backlog move the phased tickets in the tracker.
    assert %{"to_state" => "Rework"} = move.(:rework, %{"issue_identifier" => "QA-109", "reason" => "Split it differently"})
    assert_received {:memory_tracker_state_update, "qa-seed-109", "Rework"}
    assert %{"from_state" => "Rework", "to_state" => "In Progress"} = move.(:restart, %{"issue_identifier" => "QA-105", "reason" => "Start over"})
    assert_received {:memory_tracker_state_update, "qa-seed-105", "In Progress"}
    assert %{"to_state" => "Backlog"} = move.(:backlog, %{"issue_identifier" => "QA-101"})
    assert_received {:memory_tracker_state_update, "qa-seed-101", "Backlog"}

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
