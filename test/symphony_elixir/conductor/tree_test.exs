defmodule SymphonyElixir.Conductor.TreeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Conductor, Questions, SubIssueWait, TicketPlan, TicketPullRequest, TicketSignals}
  alias SymphonyElixir.Conductor.{Facts, Grooming, Tree}
  alias SymphonyElixir.Config.{Cache, Schema}
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

    test "sub-tickets it adds are a round: created, recorded on them and written on a new plan version", ctx do
      adds = [add("The docs"), add("The export", %{"after" => ["MT-1", "MT-404"]})]

      assert final(ctx, answered(%{"done" => false, "tree" => adds})) == :ok

      assert_received {:memory_tracker_issue_created, "memory-issue-4", docs}
      assert %{title: "The docs", state: "Todo", priority: 1, team: "MT", assignee_id: "user-1"} = docs
      assert_received {:memory_tracker_issue_created, "memory-issue-5", %{title: "The export", state: "Backlog", parent_id: _parent}}
      assert_received {:memory_tracker_blocked_by_added, "MT-1", "memory-issue-5"}
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

    test "a sub-ticket that can't be linked or started is said on the parent", ctx do
      Application.put_env(:symphony_elixir, :memory_tracker_add_blocked_by_result, {:error, :refused})
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :refused}])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_add_blocked_by_result) end)

      capture_log(fn -> assert final(ctx, answered(%{"tree" => [add("The export", %{"after" => ["MT-1"]})]})) == :ok end)

      assert [note] = status_notes(ctx.issue_id)
      assert note =~ "Symphony added MT-9004 but could not make the link to MT-1 (:refused) or its move to Todo (:refused)"
      assert Tree.rounds(Facts.events(ctx.issue_id)) == 1
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
      assert_received {:memory_tracker_blocked_by_added, "MT-1", "memory-issue-5"}

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

      long = %{rewrite | ask: String.duplicate("x", 30_000)}
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
