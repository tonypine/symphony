defmodule SymphonyElixir.HumanActions.CollectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Collector, Request}

  @project %{"id" => "project-1", "name" => "Cycle"}
  @scope %{"team" => %{"key" => %{"eq" => "MOT"}}}

  defp settings, do: %Schema{}

  defp collect(nodes, opts \\ []) do
    test_pid = self()

    client = fn query, variables, _opts ->
      send(test_pid, {:query, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => Keyword.get(opts, :next_page, false)}}}}}
    end

    Collector.collect(Keyword.get(opts, :repos, [:repo]),
      settings: Keyword.get(opts, :settings, settings()),
      linear_client: client,
      scope_filter: fn _repo -> {:ok, @scope} end
    )
  end

  defp node(identifier, attrs) do
    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "description" => nil,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "state" => %{"name" => "Backlog"},
        "project" => @project,
        "labels" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => []}
      },
      attrs
    )
  end

  defp labels(names), do: %{"nodes" => Enum.map(names, &%{"name" => &1})}
  defp comments(comments), do: %{"nodes" => comments}
  defp history(entries), do: %{"nodes" => entries}

  defp request_comment(id, title, created_at) do
    body = Request.render(%{title: title, why: "Release fails.", unblocks: "the Release workflow", est_minutes: 10, steps: ["Add the secret."]}, "human-action")
    %{"id" => id, "body" => body, "createdAt" => created_at}
  end

  defp actions(%{"project-1" => %{project: project, actions: actions}}) do
    assert project == %{id: "project-1", name: "Cycle"}
    Enum.sort_by(actions, & &1.key)
  end

  test "queries the route's scope for labelled or in-review issues that are not terminal" do
    assert {:ok, %{}} = collect([])

    assert_received {:query, query, variables}
    assert query =~ "query SymphonyHumanActions("
    assert variables.first == 50

    assert variables.filter == %{
             "and" => [
               @scope,
               %{
                 "or" => [
                   %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "human-action"}}}},
                   %{"state" => %{"name" => %{"eqIgnoreCase" => "In Review"}}}
                 ]
               },
               %{"state" => %{"name" => %{"nin" => ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]}}}
             ]
           }
  end

  test "lists each open request on a labelled issue, and drops the ones the issue moved on from" do
    issue =
      node("MOT-24", %{
        "labels" => labels(["Human-Action"]),
        "comments" =>
          comments([
            request_comment("comment-old", "Add the old secret", "2026-10-01T10:00:00.000Z"),
            %{"id" => "comment-workpad", "body" => "## Symphony Workpad", "createdAt" => "2026-10-02T10:00:00.000Z"},
            request_comment("comment-new", "Add the release signing secrets", "2026-10-03T10:00:00.000Z")
          ]),
        "history" =>
          history([
            # A person moved the issue on after the old request: it is done.
            %{"createdAt" => "2026-10-02T09:00:00.000Z", "fromState" => %{"name" => "Backlog"}, "toState" => %{"name" => "Todo"}},
            # The agent's own moves after the new request keep it open, and so does Auto Review's.
            %{"createdAt" => "2026-10-03T10:05:00.000Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Backlog"}},
            %{"createdAt" => "2026-10-03T11:00:00.000Z", "fromState" => %{"name" => "Auto Review"}, "toState" => %{"name" => "Backlog"}},
            # Entries that are not state changes, or carry no time, are ignored.
            %{"createdAt" => "2026-10-03T12:00:00.000Z", "fromState" => nil, "toState" => nil},
            %{"createdAt" => "not a time", "fromState" => %{"name" => "Backlog"}, "toState" => %{"name" => "Todo"}}
          ])
      })

    assert {:ok, collected} = collect([issue])

    assert [
             %Action{
               key: "request:comment-new",
               kind: :request,
               title: "Add the release signing secrets",
               why: "Release fails.",
               unblocks: "the Release workflow",
               est_minutes: 10,
               steps: ["Add the secret."],
               issue: %{id: "id-MOT-24", identifier: "MOT-24", url: "https://linear.app/acme/issue/MOT-24", state: "Backlog"},
               done_when: "you remove the `human-action` label from MOT-24, or move it on once it is unblocked."
             }
           ] = actions(collected)
  end

  test "lists a labelled issue without a request as a task, and one whose requests all closed as nothing" do
    task =
      node("MOT-31", %{
        "title" => "Turn on the pre-push hook",
        "labels" => labels(["human-action"]),
        "description" => "On your laptop:\n\n1. Run `git config core.hooksPath .githooks`\n2. Push once"
      })

    closed =
      node("MOT-32", %{
        "labels" => labels(["human-action"]),
        "comments" => comments([request_comment("comment-1", "Old", "2026-10-01T10:00:00.000Z")]),
        "history" => history([%{"createdAt" => "2026-10-02T10:00:00.000Z", "fromState" => %{"name" => "Backlog"}, "toState" => %{"name" => "Todo"}}])
      })

    assert {:ok, collected} = collect([task, closed])

    assert [
             %Action{
               key: "task:id-MOT-31",
               kind: :task,
               title: "Turn on the pre-push hook",
               steps: ["Run `git config core.hooksPath .githooks`", "Push once"],
               done_when: "you close MOT-31, or remove its `human-action` label."
             }
           ] = actions(collected)
  end

  test "lists a breakdown parent waiting in In Review for its plan" do
    parent = node("MOT-40", %{"state" => %{"name" => "In Review"}, "labels" => labels(["breakdown"])})

    assert {:ok, collected} = collect([parent, node("MOT-41", %{"labels" => labels(["breakdown"])})])

    assert [
             %Action{
               key: "plan:id-MOT-40",
               kind: :plan_review,
               title: "Approve the breakdown plan for MOT-40",
               est_minutes: 10,
               steps: [
                 "Read the plan in the `## Symphony Workpad` comment on MOT-40.",
                 "To approve, move MOT-40 to `Waiting on sub-tickets`; Symphony moves its sub-tickets to Todo.",
                 "To reject it, comment what to change and move MOT-40 to `Rework`."
               ],
               done_when: "MOT-40 leaves In Review."
             }
           ] = actions(collected)

    no_waiting_state = %Schema{tracker: %{settings().tracker | waiting_on_sub_issues_state: nil}}
    assert {:ok, collected} = collect([parent], settings: no_waiting_state)
    assert [%Action{steps: [_read, "To approve, move the sub-tickets you accept to Todo.", _reject]}] = actions(collected)
  end

  test "lists an In Review issue whose latest QA report is blocked" do
    blocked_report = "## Symphony QA Report\n\n**Verdict:** blocked → In Review\n**PR head:** `abc`\n\nReason: the QA host has no Screen Recording permission\n"

    blocked =
      node("MOT-52", %{
        "state" => %{"name" => "In Review"},
        "comments" => comments([%{"id" => "c1", "body" => blocked_report, "createdAt" => "2026-10-03T10:00:00.000Z"}, %{"id" => "c2", "body" => nil}])
      })

    no_reason =
      node("MOT-53", %{
        "state" => %{"name" => "in review"},
        "comments" => comments([%{"id" => "c3", "body" => "## Symphony QA Report\n\n**Verdict:** blocked → In Review\n", "createdAt" => "2026-10-03T10:00:00.000Z"}])
      })

    passed = node("MOT-54", %{"state" => %{"name" => "In Review"}, "comments" => comments([%{"id" => "c4", "body" => "## Symphony QA Report\n\n**Verdict:** pass → In Review\n"}])})
    no_report = node("MOT-55", %{"state" => %{"name" => "In Review"}})

    assert {:ok, collected} = collect([blocked, no_reason, passed, no_report])

    assert [
             %Action{
               key: "qa:id-MOT-52",
               kind: :qa_blocked,
               title: "Unblock QA for MOT-52",
               why: "Auto Review could not test the PR: the QA host has no Screen Recording permission",
               unblocks: "the review of its PR",
               done_when: "MOT-52 leaves In Review, or its next QA report is not blocked."
             },
             %Action{key: "qa:id-MOT-53", why: "Auto Review could not test the PR: see the QA report on MOT-53"}
           ] = actions(collected)
  end

  test "skips issues outside a project and merges what several routes return" do
    task = node("MOT-31", %{"labels" => labels(["human-action"])})
    other_project = node("ENG-1", %{"labels" => labels(["human-action"]), "project" => %{"id" => "project-2", "name" => nil}})
    no_project = node("MOT-60", %{"labels" => labels(["human-action"]), "project" => nil})
    no_state = node("MOT-61", %{"labels" => labels(["human-action"]), "state" => nil})

    assert {:ok, collected} = collect([task, other_project, no_project, no_state], repos: [:web, :api])

    assert Map.keys(collected) == ["project-1", "project-2"]
    assert [%Action{key: "task:id-MOT-31"}, %Action{key: "task:id-MOT-61", issue: %{state: nil}}] = collected["project-1"].actions
    assert %{project: %{id: "project-2", name: nil}, actions: [%Action{key: "task:id-ENG-1"}]} = collected["project-2"]
  end

  test "warns when there are more issues than one page" do
    log = capture_log(fn -> assert {:ok, %{}} = collect([], next_page: true) end)
    assert log =~ "more than 50 issues to read"
  end

  test "fails as a whole when a route cannot be read" do
    opts = [settings: settings(), scope_filter: fn _repo -> {:ok, @scope} end]

    assert {:error, :missing_linear_api_token} =
             Collector.collect([:repo], Keyword.put(opts, :scope_filter, fn _repo -> {:error, :missing_linear_api_token} end))

    assert {:error, :linear_down} = Collector.collect([:repo], Keyword.put(opts, :linear_client, fn _query, _variables, _opts -> {:error, :linear_down} end))

    errors = %{"errors" => [%{"message" => "bad filter"}]}

    assert {:error, {:human_actions_query_failed, ^errors}} =
             Collector.collect([:repo], Keyword.put(opts, :linear_client, fn _query, _variables, _opts -> {:ok, errors} end))
  end
end
