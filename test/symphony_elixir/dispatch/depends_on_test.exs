defmodule SymphonyElixir.Dispatch.DependsOnTest do
  # TP-1625: a ticket's dependencies are stored by Symphony on its record; no read of Linear fills
  # them (TP-1628: Linear's blocker links are not read at all). The engine adds and removes them; a
  # dependency points upward in the queue; dispatch holds a ticket on an unmet one, decided from the
  # stored records alone, and lets it start by itself once it is met.
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dispatch.{DependsOn, Order}
  alias SymphonyElixir.{Home, Pauses, Situation, TicketObservation, TicketPullRequest, TicketState, UpdateHold}

  @repo "default"
  @active_states ["Todo", "In Progress", "Code Review", "QA", "Merging", "Rework"]
  @old_build "d3d301b0123456789abcdef0123456789abcdef0"
  @new_build "53b1e370123456789abcdef0123456789abcdef0"
  @merge_sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @fix_pr "https://github.com/acme/symphony/pull/77"

  setup do
    terminal = ["Done", "Canceled"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: @active_states,
      tracker_terminal_states: terminal
    )

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
    test "is a field of its own, and no read of Linear or write of the record changes it" do
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Todo")

      assert :ok = RunStore.add_dependency("b", "a", :done)
      assert %{depends_on: [%{issue_id: "a", identifier: "MT-1", kind: :done}]} = record("b")
      refute Map.has_key?(record("b"), :blockers)

      # A read of Linear rewrites the record (its phase) and leaves the dependency.
      issue = %Issue{
        id: "b",
        identifier: "MT-2",
        title: "Depends",
        state: "In Progress",
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

      assert [%{issue_id: "s2", identifier: "MT-S2", kind: :done}, %{issue_id: "s1", identifier: "MT-S1", kind: :released}] =
               record("s3").depends_on

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
      # (s1 already depends on s2: keeping s2 on the epic would close a cycle.)
      assert :ok = RunStore.remove_dependency("s2", "epic")
      assert :ok = RunStore.add_dependency("epic", "s1", :done)
      # On a ticket out of the queue, or one Symphony holds no record of.
      assert :ok = RunStore.add_dependency("y", "done", :done)
      assert :ok = RunStore.add_dependency("x", "ghost", :done)
      assert places() == before
    end
  end

  describe "TP-1633: a queue move never puts a ticket above one it depends on" do
    test "a move above the ticket depended on, or of that ticket below its dependent, is refused and nothing moves" do
      for {id, n} <- [{"a", 1}, {"b", 2}, {"c", 3}], do: put!(id, "MT-#{n}", "Todo")
      assert :ok = RunStore.add_dependency("b", "a", :done)
      before = places()

      assert {:error, {:dependency_order, "b", "a"}} = RunStore.move_in_queue("b", :top)
      assert {:error, {:dependency_order, "b", "a"}} = RunStore.move_in_queue("a", :end)
      assert {:error, {:dependency_order, "b", "a"}} = RunStore.move_in_queue("a", {:between, "b", "c"})
      assert places() == before

      # Moves that keep it pointing upward go through.
      assert :ok = RunStore.move_in_queue("c", :top)
      assert :ok = RunStore.move_in_queue("b", :end)
      assert walk() == ["c", "a", "b"]
    end

    test "between two sub-tickets of one parent, and between scopes where they meet" do
      put!("epic", "MT-E", "In Progress")
      put!("s1", "MT-S1", "Todo", "MT-E")
      put!("s2", "MT-S2", "Todo", "MT-E")
      put!("x", "MT-X", "Todo")
      assert :ok = RunStore.add_dependency("s2", "s1", :released)
      before = places()

      assert {:error, {:dependency_order, "s2", "s1"}} = RunStore.move_in_queue("s2", :top)
      assert places() == before

      # A sub-ticket that depends on a top-level ticket keeps its parent below it.
      assert :ok = RunStore.add_dependency("s1", "x", :done)
      assert walk() == ["x", "epic", "s1", "s2"]
      assert {:error, {:dependency_order, "s1", "x"}} = RunStore.move_in_queue("epic", :top)
      assert walk() == ["x", "epic", "s1", "s2"]
    end
  end

  describe "TP-1633: start_refusal/4, dependents/3 and cancel_refusal/2" do
    test "a Start is refused with the first unmet dependency, done or released, as the gate judges it" do
      run_build(@old_build)
      put!("fix", "MT-F", "In Progress")
      put!("rel", "MT-R", "Done")
      put!("next", "MT-N", "Todo")
      :ok = RunStore.add_dependency("next", "fix", :done)
      :ok = RunStore.add_dependency("next", "rel", :released)
      build = SymphonyElixir.BuildInfo.current()

      assert DependsOn.start_refusal("MT-N", "next", build, UpdateHold.empty_cache()) == "MT-N depends on MT-F and can't start before it is done."

      :ok = RunStore.update_ticket_state("fix", %{phase: "Done"})
      assert DependsOn.start_refusal("MT-N", "next", build, UpdateHold.empty_cache()) == "MT-N depends on MT-R and can't start before it is released."
      # With no build, a released dependency is met once its ticket is done.
      assert DependsOn.start_refusal("MT-N", "next", %{}, UpdateHold.empty_cache()) == nil
      # A ticket with no identifier is named by its id, and so is one depended on that has no record.
      :ok = RunStore.add_dependency("fix", "ghost", :done)
      assert DependsOn.start_refusal(nil, "fix", build, UpdateHold.empty_cache()) == "fix depends on ticket ghost and can't start before it is done."

      assert DependsOn.start_refusal("MT-F", "missing", build, UpdateHold.empty_cache()) == nil
      assert DependsOn.start_refusal("MT-F", nil, build, UpdateHold.empty_cache()) == nil
    end

    test "the open tickets that depend on a ticket refuse its cancel, named in order" do
      put!("base", "MT-1", "Todo")
      put!("b", "MT-3", "Todo")
      put!("a", "MT-2", "In Progress")
      put!("done", "MT-4", "Todo")
      put!("gone", "MT-5", "Todo")
      for id <- ["a", "b", "done", "gone"], do: :ok = RunStore.add_dependency(id, "base", :done)
      :ok = RunStore.update_ticket_state("done", %{phase: "Done"})
      :ok = RunStore.update_ticket_state("gone", %{removed_at: DateTime.utc_now()})
      terminal = MapSet.new(["done", "canceled"])

      dependents = DependsOn.dependents("base", RunStore.list_all_ticket_states(), terminal)
      assert dependents == ["MT-2", "MT-3"]
      assert DependsOn.dependents("a", RunStore.list_all_ticket_states(), terminal) == []

      assert DependsOn.cancel_refusal("MT-1", dependents) == "MT-1 can't be cancelled: MT-2 and MT-3 depend on it. Remove those dependencies first."
      assert DependsOn.cancel_refusal("MT-1", ["MT-2"]) == "MT-1 can't be cancelled: MT-2 depends on it. Remove that dependency first."
      assert DependsOn.cancel_refusal("MT-1", ["MT-2", "MT-3", "MT-4"]) == "MT-1 can't be cancelled: MT-2, MT-3 and MT-4 depend on it. Remove those dependencies first."
      assert DependsOn.cancel_refusal("MT-1", []) == nil
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
      entries = Orchestrator.put_dispatch_order_for_test(state, [s3]).dispatch_order.entries
      assert [%{identifier: "MT-S3", outcome: :held, reason: "waiting for MT-S2 to be done"}] = held(entries)

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
      records = RunStore.list_all_ticket_states()
      build = SymphonyElixir.BuildInfo.current()
      assert DependsOn.resolve(records, build, held.update_hold_cache, lookups(:no_lookup)) == held.update_hold_cache

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

      records = RunStore.list_all_ticket_states()
      build = SymphonyElixir.BuildInfo.current()
      cache = DependsOn.resolve(records, build, UpdateHold.empty_cache(), lookups(:no_lookup))
      assert cache.blockers == %{"web" => :none, "skip" => :skip}
      assert Orchestrator.should_dispatch_issue_for_test(issue("next", "MT-N"), orchestrator_state(cache))

      # Records that could not be read look nothing up.
      assert DependsOn.resolve({:error, :aborted}, SymphonyElixir.BuildInfo.current(), cache) == cache
    end

    test "the stored dependency alone holds and releases the ticket, and the poll's sweep sets no pause for it" do
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Todo")
      state = orchestrator_state()
      b = issue("b", "MT-2")

      :ok = RunStore.add_dependency("b", "a", :done)
      assert sweep(b) == 0
      assert Pauses.get({:ticket, @repo, "b"}) == {:ok, nil}
      refute Orchestrator.should_dispatch_issue_for_test(b, state)

      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      assert sweep(b) == 0
      assert Orchestrator.should_dispatch_issue_for_test(b, state)
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

  describe "open/2, open_for/1 and open_identifiers/1" do
    test "a done ticket meets either kind whatever the build holds; an open or unknown ticket meets neither" do
      run_build(@old_build)
      done = %{issue_id: "d", identifier: "MT-D", kind: :done}
      released = %{issue_id: "r", identifier: "MT-R", kind: :released}
      open = %{issue_id: "o", identifier: "MT-O", kind: :done}
      ghost = %{issue_id: "g", identifier: nil, kind: :released}
      records = %{"d" => %{phase: "Done"}, "r" => %{phase: " done "}, "o" => %{phase: "In Progress"}}

      # A released dependency whose ticket is done is no longer open, even with no lookup in the cache.
      assert DependsOn.open([done, released, open, ghost], records) == [open, ghost]
      assert DependsOn.open([], records) == []
    end

    test "read the ticket's stored dependencies from the store and name the open ones once" do
      put!("a", "MT-1", "Todo")
      put!("b", "MT-2", "Done")
      put!("c", "MT-3", "In Progress")
      put!("x", "MT-X", "Todo")
      :ok = RunStore.add_dependency("x", "a", :done)
      :ok = RunStore.add_dependency("x", "b", :released)
      :ok = RunStore.add_dependency("x", "ghost", :done)
      # Stored before its ticket had a record: the entry has no identifier, the record names it.
      :ok = RunStore.add_dependency("x", "later", :done)
      put!("later", "MT-L", "Todo")

      assert [
               {%{issue_id: "a", identifier: "MT-1"}, %{issue_identifier: "MT-1"}},
               {%{issue_id: "ghost", identifier: nil}, nil},
               {%{issue_id: "later", identifier: nil}, %{issue_identifier: "MT-L"}}
             ] = DependsOn.open_for("x")

      # A ticket Symphony holds no record of has no name to show.
      assert DependsOn.open_identifiers("x") == ["MT-1", "MT-L"]

      assert DependsOn.open_for("c") == []
      assert DependsOn.open_for("missing") == []
      assert DependsOn.open_for(nil) == []
      assert DependsOn.open_identifiers(nil) == []

      :ok = RunStore.update_ticket_state("a", %{phase: "Done"})
      :ok = RunStore.remove_dependency("x", "ghost")
      :ok = RunStore.remove_dependency("x", "later")
      assert DependsOn.open_identifiers("x") == []
    end
  end

  describe "a done dependency on a merged ticket" do
    test "is met by a ticket its merge put in the waiting state, as the blocker hold counts it, so a sub-ticket never deadlocks with its parent" do
      SymphonyElixir.SubIssueWait.reset_for_test("Waiting on sub-tickets")
      done = %{issue_id: "p", identifier: "MT-P", kind: :done}
      records = %{"p" => %{phase: "Waiting on sub-tickets"}}

      # A parent a person moved there waits for them: not merged.
      assert DependsOn.unmet([done], records, %{sha: nil, repo: nil}, UpdateHold.empty_cache()) == [done]

      :ok = RunStore.put_merged_wait("p")
      assert DependsOn.unmet([done], records, %{sha: nil, repo: nil}, UpdateHold.empty_cache()) == []
      # A released dependency still waits for Done.
      assert DependsOn.unmet([%{done | kind: :released}], records, %{sha: nil, repo: nil}, UpdateHold.empty_cache()) == [%{done | kind: :released}]
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
    title = "Ticket #{identifier}"

    %Issue{
      id: id,
      identifier: identifier,
      title: title,
      state: "Todo",
      priority: 1,
      labels: [],
      repo_key: @repo
    }
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
    records = RunStore.list_all_ticket_states()
    DependsOn.resolve(records, SymphonyElixir.BuildInfo.current(), UpdateHold.empty_cache(), lookups(lookup))
  end

  defp lookups(:no_lookup) do
    [merge_commit_sha: fn _url -> flunk("nothing to look up") end, commit_included?: fn _url, _sha, _build -> flunk("cached") end]
  end

  defp lookups(:merged) do
    [
      merge_commit_sha: fn @fix_pr -> {:ok, @merge_sha} end,
      commit_included?: fn @fix_pr, @merge_sha, build_sha -> {:ok, build_sha == @new_build} end
    ]
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
