defmodule SymphonyElixir.Inbox.FromRecordTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox
  alias SymphonyElixir.Inbox.{FromRecord, Item}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{Pauses, PlanBrief, TicketState}

  @repo_key "inbox-from-record"
  @fixture "test/fixtures/inbox/situation.exs"
  @director %{kind: :person, name: "Director"}

  # The Linear writes the old path's hold sweep makes, kept off Linear.
  defmodule QuietTracker do
    def set_machine_label(_issue_id, _name), do: :ok
    def clear_machine_label(_issue_id, _name), do: :ok
    def fetch_issue_description(_issue_id), do: {:ok, "What it does."}
    def update_issue_description(_issue_id, _description), do: :ok
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> RunStore.clear() end)
    :ok
  end

  defp settings do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})
    settings
  end

  defp situation do
    {situation, _binding} = Code.eval_file(@fixture)
    situation
  end

  defp items(records, snapshot \\ %{}), do: FromRecord.items(records, snapshot, settings_fun: fn @repo_key -> settings() end)

  # What an observation of the node writes, at the move into its state, and what the fixture says
  # the record holds beside it.
  defp record(situation, node) do
    entered_at =
      node["history"]["nodes"]
      |> Enum.map(fn %{"createdAt" => at} -> at |> DateTime.from_iso8601() |> elem(1) end)
      |> Enum.max(DateTime)

    {record, :changed} = @repo_key |> TicketState.new(node["id"], %{}) |> TicketState.observe(Client.normalize_issue_for_test(node), entered_at)
    id = node["id"]

    record
    |> Map.merge(%{
      questions: Map.get(situation.questions, id, []),
      holds: List.wrap(Map.get(situation.holds, id)),
      pause: pause(situation, id),
      projected: %{labels: [], section: nil, comments: Map.get(situation.projected, id, %{})}
    })
    |> TicketState.normalize()
  end

  defp pause(situation, id) do
    case Map.get(situation.pauses, id) do
      nil -> nil
      pause -> Pauses.normalize(Map.put(pause, :subject, {:ticket, @repo_key, id}))
    end
  end

  # The plan's brief as Symphony captures it when the plan enters `Plan Review`.
  defp capture_plan_brief(record, node) do
    id = node["id"]
    client = fn _query, %{id: ^id}, _opts -> {:ok, %{"data" => %{"issue" => node}}} end
    :ok = RunStore.put_ticket_state(record)
    opts = [linear_client: client, settings: settings(), now: ~U[2026-10-20 07:00:30Z]]
    {:ok, brief} = PlanBrief.capture({@repo_key, record.issue_id}, opts)
    TicketState.normalize(%{record | plan_brief: brief})
  end

  defp records(situation) do
    for node <- situation.nodes do
      record = record(situation, node)
      if record.phase == "Plan Review", do: capture_plan_brief(record, node), else: record
    end
  end

  # A Linear stand-in serving the fixture nodes to the poller's list and detail queries, and
  # nothing to any other.
  defp linear(situation) do
    nodes = Map.new(situation.nodes, &{&1["id"], &1})
    light = for node <- situation.nodes, do: %{"id" => node["id"], "updatedAt" => "2026-10-20T12:00:00Z", "comments" => %{"nodes" => []}}

    fn query, variables, _opts ->
      cond do
        query =~ "SymphonyInboxList" -> {:ok, %{"data" => %{"issues" => %{"nodes" => light, "pageInfo" => %{"hasNextPage" => false}}}}}
        query =~ "SymphonyInboxIssues" -> {:ok, %{"data" => %{"issues" => %{"nodes" => Enum.map(variables.filter["id"]["in"], &nodes[&1])}}}}
        true -> {:ok, %{"data" => %{}}}
      end
    end
  end

  # The old path: the poller reads the fixture nodes from Linear, then the Inbox lists them.
  defp from_linear(situation) do
    name = {:test, make_ref()}

    Inbox.run_once(%{
      opts: [
        name: name,
        repos: fn -> {:ok, [%{name: @repo_key}]} end,
        settings_fun: fn _repo -> settings() end,
        scope_filter: fn _repo -> {:ok, %{"team" => %{"key" => %{"eq" => "SHOP"}}}} end,
        held_issue_ids: fn @repo_key -> {:ok, Map.keys(situation.holds)} end,
        hold: fn @repo_key, id -> Map.get(situation.holds, id) end,
        linear_client: linear(situation),
        snapshot: fn -> situation.snapshot end,
        github_repos: %{},
        tracker: QuietTracker
      ],
      nodes: %{},
      timer: make_ref()
    })

    Inbox.items(situation.snapshot, name)
  end

  # The fields both paths build: the `references` and `context` the References resolver reads from
  # Linear are left out, and so is each request's `question_id`.
  defp comparable(items), do: Enum.map(items, &(&1 |> Map.drop([:references, :context]) |> Map.update!(:review, fn review -> without_question_ids(review) end)))

  defp without_question_ids(%{decisions: decisions} = review), do: %{review | decisions: Enum.map(decisions, &Map.delete(&1, :question_id))}
  defp without_question_ids(review), do: Map.delete(review, :question_id)

  describe "the parity with today's Inbox" do
    test "the fixture's request comments are what the pause projector renders from its Questions" do
      situation = situation()

      for node <- situation.nodes, question <- Map.get(situation.questions, node["id"], []) do
        %{comment: comment_id} = situation.projected[node["id"]][question.id]
        assert Enum.find(node["comments"]["nodes"], &(&1["id"] == comment_id))["body"] == Request.render_question(question)
      end
    end

    test "the rows built from the records equal the rows built from Linear, in order, field by field apart from question_id" do
      situation = situation()

      old = from_linear(situation)
      new = items(records(situation), situation.snapshot)

      assert Enum.map(old, &{&1.kind, &1.identifier}) == [
               {:clarify, "SHOP-5"},
               {:plan, "SHOP-3"},
               {:action, "SHOP-1"},
               {:action, "SHOP-2"},
               {:blocked, "SHOP-4"}
             ]

      assert comparable(new) == comparable(old)

      # The record names each request's Question.
      assert [nil, nil, "q-signing", "q-merge", nil] == Enum.map(new, &get_in(&1, [:review, :question_id]))
      assert [%{question_id: "q-plan", comment_id: "c-plan"}] = Enum.find(new, &(&1.kind == :plan)).review.decisions
      assert %{confirm: "Merging"} = Enum.find(new, &(&1.identifier == "SHOP-2")).review
    end
  end

  describe "items/3" do
    setup do
      situation = situation()
      {:ok, situation: situation, records: records(situation)}
    end

    test "a ticket whose question was answered on the record yields no row", %{situation: situation, records: records} do
      signing = Enum.find(records, &(&1.issue_identifier == "SHOP-1"))
      answer = %{text: "Add it", option: 1, by: %{kind: :person, name: "Director"}, at: ~U[2026-10-20 13:00:00Z], scope: :ticket}
      answered = TicketState.normalize(%{signing | questions: Enum.map(signing.questions, &%{&1 | state: :answered, answer: answer})})

      assert [] = items([answered])
      refute Enum.any?(items([answered | records -- [signing]], situation.snapshot), &(&1.identifier == "SHOP-1"))
    end

    test "each open question is a row of its own, oldest first", %{records: records} do
      signing = Enum.find(records, &(&1.issue_identifier == "SHOP-1"))
      [first] = signing.questions
      second = %{first | id: "q-second", title: "Rotate the key", asked_at: ~U[2026-10-20 10:30:00Z]}

      rows = items([TicketState.normalize(%{signing | questions: [second, first], projected: nil})])

      assert [{"Add the signing secret", ~U[2026-10-20 10:00:00.000Z]}, {"Rotate the key", ~U[2026-10-20 10:30:00Z]}] = Enum.map(rows, &{&1.ask, &1.waiting_since})
      assert Enum.all?(rows, &(&1.review.comment_id == nil))
    end

    test "running tickets and tickets the orchestrator saw leave review are dropped; a pause stays", %{records: records} do
      watching = [%{issue_id: "id-SHOP-3", state: "Waiting on sub-tickets"}, %{issue_id: "id-SHOP-1", state: "Done"}, %{issue_id: "id-SHOP-4", state: "Rework"}]
      rows = items(records, %{running: [%{issue_id: "id-SHOP-2"}], watching: watching})

      assert [{:blocked, "SHOP-4", "Rework"}] = Enum.map(rows, &{&1.kind, &1.identifier, &1.state})

      kept = items(records, %{watching: [%{issue_id: "id-SHOP-3", state: "plan review"}, %{issue_id: "id-SHOP-1", state: "Plan Review"}]})
      assert Enum.map(kept, & &1.identifier) == ["SHOP-3", "SHOP-1", "SHOP-2", "SHOP-4"]
    end

    test "a clarification for a ticket already listed adds no row, and a record with no issue id none", %{situation: situation, records: records} do
      plan = Enum.find(records, &(&1.issue_identifier == "SHOP-3"))
      [clarification] = situation.snapshot.awaiting_clarification
      snapshot = %{awaiting_clarification: [%{clarification | issue_id: plan.issue_id}], skipped: [%{issue_id: nil}]}

      assert [%{kind: :plan}] = items([plan, %{repo_key: @repo_key}], snapshot)
    end
  end

  describe "Item.from_plan_brief/2" do
    setup do
      situation = situation()
      {:ok, plan: situation |> records() |> Enum.find(&(&1.issue_identifier == "SHOP-3"))}
    end

    test "is nil for a ticket outside Plan Review, without the plan label or without a captured brief", %{plan: plan} do
      assert Item.from_plan_brief(%{plan | phase: "In Progress"}, settings()) == nil
      assert Item.from_plan_brief(%{plan | labels: []}, settings()) == nil
      assert Item.from_plan_brief(%{plan | plan_brief: nil}, settings()) == nil
    end

    test "counts the answers given since the plan entered review, and keeps a captured choice the record holds no Question of", %{plan: plan} do
      [choice] = plan.plan_brief.choices
      legacy = %{choice | question_id: nil, title: "A choice asked before questions"}
      answer = fn at -> %{text: "CSV", option: 1, by: %{kind: :person, name: "Director"}, at: at, scope: :ticket} end
      [open] = plan.questions

      questions = [
        %{open | id: "q-before", state: :answered, answer: answer.(~U[2026-10-20 06:59:00Z])},
        %{open | id: "q-after", state: :answered, answer: answer.(~U[2026-10-20 08:00:00Z])},
        %{open | options: []}
      ]

      record = %{plan | questions: questions, plan_brief: %{plan.plan_brief | choices: [choice, legacy]}}
      assert %{review: %{unapplied_answers: 1, decisions: [%{title: "A choice asked before questions"}]}} = Item.from_plan_brief(record, settings())
    end

    test "asks from the brief's first review line, its raw markdown, or to approve the plan", %{plan: plan} do
      brief = plan.plan_brief.brief
      ask = fn brief -> Item.from_plan_brief(put_in(plan.plan_brief.brief, brief), settings()).ask end

      assert ask.(%{brief | headline: nil}) == "SHOP-31: the export model"
      assert ask.(%{brief | headline: nil, what_to_review: []}) == "Approve the plan"
      assert ask.(%{format: "raw", markdown: "## Review brief\n\n**What to review:** By hand."}) == "By hand."
      assert ask.(nil) == "Approve the plan"
    end
  end

  defp person_reason(text, set_at), do: %{kind: :person, waits_on: %{action: "unblock"}, text: text, set_by: @director, set_at: set_at, releasable: true}

  describe "Item.from_pause/2" do
    test "a row with no known wait sorts last; the default settings are the repo's" do
      paused = fn id, set_at ->
        reasons = [person_reason("Paused by you", set_at)]
        pause = %{subject: {:ticket, @repo_key, id}, reasons: reasons, set_by: @director, since: set_at}
        TicketState.normalize(%{repo_key: @repo_key, issue_id: id, issue_identifier: id, pause: pause})
      end

      records = [paused.("SHOP-8", nil), paused.("SHOP-7", ~U[2026-10-20 12:00:00Z])]

      assert ["SHOP-7", "SHOP-8"] = records |> items() |> Enum.map(& &1.identifier)
      assert FromRecord.items([], %{}) == []
    end

    test "is nil without a pause or without a reason the Director may release, and names no clearing condition without a hold" do
      record = TicketState.new(@repo_key, "id-SHOP-9", %{})
      question = %{person_reason("Waiting on your answer", nil) | kind: :question, waits_on: %{question_id: "q"}, releasable: false}

      assert Item.from_pause(record, nil) == nil
      assert Item.from_pause(record, %{reasons: [question]}) == nil

      assert %{kind: :blocked, ask: "Paused by you", review: %{reason: "Paused by you", clearing_condition: nil}} =
               Item.from_pause(record, %{reasons: [question, person_reason("Paused by you", nil)]})
    end
  end
end
