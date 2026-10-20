defmodule SymphonyElixir.PrHeadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CodeReview, Handoff, PrHead, TicketPullRequest}
  alias SymphonyElixir.Config.Schema

  @repo_key "api"
  @issue_id "issue-pr-head"
  @pr_url "https://github.com/acme/api/pull/1159"
  @branch "auto/API-1159"

  defmodule FakeReviewAgent do
    def evaluate(issue, workspace, _settings, _opts) do
      {head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
      send(self(), {:reviewed, issue.id, String.trim(head)})
      {:ok, %{verdict: :approve, comments: [], reason: "looks good"}}
    end
  end

  defmodule FakeTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state})
      :ok
    end

    def create_comment(issue_id, body) do
      send(self(), {:commented, issue_id, body})
      :ok
    end
  end

  defmodule FakeQaPolicy do
    def decide(_issue, _settings, _opts), do: {:run, [%{kind: "cli", paths: ["lib/**"], prompt: "Follow the CLI playbook."}], "the change delivers a journey"}
  end

  defp issue(state \\ "Code Review"), do: %Issue{id: @issue_id, identifier: "API-1159", title: "Keep the branch", state: state, repo_key: @repo_key}

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp commit!(repo, message) do
    git!(repo, ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  # GitHub's answer for the pull request: `head` on `branch`, changing `changed_files` files.
  defp github(head, changed_files \\ 3, branch \\ @branch) do
    fn ["pr", "view", @pr_url, "--json", "headRefOid,headRefName,changedFiles"], _opts ->
      {Jason.encode!(%{"headRefOid" => head, "headRefName" => branch, "changedFiles" => changed_files}), 0}
    end
  end

  defp record_pull_request!, do: :ok = TicketPullRequest.record_created(@repo_key, @issue_id, @pr_url, @branch)

  # A checkout with two commits, put back on the first: the second is the pull request's head.
  defp behind_workspace! do
    dir = Path.join(System.tmp_dir!(), "pr-head-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", @branch])
    behind = commit!(dir, "first")
    ahead = commit!(dir, "the work")
    git!(dir, ["reset", "-q", "--hard", behind])
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, behind, ahead}
  end

  defp head(workspace), do: git!(workspace, ["rev-parse", "HEAD"])

  describe "sync/3" do
    test "resets a workspace behind its pull request head to it, keeping its local work" do
      record_pull_request!()
      {workspace, behind, ahead} = behind_workspace!()
      File.write!(Path.join(workspace, "notes.txt"), "uncommitted\n")

      log = capture_log(fn -> assert {:ok, ^ahead} = PrHead.sync(issue(), workspace, gh_runner: github(ahead)) end)

      assert head(workspace) == ahead
      assert git!(workspace, ["branch", "--show-current"]) == @branch
      assert log =~ "resetting the workspace to the pull request head API-1159 workspace=#{workspace} workspace_head=#{behind} pr_head=#{ahead}"
      assert git!(workspace, ["for-each-ref", "refs/symphony/orphaned"]) =~ "refs/symphony/orphaned/#{behind}"
    end

    test "leaves a workspace already on its pull request head as it is" do
      record_pull_request!()
      {workspace, behind, _ahead} = behind_workspace!()

      log = capture_log(fn -> assert {:ok, ^behind} = PrHead.sync(issue(), workspace, gh_runner: github(behind)) end)

      refute log =~ "resetting"
      assert head(workspace) == behind
    end

    test "has nothing to compare with for an SSH worker, a ticket with no open pull request, or a head with no branch" do
      {workspace, behind, ahead} = behind_workspace!()
      unused = fn args, _opts -> flunk("gh should not run: #{inspect(args)}") end

      assert :unknown = PrHead.sync(issue(), workspace, gh_runner: unused)
      record_pull_request!()
      assert :unknown = PrHead.sync(issue(), workspace, worker_host: "worker-01", gh_runner: unused)
      assert :unknown = PrHead.sync(issue(), workspace, gh_runner: github(ahead, 3, nil))
      assert head(workspace) == behind
    end

    test "judges the workspace as it is when GitHub can't be read" do
      record_pull_request!()
      {workspace, behind, _ahead} = behind_workspace!()

      log = capture_log(fn -> assert :unknown = PrHead.sync(issue(), workspace, []) end)

      assert log =~ "Could not read the pull request head of API-1159; judging the workspace as it is"
      assert head(workspace) == behind
    end

    test "reports a pull request head the workspace can't be put on" do
      record_pull_request!()
      {workspace, _behind, ahead} = behind_workspace!()

      capture_log(fn ->
        assert {:error, {:pr_head_reset_failed, {:fetch_failed, _status, _output}}} =
                 PrHead.sync(issue(), workspace, gh_runner: github(String.duplicate("b", 40)))

        assert {:error, {:pr_head_reset_failed, _checkout}} = PrHead.sync(issue(), workspace, gh_runner: github(ahead, 3, "bad..branch"))
      end)
    end

    test "fetches a pull request head the workspace doesn't have, and reports one origin lacks too" do
      origin = Path.join(System.tmp_dir!(), "pr-head-origin-#{System.unique_integer([:positive])}.git")
      on_exit(fn -> File.rm_rf(origin) end)
      {_output, 0} = System.cmd("git", ["init", "-q", "--bare", origin])

      record_pull_request!()
      {workspace, behind, _ahead} = behind_workspace!()
      git!(workspace, ["remote", "add", "origin", origin])
      git!(workspace, ["push", "-q", "origin", "#{behind}:refs/heads/#{@branch}"])

      # A person pushes from another clone; the workspace never fetched it.
      person = Path.join(System.tmp_dir!(), "pr-head-person-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(person) end)
      {_output, 0} = System.cmd("git", ["clone", "-q", "--branch", @branch, origin, person])
      pushed = commit!(person, "a person's push")
      git!(person, ["push", "-q", "origin", @branch])

      capture_log(fn -> assert {:ok, ^pushed} = PrHead.sync(issue(), workspace, gh_runner: github(pushed)) end)
      assert head(workspace) == pushed

      capture_log(fn ->
        assert {:error, {:pr_head_reset_failed, {:commit_missing, missing}}} =
                 PrHead.sync(issue(), workspace, gh_runner: github(String.duplicate("c", 40)))

        assert missing == String.duplicate("c", 40)
      end)
    end
  end

  describe "confirm_empty/2" do
    test "is empty only when GitHub lists no changed file, or there is no pull request to ask about" do
      assert :empty = PrHead.confirm_empty(nil, [])
      assert :empty = PrHead.confirm_empty(@pr_url, gh_runner: github("abc", 0))

      capture_log(fn ->
        assert {:error, {:pull_request_not_empty, 3, "abc"}} = PrHead.confirm_empty(@pr_url, gh_runner: github("abc", 3))
        assert {:error, {:pull_request_not_empty, nil, "abc"}} = PrHead.confirm_empty(@pr_url, gh_runner: github("abc", nil))
        assert {:error, {:pull_request_unreadable, {:gh_failed, _args, 1, _output}}} = PrHead.confirm_empty(@pr_url, [])
      end)
    end

    test "reads GitHub with gh itself when no runner is set" do
      runner = Application.get_env(:symphony_elixir, :pr_head_gh_runner)
      Application.delete_env(:symphony_elixir, :pr_head_gh_runner)
      on_exit(fn -> Application.put_env(:symphony_elixir, :pr_head_gh_runner, runner) end)

      # A link that names no pull request is refused before gh would run.
      capture_log(fn ->
        assert {:error, {:pull_request_unreadable, :invalid_pr_url}} = PrHead.confirm_empty("https://example.com/change", [])
      end)
    end
  end

  # TP-1144: a person pressed Update branch on a Merging ticket's pull request (rule R11), so the
  # ticket went back to Code Review. Its workspace had been removed when it left the active states,
  # and the one made again must hold the pushed head, which the reviewer then judges.
  describe "a person's push in Merging, then Code Review" do
    setup do
      test_root = Path.join(System.tmp_dir!(), "pr-head-r11-#{System.unique_integer([:positive])}")
      primary = Path.join(test_root, "primary")
      origin = Path.join(test_root, "origin.git")
      person = Path.join(test_root, "person")
      workflow_path = Path.join([test_root, "workflow", "WORKFLOW.md"])
      on_exit(fn -> File.rm_rf(test_root) end)

      File.mkdir_p!(primary)
      git!(primary, ["init", "-q", "-b", "main"])
      commit!(primary, "initial")
      {_output, 0} = System.cmd("git", ["init", "-q", "--bare", origin])
      git!(primary, ["remote", "add", "origin", origin])
      git!(primary, ["push", "-q", "origin", "main"])
      {_output, 0} = System.cmd("git", ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/main"])

      File.mkdir_p!(Path.dirname(workflow_path))
      File.write!(workflow_path, "---\n---\nprompt\n")

      File.write!(Workflow.symphony_file_path(), """
      issues:
        provider: memory
      workspaces:
        root: #{Path.join(test_root, "workspaces")}
      agent:
        runtime: codex
        command: codex app-server
      repositories:
        - key: #{@repo_key}
          base_branch: main
          workflow: #{workflow_path}
          route:
            team: Test
          workspace:
            strategy: worktree
            repo: #{primary}
            fetch_before_dispatch: true
      """)

      assert :ok = Config.validate!()

      # The ticket's run made its workspace, committed the work and pushed it.
      assert {:ok, workspace} = Workspace.create_for_issue(issue("In Progress"))
      commit!(workspace, "the ticket's work")
      git!(workspace, ["push", "-q", "origin", @branch])
      record_pull_request!()

      # Merging: the ticket left the active states, so its workspace was removed.
      assert :ok = Workspace.remove_issue_workspaces_checked(issue("Merging"))

      # The person's push.
      {_output, 0} = System.cmd("git", ["clone", "-q", "--branch", @branch, origin, person])
      pushed = commit!(person, "Merge main into the branch")
      git!(person, ["push", "-q", "origin", @branch])

      {:ok, settings} =
        Schema.parse(%{
          "tracker" => %{"kind" => "memory"},
          "review_agent" => %{"enabled" => true, "kind" => "codex", "command" => "codex app-server"}
        })

      %{pushed: pushed, settings: settings}
    end

    test "the workspace made again holds the pushed head, and the reviewer judges it", %{pushed: pushed, settings: settings} do
      capture_log(fn -> assert {:ok, _workspace} = Workspace.create_for_issue(issue()) end)
      workspace = Path.join([Config.settings!().workspace.root, @repo_key, "API-1159"])
      assert head(workspace) == pushed

      assert :ok =
               CodeReview.run(issue(), workspace,
                 settings: settings,
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker,
                 qa_policy: FakeQaPolicy,
                 gh_runner: github(pushed)
               )

      assert_received {:reviewed, @issue_id, ^pushed}
      assert [%{outcome: "approve", head_sha: ^pushed}] = Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end
  end
end
