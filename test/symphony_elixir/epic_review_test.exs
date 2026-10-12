defmodule SymphonyElixir.EpicReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.EpicReview
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Hold
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QaAgent
  alias SymphonyElixir.RunStore
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
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
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
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"}, extra))

    settings
  end

  defp legacy_settings, do: settings!(%{"state_machine" => "legacy"})

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
                 "team" => %{"id" => "team-1", "states" => %{"nodes" => states}},
                 "children" => %{"nodes" => []}
               }
             }
           }}

        query =~ "SymphonyAgentCreateSubissue" ->
          n = System.unique_integer([:positive])
          create_result || {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{"id" => "new-#{n}", "identifier" => "TP-9#{n}"}}}}}

        query =~ "SymphonyAgentCreateIssueRelation" ->
          {:ok, %{"data" => %{"issueCreate" => %{"success" => true}}}}
      end
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
      linear_client: linear_client()
    ]
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
    test "is true only for a designed repo's epic parent, in the review state or ready for it" do
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
      refute EpicReview.epic_review_run?(epic(), legacy_settings())
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
      issue =
        epic(%{
          comments: [%{id: "c1", body: "Please check the settings window.", author: "kim"}],
          pull_request_url: "https://github.com/acme/app/pull/7"
        })

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

    test "an epic with nothing recorded and no checklist rows lists all four as evidence to derive" do
      issue = epic(%{description: "Just context.", comments: [%{id: "c1"}], pr_urls: []})

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
      assert :skip = run(epic(), settings: legacy_settings())
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
