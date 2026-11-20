defmodule SymphonyElixir.Conductor.TreeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.{Facts, Grooming, Tree}
  alias SymphonyElixir.{SubIssueWait, TicketPlan}
  alias SymphonyElixir.Tracker.Memory

  @waiting "Waiting on sub-tickets"

  # The memory tracker, but for the calls a test scripts: `:pass` lets one through, anything else
  # is that call's answer.
  defmodule Scripted do
    @moduledoc false
    for {name, arity} <- [fetch_issue_states_by_ids: 1, create_issue: 1, add_blocked_by: 2, update_issue_state: 2] do
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

  defp status_notes(issue_id), do: for(%{type: "note", payload: %{status: true, text: text}} <- Facts.events(issue_id), do: text)

  describe "split/3" do
    test "creates each sub-ticket, links and starts the one that waits, then parks the parent", ctx do
      write!(ctx)

      assert Grooming.split("default", ctx.issue) == :ok

      created = %{title: "The API filter", description: "Add the filter to the API.", priority: 1, state: "Todo", team: "MT", project: "p1"}
      first = Map.merge(created, %{assignee_id: "user-1", parent_id: ctx.issue_id})
      second = %{first | title: "The list", description: "Read it in the list.", state: "Backlog"}

      # The sub-tickets exist, linked and started, before the parent waits on them.
      assert [
               {:memory_tracker_issue_created, "memory-issue-2", ^first},
               {:memory_tracker_issue_created, "memory-issue-3", ^second},
               {:memory_tracker_blocked_by_added, "MT-9002", "memory-issue-3"},
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
      assert %{repo_key: "default", blockers: [%{identifier: "MT-9002"}]} = RunStore.get_ticket_state("memory-issue-3")
      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "split this ticket into MT-9002, MT-9003"
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

      # Run again on a parent a person moved back, it creates nothing and links nothing twice.
      assert Grooming.split("default", ctx.issue) == :ok
      again = mailbox()
      refute Enum.any?(again, &(elem(&1, 0) in [:memory_tracker_issue_created, :memory_tracker_blocked_by_added]))
      assert TicketPlan.current(ctx.issue_id).version == 3
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
            {:fetch_issue_states_by_ids, [:pass, {:error, :timeout}], "the sub-tickets could not be read: :timeout"},
            {:add_blocked_by, [{:error, :refused}], "MT-9003 could not be linked as blocked by MT-9002: :refused"},
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
end
