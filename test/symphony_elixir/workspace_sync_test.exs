defmodule SymphonyElixir.WorkspaceSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.TicketEvents
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.WorkspaceSync

  @repo_key "repo-workspace-sync"
  @issue_id "issue-workspace-sync"
  @pr_url "https://github.com/acme/repo/pull/7"
  @pr_ref "refs/pull/7/head"

  # `remote` stands in for GitHub: it holds the PR's branch and the PR head where GitHub keeps it,
  # `refs/pull/7/head`. `source` is the repo the workspace was cloned from, whose `origin` a push
  # must match; `workspace` is the ticket's kept workspace on the PR's branch.
  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    RunStore.delete_ticket_state(@issue_id)
    :ok = TicketPullRequest.put(@repo_key, @issue_id, %{pr_url: @pr_url})

    root = Path.join(System.tmp_dir!(), "symphony-workspace-sync-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    source = Path.join(root, "source")
    workspace = Path.join(root, "TP-1")
    File.mkdir_p!(root)

    git!(root, ["init", "-q", "--bare", "-b", "main", remote])
    git!(root, ["clone", "-q", remote, source])
    commit!(source, "base")
    git!(source, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    git!(root, ["clone", "-q", remote, workspace])
    git!(workspace, ["checkout", "-q", "-b", "auto/TP-1"])
    base = head!(workspace)
    publish!(workspace, base)

    on_exit(fn ->
      RunStore.delete_ticket_state(@issue_id)
      File.rm_rf(root)
    end)

    %{root: root, remote: remote, source: source, workspace: workspace, base: base}
  end

  describe "sync/3: the newest head wins" do
    test "equal heads leave the workspace untouched", %{workspace: workspace, base: base, source: source} do
      File.write!(Path.join(workspace, "notes.txt"), "draft")

      assert {:ok, %{head: ^base, winner: :equal, action: :none, recorded_head: nil}} =
               sync(workspace, source_repo: source)

      assert head!(workspace) == base
      assert File.exists?(Path.join(workspace, "notes.txt"))

      assert [%{payload: payload, head_sha: ^base}] = synced_events()

      assert %{workspace_head: ^base, pr_head: ^base, winner: "equal", action: "none", head: ^base, run_kind: "qa"} =
               payload

      refute Map.has_key?(payload, :recorded_head)
    end

    test "a workspace behind the PR head is reset to it", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])

      assert {:ok, %{head: ^pr_head, winner: :pull_request, action: :reset}} = sync(workspace)
      assert head!(workspace) == pr_head
      assert [%{payload: payload}] = synced_events()
      assert %{workspace_head: ^base, pr_head: ^pr_head, winner: "pull_request", action: "reset", head: ^pr_head} = payload
    end

    test "a workspace ahead with unpushed commits is pushed first", %{workspace: workspace, remote: remote, base: base, source: source} do
      local = commit!(workspace, "unpushed work")

      assert {:ok, %{head: ^local, winner: :workspace, action: :pushed}} =
               sync(workspace, settings: %{workspace: %{repo: source}})

      assert git!(remote, ["rev-parse", "refs/heads/auto/TP-1"]) == local
      assert [%{payload: payload}] = synced_events()
      assert %{workspace_head: ^local, pr_head: ^base, winner: "workspace", action: "pushed", head: ^local} = payload
    end

    test "a person's push ahead of both the workspace and the recorded head wins", %{workspace: workspace, base: base, source: source} do
      recorded = commit!(workspace, "a run's commit")
      pushed = commit!(workspace, "a person's push on top")
      publish!(workspace, pushed)
      git!(workspace, ["reset", "-q", "--hard", base])

      assert {:ok, %{head: ^pushed, winner: :pull_request, action: :reset, recorded_head: ^recorded}} =
               sync(workspace, recorded_head: recorded, source_repo: source)

      assert head!(workspace) == pushed
      assert [%{payload: %{recorded_head: ^recorded, winner: "pull_request", action: "reset"}}] = synced_events()
    end

    test "a recorded unpushed head newer than both is restored and pushed", %{workspace: workspace, remote: remote, base: base, source: source} do
      recorded = commit!(workspace, "a run's commit it never pushed")
      git!(workspace, ["reset", "-q", "--hard", base])
      record_run_ended!("run-1", recorded)

      assert {:ok, %{head: ^recorded, winner: :recorded, action: :reset_and_pushed}} =
               sync(workspace, source_repo: source)

      assert head!(workspace) == recorded
      assert git!(remote, ["rev-parse", "refs/heads/auto/TP-1"]) == recorded
      assert [%{payload: payload}] = synced_events()
      assert %{workspace_head: ^base, pr_head: ^base, recorded_head: ^recorded, winner: "recorded", action: "reset_and_pushed"} = payload
    end

    test "a recorded head the repository no longer holds is left out", %{workspace: workspace, base: base} do
      missing = String.duplicate("a", 40)

      log =
        capture_log(fn ->
          assert {:ok, %{winner: :equal, recorded_head: nil}} = sync(workspace, recorded_head: missing)
        end)

      assert log =~ "The unpushed head aaaaaaaaaaaa a run of TP-1 recorded is not in its workspace's repository"
      assert head!(workspace) == base
    end
  end

  describe "sync/3: a workspace with local work is never reset" do
    test "uncommitted or untracked files block the run, naming them", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])
      for n <- 1..6, do: File.write!(Path.join(workspace, "notes-#{n}.txt"), "draft")

      assert {:error, {:workspace_dirty, ^base, ^pr_head, [work]}} = sync(workspace)
      assert work == "local changes (?? notes-1.txt, ?? notes-2.txt, ?? notes-3.txt, ?? notes-4.txt, ?? notes-5.txt and 1 more)"
      assert head!(workspace) == base
      assert [%{payload: %{winner: "pull_request", action: "blocked", reason: ^work} = payload}] = synced_events()
      refute Map.has_key?(payload, :head)
    end

    test "diverged heads block the run, naming the unpushed commits", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])
      local = commit!(workspace, "work in progress")

      assert {:error, {:workspace_dirty, ^local, ^pr_head, [work]}} = sync(workspace)
      assert work == "1 unpushed commit(s) (#{String.slice(local, 0, 12)})"
      assert head!(workspace) == local
      assert [%{payload: %{winner: "none", action: "blocked"}}] = synced_events()
    end

    test "diverged heads whose commits a remote has still block the run", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])
      local = commit!(workspace, "pushed elsewhere")
      git!(workspace, ["push", "-q", "origin", "HEAD:refs/heads/auto/TP-1-other"])

      assert {:error, {:workspace_dirty, ^local, ^pr_head, ["commits the PR head does not have"]}} = sync(workspace)
    end

    test "a git read that fails counts as local work", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])

      failing_status = fn
        ["status" | _rest], _dir -> {"fatal: index locked", 128}
        args, dir -> System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      end

      assert {:error, {:workspace_dirty, ^base, ^pr_head, ["a state git could not read (git status exited 128: fatal: index locked)"]}} =
               sync(workspace, git: failing_status)
    end
  end

  describe "sync/3: what it cannot do" do
    test "a reset or a push that fails is reported and recorded", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])

      failing_reset = fn
        ["reset" | _rest], _dir -> {"fatal: cannot lock ref", 128}
        args, dir -> System.cmd("git", args, cd: dir, stderr_to_stdout: true)
      end

      assert {:error, {:pr_head_reset_failed, 128, "fatal: cannot lock ref"}} = sync(workspace, git: failing_reset)
      assert [%{payload: %{winner: "pull_request", action: "failed", reason: "{:pr_head_reset_failed, 128, \"fatal: cannot lock ref\"}"}}] = synced_events()

      git!(workspace, ["reset", "-q", "--hard", pr_head])
      commit!(workspace, "unpushed work")
      assert {:error, {:push_failed, :origin_mismatch}} = sync(workspace, settings: %{})

      assert {:error, {:push_failed, :refused}} =
               sync(workspace, pusher: fn _workspace, nil, _source -> {:error, :refused} end)
    end

    test "nothing is synced or recorded without a local head, a PR or its fetched head", %{root: root, workspace: workspace} do
      assert {:error, :remote_worker} = sync(workspace, worker_host: "worker-1")
      assert {:error, :head_unreadable} = sync(Path.join(root, "missing"))
      assert {:error, {:branch_mismatch, "auto/TP-1", "auto/TP-9"}} = sync(workspace, expected_branch: "auto/TP-9")

      git!(root, ["--git-dir", Path.join(root, "remote.git"), "update-ref", "-d", @pr_ref])
      assert {:error, {:pr_head_fetch_failed, @pr_ref, 128, _output}} = sync(workspace)

      assert {:error, :no_pull_request} = WorkspaceSync.sync(no_pr_issue(), workspace, repo_key: @repo_key)
      assert synced_events() == []
    end

    test "the expected branch passes, and a run kind is optional", %{workspace: workspace} do
      assert {:ok, %{winner: :equal}} =
               WorkspaceSync.sync(issue(), workspace, repo_key: @repo_key, expected_branch: "auto/TP-1")

      assert [%{payload: payload}] = synced_events()
      refute Map.has_key?(payload, :run_kind)
    end
  end

  describe "before_run/3" do
    test "a workspace brought to the PR head starts the run", %{workspace: workspace, base: base} do
      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])

      log =
        capture_log(fn ->
          assert :ok = WorkspaceSync.before_run(issue(), workspace, repo_key: @repo_key, run_kind: :landing)
        end)

      assert log =~ "TP-1's landing stands on the PR head #{String.slice(pr_head, 0, 12)}"
      assert head!(workspace) == pr_head
    end

    test "no PR head to stand on starts the run as before; a workspace that cannot be synced does not", %{workspace: workspace, base: base} do
      assert :ok = WorkspaceSync.before_run(no_pr_issue(), workspace, repo_key: @repo_key)

      pr_head = commit!(workspace, "upkeep merge")
      publish!(workspace, pr_head)
      git!(workspace, ["reset", "-q", "--hard", base])
      File.write!(Path.join(workspace, "notes.txt"), "draft")

      log =
        capture_log(fn ->
          assert {:error, {:workspace_sync_failed, {:workspace_dirty, ^base, ^pr_head, ["local changes (?? notes.txt)"]}}} =
                   WorkspaceSync.before_run(issue(), workspace, repo_key: @repo_key)
        end)

      assert log =~ "Not starting TP-1's run: its workspace could not be brought to the PR head"
    end
  end

  describe "recorded_unpushed_head/1" do
    test "reads the unpushed head of the ticket's newest run only" do
      assert WorkspaceSync.recorded_unpushed_head(@issue_id) == nil
      assert WorkspaceSync.recorded_unpushed_head(nil) == nil

      record_run_ended!("run-1", String.duplicate("b", 40))
      assert WorkspaceSync.recorded_unpushed_head(@issue_id) == String.duplicate("b", 40)

      record_run_ended!("run-2", nil)
      assert WorkspaceSync.recorded_unpushed_head(@issue_id) == nil
    end

    test "reads the run that ended last, not the end written last" do
      record_run_ended!("run-2", String.duplicate("c", 40))
      # An earlier run closed late, at a boot, with the time it ended.
      {:ok, _event} =
        TicketEvents.record(@repo_key, @issue_id, "run.ended", %{run_id: "run-1", exit: "ended; no end was recorded"},
          run_id: "run-1",
          at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert WorkspaceSync.recorded_unpushed_head(@issue_id) == String.duplicate("c", 40)
    end
  end

  defp sync(workspace, opts \\ []), do: WorkspaceSync.sync(issue(), workspace, [repo_key: @repo_key, run_kind: "qa"] ++ opts)

  defp issue, do: %Issue{id: @issue_id, identifier: "TP-1", state: "QA", repo_key: @repo_key}
  defp no_pr_issue, do: %Issue{issue() | id: "issue-workspace-sync-no-pr"}

  defp synced_events, do: TicketEvents.query(@issue_id, types: ["workspace.synced"])

  defp record_run_ended!(run_id, unpushed_head) do
    payload = %{run_id: run_id, exit: "ended normally", unpushed_head: unpushed_head} |> Map.reject(fn {_key, value} -> is_nil(value) end)
    {:ok, _event} = TicketEvents.record(@repo_key, @issue_id, "run.ended", payload, run_id: run_id)
  end

  # Moves the PR's branch and its head on the remote to `sha`, as a push to the PR does.
  defp publish!(workspace, sha), do: git!(workspace, ["push", "-q", "-f", "origin", "#{sha}:refs/heads/auto/TP-1", "#{sha}:#{@pr_ref}"])

  defp head!(dir), do: git!(dir, ["rev-parse", "HEAD"])

  defp commit!(dir, message) do
    git!(dir, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message])
    head!(dir)
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
