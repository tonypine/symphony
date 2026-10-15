defmodule SymphonyElixir.PrRunTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrRun

  test "resolves a same-repo pull request into a PR-shaped issue" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      gh_runner = fn
        ["pr", "view", "123", "--repo", "example/repo", "--json", _fields], _opts ->
          {Jason.encode!(%{
             "number" => 123,
             "state" => "OPEN",
             "title" => "Fix CI",
             "body" => "Build is red",
             "url" => "https://github.com/example/repo/pull/123",
             "headRefName" => "feature/fix-ci",
             "baseRefName" => "main",
             "headRepository" => %{"nameWithOwner" => "example/repo"}
           }), 0}
      end

      assert {:ok, %{issue: issue, repo_key: "default"}} =
               PrRun.resolve("123", intent: "fix failing checks", gh_runner: gh_runner)

      assert issue.id == "pr:default:123"
      assert issue.identifier == "PR-123"
      assert issue.run_kind == :pr
      assert SymphonyElixir.TicketPullRequest.current_url(issue) == "https://github.com/example/repo/pull/123"
      assert issue.workspace_branch == "feature/fix-ci"
      assert issue.workspace_base_ref == "origin/feature/fix-ci"
      assert issue.pr_context.intent == "fix failing checks"
    after
      File.rm_rf(root)
    end
  end

  test "resolves same-repo pull requests from configured enterprise origins" do
    {root, primary_repo} = init_primary_repo!(origin: "git@github.a8c.com:Automattic/symphony.git")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        github: %{enterprise_hosts: ["github.a8c.com"]}
      )

      gh_runner = fn
        ["pr", "view", "123", "--repo", "github.a8c.com/Automattic/symphony", "--json", _fields], _opts ->
          {Jason.encode!(
             valid_pr(%{
               "url" => "https://github.a8c.com/Automattic/symphony/pull/123",
               "headRepository" => %{"nameWithOwner" => "Automattic/symphony"}
             })
           ), 0}
      end

      assert {:ok, %{issue: issue, repo_key: "default"}} =
               PrRun.resolve("123", intent: "fix failing checks", gh_runner: gh_runner)

      assert SymphonyElixir.TicketPullRequest.current_url(issue) == "https://github.a8c.com/Automattic/symphony/pull/123"
      assert issue.workspace_branch == "feature/fix-ci"
    after
      File.rm_rf(root)
    end
  end

  test "rejects unconfigured enterprise origins" do
    {root, primary_repo} = init_primary_repo!(origin: "git@github.a8c.com:Automattic/symphony.git")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      assert {:error, :missing_github_origin_repo} = PrRun.resolve("123", gh_runner: fn _args, _opts -> flunk("unexpected gh call") end)
    after
      File.rm_rf(root)
    end
  end

  test "rejects invalid targets before configuration lookup" do
    assert {:error, :invalid_pr_target} = PrRun.resolve(123)
  end

  test "requires a configured primary workspace repository" do
    assert {:error, :missing_workspace_repo} = PrRun.resolve("123")
  end

  test "requires a github origin remote" do
    root = Path.join(System.tmp_dir!(), "symphony-pr-run-no-origin-#{System.unique_integer([:positive])}")
    primary_repo = Path.join(root, "primary")

    try do
      File.mkdir_p!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      assert {:error, :missing_github_origin_repo} = PrRun.resolve("123")
    after
      File.rm_rf(root)
    end
  end

  test "returns gh runner failures" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      gh_runner = fn ["pr", "view", "123", "--repo", "example/repo", "--json", _fields], _opts -> {"nope", 1} end

      assert {:error, {:gh_failed, _args, 1, "nope"}} = PrRun.resolve("123", gh_runner: gh_runner)
    after
      File.rm_rf(root)
    end
  end

  test "rejects malformed pr payloads" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      assert {:error, {:invalid_pull_request_payload, _message}} =
               PrRun.resolve("123", gh_runner: pr_json_runner("{"))

      assert {:error, :invalid_pull_request_payload} =
               PrRun.resolve("123", gh_runner: pr_json_runner("[]"))
    after
      File.rm_rf(root)
    end
  end

  test "rejects cross-repo pull requests" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      pr = valid_pr(%{"headRepository" => %{"nameWithOwner" => "elsewhere/repo"}})

      assert {:error, {:unsupported_cross_repo_pr, "elsewhere/repo", "example/repo"}} =
               PrRun.resolve("123", gh_runner: pr_payload_runner(pr))
    after
      File.rm_rf(root)
    end
  end

  test "treats null or missing headRepository as cross-repo without crashing" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      for head_repo <- [nil, %{}, %{"nameWithOwner" => nil}] do
        pr = valid_pr() |> Map.put("headRepository", head_repo)

        assert {:error, {:unsupported_cross_repo_pr, nil, "example/repo"}} =
                 PrRun.resolve("123", gh_runner: pr_payload_runner(pr))
      end

      pr_without_key = Map.delete(valid_pr(), "headRepository")

      assert {:error, {:unsupported_cross_repo_pr, nil, "example/repo"}} =
               PrRun.resolve("123", gh_runner: pr_payload_runner(pr_without_key))
    after
      File.rm_rf(root)
    end
  end

  test "requires essential pull request fields" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      assert {:error, {:missing_pr_field, "number"}} =
               PrRun.resolve("123", gh_runner: pr_payload_runner(Map.delete(valid_pr(), "number")))

      assert {:error, {:missing_pr_field, "url"}} =
               PrRun.resolve("123", gh_runner: pr_payload_runner(Map.put(valid_pr(), "url", " ")))

      assert {:error, {:missing_pr_field, "headRefName"}} =
               PrRun.resolve("123", gh_runner: pr_payload_runner(Map.delete(valid_pr(), "headRefName")))
    after
      File.rm_rf(root)
    end
  end

  test "uses defaults for optional pull request fields and blank intent" do
    {root, primary_repo} = init_primary_repo!()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      pr =
        valid_pr(%{
          "title" => " ",
          "body" => nil,
          "state" => nil,
          "baseRefName" => nil
        })

      assert {:ok, %{issue: issue}} = PrRun.resolve("123", intent: " ", gh_runner: pr_payload_runner(pr))
      assert issue.title == "Pull request #123"
      assert issue.description == ""
      assert issue.intent == "make progress on this pull request"
      assert issue.pr_context.base_ref == nil
      assert issue.pr_context.state == nil

      assert {:ok, %{issue: default_intent_issue}} = PrRun.resolve("123", gh_runner: pr_payload_runner(valid_pr()))
      assert default_intent_issue.intent == "make progress on this pull request"
    after
      File.rm_rf(root)
    end
  end

  defp init_primary_repo!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-pr-run-test-#{System.unique_integer([:positive])}")
    primary_repo = Path.join(root, "primary")
    origin = Keyword.get(opts, :origin, "git@github.com:example/repo.git")

    File.mkdir_p!(primary_repo)
    git!(primary_repo, ["init", "-b", "main"])
    git!(primary_repo, ["remote", "add", "origin", origin])

    {root, primary_repo}
  end

  defp pr_json_runner(json) do
    fn ["pr", "view", "123", "--repo", "example/repo", "--json", _fields], _opts -> {json, 0} end
  end

  defp pr_payload_runner(pr) do
    pr
    |> Jason.encode!()
    |> pr_json_runner()
  end

  defp valid_pr(overrides \\ %{}) do
    Map.merge(
      %{
        "number" => 123,
        "state" => "OPEN",
        "title" => "Fix CI",
        "body" => "Build is red",
        "url" => "https://github.com/example/repo/pull/123",
        "headRefName" => "feature/fix-ci",
        "baseRefName" => "main",
        "headRepository" => %{"nameWithOwner" => "example/repo"}
      },
      overrides
    )
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    output
  end
end
