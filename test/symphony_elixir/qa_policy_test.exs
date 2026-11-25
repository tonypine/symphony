defmodule SymphonyElixir.QaPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.RepoWorkflowSchema
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaPolicy
  alias SymphonyElixir.Workflow

  @workspace "/tmp/qa-policy-workspace"
  @sha "feedface00112233445566778899aabbccddeeff"

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))

    settings
  end

  # A macos_app playbook whose project server runs on live passes, and no `cli` one beside it.
  defp live_settings!(dev_server) do
    macos_app = %{"build" => "make", "app" => "A.app", "paths" => ["macos/**"]}

    settings!(%{
      "verification" => %{"dev_server" => Map.merge(%{"health_check_url" => "http://127.0.0.1:8090/api/v1/state", "runs" => "live_qa_pass"}, dev_server)},
      "auto_review" => %{"playbooks" => %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}}
    })
  end

  defp kinds({:run, playbooks, reason}), do: {:run, Enum.map(playbooks, & &1.kind), reason}

  @live_setting %{source: "live", page: "Home", window: %{width: 1440, height: 900}, appearance: "light"}
  @fixture_setting %{source: "fixture", fixture: "macos/Tests/Fixtures/director-app", page: "Inbox", window: %{width: 2560, height: 1440}, appearance: "dark"}

  defp qa_check(id, statement, setting) do
    check = %{id: id, kind: "qa", statement: statement, proof: "qa", action: "Open it", expect: "It shows"}
    if setting, do: Map.put(check, :setting, setting), else: check
  end

  # The test's issue, groomed afresh with a plan holding an outcome and `checks`.
  defp groomed!(checks) do
    :ok = RunStore.clear()
    ticket = issue()
    :ok = RunStore.put_ticket_state(%{repo_key: "repo-a", issue_id: ticket.id, issue_identifier: ticket.identifier})
    outcome = %{id: "c1", kind: "outcome", statement: "The decision is stored.", proof: "test"}
    size = %{tokens: 1, runs: 1}
    plan = %{reason: "Grooming", by: "grooming", shape: "single", layers: ["engine"], summary: "s", text: "t", checks: [outcome | checks], size: size}
    {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan)
    ticket
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

    test "reads the change with git itself by default" do
      dir = Path.join(System.tmp_dir!(), "qa-policy-no-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, {:git_failed, status, _output}} = QaPolicy.changed_paths(dir, "repo", @sha, [])
      assert status != 0
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

    test "a groomed ticket whose plan's layers hold the screen or the Gallery always has something on screen" do
      :ok = RunStore.clear()
      settings = settings!(%{"auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}}}})
      backend = ["lib/symphony_elixir/orchestrator.ex"]
      ticket = issue(%{labels: ["qa:macos_app"]})
      :ok = RunStore.put_ticket_state(%{repo_key: "repo-a", issue_id: ticket.id, issue_identifier: ticket.identifier})

      plan = fn layers, checks ->
        %{
          reason: "Grooming",
          by: "grooming",
          shape: "single",
          layers: layers,
          summary: "The Director shows the decision.",
          text: "Draw the decision in the Director.",
          checks: checks,
          size: %{tokens: 100_000, runs: 1}
        }
      end

      outcome = %{id: "c1", kind: "outcome", statement: "The decision is stored.", proof: "test"}
      walk = %{id: "c2", kind: "qa", statement: "The Director shows it.", proof: "qa", action: "Open it", expect: "It shows"}

      # Layers that are not on screen, and no QA check: today's diff-based policy decides.
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan.(["engine"], [outcome]))
      assert {:run, [%{kind: "macos_app", scope: :none}], _reason} = QaPolicy.decision(ticket, settings, backend)

      for layers <- [["screen"], ["engine", "gallery"]] do
        {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan.(layers, [outcome]))
        assert {:run, [playbook], "the change delivers or updates a user journey"} = QaPolicy.decision(ticket, settings, backend)
        refute Map.has_key?(playbook, :scope)
      end

      # A QA check is something to walk, as a `## User walkthrough` is.
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan.(["engine"], [outcome, walk]))
      assert {:run, [playbook], "the change delivers or updates a user journey"} = QaPolicy.decision(ticket, settings, backend)
      refute Map.has_key?(playbook, :scope)
    end

    test "a groomed ticket with an open check only QA proves is never skipped, by a label or by a docs-only diff" do
      :ok = RunStore.clear()
      settings = settings!(%{"auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}}}})
      docs = ["docs/configuration.md"]
      ticket = issue(%{labels: ["qa:skip"]})
      :ok = RunStore.put_ticket_state(%{repo_key: "repo-a", issue_id: ticket.id, issue_identifier: ticket.identifier})

      plan = fn checks ->
        size = %{tokens: 1, runs: 1}
        %{reason: "Grooming", by: "grooming", shape: "single", layers: ["docs"], summary: "s", text: "t", checks: checks, size: size}
      end

      outcome = %{kind: "outcome", statement: "The page reads well.", proof: "test"}
      seen = %{kind: "outcome", statement: "The Director shows the decision.", proof: "qa"}
      designed = %{kind: "evidence", statement: "It matches the design.", proof: "design"}

      # Nothing QA owes: the label and the diff skip it as they did.
      {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan.([outcome]))
      assert {:skip, "the issue has the `qa:skip` label"} = QaPolicy.decision(ticket, settings, docs)

      {:ok, _plan} = SymphonyElixir.TicketPlan.write("repo-a", ticket.id, plan.([Map.put(outcome, :id, "c1"), seen, designed]))
      assert {:run, playbooks, reason} = QaPolicy.decision(ticket, settings, docs)
      assert "macos_app" in Enum.map(playbooks, & &1.kind)
      assert reason =~ "the plan has open checks only QA proves (c2, c3), so QA is not skipped though the issue has the `qa:skip` label"
      assert {:run, [_ | _], docs_reason} = QaPolicy.decision(%{ticket | labels: []}, settings, docs)
      assert docs_reason =~ "though the PR only changes docs, tests"

      # With no playbook on nothing can run it, and once QA proved them the skip stands again.
      none = settings!(%{"auto_review" => %{"playbooks" => %{"cli" => %{"enabled" => false}}}})
      assert {:skip, _reason} = QaPolicy.decision(ticket, none, docs)
      for id <- ["c2", "c3"], do: {:ok, _proved} = SymphonyElixir.TicketChecks.prove("repo-a", ticket.id, %{check_id: id, by: "qa"})
      assert {:skip, "the issue has the `qa:skip` label"} = QaPolicy.decision(ticket, settings, docs)
    end

    test "marks a macos_app pass live when the plan sets a QA check QA walks on the live server, whatever its words" do
      settings = live_settings!(%{"start_cmd" => "scripts/qa-server-start.sh"})
      ticket = groomed!([qa_check("c2", "The Home screen shows the moved ticket.", @live_setting)])

      for paths <- [["macos/Sources/Inbox.swift"], ["lib/symphony_elixir/questions.ex"], ["priv/other.txt", "macos/Sources/Inbox.swift"]] do
        assert {:run, [%{kind: "macos_app", live: true, live_reason: "the plan's QA check c2 is set to the live server"}], reason} =
                 QaPolicy.decision(ticket, settings, paths)

        assert reason =~ "; the app gets a live server: the plan's QA check c2 is set to the live server"
      end
    end

    test "no word in a step makes a pass live: QA checks set to a fixture, and a ticket with no plan, read fixtures only" do
      settings = live_settings!(%{"start_cmd" => "scripts/qa-server-start.sh"})
      server_and_app = ["lib/symphony_elixir/questions.ex", "macos/Sources/Inbox.swift"]
      ticket = groomed!([qa_check("c2", "In the Director's Inbox, press Decide, then Undo.", @fixture_setting)])

      assert {:run, [macos_app], reason} = QaPolicy.decision(ticket, settings, server_and_app)
      refute Map.has_key?(macos_app, :live)
      assert macos_app.live_reason == "no QA check of the plan that QA walks is set to the live server"
      assert reason =~ "; the app reads fixtures only: no QA check of the plan that QA walks is set to the live server"

      :ok = RunStore.clear()
      director = issue(%{description: "## User walkthrough\n\n1. In the Director's Inbox, press Decide.\n"})
      assert {:run, [macos_app], _reason} = QaPolicy.decision(director, settings, server_and_app)
      refute Map.has_key?(macos_app, :live)
      assert macos_app.live_reason == "the ticket has no plan, so no QA check is set to the live server"

      # A server-only change gives the Mac app nothing to walk without the plan asking for the server.
      assert {:skip, _reason} = QaPolicy.decision(director, settings, ["lib/symphony_elixir/questions.ex"])
    end

    test "a live QA check QA no longer walks, and a plan whose QA checks carry no setting, read fixtures only" do
      settings = live_settings!(%{"start_cmd" => "start"})
      app = ["macos/Sources/Inbox.swift"]

      ticket = groomed!([qa_check("c2", "The Home screen moves.", @live_setting)])
      assert {:run, [%{live: true}], _reason} = QaPolicy.decision(ticket, settings, app)
      {:ok, _event} = SymphonyElixir.TicketChecks.prove("repo-a", ticket.id, %{check_id: "c2", by: "test", test: "test/home_test.exs"})
      assert {:run, [macos_app], _reason} = QaPolicy.decision(ticket, settings, app)
      refute Map.has_key?(macos_app, :live)

      ticket = groomed!([qa_check("c2", "The Home screen moves.", @live_setting)])
      {:ok, _event} = SymphonyElixir.TicketChecks.waive("repo-a", ticket.id, "c2", "Covered elsewhere.")
      assert {:run, [macos_app], _reason} = QaPolicy.decision(ticket, settings, app)
      refute Map.has_key?(macos_app, :live)

      # A plan written before settings still gets its QA pass, on fixtures only.
      ticket = groomed!([qa_check("c2", "The Director shows the decision.", nil)])
      assert {:run, [macos_app], "the change delivers or updates a user journey" <> note} = QaPolicy.decision(ticket, settings, app)
      refute Map.has_key?(macos_app, :live)
      assert note == "; the app reads fixtures only: no QA check of the plan that QA walks is set to the live server"
    end

    test "the labels override the plan: qa:fixture wins over qa:live" do
      settings = live_settings!(%{"start_cmd" => "start"})

      assert {:run, [%{live: true, live_reason: "the issue has the `qa:live` label"}], reason} =
               QaPolicy.decision(issue(%{labels: ["QA:Live"]}), settings, ["macos/Sources/Inbox.swift"])

      assert reason =~ "the issue has the `qa:live` label"

      ticket = groomed!([qa_check("c2", "The Home screen moves.", @live_setting)])
      assert {:run, [macos_app], reason} = QaPolicy.decision(%{ticket | labels: ["qa:live", "qa:fixture"]}, settings, ["macos/Sources/Inbox.swift"])
      refute Map.has_key?(macos_app, :live)
      assert macos_app.live_reason == "the issue has the `qa:fixture` label"
      assert reason =~ "the issue has the `qa:fixture` label"
    end

    test "a macos_app playbook with no live server is never live, and says so when the plan asks for one" do
      settings = settings!(%{"auto_review" => %{"playbooks" => %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make", "app" => "A.app"}}}})
      ticket = groomed!([qa_check("c2", "The Home screen moves.", @live_setting)])

      assert {:run, [macos_app], reason} = QaPolicy.decision(ticket, settings, ["macos/Sources/Inbox.swift"])
      refute Map.has_key?(macos_app, :live)

      assert macos_app.live_reason ==
               "the project's server does not run on live passes (`verification.dev_server.runs: live_qa_pass`), though the plan's QA check c2 is set to the live server"

      assert reason =~ "; the app reads fixtures only: the project's server does not run on live passes"

      :ok = RunStore.clear()
      assert {:run, [macos_app], "the change delivers or updates a user journey"} = QaPolicy.decision(issue(), settings, ["macos/Sources/Inbox.swift"])
      refute Map.has_key?(macos_app, :live_reason)
    end

    test "Symphony's own WORKFLOW.md still loads, and its live server runs only when the plan asks for it" do
      assert {:ok, %{config: config}} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))
      assert {:ok, _workflow} = RepoWorkflowSchema.parse(config)
      own = get_in(config, ["auto_review", "playbooks", "macos_app"])
      assert own["requires"] == ["mise"]

      # The operator's symphony.yml names the build and the app; the repository adds the rest.
      macos_app = Map.merge(%{"build" => "make -C macos qa-app", "app" => "macos/build/Symphony.app"}, own)
      assert config["verification"]["dev_server"]["runs"] == "live_qa_pass"

      settings =
        settings!(%{
          "verification" => config["verification"],
          "auto_review" => %{"playbooks" => %{"cli" => %{"enabled" => false}, "macos_app" => macos_app}}
        })

      macos = fn {:run, playbooks, _reason} -> Enum.find(playbooks, &(&1.kind == "macos_app")) end
      both = ["lib/symphony_elixir/questions.ex", "macos/Sources/SymphonyBar/InboxView.swift"]

      # A Director walkthrough and a server change, with no plan: fixtures only.
      :ok = RunStore.clear()
      director = issue(%{description: "## User walkthrough\n\n1. In the Director's Inbox, press Decide, then Undo.\n"})
      held = macos.(QaPolicy.decision(director, settings, both))
      refute Map.has_key?(held, :live)
      assert held.live_reason == "the ticket has no plan, so no QA check is set to the live server"

      # A plan that sets its QA check on the live server: the live server, on a Mac-only diff too.
      ticket = groomed!([qa_check("c2", "The Home screen moves.", @live_setting)])
      assert %{live: true} = macos.(QaPolicy.decision(ticket, settings, ["macos/Sources/SymphonyBar/InboxView.swift"]))
    end

    test "a pass with nothing on screen to judge says it reads fixtures only, and why" do
      settings = live_settings!(%{"start_cmd" => "start", "paths" => ["lib/**"]})
      :ok = RunStore.clear()

      assert {:run, [%{kind: "macos_app", scope: :none}], reason} = QaPolicy.decision(issue(%{labels: ["qa:macos_app"]}), settings, ["lib/a.ex"])

      assert reason =~
               "building and launching the app are the whole check; the app reads fixtures only: the ticket has no plan, so no QA check is set to the live server"
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
          "verification" => %{
            "enabled" => false,
            "dev_server" => %{"start_cmd" => "server/scripts/dev-server.sh", "health_check_url" => "http://127.0.0.1:8090/health", "runs" => "every_qa_pass"}
          },
          "auto_review" => %{
            "worker_host" => "qa-vm",
            "playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/App.app"}}
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
