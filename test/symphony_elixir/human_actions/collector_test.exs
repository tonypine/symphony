defmodule SymphonyElixir.HumanActions.CollectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Collector, Request, Update}
  alias SymphonyElixir.QaAgent.Report

  @project %{"id" => "project-1", "name" => "Cycle"}
  @scope %{"team" => %{"key" => %{"eq" => "MOT"}}}

  # Most tests read issues a config that predates the Human Review state labelled: it still sets
  # the deprecated `human_actions.label`.
  defp settings, do: put_in(%Schema{}.human_actions.label, "human-action")

  defp collect(nodes, opts \\ []) do
    test_pid = self()

    client = fn query, variables, _opts ->
      send(test_pid, {:query, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}
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

  defp page(nodes, page_info), do: %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => page_info}}}

  defp labels(names), do: %{"nodes" => Enum.map(names, &%{"name" => &1})}
  defp comments(comments), do: %{"nodes" => comments}
  defp history(entries), do: %{"nodes" => entries}

  defp request_comment(id, title, created_at) do
    options = [%{label: "Add it", effect: "Releases sign again.", recommended: true}, %{label: "Drop signing", effect: "Releases ship unsigned."}]

    body =
      Request.render(
        %{title: title, question: "Add the signing secret?", why: "Release fails.", unblocks: "the Release workflow", est_minutes: 10, options: options},
        "Human Review"
      )

    %{"id" => id, "body" => body, "createdAt" => created_at}
  end

  defp actions(%{"project-1" => %{project: project, actions: actions}}) do
    assert project == %{id: "project-1", name: "Cycle"}
    Enum.sort_by(actions, & &1.key)
  end

  test "collect_all/2 also lists the issues waiting on a person, from the same read" do
    nodes = [node("MOT-1", %{"state" => %{"name" => "In Review"}}), node("MOT-2", %{})]
    client = fn _query, _variables, _opts -> {:ok, page(nodes, %{"hasNextPage" => false})} end
    opts = [settings: settings(), linear_client: client, scope_filter: fn _repo -> {:ok, @scope} end]

    assert {:ok, %{}, [%{identifier: "MOT-1", kind: :pr}]} = Collector.collect_all([:repo], opts)
    assert {:error, :down} = Collector.collect_all([:repo], Keyword.put(opts, :scope_filter, fn _repo -> {:error, :down} end))
  end

  test "queries the route's scope for labelled, In Review, Human Review or final verification issues that are not terminal" do
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
                   %{"state" => %{"name" => %{"eqIgnoreCase" => "In Review"}}},
                   %{"state" => %{"name" => %{"eqIgnoreCase" => "Human Review"}}},
                   %{"title" => %{"startsWith" => "Final verification:"}}
                 ]
               },
               %{"state" => %{"name" => %{"nin" => ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]}}}
             ]
           }
  end

  test "with the default settings, queries no label, and lists a request on an unlabelled issue in Human Review" do
    issue =
      node("MOT-25", %{
        "state" => %{"name" => "Human Review"},
        # A request a supervisor wrote by hand, in the older format, still lists.
        "comments" =>
          comments([
            %{"id" => "comment-1", "body" => "## Action needed: Add the release signing secrets\n\n**Steps:**\n1. Add them.", "createdAt" => "2026-10-03T10:00:00.000Z"}
          ]),
        "history" => history([%{"createdAt" => "2026-10-03T10:00:05.000Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Human Review"}}])
      })

    # Without the deprecated setting, the label marks nothing.
    labelled = node("MOT-26", %{"labels" => labels(["human-action"])})

    assert {:ok, collected} = collect([issue, labelled], settings: %Schema{})

    assert [
             %Action{
               key: "request:comment-1",
               kind: :request,
               human_review: true,
               steps: ["Add them."],
               options: [],
               done_when: "you move MOT-25 out of Human Review once it is unblocked, or the agent withdraws the request."
             }
           ] = actions(collected)

    assert_received {:query, _query, %{filter: %{"and" => [_scope, %{"or" => wanted}, _terminal]}}}

    assert wanted == [
             %{"state" => %{"name" => %{"eqIgnoreCase" => "In Review"}}},
             %{"state" => %{"name" => %{"eqIgnoreCase" => "Human Review"}}},
             %{"title" => %{"startsWith" => "Final verification:"}}
           ]
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
            %{"createdAt" => "not a time", "fromState" => %{"name" => "Backlog"}, "toState" => %{"name" => "Todo"}},
            %{"fromState" => %{"name" => "Backlog"}, "toState" => %{"name" => "Todo"}}
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
               question: "Add the signing secret?",
               options: ["**Add it** (recommended): Releases sign again.", "**Drop signing**: Releases ship unsigned."],
               steps: [],
               issue: %{id: "id-MOT-24", identifier: "MOT-24", url: "https://linear.app/acme/issue/MOT-24", state: "Backlog"},
               done_when: "you reply with your pick and move MOT-24 out of Backlog, or the agent withdraws the request."
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
               done_when: "you close MOT-31, or move it on."
             }
           ] = actions(collected)
  end

  test "drops a withdrawn request, and lists a labelled issue whose requests were all withdrawn as nothing" do
    withdrawal = fn id, parent_id ->
      %{"id" => id, "body" => Request.render_withdrawal("Not needed."), "createdAt" => "2026-10-04T19:00:00.000Z", "parent" => %{"id" => parent_id}}
    end

    partly =
      node("MOT-33", %{
        "labels" => labels(["human-action"]),
        "comments" =>
          comments([
            request_comment("comment-1", "Re-run the stuck dialyzer job", "2026-10-04T18:57:00.000Z"),
            request_comment("comment-2", "Add the release signing secrets", "2026-10-04T18:58:00.000Z"),
            withdrawal.("reply-1", "comment-1"),
            %{"id" => "reply-2", "body" => "Still waiting on this.", "createdAt" => "2026-10-04T19:01:00.000Z", "parent" => %{"id" => "comment-2"}},
            Map.put(withdrawal.("comment-3", "comment-9"), "parent", nil)
          ])
      })

    all_withdrawn =
      node("MOT-34", %{
        "labels" => labels(["human-action"]),
        "comments" => comments([request_comment("comment-4", "Re-run CI", "2026-10-04T18:57:00.000Z"), withdrawal.("reply-4", "comment-4")])
      })

    assert {:ok, collected} = collect([partly, all_withdrawn])
    assert [%Action{key: "request:comment-2", title: "Add the release signing secrets"}] = actions(collected)
  end

  test "lists a breakdown parent waiting in In Review for its plan" do
    parent = node("MOT-40", %{"state" => %{"name" => "In Review"}, "labels" => labels(["breakdown"])})

    assert {:ok, collected} = collect([parent, node("MOT-41", %{"labels" => labels(["breakdown"])})])

    assert [
             %Action{
               key: "plan:id-MOT-40",
               kind: :plan_review,
               title: "Approve the plan for MOT-40",
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

  defp blocked_issue(identifier, state, reason) do
    body = "## Symphony QA Report\n\n**Verdict:** blocked → #{state}\n**PR head:** `abc`\n\n#{if reason, do: "Reason: " <> reason <> "\n"}"
    node(identifier, %{"state" => %{"name" => state}, "comments" => comments([%{"id" => "c-" <> identifier, "body" => body, "createdAt" => "2026-10-03T10:00:00.000Z"}])})
  end

  test "asks once for the app update that unblocks every issue QA-blocked on the running app" do
    api_fixtures = blocked_issue("MOT-56", "Human Review", "QA needs `api_fixtures`, which the running app (0.0.1.384) lacks.")
    put_file = blocked_issue("MOT-52", "In Review", "QA needs `qa_put_file`, which the running app (0.0.1.384) lacks")

    assert {:ok, collected} = collect([api_fixtures, put_file])

    assert [
             %Action{
               key: "qa:app_update:id-MOT-52,id-MOT-56",
               kind: :qa_blocked,
               title: "Update the Symphony app",
               issue: nil,
               human_review: false,
               est_minutes: 5,
               why: "MOT-52: QA needs `qa_put_file`, which the running app (0.0.1.384) lacks. MOT-56: QA needs `api_fixtures`, which the running app (0.0.1.384) lacks.",
               unblocks: "the QA of [MOT-52](https://linear.app/acme/issue/MOT-52) and [MOT-56](https://linear.app/acme/issue/MOT-56)",
               steps: ["Update the Symphony app to its latest release."],
               done_when: "MOT-52 and MOT-56 each leave their review state, or their next QA reports are not blocked."
             } = action
           ] = actions(collected)

    {body, []} = Update.render([action], ["In Review", "Human Review"])
    refute body =~ "test the PR"
    assert body =~ "[MOT-52](https://linear.app/acme/issue/MOT-52) and [MOT-56](https://linear.app/acme/issue/MOT-56)"
  end

  test "asks for the one step a tool missing on the Symphony host or the QA host's permissions need" do
    package = blocked_issue("MOT-52", "In Review", "`@playwright/mcp@0.0.41` is not installed on the Symphony host; run `npx -y @playwright/mcp@0.0.41 --version` there once")
    npx = blocked_issue("MOT-53", "In Review", "`npx` (Node.js) is not on Symphony's PATH, so the web playbook's browser could not start")
    permissions = blocked_issue("MOT-54", "In Review", "the QA host has no Screen Recording permission for the app")

    assert {:ok, collected} = collect([package, npx, permissions])

    assert [
             %Action{
               key: "qa:qa_permissions:id-MOT-54",
               title: "Grant the QA host's permissions",
               unblocks: "the QA of [MOT-54](https://linear.app/acme/issue/MOT-54)",
               done_when: "MOT-54 leaves its review state, or its next QA report is not blocked."
             },
             %Action{
               key: "qa:tool:@playwright/mcp@0.0.41:id-MOT-52",
               title: "Install `@playwright/mcp@0.0.41` on the Symphony host",
               steps: ["Run `npx -y @playwright/mcp@0.0.41 --version` on the Symphony host once."]
             },
             %Action{key: "qa:tool:npx:id-MOT-53", title: "Install Node.js on the Symphony host", unblocks: "the QA of [MOT-53](https://linear.app/acme/issue/MOT-53)"}
           ] = actions(collected)

    no_url = put_in(package, ["url"], nil)
    assert {:ok, collected} = collect([no_url])
    assert [%Action{unblocks: "the QA of MOT-52"}] = actions(collected)
  end

  test "lists nothing for a QA block with no cause only the operator can clear" do
    other_cause = blocked_issue("MOT-52", "In Review", "the dev server failed its health check, so the web playbook could not run")
    pr_adds_tool = blocked_issue("MOT-53", "In Review", "QA needs `qa_put_file`, which this PR adds and the running app (0.0.1.384) lacks")
    no_reason = blocked_issue("MOT-55", "in review", nil)
    in_human_review = blocked_issue("MOT-61", "Human Review", "no OpenRouter key")

    passed =
      node("MOT-54", %{
        "state" => %{"name" => "In Review"},
        "comments" => comments([%{"id" => "c4", "body" => "## Symphony QA Report\n\n**Verdict:** pass → In Review\n"}, %{"id" => "c5", "body" => nil}])
      })

    no_report = node("MOT-57", %{"state" => %{"name" => "In Review"}})

    assert {:ok, collected} = collect([other_cause, pr_adds_tool, no_reason, in_human_review, passed, no_report])
    assert collected == %{}
  end

  test "lists every issue in Human Review, marked so the update puts it first" do
    plan = node("MOT-60", %{"state" => %{"name" => "Human Review"}, "labels" => labels(["breakdown"])})

    blocked = blocked_issue("MOT-61", "Human Review", "the running app lacks `qa_put_file`")

    requested =
      node("MOT-62", %{
        "state" => %{"name" => "Human Review"},
        "labels" => labels(["human-action"]),
        "comments" => comments([request_comment("comment-1", "Add the OpenRouter key", "2026-10-03T10:00:00.000Z")]),
        "history" => history([%{"createdAt" => "2026-10-03T10:05:00.000Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Human Review"}}])
      })

    plain = node("MOT-63", %{"state" => %{"name" => "Human Review"}})
    in_review = node("MOT-64", %{"state" => %{"name" => "In Review"}, "labels" => labels(["breakdown"])})

    assert {:ok, collected} = collect([plan, blocked, requested, plain, in_review])

    assert [
             %Action{key: "plan:id-MOT-60", kind: :plan_review, human_review: true, done_when: "MOT-60 leaves Human Review."},
             %Action{key: "plan:id-MOT-64", kind: :plan_review, human_review: false},
             %Action{key: "qa:app_update:id-MOT-61", kind: :qa_blocked, human_review: false, title: "Update the Symphony app"},
             %Action{key: "request:comment-1", kind: :request, human_review: true},
             %Action{
               key: "review:id-MOT-63",
               kind: :human_review,
               human_review: true,
               title: "Review MOT-63",
               why: "MOT-63 waits in Human Review: only you can move it on.",
               est_minutes: 10,
               steps: [_read, "Move MOT-63 to `Merging` to approve its PR, to `Rework` to send it back, or to `Done` to sign off a final verification."],
               done_when: "MOT-63 leaves Human Review."
             }
           ] = actions(collected)
  end

  test "lists no action for a QA report blocked by the provider's usage limit" do
    usage_limited_report =
      "## Symphony QA Report\n\n**Verdict:** blocked → TP-368 In Review\n\n" <>
        "Reason: the QA agent could not finish: {:qa_agent_failed, {:usage_limited, %{scope: :all, source: :rate_limit_event, provider: \"anthropic\", window: \"five_hour\"}}}\n"

    usage_limited =
      node("MOT-56", %{"state" => %{"name" => "In Review"}, "comments" => comments([%{"id" => "c5", "body" => usage_limited_report, "createdAt" => "2026-10-04T13:08:00.000Z"}])})

    blocked = blocked_issue("MOT-57", "In Review", "the running app lacks `qa_put_file`")

    assert {:ok, collected} = collect([usage_limited, blocked])
    assert [%Action{key: "qa:app_update:id-MOT-57"}] = actions(collected)
  end

  defp walkthrough_report(identifier, verdict, target_state, attrs \\ %{}) do
    outcome = Map.merge(%{verdict: verdict, sha: "abc123", ref: "origin/main", target_issue: identifier, target_state: target_state}, attrs)
    %{"id" => "report-" <> identifier, "body" => Report.render(outcome), "createdAt" => "2026-10-03T10:00:00.000Z"}
  end

  defp step(name, status, evidence \\ []), do: %{name: name, status: status, details: "", evidence: evidence}

  defp verification(identifier, state, report, attrs \\ %{}) do
    node(
      identifier,
      Map.merge(
        %{
          "title" => "Final verification: Ship the QA driver",
          "state" => %{"name" => state},
          "parent" => %{"identifier" => "MOT-70", "project" => %{"id" => "project-2", "name" => "Parent project"}},
          "comments" => comments(List.wrap(report))
        },
        attrs
      )
    )
  end

  test "lists a final verification blocked on the QA host's permissions on its parent's project" do
    permission = "SSH on the QA host has no Accessibility permission, so QA cannot see the app."

    report =
      walkthrough_report("MOT-71", :blocked, "In Review", %{
        reason: permission,
        steps: [step("Open Settings", "blocked", ["https://uploads.linear.app/a.png"]), step("Save a repo", "blocked"), step("CLI prints the list", "pass")]
      })

    assert {:ok, %{"project-2" => %{project: %{id: "project-2", name: "Parent project"}, actions: [action]}} = collected} =
             collect([verification("MOT-71", "In Review", report)])

    assert Map.keys(collected) == ["project-2"]

    assert %Action{
             key: "verification:id-MOT-71",
             kind: :verification_blocked,
             title: "Grant the QA host's permissions for the final verification of MOT-70",
             why: "The Auto Review walkthrough could not test everything: " <> ^permission <> " Blocked steps: Open Settings; Save a repo.",
             unblocks: "the final verification of MOT-70",
             steps: [
               "On the QA host, open System Settings > Privacy & Security and grant Screen Recording and Accessibility to the app the reason above names.",
               "Then move MOT-71 to `Todo` so the walkthrough runs again."
             ],
             done_when: "MOT-71 leaves In Review, or its next walkthrough is not blocked.",
             issue: %{identifier: "MOT-71", state: "In Review"},
             project: %{id: "project-2"}
           } = action
  end

  test "lists a final verification blocked while its failing steps wait in gap tickets, until it leaves Todo" do
    report =
      walkthrough_report("MOT-72", :blocked, "Todo", %{
        reason: "the app does not build on the QA host",
        steps: [step("CLI prints the list", "fail")],
        filed: [%{identifier: "MOT-80", title: "Parent walkthrough fails: CLI prints the list"}]
      })

    no_parent_project = %{"parent" => %{"identifier" => "MOT-70", "project" => nil}}

    assert {:ok, collected} = collect([verification("MOT-72", "Todo", report, no_parent_project)])

    assert [
             %Action{
               key: "verification:id-MOT-72",
               title: "Unblock the final verification of MOT-70",
               why: "The Auto Review walkthrough could not test everything: the app does not build on the QA host",
               steps: [
                 "Fix the cause above, on the machine QA runs on.",
                 "MOT-72 runs the walkthrough again by itself once the gap tickets that block it are done."
               ],
               done_when: "MOT-72 leaves Todo, or its next walkthrough is not blocked."
             }
           ] = actions(collected)

    assert {:ok, %{}} = collect([verification("MOT-72", "In Progress", report)])
  end

  test "lists nothing for a final verification whose latest walkthrough is not blocked" do
    passed = walkthrough_report("MOT-73", :pass, "In Review")

    failed =
      walkthrough_report("MOT-74", :fail, "Todo", %{
        steps: [step("Open Settings", "fail")],
        filed: [%{identifier: "MOT-81", title: "Parent walkthrough fails: Open Settings"}]
      })

    other_ticket = walkthrough_report("MOT-70", :blocked, "In Review", %{reason: "no permission"})
    no_target = %{"id" => "c1", "body" => "## Symphony QA Report\n\n**Verdict:** blocked → In Review\n", "createdAt" => "2026-10-03T10:00:00.000Z"}
    no_state = walkthrough_report("MOT-82", :blocked, "In Review", %{reason: "no permission"})

    nodes = [
      verification("MOT-73", "In Review", passed),
      verification("MOT-74", "Todo", failed),
      verification("MOT-75", "In Review", other_ticket),
      verification("MOT-76", "In Review", no_target),
      verification("MOT-77", "Todo", nil),
      verification("MOT-82", nil, no_state, %{"state" => nil})
    ]

    assert {:ok, %{}} = collect(nodes)
  end

  test "lists nothing for a final verification whose walkthrough was blocked by the provider's usage limit" do
    report =
      walkthrough_report("MOT-79", :blocked, "In Review", %{
        reason: "the QA agent could not finish: {:qa_agent_failed, {:usage_limited, %{scope: :all, provider: \"anthropic\"}}}"
      })

    assert {:ok, collected} = collect([verification("MOT-79", "In Review", report)])
    assert collected == %{}
  end

  test "lists a final verification without a parent or reason against its own project" do
    report = walkthrough_report("MOT-78", :blocked, "In Review")

    assert {:ok, collected} = collect([verification("MOT-78", "In Review", report, %{"parent" => nil})])

    assert [
             %Action{
               title: "Unblock the final verification of MOT-78",
               why: "The Auto Review walkthrough could not test everything: see the QA report on MOT-78",
               project: %{id: "project-1"}
             }
           ] = actions(collected)
  end

  test "lists a blocked final verification the walkthrough moved to Human Review first, without a second review action" do
    report = walkthrough_report("MOT-79", :blocked, "Human Review", %{reason: "no OpenRouter key on the QA host"})

    assert {:ok, %{"project-2" => %{actions: [action]}}} = collect([verification("MOT-79", "Human Review", report)])

    assert %Action{
             key: "verification:id-MOT-79",
             kind: :verification_blocked,
             human_review: true,
             done_when: "MOT-79 leaves Human Review, or its next walkthrough is not blocked."
           } = action
  end

  test "with human_review: null, queries and lists only In Review as before" do
    no_human_review = %Schema{tracker: %{settings().tracker | human_review_state: nil}}

    assert {:ok, collected} = collect([node("MOT-63", %{"state" => %{"name" => "Human Review"}})], settings: no_human_review)
    # The deprecated label still counts.
    no_human_review = put_in(no_human_review.human_actions.label, "human-action")
    assert {:ok, ^collected} = collect([node("MOT-63", %{"state" => %{"name" => "Human Review"}})], settings: no_human_review)
    assert collected == %{}

    assert_received {:query, _query, %{filter: %{"and" => [_scope, %{"or" => wanted}, _terminal]}}}
    assert [in_review, _final_verification] = wanted
    assert in_review == %{"state" => %{"name" => %{"eqIgnoreCase" => "In Review"}}}
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

  test "reads every page of issues" do
    test_pid = self()
    first = node("MOT-1", %{"labels" => labels(["human-action"])})
    second = node("MOT-2", %{"labels" => labels(["human-action"])})

    client = fn _query, variables, _opts ->
      send(test_pid, {:after, variables.after})

      case variables.after do
        nil -> {:ok, page([first], %{"hasNextPage" => true, "endCursor" => "cursor-1"})}
        "cursor-1" -> {:ok, page([second], %{"hasNextPage" => false, "endCursor" => "cursor-2"})}
      end
    end

    opts = [settings: settings(), linear_client: client, scope_filter: fn _repo -> {:ok, @scope} end]
    assert {:ok, result} = Collector.collect([:repo], opts)
    assert ["task:id-MOT-1", "task:id-MOT-2"] = result |> actions() |> Enum.map(& &1.key)
    assert_received {:after, nil}
    assert_received {:after, "cursor-1"}
  end

  test "fails when a later page cannot be read" do
    page = page([], %{"hasNextPage" => true, "endCursor" => "cursor-1"})
    opts = [settings: settings(), scope_filter: fn _repo -> {:ok, @scope} end]

    client = fn _query, variables, _opts ->
      if variables.after == nil, do: {:ok, page}, else: {:error, :linear_down}
    end

    assert {:error, :linear_down} = Collector.collect([:repo], Keyword.put(opts, :linear_client, client))

    no_cursor = put_in(page, ["data", "issues", "pageInfo"], %{"hasNextPage" => true})

    assert {:error, :linear_missing_end_cursor} =
             Collector.collect([:repo], Keyword.put(opts, :linear_client, fn _query, _variables, _opts -> {:ok, no_cursor} end))
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

  describe "an issue with more comments and history than the issue query reads" do
    defp filler_comments(count), do: for(i <- 1..count, do: %{"id" => "c-#{i}", "body" => "Note #{i}", "createdAt" => "2026-10-02T00:00:00Z"})
    defp filler_history(count), do: for(_i <- 1..count, do: %{"createdAt" => "2026-09-01T00:00:00Z", "fromState" => nil, "toState" => nil})

    defp long_lived_node do
      node("MOT-9", %{
        "state" => %{"name" => "In Review"},
        "comments" => %{"nodes" => filler_comments(30), "pageInfo" => %{"hasPreviousPage" => true, "startCursor" => "comments-1"}},
        "history" => %{"nodes" => filler_history(50), "pageInfo" => %{"hasNextPage" => true, "endCursor" => "history-1"}}
      })
    end

    defp connection(field, nodes, page_info), do: {:ok, %{"data" => %{"issue" => %{field => %{"nodes" => nodes, "pageInfo" => page_info}}}}}

    defp collect_long_lived(more) do
      test_pid = self()

      client = fn query, variables, _opts ->
        cond do
          query =~ "SymphonyHumanActionsComments" ->
            send(test_pid, {:more, :comments, variables})
            more.(:comments, variables)

          query =~ "SymphonyHumanActionsHistory" ->
            send(test_pid, {:more, :history, variables})
            more.(:history, variables)

          true ->
            {:ok, page([long_lived_node()], %{"hasNextPage" => false})}
        end
      end

      opts = [settings: settings(), linear_client: client, scope_filter: fn _repo -> {:ok, @scope} end]
      Collector.collect_all([:repo], opts)
    end

    test "reads the rest of them, so its waiting_since and headline survive" do
      brief = %{"id" => "brief", "body" => "## Review brief\n\n**What to review:** The login fix PR\n", "createdAt" => "2026-09-20T00:00:00Z"}
      moved = %{"createdAt" => "2026-09-21T08:00:00Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "In Review"}}

      more = fn
        :comments, %{cursor: "comments-1"} -> connection("comments", [brief | filler_comments(5)], %{"hasPreviousPage" => false})
        :history, %{cursor: "history-1"} -> connection("history", filler_history(100), %{"hasNextPage" => true, "endCursor" => "history-2"})
        :history, %{cursor: "history-2"} -> connection("history", [moved], %{"hasNextPage" => false})
      end

      assert {:ok, _actions, [entry]} = collect_long_lived(more)
      assert entry.identifier == "MOT-9"
      assert entry.headline == "The login fix PR"
      assert entry.waiting_since == ~U[2026-09-21 08:00:00Z]

      assert_received {:more, :comments, %{id: "id-MOT-9", size: 100, cursor: "comments-1"}}
      assert_received {:more, :history, %{id: "id-MOT-9", size: 100, cursor: "history-1"}}
      assert_received {:more, :history, %{cursor: "history-2"}}
    end

    test "stops after ten more pages and keeps what it read" do
      more = fn
        :comments, _variables -> connection("comments", [], %{"hasPreviousPage" => false})
        :history, %{cursor: cursor} -> connection("history", filler_history(1), %{"hasNextPage" => true, "endCursor" => cursor <> "+"})
      end

      assert {:ok, _actions, [%{identifier: "MOT-9", waiting_since: nil}]} = collect_long_lived(more)

      {:messages, messages} = Process.info(self(), :messages)
      assert Enum.count(messages, &match?({:more, :history, _variables}, &1)) == 10
    end

    test "fails as a whole when the rest cannot be read" do
      history_done = fn -> connection("history", [], %{"hasNextPage" => false}) end

      assert {:error, :linear_down} = collect_long_lived(fn _field, _variables -> {:error, :linear_down} end)

      errors = %{"errors" => [%{"message" => "rate limited"}]}

      assert {:error, {:human_actions_query_failed, ^errors}} =
               collect_long_lived(fn
                 :comments, _variables -> {:ok, errors}
                 :history, _variables -> history_done.()
               end)

      assert {:error, {:human_actions_query_failed, "comments"}} =
               collect_long_lived(fn
                 :comments, _variables -> {:ok, %{"data" => %{"issue" => %{}}}}
                 :history, _variables -> history_done.()
               end)

      assert {:error, :linear_missing_end_cursor} =
               collect_long_lived(fn
                 :comments, _variables -> connection("comments", [], %{"hasPreviousPage" => true})
                 :history, _variables -> history_done.()
               end)
    end
  end
end
