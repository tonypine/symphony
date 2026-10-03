defmodule SymphonyElixir.QaAgentTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.QaAgent.{Report, Selection}

  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule FakeSession do
    def start_session(workspace, opts) do
      send(recipient(), {:qa_session_started, workspace, opts})

      case Application.get_env(:symphony_elixir, :qa_test_start_result) do
        nil -> {:ok, %{workspace: workspace}}
        result -> result
      end
    end

    def run_turn(session, prompt, issue, opts) do
      send(recipient(), {:qa_turn, session, prompt, issue, opts})
      on_message = Keyword.fetch!(opts, :on_message)
      Enum.each(Application.get_env(:symphony_elixir, :qa_test_messages, []), on_message)
      Application.get_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: pass_json()}})
    end

    def stop_session(session) do
      send(recipient(), {:qa_session_stopped, session})
      :ok
    end

    def pass_json do
      Jason.encode!(%{
        verdict: "pass",
        summary: "The CLI behaves as described.",
        steps: [%{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}]
      })
    end

    defp recipient, do: Application.fetch_env!(:symphony_elixir, :qa_test_recipient)
  end

  setup do
    Application.put_env(:symphony_elixir, :qa_test_recipient, self())

    on_exit(fn ->
      for key <- [:qa_test_recipient, :qa_test_start_result, :qa_test_messages, :qa_test_turn_result] do
        Application.delete_env(:symphony_elixir, key)
      end
    end)

    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-qa",
        identifier: "TP-900",
        title: "Add a check command",
        description: "Adds `symphony check`.",
        state: "Auto Review",
        labels: []
      },
      attrs
    )
  end

  defp playbooks, do: Selection.playbooks(%{playbooks: %{}})

  defp job(attrs \\ %{}) do
    Map.merge(
      %{
        issue: issue(),
        sha: @sha,
        workspace_path: Path.join(System.tmp_dir!(), "qa-agent-test-workspace"),
        worker_host: nil,
        repo_key: "default",
        run_id: "qa-run-1",
        playbooks: playbooks(),
        token_limit: nil
      },
      attrs
    )
  end

  # Records each git call and creates the worktree directory on `worktree add`.
  defp fake_git(overrides \\ %{}) do
    recipient = self()

    fn args, cwd ->
      send(recipient, {:git, args, cwd})

      case {args, overrides} do
        {["worktree", "add", "--detach", path, _sha], %{add: result}} ->
          File.mkdir_p!(path)
          result

        {["worktree", "add", "--detach", path, _sha], _overrides} ->
          File.mkdir_p!(path)
          {"", 0}

        {["cat-file" | _rest], %{cat_file: result}} ->
          result

        {["fetch" | _rest], %{fetch: result}} ->
          result

        _other ->
          {"", 0}
      end
    end
  end

  describe "Selection.decide/3" do
    test "skips an internal lib refactor with no walkthrough or entry-point change" do
      assert {:skip, reason} =
               Selection.decide(issue(), ["lib/symphony_elixir/orchestrator.ex", "lib/symphony_elixir/run_store.ex"], %{playbooks: %{}})

      assert reason =~ "no QA playbook applies"
    end

    test "skips docs-only and test-only changes, including configured skip globs" do
      assert {:skip, reason} = Selection.decide(issue(), ["README.md", "docs/configuration.md", "test/foo_test.exs"], %{})
      assert reason =~ "only changes docs, tests"

      assert {:skip, _reason} = Selection.decide(issue(), ["priv/static/app.css"], %{skip_globs: ["priv/static/**"]})
      assert {:skip, "the PR changes no files"} = Selection.decide(issue(), [], %{})
    end

    test "selects the cli playbook for entry points and for a user walkthrough" do
      for path <- ["bin/symphony", "lib/symphony_elixir/cli.ex", "lib/mix/tasks/symphony.init.ex"] do
        assert {:run, [%{kind: "cli", prompt: prompt}]} = Selection.decide(issue(), [path], %{playbooks: %{}})
        assert prompt =~ "### Playbook: cli"
      end

      walkthrough = issue(%{description: "Intro\n\n## User walkthrough\n\n1. Run `symphony check`."})
      assert Selection.user_walkthrough?(walkthrough)
      refute Selection.user_walkthrough?(issue(%{description: nil}))
      assert {:run, [%{kind: "cli"}]} = Selection.decide(walkthrough, ["lib/symphony_elixir/orchestrator.ex"], %{})
    end

    test "labels skip QA or force a playbook" do
      assert {:skip, "the issue has the `qa:skip` label"} =
               Selection.decide(issue(%{labels: [" QA:Skip "]}), ["lib/symphony_elixir/cli.ex"], %{})

      assert {:run, [%{kind: "cli"}]} = Selection.decide(issue(%{labels: ["qa:cli"]}), ["README.md"], %{})
    end

    test "config overrides built-in paths, disables playbooks and adds new kinds" do
      config = %{
        playbooks: %{
          :cli => %{"paths" => ["scripts/**"]},
          "web" => %{paths: ["assets/**"], prompt: "### Playbook: web"},
          "empty" => %{paths: ["x/**"], prompt: "  "},
          "odd" => "not a map"
        }
      }

      assert [%{kind: "cli", paths: ["scripts/**"]}, %{kind: "web", paths: ["assets/**"]}] = Selection.playbooks(config)
      assert {:run, [%{kind: "web"}]} = Selection.decide(issue(), ["assets/app.js"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["lib/symphony_elixir/cli.ex"], config)

      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false, "paths" => "bin/**"}}})
    end

    test "the macos_app playbook runs only when its build command and app bundle are configured" do
      swift = ["macos/Sources/SymphonyBar/SettingsView.swift"]

      refute Enum.any?(Selection.playbooks(%{playbooks: %{}}), &(&1.kind == "macos_app"))
      assert {:skip, _reason} = Selection.decide(issue(), swift, %{playbooks: %{}})
      assert [] = Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app"}}})

      config = %{
        playbooks: %{
          "macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app", "build_timeout_ms" => 600_000}
        }
      }

      assert {:run, [%{kind: "macos_app", build: "make -C macos app", app: "macos/build/Symphony.app", build_timeout_ms: 600_000, prompt: prompt}]} =
               Selection.decide(issue(), swift, config)

      assert prompt =~ "### Playbook: macos_app"
      assert prompt =~ "wait about 10 seconds"
      assert prompt =~ "qa_permission_missing"

      assert {:run, [%{kind: "macos_app"}]} = Selection.decide(issue(%{labels: ["qa:macos_app"]}), ["README.md"], config)
      assert {:skip, _reason} = Selection.decide(issue(), ["macos/Tests/SymphonyBarCoreTests/QAModeTests.swift"], config)

      odd_timeout = put_in(config, [:playbooks, "macos_app", "build_timeout_ms"], "soon")
      assert [_cli, %{kind: "macos_app", build_timeout_ms: nil}] = Selection.playbooks(odd_timeout)
    end

    test "glob matching keeps single stars inside one directory" do
      assert Selection.glob_match?("lib/mix/tasks/a/b.ex", "lib/mix/tasks/**")
      assert Selection.glob_match?("a.md", "**/*.md")
      assert Selection.glob_match?("docs/x/a.md", "**/*.md")
      refute Selection.glob_match?("lib/a/b.ex", "lib/*.ex")
      assert Selection.glob_match?("lib/a.ex", "lib/?.ex")
      refute Selection.glob_match?("lib/a+b.ex", "lib/a.b.ex")
    end
  end

  describe "parse_response/1" do
    test "reads pass, fail and blocked verdicts with steps" do
      assert {:ok, %{verdict: :pass, summary: "The CLI behaves as described.", steps: [step], findings: []}} =
               QaAgent.parse_response("Done.\n```json\n" <> FakeSession.pass_json() <> "\n```")

      assert step == %{name: "symphony check", status: "pass", details: "$ bin/symphony check\nexit: 0", evidence: ["https://uploads.linear.test/t.md"]}

      fail = ~s({"verdict":"fail","steps":[{"name":"bad config","status":"fail","details":"exit 0"}]})
      assert {:ok, %{verdict: :fail, summary: "", findings: []} = result} = QaAgent.parse_response(fail)
      assert QaAgent.failure_findings(result) == ["bad config: exit 0"]

      with_findings = ~s({"verdict":"fail","findings":["exit status is 0", " "],"steps":null})
      assert {:ok, %{findings: ["exit status is 0"], steps: []} = result} = QaAgent.parse_response(with_findings)
      assert QaAgent.failure_findings(result) == ["exit status is 0"]

      assert {:ok, %{verdict: :blocked, reason: "mix is missing"}} = QaAgent.parse_response(~s({"verdict":"blocked","reason":" mix is missing "}))
    end

    test "rejects answers that do not follow the contract" do
      for {text, reason} <- [
            {"no json here", :no_verdict_object},
            {~s({"other": 1}), :no_verdict_object},
            {~s({"verdict":"maybe"}), :invalid_verdict},
            {~s({"verdict":"pass","steps":"all good"}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":"x","status":"great"}]}), :invalid_steps},
            {~s({"verdict":"pass","steps":[{"name":" ","status":"pass"}]}), :invalid_steps},
            {~s({"verdict":"fail","findings":[]}), :missing_fail_findings},
            {~s({"verdict":"blocked","reason":""}), :missing_blocked_reason}
          ] do
        assert {:error, {:malformed_qa_response, ^reason}} = QaAgent.parse_response(text)
      end

      assert {:error, {:malformed_qa_response, :empty_response}} = QaAgent.parse_response(nil)
    end
  end

  describe "prompt/2 and settings" do
    test "includes the ticket, the parent's criteria and the playbooks" do
      prompt = QaAgent.prompt(job(), %{"identifier" => "TP-243", "title" => "Parent", "description" => "- [ ] parent criterion"})

      assert prompt =~ "TP-900"
      assert prompt =~ "Adds `symphony check`."
      assert prompt =~ "Parent issue (this is a sub-ticket"
      assert prompt =~ "- [ ] parent criterion"
      assert prompt =~ ~r/<linear_issue_title>\s*Parent\s*<\/linear_issue_title>/
      assert prompt =~ ~r/<linear_issue_body>\s*- \[ \] parent criterion\s*<\/linear_issue_body>/
      assert prompt =~ "### Playbook: cli"
      assert prompt =~ @sha
      assert prompt =~ ~s("verdict": "pass" | "fail" | "blocked")

      refute QaAgent.prompt(job(%{issue: issue(%{title: nil, description: nil})}), nil) =~ "Parent issue"
    end

    test "QA settings take the auto_review runtime, turns and timeout" do
      write_workflow_file!(Workflow.workflow_file_path(),
        auto_review: %{runtime: "codex", command: "codex app-server", max_turns: 3, timeout_ms: 5_000}
      )

      settings = QaAgent.qa_settings(Config.settings!())

      assert %{kind: "codex", command: "codex app-server", max_turns: 3, turn_timeout_ms: 5_000} = settings.agent

      write_workflow_file!(Workflow.workflow_file_path())
      base = Config.settings!()
      assert QaAgent.qa_settings(base).agent.command == base.agent.command
    end

    test "worktrees live under the workspace root, outside the repository directories" do
      settings = Config.settings!()
      path = QaAgent.worktree_path(settings, nil, nil, @sha)

      assert path == Path.join([Path.expand(settings.workspace.root), ".qa", "default", "issue-0123456789ab"])
    end
  end

  describe "run/3" do
    test "runs the agent in a detached worktree with the QA tool scope and cleans up" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120}}},
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 300, "output_tokens" => 50, "total_tokens" => 350}}},
        %{event: :notification, payload: %{"method" => "other"}}
      ])

      forwarded = self()
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", @sha)
      workspace = job().workspace_path

      assert {:ok, %{result: %{verdict: :pass}, tokens: tokens}} =
               QaAgent.run(job(), settings,
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 on_message: &send(forwarded, {:forwarded, &1})
               )

      assert tokens.total_tokens == 350
      assert tokens.output_tokens == 50
      assert_receive {:git, ["worktree", "remove", "--force", ^worktree], ^workspace}
      assert_receive {:git, ["cat-file", "-e", _object], ^workspace}
      assert_receive {:git, ["worktree", "add", "--detach", ^worktree, @sha], ^workspace}
      assert_receive {:qa_session_started, ^worktree, session_opts}
      assert session_opts[:tool_scope] == :qa
      assert_receive {:qa_turn, _session, prompt, %Issue{id: "issue-qa"}, _opts}
      assert prompt =~ "### Playbook: cli"
      assert_receive {:forwarded, _message}
      assert_receive {:qa_session_stopped, _session}
      refute File.exists?(worktree)
    end

    test "gives a macos_app pass a QA driver and stops it when the pass ends" do
      [macos_app] =
        Selection.playbooks(%{playbooks: %{"cli" => %{"enabled" => false}, "macos_app" => %{"build" => "make app", "app" => "build/App.app"}}})

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{playbooks: [macos_app]}), Config.settings!(),
                 git: fake_git(),
                 qa_agent_module: FakeSession,
                 qa_driver_opts: [host: %{kill: fn _pid -> :ok end}]
               )

      assert_receive {:qa_session_started, _worktree, session_opts}
      driver = session_opts[:qa_driver]
      assert is_pid(driver)
      assert_receive {:qa_turn, _session, prompt, _issue, turn_opts}
      assert turn_opts[:qa_driver] == driver
      assert prompt =~ "### Playbook: macos_app"
      refute Process.alive?(driver)

      assert {:ok, _result} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
      assert_receive {:qa_session_started, _worktree, cli_opts}
      assert cli_opts[:qa_driver] == nil
    end

    test "falls back to the streamed agent text when the turn result has no verdict" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, FakeSession.pass_json()}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: "I tested it."}})

      assert {:ok, %{result: %{verdict: :pass}}} = QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "reports malformed answers and agent failures as errors with the tokens spent" do
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{}})

      assert {:error, {:malformed_qa_response, :empty_response}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:error, :turn_timeout})

      assert {:error, {:qa_agent_failed, :turn_timeout}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      Application.put_env(:symphony_elixir, :qa_test_start_result, {:error, :port_failed})

      assert {:error, {:qa_agent_failed, :port_failed}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "stops the turn at the per-issue token limit" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [
        %{event: :token_count, payload: %{method: "token_count", usage: %{"input_tokens" => 900, "output_tokens" => 200, "total_tokens" => 1_100}}}
      ])

      assert {:error, {:qa_token_limit, 1_100, 1_000}, %{total_tokens: 1_100}} =
               QaAgent.run(job(%{token_limit: 1_000}), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)

      assert_receive {:qa_session_stopped, _session}
    end

    test "fetches a missing commit and reports worktree failures" do
      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"fatal: no such ref", 128}})

      assert {:error, {:qa_commit_unavailable, @sha, 128, "fatal: no such ref"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      git = fake_git(%{cat_file: {"missing", 1}, fetch: {"", 0}, add: {"fatal: busy\n", 128}})

      assert {:error, {:qa_worktree_failed, 128, "fatal: busy"}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: git, qa_agent_module: FakeSession)

      assert_receive {:git, ["fetch", "--quiet", "origin", @sha], _workspace}
    end

    test "keeps the first parse error when every candidate is malformed" do
      Application.put_env(:symphony_elixir, :qa_test_messages, [{:agent_text, ~s({"verdict":"pass","steps":"x"})}])
      Application.put_env(:symphony_elixir, :qa_test_turn_result, {:ok, %{result: ~s({"verdict":"maybe"})}})

      assert {:error, {:malformed_qa_response, :invalid_verdict}, _tokens} =
               QaAgent.run(job(), Config.settings!(), git: fake_git(), qa_agent_module: FakeSession)
    end

    test "runs against a real git workspace without a parent lookup on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      repo = Path.join(System.tmp_dir!(), "qa-agent-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      git! = fn args ->
        {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
        String.trim(output)
      end

      git!.(["init", "--quiet"])
      git!.(["config", "user.email", "qa@example.test"])
      git!.(["config", "user.name", "QA"])
      File.write!(Path.join(repo, "a.txt"), "a\n")
      git!.(["add", "."])
      git!.(["commit", "--quiet", "-m", "a"])
      head = git!.(["rev-parse", "HEAD"])
      settings = Config.settings!()
      worktree = QaAgent.worktree_path(settings, "default", "TP-900", head)

      assert {:ok, %{result: %{verdict: :pass}}} =
               QaAgent.run(job(%{workspace_path: repo, sha: head}), settings, qa_agent_module: FakeSession)

      assert_receive {:qa_session_started, ^worktree, _opts}
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      refute prompt =~ "Parent issue"
      refute File.exists?(worktree)
      assert git!.(["worktree", "list"]) =~ repo
      refute git!.(["worktree", "list"]) =~ worktree
    end

    test "maps runtimes to agent modules" do
      assert {:ok, SymphonyElixir.Codex.AppServer} = QaAgent.agent_module("codex")
      assert {:ok, SymphonyElixir.ClaudeCode.AppServer} = QaAgent.agent_module("claude")
      assert {:error, {:unsupported_qa_agent_kind, nil}} = QaAgent.agent_module(nil)
    end

    test "does not run on remote workers or unknown runtimes" do
      assert {:error, {:remote_worker_unsupported, "worker-1"}, %{total_tokens: 0}} =
               QaAgent.run(job(%{worker_host: "worker-1"}), Config.settings!())

      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{runtime: "claude"})
      settings = Config.settings!()
      settings = %{settings | auto_review: %{settings.auto_review | kind: "gpt"}}

      assert {:error, {:unsupported_qa_agent_kind, "gpt"}, _tokens} = QaAgent.run(job(), settings, git: fake_git())
    end

    test "reads the parent issue from Linear for sub-tickets and survives a failed read" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      settings = Config.settings!()
      recipient = self()

      linear_client = fn query, _variables, _opts ->
        send(recipient, {:linear_query, query})
        {:ok, %{"data" => %{"issue" => %{"parent" => %{"identifier" => "TP-243", "title" => "Parent", "description" => "parent criterion"}}}}}
      end

      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: linear_client)
      assert_receive {:qa_turn, _session, prompt, _issue, _opts}
      assert prompt =~ "parent criterion"

      failing_client = fn _query, _variables, _opts -> {:error, :linear_down} end

      log =
        capture_log(fn ->
          assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: failing_client)
        end)

      assert log =~ "QA could not read the parent issue for TP-900"

      no_parent = fn _query, _variables, _opts -> {:ok, %{"data" => %{"issue" => %{"parent" => nil}}}} end
      assert {:ok, _result} = QaAgent.run(job(), settings, git: fake_git(), qa_agent_module: FakeSession, linear_client: no_parent)
    end
  end

  describe "Report" do
    test "renders a passing report with steps, evidence and accounting" do
      body =
        Report.render(%{
          verdict: :pass,
          sha: @sha,
          target_state: "In Review",
          summary: "All good.",
          steps: [
            %{name: "check", status: "pass", details: "$ bin/symphony check\n```\nexit: 0", evidence: ["https://u/t.md"]},
            %{name: "help", status: "skipped", details: " ", evidence: []}
          ],
          findings: [],
          playbooks: ["cli"],
          runtime_seconds: 83,
          tokens: %{total_tokens: 85_412}
        })

      assert body =~ "## Symphony QA Report"
      assert body =~ "**Verdict:** pass → In Review"
      assert body =~ "`0123456789ab` · playbooks: cli · 1m 23s · 85412 tokens"
      assert body =~ "All good."
      assert body =~ "- **pass** check (evidence: https://u/t.md)"
      assert body =~ "  exit: 0"
      assert body =~ "'''"
      assert body =~ "- **skipped** help\n"
    end

    test "renders fail, escalation, skip and blocked outcomes" do
      fail =
        Report.render(%{verdict: :fail, sha: @sha, target_state: "In Progress", fix_attempt: 1, max_fix_attempts: 2, findings: ["exit 0 on bad config"]})

      assert fail =~ "fail (fix attempt 1 of 2) → In Progress"
      assert fail =~ "### Findings\n\n- exit 0 on bad config"

      escalated = Report.render(%{verdict: :fail, sha: @sha, target_state: "In Review", escalated: true, tokens: %{}, runtime_seconds: 0})
      assert escalated =~ "fix attempts used up"

      skip = Report.render(%{verdict: :skip, sha: nil, target_state: "In Review", reason: "docs only"})
      assert skip =~ "**Verdict:** skipped → In Review"
      assert skip =~ "Reason: docs only"

      blocked = Report.render(%{verdict: :blocked, sha: @sha, target_state: "In Review", reason: "no mix", summary: "ignored"})
      assert blocked =~ "Reason: no mix"
      refute blocked =~ "ignored"

      long = Report.render(%{verdict: :pass, sha: @sha, target_state: "In Review", steps: [%{name: "x", status: "pass", details: String.duplicate("a", 2_100), evidence: []}]})
      assert long =~ "[... truncated ...]"
    end

    test "creates the report comment on Linear and then rewrites it in place" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      recipient = self()

      client = fn comments ->
        fn query, variables, _opts ->
          send(recipient, {:linear, query, variables})

          cond do
            query =~ "comments(" ->
              {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => comments}}}}}

            query =~ "commentCreate" ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-new"}}}}}

            query =~ "commentUpdate" ->
              {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
          end
        end
      end

      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nnew", linear_client: client.([%{"id" => "w", "body" => "## Symphony Workpad"}, %{"body" => nil}]))
      assert_receive {:linear, create, %{body: "## Symphony QA Report\n\nnew"}}
      assert create =~ "commentCreate"

      existing = [%{"id" => "c-qa", "body" => "## Symphony QA Report\n\nold"}]
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n\nv2", linear_client: client.(existing))
      assert_receive {:linear, update, %{id: "c-qa", body: "## Symphony QA Report\n\nv2"}}
      assert update =~ "commentUpdate"

      failing = fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}, "x" => 1}} end
      assert {:error, _reason} = Report.publish(issue(), "## Symphony QA Report", linear_client: failing)
    end

    test "posts a new comment on other trackers" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
      assert :ok = Report.publish(issue(), "## Symphony QA Report\n")
      assert_receive {:memory_tracker_comment, "issue-qa", "## Symphony QA Report\n"}
      assert Report.heading() == "## Symphony QA Report"
    end
  end
end
