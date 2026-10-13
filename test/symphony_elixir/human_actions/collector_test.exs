defmodule SymphonyElixir.HumanActions.CollectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Collector, Request}

  @project %{"id" => "project-1", "name" => "Cycle"}
  @scope %{"team" => %{"key" => %{"eq" => "MOT"}}}

  # Most tests read issues a config labelled that still sets the deprecated `human_actions.label`.
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
      Request.render_hold(
        %{title: title, question: "Add the signing secret?", why: "Release fails.", unblocks: "the Release workflow", est_minutes: 10, options: options},
        "Code Review"
      )

    %{"id" => id, "body" => body, "createdAt" => created_at}
  end

  defp actions(%{"project-1" => %{project: project, actions: actions}}) do
    assert project == %{id: "project-1", name: "Cycle"}
    Enum.sort_by(actions, & &1.key)
  end

  test "collect_all/2 also lists the issues waiting on a person, from the same read" do
    nodes = [node("MOT-1", %{"state" => %{"name" => "Plan Review"}, "labels" => labels(["plan"])}), node("MOT-2", %{})]
    client = fn _query, _variables, _opts -> {:ok, page(nodes, %{"hasNextPage" => false})} end
    opts = [settings: settings(), linear_client: client, scope_filter: fn _repo -> {:ok, @scope} end]

    assert {:ok, %{}, [%{identifier: "MOT-1", kind: :plan}]} = Collector.collect_all([:repo], opts)
    assert {:error, :down} = Collector.collect_all([:repo], Keyword.put(opts, :scope_filter, fn _repo -> {:error, :down} end))
  end

  test "queries the route's scope for labelled or held issues that are not terminal" do
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
                   # A decision request leaves the ticket in its phase.
                   %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "Needs Decision"}}}}
                 ]
               },
               %{"state" => %{"name" => %{"nin" => ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]}}}
             ]
           }
  end

  test "with the default settings, queries no label, and lists a request on an unlabelled issue in its phase" do
    issue =
      node("MOT-25", %{
        "state" => %{"name" => "Code Review"},
        # A request a supervisor wrote by hand, in the older format, still lists.
        "comments" =>
          comments([
            %{"id" => "comment-1", "body" => "## Action needed: Add the release signing secrets\n\n**Steps:**\n1. Add them.", "createdAt" => "2026-10-03T10:00:00.000Z"}
          ]),
        "history" => history([%{"createdAt" => "2026-10-03T09:00:05.000Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Code Review"}}])
      })

    # Without the deprecated setting, the label marks nothing.
    labelled = node("MOT-26", %{"labels" => labels(["human-action"])})

    assert {:ok, collected} = collect([issue, labelled], settings: %Schema{})

    assert [
             %Action{
               key: "request:comment-1",
               kind: :request,
               steps: ["Add them."],
               options: [],
               done_when: "you reply to the request, or the agent withdraws the request."
             }
           ] = actions(collected)

    assert_received {:query, _query, %{filter: %{"and" => [_scope, %{"or" => wanted}, _terminal]}}}

    assert wanted == [
             %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "Needs Decision"}}}}
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
            # The agent's own moves after the new request keep it open.
            %{"createdAt" => "2026-10-03T10:05:00.000Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Backlog"}},
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
               done_when: "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request."
             }
           ] = actions(collected)
  end

  test "a decision names the reply (or the Inbox) as enough, with no state move" do
    issue =
      node("MOT-90", %{
        "state" => %{"name" => "Code Review"},
        "comments" => comments([request_comment("comment-1", "Add the release signing secrets", "2026-10-03T10:00:00.000Z")])
      })

    assert {:ok, collected} = collect([issue], settings: %Schema{})

    assert [%Action{kind: :request, options: [_ | _], done_when: done_when}] = actions(collected)

    assert done_when == "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request."
    refute done_when =~ "move"
  end

  test "a hand-written steps request names the reply, with no state move" do
    issue =
      node("MOT-92", %{
        "state" => %{"name" => "Code Review"},
        "comments" =>
          comments([
            %{"id" => "comment-1", "body" => "## Action needed: Add the release signing secrets\n\n**Steps:**\n1. Add them.", "createdAt" => "2026-10-03T10:00:00.000Z"}
          ])
      })

    assert {:ok, collected} = collect([issue], settings: %Schema{})

    assert [%Action{kind: :request, options: [], done_when: done_when}] = actions(collected)

    assert done_when == "you reply to the request, or the agent withdraws the request."
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

  test "drops a withdrawn or answered request, and lists a labelled issue whose requests were all withdrawn as nothing" do
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

    # A person's reply under a request answers it, so it closes too.
    answer = %{"id" => "reply-2", "body" => "Add it.", "createdAt" => "2026-10-04T19:01:00.000Z", "parent" => %{"id" => "comment-2"}}
    answered = %{partly | "comments" => comments(partly["comments"]["nodes"] ++ [answer])}
    assert {:ok, %{}} = collect([answered])
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
        "state" => %{"name" => "Plan Review"},
        "labels" => labels(["plan"]),
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
      moved = %{"createdAt" => "2026-09-21T08:00:00Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Plan Review"}}

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
