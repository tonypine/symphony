defmodule SymphonyElixir.AgentRunnerTicketSummaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Hold, Questions, TicketEvents, TicketState}

  @note String.duplicate("The export kept timing out on the large workspace. ", 10)

  defmodule SummaryAgent do
    # Coding-agent stand-in: reports that it started and the prompt it got.
    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(_session, prompt, _issue, _turn_opts) do
      send(Application.fetch_env!(:symphony_elixir, :summary_agent_recipient), {:turn, prompt})
      {:ok, %{session_id: "sess"}}
    end

    def stop_session(_session), do: :ok
  end

  setup do
    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, :summary_agent_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-summary-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    workflow!(test_root, "prompt_brief_max_tokens: 10")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :summary_agent_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
      File.rm_rf(test_root)
    end)

    repo_key = Config.repo_key!()
    issue = %Issue{id: "issue-sum", identifier: "TP-77", title: "Export the report", state: "In Progress"}
    {:ok, _note} = TicketEvents.record(repo_key, issue.id, "note", %{text: @note}, actor: {:person, "Sam"})

    %{test_root: test_root, repo_key: repo_key, issue: issue}
  end

  test "a summary over the limit starts no agent and asks once; after Go on, every run gets the whole summary", ctx do
    assert :ok = run(ctx)
    refute_received {:turn, _prompt}
    assert [body] = requests()
    assert body =~ "TP-77's ticket summary is over its size limit"
    assert body =~ "Go on with the whole summary"
    assert_received {:memory_tracker_label_added, "issue-sum", "Needs Decision"}
    assert %{decision: %{title: "TP-77's ticket summary is over its size limit"}} = Hold.get(ctx.repo_key, ctx.issue.id, :needs_decision)

    assert :ok = run(ctx)
    refute_received {:turn, _prompt}
    assert requests() == []

    answer!(ctx, "Go on with the whole summary")
    {:ok, _more} = TicketEvents.record(ctx.repo_key, ctx.issue.id, "note", %{text: String.duplicate("More detail. ", 200)})

    assert :ok = run(ctx)
    assert_received {:turn, prompt}
    assert prompt =~ "Ticket history (every decision, open finding and note in full;"
    assert prompt =~ String.trim(@note)
    assert prompt =~ String.trim(String.duplicate("More detail. ", 200))
    refute prompt =~ "truncated by Symphony"
    assert requests() == []
  end

  test "after Cancel the ticket, the next run moves it to Canceled without starting an agent", ctx do
    assert :ok = run(ctx)
    answer!(ctx, "Cancel the ticket")

    assert :ok = run(ctx)
    assert_received {:memory_tracker_state_update, "issue-sum", "Canceled"}
    refute_received {:turn, _prompt}
  end

  test "a team that spells it Cancelled gets that state", ctx do
    assert :ok = run(ctx)
    answer!(ctx, "2")
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_not_found}, :ok])

    log = capture_log(fn -> assert :ok = run(ctx) end)
    assert_received {:memory_tracker_state_update, "issue-sum", "Cancelled"}
    assert %{phase: "Cancelled"} = RunStore.get_ticket_state(ctx.repo_key, ctx.issue.id)
    refute log =~ "Linear refused the move"
  end

  test "a cancel the tracker refuses fails the run", ctx do
    assert :ok = run(ctx)
    answer!(ctx, "Cancel the ticket")
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :boom})

    assert_raise RuntimeError, ~r/ticket_summary_cancel_failed, :boom/, fn -> run(ctx) end
  end

  test "a request that can't be posted fails the run and leaves the question open for the Inbox to post", ctx do
    # The workpad's comment goes through; the request's doesn't.
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [:ok, {:error, :linear_down}])

    assert_raise RuntimeError, ~r/ticket_summary_request_failed/, fn -> run(ctx) end
    refute_received {:turn, _prompt}
    assert [%{id: id, title: "TP-77's ticket summary is over its size limit"}] = Questions.open({:ticket, ctx.repo_key, ctx.issue.id})
    assert %{decision: %{question_id: ^id}} = Hold.get(ctx.repo_key, ctx.issue.id, :needs_decision)
    assert [%{type: :question_comment, question: ^id}] = TicketState.normalize(RunStore.get_ticket_state(ctx.repo_key, ctx.issue.id)).pending_projection
  end

  test "with the summary off the limit is never checked", ctx do
    workflow!(ctx.test_root, "prompt_brief_max_tokens: 10\n  prompt_brief_enabled: false")

    assert :ok = run(ctx)
    assert_received {:turn, prompt}
    refute prompt =~ "Ticket history"
    assert requests() == []
  end

  # The decision requests the runs posted (each run also posts its workpad).
  defp requests do
    receive do
      {:memory_tracker_comment, _id, body} -> if(body =~ "## Decision needed", do: [body], else: []) ++ requests()
    after
      0 -> []
    end
  end

  # The Director's answer as the ledger records it: the open Question answered, as the hold it
  # projects clears.
  defp answer!(ctx, answer) do
    [_question] = Questions.open({:ticket, ctx.repo_key, ctx.issue.id})
    :ok = Hold.clear(ctx.repo_key, ctx.issue.id, :needs_decision, answered: true, question: {:answer, answer, %{kind: :person, name: "Sam"}})
  end

  defp workflow!(test_root, ledger) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      workspace_root: test_root,
      agent_kind: "claude",
      max_turns: 1
    )

    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> "ledger:\n  " <> ledger <> "\n")
    Cache.clear()
  end

  defp run(ctx) do
    workspace = Path.join(ctx.test_root, ctx.issue.identifier)
    File.mkdir_p!(workspace)

    AgentRunner.run(ctx.issue, nil,
      workspace_path: workspace,
      agent_module: SummaryAgent,
      run_id: "run-#{System.unique_integer([:positive])}",
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [%{ctx.issue | state: "Done"}]} end,
      leftover_processes: [table: fn -> {:ok, []} end]
    )
  end
end
