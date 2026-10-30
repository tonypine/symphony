defmodule SymphonyElixir.AgentRunnerPathUnlockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Decisions

  @grant "Unlock config/settings_ui_exempt.yml for TP-760 so the run can drop the human_actions.label exemption."

  defmodule UnlockAgent do
    # Coding-agent stand-in: reports the session's and the turn's opts and the prompt.
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(%{opts: session_opts}, prompt, _issue, turn_opts) do
      send(Application.fetch_env!(:symphony_elixir, :unlock_agent_recipient), {:turn, session_opts, turn_opts, prompt})
      {:ok, %{session_id: "sess"}}
    end

    def stop_session(_session), do: :ok
  end

  setup do
    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, :unlock_agent_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-unlock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      workspace_root: test_root,
      agent_kind: "claude",
      max_turns: 1
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :unlock_agent_recipient)
      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  test "the ticket's next run gets the unlocked path in its sandbox, tools and prompt; later runs and other tickets don't", ctx do
    {:ok, description} = Decisions.put("Drop the setting.", [Decisions.entry("ruling-c1", ~D[2026-10-14], nil, nil, @grant)])

    assert :ok = run(ctx, "TP-760", description)
    assert_receive {:turn, session_opts, turn_opts, prompt}
    assert session_opts[:unlocked_paths] == ["config/settings_ui_exempt.yml"]
    assert turn_opts[:unlocked_paths] == ["config/settings_ui_exempt.yml"]
    assert prompt =~ "Protected paths unlocked for this run:"
    assert prompt =~ "- `config/settings_ui_exempt.yml`, by decision D1"

    assert :ok = run(ctx, "TP-760", description)
    assert_receive {:turn, session_opts, turn_opts, prompt}
    assert session_opts[:unlocked_paths] == []
    assert turn_opts[:unlocked_paths] == []
    refute prompt =~ "Protected paths unlocked for this run:"

    assert :ok = run(ctx, "TP-761", description)
    assert_receive {:turn, session_opts, _turn_opts, _prompt}
    assert session_opts[:unlocked_paths] == []
  end

  defp run(ctx, identifier, description) do
    workspace = Path.join(ctx.test_root, identifier)
    File.mkdir_p!(workspace)
    issue = %Issue{id: "issue-#{identifier}", identifier: identifier, title: "Remove the label", state: "Rework", description: description}

    AgentRunner.run(issue, nil,
      workspace_path: workspace,
      agent_module: UnlockAgent,
      run_id: "run-#{System.unique_integer([:positive])}",
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [%{issue | state: "Done"}]} end,
      leftover_processes: [table: fn -> {:ok, []} end]
    )
  end
end
