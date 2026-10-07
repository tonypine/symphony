defmodule SymphonyElixir.InboxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.Linear.Usage

  @repo %{name: "shop"}

  defp issue_node(identifier, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "state" => %{"name" => "In Review"},
        "labels" => %{"nodes" => []},
        "attachments" => %{"nodes" => []},
        "children" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => [moved("In Review", "2026-10-01T10:00:00Z")]}
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
    Request.render(
      %{
        title: "Add the signing secret",
        question: "Add the secret?",
        why: "Releases fail to sign.",
        unblocks: "the Release workflow",
        est_minutes: 5,
        options: [%{label: "Add it", effect: "Releases sign again.", recommended: true}, %{label: "Drop signing", effect: "Unsigned builds."}]
      },
      "Human Review"
    )
  end

  # A Linear stand-in serving `listed` (light nodes) and `details` (full nodes by id), and reporting
  # each query to the test process.
  defp linear(test_pid, listed_fun, details) do
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
            ci: fn _issue_id, _repo_key -> nil end,
            gate: fn _repo_key, _issue_id -> nil end
          ],
          opts
        ),
      nodes: %{},
      timer: make_ref()
    }
  end

  defp lookups(ci \\ nil, gate \\ nil), do: %{ci: fn _issue_id, _repo_key -> ci end, gate: fn _repo_key, _issue_id -> gate end}

  describe "items from Linear" do
    test "a PR with its brief, PR, CI, QA result, gate verdict and change size" do
      pr =
        issue_node("SHOP-7", %{
          "attachments" => %{"nodes" => [%{"url" => "https://example.com/doc"}, %{"url" => "https://github.com/acme/shop/pull/7"}]},
          "comments" => %{
            "nodes" => [
              comment("brief", @brief),
              comment("4f0a2b1c-aaaa-bbbb", "## Symphony QA Report\n\n**Verdict:** pass → In Review\n")
            ]
          }
        })

      gate = %{verdict: "escalate", mode: "shadow", agent_verdict: "approve", change: %{files: 3, additions: 120, deletions: 4, largest: []}}

      assert %{
               issue_id: "id-SHOP-7",
               identifier: "SHOP-7",
               repo_key: "shop",
               kind: :pr,
               state: "In Review",
               ask: "The retry fix for the importer.",
               waiting_since: ~U[2026-10-01 10:00:00Z],
               url: "https://linear.app/acme/issue/SHOP-7",
               review: %{
                 brief: %{format: "parsed", headline: "The retry fix for the importer.", moves: [%{move: "approve"}]},
                 pull_request: %{
                   url: "https://github.com/acme/shop/pull/7",
                   ci: "passed",
                   qa: %{verdict: "pass", report_url: "https://linear.app/acme/issue/SHOP-7#comment-4f0a2b1c"},
                   gate: %{verdict: "escalate", mode: "shadow", agent_verdict: "approve"},
                   change: %{files: 3, additions: 120, deletions: 4}
                 }
               }
             } = Item.from_node(pr, "shop", %Schema{}, lookups("SUCCESS", gate))
    end

    test "a PR without a brief, a PR link, CI, QA or a gate verdict" do
      assert %{ask: "Review the pull request", review: %{brief: nil, pull_request: %{url: nil, ci: nil, qa: nil, gate: nil, change: nil}}} =
               Item.from_node(issue_node("SHOP-8"), "shop", %Schema{}, lookups())
    end

    test "a plan with its sub-tickets in landing order, and a final verification" do
      plan =
        issue_node("SHOP-330", %{
          "labels" => %{"nodes" => [%{"name" => "plan"}]},
          "children" => %{
            "nodes" => [
              %{"identifier" => "SHOP-332", "title" => "Second", "url" => "u2", "createdAt" => "2026-10-01T09:02:00Z", "state" => %{"name" => "Backlog"}},
              %{"identifier" => "SHOP-331", "title" => "First", "url" => "u1", "createdAt" => "2026-10-01T09:01:00Z", "state" => %{"name" => "Backlog"}}
            ]
          }
        })

      assert %{
               kind: :plan,
               ask: "Approve the plan",
               review: %{brief: nil, sub_tickets: [%{identifier: "SHOP-331", title: "First", url: "u1", state: "Backlog"}, %{identifier: "SHOP-332"}]}
             } = Item.from_node(plan, "shop", %Schema{}, lookups())

      verification = issue_node("SHOP-340", %{"title" => "Final verification: Gift cards"})

      assert %{kind: :final_verification, ask: "Sign off the final verification", review: %{brief: nil}} =
               Item.from_node(verification, "shop", %Schema{}, lookups())
    end

    test "an action with why, options, time and what it unblocks" do
      action =
        issue_node("SHOP-90", %{
          "state" => %{"name" => "Human Review"},
          "history" => %{"nodes" => [moved("Human Review", "2026-10-01T08:00:00Z")]},
          "comments" => %{"nodes" => [comment("request", request_body(), "2026-10-01T08:00:01Z")]}
        })

      assert %{
               kind: :action,
               ask: "Add the signing secret",
               review: %{
                 title: "Add the signing secret",
                 question: "Add the secret?",
                 why: "Releases fail to sign.",
                 unblocks: "the Release workflow",
                 est_minutes: 5,
                 steps: [],
                 options: [
                   %{label: "Add it", effect: "Releases sign again.", recommended: true},
                   %{label: "Drop signing", effect: "Unsigned builds.", recommended: false}
                 ],
                 requested_at: ~U[2026-10-01 08:00:01Z]
               }
             } = Item.from_node(action, "shop", %Schema{}, lookups())
    end

    test "nothing for an issue that left the review states" do
      assert Item.from_node(issue_node("SHOP-9", %{"state" => %{"name" => "Todo"}}), "shop", %Schema{}, lookups()) == nil
    end

    test "reads an option, a CI conclusion and a quality-gate entry" do
      assert Item.option("Plain text") == %{label: "Plain text", effect: nil, recommended: false}
      assert Item.option("**Keep** (recommended):") == %{label: "Keep", effect: nil, recommended: true}
      assert Item.ci_result("FAILURE") == "failed"
      assert Item.ci_result("IN_PROGRESS") == "pending"
      assert Item.ci_result(nil) == nil

      assert %{kind: :clarify, ask: "The quality gate couldn't score the ticket", waiting_since: ~U[2026-10-01 07:00:00Z], review: %{held: false, found: "LLM call failed"}} =
               Item.from_quality_gate(%{kind: :error, issue_id: "id-1", reason: "LLM call failed", updated_at: ~U[2026-10-01 07:00:00Z]})
    end
  end

  describe "the poller" do
    test "reads an issue in full once, and again only when it or a comment changed" do
      test_pid = self()
      pr = issue_node("SHOP-7", %{"comments" => %{"nodes" => [comment("brief", @brief)]}})
      {:ok, listed} = Agent.start_link(fn -> [light(pr)] end)
      client = linear(test_pid, fn _variables -> page(Agent.get(listed, & &1)) end, %{pr["id"] => pr})
      state = state(client)

      state = Inbox.run_once(state)
      assert_received {:listed, %{"and" => [%{"team" => _}, %{"or" => [%{"state" => %{"name" => %{"eqIgnoreCase" => "In Review"}}} | _]}]}}
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
          kind: :pr,
          state: "In Review",
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
        watching: [%{issue_id: "id-SHOP-LEFT", state: "Merging"}, %{issue_id: "id-SHOP-HR", state: "Human Review"}],
        awaiting_clarification: [held, %{held | issue_id: nil}],
        skipped: [skipped]
      }

      items = Inbox.items(snapshot, name)
      assert Enum.map(items, & &1.identifier) == ["SHOP-50", "SHOP-3", "SHOP-HR", "SHOP-1", "SHOP-51", "SHOP-2"]
      assert %{state: "Human Review"} = Enum.find(items, &(&1.identifier == "SHOP-HR"))

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
  end
end
