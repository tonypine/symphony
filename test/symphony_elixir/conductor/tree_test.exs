defmodule SymphonyElixir.Conductor.TreeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, Questions, SubIssueWait, TicketEvents, TicketPlan}
  alias SymphonyElixir.Conductor.{Facts, Filing, Grooming, Tree}
  alias SymphonyElixir.Config.{Cache, Schema}
  alias SymphonyElixir.Dispatch.DependsOn
  alias SymphonyElixir.TicketPullRequest
  alias SymphonyElixir.TicketSignals
  alias SymphonyElixir.TicketState
  alias SymphonyElixir.Tracker.Memory

  @waiting "Waiting on sub-tickets"

  # The memory tracker, but for the calls a test scripts: `:pass` lets one through, anything else
  # is that call's answer.
  defmodule Scripted do
    @moduledoc false
    for {name, arity} <- [fetch_issue_states_by_ids: 1, create_issue: 1, update_issue_state: 2] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        case Process.get({:scripted, unquote(name)}, []) do
          [reply | rest] when reply != :pass ->
            Process.put({:scripted, unquote(name)}, rest)
            reply

          script ->
            Process.put({:scripted, unquote(name)}, Enum.drop(script, 1))
            apply(Memory, unquote(name), unquote(args))
        end
      end
    end
  end

  defmodule NoWaitingState do
    @moduledoc false
    def workflow_state_exists?(_state, _teams), do: {:ok, false}
  end

  setup do
    SubIssueWait.reset_for_test(@waiting)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    n = System.unique_integer([:positive])
    record = %{repo_key: "default", issue_id: "tree-#{n}", issue_identifier: "TREE-#{n}", phase: "Todo", title: "Filters"}
    :ok = RunStore.put_ticket_state(record)

    issue = %Issue{
      id: record.issue_id,
      identifier: record.issue_identifier,
      title: "Filters",
      state: "Todo",
      repo_key: "default",
      team: %{key: "MT", name: "Team"},
      project: %{id: "p1", name: "App"},
      assignee_id: "user-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_create_issue_result)
    end)

    %{issue: issue, issue_id: issue.id}
  end

  defp script(call, replies), do: Process.put({:scripted, call}, replies)

  defp append_symphony_yml!(yaml) do
    path = Workflow.symphony_file_path()
    File.write!(path, File.read!(path) <> yaml)
    Cache.clear()
  end

  defp plan(sub_tickets) do
    %{
      shape: "split",
      layers: ["api", "screen"],
      summary: "The API, then the list.",
      text: "Approach: the API first.",
      checks: [%{id: "c1", kind: "outcome", statement: "The list is filtered.", proof: "test"}],
      size: %{tokens: 1, runs: 2},
      sub_tickets: sub_tickets
    }
  end

  defp two do
    [%{key: "s1", title: "The API filter", ask: "Add the filter to the API.", after: []}, %{key: "s2", title: "The list", ask: "Read it in the list.", after: ["s1"]}]
  end

  defp write!(ctx, sub_tickets \\ two()) do
    {:ok, _event} = Grooming.write_plan("default", ctx.issue, plan(sub_tickets))
    :ok
  end

  defp mailbox(acc \\ []) do
    receive do
      message -> mailbox([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp events(issue_id, type), do: issue_id |> Facts.events() |> Enum.filter(&(&1.type == type))

  # The ticket's stored dependencies, as its record holds them.
  defp depends_on(issue_id), do: issue_id |> RunStore.get_ticket_state() |> TicketState.normalize() |> Map.get(:depends_on)

  defp status_notes(issue_id), do: for(%{type: "note", payload: %{status: true, text: text}} <- Facts.events(issue_id), do: text)

  describe "split/3" do
    test "creates each sub-ticket, gives the one that waits its dependency and starts it, then parks the parent", ctx do
      write!(ctx)

      assert Grooming.split("default", ctx.issue) == :ok

      created = %{title: "The API filter", description: "Add the filter to the API.", priority: 1, state: "Todo", team: "MT", project: "p1"}
      first = Map.merge(created, %{assignee_id: "user-1", parent_id: ctx.issue_id})
      second = %{first | title: "The list", description: "Read it in the list.", state: "Backlog"}

      # The sub-tickets exist, the second depending on the first and started, before the parent
      # waits on them; no blocker link is written in the tracker.
      assert [
               {:memory_tracker_issue_created, "memory-issue-2", ^first},
               {:memory_tracker_issue_created, "memory-issue-3", ^second},
               {:memory_tracker_state_update, "memory-issue-3", "Todo"},
               {:memory_tracker_state_update, parent_id, @waiting}
             ] = Enum.reject(mailbox(), &(elem(&1, 0) == :memory_tracker_fetch_issue_states_by_ids))

      assert parent_id == ctx.issue_id

      current = TicketPlan.current(ctx.issue_id)
      assert %{version: 2, by: "grooming", reason: "Sub-tickets created", shape: "split"} = current
      assert [%{key: "s1", identifier: "MT-9002"}, %{key: "s2", identifier: "MT-9003", after: ["s1"]}] = current.sub_tickets

      from = ctx.issue.identifier
      assert [%{source: "parent", from: ^from, text: "Add the filter to the API."}] = TicketPlan.ask("memory-issue-2")
      assert [%{source: "parent", text: "Read it in the list."}] = TicketPlan.ask("memory-issue-3")

      # Symphony's records hold the tree at once: the parent lists its sub-tickets, and each names it.
      parent = RunStore.get_ticket_state(ctx.issue_id)
      assert %{phase: @waiting, phase_owner: :symphony} = parent
      assert [%{identifier: "MT-9002"}, %{identifier: "MT-9003"}] = parent.sub_issues
      assert TicketPlan.parent_id("memory-issue-2") == ctx.issue_id
      assert %{repo_key: "default"} = RunStore.get_ticket_state("memory-issue-3")
      assert [%{issue_id: "memory-issue-2", identifier: "MT-9002", kind: :done}] = depends_on("memory-issue-3")
      assert depends_on("memory-issue-2") == []
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "split this ticket into MT-9002, MT-9003"
    end

    test "a split with after stores dependencies on the siblings and holds the sub-ticket until they are done", ctx do
      three = two() ++ [%{key: "s3", title: "The export", ask: "Export the list.", after: ["s1", "s2"]}]
      write!(ctx, three)

      assert Grooming.split("default", ctx.issue) == :ok
      refute Enum.any?(mailbox(), &match?({:memory_tracker_blocked_by_added, _blocker, _issue}, &1))

      assert depends_on("memory-issue-2") == []
      assert [%{issue_id: "memory-issue-2", kind: :done}] = depends_on("memory-issue-3")
      assert [%{issue_id: "memory-issue-2", kind: :done}, %{issue_id: "memory-issue-3", kind: :done}] = depends_on("memory-issue-4")

      unmet = fn issue_id ->
        dependencies = RunStore.dependencies(issue_id)
        records = for {entry, %{} = record} <- dependencies, into: %{}, do: {entry.issue_id, record}
        DependsOn.unmet(Enum.map(dependencies, &elem(&1, 0)), records, %{sha: nil, repo: nil}, %{blockers: %{}, included: %{}})
      end

      # Held while a sibling it follows is not done, and free once both are.
      assert [_s1, _s2] = unmet.("memory-issue-4")
      :ok = RunStore.update_ticket_state("memory-issue-2", %{phase: "Done"})
      assert [%{issue_id: "memory-issue-3"}] = unmet.("memory-issue-4")
      assert unmet.("memory-issue-3") == []
      :ok = RunStore.update_ticket_state("memory-issue-3", %{phase: "Done"})
      assert unmet.("memory-issue-4") == []
    end

    test "a split that stops half way keeps what it created, and the next one creates only the rest", ctx do
      write!(ctx)
      Application.put_env(:symphony_elixir, :memory_tracker_create_issue_result, [:ok, {:error, :linear_down}])

      assert Grooming.split("default", ctx.issue) == {:error, "sub-ticket s2 could not be created: :linear_down"}

      assert [%{identifier: "MT-9002"}, second] = TicketPlan.current(ctx.issue_id).sub_tickets
      refute Map.has_key?(second, :identifier)
      refute Enum.any?(mailbox(), &match?({:memory_tracker_state_update, _id, _state}, &1))
      assert RunStore.get_ticket_state(ctx.issue_id).phase == "Todo"

      assert Grooming.split("default", ctx.issue) == :ok

      assert [{:memory_tracker_issue_created, "memory-issue-3", %{title: "The list"}}] = Enum.filter(mailbox(), &(elem(&1, 0) == :memory_tracker_issue_created))
      assert %{version: 3, sub_tickets: [%{identifier: "MT-9002"}, %{identifier: "MT-9003"}]} = TicketPlan.current(ctx.issue_id)
      assert RunStore.get_ticket_state(ctx.issue_id).phase == @waiting

      # Run again on a parent a person moved back, it creates nothing and stores no dependency twice.
      assert Grooming.split("default", ctx.issue) == :ok
      again = mailbox()
      refute Enum.any?(again, &(elem(&1, 0) in [:memory_tracker_issue_created, :memory_tracker_blocked_by_added]))
      assert [%{issue_id: "memory-issue-2"}] = depends_on("memory-issue-3")
      assert TicketPlan.current(ctx.issue_id).version == 3
    end

    test "a split interrupted before the plan took the identifiers creates no sub-ticket twice", ctx do
      write!(ctx)
      [first, second] = two()

      # The first sub-ticket exists and is on the parent's record; the plan never got its identifier.
      assert {:ok, %{identifier: "MT-9002"}} = Tree.create("default", ctx.issue, first, [])
      assert [%{payload: %{identifier: "MT-9002", kind: "split_off", title: "The API filter", repo: "default"} = filed}] = events(ctx.issue_id, "ticket.filed")
      refute Map.has_key?(filed, :by)

      # The second exists in the tracker only (Symphony stopped before it recorded it), and a person renamed the first.
      by_hand = Map.merge(%{description: second.ask, state: "Backlog", team: "MT", parent_id: ctx.issue_id}, Map.take(second, [:title]))
      {:ok, %{identifier: "MT-9003"}} = Memory.create_issue(by_hand)
      issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
      renamed = Enum.map(issues, &if(&1.identifier == "MT-9002", do: %{&1 | title: "The API filter, renamed"}, else: &1))
      Application.put_env(:symphony_elixir, :memory_tracker_issues, renamed)
      mailbox()

      assert capture_log([level: :info], fn -> assert Grooming.split("default", ctx.issue) == :ok end) =~ "Took the sub-ticket MT-9003 an earlier split left for s2"

      writes = mailbox()
      refute Enum.any?(writes, &(elem(&1, 0) == :memory_tracker_issue_created))
      assert [%{key: "s1", identifier: "MT-9002"}, %{key: "s2", identifier: "MT-9003"}] = TicketPlan.current(ctx.issue_id).sub_tickets
      assert RunStore.get_ticket_state(ctx.issue_id).phase == @waiting
      # The one Symphony never recorded is asked, given its dependency and started as the others are.
      assert [%{source: "parent", text: "Read it in the list."}] = TicketPlan.ask("memory-issue-3")
      assert [%{issue_id: "memory-issue-2", kind: :done}] = depends_on("memory-issue-3")
      assert {:memory_tracker_state_update, "memory-issue-3", "Todo"} in writes
    end

    test "a split that can't read what an earlier one left creates nothing", ctx do
      write!(ctx)
      assert {:ok, _child} = Tree.create("default", ctx.issue, hd(two()), [])
      mailbox()
      script(:fetch_issue_states_by_ids, [:pass, {:error, :timeout}])

      assert Tree.split("default", ctx.issue, tracker: Scripted) == {:error, "the ticket's sub-tickets could not be read: :timeout"}
      refute Enum.any?(mailbox(), &(elem(&1, 0) == :memory_tracker_issue_created))
    end

    test "adopts a sub-ticket the ticket already has, and leaves one a person keeps in Backlog there", ctx do
      existing = %Issue{id: "by-hand", identifier: "MT-50", title: "The API filter", state: "Backlog", parent: %{identifier: ctx.issue.identifier}}
      parent = %{ctx.issue | sub_issues: [%{id: "by-hand", identifier: "MT-50", state: "Backlog"}]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent, existing])
      entries = [%{key: "s1", title: "The API filter", ask: "Add it.", after: [], identifier: "MT-50"}, %{key: "s2", title: "The list", ask: "Read it.", after: []}]

      assert {:error, "its plan was refused: sub-ticket s1 names MT-50, which is not a sub-ticket of this ticket"} =
               Grooming.write_plan("default", ctx.issue, plan(entries))

      assert {:error, "its plan was refused: sub-ticket s1 names MT-50" <> _rest} =
               Grooming.write_plan("default", %Issue{id: "tree-no-record", sub_issues: :unknown}, plan(entries))

      {:ok, _event} = Grooming.write_plan("default", parent, plan(entries))
      assert Grooming.split("default", parent) == :ok

      writes = Enum.filter(mailbox(), &(elem(&1, 0) in [:memory_tracker_issue_created, :memory_tracker_state_update]))
      assert [{:memory_tracker_issue_created, "memory-issue-3", created}, {:memory_tracker_state_update, _parent, @waiting}] = writes
      assert %{title: "The list", state: "Todo"} = created

      assert [%{identifier: "MT-50"}, %{identifier: "MT-9003"}] = TicketPlan.current(ctx.issue_id).sub_tickets
      assert TicketPlan.ask("by-hand") == []
    end

    test "a sub-ticket for another repo goes to that repo's team and project", ctx do
      repo = fn
        "web" -> {:ok, %{name: "web", projects: ["web-project"]}}
        _other -> {:error, :unknown_repo}
      end

      opts = [repo: repo, routed_teams: fn %{name: "web"} -> ["WEB"] end]
      entries = [%{key: "s1", title: "The page", ask: "Show it.", after: [], repo: "web"}]

      assert {:error, "its plan was refused: sub-ticket s1 names the repo \"web\", which Symphony does not manage"} =
               Grooming.write_plan("default", ctx.issue, plan(entries))

      {:ok, _event} = Grooming.write_plan("default", ctx.issue, plan(entries), repo: repo)
      assert Tree.split("default", ctx.issue, opts) == :ok
      assert_received {:memory_tracker_issue_created, "memory-issue-2", %{team: "WEB", project: "web-project", parent_id: _parent}}
      assert %{repo_key: "web"} = RunStore.get_ticket_state("memory-issue-2")
      assert [%{source: "parent"}] = TicketPlan.ask("memory-issue-2")

      assert {:error, "the repo \"web\" has no team Symphony can file in"} =
               Tree.create("default", ctx.issue, hd(entries), Keyword.put(opts, :routed_teams, fn _repo -> [] end))
    end

    test "says what failed, in plain words, and leaves the parent where it is", ctx do
      opts = [tracker: Scripted]
      assert Tree.split("default", ctx.issue, opts) == {:error, "the ticket holds no split plan"}
      assert Tree.split("default", %Issue{id: "tree-no-record"}) == {:error, "the ticket holds no split plan"}
      write!(ctx)

      for {call, replies, why} <- [
            {:create_issue, [{:error, :refused}], "sub-ticket s1 could not be created: :refused"},
            {:fetch_issue_states_by_ids, [{:error, :timeout}], "the ticket could not be read: :timeout"},
            {:fetch_issue_states_by_ids, [{:ok, []}], "the tracker does not return the ticket"},
            {:fetch_issue_states_by_ids, [:pass, :pass, {:error, :timeout}], "the sub-tickets could not be read: :timeout"}
          ] do
        script(call, replies)
        assert capture_log(fn -> assert Tree.split("default", ctx.issue, opts) == {:error, why} end)
        script(call, [])
      end

      # The store refuses the dependency (MT-9002 already depends on MT-9003: a cycle), so nothing starts.
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "memory-issue-2", issue_identifier: "MT-9002", phase: "Todo"})
      :ok = RunStore.add_dependency("memory-issue-2", "memory-issue-3", :done)
      assert Tree.split("default", ctx.issue, opts) == {:error, "MT-9003 could not be made to depend on MT-9002: :dependency_cycle"}
      refute Enum.any?(mailbox(), &match?({:memory_tracker_state_update, "memory-issue-3", "Todo"}, &1))
      :ok = RunStore.remove_dependency("memory-issue-2", "memory-issue-3")

      for {call, replies, why} <- [
            {:update_issue_state, [{:error, :refused}], "MT-9003 could not be moved to Todo: :refused"},
            {:fetch_issue_states_by_ids, [:pass, :pass, {:error, :timeout}], "the new sub-tickets could not be read back: :timeout"},
            {:update_issue_state, [:pass, {:error, :refused}], "the ticket could not be moved to the waiting state: :refused"}
          ] do
        script(call, replies)
        assert capture_log(fn -> assert Tree.split("default", ctx.issue, opts) == {:error, why} end)
        script(call, [])
      end

      # The tracker's read of the parent does not list a sub-ticket the plan names.
      script(:fetch_issue_states_by_ids, [{:ok, [ctx.issue]}])
      assert Tree.split("default", ctx.issue, opts) == {:error, "the tracker does not list MT-9002, MT-9003 under the ticket yet"}
      script(:fetch_issue_states_by_ids, [{:ok, [%{ctx.issue | sub_issues: :unknown}]}])
      assert {:error, "the tracker does not list" <> _rest} = Tree.split("default", ctx.issue, opts)

      refute Enum.any?(mailbox(), &match?({:memory_tracker_state_update, _parent, @waiting}, &1))
      assert Tree.split("default", ctx.issue, opts) == :ok
      assert_received {:memory_tracker_state_update, _parent, @waiting}
    end

    test "a ticket with no team, and a plan that can't take the identifiers, fail the split" do
      teamless = %Issue{id: "tree-teamless", identifier: "TREE-0", title: "No team", state: "Todo"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [teamless])
      {:ok, _event} = TicketPlan.write("default", teamless.id, Map.merge(plan(two()), %{reason: "Grooming", by: "grooming"}))

      assert Tree.split("default", teamless) == {:error, "sub-ticket s1 could not be created: the ticket's team is not known"}

      # With no repo key nothing can be recorded: the sub-ticket exists, its ask and identifier are lost.
      keyless = %{teamless | team: %{key: "MT"}}

      log =
        capture_log(fn ->
          assert {:error, "the sub-tickets' identifiers could not be written on the plan: " <> _why} = Tree.split(nil, keyless)
        end)

      assert log =~ "Could not record the ask of sub-ticket MT-9002 of TREE-0"
    end
  end

  test "a split needs the waiting state" do
    assert Tree.supported?("default")
    refute Tree.supported?("no-such-repo")
    refute Tree.supported?(nil)
    settings = Config.settings!()
    capture_log(fn -> assert :disabled = SubIssueWait.check_tracker_state(settings, [], tracker: NoWaitingState) end)
    on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)
    refute Tree.supported?("default")
  end

  test "a failed split is retried twice by itself, then the person is asked each time", ctx do
    assert Tree.failed("default", ctx.issue_id, "Linear is down") == :retry
    assert Tree.failed("default", ctx.issue_id, "Linear is down") == :retry
    assert Tree.failed("default", ctx.issue_id, "Linear is down") == :ask
    assert Tree.failed("default", ctx.issue_id, "Linear is down") == :ask
    assert [note | _rest] = status_notes(ctx.issue_id)
    assert note == "Symphony could not split this ticket into its sub-tickets: Linear is down."

    assert %{title: "The sub-tickets could not be created", options: [%{action: "continue", recommended: true}, %{action: "cancel"}]} = Tree.question("Linear is down")
    assert capture_log(fn -> assert Tree.failed(nil, "tree-unrecorded", "why") == :retry end) =~ "Could not record a note"
  end

  describe "the close of a groomed ticket" do
    @on %Schema.Conductor{enabled: true}
    @off %Schema.Conductor{enabled: false}
    @terminal ["Done", "Canceled"]

    defp waiting!(ctx, sub_issues, sub_tickets \\ two()) do
      {:ok, _event} = TicketPlan.write("default", ctx.issue_id, Map.merge(plan(sub_tickets), %{reason: "Grooming", by: "grooming"}))
      :ok = TicketSignals.record_phase("default", ctx.issue_id, @waiting)
      :ok = RunStore.update_ticket_state(ctx.issue_id, %{sub_issues: sub_issues, team: ctx.issue.team, assignee: "user-1"})
      parent = %{ctx.issue | state: @waiting, sub_issues: sub_issues}
      children = for sub <- sub_issues, do: %Issue{id: sub.id, identifier: sub.identifier, state: sub.state}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent | children])
      parent
    end

    defp ended, do: [%{id: "c1", identifier: "MT-1", state: "Done"}, %{id: "c2", identifier: "MT-2", state: "Canceled"}]

    defp merged!(issue_id, state \\ "merged") do
      url = "https://github.com/acme/app/pull/#{System.unique_integer([:positive])}"
      :ok = TicketPullRequest.put("default", issue_id, %{pr_url: url})
      if state != "open", do: :ok = TicketPullRequest.mark_finished("default", url, state)
      :ok
    end

    test "waits while a sub-ticket is open, one in Backlog included, then owes the final check", ctx do
      parent = waiting!(ctx, ended())
      backlog = %{parent | sub_issues: ended() ++ [%{id: "c3", identifier: "MT-3", state: "Backlog"}]}

      # Sub-tickets ended while one is open: a look at the plan is owed, once.
      assert Tree.due(backlog, @terminal, conductor: @on) == :sub_ticket_ended
      assert Tree.due(backlog, @terminal, conductor: @off) == nil
      assert Tree.due(backlog, @terminal, conductor: %{@on | junctions: ["final_check"]}) == nil
      assert Tree.seen("default", backlog, @terminal) == :ok
      assert ["Sub-ticket MT-1 ended: Done.", "Sub-ticket MT-2 ended: Canceled."] = status_notes(ctx.issue_id)
      assert Tree.due(backlog, @terminal, conductor: @on) == nil
      assert Tree.due(%{parent | sub_issues: :unknown}, @terminal, conductor: @on) == nil
      # A read of the ticket's events that failed owes nothing: every ended sub-ticket would look unseen.
      assert Tree.due(backlog, @terminal, conductor: @on, read: fn _id -> {:error, :store_down} end) == nil
      assert Tree.due(nil, @terminal) == nil
      assert Tree.due(parent, @terminal, conductor: @on) == :final_check
      # With the Conductor or its junction off, the ticket closes on its sub-tickets alone.
      assert Tree.due(parent, @terminal, conductor: @off) == :close
      assert Tree.due(parent, @terminal, conductor: %{@on | junctions: ["grooming"]}) == :close
      assert Tree.due(parent, @terminal) == :close
      # No sub-ticket is left under it at all: nothing to check.
      assert Tree.due(%{parent | sub_issues: []}, @terminal, conductor: @on) == :close

      settings = Config.settings!()
      assert SubIssueWait.close?(parent, @terminal, settings)
      refute SubIssueWait.close?(backlog, @terminal, settings)
      refute SubIssueWait.close?(%{parent | state: "Todo"}, @terminal, settings)
    end

    test "with a pull request of its own, closes only once that merged", ctx do
      parent = waiting!(ctx, ended())
      merged!(ctx.issue_id, "open")
      assert Tree.due(parent, @terminal, conductor: @on) == nil
      assert Tree.due(parent, @terminal, conductor: @off) == nil

      # The merge's own mark counts, as the record's merged pull request does.
      :ok = RunStore.put_merged_wait(ctx.issue_id)
      assert Tree.due(parent, @terminal, conductor: @off) == :close
      :ok = RunStore.delete_merged_wait(ctx.issue_id)
      merged!(ctx.issue_id)
      assert Tree.due(parent, @terminal, conductor: @on) == :final_check
      merged!(ctx.issue_id, "closed")
      assert Tree.due(parent, @terminal, conductor: @on) == nil
    end

    test "the orchestrator closes it by the rule when no final check is owed, and tends it when one is", ctx do
      parent = waiting!(ctx, ended())
      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new(), retry_attempts: %{}}

      Orchestrator.close_finished_parents_for_test([parent], state)
      assert_received {:memory_tracker_state_update, parent_id, "Done"}
      assert parent_id == ctx.issue_id
      assert %{phase: "Done"} = RunStore.get_ticket_state(ctx.issue_id)

      # With the Conductor on, the final check comes first: the poll reads the ticket again for it.
      :ok = TicketSignals.record_phase("default", ctx.issue_id, @waiting)
      append_symphony_yml!("conductor:\n  enabled: true\n")
      Orchestrator.close_finished_parents_for_test([parent], state)
      refute_received {:memory_tracker_state_update, _parent, "Done"}

      Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result, {:error, :timeout})
      candidates = [parent, nil, %{parent | state: "Todo"}]
      log = capture_log(fn -> Orchestrator.tend_groomed_parents_for_test(candidates, state) end)
      assert log =~ "Failed to refresh a ticket before its Conductor turn; retrying next poll: issue_id=#{ctx.issue_id}"

      # A sub-ticket filed since the cached poll: no turn is owed any more.
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issue_states_result)
      filed = %{parent | sub_issues: ended() ++ [%{id: "c3", identifier: "MT-3", state: "Todo"}]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [filed])
      assert capture_log(fn -> Orchestrator.tend_groomed_parents_for_test([parent], state) end) == ""
      assert Facts.events(ctx.issue_id) |> Enum.filter(&(&1.type == "run.started")) == []
    end
  end

  describe "the final check" do
    defp final(ctx, reply, opts \\ []) do
      turn = fn _plan, _issue, _run_id, _prompt -> reply end
      Conductor.tend(ctx.parent, "final_check", "default", [settings: @on, turn: turn] ++ opts)
    end

    defp answered(attrs), do: {:ok, [Jason.encode!(Map.merge(%{"update" => "I checked the whole ticket.\n\nNext: it closes."}, attrs))], 7}
    defp add(title, extra \\ %{}), do: Map.merge(%{"op" => "add", "title" => title, "ask" => "Build #{title}.", "reason" => "#{title} is missing."}, extra)

    setup ctx do
      %{parent: waiting!(ctx, ended())}
    end

    test "done moves the ticket to Done through its own edge, with a note", ctx do
      :ok = RunStore.put_merged_wait(ctx.issue_id)
      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        answered(%{"done" => true, "tree" => []})
      end

      assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: turn) == :ok

      assert_received {:prompt, prompt}
      assert prompt =~ "This turn's junction is `final_check`: the last sub-ticket ended"
      assert prompt =~ ~s("rounds": {)
      refute prompt =~ "{{"
      assert_received {:memory_tracker_state_update, parent_id, "Done"}
      assert parent_id == ctx.issue_id
      assert %{phase: "Done", phase_owner: :symphony} = RunStore.get_ticket_state(ctx.issue_id)
      refute RunStore.merged_wait?(ctx.issue_id)
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "The final check passed"
      assert [%{payload: %{junction: "final_check"}}] = Enum.filter(Facts.events(ctx.issue_id), &(&1.type == "conductor.update"))
    end

    test "done reads the sub-tickets again: one added meanwhile keeps the ticket waiting", ctx do
      # A sub-ticket filed after the turn read the tree: the tracker lists it, the turn's facts did not.
      added = %{id: "c9", identifier: "MT-9", state: "Todo"}

      turn = fn _plan, _issue, _run_id, _prompt ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{ctx.parent | sub_issues: ended() ++ [added]}])
        answered(%{"done" => true, "tree" => []})
      end

      assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: turn) == :ok

      refute_received {:memory_tracker_state_update, _parent, "Done"}
      assert %{phase: @waiting} = RunStore.get_ticket_state(ctx.issue_id)
      assert ["The final check passed, but MT-9 was added meanwhile and has not ended. This ticket waits for it."] = status_notes(ctx.issue_id)
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []

      # A read that fails closes nothing either: the person is asked.
      script(:fetch_issue_states_by_ids, [{:error, :timeout}])
      answer = %{done: true, tree: []}
      apply_ctx = %{junction: "final_check", issue: ctx.parent, repo_key: "default", run_id: "run-1", conductor: @on}
      log = capture_log(fn -> assert {:ask, :stuck, _question} = Tree.apply(answer, apply_ctx, tracker: Scripted) end)
      assert log =~ "the ticket's sub-tickets could not be read again"
      refute_received {:memory_tracker_state_update, _parent, "Done"}
    end

    test "sub-tickets it adds are a round: created, recorded on them and written on a new plan version", ctx do
      adds = [add("The docs"), add("The export", %{"after" => ["MT-1", "MT-404"]})]

      assert final(ctx, answered(%{"done" => false, "tree" => adds})) == :ok

      assert_received {:memory_tracker_issue_created, "memory-issue-4", docs}
      assert %{title: "The docs", state: "Todo", priority: 1, team: "MT", assignee_id: "user-1"} = docs
      assert_received {:memory_tracker_issue_created, "memory-issue-5", %{title: "The export", state: "Backlog", parent_id: _parent}}
      # It is put on the records and depends on MT-1 (MT-404 is no sub-ticket); no tracker link.
      refute_received {:memory_tracker_blocked_by_added, _blocker, _issue}
      assert [%{issue_id: "c1", kind: :done}] = depends_on("memory-issue-5")
      assert_received {:memory_tracker_state_update, "memory-issue-5", "Todo"}
      refute_received {:memory_tracker_state_update, _parent, "Done"}

      current = TicketPlan.current(ctx.issue_id)
      assert %{version: 2, by: "recalibration", reason: "Final check: The docs is missing. The export is missing."} = current
      assert [_s1, _s2, %{key: "s3", identifier: "MT-9004", after: []}, %{key: "s4", identifier: "MT-9005"}] = current.sub_tickets
      events = Facts.events(ctx.issue_id)
      assert Tree.rounds(events) == 1
      assert Tree.round_limit(events, @on) == 3

      by = ctx.issue.identifier

      assert [%{payload: %{action: "added", reason: "The docs is missing.", by: ^by, target: "MT-9004"}}] =
               Enum.filter(Facts.events("memory-issue-4"), &(&1.type == "conductor.intervention"))

      assert [%{source: "parent", text: "Build The docs."}] = TicketPlan.ask("memory-issue-4")
      assert [_c1, _c2, %{identifier: "MT-9004"}, %{identifier: "MT-9005"}] = RunStore.get_ticket_state(ctx.issue_id).sub_issues
      assert status_notes(ctx.issue_id) == []
    end

    test "a 4th round is refused, and Symphony asks the person, whose answer lets one more through", ctx do
      for round <- 1..3 do
        {:ok, _event} = TicketPlan.write("default", ctx.issue_id, Map.merge(plan(two()), %{reason: "Final check: round #{round}", by: "recalibration"}))
      end

      assert final(ctx, answered(%{"done" => false, "tree" => [add("One more")]})) == :ok

      refute_received {:memory_tracker_issue_created, _id, _attrs}
      assert [%{title: "The final check still finds work after 3 rounds", options: options}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert [%{label: "Allow one more round"}, %{label: "Close it as it is", move: %{to: "Done"}}] = options
      events = Facts.events(ctx.issue_id)
      assert Tree.rounds(events) == 3
      assert Tree.round_limit(events, @on) == 4
      assert [asked] = status_notes(ctx.issue_id)
      assert asked =~ "After 3 rounds the final check still wanted to add sub-tickets"

      # The person let it go on: the next final check may add once more.
      assert final(ctx, answered(%{"done" => false, "tree" => [add("One more")]})) == :ok
      assert_received {:memory_tracker_issue_created, _id, %{title: "One more"}}
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 4
    end

    test "a check that did not finish is tried once more, then the person is asked and the ticket never closes", ctx do
      assert Tree.due(ctx.parent, @terminal, conductor: @on) == :final_check

      log = capture_log(fn -> assert final(ctx, {:error, :boom, 3}) == :ok end)
      assert log =~ "Conductor turn wrote nothing"
      assert ["The final check did not finish (failed). Symphony tries once more."] = status_notes(ctx.issue_id)
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []

      capture_log(fn -> assert final(ctx, {:ok, ["not json"], 3}) == :ok end)
      assert [_first, second, asked] = status_notes(ctx.issue_id)
      assert second =~ "The final check did not finish, 2 times in a row (unreadable answer"
      assert asked == "The final check could not close this ticket, so Symphony asked the person."

      assert [%{title: "The final check could not close this ticket", question: question, options: options}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert question =~ "the turn failed or its answer could not be read, 2 times in a row"
      assert question =~ "Still open: c1 The list is filtered."
      assert [%{label: "Check again"}, %{label: "Close it as it is", move: %{to: "Done"}}] = options

      # It never closes on its sub-tickets alone while the check can run, and its tries count from zero again.
      assert Tree.due(ctx.parent, @terminal, conductor: @on) == :final_check
      refute_received {:memory_tracker_state_update, _parent, "Done"}
      capture_log(fn -> assert final(ctx, {:error, :boom, 3}) == :ok end)
      assert List.last(status_notes(ctx.issue_id)) == "The final check did not finish (failed). Symphony tries once more."
    end

    test "not done with nothing to add asks the person at once", ctx do
      assert final(ctx, answered(%{"done" => false, "tree" => []})) == :ok

      assert [%{question: question}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert question =~ "it answered that the ticket is not done, and added no sub-ticket"
      assert ["The final check could not close this ticket, so Symphony asked the person."] = status_notes(ctx.issue_id)
      refute_received {:memory_tracker_state_update, _parent, "Done"}
      assert %{phase: @waiting} = RunStore.get_ticket_state(ctx.issue_id)
    end

    test "sub-tickets it wanted that could not be created ask the person at once", ctx do
      Application.put_env(:symphony_elixir, :memory_tracker_create_issue_result, {:error, :linear_down})
      log = capture_log(fn -> assert final(ctx, answered(%{"done" => false, "tree" => [add("The docs")]})) == :ok end)
      assert log =~ "The Conductor's add was not carried out"

      assert [%{question: question}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert question =~ "none of the sub-tickets it wanted to add could be created (The docs)"
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 0
    end

    test "a question holds the ticket and carries nothing out, and a turn Symphony can't plan runs nothing", ctx do
      ask = %{
        "title" => "Is the export needed?",
        "question" => "The ask does not say.",
        "why" => "Nothing settles it.",
        "if_unanswered" => "The ticket stays paused.",
        "recommendation_reason" => "It was asked for.",
        "options" => [
          %{"label" => "Yes", "effect" => "The check runs again.", "recommended" => true, "action" => "continue"},
          %{"label" => "Cancel", "effect" => "The ticket is cancelled.", "action" => "cancel"}
        ]
      }

      assert final(ctx, answered(%{"done" => true, "tree" => [add("The docs")], "ask_person" => ask})) == :ok
      assert [%{title: "Is the export needed?"}] = Questions.open({:ticket, "default", ctx.issue_id})
      refute_received {:memory_tracker_issue_created, _id, _attrs}
      refute_received {:memory_tracker_state_update, _parent, "Done"}
      assert status_notes(ctx.issue_id) == []

      no_turn = fn _plan, _issue, _run_id, _prompt -> flunk("no turn runs") end
      assert Conductor.tend(ctx.parent, "final_check", "default", settings: @off, turn: no_turn) == :ok
      assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: no_turn, available?: fn _profile -> false end) == :ok
      assert capture_log(fn -> assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: :not_a_function) == :ok end) =~ "wrote nothing"
      log = capture_log(fn -> assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: no_turn, record: %{}) == :ok end)
      assert log =~ "Conductor turn failed issue_id=#{ctx.issue_id}"
      assert log =~ "junction=final_check"
    end

    test "a pass that could not move the ticket asks the person", ctx do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :state_not_found}])
      log = capture_log(fn -> assert final(ctx, answered(%{"done" => true})) == :ok end)
      assert log =~ "The final check passed, but the ticket could not be moved to Done"
      assert %{phase: @waiting} = RunStore.get_ticket_state(ctx.issue_id)
      assert [%{question: question}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert question =~ "it passed, but the ticket could not be moved to Done"
      assert [_asked] = status_notes(ctx.issue_id)
    end

    test "what can't be recorded or read back is logged, and the sub-ticket stays added", ctx do
      answer = %{done: false, tree: [%{op: "add", title: "The docs", ask: "Write them.", after: [], reason: "Missing."}]}
      ctx_of = &%{junction: "final_check", issue: &1, repo_key: &2, run_id: "run-1", conductor: @on}

      script(:fetch_issue_states_by_ids, [{:error, :timeout}])
      log = capture_log(fn -> assert Tree.apply(answer, ctx_of.(ctx.parent, "default"), tracker: Scripted) == :ok end)
      assert log =~ "The added sub-tickets are not on Symphony's records yet"
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 1

      # A ticket Symphony holds no record of, under no repo key: nothing can be written.
      bare = %Issue{id: "tree-bare-#{System.unique_integer([:positive])}", identifier: "BARE-1", team: %{key: "MT"}, sub_issues: []}
      {:ok, _event} = TicketPlan.write("default", bare.id, Map.merge(plan(two()), %{reason: "Grooming", by: "grooming"}))
      log = capture_log(fn -> assert Tree.apply(answer, ctx_of.(bare, nil), []) == :ok end)
      assert log =~ "Could not record conductor.intervention on MT-"
      assert log =~ "The plan's new version could not be written issue_id=#{bare.id}"
      assert Tree.rounds(Facts.events(bare.id)) == 0
    end

    test "while no provider can take it, the ticket says that it waits, once, and after 30 minutes asks the person once", ctx do
      no_turn = fn _plan, _issue, _run_id, _prompt -> flunk("no turn runs") end
      held = [settings: @on, turn: no_turn, available?: fn _profile -> false end]
      [%{provider: provider} | _fallbacks] = Config.runs(Config.settings!(), :conductor)

      assert Conductor.unavailable("default", fn _profile -> false end, settings: @on) == to_string(provider)
      assert Conductor.unavailable("default", fn _profile -> true end, settings: @on) == nil
      assert Conductor.unavailable("default", fn _profile -> false end, settings: @off) == nil
      assert Conductor.unavailable(nil, fn _profile -> false end, settings: @on) == nil
      assert Conductor.unavailable("no-such-repo", fn _profile -> false end, settings: @on) == nil

      for _poll <- 1..2, do: assert(Conductor.tend(ctx.parent, "final_check", "default", held) == :ok)
      assert ["Waiting for the Conductor: #{provider} is paused or at its usage limit."] == status_notes(ctx.issue_id)
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []

      # A look at the plan waits as long as it must, and asks nothing.
      later = DateTime.add(DateTime.utc_now(), 31, :minute)
      assert Conductor.wait(ctx.parent, "sub_ticket_ended", "default", "openai", now: later) == :ok
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []

      assert Conductor.wait(ctx.parent, "final_check", "default", "openai", now: later) == :ok
      assert [%{title: "The final check waits for the Conductor", options: options}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert [%{label: "Keep waiting"}, %{label: "Close it on its sub-tickets", move: %{to: "Done"}}] = options
      assert [_waiting, "The final check still waits for the Conductor, so Symphony asked the person."] = status_notes(ctx.issue_id)
      assert Tree.waiting("default", ctx.issue_id, "final_check", "openai", later) == :ok

      # A turn ran: the next time the provider is away is a wait of its own.
      capture_log(fn -> assert final(ctx, {:error, :boom, 1}) == :ok end)
      assert Tree.waiting("default", ctx.issue_id, "final_check", "openai") == :ok
      assert List.last(status_notes(ctx.issue_id)) == "Waiting for the Conductor: openai is paused or at its usage limit."
      assert {:ask, {:waiting, 2}, _question} = Tree.waiting("default", ctx.issue_id, "final_check", "openai", DateTime.add(later, 31, :minute))
    end

    test "the poll reads no waiting ticket from the tracker for a turn no provider can take", ctx do
      append_symphony_yml!("conductor:\n  enabled: true\n")
      providers = for profile <- Config.runs(Config.settings!(), :conductor), into: MapSet.new(), do: profile.provider
      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new(), retry_attempts: %{}, paused_providers: providers}
      mailbox()

      Orchestrator.tend_groomed_parents_for_test([ctx.parent], state)

      assert mailbox() == []
      assert ["Waiting for the Conductor: " <> _provider] = status_notes(ctx.issue_id)
    end

    test "a sub-ticket whose dependency can't be stored is not started, and one that can't be started is said on the parent too", ctx do
      # MT-1 already depends on the sub-ticket about to be created, so depending on MT-1 is a cycle.
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "c1", issue_identifier: "MT-1", phase: "Done"})
      :ok = RunStore.add_dependency("c1", "memory-issue-4", :done)

      capture_log(fn -> assert final(ctx, answered(%{"tree" => [add("The export", %{"after" => ["MT-1"]})]})) == :ok end)

      assert [note] = status_notes(ctx.issue_id)

      assert note ==
               "Symphony created MT-9004 but could not make its dependency on MT-1 (:dependency_cycle). It stays in Backlog, where it holds this ticket, and Symphony tries again."

      refute_received {:memory_tracker_state_update, "memory-issue-4", "Todo"}
      assert depends_on("memory-issue-4") == []
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 1

      :ok = RunStore.remove_dependency("c1", "memory-issue-4")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :refused}])
      child = %{id: "memory-issue-4", identifier: "MT-9004", repo: "default"}
      blockers = [%{id: "c1", identifier: "MT-1"}]
      assert Tree.start(child, blockers, ctx.parent, "default", []) == {:error, "its move to Todo (:refused)"}
      assert Tree.start(child, blockers, ctx.parent, "default", []) == :ok
      assert [%{issue_id: "c1", identifier: "MT-1", kind: :done}] = depends_on("memory-issue-4")
      assert_received {:memory_tracker_state_update, "memory-issue-4", "Todo"}
    end
  end

  describe "a sub-ticket Symphony left in Backlog" do
    @left %{id: "c3", identifier: "MT-3", state: "Backlog"}

    setup ctx do
      parent = waiting!(ctx, [hd(ended()), @left])
      # MT-1 and the parent already depend on MT-3, so MT-3 can depend on neither: a cycle.
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "c1", issue_identifier: "MT-1", phase: "Done"})
      :ok = RunStore.add_dependency("c1", "c3", :done)
      :ok = RunStore.add_dependency(ctx.issue_id, "c3", :done)
      child = %{id: "c3", identifier: "MT-3", repo: "default"}
      assert {:error, "its dependency on MT-1 (:dependency_cycle)"} = Tree.start(child, [%{id: "c1", identifier: "MT-1"}], parent, "default", [])
      mailbox()
      %{parent: parent}
    end

    test "is tried again while its parent waits, and after 3 failed tries the person is asked", ctx do
      assert Tree.due(ctx.parent, @terminal, conductor: @off) == :start
      # One a person keeps in Backlog, which Symphony never failed to start, owes nothing.
      by_hand = %{ctx.parent | sub_issues: [hd(ended()), %{id: "c4", identifier: "MT-4", state: "Backlog"}]}
      assert Tree.due(by_hand, @terminal, conductor: @off) == nil

      for _try <- 1..2, do: assert(Conductor.tend(ctx.parent, "start", "default") == :ok)
      assert Questions.open({:ticket, "default", ctx.issue_id}) == []
      refute_received {:memory_tracker_state_update, "c3", "Todo"}

      # The tracker's read fails too: it is a try like any other, the third.
      script(:fetch_issue_states_by_ids, [{:error, :timeout}])
      assert Conductor.tend(ctx.parent, "start", "default", tracker: Scripted) == :ok

      assert [_failed, first, _second, third, asked] = status_notes(ctx.issue_id)
      # Its plan names nothing it waits after, so it waits on its parent, as one a run's turn filed does.
      assert first == "Symphony could not start MT-3 again: its dependency on #{ctx.issue.identifier} (:dependency_cycle)."
      assert third == "Symphony could not start MT-3 again: it could not be read (:timeout)."
      assert asked == "A sub-ticket could not be started, 3 times, so Symphony asked the person."
      assert [%{title: "A sub-ticket could not be started", question: question, options: options}] = Questions.open({:ticket, "default", ctx.issue_id})
      assert [%{label: "Try again"}, %{label: "Cancel this ticket"}] = options
      assert question =~ "Symphony created MT-3 under this ticket and could not start it, 3 times"

      # Asked to try again, it counts from zero.
      script(:fetch_issue_states_by_ids, [{:ok, []}])
      assert Tree.start_left("default", ctx.parent, tracker: Scripted) == :ok
      assert List.last(status_notes(ctx.issue_id)) == "Symphony could not start MT-3 again: the tracker does not return it."
    end

    test "is given its dependency and started once the step goes through, by the poll, and then owes nothing", ctx do
      :ok = RunStore.remove_dependency("c1", "c3")
      :ok = RunStore.remove_dependency(ctx.issue_id, "c3")
      state = %Orchestrator.State{max_concurrent_agents: 1, running: %{}, claimed: MapSet.new(), retry_attempts: %{}}

      Orchestrator.tend_groomed_parents_for_test([ctx.parent], state)

      parent_id = ctx.issue_id
      assert [%{issue_id: ^parent_id, kind: :done}] = depends_on("c3")
      refute_received {:memory_tracker_blocked_by_added, _blocker, "c3"}
      assert_received {:memory_tracker_state_update, "c3", "Todo"}
      assert List.last(status_notes(ctx.issue_id)) == "Symphony started MT-3, which it had left in Backlog, once its dependencies were stored."
      assert Tree.due(ctx.parent, @terminal, conductor: @off) == nil
      assert Tree.start_left("default", ctx.parent) == :ok
    end

    test "takes its blockers from the plan, keeps a dependency it has, and leaves one a person moved", ctx do
      :ok = RunStore.remove_dependency("c1", "c3")
      :ok = RunStore.remove_dependency(ctx.issue_id, "c3")
      # Its record already depends on MT-1, the sibling its plan entry waits after.
      :ok = RunStore.add_dependency("c3", "c1", :done)
      first = %{key: "s1", title: "The API filter", ask: "a", after: [], identifier: "MT-1"}
      entries = [first, %{key: "s2", title: "The list", ask: "b", after: ["s1"], identifier: "MT-3"}]
      {:ok, _event} = TicketPlan.write("default", ctx.issue_id, Map.merge(plan(entries), %{reason: "Sub-tickets created", by: "grooming"}))

      linked = %Issue{id: "c3", identifier: "MT-3", state: "Backlog"}
      script(:fetch_issue_states_by_ids, [{:ok, [%{linked | state: "Todo"}]}, {:ok, [linked]}])

      # A person moved it on: nothing is done, and nothing is said.
      notes = status_notes(ctx.issue_id)
      assert Tree.start_left("default", ctx.parent, tracker: Scripted) == :ok
      assert status_notes(ctx.issue_id) == notes
      refute_received {:memory_tracker_state_update, "c3", _state}

      assert Tree.start_left("default", ctx.parent, tracker: Scripted) == :ok
      assert [%{issue_id: "c1", kind: :done}] = depends_on("c3")
      assert_received {:memory_tracker_state_update, "c3", "Todo"}
    end

    test "with no record of its own, is put on Symphony's records, given its dependency and started", ctx do
      :ok = RunStore.remove_dependency("c1", "c3")
      :ok = RunStore.remove_dependency(ctx.issue_id, "c3")
      :ok = RunStore.delete_ticket_state("c3")
      script(:fetch_issue_states_by_ids, [{:ok, [%Issue{id: "c3", identifier: "MT-3", state: "Backlog"}]}])

      assert Tree.start_left("default", ctx.parent, tracker: Scripted) == :ok
      parent_id = ctx.issue_id
      assert [%{issue_id: ^parent_id, kind: :done}] = depends_on("c3")
      assert_received {:memory_tracker_state_update, "c3", "Todo"}
    end
  end

  describe "the bounds" do
    setup ctx do
      %{parent: waiting!(ctx, ended())}
    end

    defp filed!(issue_id, count) do
      for n <- 1..count do
        {:ok, _event} = TicketEvents.record("default", issue_id, "ticket.filed", %{identifier: "MT-#{500 + n}", kind: "split_off", title: "Part #{n}"})
      end
    end

    # A chain of records, each the sub-ticket of the one before: the last is `levels` below the first.
    defp deep!(ctx, levels) do
      Enum.reduce(1..levels, %{issue_id: ctx.issue_id, issue_identifier: ctx.issue.identifier}, fn level, parent ->
        n = System.unique_integer([:positive])
        record = %{repo_key: "default", issue_id: "deep-#{n}", issue_identifier: "DEEP-#{n}", phase: "Todo", title: "Level #{level}"}
        :ok = RunStore.put_ticket_state(Map.put(record, :parent, %{id: parent.issue_id, identifier: parent.issue_identifier}))
        record
      end)
    end

    test "a ticket gets at most 20 sub-tickets over its life: one more is refused, said in the facts, and asked about once", ctx do
      filed!(ctx.issue_id, 18)
      # A sub-ticket a plan names counts with the ones filed, once each.
      assert Tree.created(ctx.issue_id) == 18
      entry = &%{key: &1, title: &2, ask: "a", after: [], identifier: &3}
      entries = [entry.("s1", "Part 1", "MT-501"), entry.("s2", "Other", "MT-1")]
      {:ok, _event} = TicketPlan.write("default", ctx.issue_id, Map.merge(plan(entries), %{reason: "Sub-tickets created", by: "grooming"}))
      assert Tree.created(ctx.issue_id) == 19
      assert Tree.room(ctx.issue_id) == :ok

      test = self()

      turn = fn _plan, _issue, _run_id, prompt ->
        send(test, {:prompt, prompt})
        answered(%{"done" => false, "tree" => [add("The docs"), add("The export")]})
      end

      log = capture_log(fn -> assert Conductor.tend(ctx.parent, "final_check", "default", settings: @on, turn: turn) == :ok end)
      assert log =~ "The Conductor's add was not carried out"
      assert log =~ "this ticket already got 20 sub-tickets, the most one ticket may get"

      assert_received {:prompt, first}
      assert first =~ ~s("limits": {)
      assert first =~ ~s("created": 19)

      # The 20th was created, the 21st refused.
      assert [{:memory_tracker_issue_created, _id, %{title: "The docs"}}] = Enum.filter(mailbox(), &(elem(&1, 0) == :memory_tracker_issue_created))
      assert Tree.created(ctx.issue_id) == 20
      assert {:error, "already got 20 sub-tickets, the most one ticket may get"} = Tree.room(ctx.issue_id)
      refused = ~s(Symphony did not create the sub-ticket "The export": this ticket already got 20 sub-tickets, the most one ticket may get.)
      assert [^refused, "Symphony refused a sub-ticket this ticket may not get, and asked the person."] = status_notes(ctx.issue_id)

      assert [%{title: "This ticket may get no more sub-tickets", question: question, options: [%{label: "Go on without it"}, %{label: "Cancel the ticket"}]}] =
               Questions.open({:ticket, "default", ctx.issue_id})

      assert question =~ refused

      # The next turn reads what was refused, and a second refusal asks nothing more about the bound.
      assert Tree.limit_ask(ctx.issue_id) == :ok
      facts = Tree.facts(%{}, ctx.issue_id)
      assert %{sub_tickets: %{created: 20, max: 20}, depth: %{level: 0, max: 3}, refused: [^refused], rule: rule} = facts.limits
      assert rule =~ "at most 20 sub-tickets"
      apply_ctx = %{junction: "final_check", issue: ctx.parent, repo_key: "default", run_id: "run-2", conductor: @on}
      again = %{done: false, tree: [%{op: "add", title: "The export", ask: "Build it.", after: [], reason: "Missing."}]}

      capture_log(fn ->
        assert {:ask, :stuck, %{question: stuck}} = Tree.apply(again, apply_ctx, [])
        assert stuck =~ "none of the sub-tickets it wanted to add could be created (The export)"
      end)
    end

    test "a ticket 3 levels below its root gets no sub-tickets, and its plan is never a split", ctx do
      second = deep!(ctx, 2)
      third = deep!(%{issue_id: second.issue_id, issue: %{identifier: second.issue_identifier}}, 1)
      assert Tree.depth(ctx.issue_id) == 0
      assert Tree.depth(second.issue_id) == 2
      assert Tree.depth(third.issue_id) == 3
      assert Tree.room(second.issue_id) == :ok
      assert {:error, "is 3 levels below its root ticket, and a ticket that deep gets no sub-tickets"} = Tree.room(third.issue_id)
      # Records that name each other end the walk at the bound.
      assert Tree.depth(deep!(%{issue_id: third.issue_id, issue: %{identifier: third.issue_identifier}}, 3).issue_id) == 3

      split = plan(two())
      assert Tree.fit("default", second.issue_id, split) == split
      single = Tree.fit("default", third.issue_id, split)
      assert %{shape: "single"} = single
      refute Map.has_key?(single, :sub_tickets)
      assert ["The plan split this ticket into sub-tickets, but it is 3 levels below its root ticket, so it is built as one ticket."] = status_notes(third.issue_id)
      assert Tree.fit("default", third.issue_id, single) == single

      # Its Grooming is told before it plans; a ticket with no plan higher up reads nothing new.
      assert %{limits: %{depth: %{level: 3, max: 3}, refused: []}} = Tree.facts(%{}, third.issue_id)
      assert Tree.facts(%{a: 1}, second.issue_id) == %{a: 1}

      deep = %Issue{id: third.issue_id, identifier: third.issue_identifier, team: %{key: "MT"}}
      log = capture_log(fn -> assert {:error, "this ticket is 3 levels below its root ticket" <> _rest} = Tree.create("default", deep, hd(two()), []) end)
      assert log == ""
      refute_received {:memory_tracker_issue_created, _id, _attrs}
      assert {:ask, :limit, %{question: question}} = Tree.limit_ask(third.issue_id)
      assert question =~ ~s(Symphony did not create the sub-ticket "The API filter")
    end

    test "a sub-ticket Symphony creates carries where it came from, so it files no ticket of its own", ctx do
      assert {:ok, child} = Tree.create("default", ctx.issue, hd(two()), [])
      from = ctx.issue.identifier
      assert [%{payload: %{from: ^from, by: "conductor", kind: "split_off"}}] = events(child.id, "ticket.filed_from")
      assert %{open: false, closed: closed} = Filing.facts(Facts.events(child.id), @on, repos: ["default"])
      assert closed =~ "this ticket was itself filed by the Conductor (from #{from})"

      # A ticket of its own, for a finished ticket's message, is no sub-ticket and is not recorded as one.
      assert {:ok, own} = Tree.create("default", ctx.issue, hd(two()), standalone: true)
      assert events(own.id, "ticket.filed_from") == []
      assert length(events(ctx.issue_id, "ticket.filed")) == 1
    end
  end

  describe "recalibration, when a sub-ticket ended and others are open" do
    setup ctx do
      subs = [
        %{id: "c1", identifier: "MT-1", state: "Done"},
        %{id: "c2", identifier: "MT-2", state: "In Progress"},
        %{id: "c3", identifier: "MT-3", state: "Todo"}
      ]

      entries = [
        %{key: "s1", title: "The API", ask: "Add the filter.", after: [], identifier: "MT-1"},
        %{key: "s2", title: "The list", ask: "Read the filter.", after: ["s1"], identifier: "MT-2"},
        %{key: "s3", title: "The export", ask: "Export it.", after: [], identifier: "MT-3"}
      ]

      parent = waiting!(ctx, subs, entries)
      :ok = RunStore.put_ticket_state(%{repo_key: "default", issue_id: "c2", issue_identifier: "MT-2", phase: "In Progress"})
      test = self()

      cancel = fn identifier, note ->
        send(test, {:cancelled, identifier, note})
        {:ok, %{}}
      end

      stop = fn identifier ->
        send(test, {:stopped, identifier})
        {:ok, %{stopped: true}}
      end

      %{parent: parent, opts: [settings: @on, cancel: cancel, stop: stop]}
    end

    defp recalibrate(ctx, operations, opts \\ []) do
      turn = fn _plan, _issue, _run_id, _prompt -> {:ok, [Jason.encode!(%{"tree" => operations, "update" => nil})], 5} end
      Conductor.tend(ctx.parent, "sub_ticket_ended", "default", [turn: turn] ++ Keyword.merge(ctx.opts, opts))
    end

    defp interventions(issue_id), do: for(%{type: "conductor.intervention", payload: payload} <- Facts.events(issue_id), do: payload)

    test "each operation is carried out, recorded on the sub-ticket it touched, and written on a new plan version", ctx do
      assert Tree.due(ctx.parent, @terminal, conductor: @on) == :sub_ticket_ended

      operations = [
        %{"op" => "cancel", "ticket" => "MT-3", "reason" => "The API exports already."},
        %{"op" => "rewrite", "ticket" => "MT-2", "ask" => "Read the renamed field.", "stop" => true, "reason" => "The field was renamed."},
        %{"op" => "stop", "ticket" => "MT-2", "reason" => "It builds on the old name."},
        %{"op" => "add", "title" => "The docs", "ask" => "Describe the filter.", "after" => ["MT-1"], "reason" => "Nobody holds the docs."}
      ]

      assert recalibrate(ctx, operations) == :ok

      by = ctx.issue.identifier
      assert_received {:cancelled, "MT-3", note}
      assert note == "The Conductor of #{by} cancelled this sub-ticket: The API exports already."
      assert_received {:stopped, "MT-2"}
      assert_received {:memory_tracker_issue_created, "memory-issue-5", %{title: "The docs", state: "Backlog"}}
      assert [%{issue_id: "c1", kind: :done}] = depends_on("memory-issue-5")

      assert [%{action: "canceled", reason: "The API exports already.", by: ^by, target: "MT-3"}] = interventions("c3")
      assert [%{action: "stopped", reason: "The field was renamed."}, %{action: "replanned", target: "MT-2"}] = interventions("c2")
      assert [%{action: "added", target: "MT-9005"}] = interventions("memory-issue-5")
      assert [%{source: "parent", from: ^by, text: "Read the renamed field."}] = TicketPlan.ask("c2")

      current = TicketPlan.current(ctx.issue_id)
      assert %{version: 2, by: "recalibration", shape: "split"} = current
      assert current.reason == "Recalibration: The API exports already. The field was renamed. It builds on the old name. Nobody holds the docs."

      assert [
               %{key: "s1", identifier: "MT-1"},
               %{key: "s2", identifier: "MT-2", ask: "Read the renamed field."},
               %{key: "s4", identifier: "MT-9005", after: ["s1"], title: "The docs"}
             ] = current.sub_tickets

      # The turn was owed once for the sub-ticket that ended, and no round of the final check was made.
      assert ["Sub-ticket MT-1 ended: Done."] = status_notes(ctx.issue_id)
      assert Tree.due(ctx.parent, @terminal, conductor: @on) == nil
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 0
    end

    test "an operation that can't be carried out is logged and left out, and nothing is written for none", ctx do
      refused = [
        %{"op" => "cancel", "ticket" => "MT-1", "reason" => "It is done."},
        %{"op" => "cancel", "ticket" => "MT-404", "reason" => "Not ours."},
        %{"op" => "cancel", "ticket" => "MT-3", "reason" => "The move fails."},
        %{"op" => "stop", "ticket" => "MT-2", "reason" => "No run works on it."},
        %{"op" => "rewrite", "ticket" => "MT-2", "ask" => "Something else.", "stop" => true, "reason" => "Its run can't be stopped."}
      ]

      cancel = fn _identifier, _note -> {:error, :pr_close_failed} end
      opts = [cancel: cancel, stop: fn _identifier -> {:ok, %{stopped: false}} end]
      log = capture_log(fn -> assert recalibrate(ctx, refused, opts) == :ok end)

      assert log =~ "The Conductor's cancel was not carried out"
      assert log =~ "on=MT-1: MT-1 already ended (Done)"
      assert log =~ "on=MT-404: MT-404 is not a sub-ticket of this ticket"
      assert log =~ "on=MT-3: :pr_close_failed"
      assert log =~ "on=MT-2: its run was not stopped ({:ok, %{stopped: false}})"
      assert TicketPlan.current(ctx.issue_id).version == 1
      assert interventions("c2") == []
      assert TicketPlan.ask("c2") == []

      assert recalibrate(ctx, []) == :ok
      assert TicketPlan.current(ctx.issue_id).version == 1
    end

    test "a rewrite with no stop leaves the run going, and an ask that can't be recorded is left out", ctx do
      rewrite = %{op: "rewrite", ticket: "MT-3", ask: "Export as CSV.", stop: false, reason: "CSV was asked."}
      tree_ctx = %{junction: "sub_ticket_ended", issue: ctx.parent, repo_key: "default", run_id: "run-1", conductor: @on}

      test = self()
      recalibrate = fn issue_id, ask -> send(test, {:recalibrate, issue_id, ask.type, ask.payload.text}) end

      assert Tree.apply(%{done: false, tree: [rewrite]}, tree_ctx, Keyword.put(ctx.opts, :recalibrate, recalibrate)) == :ok
      refute_received {:stopped, _identifier}
      # The sub-ticket writes its plan again for the new ask, in a turn of its own.
      assert_received {:recalibrate, "c3", "ask.recorded", "Export as CSV."}
      # A sub-ticket Symphony keeps no record of is written under its parent's repo.
      assert [%{text: "Export as CSV.", source: "parent"}] = TicketPlan.ask("c3")
      assert [%{action: "replanned"}] = interventions("c3")
      assert %{version: 2, reason: "Recalibration: CSV was asked."} = TicketPlan.current(ctx.issue_id)

      long = %{rewrite | ask: String.duplicate("x", 100_001)}
      log = capture_log(fn -> assert Tree.apply(%{done: false, tree: [long]}, tree_ctx, ctx.opts) == :ok end)
      assert log =~ "The Conductor's rewrite was not carried out"
      assert TicketPlan.current(ctx.issue_id).version == 2

      # Under a repo Symphony can't read, no state counts as ended.
      stop = %{op: "stop", ticket: "MT-1", reason: "Stop it."}
      capture_log(fn -> assert Tree.apply(%{done: false, tree: [stop]}, %{tree_ctx | repo_key: "no-such-repo"}, ctx.opts) == :ok end)
      assert_received {:stopped, "MT-1"}
    end
  end
end
