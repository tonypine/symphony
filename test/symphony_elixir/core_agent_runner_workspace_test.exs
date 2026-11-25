defmodule SymphonyElixir.CoreAgentRunnerWorkspaceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  defmodule AttachedPrGitHub do
    # Stands in for GitHub.PullRequest.fetch_ci_status/2 on the attached PR; the
    # PR URL's fragment carries the head ref (and optional state) to report.
    def fetch_ci_status(pr_url, _opts) do
      case URI.parse(pr_url).fragment |> String.split(":") do
        [head_ref] -> {:ok, %{state: "OPEN", is_cross_repository: false, head_ref_name: head_ref}}
        [head_ref, state] -> {:ok, %{state: state, is_cross_repository: false, head_ref_name: head_ref}}
      end
    end
  end

  defp wait_for_hook_log(path, expected, deadline_ms \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      File.read(path) == {:ok, expected} -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("timed out waiting for #{path} to read #{inspect(expected)}")
      true -> Process.sleep(10) && wait_for_hook_log(path, expected, deadline_ms)
    end
  end

  defp no_op_issue_enricher do
    fn issue -> {:ok, issue} end
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  # Builds an upstream whose `feature-head` branch carries a commit (PR_HEAD.md)
  # that trunk lacks — standing in for commits pushed to the PR head after a run.
  # Returns the worktree-strategy workspace root and the PR head commit SHA the
  # dispatched agent must land on. Also writes a one-turn fake codex + workflow.
  defp setup_worktree_pr_head!(test_root) do
    origin_repo = Path.join(test_root, "origin")
    primary_repo = Path.join(test_root, "primary")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")

    File.mkdir_p!(origin_repo)
    git!(origin_repo, ["init", "-b", "main"])
    git!(origin_repo, ["config", "user.name", "Test User"])
    git!(origin_repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(origin_repo, "README.md"), "initial\n")
    git!(origin_repo, ["add", "README.md"])
    git!(origin_repo, ["commit", "-m", "initial"])
    git!(origin_repo, ["checkout", "-b", "feature-head"])
    File.write!(Path.join(origin_repo, "PR_HEAD.md"), "pushed to PR head\n")
    git!(origin_repo, ["add", "PR_HEAD.md"])
    git!(origin_repo, ["commit", "-m", "pr head commit"])
    pr_head_sha = git!(origin_repo, ["rev-parse", "HEAD"])
    git!(origin_repo, ["checkout", "main"])

    # Worktree strategy operates on a clone that tracks origin.
    assert {_output, 0} = System.cmd("git", ["clone", origin_repo, primary_repo])
    git!(primary_repo, ["config", "user.name", "Test User"])
    git!(primary_repo, ["config", "user.email", "test@example.com"])

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-pr-head"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-pr-head","status":"inProgress","items":[]}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
        *)
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      workspace_strategy: "worktree",
      workspace_repo: primary_repo,
      workspace_fetch_before_dispatch: true,
      agent_command: "#{codex_binary} app-server"
    )

    %{workspace_root: workspace_root, pr_head_sha: pr_head_sha}
  end

  test "agent runner falls back when issue enrichment raises and keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"inProgress\",\"items\":[]}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      repo_workspace_root = Path.join(workspace_root, "default")
      before = if File.dir?(repo_workspace_root), do: MapSet.new(File.ls!(repo_workspace_root)), else: MapSet.new()
      assert :ok = AgentRunner.run(issue, nil, issue_enricher: fn _issue -> raise "boom" end)
      entries_after = MapSet.new(File.ls!(repo_workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(repo_workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner starts the agent in one attempt when after_create times out once" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-hook-retry-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      hook_runs = Path.join(test_root, "after_create.runs")
      agent_launches = Path.join(test_root, "agent.launches")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      echo launch >> #{agent_launches}
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"inProgress\",\"items\":[]}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      # Slow on its first try only, like a dependency install on a loaded machine.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create_timeout_ms: 1_000,
        hook_after_create: """
        echo run >> #{hook_runs}
        if [ "$(wc -l < #{hook_runs})" -eq 1 ]; then sleep 2; fi
        """,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-s-373",
        identifier: "S-373",
        title: "Slow setup",
        description: "after_create is slow once",
        state: "In Progress",
        url: "https://example.org/issues/S-373",
        labels: []
      }

      log =
        capture_log(fn ->
          assert :ok = AgentRunner.run(issue, self(), issue_enricher: &{:ok, %{&1 | parent: %{identifier: "S-1", title: "Epic", done: 0, total: 1, children: ["started"]}}})
        end)

      assert File.read!(hook_runs) == "run\nrun\n"
      assert File.read!(agent_launches) == "launch\n"
      assert log =~ "Retrying workspace hook after timeout hook=after_create"
      refute log =~ "Agent run failed"

      # The orchestrator heard of both tries, each with its own deadline.
      for _try <- 1..2 do
        assert_received {:worker_runtime_info, "issue-s-373", %{workspace_hook: %{name: "after_create", deadline: %DateTime{}}}}
        assert_received {:worker_runtime_info, "issue-s-373", %{workspace_hook: nil}}
      end

      refute_received {:worker_runtime_info, "issue-s-373", %{workspace_hook: _hook}}
      # As the run ends, the orchestrator hears which comments it posted.
      assert_received {:worker_runtime_info, "issue-s-373", %{comment_ids: comment_ids}} when is_list(comment_ids)
      # The ticket page reads the parent and links the enrichment found from the orchestrator.
      assert_received {:worker_runtime_info, "issue-s-373", %{linked: %{parent: %{identifier: "S-1"}, linked_issues: []}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner sets up again a workspace whose after_create failed on the run before, then starts the agent" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-hook-rerun-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      hook_runs = Path.join(test_root, "after_create.runs")
      agent_launches = Path.join(test_root, "agent.launches")
      setup_ready = Path.join(test_root, "setup-ready")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      echo launch >> #{agent_launches}
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\",\"status\":\"inProgress\",\"items\":[]}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      # Fails until setup-ready exists, like an install with the registry down.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        echo run >> #{hook_runs}
        test -f #{setup_ready} && echo installed > deps.txt
        """,
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-s-378",
        identifier: "S-378",
        title: "Setup failed",
        description: "after_create fails once",
        state: "In Progress",
        url: "https://example.org/issues/S-378",
        labels: []
      }

      capture_log(fn ->
        assert_raise RuntimeError, ~r/workspace_hook_failed/, fn ->
          AgentRunner.run(issue, self(), issue_enricher: &{:ok, &1})
        end
      end)

      assert File.read!(hook_runs) == "run\n"
      refute File.exists?(agent_launches)

      File.write!(setup_ready, "")

      log =
        capture_log(fn ->
          assert :ok = AgentRunner.run(issue, self(), issue_enricher: &{:ok, &1})
        end)

      # The kept workspace is set up before the agent starts in it.
      assert File.read!(hook_runs) == "run\nrun\n"
      assert File.read!(Path.join([workspace_root, "default", "S-378", "deps.txt"])) == "installed\n"
      assert File.read!(agent_launches) == "launch\n"
      assert log =~ "Running workspace hook an earlier run left unfinished hook=after_create"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner waits for a removal of the issue's workspace still in flight before creating it" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-await-cleanup-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      hook_log = Path.join(test_root, "hooks.log")
      release = Path.join(test_root, "release")
      workspace = Path.join([workspace_root, "default", "S-689"])
      File.mkdir_p!(workspace)

      # after_create fails, so the run stops right after it creates the workspace.
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: """
        echo remove-started >> #{hook_log}
        while [ ! -f #{release} ]; do sleep 0.05; done
        echo remove-finished >> #{hook_log}
        """,
        hook_after_create: """
        echo created >> #{hook_log}
        exit 1
        """
      )

      issue = %Issue{id: "issue-s-689", identifier: "S-689", title: "Redispatched", state: "In Progress", labels: []}

      assert :ok = WorkspaceCleanup.remove(%{id: issue.id, identifier: issue.identifier, remove_reason: :terminal}, nil)
      wait_for_hook_log(hook_log, "remove-started\n")

      test_pid = self()

      run =
        Task.async(fn ->
          capture_log(fn ->
            assert_raise RuntimeError, ~r/workspace_hook_failed/, fn ->
              AgentRunner.run(issue, test_pid, issue_enricher: &{:ok, &1})
            end
          end)
        end)

      # The run is waiting on the removal, so after_create has not run yet.
      refute Task.yield(run, 200)
      assert File.read!(hook_log) == "remove-started\n"

      File.write!(release, "")
      Task.await(run, 10_000)

      assert File.read!(hook_log) == "remove-started\nremove-finished\ncreated\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner compacts oversized Codex first-turn prompts before app-server send" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-compact-prompt-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      capture_path = Path.join(test_root, "turn-start.json")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-compact\"}}}'
            ;;
          4)
            printf '%s\\n' "$line" > #{capture_path}
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-compact\",\"status\":\"inProgress\",\"items\":[]}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server",
        agent_codex_stdio_soft_limit_bytes: 12_000,
        prompt: String.duplicate("workflow detail\n", 1_000)
      )

      issue = %Issue{
        id: "issue-compact-prompt",
        identifier: "S-100",
        title: "Compact oversized prompt",
        description: String.duplicate("issue detail\n", 2_000),
        state: "In Progress",
        url: "https://example.org/issues/S-100",
        labels: ["backend"],
        comments: [
          %{author: "Reviewer", body: String.duplicate("comment detail\n", 1_000), created_at: nil}
        ]
      }

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher()
               )

      turn_start = File.read!(capture_path)

      assert turn_start =~ "linear_get_current_issue"
      assert turn_start =~ ~s(linear_get_comments` with `{\\"limit\\": 5})
      refute turn_start =~ "workflow detail"
      refute turn_start =~ "issue detail"
      refute turn_start =~ "comment detail"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not compact oversized Claude first-turn prompts" do
    {:ok, settings} = Schema.parse(%{execution: %{codex_stdio_prompt_soft_limit: 12_000}})
    claude_settings = %{settings | execution: %{settings.execution | harness: "claude", command: "claude"}}
    codex_settings = %{settings | execution: %{settings.execution | harness: "codex", command: "codex app-server"}}

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: String.duplicate("workflow detail\n", 1_000)
    )

    issue = %Issue{
      id: "issue-claude-no-compact",
      identifier: "S-CLAUDE-NO-COMPACT",
      title: "Claude oversized prompt regression",
      description: String.duplicate("issue detail\n", 2_000),
      state: "In Progress",
      url: "https://example.org/issues/S-CLAUDE-NO-COMPACT",
      labels: ["backend"],
      comments: [
        %{author: "Reviewer", body: String.duplicate("comment detail\n", 1_000), created_at: nil}
      ]
    }

    claude_prompt = AgentRunner.build_first_turn_prompt(issue, settings: claude_settings)
    codex_prompt = AgentRunner.build_first_turn_prompt(issue, settings: codex_settings)

    # Claude keeps the full rendered prompt regardless of size — the compact bootstrap is
    # Codex-only because Claude's transport doesn't share the Codex stdio soft limit.
    assert byte_size(claude_prompt) > 12_000
    assert claude_prompt =~ "workflow detail"
    refute claude_prompt =~ "linear_get_current_issue"

    # Codex still uses the compact bootstrap so the comparison locks in both branches of the gate.
    assert codex_prompt =~ "linear_get_current_issue"
    refute codex_prompt =~ "workflow detail"
  end

  test "the first-turn prompt lists the open PRs that share files with the ticket's own" do
    now = ~U[2026-10-13 12:00:00Z]

    for {id, files} <- [{"issue-own", ["lib/a.ex", "lib/b.ex"]}, {"issue-other", ["lib/b.ex"]}] do
      SymphonyElixir.PrWatchSupport.put_watch!("default", id,
        identifier: String.upcase(id),
        pr_url: "https://github.com/example/repo/pull/#{byte_size(id)}",
        landing: %{
          files: files,
          head_sha: "head",
          state: "QA",
          state_since: now,
          progress_at: now,
          waits_for: nil,
          waits_since: nil
        }
      )
    end

    issue = %Issue{id: "issue-own", identifier: "ISSUE-OWN", title: "Overlap", state: "Rework", repo_key: "default"}
    assert AgentRunner.build_first_turn_prompt(issue, []) =~ "- ISSUE-OTHER (QA) https://github.com/example/repo/pull/11: lib/b.ex"
    refute AgentRunner.build_first_turn_prompt(%{identifier: "NO-ID", title: "No id"}, []) =~ "Open pull requests"
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\",\"status\":\"inProgress\",\"items\":[]}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        agent_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()
      assert :ok = SymphonyElixir.Notifications.subscribe()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end,
                 issue_enricher: no_op_issue_enricher()
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"

      refute_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "issue_completed",
                        issue_identifier: "MT-99"
                      }},
                     50

      refute_receive {:notification_event,
                      %SymphonyElixir.Notifications.Event{
                        event: "pr_opened",
                        issue_identifier: "MT-99"
                      }},
                     50
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner syncs the worktree to the remote PR head when a conflict is pending" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-conflict-sync-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)

      issue = %Issue{
        id: "issue-conflict-sync",
        identifier: "RSM-CONFLICT",
        title: "Resolve the merge conflict",
        description: "PR has merge conflicts",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.test/org/repo/pull/7", nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher(),
                 pr_conflict: %{head_ref: "feature-head", head_sha: pr_head_sha, base_ref: "main"}
               )

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-CONFLICT"]))

      # The worktree branched off origin/feature-head rather than trunk, so the
      # commit only present on the PR head is visible to the agent.
      assert File.exists?(Path.join(workspace, "PR_HEAD.md"))
      assert git!(workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner syncs the worktree to the remote PR head for a reviewer-comment rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-rework-sync-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)

      # The PR review record carries the cached head branch name and the pending
      # reviewer comments that trigger the rework dispatch — no conflict involved.
      assert :ok =
               RunStore.put_pr_review(%{
                 repo_key: "default",
                 issue_id: "issue-rework-sync",
                 issue_identifier: "RSM-REWORK",
                 pr_url: "https://github.test/org/repo/pull/8",
                 head_ref_name: "feature-head",
                 status: "rework_requested",
                 pending_last_addressed_comment_id: "comment-8",
                 pending_reviewer_comments: [
                   %{
                     id: "comment-8",
                     kind: "inline_comment",
                     author: "Reviewer",
                     body: "Please address this.",
                     path: "lib/example.ex",
                     line: 7
                   }
                 ],
                 updated_at: ~U[2026-05-05 02:00:00Z]
               })

      issue = %Issue{
        id: "issue-rework-sync",
        identifier: "RSM-REWORK",
        title: "Address reviewer comments",
        description: "PR has reviewer feedback",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.test/org/repo/pull/8", nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher()
               )

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-REWORK"]))

      # The reviewer-comment rework lands on origin/feature-head, not trunk.
      assert File.exists?(Path.join(workspace, "PR_HEAD.md"))
      assert git!(workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner syncs the worktree to the remote PR head for a same-repo ci rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-ci-sync-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)

      # The failure the PR watcher sent the ticket to CI Fix for.
      SymphonyElixir.PrWatchSupport.put_fix!(
        "default",
        "issue-ci-sync",
        :ci_failure,
        %{
          commit_sha: pr_head_sha,
          head_ref_name: "feature-head",
          is_cross_repository: false,
          head_repository: %{name_with_owner: "org/repo"},
          failed_checks: [%{name: "specs"}],
          log_excerpt: "specs failed"
        },
        identifier: "RSM-CI",
        pr_url: "https://github.test/org/repo/pull/10"
      )

      issue = %Issue{
        id: "issue-ci-sync",
        identifier: "RSM-CI",
        title: "Fix CI",
        description: "PR has failing checks",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.test/org/repo/pull/10", nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher()
               )

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-CI"]))

      assert File.exists?(Path.join(workspace, "PR_HEAD.md"))
      assert git!(workspace, ["branch", "--show-current"]) == "feature-head"
      assert git!(workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not pin cross-repo ci reworks to an origin head ref" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-ci-fork-sync-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)

      assert :ok =
               RunStore.put_ci_check(%{
                 repo_key: "default",
                 issue_id: "issue-ci-fork",
                 issue_identifier: "RSM-CI-FORK",
                 pr_url: "https://github.test/org/repo/pull/11",
                 workspace_path: "/tmp/workspaces/RSM-CI-FORK",
                 status: "dispatch_requested",
                 ci_retry_count: 1,
                 ci_failure: %{
                   commit_sha: pr_head_sha,
                   head_ref_name: "feature-head",
                   is_cross_repository: true,
                   head_repository: %{name_with_owner: "contributor/repo"},
                   failed_checks: [%{name: "specs"}],
                   log_excerpt: "specs failed"
                 },
                 updated_at: ~U[2026-05-05 02:00:00Z]
               })

      issue = %Issue{
        id: "issue-ci-fork",
        identifier: "RSM-CI-FORK",
        title: "Fix fork CI",
        description: "Fork PR has failing checks",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.test/org/repo/pull/11", nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher()
               )

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-CI-FORK"]))

      refute File.exists?(Path.join(workspace, "PR_HEAD.md"))
      refute git!(workspace, ["branch", "--show-current"]) == "feature-head"
      refute git!(workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner resets a reused stale worktree onto the remote PR head for a rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-reuse-sync-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)
      primary_repo = Path.join(test_root, "primary")

      # Pre-create a registered worktree pinned to stale trunk (no PR head commit),
      # mimicking a worktree left over from a prior run before the PR head advanced.
      {:ok, stale_workspace} =
        SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "RSM-REUSE"]))

      File.mkdir_p!(Path.dirname(stale_workspace))
      git!(primary_repo, ["worktree", "add", "-b", "auto/RSM-REUSE", stale_workspace, "origin/main"])
      refute File.exists?(Path.join(stale_workspace, "PR_HEAD.md"))

      issue = %Issue{
        id: "issue-reuse-sync",
        identifier: "RSM-REUSE",
        title: "Resolve the merge conflict",
        description: "PR has merge conflicts",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, "https://github.test/org/repo/pull/9", nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher(),
                 pr_conflict: %{head_ref: "feature-head", head_sha: pr_head_sha, base_ref: "main"}
               )

      # The reused worktree was hard-reset onto origin/feature-head rather than
      # left on its stale trunk state.
      assert File.exists?(Path.join(stale_workspace, "PR_HEAD.md"))
      assert git!(stale_workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps the attached PR's branch after the issue's Linear key is renamed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-key-rename-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)
      primary_repo = Path.join(test_root, "primary")

      # The PR was opened as TON-218 from the TON-218 worktree, which still has
      # auto/TON-218 checked out (orphan_action defaults to "log").
      {:ok, old_workspace} =
        SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "TON-218"]))

      File.mkdir_p!(Path.dirname(old_workspace))
      git!(primary_repo, ["worktree", "add", "-b", "auto/TON-218", old_workspace, "origin/feature-head"])
      git!(primary_repo, ["push", "origin", "auto/TON-218"])
      # GitHub keeps the PR's head at refs/pull/218/head, where the landing run's sync fetches it.
      git!(primary_repo, ["push", "origin", "auto/TON-218:refs/pull/218/head"])

      # A post-rename dispatch already built a fresh auto/TP-218 worktree on trunk.
      {:ok, new_workspace} =
        SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "TP-218"]))

      git!(primary_repo, ["worktree", "add", "-b", "auto/TP-218", new_workspace, "origin/main"])

      pr_url = "https://github.com/org/repo/pull/218#auto/TON-218"

      issue = %Issue{
        id: "issue-key-rename",
        identifier: "TP-218",
        title: "Land the approved PR",
        description: "Renamed from TON-218",
        state: "Merging"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, pr_url, nil)

      assert :ok =
               AgentRunner.run(issue, nil,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 issue_enricher: no_op_issue_enricher(),
                 github: AttachedPrGitHub
               )

      # The TP-218 workspace now sits on the PR's head branch, so the scoped
      # GitHub tools (which resolve the PR from the current branch) find it.
      assert git!(new_workspace, ["branch", "--show-current"]) == "auto/TON-218"
      assert git!(new_workspace, ["rev-parse", "HEAD"]) == pr_head_sha
      # The clean old worktree released the branch instead of blocking dispatch.
      assert git!(old_workspace, ["branch", "--show-current"]) == ""
      assert git!(old_workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner dispatches a parent on its own branch when its sub-ticket's PR is attached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-sub-ticket-pr-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root, pr_head_sha: pr_head_sha} = setup_worktree_pr_head!(test_root)
      primary_repo = Path.join(test_root, "primary")

      # TP-586's clean, pushed worktree has its PR branch checked out while the usage limit
      # holds it, so no agent owns it right now.
      {:ok, sub_workspace} =
        SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "TP-586"]))

      File.mkdir_p!(Path.dirname(sub_workspace))
      git!(primary_repo, ["worktree", "add", "-b", "auto/TP-586", sub_workspace, "origin/feature-head"])
      git!(primary_repo, ["push", "origin", "auto/TP-586"])

      # Linear linked the sub-ticket's PR to its parent because its body said "Part of TP-381".
      pr_url = "https://github.com/org/repo/pull/83#auto/TP-586"

      issue = %Issue{
        id: "issue-parent",
        identifier: "TP-381",
        title: "Design how the hub updates itself",
        description: "Parent of TP-586",
        state: "In Progress"
      }

      :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, pr_url, nil)

      log =
        capture_log(fn ->
          assert :ok =
                   AgentRunner.run(issue, nil,
                     issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                     issue_enricher: no_op_issue_enricher(),
                     github: AttachedPrGitHub
                   )
        end)

      assert log =~ "Ignoring attached PR on another issue's branch"
      assert log =~ "head_ref=auto/TP-586"

      workspace = Path.join([workspace_root, "default", "TP-381"])
      assert git!(workspace, ["branch", "--show-current"]) == "auto/TP-381"
      refute File.exists?(Path.join(workspace, "PR_HEAD.md"))
      assert git!(sub_workspace, ["branch", "--show-current"]) == "auto/TP-586"
      assert git!(sub_workspace, ["rev-parse", "HEAD"]) == pr_head_sha
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps the default branch when the attached PR already uses it or is closed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-attached-pr-default-#{System.unique_integer([:positive])}"
      )

    try do
      %{workspace_root: workspace_root} = setup_worktree_pr_head!(test_root)

      # An open PR on a branch that isn't this issue's own is ignored too.
      for {identifier, fragment} <- [
            {"TP-300", "auto/TP-300"},
            {"TP-301", "feature-head:MERGED"},
            {"TP-302", "feature-head"},
            {"TP-303", "auto/feature-head"}
          ] do
        pr_url = "https://github.com/org/repo/pull/300##{fragment}"

        issue = %Issue{
          id: "issue-#{identifier}",
          identifier: identifier,
          title: "Attached PR",
          description: "No rename",
          state: "In Progress"
        }

        :ok = SymphonyElixir.TicketPullRequest.record_created("default", issue.id, pr_url, nil)

        assert :ok =
                 AgentRunner.run(issue, nil,
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                   issue_enricher: no_op_issue_enricher(),
                   github: AttachedPrGitHub
                 )

        workspace = Path.join([workspace_root, "default", identifier])
        assert git!(workspace, ["branch", "--show-current"]) == "auto/#{identifier}"
        refute File.exists?(Path.join(workspace, "PR_HEAD.md"))
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/home/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner refuses run when branch is checked out by another worktree" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-branch-collision-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      peer_worktree = Path.join(test_root, "peer-worktree")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(primary_repo)
      git_setup = fn args -> System.cmd("git", ["-C", primary_repo | args], stderr_to_stdout: true) end
      {_out, 0} = System.cmd("git", ["init", "-b", "main", primary_repo])
      {_out, 0} = git_setup.(["config", "user.name", "Test User"])
      {_out, 0} = git_setup.(["config", "user.email", "test@example.com"])
      File.write!(Path.join(primary_repo, "README.md"), "initial\n")
      {_out, 0} = git_setup.(["add", "README.md"])
      {_out, 0} = git_setup.(["commit", "-m", "initial"])
      {_out, 0} = git_setup.(["branch", "auto/MT-COLLIDE-AGENT"])
      {_out, 0} = git_setup.(["worktree", "add", peer_worktree, "auto/MT-COLLIDE-AGENT"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      issue = %Issue{
        id: "issue-branch-collision",
        identifier: "PR-COLLIDE-AGENT",
        title: "PR run collides with active issue worktree",
        description: "Refuse with a clear error, do not crash",
        state: "In Progress",
        workspace_branch: "auto/MT-COLLIDE-AGENT",
        workspace_base_ref: "auto/MT-COLLIDE-AGENT"
      }

      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/branch_already_checked_out_elsewhere/, fn ->
            AgentRunner.run(issue, nil, issue_enricher: no_op_issue_enricher())
          end
        end)

      assert log =~ "Refusing run for"
      assert log =~ "PR-COLLIDE-AGENT"
      assert log =~ "branch auto/MT-COLLIDE-AGENT already checked out at"
      assert File.exists?(peer_worktree)
    after
      File.rm_rf(test_root)
    end
  end
end
