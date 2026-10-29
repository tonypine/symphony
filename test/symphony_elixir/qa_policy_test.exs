defmodule SymphonyElixir.QaPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaPolicy

  @workspace "/tmp/qa-policy-workspace"
  @sha "feedface00112233445566778899aabbccddeeff"

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))

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

    test "a head that changes nothing against the merge base has nothing to verify" do
      assert {:nothing_to_verify, _reason} =
               QaPolicy.decide(issue(), settings!(), workspace: @workspace, repo_key: "repo", git: git([], "main", @sha, ""), sha: @sha)
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

    # A `qa:macos_app` label on a change no selected playbook's paths reach, with no walkthrough:
    # there is nothing on screen to judge, so building and launching the app are the whole check.
    test "scopes a macos_app pass with nothing on screen to judge to building and launching the app" do
      settings = settings!(%{"auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}}}})
      backend = ["lib/symphony_elixir/orchestrator.ex"]

      assert {:run, [%{kind: "macos_app", scope: :none}], reason} = QaPolicy.decision(issue(%{labels: ["qa:macos_app"]}), settings, backend)
      assert reason =~ "nothing on screen to judge: the PR changes none of the selected playbooks' paths"
      assert reason =~ "building and launching the app are the whole check"

      # Only the app's playbook is scoped; another selected one runs as it would.
      assert {:run, [%{kind: "cli"} = cli, %{kind: "macos_app", scope: :none}], _reason} =
               QaPolicy.decision(issue(%{labels: ["qa:cli", "qa:macos_app"]}), settings, backend)

      refute Map.has_key?(cli, :scope)

      # A path a selected playbook triggers on, a walkthrough, or no app to build: the pass judges as before.
      walkthrough = issue(%{labels: ["qa:macos_app"], description: "## User walkthrough\n\n1. Open the app.\n"})

      for {ticket, paths} <- [
            {issue(%{labels: ["qa:macos_app"]}), ["macos/Sources/App/Window.swift"]},
            {walkthrough, backend},
            {issue(%{labels: ["qa:cli"]}), backend}
          ] do
        assert {:run, playbooks, "the change delivers or updates a user journey"} = QaPolicy.decision(ticket, settings, paths)
        refute Enum.any?(playbooks, &Map.has_key?(&1, :scope))
      end
    end

    test "skips a change that reaches no playbook" do
      assert {:skip, reason} = QaPolicy.decision(issue(), settings!(), ["lib/symphony_elixir/orchestrator.ex"])
      assert reason =~ "no QA playbook applies"
    end

    test "the ticket's own `qa:skip` label skips QA whatever the diff is" do
      assert {:skip, "the issue has the `qa:skip` label"} =
               QaPolicy.decision(issue(%{labels: ["qa:skip"]}), settings!(), ["lib/symphony_elixir/cli.ex"])
    end

    # An empty diff is no change at all (a workspace built from the base branch), never a docs-only
    # one: nothing may skip it into Merging, not even a label.
    test "no changed path is nothing to verify, whatever the labels say" do
      assert {:nothing_to_verify, "the head changes no files against its base branch"} = QaPolicy.decision(issue(), settings!(), [])

      for label <- ["qa:skip", "qa:cli"] do
        assert {:nothing_to_verify, _reason} = QaPolicy.decision(issue(%{labels: [label]}), settings!(), [])
      end
    end
  end

  describe "the QA selection log line" do
    test "names the playbooks it runs and why each other one does not, with the flag each reads" do
      # A Mac app repo: verification off, its dev server run on the QA host beside the app.
      settings =
        settings!(%{
          "verification" => %{"enabled" => false, "dev_server" => %{"start_cmd" => "server/scripts/dev-server.sh", "health_check_url" => "http://127.0.0.1:8090/health"}},
          "auto_review" => %{
            "worker_host" => "qa-vm",
            "playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/App.app", "dev_server" => true}}
          }
        })

      log =
        capture_log(fn ->
          assert {:run, [%{kind: "cli"}], _reason} =
                   QaPolicy.decide(issue(), settings, workspace: @workspace, repo_key: "repo", git: git(["lib/symphony_elixir/cli.ex"]), sha: @sha)
        end)

      assert log =~
               "QA selection issue_id=issue-qa-policy issue_identifier=TP-816 sha=#{@sha} decision=run playbooks=cli " <>
                 ~s(not_selected="macos_app: not triggered; android_app: needs)

      assert log =~ ~s(web: needs `verification.enabled`")

      log =
        capture_log(fn ->
          assert {:skip, _reason} =
                   QaPolicy.decide(issue(), settings!(), workspace: @workspace, repo_key: "repo", git: git(["docs/a.md"]), sha: @sha)
        end)

      assert log =~ ~s(decision=skip reason="the PR only changes docs)
      assert log =~ ~s(playbooks= not_selected="cli: not triggered; macos_app: needs)
      assert log =~ ~s(web: needs `verification.dev_server`")
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

  describe "unselected_playbooks/2" do
    test "names the enabled playbooks a run did not select, such as the app's on a server-only diff" do
      settings = settings!(%{"auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/Hub.app"}}}})
      [cli | _rest] = QaPolicy.enabled_playbooks(settings)

      assert QaPolicy.unselected_playbooks(settings, [cli]) == ["macos_app"]
      assert QaPolicy.unselected_playbooks(settings, QaPolicy.enabled_playbooks(settings)) == []
    end
  end
end
