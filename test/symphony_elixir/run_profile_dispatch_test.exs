defmodule SymphonyElixir.RunProfileDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer

  @run_profiles %{"breakdown" => %{"effort" => "high"}}

  defmodule FakeParentWalkthrough do
    def run(issue, workspace, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :parent_walkthrough_recipient)
      send(recipient, {:parent_walkthrough, issue, workspace, opts})
      Application.fetch_env!(:symphony_elixir, :parent_walkthrough_result)
    end
  end

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-profile-#{System.unique_integer([:positive])}")
    fake_claude = Path.join(test_root, "fake-claude")
    argv_trace = Path.join(test_root, "argv.trace")
    File.mkdir_p!(test_root)

    # Appends one line per Claude invocation: its argv, space-separated.
    File.write!(fake_claude, """
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' "$*" >> "#{argv_trace}"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-profile","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":5,"duration_api_ms":4,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-profile","total_cost_usd":0.0,"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root, fake_claude: fake_claude, argv_trace: argv_trace}
  end

  defp write_profile_workflow!(ctx, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: Path.join(ctx.test_root, "workspaces"),
          agent_kind: "claude",
          agent_command: ctx.fake_claude,
          max_turns: 1,
          agent_model: "claude-opus-5-5",
          agent_effort: "medium",
          agent_run_profiles: @run_profiles
        ],
        overrides
      )
    )
  end

  defp argv_lines(argv_trace) do
    if File.exists?(argv_trace), do: argv_trace |> File.read!() |> String.split("\n", trim: true), else: []
  end

  defp wait_for_argv_lines(argv_trace, count, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_argv_lines(argv_trace, count, deadline)
  end

  defp do_wait_for_argv_lines(argv_trace, count, deadline) do
    lines = argv_lines(argv_trace)

    cond do
      length(lines) >= count ->
        lines

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{count} Claude invocation(s), got #{inspect(lines)}")

      true ->
        Process.sleep(25)
        do_wait_for_argv_lines(argv_trace, count, deadline)
    end
  end

  # The run of `issue_id` RunStore lists, once it lists one; fails naming the issue when none
  # shows up within the timeout.
  defp wait_for_run(issue_id, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_run(issue_id, deadline)
  end

  defp do_wait_for_run(issue_id, deadline) do
    runs = RunStore.list_runs()

    cond do
      run = is_list(runs) && Enum.find(runs, &(&1.issue_id == issue_id)) ->
        run

      System.monotonic_time(:millisecond) > deadline ->
        listed = if is_list(runs), do: Enum.map(runs, & &1.issue_id), else: runs
        flunk("expected RunStore to list a run of #{issue_id} within the timeout, it listed #{inspect(listed)}")

      true ->
        Process.sleep(25)
        do_wait_for_run(issue_id, deadline)
    end
  end

  defp issue(id, identifier, attrs \\ %{}) do
    struct!(
      %Issue{
        id: id,
        identifier: identifier,
        title: "Run profile #{identifier}",
        description: "Pick the model and effort for this run",
        state: "Todo",
        team: %{key: "Test"},
        labels: [],
        url: "https://example.org/issues/#{identifier}"
      },
      attrs
    )
  end

  describe "AgentRunner.run_profile/3" do
    test "resolves the run kind and its model and effort from the settings", ctx do
      write_profile_workflow!(ctx)
      settings = Config.settings!()

      assert AgentRunner.run_profile(issue("i-1", "MT-1", %{labels: ["breakdown"]}), settings) ==
               %{kind: :breakdown, model: "claude-opus-5-5", effort: "high", provider: "anthropic"}

      assert AgentRunner.run_profile(issue("i-2", "MT-2"), settings) ==
               %{kind: :implementation, model: "claude-opus-5-5", effort: "medium", provider: "anthropic"}

      assert AgentRunner.run_profile(issue("i-3", "MT-3", %{state: "Merging"}), settings) ==
               %{kind: :landing, model: "claude-opus-5-5", effort: "medium", provider: "anthropic"}
    end

    test "resolves nil model and effort when nothing is configured", ctx do
      write_profile_workflow!(ctx, agent_model: nil, agent_effort: nil, agent_run_profiles: nil)

      assert AgentRunner.run_profile(issue("i-1", "MT-1"), Config.settings!()) ==
               %{kind: :implementation, model: nil, effort: nil, provider: "anthropic"}
    end
  end

  describe "dispatch" do
    test "starts each run with its kind's flags, records them, and reads the workflow on each dispatch", ctx do
      write_profile_workflow!(ctx)
      breakdown = issue("issue-profile-breakdown", "MT-PROFILE-1", %{labels: ["breakdown"]})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [breakdown])

      orchestrator_name = Module.concat(__MODULE__, :DispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn -> stop_process(pid) end)

      {first_run, log} =
        with_log(fn ->
          send(pid, :run_poll_cycle)
          assert [first] = wait_for_argv_lines(ctx.argv_trace, 1)
          assert String.ends_with?(first, "--print --model claude-opus-5-5 --effort high")
          wait_for_run("issue-profile-breakdown")
        end)

      assert log =~ ~r/Dispatching issue to agent: issue_id=issue-profile-breakdown .* run_kind=breakdown model=claude-opus-5-5 effort=high/
      assert %{run_kind: "breakdown", model: "claude-opus-5-5", effort: "high"} = first_run

      refute Map.has_key?(first_run, :reviewer_profile)

      # Edit the workflow while Symphony runs: the next dispatch uses the new profile.
      write_profile_workflow!(ctx,
        agent_model: nil,
        agent_run_profiles: %{"implementation" => %{"effort" => "low"}},
        review_agent: %{enabled: true, kind: "claude", command: ctx.fake_claude, model: "claude-sonnet-5-5"}
      )

      sub_ticket = issue("issue-profile-sub", "MT-PROFILE-2")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [sub_ticket])

      # The repo was just polled; make it due again instead of waiting for the poll interval.
      :sys.replace_state(pid, &%{&1 | repo_poll_due_at_ms: %{}})

      {sub_run, log} =
        with_log(fn ->
          send(pid, :run_poll_cycle)
          assert [_first, second | _reviewer] = wait_for_argv_lines(ctx.argv_trace, 2)
          assert String.ends_with?(second, "--print --effort low")
          refute second =~ "--model"
          wait_for_run("issue-profile-sub")
        end)

      assert log =~ ~r/Dispatching issue to agent: issue_id=issue-profile-sub .* run_kind=implementation model=default effort=low\n/

      assert %{
               run_kind: "implementation",
               model: nil,
               effort: "low",
               reviewer_profile: %{run_kind: "pre_push_review", model: "claude-sonnet-5-5", effort: "medium"}
             } = sub_run
    end

    test "dispatches a `plan` ticket as a breakdown run with the breakdown run profile", ctx do
      write_profile_workflow!(ctx)
      plan = issue("issue-profile-plan", "MT-PROFILE-3", %{labels: ["Plan"]})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [plan])

      orchestrator_name = Module.concat(__MODULE__, :PlanDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn -> stop_process(pid) end)

      {plan_run, log} =
        with_log(fn ->
          send(pid, :run_poll_cycle)
          assert [first] = wait_for_argv_lines(ctx.argv_trace, 1)
          assert String.ends_with?(first, "--print --model claude-opus-5-5 --effort high")
          wait_for_run("issue-profile-plan")
        end)

      assert log =~ ~r/Dispatching issue to agent: issue_id=issue-profile-plan .* run_kind=breakdown model=claude-opus-5-5 effort=high/
      assert %{run_kind: "breakdown", effort: "high"} = plan_run
    end

    test "names the PR comment a review_feedback run answers", ctx do
      write_profile_workflow!(ctx)
      issue = issue("issue-profile-review", "MT-PROFILE-3", %{state: "In Progress"})
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      :ok =
        RunStore.put_pr_review(%{
          repo_key: Config.repo_key!(),
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          pr_url: "https://github.com/example/repo/pull/3",
          status: "rework_requested",
          pending_reviewer_comments: [
            %{id: "c-1", kind: "comment", author: "reviewer", body: "\nRename this helper.\nIt reads oddly.", created_at: ~U[2026-10-04 04:30:00Z]}
          ]
        })

      orchestrator_name = Module.concat(__MODULE__, :ReviewFeedbackOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn -> stop_process(pid) end)

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          assert [_first | _rest] = wait_for_argv_lines(ctx.argv_trace, 1)
          wait_for_run("issue-profile-review")
        end)

      assert log =~
               ~s(run_kind=review_feedback model=claude-opus-5-5 effort=medium trigger_comment_id=c-1 trigger_comment_author=reviewer trigger_comment="Rename this helper." pending_comments=1)
    end
  end

  describe "AgentRunner.run/3" do
    test "a plain sub-ticket gets the agent effort, and a continuation turn keeps the run's profile", ctx do
      write_profile_workflow!(ctx, max_turns: 2)
      workspace = Path.join([ctx.test_root, "workspaces", "MT-CONT"])
      File.mkdir_p!(workspace)
      run_issue = issue("issue-continuation", "MT-CONT", %{state: "In Progress"})

      state_fetcher = fn _ids ->
        fetches = Process.get(:run_profile_fetches, 0) + 1
        Process.put(:run_profile_fetches, fetches)

        if fetches == 1 do
          # A config edit mid-run does not change the profile of the running run.
          write_profile_workflow!(ctx, max_turns: 2, agent_effort: "low")
          {:ok, [run_issue]}
        else
          {:ok, [%{run_issue | state: "Done"}]}
        end
      end

      assert :ok =
               AgentRunner.run(run_issue, nil,
                 workspace_path: workspace,
                 issue_state_fetcher: state_fetcher,
                 issue_enricher: fn issue -> {:ok, issue} end
               )

      assert [first, second] = argv_lines(ctx.argv_trace)
      assert String.ends_with?(first, "--print --model claude-opus-5-5 --effort medium")
      assert String.ends_with?(second, "--print --model claude-opus-5-5 --effort medium")
    end

    test "a final verification ticket the parent walkthrough handles starts no agent", ctx do
      write_profile_workflow!(ctx)
      workspace = Path.join([ctx.test_root, "workspaces", "MT-FV"])
      File.mkdir_p!(workspace)
      run_issue = issue("issue-fv", "MT-FV", %{state: "In Progress", title: "Final verification: Parent"})
      Application.put_env(:symphony_elixir, :parent_walkthrough_recipient, self())
      Application.put_env(:symphony_elixir, :parent_walkthrough_result, :ok)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :parent_walkthrough_recipient)
        Application.delete_env(:symphony_elixir, :parent_walkthrough_result)
      end)

      assert :ok =
               AgentRunner.run(run_issue, self(),
                 workspace_path: workspace,
                 parent_walkthrough: FakeParentWalkthrough,
                 issue_enricher: fn issue -> {:ok, issue} end
               )

      assert_received {:parent_walkthrough, %Issue{identifier: "MT-FV"}, ^workspace, opts}
      assert opts[:worker_host] == nil
      assert %Config.Schema{} = opts[:settings]
      on_message = Keyword.fetch!(opts, :on_message)
      on_message.(%{event: :notification})
      assert_received {:codex_worker_update, "issue-fv", %{event: :notification}}
      assert argv_lines(ctx.argv_trace) == []
    end

    test "with no model, effort or run profiles, Claude's argv is unchanged", ctx do
      write_profile_workflow!(ctx, agent_model: nil, agent_effort: nil, agent_run_profiles: nil)
      workspace = Path.join([ctx.test_root, "workspaces", "MT-PLAIN"])
      File.mkdir_p!(workspace)
      run_issue = issue("issue-plain", "MT-PLAIN", %{state: "In Progress"})

      assert :ok =
               AgentRunner.run(run_issue, nil,
                 workspace_path: workspace,
                 issue_state_fetcher: fn _ids -> {:ok, [%{run_issue | state: "Done"}]} end,
                 issue_enricher: fn issue -> {:ok, issue} end
               )

      assert [argv] = argv_lines(ctx.argv_trace)
      assert String.ends_with?(argv, "--plugin-dir #{plugin_dir_from(argv)} --verbose --output-format stream-json --print")
      refute argv =~ "--model"
      refute argv =~ "--effort"
    end
  end

  describe "Codex runtime" do
    test "ignores the run profile with one warning", ctx do
      write_profile_workflow!(ctx, agent_kind: "codex", agent_command: "codex app-server")
      outside_root = Path.join(ctx.test_root, "outside")
      File.mkdir_p!(outside_root)
      run_issue = issue("issue-codex", "MT-CODEX")
      profile = %{kind: :implementation, model: "gpt-5", effort: nil}

      log =
        capture_log(fn ->
          assert {:error, _reason} = CodexAppServer.start_session(outside_root, issue: run_issue, run_profile: profile)
        end)

      assert log =~ "Ignoring agent.model and agent.effort for the codex runtime issue_id=issue-codex issue_identifier=MT-CODEX run_kind=implementation model=gpt-5 effort=default"

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   CodexAppServer.start_session(outside_root,
                     issue: run_issue,
                     run_profile: %{profile | model: nil}
                   )
        end)

      refute log =~ "Ignoring agent.model"
    end
  end

  defp plugin_dir_from(argv) do
    [_, plugin_dir] = Regex.run(~r/--plugin-dir (\S+)/, argv)
    plugin_dir
  end
end
