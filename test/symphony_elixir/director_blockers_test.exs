defmodule SymphonyElixir.DirectorBlockersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{DirectorBlockers, RunStore, TicketState}

  @moduletag :tmp_dir

  defmodule Linker do
    @moduledoc false
    def add_blocked_by(blocker, issue_id), do: reply({:add, blocker, issue_id})
    def remove_blocked_by(blocker, issue_id), do: reply({:remove, blocker, issue_id})

    defp reply(call) do
      send(self(), {:linker, call})
      Process.get(:linker_reply, :ok)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    repo = "blockers-#{n}"
    put = fn suffix, attrs -> put(repo, "#{n}#{suffix}", attrs) end

    ticket = put.("1", %{phase: "Todo", title: "Export the report"})
    blocker = put.("2", %{phase: "In Progress", title: "Fix the exporter"})
    other = put.("3", %{phase: "Todo", title: "Rename the button"})
    done = put.("4", %{phase: "Done", title: "Old work"})

    opts = [
      linker: Linker,
      orchestrator: self(),
      audit_log: [dir: tmp_dir],
      terminal_states: ["Done", "Canceled"],
      active_states: ["Todo", "In Progress", "Rework"],
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

  test "adds a blocker: Linear first, then the record, the pause, the event, the audit and a refresh at once", ctx do
    %{ticket: ticket, blocker: blocker, repo: repo} = ctx

    assert {:ok, payload} = change(:add, ticket, blocker, ctx.opts)

    assert payload == %{
             action: "add",
             issue_identifier: ticket.issue_identifier,
             blocker: blocker.issue_identifier,
             blockers: [%{issue_identifier: blocker.issue_identifier, title: "Fix the exporter", state: "In Progress"}]
           }

    assert_received {:linker, {:add, blocker_id, ticket_id}}
    assert {blocker_id, ticket_id} == {blocker.issue_id, ticket.issue_id}
    assert_received {:"$gen_cast", {:request_refresh, ^repo, :now}}

    assert [%{id: blocker_id, identifier: blocker_identifier, state: "In Progress"}] = record(ticket).blockers
    assert {blocker_id, blocker_identifier} == {blocker.issue_id, blocker.issue_identifier}

    assert [%{kind: :ticket, waits_on: %{identifier: waits_on}}] = TicketState.pause_reasons(record(ticket))
    assert waits_on == blocker.issue_identifier

    assert [%{type: "person.action", payload: %{action: "add_blocker", blocker: event_blocker}, actor: %{kind: :person, name: "the Director"}}] =
             actions(ticket)

    assert event_blocker == blocker.issue_identifier

    {:ok, stream} = SymphonyElixir.AuditLog.query(dir: ctx.tmp_dir, event_type: "director_move")
    assert [%{"move" => "add_blocker", "blocker" => audit_blocker}] = Enum.to_list(stream)
    assert audit_blocker == blocker.issue_identifier
  end

  test "removes a blocker: the link goes from Linear and the record, and the ticket no longer waits for it", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)

    assert {:ok, %{action: "remove", blockers: []}} = change(:remove, ticket, blocker, ctx.opts)

    assert_received {:linker, {:remove, _blocker_id, _ticket_id}}
    assert record(ticket).blockers == []
    assert TicketState.pause_reasons(record(ticket)) == []

    assert [%{payload: %{action: "add_blocker"}}, %{payload: %{action: "remove_blocker"}}] = actions(ticket)
  end

  test "an added blocker outside an active phase leaves the pause alone", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    assert {:ok, _added} = change(:add, ticket, blocker, Keyword.put(ctx.opts, :active_states, ["Rework"]))
    assert TicketState.pause_reasons(record(ticket)) == []
  end

  test "refuses a ticket blocking itself", ctx do
    assert {:error, {:conflict, message}} = change(:add, ctx.ticket, ctx.ticket, ctx.opts)
    assert message == "#{ctx.ticket.issue_identifier} can't block itself."
    refute_received {:linker, _call}
  end

  test "refuses a link that would make a cycle, directly or through another ticket", ctx do
    %{ticket: ticket, blocker: blocker, other: other} = ctx
    assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)
    assert {:ok, _added} = change(:add, blocker, other, ctx.opts)

    assert {:error, {:conflict, direct}} = change(:add, blocker, ticket, ctx.opts)
    assert direct =~ "#{ticket.issue_identifier} already waits on #{blocker.issue_identifier}"
    assert direct =~ "would make a cycle"

    assert {:error, {:conflict, through}} = change(:add, other, ticket, ctx.opts)
    assert through =~ "would make a cycle"
  end

  test "a blocker known by identifier only still closes a cycle", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    :ok = RunStore.update_ticket_state(blocker.issue_id, %{blockers: [ticket.issue_identifier]})

    assert {:error, {:conflict, message}} = change(:add, ticket, blocker, ctx.opts)
    assert message =~ "would make a cycle"
  end

  test "refuses a ticket Symphony doesn't track, on either side", ctx do
    opts = scoped(ctx.opts)
    assert {:error, {:conflict, message}} = DirectorBlockers.change(:add, ctx.ticket.issue_identifier, "ZZZ-404", opts)
    assert message == "Symphony doesn't track ZZZ-404, so it can't be linked as a blocker or be given one."
    assert {:error, {:conflict, _message}} = DirectorBlockers.change(:add, "ZZZ-404", ctx.blocker.issue_identifier, opts)
    assert {:error, {:conflict, _message}} = DirectorBlockers.change(:remove, "ZZZ-404", "ZZZ-405")
  end

  test "refuses a finished blocker, a link already there and one that isn't", ctx do
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
  test "a write Linear refuses changes nothing", ctx do
    Process.put(:linker_reply, {:error, :issue_relation_failed})
    assert {:error, {:linear, message}} = change(:add, ctx.ticket, ctx.blocker, ctx.opts)
    assert message == "Linear didn't add the link #{ctx.blocker.issue_identifier} blocks #{ctx.ticket.issue_identifier}, so nothing changed. Try again in a moment."
    assert record(ctx.ticket).blockers == []
    assert RunStore.list_ticket_events(ctx.ticket.issue_id, []) == []
  end

  @tag :capture_log
  test "a write refused for a missing Linear key says so in plain words", ctx do
    assert {:ok, _added} = change(:add, ctx.ticket, ctx.blocker, ctx.opts)

    for reason <- [:missing_linear_api_token, {:linear_api_request, :missing_linear_api_token}] do
      Process.put(:linker_reply, {:error, reason})
      assert {:error, {:linear, message}} = change(:remove, ctx.ticket, ctx.blocker, ctx.opts)
      assert message == "Symphony has no Linear API key, so it couldn't remove the link #{ctx.blocker.issue_identifier} blocks #{ctx.ticket.issue_identifier} in Linear."
    end
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

  test "a record that can't be written still answers the change Linear took", ctx do
    %{ticket: ticket, blocker: blocker} = ctx
    opts = scoped(ctx.opts)
    :ok = RunStore.delete_ticket_state(ticket.issue_id)

    log = capture_log(fn -> assert {:ok, %{blockers: [_blocker]}} = DirectorBlockers.change(:add, ticket.issue_identifier, blocker.issue_identifier, opts) end)
    assert log =~ "Failed to write the blockers of issue_id=#{ticket.issue_id}"
  end

  test "logs an audit record it can't write and still makes the change", ctx do
    file = Path.join(ctx.tmp_dir, "file")
    File.write!(file, "")
    opts = Keyword.put(ctx.opts, :audit_log, dir: Path.join(file, "audit"))

    log = capture_log(fn -> assert {:ok, _added} = change(:add, ctx.ticket, ctx.blocker, opts) end)
    assert log =~ "Failed to record director_move audit event: issue_id=#{ctx.ticket.issue_id}"
  end

  describe "blockers/2" do
    test "lists the ticket's blockers and the open tickets it can be given, in identifier order", ctx do
      %{ticket: ticket, blocker: blocker, other: other} = ctx
      assert {:ok, _added} = change(:add, ticket, blocker, ctx.opts)
      external = %{identifier: "EXT-1", state: "Todo"}
      :ok = RunStore.update_ticket_state(ticket.issue_id, %{blockers: record(ticket).blockers ++ [external]})

      assert {:ok, payload} = DirectorBlockers.blockers(ticket.issue_identifier, scoped(ctx.opts))

      assert payload == %{
               issue_identifier: ticket.issue_identifier,
               blockers: [
                 %{issue_identifier: blocker.issue_identifier, title: "Fix the exporter", state: "In Progress"},
                 %{issue_identifier: "EXT-1", title: nil, state: "Todo"}
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
