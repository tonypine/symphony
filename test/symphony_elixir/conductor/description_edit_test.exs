defmodule SymphonyElixir.Conductor.DescriptionEditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Conductor.{DescriptionEdit, Facts, Message}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{IssueSummary, Messages, TicketChecks, TicketPlan, TicketProjection}

  @on %Schema.Conductor{enabled: true}
  @projected %{labels: [], section: nil, comments: nil, described: true}

  setup do
    n = System.unique_integer([:positive])
    issue_id = "issue-edit-#{n}"
    record = %{repo_key: "default", issue_id: issue_id, issue_identifier: "EDIT-#{n}", phase: "Todo", title: "Filters", projected: @projected}
    :ok = RunStore.put_ticket_state(record)
    {:ok, _ask} = TicketPlan.record_ask("default", issue_id, "Keep my filter.")

    plan = %{
      shape: "single",
      layers: ["logic"],
      summary: "The list keeps its filter.",
      text: "Approach: store the filter.",
      checks: [%{id: "c1", kind: "outcome", statement: "The filter survives a reload.", proof: "test"}],
      size: %{tokens: 1, runs: 1},
      reason: "Grooming",
      by: "grooming"
    }

    {:ok, _plan} = TicketPlan.write("default", issue_id, plan)
    %{record: record, issue_id: issue_id}
  end

  # The description as Symphony writes it: the projection, above its own blocks.
  defp written(issue_id, extra \\ "") do
    text = TicketProjection.render(Facts.events(issue_id)) <> extra
    "#{TicketProjection.put("", text)}\n\n#{IssueSummary.start_marker()}\nPR open.\n#{IssueSummary.end_marker()}"
  end

  defp messages(issue_id), do: issue_id |> Facts.events() |> Messages.messages()

  defp turns(reply) do
    test = self()

    fn plan, _issue, _run_id, prompt ->
      send(test, {:turn, plan.junction, prompt})
      reply
    end
  end

  defp conductor(reply), do: [conductor: [settings: @on, turn: turns(reply), start: fn task -> task.() end, running: fn _id -> nil end]]

  defp facts_of(prompt), do: prompt |> String.split("carries that event's id):\n\n") |> List.last() |> Jason.decode!()

  test "Symphony's own writes are never an edit: the projection now, an older one, the summary block", ctx do
    assert DescriptionEdit.observed("default", ctx.record, written(ctx.issue_id), conductor(nil)) == :ok
    older = written(ctx.issue_id)
    {:ok, _proof} = TicketChecks.prove("default", ctx.issue_id, %{check_id: "c1", by: "test", test: "list_test › keeps the filter"})

    # A plan version or a proof newer than what Linear holds leaves Symphony's older text there.
    assert DescriptionEdit.observed("default", ctx.record, older, conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", ctx.record, written(ctx.issue_id), conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", ctx.record, "Keep my filter.", conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", ctx.record, "", conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", ctx.record, nil, conductor(nil)) == :ok

    assert messages(ctx.issue_id) == []
    refute_received {:turn, _junction, _prompt}
  end

  test "a person's edit goes to the Conductor as a message, once, and the words it adds become the ask", ctx do
    edited = written(ctx.issue_id, "\n\nKeep the sort order too.")

    plan = %{
      "reason" => "The edit adds the sort order.",
      "shape" => "single",
      "layers" => ["logic"],
      "summary" => "The list keeps its filter and its sort order.",
      "text" => "Approach: store both.",
      "checks" => [%{"id" => "c1", "kind" => "outcome", "statement" => "The filter survives a reload.", "proof" => "test"}],
      "size" => %{"tokens" => 1, "runs" => 1}
    }

    reply = {:ok, [Jason.encode!(%{"update" => "I added the sort order.", "ask" => true, "added" => "Keep the sort order too.", "plan" => plan})], 900}
    assert DescriptionEdit.observed("default", ctx.record, edited, conductor(reply)) == :ok

    assert [%{payload: %{source: "linear_description", text: text}, actor: actor} = message] = messages(ctx.issue_id)
    assert text == TicketProjection.person_text(edited)
    assert Messages.writer(actor) == DescriptionEdit.writer()

    assert_received {:turn, "message", prompt}
    facts = facts_of(prompt)
    assert facts["message"]["source"] == "linear_description"
    assert facts["rules"] =~ "whole Linear description"

    message_id = message.id
    assert [%{parent: ^message_id, payload: %{text: "I added the sort order."}}] = ctx.issue_id |> Facts.events() |> Enum.filter(&(&1.type == "conductor.update"))
    assert [_linear, %{source: "message", from: ^message_id, text: "Keep the sort order too."}] = TicketPlan.ask(ctx.issue_id)

    # The same edit, seen again (another delivery, a poll), is not given twice.
    assert DescriptionEdit.observed("default", ctx.record, edited, conductor(reply)) == :ok
    assert [_once] = messages(ctx.issue_id)
  end

  test "an answer that folds an edit in without naming what it adds is refused, and the turn is tried again", ctx do
    edited = written(ctx.issue_id, "\n\nAnd the search text.")
    checks = [%{"id" => "c1", "kind" => "outcome", "statement" => "The filter survives a reload.", "proof" => "test"}]
    plan = %{"shape" => "single", "layers" => ["logic"], "summary" => "Both.", "text" => "T.", "checks" => checks, "size" => %{"tokens" => 1, "runs" => 1}}
    reply = {:ok, [Jason.encode!(%{"update" => "Folded in.", "ask" => true, "plan" => plan})], 900}

    capture_log(fn -> assert DescriptionEdit.observed("default", ctx.record, edited, conductor(reply)) == :ok end)

    # The whole description, which holds Symphony's own projection, is never recorded as an ask.
    assert [%{source: "linear"}] = TicketPlan.ask(ctx.issue_id)
    assert %{version: 1} = TicketPlan.current(ctx.issue_id)
    assert ctx.issue_id |> Facts.events() |> Enum.filter(&(&1.type == "conductor.update")) == []
    assert [note] = for(%{type: "note", payload: %{status: true, text: text}} <- Facts.events(ctx.issue_id), do: text)
    assert note =~ "without `added`"
    assert [_message] = Message.owed(ctx.issue_id, settings: @on).messages
  end

  test "Symphony's own write as Linear gives it back (its list markers, escapes and blank lines) is no edit", ctx do
    {:ok, _proof} = TicketChecks.prove("default", ctx.issue_id, %{check_id: "c1", by: "test", test: "list_test › keeps_the_filter"})

    {:ok, _ask} = TicketPlan.record_ask("default", ctx.issue_id, "Use the *list_view* module.")

    projection =
      ctx.issue_id
      |> Facts.events()
      |> TicketProjection.render()
      |> String.replace(~r/^- /m, "* ")
      |> String.replace("[", "\\[")
      |> String.replace("]", "\\]")
      |> String.replace("_", "\\_")
      |> String.replace("*list", "_list")
      |> String.replace("view*", "view_")
      |> String.replace("\n\n", "\n\n\n")

    as_linear = "#{projection}\n\n#{IssueSummary.start_marker()}\nPR open.\n#{IssueSummary.end_marker()}"
    assert as_linear =~ "* \\[proved\\] c1"
    assert as_linear =~ "_list\\_view_"
    assert DescriptionEdit.observed("default", ctx.record, as_linear, conductor(nil)) == :ok
    assert messages(ctx.issue_id) == []

    # A person's words added to it are still an edit.
    assert TicketProjection.edited(as_linear <> "\n\nAnd the search text.", Facts.events(ctx.issue_id)) =~ "And the search text."
  end

  test "nothing before Symphony wrote the description, and an edit too long for a message is logged", ctx do
    unwritten = Map.delete(ctx.record, :projected)
    assert DescriptionEdit.observed("default", unwritten, "Keep my filter, and the sort order.", conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", %{}, "Anything.", conductor(nil)) == :ok
    assert DescriptionEdit.observed("default", unwritten, "Anything.") == :ok
    assert messages(ctx.issue_id) == []

    long = String.duplicate("x", 100_001)
    assert capture_log(fn -> assert DescriptionEdit.observed("default", ctx.record, long, conductor(nil)) == :ok end) =~ "Could not give a description edit"
    assert messages(ctx.issue_id) == []
  end

  test "a ticket with no plan has no projection, so its description holds no edit" do
    assert TicketProjection.edited("Anything a person wrote.", []) == nil
  end
end
