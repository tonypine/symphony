defmodule SymphonyElixir.GroomingEndToEndTest do
  # A new ticket from its dispatch to its first coding run: the orchestrator's own dispatch pass
  # starts the run's task, the Conductor's Grooming turn runs in it before the agent, and the run
  # that follows works from the plan. Nothing of Symphony is replaced: the only stand-in is the
  # `claude` command, a script that answers Grooming with a canned plan and any other turn with
  # "Done.", and that keeps each prompt it was given.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.Facts
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.{SubIssueWait, TicketChecks, TicketPlan, TicketState}

  @repo "default"
  @waiting "Waiting on sub-tickets"
  @description "The ticket list forgets my filter when I reload. Keep it.\n\n## Acceptance criteria\n\n- The description's own criterion.\n"

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "symphony-grooming-e2e-#{n}")
    prompts = Path.join(root, "prompts")
    File.mkdir_p!(prompts)
    claude = Path.join(root, "fake-claude")

    # The prompt comes on stdin. Grooming's opens with its own words, so the script tells it apart.
    File.write!(claude, """
    #!/bin/sh
    prompt="#{prompts}/$(date +%s)-$$.txt"
    cat > "$prompt"
    if grep -q "this turn is Grooming" "$prompt"; then pwd > "#{root}/grooming.cwd"; fi
    if grep -q "this turn is Grooming" "$prompt"; then cat "#{root}/grooming.jsonl"; else cat "#{root}/run.jsonl"; fi
    exit 0
    """)

    File.chmod!(claude, 0o755)
    File.write!(Path.join(root, "run.jsonl"), stream("sess-run", "Done."))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Code Review", "Rework", @waiting],
      tracker_terminal_states: ["Done", "Canceled"],
      workspace_root: Path.join(root, "workspaces"),
      agent_kind: "claude",
      agent_command: claude,
      max_turns: 1,
      quality_gate: %{enabled: false},
      prompt: "Issue {{ issue.identifier }}\n{{ issue.description }}"
    )

    append_symphony_yml!("conductor:\n  enabled: true\n")
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-e2e-#{n}"
    identifier = "E2E-#{n}"

    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Keep the list's filter",
      description: @description,
      state: "Todo",
      repo_key: @repo,
      labels: [],
      team: %{key: "MT"},
      assignee_id: "user-1",
      url: "https://example.org/issues/#{identifier}"
    }

    :ok = RunStore.put_ticket_state(%{repo_key: @repo, issue_id: issue_id, issue_identifier: identifier, phase: "Todo", title: issue.title, description: @description})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      File.rm_rf(root)
    end)

    %{root: root, prompts: prompts, issue: issue, issue_id: issue_id}
  end

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  # What the `claude` command prints for one turn that ends with `text`.
  defp stream(session, text) do
    init = %{
      type: "system",
      subtype: "init",
      session_id: session,
      cwd: "/tmp",
      tools: [],
      mcp_servers: [%{name: "symphony", status: "connected"}],
      model: "claude-opus-5-5",
      permissionMode: "default",
      apiKeySource: "env"
    }

    usage = %{input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0}
    said = %{type: "assistant", message: %{content: [%{type: "text", text: text}]}, session_id: session}
    timing = %{duration_ms: 5, duration_api_ms: 4, num_turns: 1, total_cost_usd: 0.0, usage: usage}
    result = Map.merge(timing, %{type: "result", subtype: "success", is_error: false, result: text, session_id: session})
    Enum.map_join([init, said, result], &(Jason.encode!(&1) <> "\n"))
  end

  defp grooming_answers!(root, plan) do
    answer = Jason.encode!(%{"plan" => plan, "update" => "I read this as one small change.\n\nNext: one coding run."})
    File.write!(Path.join(root, "grooming.jsonl"), stream("sess-grooming", answer))
  end

  defp plan(attrs \\ %{}) do
    Map.merge(
      %{
        "shape" => "single",
        "layers" => ["screen"],
        "summary" => "The ticket list remembers its filter.",
        "text" => "Approach: store the filter with the view state.",
        "checks" => [
          %{"kind" => "outcome", "statement" => "The filter is applied after a reload.", "proof" => "test"},
          %{"kind" => "qa", "statement" => "The list is still filtered.", "proof" => "qa", "state" => "2 states", "action" => "Reload", "expect" => "Filtered"}
        ],
        "size" => %{"tokens" => 3_000_000, "runs" => 3}
      },
      attrs
    )
  end

  defp orchestrator_state do
    %Orchestrator.State{
      repo_key: @repo,
      max_concurrent_agents: 2,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  # The dispatch pass, then the end of the task it started for the ticket: how that task exited.
  defp dispatch_and_wait(issue) do
    [issue] |> Orchestrator.dispatch_chosen_issues_for_test(orchestrator_state()) |> wait(issue)
  end

  defp wait(state, issue) do
    assert %{pid: pid, run_id: run_id} = state.running[issue.id]
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
    {run_id, reason}
  end

  defp events(issue_id), do: Facts.events(issue_id)
  defp events(issue_id, type), do: issue_id |> events() |> Enum.filter(&(&1.type == type))
  defp run_kinds(issue_id), do: for(%{type: "run.started", payload: payload} <- events(issue_id), do: payload.run_kind)

  defp prompts(dir), do: dir |> Path.join("*.txt") |> Path.wildcard() |> Enum.map(&File.read!/1)

  test "a new ticket is groomed in its dispatch, and the run that follows works from the plan", ctx do
    %{issue: issue, issue_id: issue_id} = ctx
    grooming_answers!(ctx.root, plan())
    # Before Grooming, a run of this ticket would read its description.
    assert PromptBuilder.build_prompt(issue) =~ "<linear_issue_body>\nThe ticket list forgets my filter"

    {run_id, reason} = dispatch_and_wait(issue)
    assert reason == :normal

    # The ask, the plan and the Conductor's update are on the ledger, in that order.
    assert [%{payload: %{text: asked, source: "linear"}} = ask] = events(issue_id, "ask.recorded")
    assert asked =~ "The ticket list forgets my filter when I reload."
    assert [%{payload: %{version: 1, by: "grooming", shape: "single", summary: "The ticket list remembers its filter."}} = written] = events(issue_id, "plan.written")
    assert [%{payload: %{junction: "grooming", text: "I read this as one small change." <> _rest}} = update] = events(issue_id, "conductor.update")
    assert ask.seq < written.seq and written.seq < update.seq
    assert TicketPlan.groomed?(issue_id)
    assert [%{id: "c1", kind: "outcome", state: :open}, %{id: "c2", kind: "qa", state: :open}] = TicketChecks.list(issue_id)

    # The implementation run started in the same dispatch, after the Conductor's turn.
    assert run_kinds(issue_id) == ["conductor", "implementation"]
    assert [%{run_id: ^run_id, seq: started}] = Enum.filter(events(issue_id, "run.started"), &(&1.payload.run_kind == "implementation"))
    assert started > update.seq

    # Its prompt carries the ask, the plan and the checks, and not the description (the ask is
    # the description's words, so what is gone is the description's own block).
    prompt = PromptBuilder.build_prompt(issue)
    assert prompt =~ "## Ask\n"
    assert prompt =~ "The ticket list forgets my filter when I reload."
    assert prompt =~ "## Plan\n"
    assert prompt =~ "Approach: store the filter with the view state."
    assert prompt =~ "## Checks\n"
    assert prompt =~ "The filter is applied after a reload."
    refute prompt =~ "<linear_issue_body>"

    # And that is the prompt the run's agent was given: the command saw Grooming's, then the run's.
    assert [run_prompt] = Enum.reject(prompts(ctx.prompts), &(&1 =~ "this turn is Grooming"))
    assert run_prompt =~ "## Ask"
    assert run_prompt =~ "## Plan"
    assert run_prompt =~ "## Checks"
    assert run_prompt =~ "Approach: store the filter with the view state."
    refute run_prompt =~ "<linear_issue_body>"
  end

  test "a plan that splits the ticket creates its sub-tickets and parks it, and no run starts on it", ctx do
    %{issue: issue, issue_id: issue_id} = ctx
    subs = [%{"title" => "The API", "ask" => "Add the filter."}, %{"title" => "The list", "ask" => "Read it.", "after" => ["s1"]}]
    grooming_answers!(ctx.root, plan(%{"shape" => "split", "sub_tickets" => subs}))

    {_run_id, reason} = dispatch_and_wait(issue)
    # The run's task ended before its agent started, for the ticket's next dispatch.
    assert reason == {:shutdown, :groom_again}

    # Both sub-tickets exist under the ticket in the tracker, with no Linear blocker link between them.
    assert [parent, first, second] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    assert parent.id == issue_id
    assert [%{id: first_id}, %{id: second_id}] = parent.sub_issues
    assert %Issue{id: ^first_id, title: "The API", description: "Add the filter.", blocked_by: []} = first
    assert %Issue{id: ^second_id, title: "The list", blocked_by: []} = second
    assert %{identifier: parent_identifier} = first.parent
    assert %{identifier: ^parent_identifier} = second.parent
    assert parent_identifier == issue.identifier
    assert_received {:memory_tracker_issue_created, ^first_id, %{parent_id: ^issue_id, state: "Todo"}}
    assert_received {:memory_tracker_issue_created, ^second_id, %{parent_id: ^issue_id, state: "Backlog"}}
    # The second was given its stored dependency on the first while in Backlog, and only then moved to Todo.
    assert [%{issue_id: ^first_id, kind: :done}] = second_id |> RunStore.get_ticket_state() |> TicketState.normalize() |> Map.fetch!(:depends_on)
    assert_received {:memory_tracker_state_update, ^second_id, "Todo"}

    # Each sub-ticket's ask is on its own ledger, from the parent.
    assert [%{payload: %{text: "Add the filter.", source: "parent", from: ^parent_identifier}}] = events(first_id, "ask.recorded")
    assert [%{payload: %{text: "Read it.", source: "parent"}}] = events(second_id, "ask.recorded")

    # The parent waits on them, in the tracker and on Symphony's record, with its plan naming them.
    assert_received {:memory_tracker_state_update, ^issue_id, @waiting}
    assert %{phase: @waiting} = RunStore.get_ticket_state(issue_id)
    assert %{shape: "split", sub_tickets: [planned_first, planned_second]} = TicketPlan.current(issue_id)
    assert %{key: "s1", identifier: first_identifier} = planned_first
    assert %{key: "s2", identifier: second_identifier, after: ["s1"]} = planned_second
    assert [first_identifier, second_identifier] == [first.identifier, second.identifier]
    assert [%{payload: %{junction: "grooming"}}] = events(issue_id, "conductor.update")

    # No implementation run started on it: the only run is the Conductor's, and the command was
    # given Grooming's prompt alone.
    assert run_kinds(issue_id) == ["conductor"]
    assert [grooming_prompt] = prompts(ctx.prompts)
    assert grooming_prompt =~ "this turn is Grooming"

    # A dispatch that finds it again holds it: a groomed ticket in the waiting state gets no run.
    waiting = %{parent | state: @waiting}
    assert SubIssueWait.held?(waiting, ["Done", "Canceled"], Config.settings!())
    state = Orchestrator.dispatch_chosen_issues_for_test([waiting], orchestrator_state())
    assert state.running == %{}
    assert run_kinds(issue_id) == ["conductor"]
  end

  # TP-1566: Start reads the ticket by identifier, with no repo key, and runs it in its record's
  # repository. A ticket with no plan is still groomed first, in that repository's workspace.
  test "Start from the Director on a ticket with no plan grooms it first, in its record's repository", ctx do
    %{issue: issue, issue_id: issue_id} = ctx
    grooming_answers!(ctx.root, plan())
    read_by_identifier = %{issue | repo_key: nil}

    {:reply, {:ok, %{started: true, repo_key: @repo}}, state} =
      Orchestrator.handle_call({:start_issue, read_by_identifier, "start it"}, {self(), make_ref()}, orchestrator_state())

    assert {_run_id, :normal} = wait(state, issue)
    assert run_kinds(issue_id) == ["conductor", "implementation"]
    assert [%{repo_key: @repo, payload: %{by: "grooming"}}] = events(issue_id, "plan.written")
    assert [_grooming, run_prompt] = Enum.sort_by(prompts(ctx.prompts), &(not (&1 =~ "this turn is Grooming")))
    assert run_prompt =~ "## Plan"

    # Grooming read the code where the run then worked: the ticket's workspace under its repository.
    workspace = Path.join([ctx.root, "workspaces", @repo, issue.identifier])
    assert ctx.root |> Path.join("grooming.cwd") |> File.read!() |> String.trim() |> String.ends_with?(Path.join(@repo, issue.identifier))
    assert File.dir?(workspace)
  end
end
