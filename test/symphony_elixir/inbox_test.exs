defmodule SymphonyElixir.InboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.Usage
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

  describe "Item.plan_from_node/2" do
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
               brief: %{format: "parsed", headline: "The retry fix for the importer.", moves: [%{move: "approve"}]},
               sub_tickets: [%{identifier: "SHOP-331", title: "First", url: "u1", state: "Backlog"}, %{identifier: "SHOP-332"}]
             } = Item.plan_from_node(plan, %Schema{})
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

      assert %{brief: %{format: "parsed"}, decisions: [undated, first, card]} = review = Item.plan_from_node(plan, %Schema{})

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

    test "a plan without a brief has nothing but its approval to show" do
      assert Item.plan_from_node(issue_node("SHOP-331"), %Schema{}) == %{brief: nil, sub_tickets: [], decisions: []}
    end

    test "a ticket with no plan label, or one outside Plan Review, is no plan" do
      for node <- [
            issue_node("SHOP-8", %{"labels" => %{"nodes" => []}}),
            issue_node("SHOP-340", %{"title" => "Final verification: Gift cards", "labels" => %{"nodes" => []}}),
            issue_node("SHOP-341", %{"state" => %{"name" => "In Review"}}),
            issue_node("SHOP-9", %{"state" => %{"name" => "Todo"}})
          ] do
        assert Item.plan_from_node(node, %Schema{}) == nil
      end
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
      :ok = SymphonyElixir.Pauses.stop({:ticket, repo_key, stopped.issue_id}, ~U[2026-10-01 09:00:00Z])
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
