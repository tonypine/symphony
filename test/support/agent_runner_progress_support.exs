defmodule SymphonyElixir.AgentRunnerProgressSupport do
  @moduledoc """
  What the tests of how an agent run ends (`SymphonyElixir.AgentRunner`'s progress checks) share:
  the coding-agent and GitHub stand-ins a run is given, and `run_issue!/2`, which runs the ticket
  `issue-progress` through `AgentRunner.run/3` with them.
  """

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrWatchSupport
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.Workflow

  import ExUnit.Assertions
  import SymphonyElixir.TestSupport, only: [ticket_signals: 1, write_workflow_file!: 2]

  @pr_url "https://github.com/example/repo/pull/337"

  # These tests follow how a run ends, so a CI Fix run is one agent session unless a test gives a
  # list: the default list's failed-check step (TP-1555) has its own tests.
  @one_session_ci_fix """
  phases:
    ci_fix:
      steps:
        - {id: fix, title: Fix the failed check, mode: delegated}
  """

  defmodule ProgressAgent do
    # Coding-agent stand-in: every turn completes and is reported to the test, or, with
    # `:progress_api_unreachable` set, ends as Claude's turn does when it can't reach the model API.
    # `:progress_turn_hook` runs with the turn's options, as a tool the agent calls would. A turn on
    # a delegated step of the run's step list records the step passed, as the prompt asks
    # (`SymphonyElixir.PhaseSteps`). `:progress_turn_extra` adds its fields to every turn's result,
    # as the harness's `background_wait` (TP-1570).
    def start_session(_workspace, opts) do
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_session_started, opts})
      {:ok, %{}}
    end

    def run_turn(_session, prompt, issue, opts) do
      count = Application.get_env(:symphony_elixir, :progress_agent_turns, 0) + 1
      Application.put_env(:symphony_elixir, :progress_agent_turns, count)
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:progress_turn, count})
      if hook = Application.get_env(:symphony_elixir, :progress_turn_hook), do: hook.(opts)
      record_step(prompt, issue, opts)

      case Application.get_env(:symphony_elixir, :progress_api_unreachable) do
        %{} = info -> {:error, {:model_api_unreachable, info}}
        nil -> {:ok, Map.merge(%{session_id: "sess-#{count}"}, Application.get_env(:symphony_elixir, :progress_turn_extra, %{}))}
      end
    end

    def stop_session(_session), do: :ok

    defp record_step(prompt, issue, opts) do
      with [_match, id] <- Regex.run(~r/This turn is the `(\w+)` step/, prompt),
           true <- prompt =~ "End this step by recording `step.completed`" do
        run_id = Keyword.get(opts, :run_id) || "run-progress"
        payload = %{step_id: id, title: id, mode: "delegated", outcome: "passed"}
        SymphonyElixir.TicketEvents.record("default", issue.id, "step.completed", payload, actor: {:agent, run_id, "implementation"}, run_id: run_id)
      end
    end
  end

  defmodule ProgressGitHub do
    # Stands in for GitHub.PullRequest.fetch_ci_status/2 and reports the configured PR head;
    # `{:by_turn, results}` gives the result read after each turn (the last one repeats).
    def fetch_ci_status(pr_url, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :progress_agent_recipient), {:pr_head_fetched, pr_url})

      case Application.fetch_env!(:symphony_elixir, :progress_pr_head_result) do
        {:by_turn, results} -> Enum.at(results, Application.get_env(:symphony_elixir, :progress_agent_turns, 1) - 1) || List.last(results)
        result -> result
      end
    end
  end

  # `heads` is the workspace HEAD at run start and after each turn (the last one repeats);
  # `states` is the issue state after each turn (the last one repeats). `handoff` is a head the
  # push and PR tool hooks already emitted the handoff signal for, as a run that pushed it would.
  def run_issue!(state, opts) do
    heads = Keyword.fetch!(opts, :heads)

    if handoff = Keyword.get(opts, :handoff),
      do: :ok = SymphonyElixir.Handoff.emit("default", "issue-progress", %{head: handoff, branch: "auto/TP-337"})

    states = Keyword.get(opts, :states, [state])
    pr_url = Keyword.get(opts, :pr_url, @pr_url)
    test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-progress-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "TP-337")
    File.mkdir_p!(workspace)
    if setup_workspace = Keyword.get(opts, :workspace_setup), do: setup_workspace.(workspace)
    reviewer? = Keyword.get(opts, :reviewer, false)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      workspace_root: test_root,
      max_turns: Keyword.get(opts, :max_turns, 3),
      auto_review: Keyword.get(opts, :auto_review, %{enabled: true}),
      repos: Keyword.get(opts, :repos),
      review_agent: if(reviewer?, do: %{enabled: true, kind: "codex", command: "reviewer app-server"})
    )

    append_symphony_steps!(Keyword.get(opts, :symphony_steps, @one_session_ci_fix))

    issue =
      Keyword.get(opts, :issue, %Issue{
        id: "issue-progress",
        identifier: "TP-337",
        title: "Leave Rework",
        description: "Fix the PR",
        state: state,
        repo_key: "default"
      })

    if pr_url, do: :ok = TicketPullRequest.record_created("default", "issue-progress", pr_url, "auto/TP-337")

    try do
      AgentRunner.run(
        issue,
        Keyword.get(opts, :recipient),
        [
          workspace_path: workspace,
          agent_module: ProgressAgent,
          github: ProgressGitHub,
          workspace_head_reader: fn ^workspace, nil -> at_turn(heads) end,
          issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, fn _ids -> {:ok, [%{issue | state: at_turn(states, -1)}]} end),
          issue_enricher: &{:ok, &1}
        ] ++ Keyword.get(opts, :runner_opts, [])
      )
    after
      File.rm_rf(test_root)
    end
  end

  def at_turn(values, offset \\ 0) do
    Enum.at(values, turns() + offset) || List.last(values)
  end

  def turns, do: Application.get_env(:symphony_elixir, :progress_agent_turns, 0)

  def append_symphony_steps!(yaml) do
    path = Workflow.symphony_file_path()
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, File.read!(path) <> "\n" <> yaml)
    File.touch!(tmp, System.os_time(:second) + 2)
    File.rename!(tmp, path)
    Cache.clear()
    SymphonyElixir.TestSupport.settle_config_cache!([path])
  end

  def designed_repos do
    [[key: "default", workflow: Workflow.workflow_file_path(), team: "Test"]]
  end

  def assert_handoff_recorded(head, source) do
    signals = ticket_signals("issue-progress")
    assert Enum.any?(signals, &match?(%{name: "handoff", details: %{head: ^head, source: ^source}}, &1))
  end

  # The newest signal recorded for the run's issue, asserting its name and details.
  def assert_signal(name, details) do
    assert [%{name: ^name, details: ^details} | _rest] = ticket_signals("issue-progress")
  end

  # Another run on the same ticket: its turns count from zero, and the pause a park set is lifted, as
  # a person's Unblock lifts it.
  def next_run do
    Application.delete_env(:symphony_elixir, :progress_agent_turns)
    {:ok, _pause} = Pauses.clear_reasons({:ticket, "default", "issue-progress"}, fn _reason -> true end, by: Pauses.director())
  end

  def put_pending_ci_failure(opts) do
    failure = %{
      commit_sha: Keyword.get(opts, :commit_sha, "sha-same"),
      failed_checks: Keyword.get(opts, :failed_checks, [%{name: "make-all", status: "COMPLETED", conclusion: "FAILURE"}]),
      log_excerpt: "stub_test.exs:21 failed",
      approved: Keyword.fetch!(opts, :approved)
    }

    PrWatchSupport.put_fix!("default", "issue-progress", :ci_failure, failure, identifier: "TP-337", pr_url: @pr_url)
  end

  def put_pending_conflict(opts \\ []) do
    head = Keyword.get(opts, :head_sha, "sha-dirty")

    conflict = %{
      pr_url: @pr_url,
      head_ref: "auto/TP-337",
      head_sha: head,
      base_ref: "main",
      base_sha: "sha-main",
      conflict_key: "#{head}|sha-main",
      approved: Keyword.get(opts, :approved, false)
    }

    PrWatchSupport.put_fix!("default", "issue-progress", :pr_conflict, conflict, identifier: "TP-337", pr_url: @pr_url)
  end

  # Refreshes the issue through the Linear client, as the runner does in production.
  def linear_issue_fetcher do
    graphql_fun = fn "query SymphonyLinearIssuesById" <> _query, %{ids: ["issue-progress"]} ->
      issue = %{"id" => "issue-progress", "identifier" => "TP-337", "title" => "Leave Rework", "state" => %{"name" => "In Progress"}}
      {:ok, %{"data" => %{"issues" => %{"nodes" => [issue]}}}}
    end

    &Client.fetch_issue_states_by_ids_for_test(&1, graphql_fun)
  end
end
