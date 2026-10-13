defmodule SymphonyElixir.InitiativesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Initiatives
  alias SymphonyElixir.Initiatives.Initiative
  alias SymphonyElixir.Linear.Usage

  @now ~U[2026-10-12 12:00:00Z]
  @repo %{name: "billing"}

  defp settings, do: %Schema{}

  defp child(identifier, state, attrs \\ %{}) do
    {name, type} = state

    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Title of " <> identifier,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "createdAt" => "2026-10-01T10:00:00Z",
        "state" => %{"name" => name, "type" => type},
        "inverseRelations" => %{"nodes" => []}
      },
      attrs
    )
  end

  defp blocked_by(blockers) do
    %{
      "inverseRelations" => %{
        "nodes" =>
          Enum.map(blockers, fn {identifier, type} ->
            %{"type" => "blocks", "issue" => %{"identifier" => identifier, "state" => %{"name" => "x", "type" => type}}}
          end) ++ [%{"type" => "related", "issue" => %{"identifier" => "BIL-999"}}]
      }
    }
  end

  defp plan(identifier, state, children, attrs \\ %{}) do
    {name, type} = state

    Map.merge(
      %{
        "id" => "id-" <> identifier,
        "identifier" => identifier,
        "title" => "Plan " <> identifier,
        "url" => "https://linear.app/acme/issue/" <> identifier,
        "completedAt" => nil,
        "state" => %{"name" => name, "type" => type},
        "children" => %{"nodes" => children}
      },
      attrs
    )
  end

  @done {"Done", "completed"}
  @todo {"Todo", "unstarted"}
  @in_review {"In Review", "started"}
  @in_progress {"In Progress", "started"}

  describe "from_node/4" do
    test "groups plan tickets as active, in review or done recently, and skips the rest" do
      assert %{group: "active"} = Initiative.from_node(plan("BIL-1", {"Waiting on sub-tickets", "started"}, []), "billing", settings(), @now)
      assert %{group: "in_review"} = Initiative.from_node(plan("BIL-2", @in_review, []), "billing", settings(), @now)
      assert %{group: "in_review"} = Initiative.from_node(plan("BIL-3", {"Epic Review", "started"}, []), "billing", settings(), @now)
      assert %{group: "done"} = Initiative.from_node(plan("BIL-4", @done, [], %{"completedAt" => "2026-10-08T00:00:00Z"}), "billing", settings(), @now)

      assert Initiative.from_node(plan("BIL-5", @done, [], %{"completedAt" => "2026-09-01T00:00:00Z"}), "billing", settings(), @now) == nil
      assert Initiative.from_node(plan("BIL-6", @done, [], %{"completedAt" => "yesterday"}), "billing", settings(), @now) == nil
      assert Initiative.from_node(plan("BIL-7", @done, []), "billing", settings(), @now) == nil
      assert Initiative.from_node(plan("BIL-8", {"Canceled", "canceled"}, []), "billing", settings(), @now) == nil
      assert Initiative.from_node(plan("BIL-9", {"Backlog", "backlog"}, []), "billing", settings(), @now) == nil
      assert Initiative.from_node(%{"identifier" => "BIL-10"}, "billing", settings(), @now) == nil
      assert %{group: "active", state: nil} = Initiative.from_node(plan("BIL-11", {nil, "started"}, []), "billing", settings(), @now)
    end

    test "orders sub-tickets by blocked-by, then creation, and sets the final verification apart" do
      children = [
        child("BIL-4", @todo, Map.merge(%{"createdAt" => "2026-10-01T09:00:00Z"}, blocked_by([{"BIL-3", "unstarted"}]))),
        child("BIL-3", @todo, %{"createdAt" => "2026-10-02T09:00:00Z"}),
        child("BIL-2", @done, %{"createdAt" => "2026-10-03T09:00:00Z"}),
        child("BIL-9", {"Canceled", "canceled"}),
        child("BIL-8", @todo, %{"title" => "Final verification: the epic"}),
        child("BIL-6", @todo, Map.merge(%{"createdAt" => "2026-10-04T09:00:00Z"}, blocked_by([{"BIL-7", "unstarted"}]))),
        child("BIL-7", @todo, Map.merge(%{"createdAt" => "2026-10-05T09:00:00Z"}, blocked_by([{"BIL-6", "unstarted"}]))),
        child("BIL-5", @todo, %{"createdAt" => nil, "title" => nil})
      ]

      initiative = Initiative.from_node(plan("BIL-1", @in_progress, children), "billing", settings(), @now)

      # BIL-6 and BIL-7 block each other: creation order breaks the cycle.
      assert Enum.map(initiative.sub_tickets, & &1.identifier) == ["BIL-5", "BIL-3", "BIL-4", "BIL-2", "BIL-6", "BIL-7"]
      assert initiative.final_verification.identifier == "BIL-8"
      assert hd(Enum.filter(initiative.sub_tickets, &(&1.identifier == "BIL-4"))).blocked_by == [%{identifier: "BIL-3", state: "x", open: true}]
      assert initiative.repo_key == "billing"
      refute initiative.incomplete
    end

    test "keeps the oldest open final verification and leaves the others in the sub-tickets" do
      final = &child(&1, &2, %{"title" => "Final verification: the epic", "createdAt" => &3})

      children = [
        final.("BIL-4", @todo, "2026-10-03T09:00:00Z"),
        final.("BIL-3", @todo, "2026-10-02T09:00:00Z"),
        final.("BIL-2", @done, "2026-10-01T09:00:00Z")
      ]

      initiative = Initiative.from_node(plan("BIL-1", @in_progress, children), "billing", settings(), @now)
      assert initiative.final_verification.identifier == "BIL-3"
      assert Enum.map(initiative.sub_tickets, & &1.identifier) == ["BIL-2", "BIL-4"]

      all_done = [final.("BIL-6", @done, "2026-10-02T09:00:00Z"), final.("BIL-5", @done, "2026-10-01T09:00:00Z")]
      all_done = Initiative.from_node(plan("BIL-1", @in_progress, all_done), "billing", settings(), @now)
      assert all_done.final_verification.identifier == "BIL-5"
      assert Enum.map(all_done.sub_tickets, & &1.identifier) == ["BIL-6"]
    end

    test "flags a plan whose sub-tickets or blockers run past one read as incomplete" do
      more = %{"pageInfo" => %{"hasNextPage" => true}}
      many_children = plan("BIL-1", @in_progress, [child("BIL-2", @todo)], %{"children" => Map.put(more, "nodes", [child("BIL-2", @todo)])})
      assert Initiative.from_node(many_children, "billing", settings(), @now).incomplete

      many_blockers = child("BIL-2", @todo, %{"inverseRelations" => Map.put(more, "nodes", [])})
      assert Initiative.from_node(plan("BIL-1", @in_progress, [many_blockers]), "billing", settings(), @now).incomplete
    end
  end

  describe "parent_of/2" do
    test "names the plan that has the ticket among its sub-tickets or as its final verification" do
      node =
        plan("BIL-1", @in_progress, [
          child("BIL-2", @done),
          child("BIL-3", @todo, %{"title" => "Final verification: Plan BIL-1"})
        ])

      other = plan("BIL-9", @in_progress, [])
      initiatives = Enum.map([other, node], &Initiative.from_node(&1, "billing", settings(), @now))

      assert Initiatives.parent_of("id-BIL-2", initiatives) == %{identifier: "BIL-1", title: "Plan BIL-1"}
      assert Initiatives.parent_of("id-BIL-3", initiatives) == %{identifier: "BIL-1", title: "Plan BIL-1"}
      assert Initiatives.parent_of("id-BIL-4", initiatives) == nil
      assert Initiatives.parent_of("id-BIL-2") == nil
    end
  end

  describe "live/2" do
    test "says what each sub-ticket waits on and counts the stages" do
      children = [
        child("BIL-2", @done),
        child("BIL-3", {"In Progress", "started"}),
        child("BIL-4", {"Human Review", "started"}),
        child("BIL-5", @todo, blocked_by([{"BIL-4", "started"}, {"BIL-2", "completed"}])),
        child("BIL-6", {"Code Review", "started"}),
        child("BIL-7", @todo),
        child("BIL-8", {"Backlog", "backlog"}),
        child("BIL-10", @todo, blocked_by([{"BIL-4", "started"}])),
        child("BIL-11", @in_review),
        child("BIL-9", {"Todo", "unstarted"}, Map.merge(%{"title" => "Final verification: billing"}, blocked_by([{"BIL-7", "unstarted"}])))
      ]

      settings = %Schema{tracker: %{kind: "memory", human_review_state: "Human Review"}}

      initiative = Initiative.from_node(plan("BIL-1", @in_progress, children), "billing", settings, @now)
      live = Initiative.live(initiative, %{running: MapSet.new(["id-BIL-3"]), you: MapSet.new(["id-BIL-4"]), settings: settings})

      waits = Map.new(live.sub_tickets, &{&1.identifier, &1.waits_on})

      assert waits == %{
               "BIL-2" => "done",
               "BIL-3" => "working",
               "BIL-4" => "you",
               "BIL-5" => "blocker",
               "BIL-6" => "ci",
               "BIL-7" => "slot",
               "BIL-8" => "you",
               "BIL-10" => "blocker",
               "BIL-11" => "you"
             }

      assert Enum.find(live.sub_tickets, &(&1.identifier == "BIL-5")).waiting_for == ["BIL-4"]
      assert live.counts == %{"done" => 1, "working" => 2, "you" => 3, "queued" => 1, "blocked" => 2, "total" => 9}
      assert %{identifier: "BIL-9", waits_on: "blocker", open_tickets: 8} = live.final_verification
      assert Initiative.stages() == ~w(done working you queued blocked)

      no_final = Initiative.live(%{initiative | final_verification: nil}, %{running: MapSet.new(), you: MapSet.new(), settings: nil})
      assert no_final.final_verification == nil
    end
  end

  describe "the server" do
    defp linear(test_pid, pages) do
      fn query, variables, _opts ->
        send(test_pid, {:query, query, variables, Usage.current_caller()})
        Map.fetch!(pages, variables.after)
      end
    end

    defp page(nodes, next \\ nil) do
      info = if next, do: %{"hasNextPage" => true, "endCursor" => next}, else: %{"hasNextPage" => false}
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => info}}}}
    end

    defp server_state(linear_client, opts \\ []) do
      %{
        opts:
          Keyword.merge(
            [
              name: {:test, make_ref()},
              repos: fn -> {:ok, [@repo, %{name: "billing-copy"}]} end,
              settings_fun: fn _repo -> settings() end,
              scope_filter: fn repo -> {:ok, %{"team" => %{"key" => %{"eq" => repo.name}}}} end,
              linear_client: linear_client,
              now: fn -> @now end
            ],
            opts
          ),
        timer: make_ref()
      }
    end

    test "reads the plan tickets of every route on the poll, page by page, and caches them" do
      first = plan("BIL-1", @in_progress, [child("BIL-2", @todo)])
      second = plan("BIL-3", @done, [], %{"completedAt" => "2026-09-01T00:00:00Z"})
      pages = %{nil => page([first], "c1"), "c1" => page([second])}

      state = server_state(linear(self(), pages))
      name = Keyword.fetch!(state.opts, :name)

      refute Initiatives.read?(name)
      assert Initiatives.cached(name) == []

      Initiatives.run_once(state)

      assert_received {:query, query, %{filter: %{"and" => [scope, labels, open_or_recent]}, after: nil}, _caller}
      assert query =~ "SymphonyInitiatives"
      assert scope == %{"team" => %{"key" => %{"eq" => "billing"}}}
      assert labels == %{"or" => [plan_label("plan"), plan_label("breakdown")]}
      assert %{"or" => [_open, %{"completedAt" => %{"gte" => "2026-10-05T12:00:00Z"}}]} = open_or_recent
      assert_received {:query, _query, %{after: "c1"}, _caller}

      # The second route lists the same tickets: each is kept once.
      assert [%{identifier: "BIL-1", repo_key: "billing"}] = Initiatives.cached(name)
      assert Initiatives.read?(name)

      # A second read with the same answer leaves the cache as it is.
      Initiatives.run_once(state)
      assert [%{identifier: "BIL-1"}] = Initiatives.cached(name)
    end

    test "warns about a plan read incomplete" do
      truncated = plan("BIL-1", @in_progress, [], %{"children" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}})
      state = server_state(linear(self(), %{nil => page([truncated])}))

      log = capture_log(fn -> Initiatives.run_once(state) end)
      assert log =~ "Initiatives: BIL-1 has more sub-tickets or blockers than one read returns"
      assert [%{incomplete: true}] = Initiatives.cached(Keyword.fetch!(state.opts, :name))
    end

    defp plan_label(name), do: %{"labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => name}}}}

    test "keeps the last list when Linear fails" do
      name = {:test, make_ref()}
      ok = server_state(linear(self(), %{nil => page([plan("BIL-1", @in_progress, [])])}), name: name)
      Initiatives.run_once(ok)

      for failing <- [
            fn _query, _variables, _opts -> {:ok, %{"errors" => [%{"message" => "boom"}]}} end,
            fn _query, _variables, _opts -> {:ok, %{"data" => nil}} end,
            fn _query, _variables, _opts -> {:error, :timeout} end
          ] do
        log = capture_log(fn -> Initiatives.run_once(server_state(failing, name: name)) end)
        assert log =~ "Initiatives: could not read the plan tickets from Linear"
        assert [%{identifier: "BIL-1"}] = Initiatives.cached(name)
      end

      no_scope = server_state(nil, name: name, scope_filter: fn _repo -> {:error, :no_scope} end)
      log = capture_log(fn -> Initiatives.run_once(no_scope) end)
      assert log =~ ":no_scope"
    end

    test "ticks on its interval, tagged as the initiatives caller" do
      test_pid = self()
      name = Module.concat(__MODULE__, :Ticking)

      {:ok, pid} =
        Initiatives.start_link(
          name: name,
          initial_delay_ms: 0,
          interval_ms: 60_000,
          repos: fn -> {:ok, [@repo]} end,
          settings_fun: fn _repo -> settings() end,
          scope_filter: fn _repo -> {:ok, %{}} end,
          linear_client: linear(test_pid, %{nil => page([])})
        )

      assert_receive {:query, _query, _variables, :initiatives}
      GenServer.stop(pid)
    end

    test "lists the cached initiatives with what runs and what waits on the Director" do
      name = {:test, make_ref()}
      node = plan("BIL-1", @in_progress, [child("BIL-2", @todo), child("BIL-3", @todo)])
      Initiatives.run_once(server_state(linear(self(), %{nil => page([node])}), name: name))

      snapshot = %{running: [%{issue_id: "id-BIL-2"}]}

      assert [%{counts: %{"working" => 1, "queued" => 1}}] = Initiatives.list(snapshot, name, {:test, make_ref()}, fn "billing" -> settings() end)
      assert [%{counts: %{"working" => 0}}] = Initiatives.list(%{}, name, {:test, make_ref()})
      assert Initiatives.list(%{}, {:test, make_ref()}) == []
      assert Initiatives.read?(Module.concat(__MODULE__, :NotStarted))
    end
  end
end
