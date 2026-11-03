defmodule SymphonyElixir.DirectorRulingsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AuditLog, Decisions, DirectorRulings, RunStore}

  @moduletag :tmp_dir

  defmodule Tracker do
    @moduledoc false
    def fetch_issue_description(issue_id) do
      send(self(), {:tracker, :fetch, issue_id})
      Process.get(:description_reply, {:ok, "Ship the export."})
    end

    def update_issue_description(issue_id, description) do
      send(self(), {:tracker, :update, issue_id, description})
      Process.put(:description_reply, {:ok, description})
      Process.get(:update_reply, :ok)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    repo = "rulings-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "RUL-#{n}", phase: "In Progress", title: "Export"}
    :ok = RunStore.put_ticket_state(ticket)

    records = RunStore.list_ticket_states(repo)
    opts = [tracker: Tracker, orchestrator: self(), audit_log: [dir: tmp_dir], records: records, today: ~D[2026-11-03]]
    %{repo: repo, ticket: ticket, opts: opts}
  end

  defp events(%{issue_id: id}, type), do: id |> RunStore.list_ticket_events([]) |> Enum.filter(&(&1.type == type))

  defp stored(ticket), do: Decisions.stored(%{id: ticket.issue_id, repo_key: ticket.repo_key, description: nil})

  test "records a ruling: the record, the Decisions section in Linear, the event, the audit and a refresh", ctx do
    %{ticket: ticket, repo: repo} = ctx
    text = "Keep the old endpoint until TP-1400 lands"

    assert {:ok, payload} = DirectorRulings.record(ticket.issue_identifier, "  #{text}  ", ctx.opts)
    assert payload.action == "record_decision"
    assert payload.issue_identifier == ticket.issue_identifier
    assert [%{id: "D1", date: "2026-11-03", title: "Ruling by the Director", answer: ^text, scope: "As answered"}] = payload.decisions

    issue_id = ticket.issue_id
    assert_received {:tracker, :update, ^issue_id, description}
    assert description =~ "Ship the export."
    assert [%{id: "D1", answer: ^text, key: "ruling-director-" <> _id}] = Decisions.recorded(description)
    assert_received {:"$gen_cast", {:request_refresh, ^repo, :now}}

    # The record holds it as a decision, so the ticket's next run reads it among its decisions.
    assert [%{id: "D1", answer: ^text}] = stored(ticket)
    assert Decisions.prompt_section(stored(ticket)) =~ "D1: No question asked: the Director recorded this ruling on the ticket page. Answer: #{text}"

    assert [%{actor: %{kind: :person}, payload: event_payload, summary: %{title: "The Director ruled"}}] = events(ticket, "decision.recorded")
    assert %{answer: ^text, key: "ruling-director-" <> _id} = event_payload

    refute Map.has_key?(event_payload, :request)

    {:ok, stream} = AuditLog.query(dir: ctx.tmp_dir, event_type: "director_move")
    assert [%{"move" => "record_decision", "comment" => ^text, "issue_identifier" => _}] = Enum.to_list(stream)
  end

  test "a second ruling goes after the first, and the same text again is refused", ctx do
    assert {:ok, _payload} = DirectorRulings.record(ctx.ticket.issue_id, "Keep the old endpoint", ctx.opts)
    assert {:ok, payload} = DirectorRulings.record(ctx.ticket.issue_identifier, "Drop the CSV option", ctx.opts)
    assert Enum.map(payload.decisions, &{&1.id, &1.answer}) == [{"D1", "Keep the old endpoint"}, {"D2", "Drop the CSV option"}]

    assert {:error, {:conflict, message}} = DirectorRulings.record(String.downcase(ctx.ticket.issue_identifier), "keep  the old endpoint", ctx.opts)
    assert message == "#{ctx.ticket.issue_identifier} already has this decision (D1)."
    assert length(events(ctx.ticket, "decision.recorded")) == 2
  end

  test "refuses a blank, missing or too long text, writing nothing", ctx do
    for text <- ["", "   \n ", nil] do
      assert {:error, {:invalid, "A decision needs text"}} = DirectorRulings.record(ctx.ticket.issue_identifier, text, ctx.opts)
    end

    long = String.duplicate("a", DirectorRulings.max_chars() + 1)
    assert {:error, {:invalid, "A decision holds at most 600 characters; this one has 601"}} = DirectorRulings.record(ctx.ticket.issue_identifier, long, ctx.opts)

    refute_received {:tracker, _action, _issue_id, _description}
    assert stored(ctx.ticket) == []
    assert events(ctx.ticket, "decision.recorded") == []
  end

  test "refuses a ticket Symphony doesn't track, and a removed one", ctx do
    assert {:error, {:conflict, "Symphony doesn't track NOPE-1, so it can't record a decision on it."}} =
             DirectorRulings.record("NOPE-1", "Keep it", ctx.opts)

    removed = [
      %{repo_key: ctx.repo, issue_id: "gone", issue_identifier: "GONE-1", removed_at: DateTime.utc_now()},
      %{issue_identifier: "BAD-1"},
      %{repo_key: ctx.repo, issue_id: "unnamed", issue_identifier: nil}
    ]

    assert {:error, {:conflict, _message}} = DirectorRulings.record("GONE-1", "Keep it", Keyword.put(ctx.opts, :records, removed))
    assert {:error, {:conflict, _message}} = DirectorRulings.decisions("NOPE-1", ctx.opts)
  end

  test "a write Linear refuses is answered in the app's words", ctx do
    replies = [
      {{:error, :missing_linear_api_token}, "Symphony has no Linear API key, so it couldn't record the decision on #{ctx.ticket.issue_identifier}."},
      {{:error, {:linear_api_request, :missing_linear_api_token}}, "Symphony has no Linear API key"},
      {{:ok, "Text\n\n#{Decisions.start_marker()}\n- lost"}, "has lost its end marker"},
      {{:error, :timeout}, "Symphony couldn't record the decision on #{ctx.ticket.issue_identifier}, so nothing changed. Try again in a moment."}
    ]

    for {{reply, expected}, index} <- Enum.with_index(replies) do
      Process.put(:description_reply, reply)

      log =
        capture_log(fn ->
          assert {:error, {:linear, message}} = DirectorRulings.record(ctx.ticket.issue_identifier, "Ruling #{index}", ctx.opts)
          assert message =~ expected
        end)

      assert log =~ "Failed to record decisions"
    end

    assert events(ctx.ticket, "decision.recorded") == []
  end

  test "lists the ticket's decisions, a Decide answer and a ruling alike, by identifier or id", ctx do
    answer = Decisions.entry("comment-1", ~D[2026-11-01], "Scope", "Ship CSV too?", "Yes, ship CSV")
    :ok = Decisions.record(ctx.ticket.issue_id, [answer], repo_key: ctx.repo, tracker: Tracker)
    assert {:ok, _payload} = DirectorRulings.record(ctx.ticket.issue_identifier, "Keep the old endpoint", ctx.opts)

    assert {:ok, %{issue_identifier: identifier, decisions: decisions}} = DirectorRulings.decisions(ctx.ticket.issue_id, ctx.opts)
    assert identifier == ctx.ticket.issue_identifier
    assert [%{id: "D1", date: "2026-11-01", question: "Ship CSV too?", answer: "Yes, ship CSV"}, %{id: "D2", answer: "Keep the old endpoint"}] = decisions
  end

  test "the options default to every tracked record, and a stored date that isn't a day reads as given", ctx do
    assert {:error, {:invalid, "A decision needs text"}} = DirectorRulings.record(ctx.ticket.issue_identifier, " ")

    entry = %{key: "comment-9", date: "someday", title: "Old", question: "Old?", answer: "Kept", scope: "As answered"}
    {:ok, _decisions} = RunStore.record_ticket_decisions(ctx.repo, ctx.ticket.issue_id, [entry], [])

    assert {:ok, %{decisions: [%{id: "D1", date: "someday", answer: "Kept"}]}} = DirectorRulings.decisions(ctx.ticket.issue_identifier)
  end

  test "an audit log that can't be written leaves the ruling recorded", ctx do
    path = Path.join(ctx.tmp_dir, "not-a-dir")
    File.write!(path, "")

    log = capture_log(fn -> assert {:ok, _payload} = DirectorRulings.record(ctx.ticket.issue_identifier, "Keep it", Keyword.put(ctx.opts, :audit_log, dir: path)) end)
    assert log =~ "Failed to record director_move audit event"
    assert [%{answer: "Keep it"}] = stored(ctx.ticket)
  end
end
