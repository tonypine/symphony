defmodule SymphonyElixir.DirectorBlockersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{DirectorBlockers, RunStore, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    repo = "blockers-#{n}"
    put = fn suffix, attrs -> put(repo, "#{n}#{suffix}", attrs) end

    ticket = put.("1", %{phase: "Todo", title: "Export the report"})
    blocker = put.("2", %{phase: "In Progress", title: "Fix the exporter"})
    other = put.("3", %{phase: "Todo", title: "Rename the button"})
    done = put.("4", %{phase: "Done", title: "Old work"})

    opts = [
      orchestrator: self(),
      audit_log: [dir: tmp_dir],
      terminal_states: ["Done", "Canceled"],
      records_repo: repo
    ]

    %{repo: repo, ticket: ticket, blocker: blocker, other: other, done: done, opts: opts}
  end

  defp put(repo, n, attrs) do
    record = Map.merge(%{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "BLK-#{n}"}, attrs)
    :ok = RunStore.put_ticket_state(record)
    record
  end

  # The records of the test's own repository only, so the other tests' tickets stay out.
  defp scoped(opts) do
    {repo, opts} = Keyword.pop(opts, :records_repo)
    Keyword.put(opts, :records, RunStore.list_ticket_states(repo))
  end

  defp record(%{issue_id: id}), do: id |> RunStore.get_ticket_state() |> TicketState.normalize()

  defp actions(%{issue_id: id}), do: id |> RunStore.list_ticket_events([]) |> Enum.filter(&(&1.type == "person.action"))

  defp change(action, ticket, blocker, opts), do: DirectorBlockers.change(action, ticket.issue_identifier, blocker.issue_identifier, scoped(opts))

  defp dependencies(ticket), do: Enum.map(record(ticket).depends_on, &{&1.issue_id, &1.identifier, &1.kind})

  test "the Director's add and remove store and remove a done dependency, with no Linear write", ctx do
    %{ticket: ticket, blocker: blocker, repo: repo} = ctx
    :ok = ObservabilityPubSub.subscribe_ticket_records()
    ticket_id = ticket.issue_id

    assert {:ok, payload} = change(:add, ticket, blocker, ctx.opts)

    assert payload == %{
             action: "add",
             issue_identifier: ticket.issue_identifier,
             blocker: blocker.issue_identifier,
             blockers: [%{issue_identifier: blocker.issue_identifier, title: "Fix the exporter", state: "In Progress"}]
           }

    assert dependencies(ticket) == [{blocker.issue_id, blocker.issue_identifier, :done}]
    # Nothing of Linear's: the observed blockers and the pause stay as they were.
    assert record(ticket).blockers == []
    assert TicketState.pause_reasons(record(ticket)) == []
    assert_received {:"$gen_cast", {:request_refresh, ^repo, :now}}
    assert_received {:ticket_record, ^repo, ^ticket_id, :changed, [:depends_on]}

    assert [%{type: "person.action", payload: %{action: "add_blocker", blocker: event_blocker}, actor: %{kind: :person, name: "the Director"}}] =
             actions(ticket)

    assert event_blocker == blocker.issue_identifier

    {:ok, stream} = SymphonyElixir.AuditLog.query(dir: ctx.tmp_dir, event_type: "director_move")
    assert [%{"move" => "add_blocker", "blocker" => audit_blocker}] = Enum.to_list(stream)
    assert audit_blocker == blocker.issue_identifier

    assert {:ok, %{action: "remove", blockers: []}} = change(:remove, ticket, blocker, ctx.opts)
    assert dependencies(ticket) == []
    assert record(ticket).blockers == []
    assert TicketState.pause_reasons(record(ticket)) == []
    assert [%{payload: %{action: "add_blocker"}}, %{payload: %{action: "remove_blocker"}}] = actions(ticket)
  end

  test "a blocker Linear's links name is neither listed nor counted", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    :ok = RunStore.update_ticket_state(blocker.issue_id, %{blockers: [%{id: ticket.issue_id, identifier: ticket.issue_identifier, state: "Todo"}]})
    :ok = RunStore.update_ticket_state(ticket.issue_id, %{blockers: [%{id: blocker.issue_id, identifier: blocker.issue_identifier, state: "In Progress"}]})

    assert {:ok, %{blockers: []}} = DirectorBlockers.blockers(ticket.issue_identifier, scoped(ctx.opts))
    assert {:error, {:conflict, _missing}} = change(:remove, ticket, blocker, ctx.opts)
    assert {:ok, %{blockers: [_stored]}} = change(:add, ticket, blocker, ctx.opts)
  end

  test "refuses a ticket blocking itself", ctx do
    assert {:error, {:conflict, message}} = change(:add, ctx.ticket, ctx.ticket, ctx.opts)
    assert message == "#{ctx.ticket.issue_identifier} can't block itself."
    assert dependencies(ctx.ticket) == []
  end

  test "refuses a dependency that would make a cycle, directly or through another ticket", ctx do
    %{ticket: ticket, blocker: blocker, other: other} = ctx
    assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)
    assert {:ok, _added} = change(:add, blocker, other, ctx.opts)

    assert {:error, {:conflict, direct}} = change(:add, blocker, ticket, ctx.opts)
    assert direct =~ "#{ticket.issue_identifier} already waits on #{blocker.issue_identifier}"
    assert direct =~ "would make a cycle"

    assert {:error, {:conflict, through}} = change(:add, other, ticket, ctx.opts)
    assert through =~ "would make a cycle"
    assert dependencies(other) == []
  end

  test "refuses a ticket Symphony doesn't track, on either side", ctx do
    opts = scoped(ctx.opts)
    assert {:error, {:conflict, message}} = DirectorBlockers.change(:add, ctx.ticket.issue_identifier, "ZZZ-404", opts)
    assert message == "Symphony doesn't track ZZZ-404, so it can't be linked as a blocker or be given one."
    assert {:error, {:conflict, _message}} = DirectorBlockers.change(:add, "ZZZ-404", ctx.blocker.issue_identifier, opts)
    assert {:error, {:conflict, _message}} = DirectorBlockers.change(:remove, "ZZZ-404", "ZZZ-405")
  end

  test "refuses a finished blocker, a dependency already there and one that isn't", ctx do
    %{ticket: ticket, blocker: blocker, done: done} = ctx

    assert {:error, {:conflict, finished}} = change(:add, ticket, done, ctx.opts)
    assert finished == "#{done.issue_identifier} is Done: a finished ticket blocks nothing."

    assert {:error, {:conflict, missing}} = change(:remove, ticket, blocker, ctx.opts)
    assert missing == "#{blocker.issue_identifier} doesn't block #{ticket.issue_identifier}."

    assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)
    assert {:error, {:conflict, twice}} = change(:add, ticket, blocker, ctx.opts)
    assert twice == "#{blocker.issue_identifier} already blocks #{ticket.issue_identifier}."
  end

  @tag :capture_log
  test "a write the store refuses changes nothing and says so", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    # The record the read gave is gone from the store by the time of the write.
    opts = scoped(ctx.opts)
    :ok = RunStore.delete_ticket_state(ticket.issue_id)

    assert {:error, {:store, message}} = DirectorBlockers.change(:add, ticket.issue_identifier, blocker.issue_identifier, opts)
    assert message == "Symphony couldn't add #{blocker.issue_identifier} as a blocker of #{ticket.issue_identifier}, so nothing changed. Try again in a moment."

    ghost = %{
      repo_key: ctx.repo,
      issue_id: "#{ticket.issue_id}-ghost",
      issue_identifier: "#{ticket.issue_identifier}9",
      depends_on: [%{issue_id: blocker.issue_id, identifier: blocker.issue_identifier, kind: :done}]
    }

    records = [ghost | Keyword.fetch!(opts, :records)]

    assert {:error, {:store, removed}} = DirectorBlockers.change(:remove, ghost.issue_identifier, blocker.issue_identifier, Keyword.put(opts, :records, records))
    assert removed =~ "Symphony couldn't remove #{blocker.issue_identifier} as a blocker of #{ghost.issue_identifier}"
    assert RunStore.list_ticket_events(ticket.issue_id, []) == []
  end

  test "names a ticket by id or by identifier in any case, and skips a removed record", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    # A record without an identifier is passed over when a ticket is named by identifier.
    put(ctx.repo, "#{System.unique_integer([:positive])}", %{issue_identifier: nil, phase: "Todo"})
    opts = scoped(ctx.opts)
    assert {:error, {:conflict, _untracked}} = DirectorBlockers.change(:add, ticket.issue_identifier, "BLK-0", opts)
    assert {:ok, %{blocker: blocker_identifier}} = DirectorBlockers.change(:add, ticket.issue_id, String.downcase(blocker.issue_identifier), opts)
    assert blocker_identifier == blocker.issue_identifier

    :ok = RunStore.update_ticket_state(ctx.other.issue_id, %{removed_at: DateTime.utc_now()})
    assert {:error, {:conflict, _untracked}} = DirectorBlockers.change(:add, ticket.issue_identifier, ctx.other.issue_identifier, scoped(ctx.opts))
  end

  test "logs an audit record it can't write and still makes the change", ctx do
    file = Path.join(ctx.tmp_dir, "file")
    File.write!(file, "")
    opts = Keyword.put(ctx.opts, :audit_log, dir: Path.join(file, "audit"))

    log = capture_log(fn -> assert {:ok, _added} = change(:add, ctx.ticket, ctx.blocker, opts) end)
    assert log =~ "Failed to record director_move audit event: issue_id=#{ctx.ticket.issue_id}"
  end

  describe "blockers/2" do
    test "lists the ticket's stored dependencies and the open tickets it can be given, in identifier order", ctx do
      %{ticket: ticket, blocker: blocker, other: other} = ctx
      assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)
      # A ticket of another repository, outside the records read: listed by the identifier stored.
      elsewhere = put("#{ctx.repo}-elsewhere", "#{System.unique_integer([:positive])}", %{phase: "Todo"})
      :ok = RunStore.add_dependency(ticket.issue_id, elsewhere.issue_id, :done)

      assert {:ok, payload} = DirectorBlockers.blockers(ticket.issue_identifier, scoped(ctx.opts))

      assert payload == %{
               issue_identifier: ticket.issue_identifier,
               blockers: [
                 %{issue_identifier: blocker.issue_identifier, title: "Fix the exporter", state: "In Progress"},
                 %{issue_identifier: elsewhere.issue_identifier, title: nil, state: nil}
               ],
               candidates: [%{issue_identifier: other.issue_identifier, title: "Rename the button", state: "Todo"}]
             }
    end

    test "sorts candidates by team, then number", ctx do
      repo = "blockers-sort-#{System.unique_integer([:positive])}"

      for {id, identifier} <- [{"a", "ABC-10"}, {"b", "ABC-9"}, {"c", "odd"}, {"d", "ABC-1"}] do
        put(repo, "#{repo}-#{id}", %{issue_identifier: identifier, phase: "Todo"})
      end

      # A record no read gave a phase yet is open.
      :ok = RunStore.update_ticket_state("issue-#{repo}-c", %{phase: nil})

      opts = Keyword.put(ctx.opts, :records, RunStore.list_ticket_states(repo))
      assert {:ok, %{candidates: candidates}} = DirectorBlockers.blockers("ABC-1", opts)
      assert Enum.map(candidates, & &1.issue_identifier) == ["ABC-9", "ABC-10", "odd"]
    end

    test "refuses a ticket Symphony doesn't track", ctx do
      assert {:error, {:conflict, _message}} = DirectorBlockers.blockers("ZZZ-404", scoped(ctx.opts))
    end

    test "reads every repository's records and the settings' states by default", ctx do
      assert {:ok, %{issue_identifier: identifier}} = DirectorBlockers.blockers(ctx.ticket.issue_identifier)
      assert identifier == ctx.ticket.issue_identifier
    end
  end
end
