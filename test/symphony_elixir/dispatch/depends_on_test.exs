defmodule SymphonyElixir.Dispatch.DependsOnTest do
  # TP-1625: a ticket's dependencies are stored by Symphony on its record, apart from the blockers a
  # read of Linear fills. The engine adds and removes them; a dependency points upward in the queue;
  # dispatch holds a ticket on an unmet one, decided from the stored records alone, and lets it start
  # by itself once it is met.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.{DependsOn, Order}
  alias SymphonyElixir.{Home, Situation, TicketObservation, TicketPullRequest, TicketState, UpdateHold}

  @repo "default"
  @active_states ["Todo", "In Progress", "Code Review", "QA", "Merging", "Rework"]
  @old_build "d3d301b0123456789abcdef0123456789abcdef0"
  @new_build "53b1e370123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @fix_pr "https://github.com/acme/symphony/pull/77"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: @active_states, tracker_terminal_states: ["Done", "Canceled"])
    previous = Application.fetch_env(:symphony_elixir, :build)
    :ok = RunStore.clear()
    :ok = RunStore.place_queue()
    :ok = RunStore.key_queue()

    on_exit(fn ->
      RunStore.clear()

      case previous do
        {:ok, value} -> Application.put_env(:symphony_elixir, :build, value)
        :error -> Application.delete_env(:symphony_elixir, :build)
      end
    end)

    :ok
  end

  describe "the stored dependency" do
    test "is a field of its own, apart from the blockers, and no read of Linear or write of the record changes it" do
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Todo")

      assert :ok = RunStore.add_dependency("b", "a", :done)
      assert %{depends_on: [%{issue_id: "a", identifier: "MT-1", kind: :done}], blockers: []} = record("b")

      # A read of Linear rewrites the record (its phase, its blockers) and leaves the dependency.
      issue = %Issue{
        id: "b",
        identifier: "MT-2",
        title: "Depends",
        state: "In Progress",
        blocked_by: [%{id: "z", identifier: "MT-9", state: "Todo"}],
        updated_at: DateTime.utc_now()
      }

      assert {:ok, _outcome} = TicketObservation.observe(@repo, issue)
      assert %{phase: "In Progress", depends_on: [%{issue_id: "a", kind: :done}]} = record("b")

      # A caller writing back a record it read before, or naming the field, changes nothing of it.
      :ok = RunStore.put_ticket_state(%{record("b") | depends_on: []})
      :ok = RunStore.update_ticket_state("b", %{depends_on: [], title: "Renamed"})
      assert %{title: "Renamed", depends_on: [%{issue_id: "a", kind: :done}]} = record("b")

      # A new record holds none, whatever it is written with.
      :ok = RunStore.put_ticket_state(TicketState.new(@repo, "c", %{issue_identifier: "MT-3", phase: "Todo", depends_on: [%{issue_id: "a", kind: :done}]}))
      assert record("c").depends_on == []
    end

    test "is added and removed between any two tickets, also two sub-tickets of one parent" do
      put!("top", "MT-T", "Todo")
      put!("epic", "MT-E", "In Progress")
      put!("s1", "MT-S1", "Done", "MT-E")
      put!("s2", "MT-S2", "Todo", "MT-E")
      put!("s3", "MT-S3", "Todo", "MT-E")

      assert :ok = RunStore.add_dependency("s3", "s2", :done)
      assert :ok = RunStore.add_dependency("s3", "s1", :released)
      assert :ok = RunStore.add_dependency("s2", "top", :done)
      # A ticket Symphony holds no record of: stored, without an identifier.
      assert :ok = RunStore.add_dependency("s2", "ghost", :done)

      assert [%{issue_id: "s2", identifier: "MT-S2", kind: :done}, %{issue_id: "s1", identifier: "MT-S1", kind: :released}] = record("s3").depends_on
      assert [%{issue_id: "top", kind: :done}, %{issue_id: "ghost", identifier: nil}] = record("s2").depends_on

      # The same pair again replaces its kind, in its place.
      assert :ok = RunStore.add_dependency("s3", "s2", :released)
      assert [%{issue_id: "s2", kind: :released}, %{issue_id: "s1"}] = record("s3").depends_on

      assert :ok = RunStore.remove_dependency("s3", "s2")
      assert [%{issue_id: "s1"}] = record("s3").depends_on
      # Removing one that is not stored is fine.
      assert :ok = RunStore.remove_dependency("s3", "s2")
      assert [%{issue_id: "s1"}] = record("s3").depends_on

      # The read the gate decides from: each dependency with the record of the ticket depended on.
      assert [{%{issue_id: "top"}, %{issue_identifier: "MT-T"}}, {%{issue_id: "ghost"}, nil}] = RunStore.dependencies("s2")
      assert RunStore.dependencies("missing") == []
      assert RunStore.dependencies(nil) == []

      assert {:error, :ticket_state_not_found} = RunStore.add_dependency("missing", "s1", :done)
      assert {:error, :ticket_state_not_found} = RunStore.remove_dependency("missing", "s1")
      assert {:error, :self_dependency} = RunStore.add_dependency("s2", "s2", :done)
    end

    test "a dependency that would close a cycle is refused, directly or through others" do
      for {id, n} <- [{"a", 1}, {"b", 2}, {"c", 3}], do: put!(id, "MT-#{n}", "Todo")

      assert :ok = RunStore.add_dependency("b", "a", :done)
      assert {:error, :dependency_cycle} = RunStore.add_dependency("a", "b", :done)

      assert :ok = RunStore.add_dependency("c", "b", :done)
      assert :ok = RunStore.add_dependency("c", "a", :done)
      assert {:error, :dependency_cycle} = RunStore.add_dependency("a", "c", :released)
      assert record("a").depends_on == []
    end
  end

  describe "a dependency points upward in the queue" do
    test "on a ticket that sits lower, the depending ticket moves to just below it; on one above, no place changes" do
      for {id, n} <- [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}], do: put!(id, "MT-#{n}", "Todo")
      assert walk() == ["a", "b", "c", "d"]

      assert :ok = RunStore.add_dependency("a", "c", :done)
      assert walk() == ["b", "c", "a", "d"]

      before = places()
      assert :ok = RunStore.add_dependency("d", "b", :released)
      assert places() == before
    end

    test "between scopes the move applies where they meet, and a sub-ticket moves among its siblings" do
      put!("epic", "MT-E", "In Progress")
      put!("s1", "MT-S1", "Todo", "MT-E")
      put!("s2", "MT-S2", "Todo", "MT-E")
      put!("x", "MT-X", "Todo")
      put!("y", "MT-Y", "Todo")
      put!("done", "MT-D", "Done")
      assert walk() == ["epic", "s1", "s2", "x", "y"]

      # A sub-ticket on a top-level ticket below its epic: the epic moves below it, with its sub-tickets.
      assert :ok = RunStore.add_dependency("s1", "x", :done)
      assert walk() == ["x", "epic", "s1", "s2", "y"]

      # Two sub-tickets of one parent.
      assert :ok = RunStore.add_dependency("s1", "s2", :done)
      assert walk() == ["x", "epic", "s2", "s1", "y"]

      before = places()
      # On its own parent, or a parent on its sub-ticket: a parent always sits above its sub-tickets.
      assert :ok = RunStore.add_dependency("s2", "epic", :done)
      assert :ok = RunStore.add_dependency("epic", "s1", :done)
      # On a ticket out of the queue, or one Symphony holds no record of.
      assert :ok = RunStore.add_dependency("y", "done", :done)
      assert :ok = RunStore.add_dependency("x", "ghost", :done)
      assert places() == before
    end
  end

  describe "dispatch" do
    test "holds a ticket on an unmet done dependency, and starts it by itself once it is met, from the stored records alone" do
      put!("epic", "MT-E", "In Progress")
      put!("s1", "MT-S1", "Done", "MT-E")
      put!("s2", "MT-S2", "Todo", "MT-E")
      put!("s3", "MT-S3", "Todo", "MT-E")
      :ok = RunStore.add_dependency("s2", "s1", :done)
      :ok = RunStore.add_dependency("s3", "s2", :done)

      # Linear holds no blocker links between them: the issues read clear of any.
      s2 = issue("s2", "MT-S2")
      s3 = issue("s3", "MT-S3")
      state = orchestrator_state()

      assert Orchestrator.should_dispatch_issue_for_test(s2, state)
      refute Orchestrator.should_dispatch_issue_for_test(s3, state)
      assert %{reason: "waiting for MT-S2 to be done", gate: :depends_on, rule: nil} = skipped(s3, state)
      assert [%{identifier: "MT-S3", outcome: :held, reason: "waiting for MT-S2 to be done"}] = Orchestrator.put_dispatch_order_for_test(state, [s3]).dispatch_order.entries |> held()

      # Cancelled is not done.
      :ok = RunStore.update_ticket_state("s2", %{phase: "Canceled"})
      refute Orchestrator.should_dispatch_issue_for_test(s3, state)

      # The ticket depended on is Done: the next pass finds the gate open, with no one's action.
      :ok = RunStore.update_ticket_state("s2", %{phase: "Done"})
      assert Orchestrator.should_dispatch_issue_for_test(s3, state)

      # A ticket Symphony holds no record of never meets a dependency; removed, it holds nothing.
      :ok = RunStore.add_dependency("s3", "ghost", :done)
      assert %{reason: "waiting for ticket ghost to be done", gate: :depends_on} = skipped(s3, state)
      :ok = RunStore.remove_dependency("s3", "ghost")
      assert Orchestrator.should_dispatch_issue_for_test(s3, state)
    end

    test "holds a ticket on a released dependency until the running build includes the other ticket's merge" do
      run_build(@old_build)
      put!("fix", "MT-F", "In Progress")
      put!("next", "MT-N", "Todo")
      :ok = RunStore.add_dependency("next", "fix", :released)
      next = issue("next", "MT-N")

      # Not done yet: held, and nothing is looked up.
      cache = resolve(:no_lookup)
      refute Orchestrator.should_dispatch_issue_for_test(next, orchestrator_state(cache))

      # Done, merged, and the build lacks the merge commit: still held.
      :ok = RunStore.update_ticket_state("fix", %{phase: "Done"})
      merged!("fix", @fix_pr)
      held = orchestrator_state(resolve(:merged))
      refute Orchestrator.should_dispatch_issue_for_test(next, held)
      assert %{reason: "waiting for a Symphony update that includes MT-F", gate: :depends_on} = skipped(next, held)
      # The same build again: the cache answers, nothing is looked up.
      assert DependsOn.resolve(RunStore.list_all_ticket_states(), SymphonyElixir.BuildInfo.current(), held.update_hold_cache, lookups(:no_lookup)) == held.update_hold_cache

      # The app updates to a build that includes it: the next pass lets the ticket start.
      run_build(@new_build)
      assert Orchestrator.should_dispatch_issue_for_test(next, orchestrator_state(resolve(:merged)))

      # A lookup that has not answered holds the ticket until one does.
      refute Orchestrator.should_dispatch_issue_for_test(next, orchestrator_state(resolve(:lookup_down)))

      # A build from a checkout releases it at Done.
      Application.put_env(:symphony_elixir, :build, sha: nil, repo: nil, number: nil)
      assert Orchestrator.should_dispatch_issue_for_test(next, orchestrator_state())
    end

    test "a released dependency merged in another repository, or opted out, is met at Done" do
      run_build(@old_build)
      put!("web", "MT-W", "Done")
      put!("skip", "MT-K", "Done")
      put!("next", "MT-N", "Todo")
      :ok = RunStore.add_dependency("next", "web", :released)
      :ok = RunStore.add_dependency("next", "skip", :released)
      :ok = RunStore.update_ticket_state("skip", %{labels: [UpdateHold.skip_label()]})
      merged!("web", "https://github.com/acme/web-app/pull/5")

      cache = DependsOn.resolve(RunStore.list_all_ticket_states(), SymphonyElixir.BuildInfo.current(), UpdateHold.empty_cache(), lookups(:no_lookup))
      assert cache.blockers == %{"web" => :none, "skip" => :skip}
      assert Orchestrator.should_dispatch_issue_for_test(issue("next", "MT-N"), orchestrator_state(cache))

      # Records that could not be read look nothing up.
      assert DependsOn.resolve({:error, :aborted}, SymphonyElixir.BuildInfo.current(), cache) == cache
    end

    test "the Linear blocker hold still holds and releases as before, and the stored dependency holds on its own" do
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Todo")
      state = orchestrator_state()

      blocked = %Issue{issue("b", "MT-2") | blocked_by: [%{id: "id-MT-9", identifier: "MT-9", state: "In Progress"}]}
      assert sweep(blocked) == 1
      refute Orchestrator.should_dispatch_issue_for_test(blocked, state)

      # A stored dependency, met, changes nothing of the Linear hold.
      :ok = RunStore.add_dependency("b", "a", :done)
      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      refute Orchestrator.should_dispatch_issue_for_test(blocked, state)

      released = %Issue{blocked | blocked_by: [%{id: "id-MT-9", identifier: "MT-9", state: "Done"}]}
      assert sweep(released) == 1
      assert Orchestrator.should_dispatch_issue_for_test(released, state)

      # Unmet, it holds the ticket Linear releases.
      :ok = RunStore.update_ticket_state("a", %{phase: "Todo"})
      refute Orchestrator.should_dispatch_issue_for_test(released, state)
    end

    test "the dispatch order and Home answer as before with dependencies stored" do
      Application.put_env(:symphony_elixir, :build, sha: nil, repo: nil, number: nil)
      put!("done", "MT-D", "Done")
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Todo")
      issues = [issue("a", "MT-1"), issue("b", "MT-2")]
      live = Situation.live_facts(%{running: [], retrying: []})

      computed_at = DateTime.utc_now()

      reads = fn ->
        %{dispatch_order: order} = Orchestrator.put_dispatch_order_for_test(orchestrator_state(), issues)
        order = %{order | computed_at: computed_at}
        records = RunStore.list_all_ticket_states()
        {order, Order.read(order, records, live), Home.read(order, records, live)}
      end

      before = reads.()
      # Met dependencies, on a Done ticket and with a build from a checkout.
      :ok = RunStore.add_dependency("b", "done", :done)
      :ok = RunStore.add_dependency("a", "done", :released)
      assert reads.() == before
    end
  end

  describe "unmet/4 and reason/1" do
    test "decide from the records and the update hold's cache alone" do
      done = %{issue_id: "d", identifier: "MT-D", kind: :done}
      released = %{issue_id: "r", identifier: "MT-R", kind: :released}
      build = %{sha: @new_build, repo: "https://github.com/acme/symphony"}
      records = %{"d" => %{phase: " done "}, "r" => %{phase: "Done"}}
      included = %{blockers: %{"r" => {:merged, @fix_pr, @merge_sha}}, included: %{{@merge_sha, @new_build} => true}}

      assert DependsOn.unmet([done, released], records, build, included) == []
      assert DependsOn.unmet([done, released], records, build, %{included | included: %{{@merge_sha, @new_build} => false}}) == [released]
      assert DependsOn.unmet([released], records, build, UpdateHold.empty_cache()) == [released]
      assert DependsOn.unmet([done, released], %{"d" => %{phase: "Todo"}, "r" => %{phase: nil}}, %{sha: nil, repo: nil}, included) == [done, released]

      assert DependsOn.reason([done, released, %{issue_id: "x", identifier: nil, kind: :done}]) ==
               "waiting for MT-D to be done; waiting for a Symphony update that includes MT-R; waiting for ticket x to be done"
    end
  end

  defp put!(issue_id, identifier, phase, parent \\ nil) do
    attrs = %{issue_identifier: identifier, title: "Ticket #{identifier}", phase: phase, parent: parent && %{identifier: parent}}
    :ok = RunStore.put_ticket_state(TicketState.new(@repo, issue_id, attrs))
  end

  defp record(issue_id), do: RunStore.get_ticket_state(issue_id)

  defp places, do: RunStore.queue_places()
  defp walk, do: places() |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  defp issue(id, identifier) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: "Todo", priority: 1, labels: [], repo_key: @repo, blocked_by: []}
  end

  defp held(tickets), do: Enum.filter(tickets, &(&1.outcome == :held))

  defp skipped(issue, state), do: Orchestrator.dispatch_chosen_issues_for_test([issue], state).dispatch_skipped[issue.id]

  defp sweep(issue), do: Orchestrator.sweep_dependencies_for_test(@repo, [issue], ["Done", "Canceled"])

  defp run_build(sha), do: Application.put_env(:symphony_elixir, :build, sha: sha, repo: "https://github.com/acme/symphony", number: "168")

  # A Done ticket whose PR Symphony's record shows merged.
  defp merged!(issue_id, pr_url) do
    :ok = TicketPullRequest.record_created(@repo, issue_id, pr_url, nil)
    :ok = TicketPullRequest.mark_finished(@repo, pr_url, "merged")
  end

  # What the poll task looks up into the update hold's cache for the stored released dependencies.
  defp resolve(lookup) do
    DependsOn.resolve(RunStore.list_all_ticket_states(), SymphonyElixir.BuildInfo.current(), UpdateHold.empty_cache(), lookups(lookup))
  end

  defp lookups(:no_lookup) do
    [merge_commit_sha: fn _url -> flunk("nothing to look up") end, commit_included?: fn _url, _sha, _build -> flunk("cached") end]
  end

  defp lookups(:merged) do
    [merge_commit_sha: fn @fix_pr -> {:ok, @merge_sha} end, commit_included?: fn @fix_pr, @merge_sha, build_sha -> {:ok, build_sha == @new_build} end]
  end

  defp lookups(:lookup_down), do: [merge_commit_sha: fn _url -> {:error, :github_down} end]

  defp orchestrator_state(cache \\ UpdateHold.empty_cache()) do
    %Orchestrator.State{
      repo_key: @repo,
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      update_hold_cache: cache
    }
  end
end
