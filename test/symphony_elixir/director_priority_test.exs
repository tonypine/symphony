defmodule SymphonyElixir.DirectorPriorityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AuditLog, Config, DirectorPriority, RunStore, TicketState}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Dispatch.Candidates

  @moduletag :tmp_dir

  defmodule Writer do
    @moduledoc false
    def update_issue_priority(issue_id, priority) do
      send(self(), {:tracker, issue_id, priority})
      Process.get(:tracker_reply, :ok)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    repo = "priority-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "PRI-#{n}", phase: "Todo", title: "Export", priority: 4}
    :ok = RunStore.put_ticket_state(ticket)
    records = RunStore.list_ticket_states(repo)
    opts = [tracker: Writer, orchestrator: self(), audit_log: [dir: tmp_dir], records: records]
    %{repo: repo, ticket: ticket, opts: opts}
  end

  defp record(%{issue_id: id}), do: id |> RunStore.get_ticket_state() |> TicketState.normalize()

  defp actions(%{issue_id: id}), do: id |> RunStore.list_ticket_events([]) |> Enum.filter(&(&1.type == "person.action"))

  defp refresh_opts(ctx), do: Keyword.put(ctx.opts, :records, RunStore.list_ticket_states(ctx.repo))

  # Whether `tickets.priorities: [urgent]`, this repo's setting, lets the ticket's record start new work.
  defp picked?(ticket) do
    allowed = Config.ticket_priority_filter(%Schema{tickets: %Schema.Tickets{priorities: ["urgent"]}})
    MapSet.member?(allowed, Candidates.issue_from_record(record(ticket)).priority || 0)
  end

  test "sets a ticket's priority: Linear first, then the record, the event, the audit and a refresh at once", ctx do
    %{ticket: ticket, repo: repo} = ctx
    refute picked?(ticket)

    assert {:ok, payload} = DirectorPriority.set(ticket.issue_identifier, "Urgent", ctx.opts)

    assert payload == %{
             action: "set_priority",
             issue_identifier: ticket.issue_identifier,
             priority: "urgent",
             priority_value: 1,
             priorities: ~w(none urgent high medium low)
           }

    assert_received {:tracker, issue_id, 1}
    assert issue_id == ticket.issue_id
    assert_received {:"$gen_cast", {:request_refresh, ^repo, :now}}
    assert record(ticket).priority == 1
    assert picked?(ticket)

    assert [%{payload: %{action: "set_priority", from: "Low", to: "Urgent"}, summary: %{title: "The Director set the priority to Urgent", detail: "from Low"}}] = actions(ticket)

    {:ok, stream} = AuditLog.query(dir: ctx.tmp_dir, event_type: "director_move")
    assert [%{"move" => "set_priority", "priority" => "Urgent", "from_priority" => "Low"}] = Enum.to_list(stream)
  end

  test "setting it back to Low takes the ticket out of the picks", ctx do
    assert {:ok, %{priority: "urgent"}} = DirectorPriority.set(ctx.ticket.issue_identifier, "urgent", ctx.opts)
    assert picked?(ctx.ticket)

    assert {:ok, %{priority: "low", priority_value: 4}} = DirectorPriority.set(ctx.ticket.issue_id, "4", refresh_opts(ctx))
    refute picked?(ctx.ticket)
    assert Enum.map(actions(ctx.ticket), & &1.payload.to) |> Enum.sort() == ["Low", "Urgent"]
  end

  test "takes Linear's number and every name, case and space aside", ctx do
    for {value, number} <- [{0, 0}, {" High ", 2}, {"MEDIUM", 3}, {"none", 0}, {"1", 1}] do
      ticket = %{ctx.ticket | priority: 4}
      opts = Keyword.put(ctx.opts, :records, [ticket])
      assert {:ok, %{priority_value: ^number}} = DirectorPriority.set(ticket.issue_identifier, value, opts)
    end
  end

  test "refuses an unknown value, an untracked ticket and the priority the ticket already has, changing nothing", ctx do
    for value <- ["critical", "5", 7, nil] do
      assert {:error, {:invalid, message}} = DirectorPriority.set(ctx.ticket.issue_identifier, value, ctx.opts)
      assert message =~ "is not a Linear priority: use one of none, urgent, high, medium, low."
    end

    assert {:error, {:conflict, "Symphony doesn't track ZZZ-1, so it can't set its priority."}} =
             DirectorPriority.set("ZZZ-1", "urgent", ctx.opts)

    assert {:error, {:conflict, message}} = DirectorPriority.set(ctx.ticket.issue_identifier, "low", ctx.opts)
    assert message == "#{ctx.ticket.issue_identifier} is already Low."

    refute_received {:tracker, _issue_id, _priority}
    assert record(ctx.ticket).priority == 4
    assert actions(ctx.ticket) == []
  end

  test "a write Linear refuses changes nothing and says why", ctx do
    Process.put(:tracker_reply, {:error, :issue_update_failed})

    log =
      capture_log(fn ->
        assert {:error, {:linear, message}} = DirectorPriority.set(ctx.ticket.issue_identifier, "urgent", ctx.opts)
        assert message == "Linear didn't set #{ctx.ticket.issue_identifier} to Urgent, so nothing changed. Try again in a moment."
      end)

    assert log =~ "Failed to write a priority"

    Process.put(:tracker_reply, {:error, {:linear_api_request, :missing_linear_api_token}})

    capture_log(fn ->
      assert {:error, {:linear, message}} = DirectorPriority.set(ctx.ticket.issue_identifier, "urgent", ctx.opts)
      assert message =~ "Symphony has no Linear API key"
    end)

    Process.put(:tracker_reply, {:error, :missing_linear_api_token})

    capture_log(fn -> assert {:error, {:linear, "Symphony has no Linear API key" <> _}} = DirectorPriority.set(ctx.ticket.issue_id, "high", ctx.opts) end)

    assert record(ctx.ticket).priority == 4
    assert actions(ctx.ticket) == []
  end

  test "a record that can't be written or an audit log that can't is logged, and the move still answers", ctx do
    ghost = %{ctx.ticket | issue_id: "ghost-#{System.unique_integer([:positive])}", priority: nil}

    log =
      capture_log(fn ->
        opts = ctx.opts |> Keyword.put(:records, [ghost]) |> Keyword.put(:audit_log, dir: "/dev/null/audit")
        assert {:ok, %{priority: "high"}} = DirectorPriority.set(ghost.issue_identifier, "high", opts)
      end)

    assert log =~ "Failed to write the priority of issue_id=#{ghost.issue_id}"
    assert log =~ "Failed to record director_move audit event"
  end

  test "reads the priority as the record holds it; a ticket without one reads as none", ctx do
    assert {:ok, %{priority: "low", priority_value: 4, issue_identifier: identifier}} =
             DirectorPriority.priority(String.downcase(ctx.ticket.issue_identifier), ctx.opts)

    assert identifier == ctx.ticket.issue_identifier

    none = %{ctx.ticket | priority: nil}
    assert {:ok, %{priority: "none", priority_value: nil}} = DirectorPriority.priority(none.issue_id, records: [none])
    assert {:error, {:conflict, _message}} = DirectorPriority.priority("ZZZ-1", ctx.opts)
    assert DirectorPriority.names() == ~w(none urgent high medium low)
  end

  test "reads the run store's records by default" do
    n = System.unique_integer([:positive])
    :ok = RunStore.put_ticket_state(%{repo_key: "priority-default-#{n}", issue_id: "issue-d-#{n}", issue_identifier: "PRD-#{n}", priority: 2})
    assert {:ok, %{priority: "high"}} = DirectorPriority.priority("PRD-#{n}")
    # A record without an identifier is found by its id only.
    :ok = RunStore.put_ticket_state(%{repo_key: "priority-default-#{n}", issue_id: "issue-e-#{n}", priority: 2})
    assert {:error, {:conflict, _message}} = DirectorPriority.set("PRD-none-#{n}", "urgent")
    assert {:error, {:conflict, _message}} = DirectorPriority.set("issue-e-#{n}", "high")
  end
end
