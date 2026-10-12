defmodule SymphonyElixir.QaPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaPolicy

  @workspace "/tmp/qa-policy-workspace"
  @sha "feedface00112233445566778899aabbccddeeff"

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"}, extra))

    settings
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-qa-policy",
        identifier: "TP-816",
        title: "Land the QA state",
        state: "QA",
        labels: []
      },
      attrs
    )
  end

  # The git runner shape `changed_paths/4` drives: a merge base, then the changed paths.
  defp git(paths, base \\ "main", sha \\ @sha, output \\ nil) do
    fn
      ["merge-base", "origin/" <> ^base, ^sha], @workspace ->
        {"base123\n", 0}

      ["diff", "--name-only", "base123", ^sha], @workspace ->
        {output || Enum.join(paths, "\n") <> "\n", 0}
    end
  end

  describe "changed_paths/4" do
    test "lists the paths the sha changes against the base's merge base" do
      opts = [git: git(["docs/configuration.md", "lib/symphony_elixir/cli.ex"])]

      assert {:ok, ["docs/configuration.md", "lib/symphony_elixir/cli.ex"]} =
               QaPolicy.changed_paths(@workspace, "repo", @sha, opts)
    end

    test "resolves the base branch from the repo's config" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: "branched-repo", workflow: Workflow.workflow_file_path(), team: "Test", base_branch: "develop"]]
      )

      opts = [git: git([], "develop")]

      assert {:ok, []} = QaPolicy.changed_paths(@workspace, "branched-repo", @sha, opts)
    end

    test "a failing git call is an error, not an empty change" do
      failing = fn _args, _cwd -> {"fatal: not a git repository\n", 128} end

      assert {:error, {:git_failed, 128, "fatal: not a git repository\n"}} =
               QaPolicy.changed_paths(@workspace, "repo", @sha, git: failing)
    end
  end

  describe "decide/3" do
    test "runs QA on a change that delivers a user journey" do
      settings = settings!()

      assert {:run, [%{kind: "cli"}], "the change delivers or updates a user journey"} =
               QaPolicy.decide(issue(), settings,
                 workspace: @workspace,
                 repo_key: "repo",
                 git: git(["lib/symphony_elixir/cli.ex"]),
                 sha: @sha
               )
    end

    test "binds the decision to the head SHA it is asked about" do
      other_sha = "0123456789abcdef0123456789abcdef01234567"

      assert {:run, _playbooks, _reason} =
               QaPolicy.decide(issue(), settings!(),
                 workspace: @workspace,
                 repo_key: "repo",
                 git: git(["lib/symphony_elixir/cli.ex"], "main", other_sha),
                 sha: other_sha
               )
    end

    test "defaults to HEAD when no sha is given" do
      head_git = fn
        ["merge-base", "origin/main", "HEAD"], @workspace -> {"base123\n", 0}
        ["diff", "--name-only", "base123", "HEAD"], @workspace -> {"lib/symphony_elixir/cli.ex\n", 0}
      end

      assert {:run, _playbooks, _reason} =
               QaPolicy.decide(issue(), settings!(), workspace: @workspace, repo_key: "repo", git: head_git)
    end

    test "skips QA on a docs-only change, with the reason recorded" do
      assert {:skip, reason} =
               QaPolicy.decide(issue(), settings!(),
                 workspace: @workspace,
                 repo_key: "repo",
                 git: git(["docs/configuration.md", "README.md"]),
                 sha: @sha
               )

      assert reason =~ "only changes docs, tests or `auto_review.skip_globs`"
    end

    test "runs QA when the changed paths cannot be read, rather than skipping it" do
      # A broken read must never smuggle a change past verification.
      failing = fn _args, _cwd -> {"fatal: bad revision\n", 128} end

      assert {:run, playbooks, reason} =
               QaPolicy.decide(issue(), settings!(),
                 workspace: @workspace,
                 repo_key: "repo",
                 git: failing,
                 sha: @sha
               )

      assert reason == "the changed paths could not be read (git exited 128: fatal: bad revision)"
      assert Enum.map(playbooks, & &1.kind) == Enum.map(QaPolicy.enabled_playbooks(settings!()), & &1.kind)
    end

    test "a git failure with no output names only the status" do
      failing = fn _args, _cwd -> {"", 1} end

      assert {:run, _playbooks, "the changed paths could not be read (git exited 1)"} =
               QaPolicy.decide(issue(), settings!(),
                 workspace: @workspace,
                 repo_key: "repo",
                 git: failing,
                 sha: @sha
               )
    end

    test "takes the repo key from the issue when none is given" do
      assert {:run, _playbooks, _reason} =
               QaPolicy.decide(issue(%{repo_key: "repo"}), settings!(),
                 workspace: @workspace,
                 git: git(["lib/symphony_elixir/cli.ex"]),
                 sha: @sha
               )
    end
  end

  describe "decision/3" do
    test "runs the playbooks the changed paths trigger" do
      assert {:run, [%{kind: "cli"}], "the change delivers or updates a user journey"} =
               QaPolicy.decision(issue(), settings!(), ["lib/symphony_elixir/cli.ex"])
    end

    test "skips a change that reaches no playbook" do
      assert {:skip, reason} = QaPolicy.decision(issue(), settings!(), ["lib/symphony_elixir/orchestrator.ex"])
      assert reason =~ "no QA playbook applies"
    end

    test "the ticket's own `qa:skip` label skips QA whatever the diff is" do
      assert {:skip, "the issue has the `qa:skip` label"} =
               QaPolicy.decision(issue(%{labels: ["qa:skip"]}), settings!(), ["lib/symphony_elixir/cli.ex"])
    end
  end

  describe "enabled_playbooks/1" do
    test "is every playbook the repo's config leaves on" do
      kinds = settings!() |> QaPolicy.enabled_playbooks() |> Enum.map(& &1.kind)

      assert "cli" in kinds
      # The web playbook is on only when a dev server is configured.
      refute "web" in kinds
    end
  end
end
