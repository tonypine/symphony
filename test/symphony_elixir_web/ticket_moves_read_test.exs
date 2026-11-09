defmodule SymphonyElixirWeb.TicketMovesReadTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.{DirectorMoves, Pauses, Questions, SubIssueWait, TicketMoves, TransitionGuard}
  alias SymphonyElixir.PrDecision.Facts
  alias SymphonyElixirWeb.{ControlApiController, Presenter}

  @repo "default"
  @id "ticket"
  @identifier "MOT-1"

  # What goes through the control API here; `start`, `stop`, `force` and `unforce` need a running
  # orchestrator, and their words are proved in `start_issue_test.exs` and `force_issue_test.exs`.
  @called_moves [
    :answer,
    :restart,
    :cancel,
    :move_to,
    :unblock,
    :note,
    :blocker,
    :priority,
    :labels,
    :ruling,
    :approve_plan,
    :rework,
    :decisions,
    :changes,
    :backlog
  ]

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defmodule NoPullRequests do
    def fetch_activity(_pr_url, _opts), do: {:ok, %{state: "OPEN"}}
    def close(_pr_url, _opts), do: :ok
  end

  defmodule FakeWorkspace do
    def remove_issue_workspaces_checked(_issue), do: :ok
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    SubIssueWait.reset_for_test("Waiting on sub-tickets")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)

    server = :"ticket_moves_read_#{System.unique_integer([:positive])}"
    start_supervised!({DirectorMoves, name: server})
    %{moves: [server: server, github: NoPullRequests, workspace: FakeWorkspace]}
  end

  defp orchestrator(snapshot \\ %{}) do
    snapshot = Map.merge(%{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: [], watching: []}, snapshot)

    start_supervised!(%{id: make_ref(), start: {SnapshotOrchestrator, :start_link, [snapshot]}})
  end

  defp running_entry do
    %{
      issue_id: @id,
      identifier: @identifier,
      repo_key: @repo,
      state: "In Progress",
      session_id: "session-1",
      started_at: ~U[2026-11-06 10:00:00Z],
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }
  end

  defp ticket!(phase, labels) do
    RunStore.delete_ticket_state(@id)
    record = %{repo_key: @repo, issue_id: @id, issue_identifier: @identifier, phase: phase, labels: labels}
    :ok = RunStore.put_ticket_state(record)
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: "other", issue_identifier: "MOT-9", phase: "Todo"})
    issue = %Issue{id: @id, identifier: @identifier, title: "A ticket", state: phase, labels: labels, repo_key: @repo}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
  end

  defp watched!(issue_id, identifier) do
    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: issue_id, issue_identifier: identifier, phase: "Code Review"})
    facts = %Facts{phase: :code_review, ci: :pending, pr: :open, pr_number: 741}
    :ok = RunStore.put_ticket_pr_watch(@repo, issue_id, identifier, %{facts: facts, head_sha: "abc1234"})
  end

  defp post(action, params, moves) do
    conn(:post, "/api/v1/control/#{action}", Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> Phoenix.Controller.put_view(SymphonyElixirWeb.ErrorJSON)
    |> assign(:director_moves, moves)
    |> assign(:orchestrator, :no_orchestrator_in_this_test)
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> then(&apply(ControlApiController, action, [&1, params]))
  end

  # The control call of each move the read judges, with an argument the call takes.
  defp calls(read, question_id) do
    [
      {:answer, :decide, %{"question_id" => question_id, "request_comment_id" => "comment-1", "picks" => [%{"question" => "Add it?", "answer" => "Add it"}]}},
      {:restart, :restart, %{"reason" => "Start over"}},
      {:cancel, :cancel, %{}},
      {:move_to, :move, %{"to" => List.first(read.move_to.states) || "Todo"}},
      {:unblock, :unblock, %{}},
      {:note, :note, %{"repo_key" => @repo, "text" => "For the next run"}},
      {:blocker, :blocker, %{"blocker" => "MOT-9", "action" => "add"}},
      {:priority, :priority, %{"priority" => "low"}},
      {:labels, :label, %{"label" => "qa:skip", "action" => "add"}},
      {:ruling, :decision, %{"text" => "Keep it small"}},
      {:approve_plan, :approve_plan, %{}},
      {:rework, :rework, %{"reason" => "Split it"}},
      {:decisions, :decisions, %{"picks" => [%{"question" => "Where?", "answer" => "B"}]}},
      {:changes, :changes, %{"reason" => "Ask it plainly"}},
      {:backlog, :backlog, %{}}
    ]
  end

  defp request_question do
    %{
      title: "Add it",
      question: "Add it?",
      why: "Only you can decide.",
      if_unanswered: "It waits.",
      recommendation_reason: "It is safe.",
      options: [%{label: "Add it", effect: "It is added.", recommended: true}, %{label: "Leave it", effect: "Nothing changes."}]
    }
  end

  # Each fixture sets up the ticket fresh, then answers the question id a Decide names.
  defp fixtures do
    phases = ["Backlog", "Todo", "In Progress", "Plan Review", "Waiting on sub-tickets", "Rework", "Code Review", "Done", "Canceled"]
    ticket = {:ticket, @repo, @id}

    plain =
      for phase <- phases, labels <- [[], ["plan"]] do
        {"#{phase} #{inspect(labels)}",
         fn ->
           ticket!(phase, labels)
           nil
         end}
      end

    held = fn attrs ->
      fn ->
        ticket!("In Progress", [])
        {:ok, question} = Questions.ask(ticket, attrs)
        question.id
      end
    end

    plain ++
      [
        {"on a block report", held.(TransitionGuard.block_report_question(@identifier))},
        {"on a decision", held.(request_question())},
        {"stopped",
         fn ->
           ticket!("In Progress", [])
           :ok = Pauses.stop(ticket, DateTime.utc_now())
           nil
         end}
      ]
  end

  defp read_moves, do: Presenter.issue_payload(@identifier, orchestrator(), 1_000) |> elem(1) |> Map.fetch!(:moves)

  describe "the ticket read" do
    test "a ticket with a run working can't be started and can be stopped" do
      ticket!("In Progress", [])

      assert {:ok, payload} = Presenter.issue_payload(@identifier, orchestrator(%{running: [running_entry()]}), 1_000)

      assert payload.moves.start == %{allowed: false, reason: "A run is already working on it."}
      assert payload.moves.stop == %{allowed: true, reason: nil}
      assert payload.start == payload.moves.start
    end

    test "a ticket no run works on can be started and has nothing to stop" do
      ticket!("In Progress", [])

      assert {:ok, %{moves: moves, start: start}} = Presenter.issue_payload(@identifier, orchestrator(), 1_000)

      assert moves.stop == %{allowed: false, reason: "No run is working."}
      assert moves.start == %{allowed: true, reason: nil}
      assert start == moves.start
    end

    test "a done ticket says so on each move a closed ticket can't make" do
      ticket!("Done", [])

      moves = read_moves()

      for move <- [:start, :restart, :cancel, :force, :backlog] do
        assert moves[move] == %{allowed: false, reason: "The ticket is done."}
      end
    end

    test "a ticket held on a Question waits on the answer" do
      ticket!("In Progress", [])
      {:ok, _question} = Questions.ask({:ticket, @repo, @id}, request_question())

      moves = read_moves()

      assert moves.start == %{allowed: false, reason: "It waits on your answer first."}
      assert moves.answer == %{allowed: true, reason: nil}
    end
  end

  describe "the state's tickets" do
    test "each carries its moves: a watched one, and a running one no record holds" do
      watched!("watched", "MOT-2")
      watched!("busy", "MOT-3")

      snapshot = %{running: [%{running_entry() | issue_id: "busy", identifier: "MOT-3"}]}
      payload = Presenter.state_payload(orchestrator(snapshot), 1_000)

      assert %{moves: %{stop: %{allowed: false}, restart: %{allowed: true}}} = Enum.find(payload.issues, &(&1.identifier == "MOT-2"))
      assert %{moves: %{stop: %{allowed: true}, start: %{allowed: false, reason: "A run is already working on it."}}} = Enum.find(payload.issues, &(&1.identifier == "MOT-3"))
      assert [%{moves: moves, start: start}] = payload.running
      assert moves.stop.allowed
      assert start == moves.start
    end
  end

  describe "the read and the call" do
    # The read's verdict, then the call on the same ticket: a move the read allows is not refused,
    # and a move it refuses is refused with the read's reason, word for word.
    test "a move the read allows is not refused, and a refusal is the read's reason, on every fixture", %{moves: moves} do
      for {name, set_up} <- fixtures(), move <- @called_moves do
        question_id = set_up.()
        read = read_moves()
        {^move, action, params} = List.keyfind(calls(read, question_id), move, 0)

        conn = post(action, Map.put(params, "issue_identifier", @identifier), moves)

        assert_agrees(name, move, read[move], conn)
      end
    end

    test "a ticket Symphony holds no record of is refused with the read's reason", %{moves: moves} do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      read = TicketMoves.read(TicketMoves.facts(nil, %{identifier: "ZZZ-1", repo_key: @repo, symphony_pause: nil, repository_pause: nil, running?: false}))

      for {move, action, params} <- [
            {:note, :note, %{"repo_key" => @repo, "text" => "For the next run"}},
            {:priority, :priority, %{"priority" => "low"}},
            {:labels, :label, %{"label" => "qa:skip", "action" => "add"}},
            {:ruling, :decision, %{"text" => "Keep it small"}},
            {:blocker, :blocker, %{"blocker" => "ZZZ-2", "action" => "add"}}
          ] do
        conn = post(action, Map.put(params, "issue_identifier", "ZZZ-1"), moves)

        assert %{"error" => %{"message" => message}} = Jason.decode!(conn.resp_body)
        assert message == read[move].reason, "#{move}: the call said #{message}"
      end
    end
  end

  # A 409 is the only refusal for the ticket's state; a write the tracker can't make is another answer.
  defp assert_agrees(name, move, %{allowed: true}, conn) do
    refute conn.status == 409, "#{name}: the read allows #{move}, the call refused it: #{conn.resp_body}"
  end

  defp assert_agrees(name, move, %{allowed: false, reason: reason}, conn) do
    assert %{"error" => %{"message" => message}} = Jason.decode!(conn.resp_body), "#{name}: the read refuses #{move} (#{reason}), the call answered #{conn.status}"
    assert message == reason, "#{name}: #{move}: the read says #{reason}, the call says #{message}"
  end
end
