defmodule SymphonyElixir.HumanActions.CollectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.{Action, Collector, Request}
  alias SymphonyElixir.Inbox.FromRecord
  alias SymphonyElixir.TicketState

  @repo "shop"
  @project %{id: "project-1", name: "Cycle", slug_id: "cycle"}
  @fixture "test/fixtures/inbox/situation.exs"

  defp settings, do: %Schema{}

  defp situation do
    {situation, _binding} = Code.eval_file(@fixture)
    situation
  end

  defp option(label, effect, recommended?, attrs \\ %{}),
    do: Map.merge(%{label: label, effect: effect, good: [], cost: [], risk: [], recommended?: recommended?, unlocks: []}, attrs)

  defp question(id, attrs) do
    Map.merge(
      %{
        id: id,
        asked_by: %{kind: :run, name: "Implementation run", run_id: "run-1"},
        title: "Add the signing secret",
        question: "Add the signing secret?",
        why: "Release fails.",
        if_unanswered: "Releases stay unsigned.",
        unblocks: "the Release workflow",
        options: [option("Add it", "Releases sign again.", true, %{good: ["Gatekeeper stops warning."]}), option("Drop signing", "Releases ship unsigned.", false)],
        recommendation_reason: "Signing is a one-time setup.",
        state: :open,
        asked_at: ~U[2026-10-20 10:00:00Z]
      },
      attrs
    )
  end

  defp record(identifier, questions, attrs \\ %{}) do
    Map.merge(
      %{
        repo_key: @repo,
        issue_id: "id-" <> identifier,
        issue_identifier: identifier,
        title: "Title of " <> identifier,
        url: "https://linear.app/acme/issue/" <> identifier,
        phase: "In Progress",
        project: @project,
        questions: questions
      },
      attrs
    )
  end

  defp collect(records, repos \\ [%{name: @repo}]), do: Collector.collect(repos, records: fn -> records end)

  defp actions(%{"project-1" => %{project: project, actions: actions}}) do
    assert project == %{id: "project-1", name: "Cycle"}
    Enum.sort_by(actions, & &1.key)
  end

  describe "collect/2 over the records" do
    test "lists each open question as a request action, with its ticket" do
      records = [record("SHOP-1", [question("q-1", %{}), question("q-2", %{title: "Add the key", options: []})])]

      assert {:ok, collected} = collect(records)

      assert [
               %Action{
                 key: "question:q-1",
                 kind: :request,
                 title: "Add the signing secret",
                 why: "Release fails.",
                 unblocks: "the Release workflow",
                 if_unanswered: "Releases stay unsigned.",
                 question: "Add the signing secret?",
                 options: ["**Add it** (recommended): Releases sign again.", "**Drop signing**: Releases ship unsigned."],
                 steps: [],
                 issue: %{id: "id-SHOP-1", identifier: "SHOP-1", title: "Title of SHOP-1", url: "https://linear.app/acme/issue/SHOP-1", state: "In Progress"},
                 done_when: "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request."
               },
               # A question without options names the reply alone; neither names a state move.
               %Action{key: "question:q-2", options: [], done_when: "you reply to the request, or the agent withdraws the request."}
             ] = actions(collected)
    end

    test "leaves out answered and withdrawn questions, tickets outside a project and repositories not listed" do
      answer = %{text: "Add it", option: 1, by: %{kind: :person, name: "Director"}, at: ~U[2026-10-20 11:00:00Z], scope: :ticket}

      records = [
        record("SHOP-1", [question("q-answered", %{state: :answered, answer: answer}), question("q-open", %{})]),
        record("SHOP-2", [question("q-withdrawn", %{state: :withdrawn, withdrawn: %{reason: "Not needed.", at: ~U[2026-10-20 11:00:00Z]}})]),
        record("SHOP-3", [question("q-no-project", %{})], %{project: nil}),
        record("SHOP-4", [question("q-other-repo", %{})], %{repo_key: "other"}),
        record("ENG-1", [question("q-eng", %{})], %{project: %{id: "project-2", name: nil}})
      ]

      assert {:ok, collected} = collect(records)
      assert Map.keys(collected) == ["project-1", "project-2"]
      assert [%Action{key: "question:q-open"}] = actions(collected)
      assert %{project: %{id: "project-2", name: nil}, actions: [%Action{key: "question:q-eng"}]} = collected["project-2"]

      assert {:ok, %{}} = collect(records, [])
    end

    test "fails when the records cannot be read" do
      assert {:error, :store_down} = Collector.collect([%{name: @repo}], records: fn -> {:error, :store_down} end)
    end

    test "lists the open questions the Inbox lists, worded as today's request comments read" do
      situation = situation()

      records =
        for node <- situation.nodes do
          TicketState.normalize(%{
            repo_key: @repo,
            issue_id: node["id"],
            issue_identifier: node["identifier"],
            title: node["title"],
            url: node["url"],
            phase: node["state"]["name"],
            project: @project,
            questions: Map.get(situation.questions, node["id"], [])
          })
        end

      assert {:ok, collected} = collect(records)
      listed = actions(collected)

      inbox = FromRecord.items(records, %{}, settings_fun: fn @repo -> settings() end)
      inbox_titles = for %{kind: :action, review: review} <- inbox, do: review.title
      assert Enum.sort(Enum.map(listed, & &1.title)) == Enum.sort(inbox_titles)
      assert Enum.map(listed, & &1.key) == ["question:q-merge", "question:q-plan", "question:q-signing"]

      # Today's update read the same fields from the request comments the projector posted.
      parsed =
        for node <- situation.nodes, {_comment_id, request} <- Collector.open_requests(node, settings()) do
          Map.take(request, [:title, :why, :if_unanswered, :unblocks, :question, :options])
        end

      assert Enum.sort(parsed) == listed |> Enum.map(&Map.take(&1, [:title, :why, :if_unanswered, :unblocks, :question, :options])) |> Enum.sort()
    end
  end

  # The issue node helpers the plan's brief capture still uses (`SymphonyElixir.Inbox.Item.plan_from_node/2`).
  describe "open_requests/2 on an issue node" do
    defp node(identifier, attrs) do
      Map.merge(
        %{
          "id" => "id-" <> identifier,
          "identifier" => identifier,
          "state" => %{"name" => "Backlog"},
          "comments" => %{"nodes" => []},
          "history" => %{"nodes" => []}
        },
        attrs
      )
    end

    defp comments(comments), do: %{"nodes" => comments}
    defp history(entries), do: %{"nodes" => entries}

    defp request_comment(id, title, created_at) do
      options = [%{label: "Add it", effect: "Releases sign again.", recommended: true}, %{label: "Drop signing", effect: "Releases ship unsigned."}]

      body =
        Request.render_hold(
          %{title: title, question: "Add the signing secret?", why: "Release fails.", unblocks: "the Release workflow", if_unanswered: "Releases stay unsigned.", options: options},
          "Code Review"
        )

      %{"id" => id, "body" => body, "createdAt" => created_at}
    end

    defp open_titles(node), do: node |> Collector.open_requests(settings()) |> Enum.map(fn {id, request} -> {id, request.title} end)

    test "reads a hand-written steps request" do
      issue =
        node("MOT-25", %{
          "comments" => comments([%{"id" => "comment-1", "body" => "## Action needed: Add the release signing secrets\n\n**Steps:**\n1. Add them.", "createdAt" => "2026-10-03T10:00:00.000Z"}])
        })

      assert [{"comment-1", %{steps: ["Add them."], options: []}}] = Collector.open_requests(issue, settings())
    end

    test "drops the requests the issue moved on from" do
      issue =
        node("MOT-24", %{
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

      assert open_titles(issue) == [{"comment-new", "Add the release signing secrets"}]
    end

    test "drops a withdrawn or answered request" do
      withdrawal = fn id, parent_id ->
        %{"id" => id, "body" => Request.render_withdrawal("Not needed."), "createdAt" => "2026-10-04T19:00:00.000Z", "parent" => %{"id" => parent_id}}
      end

      partly =
        node("MOT-33", %{
          "comments" =>
            comments([
              request_comment("comment-1", "Re-run the stuck dialyzer job", "2026-10-04T18:57:00.000Z"),
              request_comment("comment-2", "Add the release signing secrets", "2026-10-04T18:58:00.000Z"),
              withdrawal.("reply-1", "comment-1"),
              Map.put(withdrawal.("comment-3", "comment-9"), "parent", nil)
            ])
        })

      assert open_titles(partly) == [{"comment-2", "Add the release signing secrets"}]

      # A person's reply under a request answers it, so it closes too.
      answer = %{"id" => "reply-2", "body" => "Add it.", "createdAt" => "2026-10-04T19:01:00.000Z", "parent" => %{"id" => "comment-2"}}
      assert open_titles(%{partly | "comments" => comments(partly["comments"]["nodes"] ++ [answer])}) == []
      assert open_titles(node("MOT-31", %{})) == []
    end
  end

  describe "read_more_pages/2 on an issue with more comments and history than its first read" do
    defp filler_comments(count), do: for(i <- 1..count, do: %{"id" => "c-#{i}", "body" => "Note #{i}", "createdAt" => "2026-10-02T00:00:00Z"})
    defp filler_history(count), do: for(_i <- 1..count, do: %{"createdAt" => "2026-09-01T00:00:00Z", "fromState" => nil, "toState" => nil})

    defp long_lived_node do
      node("MOT-9", %{
        "comments" => %{"nodes" => filler_comments(30), "pageInfo" => %{"hasPreviousPage" => true, "startCursor" => "comments-1"}},
        "history" => %{"nodes" => filler_history(50), "pageInfo" => %{"hasNextPage" => true, "endCursor" => "history-1"}}
      })
    end

    defp connection(field, nodes, page_info), do: {:ok, %{"data" => %{"issue" => %{field => %{"nodes" => nodes, "pageInfo" => page_info}}}}}

    defp read_long_lived(more) do
      test_pid = self()

      client = fn query, variables, _opts ->
        field = if query =~ "SymphonyHumanActionsComments", do: :comments, else: :history
        send(test_pid, {:more, field, variables})
        more.(field, variables)
      end

      Collector.read_more_pages([long_lived_node()], client)
    end

    test "reads the rest of them: older comments first, later history last" do
      brief = %{"id" => "brief", "body" => "## Review brief", "createdAt" => "2026-09-20T00:00:00Z"}
      moved = %{"createdAt" => "2026-09-21T08:00:00Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "Plan Review"}}

      more = fn
        :comments, %{cursor: "comments-1"} -> connection("comments", [brief | filler_comments(5)], %{"hasPreviousPage" => false})
        :history, %{cursor: "history-1"} -> connection("history", filler_history(100), %{"hasNextPage" => true, "endCursor" => "history-2"})
        :history, %{cursor: "history-2"} -> connection("history", [moved], %{"hasNextPage" => false})
      end

      assert {:ok, [node]} = read_long_lived(more)
      assert [^brief | _rest] = node["comments"]["nodes"]
      assert length(node["comments"]["nodes"]) == 36
      assert List.last(node["history"]["nodes"]) == moved
      assert length(node["history"]["nodes"]) == 151

      assert_received {:more, :comments, %{id: "id-MOT-9", size: 100, cursor: "comments-1"}}
      assert_received {:more, :history, %{id: "id-MOT-9", size: 100, cursor: "history-1"}}
      assert_received {:more, :history, %{cursor: "history-2"}}
    end

    test "stops after ten more pages and keeps what it read" do
      more = fn
        :comments, _variables -> connection("comments", [], %{"hasPreviousPage" => false})
        :history, %{cursor: cursor} -> connection("history", filler_history(1), %{"hasNextPage" => true, "endCursor" => cursor <> "+"})
      end

      assert {:ok, [node]} = read_long_lived(more)
      assert length(node["history"]["nodes"]) == 60

      {:messages, messages} = Process.info(self(), :messages)
      assert Enum.count(messages, &match?({:more, :history, _variables}, &1)) == 10
    end

    test "leaves a node with nothing more as it is" do
      node = node("MOT-1", %{})
      assert {:ok, [^node]} = Collector.read_more_pages([node], fn _query, _variables, _opts -> flunk("no read") end)
    end

    test "fails as a whole when the rest cannot be read" do
      history_done = fn -> connection("history", [], %{"hasNextPage" => false}) end

      assert {:error, :linear_down} = read_long_lived(fn _field, _variables -> {:error, :linear_down} end)

      errors = %{"errors" => [%{"message" => "rate limited"}]}

      assert {:error, {:human_actions_query_failed, ^errors}} =
               read_long_lived(fn
                 :comments, _variables -> {:ok, errors}
                 :history, _variables -> history_done.()
               end)

      assert {:error, {:human_actions_query_failed, "comments"}} =
               read_long_lived(fn
                 :comments, _variables -> {:ok, %{"data" => %{"issue" => %{}}}}
                 :history, _variables -> history_done.()
               end)

      assert {:error, :linear_missing_end_cursor} =
               read_long_lived(fn
                 :comments, _variables -> connection("comments", [], %{"hasPreviousPage" => true})
                 :history, _variables -> history_done.()
               end)
    end
  end
end
