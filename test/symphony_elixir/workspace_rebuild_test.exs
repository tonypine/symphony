defmodule SymphonyElixir.WorkspaceRebuildTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{TicketEvents, TicketPullRequest, TicketSignals, WorkspaceRebuild}

  # Coding-agent stand-in: reports the head its workspace stands on when the turn starts.
  defmodule HeadAgent do
    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(%{workspace: workspace}, _prompt, _issue, _turn_opts) do
      {head, _status} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
      send(Application.fetch_env!(:symphony_elixir, :rebuild_agent_recipient), {:turn_on, workspace, String.trim(head)})
      {:ok, %{session_id: "sess"}}
    end

    def stop_session(_session), do: :ok
  end

  setup do
    :ok = RunStore.clear()
    Application.put_env(:symphony_elixir, :rebuild_agent_recipient, self())
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-rebuild-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :rebuild_agent_recipient)
      File.rm_rf(test_root)
    end)

    origin = Path.join(test_root, "origin.git")
    primary = Path.join(test_root, "primary")
    git!(test_root, ["init", "-q", "--bare", "-b", "main", origin])
    git!(test_root, ["clone", "-q", origin, primary])
    main = commit!(primary, "base")
    git!(primary, ["push", "-q", "origin", "HEAD:refs/heads/main"])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      workspace_root: Path.join(test_root, "workspaces"),
      workspace_strategy: "worktree",
      workspace_repo: primary,
      agent_kind: "claude",
      max_turns: 1
    )

    %{test_root: test_root, origin: origin, primary: primary, main: main, repo_key: Config.repo_key!()}
  end

  describe "a ticket whose workspace folder was deleted while its PR is open" do
    test "is rebuilt on the PR's head, and its timeline names the rebuild and the head", ctx do
      issue = %Issue{id: "issue-deleted", identifier: "TP-90", title: "Continue it", state: "In Progress"}

      capture_log(fn -> assert :ok = run(issue, "run-1") end)
      assert_received {:turn_on, workspace, main}
      assert main == ctx.main

      # The run's work is pushed and its PR opened; a person pushes on top of it.
      commit!(workspace, "the run's work")
      git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/auto/TP-90"])
      pr_head = commit!(workspace, "a person's push")
      git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/auto/TP-90", "HEAD:refs/pull/90/head"])
      :ok = TicketPullRequest.put(ctx.repo_key, issue.id, %{pr_url: "https://github.com/acme/repo/pull/90"})
      put_run(ctx, issue, "run-1", ended_at: DateTime.utc_now())

      File.rm_rf!(workspace)

      capture_log(fn -> assert :ok = run(issue, "run-2") end)

      assert_received {:turn_on, ^workspace, ^pr_head}
      assert git!(workspace, ["branch", "--show-current"]) == "auto/TP-90"

      assert [%{payload: payload, summary: summary}] = TicketEvents.query(issue.id, types: ["workspace.rebuilt"])
      assert %{reason: "missing_folder", winner: "pull_request", head: ^pr_head, pr_head: ^pr_head, branch_head: ^pr_head} = payload
      assert summary.title == "Workspace rebuilt on the PR head #{String.slice(pr_head, 0, 7)}"
      assert summary.detail =~ "Its workspace folder was missing"
    end
  end

  describe "choose/2" do
    test "a workspace the age GC reclaimed starts on the PR's head", ctx do
      issue = issue("TP-91")
      pr_head = push_branch!(ctx, "auto/TP-91", ["work"], pr: 91)
      put_pr(ctx, issue, 91)
      put_run(ctx, issue, "old-run", ended_at: DateTime.add(DateTime.utc_now(), -30 * 86_400))

      assert {:ok, %{reason: :reclaim, winner: :pull_request, head: ^pr_head}} = choose(issue)
      assert [%{payload: %{reason: "reclaim", winner: "pull_request"}}] = TicketEvents.query(issue.id, types: ["workspace.rebuilt"])
    end

    test "a ticket whose last run was on another host is a host change", ctx do
      issue = issue("TP-92")
      pr_head = push_branch!(ctx, "auto/TP-92", ["work"], pr: 92)
      put_pr(ctx, issue, 92)
      put_run(ctx, issue, "remote-run", worker_host: "worker-1", ended_at: DateTime.utc_now())

      assert {:ok, %{reason: :host_change, winner: :pull_request, head: ^pr_head}} = choose(issue)
    end

    test "a recorded unpushed head newer than the PR's head wins", ctx do
      issue = issue("TP-93")
      pr_head = push_branch!(ctx, "auto/TP-93", ["work"], pr: 93)
      put_pr(ctx, issue, 93)
      unpushed = local_commit!(ctx, pr_head, "unpushed work")
      record_run_ended(ctx, issue, "run-a", unpushed)
      put_run(ctx, issue, "run-a", ended_at: DateTime.utc_now())

      assert {:ok, %{winner: :recorded, head: ^unpushed, pr_head: ^pr_head, recorded_head: ^unpushed}} = choose(issue)

      assert %Issue{workspace_base_ref: ^unpushed} =
               capture_log_result(fn -> WorkspaceRebuild.start(issue, opts(run_id: "run-b")) end)
    end

    test "a recorded head older than the PR's head loses to it", ctx do
      issue = issue("TP-94")
      first = push_branch!(ctx, "auto/TP-94", ["work"], pr: 94)
      record_run_ended(ctx, issue, "run-a", first)
      pr_head = push_branch!(ctx, "auto/TP-94", ["a person's push"], pr: 94, from: first)
      put_pr(ctx, issue, 94)

      assert {:ok, %{winner: :pull_request, head: ^pr_head, recorded_head: ^first}} = choose(issue)
    end

    test "heads that diverge are settled for the PR's", ctx do
      issue = issue("TP-95")
      pr_head = push_branch!(ctx, "auto/TP-95", ["work"], pr: 95)
      put_pr(ctx, issue, 95)
      record_run_ended(ctx, issue, "run-a", local_commit!(ctx, ctx.main, "other work"))

      assert {:ok, %{winner: :pull_request, head: ^pr_head}} = choose(issue)
    end

    test "a pushed branch with no PR yet is the start", ctx do
      issue = issue("TP-96")
      branch_head = push_branch!(ctx, "auto/TP-96", ["work"])

      assert {:ok, %{winner: :branch, head: ^branch_head, pr_head: nil, reason: :missing_folder}} = choose(issue)
    end

    test "a renamed ticket's branch is the one its PR is on", ctx do
      issue = %{issue("TP-102") | workspace_branch: "auto/TON-102"}
      branch_head = push_branch!(ctx, "auto/TON-102", ["work before the rename"])
      push_branch!(ctx, "auto/TP-102", ["another branch"])

      assert {:ok, %{winner: :branch, branch: "auto/TON-102", head: ^branch_head}} = choose(issue)
    end

    test "a ticket read without its id still starts on its branch", ctx do
      issue = %{issue("TP-103") | id: nil}
      branch_head = push_branch!(ctx, "auto/TP-103", ["work"])

      assert {:ok, %{winner: :branch, head: ^branch_head, reason: :missing_folder}} = choose(issue)
    end

    test "a ticket with no branch anywhere starts from main", ctx do
      issue = issue("TP-97")
      put_run(ctx, issue, "run-a", ended_at: DateTime.utc_now())
      record_run_ended(ctx, issue, "run-a", "0123456789abcdef0123456789abcdef01234567")

      assert {:ok, %{winner: :main, head: nil}} = choose(issue)
      assert %Issue{workspace_base_ref: nil} = capture_log_result(fn -> WorkspaceRebuild.start(issue, opts()) end)

      assert [%{payload: %{winner: "main"} = payload, summary: %{title: "Workspace rebuilt from main: the ticket has no branch yet"}} | _] =
               TicketEvents.query(issue.id, types: ["workspace.rebuilt"])

      refute Map.has_key?(payload, :head)
    end

    test "a ticket's first workspace records nothing", ctx do
      issue = issue("TP-98")

      assert :not_rebuilt = choose(issue)
      assert WorkspaceRebuild.start(issue, opts()) == issue
      assert TicketEvents.query(issue.id, types: ["workspace.rebuilt"]) == []
      _ = ctx
    end

    test "what came before a Restart never counts", ctx do
      issue = issue("TP-99")
      old = push_branch!(ctx, "auto/TP-99", ["thrown away"])
      record_run_ended(ctx, issue, "run-a", old)
      put_run(ctx, issue, "run-a", ended_at: DateTime.utc_now())
      {:ok, _event} = TicketEvents.record(ctx.repo_key, issue.id, "person.action", %{action: "restart"}, actor: %{kind: "person", name: "Tony"})

      assert {:ok, %{winner: :main, branch_head: nil, recorded_head: nil}} = choose(issue)

      # Once a run pushed the new attempt, the branch is the ticket's again.
      fresh = push_branch!(ctx, "auto/TP-99", ["new attempt"], from: ctx.main, force: true)
      TicketSignals.record_event(ctx.repo_key, issue.id, "attempt.pushed", %{head: fresh})

      assert {:ok, %{winner: :branch, head: ^fresh}} = choose(issue)
    end

    test "is not a rebuild for a kept workspace, an SSH worker or a clone workspace", ctx do
      issue = issue("TP-100")
      push_branch!(ctx, "auto/TP-100", ["work"])
      {:ok, workspace} = Workspace.local_path_for_issue(issue, ctx.repo_key)
      File.mkdir_p!(workspace)

      assert :not_rebuilt = choose(issue)
      File.rm_rf!(workspace)

      assert :not_rebuilt = WorkspaceRebuild.choose(issue, opts(worker_host: "worker-1"))
      settings = Config.settings!()
      clone = %{settings | workspace: %{settings.workspace | strategy: "clone"}}
      assert :not_rebuilt = WorkspaceRebuild.choose(issue, opts(settings: clone))
      assert :not_rebuilt = WorkspaceRebuild.choose(issue, repo_key: ctx.repo_key)
    end

    test "a workspace made again with no lifecycle settings is a missing folder", ctx do
      issue = issue("TP-101")
      branch_head = push_branch!(ctx, "auto/TP-101", ["work"])
      put_run(ctx, issue, "run-a", ended_at: DateTime.add(DateTime.utc_now(), -30 * 86_400))
      settings = Config.settings!()
      lifecycle = %{settings.workspace.lifecycle | age_gc_enabled: false}
      no_gc = %{settings | workspace: %{settings.workspace | lifecycle: lifecycle}}

      assert {:ok, %{reason: :missing_folder, head: ^branch_head}} = WorkspaceRebuild.choose(issue, opts(settings: no_gc))

      no_lifecycle = %{settings | workspace: Map.delete(Map.from_struct(settings.workspace), :lifecycle)}
      assert {:ok, %{reason: :missing_folder}} = WorkspaceRebuild.choose(issue, opts(settings: no_lifecycle))
    end
  end

  defp run(issue, run_id) do
    AgentRunner.run(issue, nil,
      agent_module: HeadAgent,
      run_id: run_id,
      issue_enricher: &{:ok, &1},
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      leftover_processes: [table: fn -> {:ok, []} end]
    )
  end

  defp issue(identifier), do: %Issue{id: "issue-#{identifier}", identifier: identifier, title: identifier, state: "In Progress"}

  defp opts(extra \\ []), do: Keyword.merge([repo_key: Config.repo_key!(), settings: Config.settings!()], extra)

  defp choose(issue), do: capture_log_result(fn -> WorkspaceRebuild.choose(issue, opts()) end)

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp put_pr(ctx, issue, number), do: :ok = TicketPullRequest.put(ctx.repo_key, issue.id, %{pr_url: "https://github.com/acme/repo/pull/#{number}"})

  defp put_run(ctx, issue, run_id, attrs) do
    :ok =
      RunStore.put_run(
        Map.merge(
          %{
            repo_key: ctx.repo_key,
            run_id: run_id,
            issue_id: issue.id,
            issue_identifier: issue.identifier,
            status: "success",
            worker_host: nil,
            started_at: DateTime.add(Keyword.fetch!(attrs, :ended_at), -60)
          },
          Map.new(attrs)
        )
      )
  end

  defp record_run_ended(ctx, issue, run_id, unpushed_head) do
    {:ok, _event} = TicketEvents.record(ctx.repo_key, issue.id, "run.ended", %{run_id: run_id, exit: "success", unpushed_head: unpushed_head})
  end

  # Commits `messages` on a scratch clone from `from` (main by default) and pushes them to `branch`
  # on origin, and to the PR's head ref when `pr:` names one. Returns the pushed head.
  defp push_branch!(ctx, branch, messages, opts \\ []) do
    scratch = Path.join(ctx.test_root, "scratch-#{System.unique_integer([:positive])}")
    git!(ctx.test_root, ["clone", "-q", ctx.origin, scratch])
    git!(scratch, ["fetch", "-q", "origin", "+refs/heads/*:refs/remotes/origin/*"])
    git!(scratch, ["checkout", "-q", "--detach", Keyword.get(opts, :from, ctx.main)])
    head = Enum.reduce(messages, nil, fn message, _head -> commit!(scratch, message) end)
    refs = ["HEAD:refs/heads/#{branch}"] ++ if(number = opts[:pr], do: ["HEAD:refs/pull/#{number}/head"], else: [])
    git!(scratch, ["push", "-q"] ++ if(opts[:force], do: ["--force"], else: []) ++ ["origin" | refs])
    head
  end

  # A commit only the source repository holds (a run's unpushed work), on top of `parent`.
  defp local_commit!(ctx, parent, message) do
    git!(ctx.primary, ["fetch", "-q", "origin", "+refs/heads/*:refs/remotes/origin/*"])
    tree = git!(ctx.primary, ["rev-parse", "#{parent}^{tree}"])
    git!(ctx.primary, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit-tree", tree, "-p", parent, "-m", message])
  end

  defp commit!(dir, message) do
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
