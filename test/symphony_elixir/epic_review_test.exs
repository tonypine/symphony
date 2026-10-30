defmodule SymphonyElixir.EpicReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.CiWait
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.EpicReview
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.RunStore
  alias SymphonyElixir.SelfHeal
  alias SymphonyElixir.TicketSignals

  @repo_key "repo-epic-review"
  @issue_id "issue-epic-review"
  @other_issue_id "issue-epic-review-other"
  @symphony_repo_key "repo-symphony"
  @fix_ticket "TP-900"
  @sha "c0ffee00112233445566778899aabbccddeeff00"
  @workspace "/tmp/workspaces/TP-823"
  # The epic's checklist row, checked by the review.
  @checked_row %{name: "The settings window opens", status: "pass", details: "Opened it.", evidence: [], checklist: true}

  defmodule FakeQaAgent do
    def run(job, settings, opts) do
      send(self(), {:qa_agent_run, job, settings, opts})
      Process.get(:epic_review_agent_result, default_result())
    end

    defp default_result do
      {:ok, %{result: %{verdict: :pass, summary: "Every requirement is met.", steps: [checked_row()], findings: []}, tokens: %{}}}
    end

    defp checked_row do
      %{name: "The settings window opens", status: "pass", details: "Opened it.", evidence: [], checklist: true}
    end
  end

  # The tracker a caller can name in place of the configured one, so a test sees the moves the
  # review performs rather than the memory tracker's.
  defmodule FakeMoveTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:tracker_move, issue_id, state})
      :ok
    end
  end

  # The fix-ticket filer, standing in for the Linear-backed one so no test reaches the network.
  defmodule FakeFixer do
    def create(attrs, _opts) do
      send(self(), {:fixer_create, attrs})
      {:ok, %{identifier: "TP-900", url: "https://linear.app/acme/issue/TP-900"}}
    end

    def attach(identifier, body, _opts) do
      send(self(), {:fixer_attach, identifier, body})
      :ok
    end

    def block(_issue, ticket, _opts) do
      send(self(), {:fixer_block, ticket.identifier})
      :ok
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    for id <- [@issue_id, @other_issue_id] do
      RunStore.delete_ticket_state(@repo_key, id)
      on_exit(fn -> RunStore.delete_ticket_state(@repo_key, id) end)
    end

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end)

    :ok
  end

  defp settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))

    settings
  end

  defp epic(attrs \\ %{}) do
    struct!(
      %Issue{
        id: @issue_id,
        identifier: "TP-823",
        title: "Land the epic path",
        description: "## Acceptance criteria\n\n- [ ] The settings window opens\n",
        url: "https://linear.test/TP-823",
        state: "Waiting on sub-tickets",
        labels: ["plan"],
        sub_issues: [%{id: "child-1", identifier: "TP-824", state: "Done"}],
        repo_key: @repo_key
      },
      attrs
    )
  end

  defp git(overrides \\ %{}) do
    recipient = self()
    overrides = Map.new(overrides)

    fn args, cwd ->
      send(recipient, {:git, args, cwd})

      case args do
        ["fetch" | _rest] -> Map.get(overrides, :fetch, {"", 0})
        ["rev-parse" | _rest] -> Map.get(overrides, :rev_parse, {@sha <> "\n", 0})
      end
    end
  end

  # Answers the epic's comments, the sub-issue scope, sub-issue creation and the report comment.
  defp linear_client(opts \\ []) do
    recipient = self()
    create_result = Keyword.get(opts, :create)
    states = Keyword.get(opts, :states, [%{"id" => "state-todo", "name" => "Todo", "type" => "unstarted"}])
    children = Keyword.get(opts, :children, [])
    relation = Keyword.get(opts, :relation, {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}})

    fn query, variables, _opts ->
      send(recipient, {:linear, query, variables})

      cond do
        query =~ "SymphonyAgentIssueComments" ->
          Keyword.get(opts, :comments, {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}})

        query =~ "SymphonyAgentAddComment" ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-#{variables.issueId}"}}}}}

        query =~ "SymphonyAgentSubissueScope" ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => @issue_id,
                 "priority" => 1,
                 "team" => %{"id" => "team-1", "states" => %{"nodes" => states}},
                 "children" => %{"nodes" => children}
               }
             }
           }}

        query =~ "SymphonyAgentCreateSubissue" ->
          create_answer(create_result, variables.input)

        query =~ "SymphonyAgentCreateIssueRelation" ->
          relation
      end
    end
  end

  # The fake's answer to a sub-issue creation: a fresh issue, unless the test names one.
  defp create_answer(fun, input) when is_function(fun, 1), do: fun.(input) || create_answer(nil, input)

  defp create_answer(nil, _input) do
    n = System.unique_integer([:positive])
    created_issue("new-#{n}", "TP-9#{n}")
  end

  defp create_answer(result, _input), do: result

  defp created_issue(id, identifier),
    do: {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => id, "identifier" => identifier}}}}}

  defp verdict_runs do
    for event <- RunStore.list_ticket_events(@repo_key, @issue_id, types: ["verdict.recorded"]) do
      {event.payload.outcome, event.run_id}
    end
  end

  defp run(issue, opts \\ []) do
    EpicReview.run(
      issue,
      Keyword.get(opts, :workspace, @workspace),
      Keyword.merge(default_opts(), Keyword.delete(opts, :workspace))
    )
  end

  defp default_opts do
    [
      settings: settings!(),
      repo_key: @repo_key,
      run_id: "run-1",
      qa_agent: FakeQaAgent,
      fixer: FakeFixer,
      symphony_repo_key: @symphony_repo_key,
      git: git(),
      gh_runner: gh_runner([]),
      linear_client: linear_client()
    ]
  end

  # Answers `gh run list --commit` with `runs` (a list of run payloads, or a `{output, status}`).
  defp gh_runner(runs) do
    recipient = self()

    fn ["run", "list", "--commit", _sha | _rest] = args, opts ->
      send(recipient, {:gh, args, opts[:cd]})

      case runs do
        {output, status} -> {output, status}
        runs -> {Jason.encode!(runs), 0}
      end
    end
  end

  defp ci_run(name, status, attrs \\ %{}) do
    Map.merge(
      %{
        "databaseId" => System.unique_integer([:positive]),
        "workflowName" => name,
        "status" => status,
        "conclusion" => if(status == "completed", do: "success", else: ""),
        "url" => "https://github.com/acme/app/actions/runs/#{name}",
        "createdAt" => "2026-10-14T18:00:00Z"
      },
      attrs
    )
  end

  defp agent_result(verdict, attrs) do
    result = Map.merge(%{verdict: verdict, summary: "", steps: [@checked_row], findings: []}, attrs)
    Process.put(:epic_review_agent_result, {:ok, %{result: result, tokens: %{QaAgent.empty_tokens() | total_tokens: 1_200}}})
  end

  defp agent_error(reason), do: Process.put(:epic_review_agent_result, {:error, reason, %{}})

  defp verdicts(id \\ @issue_id), do: Handoff.verdicts(@repo_key, id, "epic_review")

  defp signals(id \\ @issue_id), do: Handoff.signals(@repo_key, id)

  defp state_updates(messages \\ peek()) do
    for {:memory_tracker_state_update, id, state} <- messages, do: {id, state}
  end

  defp comments_posted(messages \\ peek()) do
    for {:memory_tracker_comment, issue_id, body} <- messages, do: {issue_id, body}
  end

  # The blocked-by relations filed, as `{blocker id, blocked id}`.
  defp relations(messages \\ peek()) do
    for {:linear, query, %{input: %{"type" => "blocks"} = input}} <- messages, query =~ "SymphonyAgentCreateIssueRelation", do: {input["issueId"], input["relatedIssueId"]}
  end

  # Files each follow-up named in `tickets` (title => `{id, identifier}` or an error) as that
  # ticket, and any other one as the fake's default.
  defp create_by_title(tickets) do
    fn %{"title" => title} ->
      case Map.get(tickets, title) do
        {:error, _reason} = error -> error
        {id, identifier} -> created_issue(id, identifier)
        nil -> nil
      end
    end
  end

  defp created_subissues(messages \\ peek()) do
    messages
    |> Enum.flat_map(fn
      {:linear, query, %{input: input}} -> if query =~ "SymphonyAgentCreateSubissue", do: [input], else: []
      _message -> []
    end)
  end

  # Reads the mailbox without consuming it: a test collects, then still asserts on the messages
  # themselves, and `assert_received` / `refute_received` keep working.
  defp peek do
    messages = receive_all()
    Enum.each(messages, &send(self(), &1))
    messages
  end

  defp receive_all(acc \\ []) do
    receive do
      message -> receive_all([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "epic_review_run?/2" do
    test "is true only for an epic parent, in the review state or ready for it" do
      assert EpicReview.epic_review_run?(epic(), settings!())
      assert EpicReview.epic_review_run?(epic(%{state: "Epic Review"}), settings!())

      # A stale candidate is still this run's: it is the run that checks and holds it.
      assert EpicReview.epic_review_run?(
               epic(%{state: "Epic Review", sub_issues: [%{identifier: "TP-824", state: "In Progress"}]}),
               settings!()
             )

      refute EpicReview.epic_review_run?(epic(%{labels: []}), settings!())
      refute EpicReview.epic_review_run?(epic(%{sub_issues: []}), settings!())
      refute EpicReview.epic_review_run?(epic(%{state: "Rework"}), settings!())
      refute EpicReview.epic_review_run?(%Issue{id: "x", state: nil}, settings!())
    end

    test "is false for anything that is not an issue, or that carries no state to match" do
      refute EpicReview.epic_review_run?(nil, settings!())
      refute EpicReview.epic_review_run?(%{id: "not-an-issue"}, settings!())

      # No state to compare with the review state, and an open child: not this run's.
      refute EpicReview.epic_review_run?(
               epic(%{state: nil, sub_issues: [%{identifier: "TP-824", state: "In Progress"}]}),
               settings!()
             )
    end
  end

  describe "state/1 and follow_up_state/0" do
    test "the configured states, and nil when the tracker names none" do
      assert EpicReview.state(settings!()) == "Epic Review"
      assert EpicReview.state(%{tracker: %{epic_review_state: "Integrity Check"}}) == "Integrity Check"
      assert EpicReview.state(%{tracker: %{epic_review_state: nil}}) == nil
      assert EpicReview.state(%{}) == nil
      assert EpicReview.follow_up_state() == "Todo"
    end
  end

  describe "checks/2" do
    test "lists what the review must account for, with attention where there is something to answer" do
      :ok = SymphonyElixir.TicketPullRequest.record_created(@repo_key, @issue_id, "https://github.com/acme/app/pull/7", "auto/TP-823")
      issue = epic(%{comments: [%{id: "c1", body: "Please check the settings window.", author: "kim"}]})

      assert {:ok, checks} = EpicReview.checks(issue, settings!())

      assert [
               %{name: :artifacts, status: :ok, detail: "all 1 sub-issue(s) terminal"},
               %{name: :comments, status: :attention, detail: comments_detail},
               %{name: :pull_requests, status: :attention, detail: pr_detail},
               %{name: :checklist, status: :ok, detail: checklist_detail}
             ] = checks

      assert comments_detail =~ "1 comment(s) to account for, the newest from kim"
      assert pr_detail =~ "https://github.com/acme/app/pull/7"
      assert checklist_detail =~ "1 checklist row(s) for the review to resolve"
    end

    test "the pull-request check lists the epic's PR from Symphony's record, and none once it merged" do
      pr_url = "https://github.com/acme/app/pull/1012"
      :ok = SymphonyElixir.TicketPullRequest.record_created(@repo_key, @issue_id, pr_url, "auto/TP-823")

      assert {:ok, checks} = EpicReview.checks(epic(), settings!())
      assert %{status: :attention, detail: detail} = Enum.find(checks, &(&1.name == :pull_requests))
      assert detail == "1 pull request(s) recorded on the epic: #{pr_url}"

      :ok = SymphonyElixir.TicketPullRequest.mark_finished(@repo_key, pr_url, "merged")

      assert {:ok, checks} = EpicReview.checks(epic(), settings!())
      assert %{status: :ok} = Enum.find(checks, &(&1.name == :pull_requests))
    end

    test "an epic with nothing recorded and no checklist rows lists all four as evidence to derive" do
      issue = epic(%{description: "Just context.", comments: [%{id: "c1"}]})

      assert {:ok, checks} = EpicReview.checks(issue, settings!())

      assert Enum.map(checks, & &1.status) == [:ok, :attention, :ok, :attention]
      assert Enum.at(checks, 1).detail =~ "the newest from unknown"
      assert Enum.at(checks, 3).detail =~ "no checklist row in the epic's description"
    end

    test "an open sub-issue makes the epic not reviewable yet" do
      issue = epic(%{sub_issues: [%{identifier: "TP-824", state: "In Progress"}, %{identifier: "TP-825", state: "Todo"}]})

      assert {:not_ready, reason} = EpicReview.checks(issue, settings!())
      assert reason == "sub-issues still open: TP-824, TP-825"
    end

    test "an epic with no description at all counts no checklist rows" do
      assert {:ok, checks} = EpicReview.checks(epic(%{description: nil}), settings!())

      assert Enum.at(checks, 3) == %{
               name: :checklist,
               status: :attention,
               detail: "no checklist row in the epic's description: the review derives them from it"
             }
    end

    test "a tracker config that names no terminal states leaves every child open" do
      assert {:not_ready, "sub-issues still open: TP-824"} =
               EpicReview.checks(epic(), %{tracker: %{epic_review_state: "Epic Review"}})
    end
  end

  describe "run/3 when the review does not apply" do
    test "skips every other ticket without reading anything" do
      assert :skip = run(epic(%{labels: []}))
      assert :skip = run(epic(%{state: "Rework"}))
      assert :skip = run(%{}, [])

      assert :skip = EpicReview.run(epic(), nil, default_opts())

      refute_received {:git, _args, _cwd}
      refute_received {:qa_agent_run, _job, _settings, _opts}
    end

    test "a stale candidate with an open sub-issue moves nothing and runs nothing" do
      log =
        capture_log(fn ->
          assert :ok = run(epic(%{state: "Epic Review", sub_issues: [%{identifier: "TP-824", state: "In Progress"}]}))
        end)

      assert log =~ "Not reviewing epic TP-823: sub-issues still open: TP-824"
      refute_received {:memory_tracker_state_update, _, _}
      refute_received {:qa_agent_run, _job, _settings, _opts}
      assert verdicts() == []
    end
  end

  describe "run/3 on an epic whose children are terminal" do
    test "a pass enters Epic Review, reviews the base branch head and lands the epic in Done" do
      agent_result(:pass, %{
        summary: "Every requirement is met.",
        steps: [
          %{name: "Open Settings", status: "pass", details: "The window opened.", evidence: ["https://uploads.linear.test/s1.png"]},
          @checked_row
        ]
      })

      on_message = fn _message -> :ok end
      assert :ok = run(epic(), on_message: on_message)

      assert_received {:git, ["fetch", "--quiet", "origin", "main"], @workspace}
      assert_received {:git, ["rev-parse", "--verify", "refs/remotes/origin/main^{commit}"], @workspace}
      assert_received {:qa_agent_run, job, %Schema{}, agent_opts}

      assert job.epic_review == true
      assert job.sha == @sha
      assert job.base_ref == "origin/main"
      assert job.workspace_path == @workspace
      assert job.run_id == "run-1"
      assert job.journey.source == "the epic's acceptance criteria"
      assert [%{kind: kind}] = job.playbooks
      assert is_binary(kind)
      assert agent_opts[:on_message] == on_message
      assert is_function(agent_opts[:git], 2)

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()

      assert [%{kind: "epic_review", head_sha: @sha, outcome: "pass"}] = verdicts()
      assert [{"pass", "run-1"}] = verdict_runs()

      assert [
               %{name: "epic_review", details: %{signal: "epic_review_pass", target: "Done"}},
               %{name: "epic_review", details: %{signal: "epic_review_enter", target: "Epic Review"}}
             ] = signals()

      assert [{@issue_id, report}] = comments_posted()

      assert report =~ "**Verdict:** pass → TP-823 Done"
      assert report =~ "**Commit:** `c0ffee001122` (head of `origin/main`)"
      assert report =~ "### Pre-checks"
      assert report =~ "- **ok** artifacts: all 1 sub-issue(s) terminal"
      assert report =~ "- **ok** comments: no comment on the epic to account for"
      assert report =~ "1200 tokens"
      assert report =~ "- **pass** Open Settings (evidence: https://uploads.linear.test/s1.png)"
    end

    test "a verdict from a run given no id names the id its QA agent ran as" do
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})

      assert :ok = run(epic(), run_id: nil)

      assert_received {:qa_agent_run, %{run_id: "epic-review-TP-823-c0ffee001122"}, _settings, _agent_opts}
      assert [{"fail", "epic-review-TP-823-c0ffee001122"}] = verdict_runs()
    end

    test "a recovery run in Epic Review does not enter it again" do
      assert :ok = run(epic(%{state: "Epic Review"}))

      assert [{@issue_id, "Done"}] = state_updates()
      assert [%{name: "epic_review", details: %{signal: "epic_review_pass"}} | _] = signals()
    end

    test "a review that already passed this commit is carried instead of run twice" do
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "epic_review", @sha, "pass")

      assert :ok = run(epic())

      refute_received {:qa_agent_run, _job, _settings, _opts}
      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "carried forward: this commit's epic review already passed"

      # The pass is not recorded a second time: the first one is still the verdict for this commit.
      assert [%{head_sha: @sha, outcome: "pass"}] = verdicts()
    end

    test "a fail already recorded for this commit is carried instead of filing the gaps twice" do
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "epic_review", @sha, "fail")

      assert :ok = run(epic(%{state: "Epic Review"}))

      refute_received {:qa_agent_run, _job, _settings, _opts}
      assert created_subissues() == []
      assert [{@issue_id, "Waiting on sub-tickets"}] = state_updates()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "carried forward: this commit's gaps were already filed as follow-ups"

      # The verdict is not recorded a second time, and the move says it was carried.
      assert [%{head_sha: @sha, outcome: "fail"}] = verdicts()
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", carried: true}} | _] = signals()
    end

    test "a fail recorded before the parent left Epic Review is reviewed again once it is waiting" do
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "epic_review", @sha, "fail")
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})

      assert :ok = run(epic())

      # The move that recorded that fail landed: what reaches the review again is a changed epic,
      # so it is judged afresh — and its gap is filed.
      assert_received {:qa_agent_run, _job, _settings, _opts}
      assert [%{"title" => "Epic review finding: The export button is absent"}] = created_subissues()
    end

    test "gaps are filed as follow-ups in Todo and the parent goes back to the waiting state" do
      agent_result(:fail, %{
        summary: "The settings window is missing.",
        steps: [
          %{name: "Open Settings", status: "pass", details: "The window opened.", evidence: []},
          %{name: "Settings shows the API key field", status: "fail", details: "There is no field.", evidence: ["https://uploads.linear.test/s2.png"], checklist: true}
        ]
      })

      assert :ok = run(epic())

      assert [input] = created_subissues()

      assert input["stateId"] == "state-todo"
      assert input["parentId"] == @issue_id
      # The epic's Urgent priority, so `tickets.priorities: [urgent]` dispatches the follow-up.
      assert input["priority"] == 1
      assert input["title"] == "Epic review fails: Settings shows the API key field"
      assert input["description"] =~ "The epic review of TP-823 (https://linear.test/TP-823) failed on commit `c0ffee001122`"
      assert input["description"] =~ "https://uploads.linear.test/s2.png"
      assert input["description"] =~ "when it runs TP-823 again"

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Waiting on sub-tickets"}] = state_updates()

      assert [%{head_sha: @sha, outcome: "fail"} | _] = verdicts()

      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 1}} | _] = signals()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** fail → TP-823 Waiting on sub-tickets"
      assert report =~ "### Filed tickets"
      assert report =~ "Epic review fails: Settings shows the API key field"
    end

    test "without failing steps each finding is filed" do
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent", "The window forgets its size"]})

      assert :ok = run(epic())

      assert Enum.map(created_subissues(), & &1["title"]) == [
               "Epic review finding: The export button is absent",
               "Epic review finding: The window forgets its size"
             ]

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Waiting on sub-tickets"}] = state_updates()
    end

    test "gaps none of which could be filed are a block, not a waiting state with nothing to wait on" do
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})
      down = linear_client(create: {:error, :linear_down})

      log =
        capture_log(fn ->
          assert :ok = run(epic(), linear_client: down)
        end)

      assert log =~ "Failed to file an epic review follow-up for TP-823: :linear_down"

      assert [{@issue_id, "Epic Review"}] = state_updates()

      assert [%{outcome: "blocked"} | _] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → TP-823 Epic Review (blocked, retrying)"
      assert report =~ "could not file any follow-up for them"
    end

    test "failing steps that rest on one defect are one follow-up listing every step and its evidence" do
      agent_result(:fail, %{
        summary: "The split view overflows on Today; Settings lacks the key field.",
        steps: [
          @checked_row,
          %{
            name: "Design check: app shell, Today with the inspector open",
            status: "fail",
            details: "The split view grows to 1523 pt in a 1400 pt window.",
            evidence: ["https://uploads.linear.test/today-wide.png"],
            defect: "Split view wider than the window on Today"
          },
          %{name: "Settings shows the API key field", status: "fail", details: "No field.", evidence: ["https://uploads.linear.test/s2.png"], checklist: true},
          %{
            name: "Plan level: the overall app wrapper",
            status: "fail",
            details: "Fails on Today (see the design check).",
            evidence: ["https://uploads.linear.test/today-inspector.png"],
            checklist: true,
            defect: " split view wider than the window on today "
          }
        ]
      })

      assert :ok = run(epic())

      assert [shared, single] = created_subissues()

      assert shared["title"] == "Epic review fails: Split view wider than the window on Today"
      description = shared["description"]
      assert description =~ "## Defect\n\nSplit view wider than the window on Today\n"
      assert description =~ "2 failing step(s) of the review rest on this defect"
      assert description =~ "### Design check: app shell, Today with the inspector open\n"
      assert description =~ "The split view grows to 1523 pt in a 1400 pt window."
      assert description =~ "- https://uploads.linear.test/today-wide.png"
      assert description =~ "### Plan level: the overall app wrapper\n"
      assert description =~ "Fails on Today (see the design check)."
      assert description =~ "- https://uploads.linear.test/today-inspector.png"
      assert description =~ ~s(- [ ] The step "Design check: app shell, Today with the inspector open" behaves as TP-823 describes)
      assert description =~ ~s(- [ ] The step "Plan level: the overall app wrapper" behaves as TP-823 describes)
      assert description =~ "- [ ] The epic's review passes these steps when it runs TP-823 again."
      refute description =~ "Settings shows the API key field"

      # A step with no defect is filed as it always was.
      assert single["title"] == "Epic review fails: Settings shows the API key field"
      assert single["description"] =~ "## Failing step\n\nSettings shows the API key field"
      refute single["description"] =~ "## Defect"

      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 2}} | _] = signals()
    end

    test "a plan-level step that names a design check's defect files no ticket of its own" do
      agent_result(:fail, %{
        summary: "The Companies table's People column is empty.",
        steps: [
          %{name: "Plan level: redesign individual pages", status: "fail", details: "Companies fails (see the design check).", evidence: [], defect: "People column empty"},
          %{name: "Design check: Companies table", status: "fail", details: "Reads – while the pages list contacts.", evidence: [], defect: "People column empty"}
        ]
      })

      assert :ok = run(epic())

      assert [input] = created_subissues()
      assert input["title"] == "Epic review fails: People column empty"
      assert input["description"] =~ "### Plan level: redesign individual pages"
      assert input["description"] =~ "### Design check: Companies table"
      assert input["description"] =~ "The review recorded no evidence for this; see the step details."
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 1}} | _] = signals()
    end

    test "a defect's follow-up answers to its steps' gap labels and waits on what they wait on, not on itself" do
      agent_result(:fail, %{
        summary: "The walkthrough needs a QA tool that is not there.",
        steps: [
          %{name: "Record the walkthrough", status: "fail", details: "", evidence: [], defect: "No walkthrough", gap: "G2", blocked_by: ["G1"]},
          %{name: "Plan level: walkthrough", status: "fail", details: "", evidence: [], defect: "No walkthrough", gap: "G3", blocked_by: ["g2", "G1"]},
          %{name: "Check the walkthrough", status: "fail", details: "", evidence: [], blocked_by: ["G3"]},
          %{name: "QA can serve a prepared checkout", status: "fail", details: "", evidence: [], gap: "G1"}
        ]
      })

      client =
        linear_client(
          create:
            create_by_title(%{
              "Epic review fails: QA can serve a prepared checkout" => {"tool-id", "TP-950"},
              "Epic review fails: No walkthrough" => {"walk-id", "TP-951"},
              "Epic review fails: Check the walkthrough" => {"check-id", "TP-952"}
            })
        )

      assert :ok = run(epic(), linear_client: client)

      assert Enum.map(created_subissues(), & &1["title"]) == [
               "Epic review fails: QA can serve a prepared checkout",
               "Epic review fails: No walkthrough",
               "Epic review fails: Check the walkthrough"
             ]

      assert relations() == [{"tool-id", "walk-id"}, {"walk-id", "check-id"}]
    end

    test "a gap that waits on another gap of the same answer is filed after it, blocked by it" do
      agent_result(:fail, %{
        summary: "The walkthrough needs a QA tool that is not there.",
        steps: [
          @checked_row,
          %{name: "Record the Add Repo walkthrough", status: "fail", details: "No QA run.", evidence: [], checklist: true, gap: "G2", blocked_by: [" g1 "]},
          %{name: "QA can serve a prepared checkout", status: "fail", details: "No tool.", evidence: [], gap: "G1"}
        ]
      })

      client =
        linear_client(
          create:
            create_by_title(%{
              "Epic review fails: QA can serve a prepared checkout" => {"tool-id", "TP-950"},
              "Epic review fails: Record the Add Repo walkthrough" => {"walk-id", "TP-951"}
            })
        )

      assert :ok = run(epic(), linear_client: client)

      # The blocker is filed first, whatever order the answer listed them in.
      assert Enum.map(created_subissues(), & &1["title"]) == [
               "Epic review fails: QA can serve a prepared checkout",
               "Epic review fails: Record the Add Repo walkthrough"
             ]

      assert relations() == [{"tool-id", "walk-id"}]
      assert [{@issue_id, "Epic Review"}, {@issue_id, "Waiting on sub-tickets"}] = state_updates()
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 2}} | _] = signals()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "- TP-950 Epic review fails: QA can serve a prepared checkout\n"
      assert report =~ "- TP-951 Epic review fails: Record the Add Repo walkthrough (blocked by TP-950)"
    end

    test "a gap that waits on a ticket of the epic is filed blocked by that ticket" do
      agent_result(:fail, %{
        summary: "The walkthrough waits on TP-824.",
        steps: [%{name: "Record the walkthrough", status: "fail", details: "Not yet.", evidence: [], blocked_by: ["tp-824"]}]
      })

      client = linear_client(children: [%{"id" => "child-1", "identifier" => "TP-824"}])

      assert :ok = run(epic(), linear_client: client)

      assert [input] = created_subissues()
      assert input["title"] == "Epic review fails: Record the walkthrough"
      assert [{"child-1", new_id}] = relations()
      assert new_id =~ "new-"
    end

    test "a gap whose blocker is neither in the epic nor in the answer is filed without it, and logged" do
      agent_result(:fail, %{
        summary: "Missing.",
        steps: [%{name: "Record the walkthrough", status: "fail", details: "Not yet.", evidence: [], blocked_by: ["TP-555"]}]
      })

      log = capture_log(fn -> assert :ok = run(epic()) end)

      assert [_input] = created_subissues()
      assert relations() == []

      assert log =~
               ~s(Epic review follow-up "Epic review fails: Record the walkthrough" for TP-823 names "TP-555" as its blocker, ) <>
                 "but it is neither a gap of this review nor a ticket of TP-823; filing it without that relation"

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Waiting on sub-tickets"}] = state_updates()
    end

    test "gaps that wait on each other are both filed, the first without the relation that loops" do
      agent_result(:fail, %{
        summary: "Missing.",
        steps: [
          %{name: "First", status: "fail", details: "", evidence: [], gap: "G1", blocked_by: ["G2"]},
          %{name: "Second", status: "fail", details: "", evidence: [], gap: "G2", blocked_by: ["G1"]}
        ]
      })

      client = linear_client(create: create_by_title(%{"Epic review fails: First" => {"first-id", "TP-950"}, "Epic review fails: Second" => {"second-id", "TP-951"}}))

      log = capture_log(fn -> assert :ok = run(epic(), linear_client: client) end)

      assert Enum.map(created_subissues(), & &1["title"]) == ["Epic review fails: First", "Epic review fails: Second"]
      assert relations() == [{"first-id", "second-id"}]
      assert log =~ ~s(names "G2" as its blocker, but the gaps wait on each other)
    end

    test "a gap whose blocker could not be filed is filed on its own, and logged" do
      agent_result(:fail, %{
        summary: "Missing.",
        steps: [
          %{name: "Make the tool", status: "fail", details: "", evidence: [], gap: "G1"},
          %{name: "Check with the tool", status: "fail", details: "", evidence: [], blocked_by: ["G1"]}
        ]
      })

      client = linear_client(create: create_by_title(%{"Epic review fails: Make the tool" => {:error, :linear_down}}))

      log = capture_log(fn -> assert :ok = run(epic(), linear_client: client) end)

      assert relations() == []
      assert log =~ "Failed to file an epic review follow-up for TP-823: :linear_down"
      assert log =~ ~s(names "G1" as its blocker, but its gap could not be filed)
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 1}} | _] = signals()
    end

    test "a ticket of the epic that Linear no longer lists under it is left out, and the gap still filed" do
      agent_result(:fail, %{
        summary: "Missing.",
        steps: [%{name: "Record the walkthrough", status: "fail", details: "", evidence: [], blocked_by: ["TP-824"]}]
      })

      log = capture_log(fn -> assert :ok = run(epic()) end)

      # Refused before anything was created, then filed without the relation.
      assert [_input] = created_subissues()
      assert relations() == []
      assert log =~ ~s(names "TP-824" as its blocker, but Linear does not list it under TP-823)
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 1}} | _] = signals()
    end

    test "a follow-up whose relation Linear refused still counts as filed" do
      agent_result(:fail, %{
        summary: "Missing.",
        steps: [%{name: "Record the walkthrough", status: "fail", details: "", evidence: [], blocked_by: ["TP-824"]}]
      })

      client =
        linear_client(
          children: [%{"id" => "child-1", "identifier" => "TP-824"}],
          create: create_by_title(%{"Epic review fails: Record the walkthrough" => {"walk-id", "TP-951"}}),
          relation: {:error, :linear_down}
        )

      log = capture_log(fn -> assert :ok = run(epic(), linear_client: client) end)

      assert [_input] = created_subissues()
      assert log =~ "Filed epic review follow-up TP-951 for TP-823 without its blocker TP-824"
      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", filed: 1}} | _] = signals()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "- TP-951 Epic review fails: Record the walkthrough\n"
    end

    test "a team with no Todo state leaves the gaps unfiled and blocks the run" do
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})
      states = [%{"id" => "state-backlog", "name" => "Backlog", "type" => "backlog"}]

      log =
        capture_log(fn ->
          assert :ok = run(epic(), linear_client: linear_client(states: states))
        end)

      assert log =~ "child_state_not_found"
      assert [{@issue_id, "Epic Review"}] = state_updates()
    end

    test "a pass that resolved no checklist row of the epic is blocked, not done" do
      agent_result(:pass, %{summary: "All good.", steps: [%{name: "Look around", status: "pass", details: "Fine.", evidence: []}]})

      assert :ok = run(epic())

      assert [{@issue_id, "Epic Review"}] = state_updates()
      assert [%{outcome: "blocked"} | _] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "answered pass without a verdict on any row of TP-823's checklist"
    end

    test "a pass that skipped most of the epic's checklist rows is blocked with the rows named" do
      description = """
      ## Acceptance criteria

      - [ ] One
      - [ ] Two
      - [ ] Three
      """

      agent_result(:pass, %{
        summary: "Mostly fine.",
        steps: [
          %{name: "One", status: "pass", details: "Fine.", evidence: [], checklist: true},
          %{name: "Two", status: "skipped", details: "Could not check.", evidence: [], checklist: true},
          %{name: "Three", status: "blocked", details: "No access.", evidence: [], checklist: true}
        ]
      })

      assert :ok = run(epic(%{description: description}))

      assert [%{outcome: "blocked"} | _] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "did not check 2 of the 3 rows of TP-823's checklist: Two; Three"
    end

    test "a move that fails is reported as an error for the next tick" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :rate_limited})

      assert {:error, {:epic_review_move_failed, :epic_review_enter, :rate_limited}} = run(epic())
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_result)
    end

    test "an epic with no checklist rows of its own passes without the row rule" do
      agent_result(:pass, %{summary: "Nothing to check off."})

      assert :ok = run(epic(%{description: "Just context."}))

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()
      assert [%{outcome: "pass"} | _] = verdicts()
    end

    test "an epic with no url files its follow-up without one" do
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})

      assert :ok = run(epic(%{url: nil}))

      assert [input] = created_subissues()
      assert input["description"] =~ "The epic review of TP-823 failed on commit `c0ffee001122`"
      refute input["description"] =~ "TP-823 ("
    end

    test "the review's own reason is what the gaps move records" do
      agent_result(:fail, %{
        summary: "Missing.",
        reason: "the export button is missing",
        steps: [
          %{name: "Settings exports the report", status: "fail", details: "There is no button.", evidence: [], checklist: true}
        ]
      })

      assert :ok = run(epic())

      assert [%{name: "epic_review", details: %{signal: "epic_review_gaps", reason: reason}} | _] = signals()
      assert reason == "the export button is missing"
    end

    test "a qa: label on the epic narrows the playbooks the review offers" do
      agent_result(:pass, %{summary: "Every requirement is met."})
      settings = put_in(settings!().auto_review.playbooks, %{"macos_app" => %{"build" => "make -C macos app", "app" => "macos/build/Symphony.app"}})

      assert :ok = run(epic(%{labels: ["plan", "qa:macos_app"]}), settings: settings)

      assert_received {:qa_agent_run, job, _settings, _opts}
      assert Enum.map(job.playbooks, & &1.kind) == ["macos_app"]
    end

    test "the moves go through the tracker the caller names, with the caller's retry settings" do
      agent_result(:pass, %{summary: "Every requirement is met."})

      assert :ok = run(epic(), tracker: FakeMoveTracker, linear_retry_opts: [max_wait_ms: 5])

      assert_received {:tracker_move, @issue_id, "Epic Review"}
      assert_received {:tracker_move, @issue_id, "Done"}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "an epic with no identifier is labelled by its id" do
      agent_result(:pass, %{summary: "Every requirement is met."})

      log = capture_log(fn -> assert :ok = run(epic(%{identifier: nil})) end)

      assert log =~ "Epic review passed for #{inspect(@issue_id)}"
      assert [%{outcome: "pass"} | _] = verdicts()
    end

    test "an agent verdict the review does not know is an error, not a move" do
      agent_result(:bogus, %{summary: "?"})

      assert {:error, {:epic_review_unknown_verdict, :bogus}} = run(epic())

      assert [{@issue_id, "Epic Review"}] = state_updates()
      assert verdicts() == []
    end
  end

  describe "run/3 on a red base branch head" do
    @red_run "https://github.com/acme/app/actions/runs/501"

    # The review already reran this commit's failed run once and it failed again, so the agent
    # judges the red commit (`SymphonyElixir.EpicReview.CiRerun`).
    setup do
      RunStore.record_ticket_signal(@repo_key, @issue_id, "ci_rerun", %{
        sha: @sha,
        runs: [%{id: "501", workflow: "CI", url: @red_run, jobs: ["verify"], tests: []}]
      })
    end

    # `gh` on a commit whose `CI` run 501 failed in its `verify` job (601) and whose `release` run
    # passed: the runs, the failed run's jobs, the job's annotations and its failed log.
    defp red_gh(overrides \\ %{}) do
      recipient = self()

      fn args, opts ->
        send(recipient, {:gh, args, opts[:cd]})

        case Map.fetch(overrides, hd(tl(args))) do
          {:ok, answer} -> answer.(args)
          :error -> red_answer(args)
        end
      end
    end

    defp red_answer(["run", "list", "--commit", @sha | _rest]) do
      runs = [
        ci_run("CI", "completed", %{"databaseId" => 501, "conclusion" => "failure", "url" => @red_run}),
        ci_run("release", "completed", %{"databaseId" => 502})
      ]

      {Jason.encode!(runs), 0}
    end

    defp red_answer(["run", "view", "501", "-R", "acme/app", "--json", _fields]) do
      job = %{
        "databaseId" => 601,
        "name" => "verify",
        "conclusion" => "failure",
        "url" => @red_run <> "/job/601",
        "steps" => [%{"name" => "Verify app bundle", "conclusion" => "failure"}]
      }

      {Jason.encode!(%{"url" => @red_run, "workflowName" => "CI", "jobs" => [job]}), 0}
    end

    defp red_answer(["api", "repos/acme/app/check-runs/601/annotations"]) do
      {Jason.encode!([%{"annotation_level" => "failure", "path" => ".github", "start_line" => 30, "message" => "Process completed with exit code 141."}]), 0}
    end

    defp red_answer(["run", "view", "--job", "601", "--log-failed", "-R", "acme/app"]) do
      {"verify\tVerify app bundle\t2026-10-20T06:30:00.000Z checking the bundle\n" <>
         "verify\tVerify app bundle\t2026-10-20T06:30:01.000Z printf: write error: Broken pipe\n", 0}
    end

    defp ci_step(details), do: %{name: "CI on c0ffee001122", status: "fail", details: details, evidence: []}

    test "files the CI follow-up with the failing step's log tail and annotations, read by Symphony" do
      agent_result(:fail, %{
        steps: [
          ci_step("The CI workflow failed (#{@red_run}); its verify job is red."),
          %{name: "Settings shows the API key field", status: "fail", details: "There is no field.", evidence: []}
        ]
      })

      assert :ok = run(epic(), gh_runner: red_gh())

      assert [ci, other] = created_subissues()
      assert ci["title"] == "Epic review fails: CI on c0ffee001122"
      assert ci["description"] =~ "## CI log"
      assert ci["description"] =~ "Symphony read the failed jobs of CI on `c0ffee001122`"
      assert ci["description"] =~ "### CI › verify\n\n#{@red_run}/job/601"
      assert ci["description"] =~ "Failed steps: Verify app bundle"
      assert ci["description"] =~ "- failure .github:30 Process completed with exit code 141."
      assert ci["description"] =~ "The last 2 lines of the failed steps' log:\n\n```text\nchecking the bundle\nprintf: write error: Broken pipe\n```"
      # The section sits between the evidence and the acceptance criteria.
      assert ci["description"] =~ ~r/## Evidence.*## CI log.*## Acceptance criteria/s

      refute other["description"] =~ "## CI log"

      assert_received {:gh, ["run", "view", "--job", "601", "--log-failed", "-R", "acme/app"], _cwd}
      refute_received {:gh, ["run", "view", "502" | _rest], _cwd}
    end

    test "a step that names a run quotes that run only, not one whose id it starts" do
      runs = [
        ci_run("CI", "completed", %{"databaseId" => 50, "conclusion" => "failure", "url" => "https://github.com/acme/app/actions/runs/50"}),
        ci_run("CI", "completed", %{"databaseId" => 501, "conclusion" => "failure", "url" => @red_run})
      ]

      agent_result(:fail, %{steps: [ci_step("Red: #{@red_run}")]})

      assert :ok = run(epic(), gh_runner: red_gh(%{"list" => fn _args -> {Jason.encode!(runs), 0} end}))

      assert [ci] = created_subissues()
      assert ci["description"] =~ "printf: write error: Broken pipe"
      refute_received {:gh, ["run", "view", "50" | _rest], _cwd}
    end

    test "a finding that names CI without a run quotes every failed run on the commit" do
      agent_result(:fail, %{summary: "Red.", findings: ["CI is red on the default branch", "The export button is absent"]})

      assert :ok = run(epic(), gh_runner: red_gh())

      assert [ci, other] = created_subissues()
      assert ci["description"] =~ "printf: write error: Broken pipe"
      refute other["description"] =~ "## CI log"
    end

    test "a log too long for a ticket keeps its end, and a job without steps or annotations says so" do
      lines = for n <- 1..100, do: "verify\tVerify app bundle\t2026-10-20T06:30:00.000Z line #{n} " <> String.duplicate("x", 200)

      overrides = %{
        "view" => fn
          ["run", "view", "501" | _rest] ->
            {Jason.encode!(%{"url" => @red_run, "jobs" => [%{"databaseId" => 601, "conclusion" => "failure", "url" => nil}]}), 0}

          ["run", "view", "--job", "601" | _rest] ->
            {Enum.join(lines, "\n"), 0}
        end,
        "repos/acme/app/check-runs/601/annotations" => fn _args -> {"[]", 0} end,
        "list" => fn _args -> {Jason.encode!([ci_run("CI", "completed", %{"databaseId" => 501, "conclusion" => "failure", "url" => @red_run, "workflowName" => nil})]), 0} end
      }

      runner = fn args, opts ->
        case args do
          ["api", endpoint] -> Map.fetch!(overrides, endpoint).(args)
          _other -> red_gh(overrides).(args, opts)
        end
      end

      agent_result(:fail, %{steps: [ci_step("Red: #{@red_run}")]})

      assert :ok = run(epic(), gh_runner: runner)

      assert [ci] = created_subissues()
      assert ci["description"] =~ "### Run 501 › 601\n\n#{@red_run}\n"
      assert ci["description"] =~ "Failed steps: none named"
      assert ci["description"] =~ "Annotations:\n\n- none"
      assert ci["description"] =~ "The last 60 lines of the failed steps' log (of 100):\n\n```text\n[... earlier lines cut ...]\n"
      assert ci["description"] =~ "line 100 xxx"
      refute ci["description"] =~ "line 40 "
    end

    test "a log Symphony cannot read is named in the follow-up, and the follow-up is still filed" do
      overrides = %{"view" => fn _args -> {"HTTP 404: Not Found", 1} end}
      agent_result(:fail, %{steps: [ci_step("Red: #{@red_run}")]})

      log = capture_log(fn -> assert :ok = run(epic(), gh_runner: red_gh(overrides)) end)

      assert [ci] = created_subissues()
      assert ci["description"] =~ "### CI\n\n#{@red_run}\n\nSymphony could not read this run's failed log: `{:gh_failed"
      assert log =~ "Epic review could not read the failed log of run 501"
    end

    test "CI that cannot be read files the follow-up without a log" do
      agent_result(:fail, %{steps: [ci_step("The CI workflow failed.")]})

      log = capture_log(fn -> assert :ok = run(epic(), gh_runner: gh_runner({"HTTP 502", 1})) end)

      assert [ci] = created_subissues()
      refute ci["description"] =~ "## CI log"
      assert log =~ "Epic review could not read CI on c0ffee001122 for its follow-up"
    end

    test "a green commit adds no CI log to a CI follow-up" do
      agent_result(:fail, %{steps: [ci_step("The agent thinks CI failed.")]})

      assert :ok = run(epic(), gh_runner: gh_runner([ci_run("CI", "completed")]))

      assert [ci] = created_subissues()
      refute ci["description"] =~ "## CI log"
    end
  end

  describe "run/3 on a red base branch head not rerun yet" do
    @flaky_test "TestAnAppThatDoesntQuitAbandonsTheInstall"

    # `red_gh/1` whose `gh run list` answers each of `lists` in turn and the last one from then on,
    # which accepts the rerun, and whose failed job log names a failed Go test.
    defp rerun_gh(lists) do
      Process.put(:epic_review_run_lists, lists)

      red_gh(%{
        "list" => fn _args ->
          [list | rest] = Process.get(:epic_review_run_lists)
          Process.put(:epic_review_run_lists, if(rest == [], do: [list], else: rest))
          {Jason.encode!(list), 0}
        end,
        "rerun" => fn _args -> {"", 0} end,
        "view" => fn
          ["run", "view", "--job" | _rest] ->
            {"verify\tgo test\t2026-10-20T06:30:00.000Z --- FAIL: #{@flaky_test} (0.30s)\n" <>
               "verify\tgo test\t2026-10-20T06:30:01.000Z printf: write error: Broken pipe\n", 0}

          args ->
            red_answer(args)
        end
      })
    end

    defp red_runs, do: [ci_run("CI", "completed", %{"databaseId" => 501, "conclusion" => "failure", "url" => @red_run}), release_run()]

    defp green_runs, do: [ci_run("CI", "completed", %{"databaseId" => 501, "url" => @red_run}), release_run()]

    defp release_run, do: ci_run("release", "completed", %{"databaseId" => 502})

    defp reruns(messages \\ peek()), do: for({:gh, ["run", "rerun" | _rest] = args, _cwd} <- messages, do: args)

    defp agent_runs(messages \\ peek()), do: for({:qa_agent_run, _job, _settings, _opts} <- messages, do: :run)

    defp signal(name), do: Enum.find(signals(), &(&1.name == name))

    test "reruns the failed jobs once and waits for them: no agent pass, no verdict, no follow-up" do
      {result, log} = with_log(fn -> run(epic(), gh_runner: rerun_gh([red_runs()])) end)

      assert {:error, {:ci_pending, %{sha: @sha, runs: [%{id: "501"}]}}} = result

      assert reruns() == [["run", "rerun", "501", "--failed", "-R", "acme/app"]]
      assert agent_runs() == []
      assert verdicts() == []
      assert created_subissues() == []
      assert comments_posted() == []
      assert log =~ "Epic review reran the failed CI on c0ffee001122: CI (#{@red_run})"

      # The rerun is bound to the commit with what its attempt replaces, and the CI wait starts over.
      assert [%{name: "ci_wait_started", details: %{sha: @sha}}, %{name: "ci_rerun", details: rerun} | _rest] = signals()
      assert %{sha: @sha, runs: [%{id: "501", workflow: "CI", url: @red_run, jobs: ["verify"], tests: [@flaky_test]}]} = rerun
    end

    test "a red run that passes on rerun files no follow-up, records the flake, and the review proceeds" do
      runner = rerun_gh([red_runs(), green_runs()])

      assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: runner)
      assert :ok = run(epic(%{state: "Epic Review"}), gh_runner: runner)

      assert length(reruns()) == 1
      assert agent_runs() == [:run]
      assert created_subissues() == []
      assert [%{kind: "epic_review", head_sha: @sha, outcome: "pass"}] = verdicts()

      assert %{details: %{sha: @sha, runs: [@red_run], workflows: ["CI"], jobs: ["verify"], tests: [@flaky_test]}} = signal("ci_flake")

      assert [{@issue_id, report}] = comments_posted()
      assert report =~ "- **attention** ci_rerun: CI (#{@red_run}) failed and passed on Symphony's rerun, a flake in verify, #{@flaky_test}"
    end

    test "a red run that fails twice files a follow-up whose description contains the log tail" do
      runner = rerun_gh([red_runs()])

      assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: runner)

      agent_result(:fail, %{steps: [ci_step("The CI workflow failed (#{@red_run}); its verify job is red.")]})
      assert :ok = run(epic(%{state: "Epic Review"}), gh_runner: runner)

      assert length(reruns()) == 1
      assert [ci] = created_subissues()
      assert ci["title"] == "Epic review fails: CI on c0ffee001122"
      assert ci["description"] =~ "## CI log"
      assert ci["description"] =~ "--- FAIL: #{@flaky_test} (0.30s)\nprintf: write error: Broken pipe"
      assert signal("ci_flake") == nil

      assert [{@issue_id, report}] = comments_posted()
      assert report =~ "- **attention** ci_rerun: CI (#{@red_run}) is not green after Symphony's rerun"
    end

    test "the rerun is attempted once per head: a third review on the same head does not rerun again" do
      runner = rerun_gh([red_runs()])
      agent_result(:fail, %{summary: "Red.", findings: ["The export button is absent"]})

      assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: runner)
      assert :ok = run(epic(), gh_runner: runner)
      assert :ok = run(epic(), gh_runner: runner)

      assert length(reruns()) == 1
      assert agent_runs() == [:run, :run]
    end

    test "a carried verdict reads no CI and reruns nothing" do
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "epic_review", @sha, "pass")

      assert :ok = run(epic(), gh_runner: rerun_gh([red_runs()]))

      assert reruns() == []
      assert signal("ci_rerun") == nil
    end
  end

  describe "run/3 while CI runs on the base branch head" do
    @now ~U[2026-10-14 18:30:00Z]

    test "waits for CI: no agent pass, no verdict, no report, and the epic stays in Epic Review" do
      runs = [ci_run("make-all", "completed"), ci_run("macos", "in_progress"), ci_run("release", "queued")]

      runner = gh_runner(runs)
      log = capture_log(fn -> assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: runner, now: @now) end)

      assert_received {:gh, ["run", "list", "--commit", @sha, "--limit", "100", "--json", "databaseId,workflowName,status,conclusion,url,createdAt"], _cwd}
      refute_received {:qa_agent_run, _job, _settings, _opts}

      assert log =~ "Epic review for TP-823 waits for CI on c0ffee001122"
      assert log =~ "macos (https://github.com/acme/app/actions/runs/macos), release (https://github.com/acme/app/actions/runs/release) still running"

      assert [{@issue_id, "Epic Review"}] = state_updates()
      assert verdicts() == []
      assert comments_posted() == []
    end

    test "the error carries the commit and the runs still going" do
      runner = gh_runner([ci_run("macos", "in_progress")])

      assert {:error, {:ci_pending, %{sha: @sha, runs: [run]}}} = run(epic(), gh_runner: runner, now: @now)

      assert %{workflow_name: "macos", status: "IN_PROGRESS"} = run
    end

    test "a run with no name or url is still named in the log" do
      unnamed = ci_run("x", "waiting") |> Map.drop(["workflowName", "url"]) |> Map.put("databaseId", 77)

      runner = gh_runner([unnamed])
      log = capture_log(fn -> assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: runner, now: @now) end)

      assert log =~ "a workflow (77) still running"
    end

    test "once every run finished the review runs as usual" do
      runs = [ci_run("make-all", "completed"), ci_run("macos", "completed", %{"conclusion" => "failure"})]

      assert :ok = run(epic(), gh_runner: gh_runner(runs), now: @now)

      assert_received {:qa_agent_run, _job, _settings, _opts}
      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()
    end

    test "CI settling clears the CI wait's pause reason, and the verdict the review reached the QA environment's (TP-1250)" do
      ticket = {:ticket, @repo_key, @issue_id}
      {:ok, _pause} = CiWait.pause(@repo_key, @issue_id, @sha)
      {:ok, _pause} = Pauses.set(ticket, SelfHeal.environment_reason("worker_host"))

      assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: gh_runner([ci_run("macos", "in_progress")]), now: @now)
      assert Pauses.why(ticket) == ["Waiting for CI on #{String.slice(@sha, 0, 12)} to finish", "The QA machine is not reachable"]

      assert :ok = run(epic(), gh_runner: gh_runner([ci_run("macos", "completed")]), now: @now)
      assert {:ok, nil} = Pauses.get(ticket)
    end

    test "a review that reaches a fail verdict saw the QA environment working too" do
      ticket = {:ticket, @repo_key, @issue_id}
      {:ok, _pause} = Pauses.set(ticket, SelfHeal.environment_reason("worker_host"))
      agent_result(:fail, %{summary: "Missing.", findings: ["The export button is absent"]})

      assert :ok = run(epic(), gh_runner: gh_runner([]), now: @now)
      assert {:ok, nil} = Pauses.get(ticket)
    end

    test "a run unfinished for over two hours is stuck, not waited on: the review runs and reports it" do
      stuck = ci_run("macos", "queued", %{"createdAt" => "2026-10-14T16:29:59Z"})
      fresh_enough = ci_run("release", "completed", %{"createdAt" => nil})

      assert :ok = run(epic(), gh_runner: gh_runner([stuck, fresh_enough]), now: @now)

      assert_received {:qa_agent_run, _job, _settings, _opts}
    end

    test "a run with no start time is waited on, and the clock defaults to now" do
      no_start = ci_run("macos", "in_progress", %{"createdAt" => nil})

      assert {:error, {:ci_pending, _info}} = run(epic(), gh_runner: gh_runner([no_start]))
    end

    test "a commit whose review already passed is carried without reading CI" do
      :ok = TicketSignals.record_verdict(@repo_key, @issue_id, "epic_review", @sha, "pass")

      assert :ok = run(epic(), gh_runner: gh_runner([ci_run("macos", "in_progress")]), now: @now)

      refute_received {:gh, _args, _cwd}
      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()
    end
  end

  describe "run/3 on a blocked review" do
    test "retries boundedly on the same commit, then files the fix ticket and holds the epic" do
      agent_error(:environment_unreachable)

      assert :ok = run(epic())

      assert [{@issue_id, "Epic Review"}] = state_updates()
      refute Hold.held?(@repo_key, @issue_id, :blocked)
      refute_received {:fixer_create, _}

      assert :ok = run(epic(%{state: "Epic Review"}))

      assert %{reason: reason, waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}} =
               Hold.get(@repo_key, @issue_id, :blocked)

      assert reason =~ "waiting on fix ticket TP-900"
      assert_received {:fixer_create, attrs}
      assert attrs.scope == @symphony_repo_key
      assert_received {:fixer_block, @fix_ticket}

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked"]
      assert Enum.all?(verdicts(), &(&1.head_sha == @sha))
      assert [{@issue_id, "Epic Review"}] = state_updates()

      assert_received {:memory_tracker_comment, @issue_id, retrying}
      assert retrying =~ "**Verdict:** blocked → TP-823 Epic Review (blocked, retrying)"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → TP-823 Epic Review (blocked)"
    end

    test "a block only a person can clear goes straight to the hold a person lifts" do
      agent_result(:blocked, %{summary: "Needs a person.", reason: "The app needs a real key.", needs_person: true})

      log = capture_log(fn -> assert :ok = run(epic()) end)

      # Not retried: the retry would burn the same block again, so it goes straight to the hold.
      assert log =~ "needs a person"
      refute log =~ "retrying"
      assert Hold.held?(@repo_key, @issue_id, :blocked)
      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "**Verdict:** blocked → TP-823 Epic Review (blocked)"
    end

    test "a usage limit holds the run instead of applying a verdict" do
      agent_error({:usage_limited, %{resets_at: DateTime.utc_now()}})

      assert {:error, {:usage_limited, %{}}} = run(epic())

      assert state_updates() == [{@issue_id, "Epic Review"}]
      assert verdicts() == []
      refute_received {:memory_tracker_comment, _issue_id, _body}
    end

    test "a CI read that fails is not waited on: the review runs and judges CI itself" do
      log = capture_log(fn -> assert :ok = run(epic(), gh_runner: gh_runner({"HTTP 502", 1})) end)

      assert log =~ "Epic review could not read CI on c0ffee001122; reviewing without waiting for it"
      assert_received {:qa_agent_run, _job, _settings, _opts}
      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()
    end

    test "a base branch head that cannot be read blocks the run with the reason" do
      failing = git(%{rev_parse: {"", 128}})

      assert :ok = run(epic(), git: failing)

      assert [%{outcome: "blocked"} | _] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "could not read the head of origin/main"
    end

    test "a report that cannot be published does not stop the verdict" do
      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :rate_limited})

      log = capture_log(fn -> assert :ok = run(epic()) end)

      assert log =~ "Failed to publish the epic review report for TP-823"

      assert [{@issue_id, "Epic Review"}, {@issue_id, "Done"}] = state_updates()
      assert [%{outcome: "pass"} | _] = verdicts()
    after
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_result)
    end

    test "a block the self-heal lane cannot scope is reported as an error" do
      agent_error(:environment_unreachable)

      # Two attempts, each retried boundedly, then the block goes to the self-heal lane — which
      # cannot resolve a scope for this one.
      assert :ok = run(epic())
      assert :ok = run(epic(%{state: "Epic Review"}))

      assert {:error, {:epic_review_self_heal_failed, {:self_heal_scope_unknown, "qa_environment"}}} =
               run(epic(%{state: "Epic Review"}), symphony_repo_key: nil)

      assert Enum.map(verdicts(), & &1.outcome) == ["blocked", "blocked", "blocked"]
    end

    test "a review dispatched to a remote worker is blocked, not run where the workspace is not" do
      log = capture_log(fn -> assert :ok = run(epic(), worker_host: "worker-1") end)

      assert [{@issue_id, "Epic Review"}] = state_updates()
      refute_received {:git, _args, _cwd}
      refute_received {:qa_agent_run, _job, _settings, _opts}

      assert [%{outcome: "blocked"} | _] = verdicts()
      assert log =~ "retrying"

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "Reason: QA does not run on remote workers yet (worker-1)"
      assert report =~ "**Commit:** `` (head of `origin/main`)"
    end

    test "with no git runner injected the review reads the base branch head itself" do
      workspace = Path.join(System.tmp_dir!(), "epic-review-not-a-repo-#{System.unique_integer([:positive])}")

      assert :ok = EpicReview.run(epic(), workspace, Keyword.delete(default_opts(), :git))

      assert [{@issue_id, "Epic Review"}] = state_updates()
      assert [%{outcome: "blocked"} | _] = verdicts()

      assert_received {:memory_tracker_comment, @issue_id, report}
      assert report =~ "could not read the head of origin/main"
    end
  end
end
