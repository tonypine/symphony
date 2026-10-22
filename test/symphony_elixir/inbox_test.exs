defmodule SymphonyElixir.InboxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.{Issue, Usage}
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.{RunStore, TicketState}

  @repo %{name: "shop"}

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

  defp issue_node(identifier, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "state" => %{"name" => "Plan Review"},
        "labels" => %{"nodes" => [%{"name" => "plan"}]},
        "attachments" => %{"nodes" => []},
        "children" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => [moved("Plan Review", "2026-10-01T10:00:00Z")]}
      },
      attrs
    )
  end

  defp moved(to, at), do: %{"createdAt" => at, "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => to}}

  defp light(node, comment_at \\ nil) do
    %{"id" => node["id"], "updatedAt" => "2026-10-01T10:00:00Z", "comments" => %{"nodes" => if(comment_at, do: [%{"updatedAt" => comment_at}], else: [])}}
  end

  @brief """
  ## Review brief

  **What to review:** The retry fix for the importer.

  - [PR #7](https://github.com/acme/shop/pull/7)

  **Decisions needed:**

  None.

  **How to approve / change / reject:**

  - Approve: move it to Merging.
  """

  defp comment(id, body, created_at \\ "2026-10-01T11:00:00Z"), do: %{"id" => id, "body" => body, "createdAt" => created_at}

  defp request_body do
    Request.render_hold(
      %{
        title: "Add the signing secret",
        question: "Add the secret?",
        why: "Releases fail to sign.",
        unblocks: "the Release workflow",
        if_unanswered: "Every release stays unsigned.",
        options: [
          %{label: "Add it", effect: "Releases sign again.", recommended: true, tradeoffs: [%{kind: "good", text: "Gatekeeper stops warning."}]},
          %{label: "Drop signing", effect: "Unsigned builds."}
        ],
        recommendation_reason: "Signing is a one-time setup."
      },
      "Code Review"
    )
  end

  # A Linear stand-in serving `listed` (light nodes), `details` (full nodes by id) and `references`
  # (the nodes of the references query, by root), and reporting each query to the test process.
  defp linear(test_pid, listed_fun, details, references \\ %{}) do
    fn query, variables, _opts ->
      send(test_pid, {:caller, Usage.current_caller()})

      cond do
        query =~ "SymphonyInboxList" ->
          send(test_pid, {:listed, variables.filter})
          listed_fun.(variables)

        query =~ "SymphonyInboxIssues" ->
          ids = variables.filter["id"]["in"]
          send(test_pid, {:read, ids})
          {:ok, %{"data" => %{"issues" => %{"nodes" => Enum.flat_map(ids, &List.wrap(details[&1]))}}}}

        query =~ "SymphonyInboxReferences" ->
          send(test_pid, {:references, variables})
          {:ok, %{"data" => Map.new(references, fn {root, nodes} -> {root, %{"nodes" => nodes}} end)}}
      end
    end
  end

  defp page(nodes), do: {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}

  defp state(linear_client, opts \\ []) do
    %{
      opts:
        Keyword.merge(
          [
            name: {:test, make_ref()},
            repos: fn -> {:ok, [@repo]} end,
            settings_fun: fn _repo -> %Schema{} end,
            scope_filter: fn _repo -> {:ok, %{"team" => %{"key" => %{"eq" => "SHOP"}}}} end,
            linear_client: linear_client,
            snapshot: fn -> %{} end,
            github_repos: %{"shop" => "acme/shop"},
            pull_request: &{:ok, pull_request(&1)}
          ],
          opts
        ),
      nodes: %{},
      timer: make_ref()
    }
  end

  defp pull_request(url, attrs \\ %{}) do
    Map.merge(
      %{
        number: url |> String.split("/") |> List.last() |> String.to_integer(),
        url: url,
        title: "SHOP-7 Retry the importer",
        body: "## This PR\n\nThe importer retries a failed page.",
        state: "OPEN",
        review_decision: nil,
        changed_files: 3,
        additions: 40,
        deletions: 2,
        head_ref_name: "auto/SHOP-7",
        checks: "passed"
      },
      attrs
    )
  end

  defp lookups(hold \\ nil), do: %{hold: fn _repo_key, _issue_id -> hold end}

  describe "items from Linear" do
    test "a plan with its brief and its sub-tickets in landing order" do
      plan =
        issue_node("SHOP-330", %{
          "comments" => %{"nodes" => [comment("brief", @brief)]},
          "children" => %{
            "nodes" => [
              %{"identifier" => "SHOP-332", "title" => "Second", "url" => "u2", "createdAt" => "2026-10-01T09:02:00Z", "state" => %{"name" => "Backlog"}},
              %{"identifier" => "SHOP-331", "title" => "First", "url" => "u1", "createdAt" => "2026-10-01T09:01:00Z", "state" => %{"name" => "Backlog"}}
            ]
          }
        })

      assert %{
               issue_id: "id-SHOP-330",
               identifier: "SHOP-330",
               repo_key: "shop",
               kind: :plan,
               state: "Plan Review",
               ask: "The retry fix for the importer.",
               waiting_since: ~U[2026-10-01 10:00:00Z],
               url: "https://linear.app/acme/issue/SHOP-330",
               review: %{
                 brief: %{format: "parsed", headline: "The retry fix for the importer.", moves: [%{move: "approve"}]},
                 sub_tickets: [%{identifier: "SHOP-331", title: "First", url: "u1", state: "Backlog"}, %{identifier: "SHOP-332"}]
               }
             } = Item.from_node(plan, "shop", %Schema{}, lookups())

      refute Map.has_key?(Item.from_node(plan, "shop", %Schema{}, lookups()), :state_machine)
    end

    test "a plan's open choices are its requests, oldest first, each with what the Inbox shows of a request" do
      second =
        Request.render_hold(
          %{
            title: "Card lifetime",
            question: "How long does a gift card last?",
            why: "The screens need it.",
            if_unanswered: "SHOP-331 waits.",
            options: [%{label: "One year", effect: "Cards expire after a year.", recommended: true}, %{label: "Two years", effect: "Cards last two years."}],
            recommendation_reason: "Most shops pick one year."
          },
          "In Progress"
        )

      steps_only = "## Action needed: Check the screens\n\n**Steps:**\n1. Open them."

      plan =
        issue_node("SHOP-330", %{
          "history" => %{"nodes" => [moved("Plan Review", "2026-10-01T10:00:00Z")]},
          "comments" => %{
            "nodes" => [
              comment("brief", @brief, "2026-10-01T09:59:00Z"),
              comment("q2", second, "2026-10-01T09:58:00Z"),
              comment("q1", request_body(), "2026-10-01T09:57:00Z"),
              comment("steps", steps_only, "2026-10-01T09:56:00Z"),
              %{"id" => "q0", "body" => second}
            ]
          }
        })

      assert %{kind: :plan, review: %{brief: %{format: "parsed"}, decisions: [undated, first, card]} = review} =
               Item.from_node(plan, "shop", %Schema{}, lookups())

      # A request read without its posting time sorts first.
      assert %{comment_id: "q0"} = undated
      refute Map.has_key?(review.brief, :decisions)

      assert %{
               comment_id: "q1",
               question: "Add the secret?",
               why: "Releases fail to sign.",
               if_unanswered: "Every release stays unsigned.",
               recommendation_reason: "Signing is a one-time setup.",
               options: [%{label: "Add it", recommended: true, tradeoffs: [%{kind: "good"}]}, %{label: "Drop signing", recommended: false}]
             } = first

      assert %{comment_id: "q2", question: "How long does a gift card last?"} = card
    end

    test "a plan counts the answers given since it last came back to review, which no revision applied yet" do
      reply = fn id, parent, at -> %{"id" => id, "body" => "Decision from the Director:\n\n1. Q\n   **Decision:** B", "createdAt" => at, "parent" => %{"id" => parent}} end

      plan =
        issue_node("SHOP-330", %{
          "history" => %{"nodes" => [moved("Plan Review", "2026-10-01T08:00:00Z"), moved("Plan Review", "2026-10-01T10:00:00Z")]},
          "comments" => %{
            "nodes" => [
              reply.("a2", "q2", "2026-10-01T10:16:00Z"),
              reply.("a4", "q4", nil),
              comment("q4", request_body(), "2026-10-01T09:59:30Z"),
              reply.("a1", "q1", "2026-10-01T10:15:00Z"),
              %{"id" => "w3", "body" => Request.render_withdrawal("Not needed"), "createdAt" => "2026-10-01T10:14:00Z", "parent" => %{"id" => "q3"}},
              comment("q3", request_body(), "2026-10-01T09:59:00Z"),
              comment("q2", request_body(), "2026-10-01T09:58:00Z"),
              comment("q1", request_body(), "2026-10-01T09:57:00Z"),
              reply.("a0", "q0", "2026-10-01T09:00:00Z"),
              comment("q0", request_body(), "2026-10-01T07:57:00Z")
            ]
          }
        })

      # The first round's answer was applied by the revision that brought the plan back at 10:00; an
      # answer read without its time can't be told apart, so it isn't counted.
      assert %{kind: :plan, review: %{unapplied_answers: 2}} = Item.from_node(plan, "shop", %Schema{}, lookups())

      # A plan whose history shows no move into review counts none.
      undated = %{plan | "history" => %{"nodes" => [%{"createdAt" => nil, "toState" => %{"name" => "Plan Review"}}]}}
      assert %{review: %{unapplied_answers: 0}} = Item.from_node(undated, "shop", %Schema{}, lookups())
    end

    test "a plan without a brief asks for its approval" do
      assert %{kind: :plan, ask: "Approve the plan", review: %{brief: nil, sub_tickets: [], decisions: [], unapplied_answers: 0}} =
               Item.from_node(issue_node("SHOP-331"), "shop", %Schema{}, lookups())
    end

    test "a pull request or a final verification sits in no state a person reviews in, so it waits on nobody" do
      for node <- [
            issue_node("SHOP-8", %{"labels" => %{"nodes" => []}}),
            issue_node("SHOP-340", %{"title" => "Final verification: Gift cards", "labels" => %{"nodes" => []}}),
            issue_node("SHOP-341", %{"state" => %{"name" => "In Review"}})
          ] do
        assert Item.from_node(node, "shop", %Schema{}, lookups()) == nil
      end
    end

    test "an action with why, what waits if unanswered, options with trade-offs and what it unblocks" do
      action =
        issue_node("SHOP-90", %{
          "state" => %{"name" => "Code Review"},
          "history" => %{"nodes" => [moved("Code Review", "2026-10-01T08:00:00Z")]},
          "comments" => %{"nodes" => [comment("request", request_body(), "2026-10-01T08:00:01Z")]}
        })

      assert %{
               kind: :action,
               ask: "Add the signing secret",
               review:
                 %{
                   comment_id: "request",
                   title: "Add the signing secret",
                   question: "Add the secret?",
                   why: "Releases fail to sign.",
                   unblocks: "the Release workflow",
                   if_unanswered: "Every release stays unsigned.",
                   steps: [],
                   options: [
                     %{label: "Add it", effect: "Releases sign again.", recommended: true, tradeoffs: [%{kind: "good", text: "Gatekeeper stops warning."}]},
                     %{label: "Drop signing", effect: "Unsigned builds.", recommended: false, tradeoffs: []}
                   ],
                   recommendation_reason: "Signing is a one-time setup.",
                   requested_at: ~U[2026-10-01 08:00:01Z]
                 } = review
             } = Item.from_node(action, "shop", %Schema{}, lookups())

      refute Map.has_key?(review, :est_minutes)
    end

    test "a held ticket waits in its phase, listed with the request's ask and age" do
      # The hold pauses the ticket where it stands: the request on it lists it, and the decision is
      # answerable from the Inbox with its comment id.
      held =
        issue_node("SHOP-91", %{
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
          "history" => %{"nodes" => []},
          "comments" => %{"nodes" => [comment("request", request_body(), "2026-10-01T08:00:01Z")]}
        })

      assert %{
               kind: :action,
               state: "In Progress",
               ask: "Add the signing secret",
               waiting_since: ~U[2026-10-01 08:00:01Z],
               review: %{comment_id: "request", question: "Add the secret?", requested_at: ~U[2026-10-01 08:00:01Z], confirm: nil}
             } = Item.from_node(held, "shop", %Schema{}, lookups())
    end

    test "a merge confirmation's request names the move its confirmation performs" do
      held =
        issue_node("SHOP-92", %{
          "state" => %{"name" => "QA"},
          "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
          "history" => %{"nodes" => []},
          "comments" => %{"nodes" => [comment("request", request_body(), "2026-10-01T08:00:01Z")]}
        })

      summary = %{recommendation: "merge", review: nil, qa: "pass", pr: nil}
      hold = MergeConfirmation.attrs(MergeConfirmation.request(%Issue{identifier: "SHOP-92"}, summary))

      assert %{kind: :action, review: %{confirm: "Merging"}} = Item.from_node(held, "shop", %Schema{}, lookups(hold))
    end

    test "nothing for an issue that left Plan Review" do
      assert Item.from_node(issue_node("SHOP-9", %{"state" => %{"name" => "Todo"}}), "shop", %Schema{}, lookups()) == nil
    end

    test "a ticket an access hold pauses in place, with the reason the hold recorded" do
      held = issue_node("SHOP-60", %{"state" => %{"name" => "In Progress"}, "labels" => %{"nodes" => []}})

      hold = %{
        kind: :blocked,
        reason: "The run reported a block",
        clearing_condition: "when the block is resolved; a person clears an access hold",
        waits_on: %{type: "access", keys: []},
        decision: nil,
        set_at: ~U[2026-10-01 06:00:00Z]
      }

      assert %{
               issue_id: "id-SHOP-60",
               identifier: "SHOP-60",
               repo_key: "shop",
               kind: :blocked,
               state: "In Progress",
               ask: "The run reported a block",
               waiting_since: ~U[2026-10-01 06:00:00Z],
               url: "https://linear.app/acme/issue/SHOP-60",
               review: %{
                 reason: "The run reported a block",
                 clearing_condition: "when the block is resolved; a person clears an access hold"
               }
             } = Item.from_node(held, "shop", %Schema{}, lookups(hold))

      # A hold that clears on its own waits on nobody, and neither does a ticket with no hold at all
      # or a run whose lookups name no hold source.
      assert Item.from_node(held, "shop", %Schema{}, lookups(%{hold | waits_on: %{type: "dependency", keys: ["SHOP-1"]}})) == nil
      assert Item.from_node(held, "shop", %Schema{}, lookups()) == nil
      assert Item.from_node(held, "shop", %Schema{}, %{}) == nil

      # A hold never displaces a plan review the ticket already waits on.
      assert %{kind: :plan} = Item.from_node(issue_node("SHOP-60"), "shop", %Schema{}, lookups(hold))

      # A hold that recorded no reason still says what acting on it does.
      assert %{ask: "Unblock the ticket and it continues", review: %{reason: nil}} =
               Item.from_node(held, "shop", %Schema{}, lookups(%{hold | reason: nil, clearing_condition: nil}))
    end

    test "a ticket the dispatch-loop guard holds, with the loop in the reason" do
      held = issue_node("SHOP-61", %{"state" => %{"name" => "Rework"}, "labels" => %{"nodes" => [%{"name" => "Blocked"}]}})
      run = %{kind: "rework", run_id: "run-1", state: "Rework", head: "abc", at: ~U[2026-10-01 05:58:00Z], outcome: %{exit: "ended normally", head: "abc", at: nil}}
      attrs = SymphonyElixir.DispatchLoop.hold_attrs(%{kind: "rework", count: 4, window_ms: 600_000, runs: [run]}, [])
      hold = Map.merge(attrs, %{kind: :blocked, decision: nil, set_at: ~U[2026-10-01 06:00:00Z]})

      assert %{kind: :blocked, ask: ask, review: %{reason: ask, clearing_condition: "when a person unblocks or restarts it"}} =
               Item.from_node(held, "shop", %Schema{}, lookups(hold))

      assert ask =~ "dispatch_loop: 4 rework runs in 10 minutes without a state change, a new PR head or a decision"
      assert ask =~ "started 05:58 UTC, ended normally, no new PR head, no handoff signal"
    end

    test "a ticket the Director stopped waits as Stopped by you, which Unblock or Restart lifts" do
      held = issue_node("SHOP-62", %{"state" => %{"name" => "Todo"}, "labels" => %{"nodes" => [%{"name" => "Blocked"}]}})
      attrs = SymphonyElixir.OperatorStop.hold_attrs(SymphonyElixir.OperatorStop.mark("SHOP-62", "shop", ~U[2026-10-01 06:00:00Z]))
      hold = Map.merge(attrs, %{kind: :blocked, decision: nil, set_at: ~U[2026-10-01 06:00:00Z]})

      assert %{kind: :blocked, ask: "Stopped by you at 2026-10-01 06:00:00 UTC. " <> _, waiting_since: ~U[2026-10-01 06:00:00Z]} =
               Item.from_node(held, "shop", %Schema{}, lookups(hold))
    end

    test "reads an option and a quality-gate entry" do
      assert Item.option("Plain text") == %{label: "Plain text", effect: nil, recommended: false}
      assert Item.option("**Keep** (recommended):") == %{label: "Keep", effect: nil, recommended: true}

      assert %{kind: :clarify, ask: "The quality gate couldn't score the ticket", waiting_since: ~U[2026-10-01 07:00:00Z], review: %{held: false, found: "LLM call failed"}} =
               Item.from_quality_gate(%{kind: :error, issue_id: "id-1", reason: "LLM call failed", updated_at: ~U[2026-10-01 07:00:00Z]})
    end
  end

  # The description a decision is written into, as Linear would hold it; the hold's label goes nowhere.
  defmodule DescriptionTracker do
    def set_machine_label(_issue_id, _name), do: :ok
    def clear_machine_label(_issue_id, _name), do: :ok
    def fetch_issue_description(_issue_id), do: {:ok, "Sign the release builds."}

    def update_issue_description(issue_id, description) do
      send(self(), {:description_written, issue_id, description})
      :ok
    end
  end

  describe "the poller" do
    test "the read is also the one that sets and clears the Needs Decision hold" do
      test_pid = self()

      held =
        issue_node("SHOP-92", %{
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
          "history" => %{"nodes" => []},
          "comments" => %{"nodes" => [comment("request", request_body(), "2026-10-01T08:00:01Z")]}
        })

      client = linear(test_pid, fn _variables -> page([light(held)]) end, %{held["id"] => held})
      state = state(client, settings_fun: fn _repo -> designed_settings() end)

      state = Inbox.run_once(state)
      assert [%{identifier: "SHOP-92", kind: :action, ask: "Add the signing secret"}] = Inbox.cached(state.opts[:name])
      assert %{holds: [%{kind: :needs_decision, decision: %{title: "Add the signing secret"}}]} = RunStore.get_ticket_state("shop", "id-SHOP-92")

      # The person answers under the request: the next read no longer finds it and clears the hold,
      # so the ticket continues in its phase.
      answered =
        put_in(held, ["comments", "nodes"], [
          comment("request", request_body(), "2026-10-01T08:00:01Z"),
          %{"id" => "reply", "body" => "Add it", "parent" => %{"id" => "request"}}
        ])

      answered_client = linear(test_pid, fn _variables -> page([light(answered)]) end, %{answered["id"] => answered})

      state =
        answered_client
        |> state(settings_fun: fn _repo -> designed_settings() end, tracker: DescriptionTracker)
        |> Inbox.run_once()

      assert TicketState.get_hold(RunStore.get_ticket_state("shop", "id-SHOP-92"), :needs_decision) == nil
      assert Inbox.cached(state.opts[:name]) == []

      # The same read writes the answer into the ticket's scope.
      assert_received {:description_written, "id-SHOP-92", description}
      assert String.starts_with?(description, "Sign the release builds.\n\n")
      assert [%{id: "D1", key: "request", title: "Add the signing secret", question: "Add the secret?"}] = SymphonyElixir.Decisions.recorded(description)
    end

    test "reads a ticket the store holds by its id, label or not, so an answer posted while the label was missing clears it" do
      test_pid = self()
      :ok = RunStore.set_ticket_hold("shop", "id-SHOP-92", :needs_decision, %{reason: "Add the secret?", decision: %{title: "Add the signing secret", question: "Add the secret?"}})

      # The label went missing and the person answered under the request.
      answered =
        issue_node("SHOP-92", %{
          "state" => %{"name" => "QA"},
          "labels" => %{"nodes" => []},
          "history" => %{"nodes" => []},
          "comments" => %{
            "nodes" => [
              comment("request", request_body(), "2026-10-01T08:00:01Z"),
              %{"id" => "reply", "body" => "Add it", "parent" => %{"id" => "request"}}
            ]
          }
        })

      # Linear lists only what the filter names: the ticket is found by its id, not its label.
      listed = fn %{filter: %{"and" => [_scope, %{"or" => conditions}]}} ->
        if %{"id" => %{"in" => ["id-SHOP-92"]}} in conditions, do: page([light(answered)]), else: page([])
      end

      test_pid
      |> linear(listed, %{answered["id"] => answered})
      |> state(settings_fun: fn _repo -> designed_settings() end, tracker: DescriptionTracker)
      |> Inbox.run_once()

      assert_received {:listed, %{"and" => [_scope, %{"or" => conditions}]}}
      refute Enum.any?(conditions, &Map.has_key?(&1, "labels"))
      assert_received {:read, ["id-SHOP-92"]}

      assert TicketState.get_hold(RunStore.get_ticket_state("shop", "id-SHOP-92"), :needs_decision) == nil
      assert_received {:description_written, "id-SHOP-92", description}
      assert [%{id: "D1", key: "request", title: "Add the signing secret"}] = SymphonyElixir.Decisions.recorded(description)
    end

    test "keeps the last list when the store's holds can't be read" do
      test_pid = self()

      log =
        capture_log(fn ->
          test_pid
          |> linear(fn _variables -> page([]) end, %{})
          |> state(held_issue_ids: fn "shop" -> {:error, :boom} end)
          |> Inbox.run_once()
        end)

      assert log =~ "{:hold_store_unreadable, :boom}"
      refute_received {:listed, _filter}
    end

    test "reads an issue in full once, and again only when it or a comment changed" do
      test_pid = self()
      pr = issue_node("SHOP-7", %{"comments" => %{"nodes" => [comment("brief", @brief)]}})
      {:ok, listed} = Agent.start_link(fn -> [light(pr)] end)
      client = linear(test_pid, fn _variables -> page(Agent.get(listed, & &1)) end, %{pr["id"] => pr})
      state = state(client)

      state = Inbox.run_once(state)
      assert_received {:listed, %{"and" => [%{"team" => _}, %{"or" => [%{"state" => %{"name" => %{"eqIgnoreCase" => "Plan Review"}}} | conditions]}]}}
      # A held ticket sits in its phase, so the store's holds list it by id, never the label.
      assert [%{"id" => %{"in" => held}}] = conditions
      assert is_list(held)
      assert_received {:read, ["id-SHOP-7"]}
      assert [%{identifier: "SHOP-7", ask: "The retry fix for the importer."}] = Inbox.cached(state.opts[:name])

      state = Inbox.run_once(state)
      assert_received {:listed, _filter}
      refute_received {:read, _ids}

      Agent.update(listed, fn _nodes -> [light(pr, "2026-10-02T00:00:00Z")] end)
      state = Inbox.run_once(state)
      assert_received {:read, ["id-SHOP-7"]}

      Agent.update(listed, fn _nodes -> [] end)
      state = Inbox.run_once(state)
      assert state.nodes == %{}
      assert Inbox.cached(state.opts[:name]) == []
    end

    test "lists a designed repo's plan waiting in Plan Review, and drops it once it leaves" do
      test_pid = self()

      plan =
        issue_node("SHOP-330", %{
          "state" => %{"name" => "Plan Review"},
          "labels" => %{"nodes" => [%{"name" => "plan"}]},
          "history" => %{"nodes" => [moved("Plan Review", "2026-10-01T09:00:00Z")]},
          "comments" => %{"nodes" => [comment("brief", @brief)]},
          "children" => %{
            "nodes" => [%{"identifier" => "SHOP-331", "title" => "First", "url" => "u1", "createdAt" => "2026-10-01T09:01:00Z", "state" => %{"name" => "Backlog"}}]
          }
        })

      {:ok, listed} = Agent.start_link(fn -> [light(plan)] end)
      client = linear(test_pid, fn _variables -> page(Agent.get(listed, & &1)) end, %{plan["id"] => plan})
      state = state(client, settings_fun: fn _repo -> designed_settings() end)

      state = Inbox.run_once(state)
      assert_received {:listed, %{"and" => [_scope, %{"or" => conditions}]}}
      assert %{"state" => %{"name" => %{"eqIgnoreCase" => "Plan Review"}}} in conditions

      assert [
               %{
                 identifier: "SHOP-330",
                 kind: :plan,
                 state: "Plan Review",
                 ask: "The retry fix for the importer.",
                 waiting_since: ~U[2026-10-01 09:00:00Z],
                 review: %{brief: %{headline: "The retry fix for the importer."}, sub_tickets: [%{identifier: "SHOP-331", state: "Backlog"}]}
               }
             ] = Inbox.cached(state.opts[:name])

      # Approved: the parent moved on to `Waiting on sub-tickets`, which the list no longer finds.
      Agent.update(listed, fn _nodes -> [] end)
      state = Inbox.run_once(state)
      assert Inbox.cached(state.opts[:name]) == []
    end

    test "lists nothing more with the Plan Review state turned off" do
      test_pid = self()
      settings = designed_settings()
      off = %{settings | tracker: %{settings.tracker | plan_review_state: nil}}
      plan = issue_node("SHOP-330", %{"state" => %{"name" => "Plan Review"}, "labels" => %{"nodes" => [%{"name" => "plan"}]}})

      client = linear(test_pid, fn _variables -> page([light(plan)]) end, %{plan["id"] => plan})
      state = state(client, settings_fun: fn _repo -> off end) |> Inbox.run_once()

      assert_received {:listed, %{"and" => [_scope, %{"or" => conditions}]}}
      refute %{"state" => %{"name" => %{"eqIgnoreCase" => "Plan Review"}}} in conditions
      assert Inbox.cached(state.opts[:name]) == []
    end

    test "says it read Linear once a read succeeds, even one that found nothing" do
      test_pid = self()
      {:ok, answer} = Agent.start_link(fn -> {:error, :timeout} end)
      state = state(linear(test_pid, fn _variables -> Agent.get(answer, & &1) end, %{}))
      refute Inbox.read?(state.opts[:name])

      capture_log(fn -> Inbox.run_once(state) end)
      refute Inbox.read?(state.opts[:name])

      Agent.update(answer, fn _answer -> page([]) end)
      state = Inbox.run_once(state)
      assert Inbox.read?(state.opts[:name])
      assert Inbox.cached(state.opts[:name]) == []

      Inbox.run_once(state)
      assert Inbox.read?(state.opts[:name])
    end

    test "counts as read when it does not run, and not before a running server's first read" do
      assert Inbox.read?(Module.concat(__MODULE__, :NotRunning))

      name = Module.concat(__MODULE__, :NotReadYet)
      start_supervised!({Inbox, name: name, initial_delay_ms: 60_000})
      refute Inbox.read?(name)
    end

    test "reads every page of the list" do
      test_pid = self()
      first = issue_node("SHOP-1")
      second = issue_node("SHOP-2")

      list = fn
        %{after: nil} -> {:ok, %{"data" => %{"issues" => %{"nodes" => [light(first)], "pageInfo" => %{"hasNextPage" => true, "endCursor" => "c1"}}}}}
        %{after: "c1"} -> page([light(second)])
      end

      state = Inbox.run_once(state(linear(test_pid, list, %{first["id"] => first, second["id"] => second})))
      assert ["SHOP-1", "SHOP-2"] = state.opts[:name] |> Inbox.cached() |> Enum.map(& &1.identifier)
    end

    test "keeps the last list when Linear fails" do
      test_pid = self()
      pr = issue_node("SHOP-7")
      {:ok, answer} = Agent.start_link(fn -> page([light(pr)]) end)
      state = state(linear(test_pid, fn _variables -> Agent.get(answer, & &1) end, %{pr["id"] => pr}))
      state = Inbox.run_once(state)

      for failure <- [{:error, :timeout}, {:ok, %{"errors" => [%{"message" => "rate limited"}]}}, {:ok, %{"data" => nil}}] do
        Agent.update(answer, fn _answer -> failure end)
        log = capture_log(fn -> Inbox.run_once(state) end)
        assert log =~ "Inbox: could not read what waits on you"
        assert [%{identifier: "SHOP-7"}] = Inbox.cached(state.opts[:name])
      end

      failing_details = fn query, _variables, _opts ->
        if query =~ "SymphonyInboxList", do: page([light(issue_node("SHOP-8"))]), else: {:error, :timeout}
      end

      assert capture_log(fn -> Inbox.run_once(state(failing_details, name: state.opts[:name])) end) =~ ":timeout"
      assert [%{identifier: "SHOP-7"}] = Inbox.cached(state.opts[:name])

      assert capture_log(fn -> Inbox.run_once(state(failing_details, repos: fn -> {:error, :no_config} end)) end) =~ ":no_config"
      no_token = state(failing_details, scope_filter: fn _repo -> {:error, :no_token} end)
      assert capture_log(fn -> Inbox.run_once(no_token) end) =~ ":no_token"
    end

    test "polls on its own and counts its Linear requests as `inbox`" do
      test_pid = self()
      pr = issue_node("SHOP-7")
      opts = state(linear(test_pid, fn _variables -> page([light(pr)]) end, %{pr["id"] => pr})).opts
      name = Module.concat(__MODULE__, :Poller)
      start_supervised!({Inbox, Keyword.merge(opts, name: name, initial_delay_ms: 0, interval_ms: 60_000)})

      assert_receive {:read, ["id-SHOP-7"]}
      assert_received {:caller, :inbox}
      # Waits for the tick that read it to finish.
      _state = :sys.get_state(name)
      assert [%{identifier: "SHOP-7"}] = Inbox.cached(name)
    end

    test "resolves what every item mentions and where it sits in one Linear query per poll, the quality gate's tickets included" do
      test_pid = self()

      action =
        issue_node("SHOP-92", %{
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => [%{"name" => "Needs Decision"}]},
          "history" => %{"nodes" => []},
          "comments" => %{"nodes" => [comment("request", String.replace(request_body(), "Releases fail to sign.", "SHOP-5 fails to sign, see #7."), "2026-10-01T08:00:01Z")]}
        })

      plan = issue_node("SHOP-330", %{"comments" => %{"nodes" => [comment("brief", String.replace(@brief, "The retry fix", "SHOP-6, the retry fix"))]}})

      held = %{
        kind: :clarification,
        issue_id: "id-SHOP-50",
        identifier: "SHOP-50",
        title: "Vague",
        repo_key: "shop",
        state: "Todo",
        url: "https://linear.app/acme/issue/SHOP-50",
        reason: "Like SHOP-5, it has no criteria.",
        questions: [],
        scored_at: ~U[2026-10-01 07:00:00Z]
      }

      references = %{
        "own" => [%{"id" => "id-SHOP-92", "identifier" => "SHOP-92", "parent" => %{"identifier" => "SHOP-330", "title" => "Plan", "children" => %{"nodes" => []}}}],
        "mentioned" => [issue_node("SHOP-5", %{"state" => %{"name" => "Todo", "type" => "unstarted"}, "description" => "Sign builds."})]
      }

      details = %{action["id"] => action, plan["id"] => plan}
      client = linear(test_pid, fn _variables -> page([light(action), light(plan)]) end, details, references)
      {:ok, reads} = Agent.start_link(fn -> 0 end)

      state =
        state(client,
          settings_fun: fn _repo -> designed_settings() end,
          snapshot: fn -> %{awaiting_clarification: [held]} end,
          pull_request: fn url ->
            Agent.update(reads, &(&1 + 1))
            {:ok, pull_request(url)}
          end
        )

      state = Inbox.run_once(state)
      assert_received {:references, variables}
      refute_received {:references, _second_query}
      assert variables.own == %{"id" => %{"in" => ["id-SHOP-92", "id-SHOP-330", "id-SHOP-50"]}}
      assert length(variables.mentioned["or"]) == 3

      [action_item, plan_item] = Inbox.cached(state.opts[:name])
      assert %{kind: "ticket", title: "Title of SHOP-5", summary: "Sign builds."} = action_item.references["SHOP-5"]
      assert %{kind: "pull_request", number: 7, files: 3, ticket: "SHOP-7"} = action_item.references["#7"]
      assert %{parent: %{identifier: "SHOP-330", total: 0}} = action_item.context
      assert %{"SHOP-6" => %{kind: "missing", url: "https://linear.app/acme/issue/SHOP-6"}, "PR #7" => %{kind: "pull_request"}} = plan_item.references

      # The held ticket is listed from the snapshot at GET time, with what the poll resolved for it,
      # and each ticket reference says what it waits on now.
      items = Inbox.items(%{awaiting_clarification: [held], running: [%{issue_id: "id-SHOP-5"}]}, state.opts[:name])
      clarify = Enum.find(items, &(&1.kind == :clarify))
      assert %{references: %{"SHOP-5" => %{kind: "ticket", waiting_on: nil} = shop5}} = clarify
      assert %{parent: nil, earlier_decisions: []} = clarify.context
      refute Map.has_key?(shop5, :facts)
      assert Enum.find(Inbox.items(%{awaiting_clarification: [held]}, state.opts[:name]), &(&1.kind == :clarify)).references["SHOP-5"].waiting_on == "a slot"

      # The next poll reuses the pull request it just read.
      assert Agent.get(reads, & &1) == 1
      _state = Inbox.run_once(state)
      assert Agent.get(reads, & &1) == 1
    end

    test "reads each repo's GitHub repository once, and again when the repos change" do
      test_pid = self()
      pr = issue_node("SHOP-7")
      base = state(linear(test_pid, fn _variables -> page([light(pr)]) end, %{pr["id"] => pr}))
      state = %{base | opts: Keyword.delete(base.opts, :github_repos)}

      state = Inbox.run_once(state)
      assert state.github_repos == {[@repo], %{}}
      assert Inbox.run_once(state).github_repos == {[@repo], %{}}

      other = %{name: "other"}
      changed = %{state | opts: Keyword.put(state.opts, :repos, fn -> {:ok, [other]} end)}
      assert Inbox.run_once(changed).github_repos == {[other], %{}}
    end

    test "an unavailable orchestrator snapshot resolves no quality gate tickets" do
      test_pid = self()
      pr = issue_node("SHOP-7")
      client = linear(test_pid, fn _variables -> page([light(pr)]) end, %{pr["id"] => pr})
      Inbox.run_once(state(client, snapshot: fn -> :unavailable end))
      assert_received {:references, %{own: %{"id" => %{"in" => ["id-SHOP-7"]}}}}
    end

    test "is on for a Linear tracker" do
      assert Inbox.enabled?(%Schema{tracker: %Schema.Tracker{kind: "linear"}})
      refute Inbox.enabled?(%Schema{tracker: %Schema.Tracker{kind: "memory"}})
      refute Inbox.enabled?(nil)
      assert Inbox.cached({:test, make_ref()}) == []
    end
  end

  describe "items/2" do
    test "adds the quality gate's holds and skips, drops running tickets and ones that left review, oldest first" do
      name = {:test, make_ref()}

      cached = fn identifier, hours_ago ->
        %{
          issue_id: "id-" <> identifier,
          identifier: identifier,
          title: nil,
          repo_key: "shop",
          kind: :plan,
          state: "Plan Review",
          ask: "Review",
          waiting_since: hours_ago && DateTime.add(~U[2026-10-01 12:00:00Z], -hours_ago * 3_600),
          url: nil,
          review: %{}
        }
      end

      :persistent_term.put({Inbox, :items, name}, [
        cached.("SHOP-1", 1),
        cached.("SHOP-2", nil),
        cached.("SHOP-3", 3),
        cached.("SHOP-RUN", 5),
        cached.("SHOP-LEFT", 6),
        cached.("SHOP-HR", 2)
      ])

      held = %{
        kind: :clarification,
        issue_id: "id-SHOP-50",
        identifier: "SHOP-50",
        title: "Vague",
        repo_key: "shop",
        state: "Todo",
        url: "https://linear.app/acme/issue/SHOP-50",
        score: 3,
        reason: "No acceptance criteria.",
        rounds_asked: 1,
        max_rounds: 2,
        pass_threshold: 6,
        questions: ["What should it do?"],
        scored_at: ~U[2026-10-01 07:00:00Z]
      }

      skipped = %{kind: :scored, issue_id: "id-SHOP-51", identifier: "SHOP-51", score: 2, reason: "Empty.", scored_at: ~U[2026-10-01 11:30:00Z]}

      snapshot = %{
        running: [%{issue_id: "id-SHOP-RUN"}],
        watching: [%{issue_id: "id-SHOP-LEFT", state: "Merging"}, %{issue_id: "id-SHOP-HR", state: "plan review"}],
        awaiting_clarification: [held, %{held | issue_id: nil}],
        skipped: [skipped]
      }

      items = Inbox.items(snapshot, name)
      assert Enum.map(items, & &1.identifier) == ["SHOP-50", "SHOP-3", "SHOP-HR", "SHOP-1", "SHOP-51", "SHOP-2"]
      assert %{state: "plan review"} = Enum.find(items, &(&1.identifier == "SHOP-HR"))

      assert %{
               kind: :clarify,
               ask: "Answer the quality gate's questions",
               state: "Todo",
               review: %{held: true, score: 3, pass_threshold: 6, round: 1, max_rounds: 2, found: "No acceptance criteria.", questions: ["What should it do?"]}
             } = hd(items)

      assert %{kind: :clarify, ask: "Rewrite the ticket: the quality gate skipped it", review: %{held: false, questions: []}} =
               Enum.find(items, &(&1.identifier == "SHOP-51"))

      assert Inbox.items(%{}, name) |> length() == 6
    end

    test "keeps a held ticket whatever state the orchestrator last saw it in" do
      name = {:test, make_ref()}

      entry = fn identifier, kind ->
        %{
          issue_id: "id-" <> identifier,
          identifier: identifier,
          title: nil,
          repo_key: "shop",
          kind: kind,
          state: "In Progress",
          ask: "Ask",
          waiting_since: ~U[2026-10-01 12:00:00Z],
          url: nil,
          review: %{}
        }
      end

      :persistent_term.put({Inbox, :items, name}, [entry.("SHOP-70", :blocked), %{entry.("SHOP-71", :plan) | state: "Plan Review"}])

      snapshot = %{
        running: [],
        watching: [%{issue_id: "id-SHOP-70", state: "In Progress"}, %{issue_id: "id-SHOP-71", state: "In Progress"}]
      }

      # The hold is what waits on the Director; an item with no hold that left Plan Review does not.
      assert Enum.map(Inbox.items(snapshot, name), & &1.identifier) == ["SHOP-70"]
    end

    test "keeps a plan while the orchestrator still sees it in the state the read listed it in" do
      name = {:test, make_ref()}

      plan = fn identifier, state ->
        %{
          issue_id: "id-" <> identifier,
          identifier: identifier,
          title: nil,
          repo_key: "shop",
          kind: :plan,
          state: state,
          ask: "Approve the plan",
          waiting_since: ~U[2026-10-01 12:00:00Z],
          url: nil,
          review: %{}
        }
      end

      :persistent_term.put({Inbox, :items, name}, [plan.("SHOP-80", "Plan Review"), plan.("SHOP-81", "Plan Review"), plan.("SHOP-82", nil)])

      snapshot = %{
        running: [],
        watching: [
          %{issue_id: "id-SHOP-80", state: " plan review "},
          %{issue_id: "id-SHOP-81", state: "Waiting on sub-tickets"},
          %{issue_id: "id-SHOP-82", state: "QA"}
        ]
      }

      assert [%{identifier: "SHOP-80", state: " plan review "}] = Inbox.items(snapshot, name)
    end
  end
end
