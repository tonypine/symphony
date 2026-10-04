defmodule SymphonyElixir.ParentWalkthroughTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.AutoReview.ParentWalkthrough
  alias SymphonyElixir.QaAgent

  @sha "c0ffee00112233445566778899aabbccddeeff00"
  @now_ms 1_791_000_000_000
  @rate_limited {:error, {:linear_rate_limited, 1_791_000_030_000}}
  @workspace "/tmp/workspaces/TP-910"
  @env_keys [:walkthrough_recipient, :walkthrough_agent_result, :walkthrough_state_result, :walkthrough_parent_result]

  defmodule FakeQaAgent do
    def run(job, settings, opts) do
      send(Application.fetch_env!(:symphony_elixir, :walkthrough_recipient), {:qa_agent_run, job, settings, opts})
      Application.fetch_env!(:symphony_elixir, :walkthrough_agent_result)
    end
  end

  defmodule FakeTracker do
    def fetch_issue_by_identifier(identifier) do
      send(Application.fetch_env!(:symphony_elixir, :walkthrough_recipient), {:fetch_issue, identifier})
      Application.fetch_env!(:symphony_elixir, :walkthrough_parent_result)
    end

    # A list of results answers one move each, then `:ok`.
    def update_issue_state(issue_id, state) do
      send(Application.fetch_env!(:symphony_elixir, :walkthrough_recipient), {:state_update, issue_id, state})

      case Application.get_env(:symphony_elixir, :walkthrough_state_result, :ok) do
        [result | rest] ->
          Application.put_env(:symphony_elixir, :walkthrough_state_result, rest)
          result

        [] ->
          :ok

        result ->
          result
      end
    end
  end

  setup do
    write_settings!()
    Application.put_env(:symphony_elixir, :walkthrough_recipient, self())
    Application.put_env(:symphony_elixir, :walkthrough_parent_result, {:ok, parent()})

    on_exit(fn ->
      Enum.each(@env_keys, &Application.delete_env(:symphony_elixir, &1))
      AutoReview.reset_for_test("Auto Review")
    end)

    :ok
  end

  defp write_settings!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "linear",
          pr_review_mode: "polling",
          ci: %{enabled: true},
          auto_review: %{enabled: true, playbooks: %{"api" => %{paths: ["api/**"], prompt: "### Playbook: api"}}}
        ],
        overrides
      )
    )

    AutoReview.reset_for_test("Auto Review")
  end

  defp verification(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-fv",
        identifier: "TP-910",
        title: "Final verification: Settings window",
        description: "- [ ] Settings shows the API key field",
        state: "In Progress",
        labels: []
      },
      attrs
    )
  end

  defp parent(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-parent",
        identifier: "TP-900",
        title: "Settings window",
        description: "## User walkthrough\n1. Open Settings. The API key field shows.",
        url: "https://linear.test/TP-900",
        labels: []
      },
      attrs
    )
  end

  defp git(overrides \\ %{}) do
    recipient = self()

    fn args, cwd ->
      send(recipient, {:git, args, cwd})

      case args do
        ["fetch" | _rest] -> Map.get(overrides, :fetch, {"", 0})
        ["rev-parse" | _rest] -> Map.get(overrides, :rev_parse, {@sha <> "\n", 0})
      end
    end
  end

  # Answers the parent lookup, the QA report comments, sub-issue creation and blocked-by links.
  defp linear_client(opts \\ []) do
    recipient = self()
    parent_node = Keyword.get(opts, :parent, %{"id" => "issue-parent", "identifier" => "TP-900"})
    create_result = Keyword.get(opts, :create)
    relation_result = Keyword.get(opts, :relation, {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}})

    fn query, variables, _opts ->
      send(recipient, {:linear, query, variables})

      cond do
        query =~ "SymphonyAgentParentIssue" ->
          Keyword.get(opts, :parent_result, {:ok, %{"data" => %{"issue" => %{"parent" => parent_node}}}})

        query =~ "SymphonyAgentIssueComments" ->
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        query =~ "SymphonyAgentAddComment" ->
          Keyword.get(opts, :comment_result, {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-#{variables.issueId}"}}}}})

        query =~ "SymphonyAgentSubissueScope" ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-fv",
                 "team" => %{"id" => "team-1", "states" => %{"nodes" => [%{"id" => "state-backlog", "name" => "Backlog", "type" => "backlog"}]}},
                 "children" => %{"nodes" => []}
               }
             }
           }}

        query =~ "SymphonyAgentCreateSubissue" ->
          n = System.unique_integer([:positive])
          create_result || {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "new-#{n}", "identifier" => "TP-9#{n}"}}}}}

        query =~ "SymphonyAgentIssueByIdentifier" ->
          {:ok, %{"data" => %{"issue" => %{"id" => "id-" <> variables.id, "identifier" => variables.id}}}}

        query =~ "SymphonyAgentCreateIssueRelation" ->
          relation_result
      end
    end
  end

  defp run(issue, opts \\ []), do: ParentWalkthrough.run(issue, @workspace, Keyword.merge(run_opts(), opts))

  defp linear_retry_opts do
    parent = self()
    [now_ms_fun: fn -> @now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]
  end

  # A clock that each wait moves forward.
  defp clocked_linear_retry_opts do
    parent = self()
    Process.put(:walkthrough_now_ms, @now_ms)

    [
      now_ms_fun: fn -> Process.get(:walkthrough_now_ms) end,
      sleep_fun: fn delay_ms ->
        Process.put(:walkthrough_now_ms, Process.get(:walkthrough_now_ms) + delay_ms)
        send(parent, {:linear_wait_slept, delay_ms})
      end
    ]
  end

  # Linear's pause grows 1 → 2 → 4 → 5 minutes; the move goes through 12 minutes in.
  defp growing_rate_limit do
    Enum.map([60_000, 180_000, 420_000, 720_000], &{:error, {:linear_rate_limited, @now_ms + &1}})
  end

  defp waits(messages), do: for({:linear_wait_slept, delay_ms} <- messages, do: delay_ms)

  defp run_opts do
    [
      settings: Config.settings!(),
      repo_key: nil,
      run_id: "run-1",
      worker_host: nil,
      tracker: FakeTracker,
      qa_agent: FakeQaAgent,
      git: git(),
      linear_client: linear_client()
    ]
  end

  defp agent_result(verdict, attrs) do
    result = Map.merge(%{verdict: verdict, summary: "", steps: [], findings: []}, attrs)
    tokens = %{QaAgent.empty_tokens() | total_tokens: 1_200}
    Application.put_env(:symphony_elixir, :walkthrough_agent_result, {:ok, %{result: result, tokens: tokens}})
  end

  defp comments_posted do
    receive_all()
    |> Enum.flat_map(fn
      {:linear, query, %{issueId: issue_id, body: body}} -> if query =~ "SymphonyAgentAddComment", do: [{issue_id, body}], else: []
      _message -> []
    end)
  end

  defp created_subissues(messages \\ receive_all()) do
    messages
    |> Enum.flat_map(fn
      {:linear, query, %{input: input}} -> if query =~ "SymphonyAgentCreateSubissue", do: [input], else: []
      _message -> []
    end)
  end

  defp relations_created(messages) do
    messages
    |> Enum.flat_map(fn
      {:linear, query, %{input: input}} -> if query =~ "SymphonyAgentCreateIssueRelation", do: [input], else: []
      _message -> []
    end)
  end

  defp receive_all(acc \\ []) do
    receive do
      message -> receive_all([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run/3 when the walkthrough does not apply" do
    test "other tickets skip without reading anything" do
      assert :skip = run(verification(%{title: "Add the Settings window"}))
      refute_received {:linear, _query, _variables}
    end

    test "a final verification ticket keeps the executor run when the walkthrough cannot run" do
      log =
        capture_log(fn ->
          assert :skip = run(verification(), worker_host: "builder-1")
          assert :skip = run(verification(%{labels: ["QA:Skip"]}))

          assert :skip = run(verification(), linear_client: linear_client(parent: nil))

          write_settings!(auto_review: %{enabled: false})
          assert :skip = run(verification(), settings: Config.settings!())

          write_settings!(tracker_kind: "memory")
          assert :skip = run(verification(), settings: Config.settings!())
        end)

      assert log =~ "QA does not run on remote workers yet"
      assert log =~ "the ticket has the `qa:skip` label"
      assert log =~ "the ticket has no parent"
      assert log =~ "Auto Review is off"
      assert log =~ "the parent walkthrough needs the Linear tracker"
      refute_received {:qa_agent_run, _job, _settings, _opts}
    end

    test "a failed parent lookup is an error, so the run is retried" do
      down = linear_client(parent_result: {:error, :linear_down})
      assert {:error, {:parent_walkthrough_failed, :linear_down}} = run(verification(), linear_client: down)

      Application.put_env(:symphony_elixir, :walkthrough_parent_result, {:error, :not_found})
      assert {:error, {:parent_walkthrough_failed, :not_found}} = run(verification())
    end
  end

  describe "run/3 on a parent whose sub-tickets have merged" do
    test "a pass tests the parent at the base branch head, reports on the parent and hands the ticket to a human" do
      agent_result(:pass, %{
        summary: "Settings shows the API key field.",
        steps: [%{name: "Open Settings", status: "pass", details: "The window lists the API key field.", evidence: ["https://uploads.linear.test/settings.png"]}]
      })

      on_message = fn _message -> :ok end
      assert :ok = run(verification(), on_message: on_message)

      assert_received {:git, ["fetch", "--quiet", "origin", "main"], @workspace}
      assert_received {:git, ["rev-parse", "--verify", "refs/remotes/origin/main^{commit}"], @workspace}
      assert_received {:fetch_issue, "TP-900"}
      assert_received {:qa_agent_run, job, settings, agent_opts}

      assert %Issue{identifier: "TP-900"} = job.issue
      assert %Issue{identifier: "TP-910"} = job.verification_issue
      assert job.sha == @sha
      assert job.base_ref == "origin/main"
      assert job.workspace_path == @workspace
      assert job.run_id == "run-1"
      assert job.run_profile.kind == :qa
      assert Enum.map(job.playbooks, & &1.kind) == ["cli", "api"]
      assert settings.auto_review.enabled
      assert agent_opts[:on_message] == on_message
      assert is_function(agent_opts[:git], 2)
      assert_received {:state_update, "issue-fv", "In Review"}

      assert [{"issue-parent", report}, {"issue-fv", report}] = comments_posted()
      assert report =~ "**Verdict:** pass → TP-910 In Review"
      assert report =~ "**Commit:** `c0ffee001122` (head of `origin/main`)"
      assert report =~ "playbooks: cli, api"
      assert report =~ "1200 tokens"
      assert report =~ "- **pass** Open Settings (evidence: https://uploads.linear.test/settings.png)"
    end

    test "reads the base branch head from a real clone" do
      root = Path.join(System.tmp_dir!(), "parent-walkthrough-#{System.unique_integer([:positive])}")
      origin = Path.join(root, "origin")
      clone = Path.join(root, "clone")
      on_exit(fn -> File.rm_rf(root) end)

      File.mkdir_p!(origin)
      git! = fn args, cwd -> {_output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true) end
      git!.(["init", "--quiet", "--initial-branch=main"], origin)
      File.write!(Path.join(origin, "README.md"), "hello\n")
      git!.(["add", "README.md"], origin)
      git!.(["-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "--quiet", "-m", "init"], origin)
      git!.(["clone", "--quiet", origin, clone], root)
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: origin)

      agent_result(:pass, %{})
      assert :ok = ParentWalkthrough.run(verification(), clone, Keyword.delete(run_opts(), :git))
      assert_received {:qa_agent_run, %{sha: sha}, _settings, _opts}
      assert sha == String.trim(head)
    end

    test "qa labels on the ticket or the parent choose the playbooks" do
      agent_result(:pass, %{})

      assert :ok = run(verification(%{labels: ["qa:api"]}))
      assert_received {:qa_agent_run, %{playbooks: [%{kind: "api"}]}, _settings, _opts}

      Application.put_env(:symphony_elixir, :walkthrough_parent_result, {:ok, parent(%{labels: ["qa:cli"]})})
      assert :ok = run(verification())
      assert_received {:qa_agent_run, %{playbooks: [%{kind: "cli"}]}, _settings, _opts}
    end

    test "the built-in web playbook runs when the verification dev server is configured" do
      write_settings!(verification: %{enabled: true, dev_server: %{start_cmd: "scripts/dev-server.sh", health_check_url: "http://127.0.0.1:4000/"}})
      agent_result(:pass, %{})

      assert :ok = run(verification(%{labels: ["qa:web"]}), settings: Config.settings!())
      assert_received {:qa_agent_run, %{playbooks: [%{kind: "web"}]}, _settings, _opts}
    end

    test "each failing step becomes a Backlog child that names the step, holds the evidence and blocks the ticket in Todo" do
      agent_result(:fail, %{
        summary: "Settings opens empty.",
        steps: [
          %{name: "Open Settings", status: "fail", details: "The window is empty.\n```\nno views", evidence: ["https://uploads.linear.test/empty.png"]},
          %{name: "Save the API key", status: "fail", details: String.duplicate("x", 4_100), evidence: []},
          %{name: "Quit", status: "pass", details: "", evidence: []}
        ],
        findings: ["Settings renders no views"]
      })

      assert :ok = run(verification())
      assert_received {:state_update, "issue-fv", "Todo"}

      messages = receive_all()
      assert [first, second] = created_subissues(messages)

      assert [%{"issueId" => "id-" <> _, "relatedIssueId" => "issue-fv", "type" => "blocks"}, %{"relatedIssueId" => "issue-fv"}] =
               relations_created(messages)

      assert first["parentId"] == "issue-fv"
      assert first["stateId"] == "state-backlog"
      assert first["title"] == "Parent walkthrough fails: Open Settings"
      assert first["description"] =~ "The Auto Review parent walkthrough of TP-900 (https://linear.test/TP-900), run by the final verification ticket TP-910"
      assert first["description"] =~ "commit `c0ffee001122` (head of `origin/main`)"
      assert first["description"] =~ "## Failing step\n\nOpen Settings"
      assert first["description"] =~ "The window is empty.\n'''\nno views"
      assert first["description"] =~ "- https://uploads.linear.test/empty.png"
      assert first["description"] =~ ~s(- [ ] The step "Open Settings" behaves as TP-900 describes)

      assert second["title"] == "Parent walkthrough fails: Save the API key"
      assert second["description"] =~ "[... truncated ...]"
      assert second["description"] =~ "The QA agent recorded no evidence for this"
    end

    test "findings without a failing step are filed one per finding, and a failed create is logged" do
      long = String.duplicate("y", 200)

      agent_result(:fail, %{
        steps: [%{name: "Open Settings", status: "pass", details: "", evidence: ["https://uploads.linear.test/a.png"]}],
        findings: ["The About tab is missing\nIt should list the version", long]
      })

      Application.put_env(:symphony_elixir, :walkthrough_parent_result, {:ok, parent(%{url: nil})})

      assert :ok = run(verification())
      assert [first, second] = created_subissues()
      assert first["title"] == "Parent walkthrough finding: The About tab is missing"
      assert first["description"] =~ "The Auto Review parent walkthrough of TP-900, run by"
      assert first["description"] =~ "## Finding\n\nThe About tab is missing\nIt should list the version"
      assert first["description"] =~ "- https://uploads.linear.test/a.png"
      assert String.length(second["title"]) == 120

      agent_result(:fail, %{findings: ["The About tab is missing"]})
      failing = linear_client(create: {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}})

      log = capture_log(fn -> assert :ok = run(verification(), linear_client: failing) end)
      assert log =~ "Failed to file a parent walkthrough finding for TP-910"
      assert_received {:state_update, "issue-fv", "Backlog"}
      assert [{"issue-parent", report} | _rest] = comments_posted()
      refute report =~ "### Filed tickets"
    end

    test "a gap that cannot block the ticket sends it to Backlog for a human" do
      agent_result(:fail, %{findings: ["The About tab is missing"]})
      failing = linear_client(relation: {:error, :linear_down})

      log = capture_log(fn -> assert :ok = run(verification(), linear_client: failing) end)
      assert log =~ ~r/Failed to mark TP-910 blocked by TP-9\d+/
      assert_received {:state_update, "issue-fv", "Backlog"}
      assert [{"issue-parent", report}, _ticket] = comments_posted()
      assert report =~ "**Verdict:** fail → TP-910 Backlog"
    end

    test "the report lists the filed tickets" do
      agent_result(:fail, %{findings: ["The About tab is missing"]})

      assert :ok = run(verification())
      assert [{"issue-parent", report}, _ticket] = comments_posted()
      assert report =~ "**Verdict:** fail → TP-910 Todo"
      assert report =~ ~r/### Filed tickets\n\n- TP-9\d+ Parent walkthrough finding: The About tab is missing/
    end

    test "an agent error or an unreadable base branch is reported as blocked and handed to a human" do
      token_limit = {:error, {:qa_token_limit, 600, 500}, QaAgent.empty_tokens()}
      Application.put_env(:symphony_elixir, :walkthrough_agent_result, token_limit)

      assert :ok = run(verification())
      assert_received {:state_update, "issue-fv", "In Review"}
      assert [{"issue-parent", report}, _ticket] = comments_posted()
      assert report =~ "**Verdict:** blocked → TP-910 In Review"
      assert report =~ "Reason: the QA agent reached the per-issue token limit (600 of 500 tokens)"

      assert :ok = run(verification(), git: git(%{fetch: {"fatal: unreachable", 128}}))
      assert [{"issue-parent", report}, _ticket] = comments_posted()
      assert report =~ ~s(Reason: could not read the head of origin/main: {:git_failed, 128, "fatal: unreachable"})
      refute_received {:qa_agent_run, _job, _settings, _opts}
    end

    test "a rate-limited final state move keeps the verdict and applies it after the wait" do
      agent_result(:fail, %{findings: ["The About tab is missing"]})
      Application.put_env(:symphony_elixir, :walkthrough_state_result, [@rate_limited])

      log = capture_log(fn -> assert :ok = run(verification(), linear_retry_opts: linear_retry_opts()) end)

      messages = receive_all()
      assert [{:qa_agent_run, _job, _settings, _opts}] = Enum.filter(messages, &match?({:qa_agent_run, _, _, _}, &1))
      assert [{:state_update, "issue-fv", "Todo"}, {:state_update, "issue-fv", "Todo"}] = Enum.filter(messages, &match?({:state_update, _, _}, &1))
      assert {:linear_wait_slept, 30_000} in messages
      assert [_gap] = created_subissues(messages)
      assert log =~ "Linear call failed while moving TP-910 to Todo after the parent walkthrough; retrying in 30000ms"
      assert log =~ "Parent walkthrough for TP-900 ended fail; moved TP-910 to Todo"
    end

    test "a final state move rate-limited past five minutes still applies the verdict" do
      agent_result(:fail, %{findings: ["The About tab is missing"]})
      Application.put_env(:symphony_elixir, :walkthrough_state_result, growing_rate_limit())

      log = capture_log(fn -> assert :ok = run(verification(), linear_retry_opts: clocked_linear_retry_opts()) end)

      messages = receive_all()
      assert [{:qa_agent_run, _job, _settings, _opts}] = Enum.filter(messages, &match?({:qa_agent_run, _, _, _}, &1))
      assert List.duplicate({:state_update, "issue-fv", "Todo"}, 5) == Enum.filter(messages, &match?({:state_update, _, _}, &1))
      assert [60_000, 120_000, 240_000, 300_000] = waits(messages)
      assert [_gap] = created_subissues(messages)
      assert log =~ "Parent walkthrough for TP-900 ended fail; moved TP-910 to Todo"
    end

    test "a caller's wait budget still bounds the final state move" do
      agent_result(:pass, %{})
      Application.put_env(:symphony_elixir, :walkthrough_state_result, growing_rate_limit())
      retry_opts = [max_wait_ms: 300_000] ++ clocked_linear_retry_opts()

      capture_log(fn ->
        assert {:error, {:parent_walkthrough_state_update_failed, "In Review", {:linear_rate_limited, _until_ms}}} =
                 run(verification(), linear_retry_opts: retry_opts)
      end)

      assert [60_000, 120_000, 120_000] = waits(receive_all())
    end

    test "a rate-limited QA report is posted after the wait" do
      agent_result(:pass, %{})
      client = linear_client()

      rate_limited_once = fn query, variables, opts ->
        if query =~ "SymphonyAgentAddComment" and !Process.put(:walkthrough_comment_rate_limited, true) do
          {:error, {:linear_rate_limited, 1_791_000_030_000}}
        else
          client.(query, variables, opts)
        end
      end

      log =
        capture_log(fn ->
          assert :ok = run(verification(), linear_client: rate_limited_once, linear_retry_opts: linear_retry_opts())
        end)

      assert_received {:linear_wait_slept, 30_000}
      assert [{"issue-parent", report}, {"issue-fv", report}] = comments_posted()
      assert report =~ "**Verdict:** pass → TP-910 In Review"
      assert log =~ "Linear call failed while publishing the parent walkthrough QA report on TP-900"
      refute log =~ "Failed to publish"
    end

    test "a report that cannot be posted is logged and a failed move is an error" do
      agent_result(:pass, %{})
      Application.put_env(:symphony_elixir, :walkthrough_state_result, {:error, :linear_down})
      failing_comment = linear_client(comment_result: {:error, :linear_down})

      log =
        capture_log(fn ->
          assert {:error, {:parent_walkthrough_state_update_failed, "In Review", :linear_down}} =
                   run(verification(), linear_client: failing_comment)
        end)

      assert log =~ "Failed to publish the parent walkthrough QA report on TP-900"
      assert log =~ "Failed to publish the parent walkthrough QA report on TP-910"
    end
  end
end
