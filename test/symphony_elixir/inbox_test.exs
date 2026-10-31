defmodule SymphonyElixir.InboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.{Issue, Usage}
  alias SymphonyElixir.MergeConfirmation
  alias SymphonyElixir.{RunStore, TicketState}

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

  describe "Item.from_node/4" do
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
      attrs = SymphonyElixir.OperatorStop.hold_attrs(~U[2026-10-01 06:00:00Z])
      hold = Map.merge(attrs, %{kind: :blocked, decision: nil, set_at: ~U[2026-10-01 06:00:00Z]})

      assert %{kind: :blocked, ask: "Stopped by you at 2026-10-01 06:00:00 UTC. " <> _, waiting_since: ~U[2026-10-01 06:00:00Z]} =
               Item.from_node(held, "shop", %Schema{}, lookups(hold))
    end

    test "reads an option and a quality-gate entry" do
      assert Item.option("Plain text") == %{label: "Plain text", effect: nil, recommended: false}
      assert Item.option("**Keep** (recommended):") == %{label: "Keep", effect: nil, recommended: true}

      assert %{kind: :clarify, ask: "The quality gate couldn't score the ticket", waiting_since: ~U[2026-10-01 07:00:00Z], review: %{held: false, found: "LLM call failed"}} =
               Item.from_quality_gate(%{kind: :error, issue_id: "id-1", reason: "LLM call failed", updated_at: ~U[2026-10-01 07:00:00Z]})

      assert %{kind: :clarify, ask: "Rewrite the ticket: the quality gate skipped it", waiting_since: ~U[2026-10-01 07:30:00Z], review: %{held: false, questions: []}} =
               Item.from_quality_gate(%{kind: :scored, issue_id: "id-2", score: 2, reason: "Empty.", scored_at: ~U[2026-10-01 07:30:00Z]})
    end
  end

  describe "items/2 over the records" do
    # A repository of its own, so the shared run store holds no other test's records for it.
    defp repo_key, do: "shop-#{System.unique_integer([:positive])}"

    defp inbox(records, opts \\ []) do
      Keyword.merge(
        [
          name: {:test, make_ref()},
          records: fn -> records end,
          settings_fun: fn _repo_key -> {:ok, %Schema{}} end,
          github_repos: %{},
          pull_request: fn url -> flunk("read #{url} from GitHub") end
        ],
        opts
      )
    end

    defp record(repo_key, identifier, attrs \\ %{}) do
      TicketState.new(
        repo_key,
        "id-" <> identifier,
        Map.merge(%{issue_identifier: identifier, title: "Title of " <> identifier, phase: "In Progress", phase_at: ~U[2026-10-01 08:00:00Z]}, attrs)
      )
    end

    defp put_record(record) do
      :ok = RunStore.put_ticket_state(record)
      record
    end

    defp stored(repo_key), do: inbox(nil, records: fn -> Enum.filter(RunStore.list_all_ticket_states(), &(&1.repo_key == repo_key)) end)

    @request %{
      title: "Add the signing secret",
      question: "Add the secret?",
      why: "Releases fail to sign.",
      if_unanswered: "Every release stays unsigned.",
      recommendation_reason: "Signing is a one-time setup.",
      options: [%{label: "Add it", effect: "Releases sign again.", recommended: true}, %{label: "Drop signing", effect: "Unsigned builds."}]
    }

    test "an answer, an Unblock and a Stop show on the very next read, with no Linear request" do
      repo_key = repo_key()
      asked = put_record(record(repo_key, "SHOP-95"))
      stopped = put_record(record(repo_key, "SHOP-96"))
      {:ok, question} = SymphonyElixir.Questions.ask({:ticket, repo_key, asked.issue_id}, @request)
      inbox = stored(repo_key)

      assert [%{identifier: "SHOP-95", kind: :action, review: %{question_id: question_id}}] = Inbox.items(%{}, inbox)
      assert question_id == question.id

      # Send Decisions: the row goes.
      {:ok, _answered} = SymphonyElixir.Questions.answer({:ticket, repo_key, asked.issue_id}, question.id, "Drop signing")
      assert Inbox.items(%{}, inbox) == []

      # Stop: the ticket waits as Stopped by you; Unblock lifts it.
      :ok = SymphonyElixir.OperatorStop.mark(repo_key, stopped.issue_id, ~U[2026-10-01 09:00:00Z])
      assert [%{identifier: "SHOP-96", kind: :blocked, ask: "Stopped by you" <> _}] = Inbox.items(%{}, inbox)
      {:ok, nil} = SymphonyElixir.Pauses.clear_reasons({:ticket, repo_key, stopped.issue_id}, fn _reason -> true end)
      assert Inbox.items(%{}, inbox) == []

      refute Enum.any?(Usage.snapshot().callers, &(&1.caller == "inbox"))
    end

    test "reads the run store by default, and lists nothing when it can't be read" do
      repo_key = repo_key()
      record = put_record(record(repo_key, "SHOP-97"))
      {:ok, _question} = SymphonyElixir.Questions.ask({:ticket, repo_key, record.issue_id}, @request)
      settings_fun = fn _repo_key -> {:ok, %Schema{}} end

      assert Enum.any?(Inbox.items(%{}, settings_fun: settings_fun, github_repos: %{}), &(&1.issue_id == record.issue_id))
      assert Enum.any?(Inbox.rows(settings_fun: settings_fun), &(&1.issue_id == record.issue_id))
      assert Inbox.items(%{}, inbox(nil, records: fn -> {:error, :unavailable} end)) == []
    end

    test "leaves out a record of a repository the configuration no longer names" do
      records = [record("gone", "SHOP-98", %{pause: pause()}), record("shop", "SHOP-99", %{pause: pause()})]

      settings_fun = fn
        "shop" -> %Schema{}
        "gone" -> {:error, :unknown_repo}
      end

      assert [%{identifier: "SHOP-99"}] = Inbox.items(%{}, inbox(records, settings_fun: settings_fun))
      assert [%{identifier: "SHOP-99"}] = Inbox.rows(inbox(records, settings_fun: settings_fun))
      assert Inbox.items(%{}, inbox([%{issue_id: "id-x", pause: pause()}])) == []
    end

    test "drops a running ticket, and fills each mention's waiting_on from what runs and waits" do
      blocker = record("shop", "SHOP-11", %{phase: "Todo"})
      waiting = record("shop", "SHOP-12", %{pause: pause("Waits on SHOP-11 and SHOP-13")})
      running = record("shop", "SHOP-13", %{pause: pause()})

      assert [%{identifier: "SHOP-12", references: references}] = Inbox.items(%{running: [%{issue_id: running.issue_id}]}, inbox([blocker, waiting, running]))
      assert %{"SHOP-11" => %{kind: "ticket", waiting_on: "a slot"}, "SHOP-13" => %{kind: "ticket", waiting_on: nil}} = references
      refute Map.has_key?(references["SHOP-11"], :facts)
    end

    test "reads GitHub for a row's pull requests only when the row changed since it last read them" do
      test_pid = self()
      watched = record("shop", "SHOP-20", %{pr_watch: %{facts: %SymphonyElixir.PrDecision.Facts{}, pr_url: "https://github.com/acme/shop/pull/20"}, pause: pause("Waits on #21")})

      fetch = fn url ->
        send(test_pid, {:read, url})
        {:ok, pull_request(url)}
      end

      inbox = inbox([watched], github_repos: %{"shop" => "acme/shop"}, pull_request: fetch)

      assert [%{context: %{pull_request: %{number: 20, checks: "passed"}}, references: %{"#21" => %{kind: "pull_request", number: 21}}}] =
               Inbox.items(%{}, inbox)

      assert_received {:read, "https://github.com/acme/shop/pull/21"}
      assert_received {:read, "https://github.com/acme/shop/pull/20"}

      assert [%{context: %{pull_request: %{checks: "passed"}}}] = Inbox.items(%{}, inbox)
      refute_received {:read, _url}

      changed = %{watched | pause: pause("Waits on #22")}
      assert [%{references: %{"#22" => %{number: 22}}}] = Inbox.items(%{}, Keyword.put(inbox, :records, fn -> [changed] end))
      assert_received {:read, "https://github.com/acme/shop/pull/22"}
    end
  end

  defp pause(text \\ "Waiting for the registry token") do
    director = %{kind: :person, name: "Director"}
    at = ~U[2026-10-01 09:00:00Z]
    waits_on = %{condition: "the registry token"}
    reason = %{kind: :environment, waits_on: waits_on, text: text, releasable: true, set_at: at, set_by: director}
    %{subject: :symphony, reasons: [reason], set_by: director, since: at}
  end
end
