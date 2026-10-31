defmodule SymphonyElixir.PlanBriefTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Inbox.Item
  alias SymphonyElixir.{PlanBrief, TicketObservation, TicketSignals, TicketState}
  alias SymphonyElixirWeb.Presenter

  @repo_key "plans"
  @issue_id "plan-1"
  @read_at ~U[2026-10-30 12:00:00Z]
  @ticket {@repo_key, @issue_id}

  @brief """
  ## Review brief

  **What to review:** The gift card plan.

  - [Screens](https://linear.app/acme/document/screens)
  - TP-91: the card model

  **Decisions needed:**

  1. Card lifetime: https://linear.app/acme/issue/TP-90#comment-q1

  **How to approve / change / reject:**

  - Approve: move the parent to Waiting on sub-tickets.
  - Reject: move the parent to Rework.
  """

  # Answers the snapshot it is given.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  setup do
    :ok = RunStore.clear()

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :plan_brief_capture, false)
      Application.delete_env(:symphony_elixir, :plan_brief_opts)
      RunStore.clear()
    end)

    :ok
  end

  defp settings do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})
    settings
  end

  defp put_record(phase, attrs \\ %{}) do
    :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, Map.merge(%{phase: phase, issue_identifier: "TP-90"}, attrs)))
  end

  defp record, do: normalized(@repo_key)

  defp normalized(repo_key), do: TicketState.normalize(RunStore.get_ticket_state(repo_key, @issue_id))

  defp request_body(question_id) do
    Request.render_hold(
      %{
        title: "Card lifetime",
        question: "How long does a gift card last?",
        why: "The screens need it.",
        if_unanswered: "TP-91 waits.",
        options: [%{label: "One year", effect: "Cards expire after a year.", recommended: true}, %{label: "Two years", effect: "Cards last two years."}],
        recommendation_reason: "Most shops pick one year."
      },
      "In Progress"
    ) <> "\n\n<!-- symphony:question #{question_id} -->"
  end

  defp child(identifier, title, created_at, state \\ "Backlog"),
    do: %{"identifier" => identifier, "title" => title, "url" => "https://linear.app/acme/issue/" <> identifier, "createdAt" => created_at, "state" => %{"name" => state}}

  # The plan as Linear reads it: still in `Rework`, as the move into `Plan Review` was written on the
  # record first and Linear's has not landed yet.
  defp plan_node(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => @issue_id,
        "identifier" => "TP-90",
        "title" => "Gift cards",
        "url" => "https://linear.app/acme/issue/TP-90",
        "state" => %{"name" => "Rework"},
        "labels" => %{"nodes" => [%{"name" => "plan"}]},
        "attachments" => %{"nodes" => []},
        "children" => %{"nodes" => [child("TP-92", "Card screens", "2026-10-02T10:00:00Z"), child("TP-91", "Card model", "2026-10-01T10:00:00Z", "Todo")]},
        "comments" => %{
          "nodes" => [
            %{"id" => "brief", "body" => @brief, "createdAt" => "2026-10-30T11:00:00Z"},
            %{"id" => "q1", "body" => request_body("question-1"), "createdAt" => "2026-10-30T10:59:00Z"}
          ],
          "pageInfo" => %{"hasPreviousPage" => false}
        },
        "history" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
      },
      attrs
    )
  end

  # A Linear client that answers the plan query with `answer` and tells the test what it was asked.
  defp client(answer) do
    test_pid = self()

    fn query, variables, _opts ->
      send(test_pid, {:linear_read, query, variables})
      answer.()
    end
  end

  defp answering(node), do: client(fn -> {:ok, %{"data" => %{"issue" => node}}} end)

  # The options of a capture that reads `node` over a Linear tracker.
  defp opts(node \\ plan_node()), do: [linear_client: answering(node), settings: settings()]

  defp failing(answer), do: [linear_client: client(answer), settings: settings()]

  defp await(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  describe "capture/2" do
    test "stores the brief, the sub-tickets in landing order and the open choices with their question ids, as the Inbox shows them" do
      put_record("Plan Review")

      assert {:ok, brief} = PlanBrief.capture(@ticket, [now: @read_at] ++ opts())

      assert_received {:linear_read, query, %{id: @issue_id}}
      assert query =~ "SymphonyPlanBrief"

      assert %{brief: %{format: "parsed", headline: "The gift card plan."}, read_at: @read_at} = brief

      assert [%{identifier: "TP-91", title: "Card model", state: "Todo"}, %{identifier: "TP-92", state: "Backlog"}] =
               brief.sub_tickets

      assert [%{comment_id: "q1", question_id: "question-1", title: "Card lifetime", options: [%{label: "One year", recommended: true}, _two]}] =
               brief.choices

      assert %{plan_brief: ^brief, plan_brief_error: nil} = record()
      assert PlanBrief.from_record(record()) == brief

      # The same plan, read in `Plan Review`, is what the Inbox lists today.
      inbox = Item.from_node(plan_node(%{"state" => %{"name" => "Plan Review"}}), @repo_key, settings(), %{})
      assert inbox.review.brief == brief.brief
      assert inbox.review.sub_tickets == brief.sub_tickets
      assert inbox.review.decisions == brief.choices
    end

    test "a revision's capture replaces the brief" do
      put_record("Plan Review")
      {:ok, _first} = PlanBrief.capture(@ticket, [now: @read_at] ++ opts())

      revised =
        plan_node(%{
          "children" => %{
            "nodes" => [child("TP-91", "Card model", "2026-10-01T10:00:00Z"), child("TP-93", "Card emails", "2026-10-03T10:00:00Z")]
          },
          "comments" => %{"nodes" => [%{"id" => "brief", "body" => String.replace(@brief, "The gift card plan.", "The revised plan.")}]}
        })

      later = DateTime.add(@read_at, 60)
      {:ok, _second} = PlanBrief.capture(@ticket, [now: later] ++ opts(revised))

      assert %{brief: %{headline: "The revised plan."}, choices: [], read_at: ^later} = revised_brief = record().plan_brief
      assert [%{identifier: "TP-91"}, %{identifier: "TP-93"}] = revised_brief.sub_tickets
    end

    test "a failed read stores no brief and the reason, which a later capture clears" do
      put_record("Plan Review")
      timing_out = failing(fn -> {:error, :timeout} end)
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, :timeout} = PlanBrief.capture(@ticket, timing_out) end)
      assert log =~ "Plan brief: the capture failed issue_id=#{@issue_id}: :timeout"
      assert %{plan_brief: nil, plan_brief_error: ":timeout"} = record()

      {:ok, _brief} = PlanBrief.capture(@ticket, opts())
      assert %{plan_brief: %{brief: %{format: "parsed"}}, plan_brief_error: nil} = record()
    end

    test "an issue Linear doesn't return, an answer it can't read and a ticket that is no plan are failures" do
      put_record("Plan Review")
      no_issue = failing(fn -> {:ok, %{"data" => %{"issue" => nil}}} end)
      unreadable = failing(fn -> {:ok, %{"errors" => [%{}]}} end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :issue_not_found} = PlanBrief.capture(@ticket, no_issue)
        assert {:error, {:unexpected_response, %{"errors" => _}}} = PlanBrief.capture(@ticket, unreadable)
        assert {:error, :not_a_plan} = PlanBrief.capture(@ticket, opts(plan_node(%{"labels" => %{"nodes" => []}})))
      end)

      assert %{plan_brief: nil, plan_brief_error: ":not_a_plan"} = record()
    end

    test "a repo that isn't configured is a failure; a tracker other than Linear is skipped and writes nothing" do
      put_record("Plan Review")

      ExUnit.CaptureLog.capture_log(fn -> assert {:error, {:settings, _reason}} = PlanBrief.capture(@ticket) end)
      assert %{plan_brief_error: "{:settings, " <> _rest} = record()

      repo_key = Config.repo_key!()
      :ok = RunStore.put_ticket_state(TicketState.new(repo_key, @issue_id, %{phase: "Plan Review"}))
      assert :skipped = PlanBrief.capture({repo_key, @issue_id})
      assert %{plan_brief: nil, plan_brief_error: nil} = normalized(repo_key)
    end

    test "a memory tracker's issues file is read in Linear's place, as on a QA server" do
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      issues_file = Path.join(Path.dirname(Workflow.symphony_file_path()), "issues.json")
      plan = %{"id" => @issue_id, "identifier" => "QA-9", "title" => "A plan", "state" => "Plan Review", "labels" => ["plan"]}
      File.write!(issues_file, Jason.encode!([plan]))
      write_workflow_file!(Workflow.workflow_file_path(), tracker_memory_issues_file: "issues.json")
      repo_key = Config.repo_key!()

      for id <- [@issue_id, "plan-unknown"], do: :ok = RunStore.put_ticket_state(TicketState.new(repo_key, id, %{phase: "Plan Review"}))

      assert {:ok, %{brief: nil, sub_tickets: []}} = PlanBrief.capture({repo_key, @issue_id}, now: @read_at)
      assert %{plan_brief: %{read_at: @read_at}, plan_brief_error: nil} = normalized(repo_key)

      ExUnit.CaptureLog.capture_log(fn -> assert {:error, :issue_not_found} = PlanBrief.capture({repo_key, "plan-unknown"}) end)
    end

    test "a ticket with no record can't take the brief" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:store, :ticket_state_not_found}} = PlanBrief.capture(@ticket, opts())
          down = failing(fn -> {:error, :down} end)
          assert {:error, {:store, :ticket_state_not_found}} = PlanBrief.capture(@ticket, down)
        end)

      assert log =~ "Plan brief: the record could not be written issue_id=#{@issue_id}"
    end
  end

  describe "capture_async/2" do
    test "is off unless the application env turns it on" do
      assert :off = PlanBrief.capture_async({@repo_key, @issue_id})
    end

    test "captures in a task" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review")

      assert {:ok, pid} = PlanBrief.capture_async(@ticket, opts())
      await(pid)
      assert %{plan_brief: %{brief: %{headline: "The gift card plan."}}} = record()
    end

    test "a capture that outlives its bound, or crashes, is stored as failed" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review")

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, pid} = PlanBrief.capture_async(@ticket, [timeout_ms: 10] ++ failing(fn -> Process.sleep(:infinity) end))
        await(pid)
      end)

      assert %{plan_brief: nil, plan_brief_error: ":timeout"} = record()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, pid} = PlanBrief.capture_async(@ticket, failing(fn -> raise "boom" end))
        await(pid)
      end)

      assert %{plan_brief: nil, plan_brief_error: "{:exit, " <> _rest} = record()
    end

    test "a task that can't start is logged" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)

      no_supervisor = [task_supervisor: :no_such_supervisor]
      log = ExUnit.CaptureLog.capture_log(fn -> assert :error = PlanBrief.capture_async(@ticket, no_supervisor) end)
      assert log =~ "Plan brief: the capture did not start issue_id=#{@issue_id}"
    end
  end

  describe "entered/4" do
    test "a move into Plan Review captures; a move anywhere else, or none, starts nothing" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review")
      opts = opts()

      assert :ok = PlanBrief.entered(@repo_key, @issue_id, "In Progress", opts)
      assert :ok = PlanBrief.entered(@repo_key, @issue_id, nil, opts)
      refute_received {:linear_read, _query, _variables}

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = PlanBrief.entered("unconfigured", @issue_id, "Plan Review") end)
      refute_received {:linear_read, _query, _variables}

      assert :ok = PlanBrief.entered(@repo_key, @issue_id, "plan review", opts)
      assert_receive {:linear_read, _query, %{id: @issue_id}}, 5_000
    end

    test "Symphony's move into Plan Review stores the brief, which the ticket's API payload carries (walkthrough)" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      Application.put_env(:symphony_elixir, :plan_brief_opts, opts())
      put_record("In Progress")

      assert :ok = TicketSignals.record_phase(@repo_key, @issue_id, "Plan Review")
      assert_receive {:linear_read, _query, %{id: @issue_id}}, 5_000
      eventually(fn -> match?(%{plan_brief: %{}}, record()) end)

      snapshot = %{running: [], retrying: [], rate_limits: nil, repositories: [], dispatch_skipped: []}
      {:ok, pid} = SnapshotOrchestrator.start_link(snapshot)
      assert {:ok, %{plan_brief: payload}} = Presenter.issue_payload("TP-90", pid, 1_000)
      GenServer.stop(pid)

      assert %{brief: %{headline: "The gift card plan."}, choices: [%{question_id: "question-1"}]} = payload
      assert [%{identifier: "TP-91"}, %{identifier: "TP-92"}] = payload.sub_tickets
      assert is_binary(payload.read_at)
      assert {:ok, _json} = Jason.encode(payload)
    end
  end

  describe "observe_delivery/2" do
    defp brief_comment(action, body \\ @brief),
      do: {:comment, action, @issue_id, %{id: "brief", author: "Agent", body: body, created_at: nil}}

    test "a review brief created or edited on a ticket in Plan Review captures it again" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review")
      opts = [repos: [@repo_key, "elsewhere"], linear_client: answering(plan_node()), settings: settings()]

      assert [@repo_key] = PlanBrief.observe_delivery(brief_comment(:update), opts)
      assert_receive {:linear_read, _query, %{id: @issue_id}}, 5_000
      assert [@repo_key] = PlanBrief.observe_delivery(brief_comment(:create), opts)
      assert_receive {:linear_read, _query, %{id: @issue_id}}, 5_000
    end

    test "any other comment, a removal, a ticket outside Plan Review and any other delivery start nothing" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review")
      opts = [repos: [@repo_key], linear_client: answering(plan_node()), settings: settings()]

      assert [] = PlanBrief.observe_delivery(brief_comment(:update, "Looks good"), opts)
      assert [] = PlanBrief.observe_delivery(brief_comment(:remove), opts)
      assert [] = PlanBrief.observe_delivery(:ignored, opts)
      assert [] = PlanBrief.observe_delivery(:ignored)

      put_record("Waiting on sub-tickets")
      assert [] = PlanBrief.observe_delivery(brief_comment(:update), opts)
      # The configured repos hold no record of the ticket.
      assert [] = PlanBrief.observe_delivery(brief_comment(:update), Keyword.delete(opts, :repos))
      refute_received {:linear_read, _query, _variables}
    end
  end

  describe "retry_failed/3" do
    test "captures again each record in Plan Review whose capture failed" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      put_record("Plan Review", %{plan_brief_error: ":timeout"})
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "moved-on", %{phase: "Waiting on sub-tickets", plan_brief_error: ":timeout"}))
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, "captured", %{phase: "Plan Review"}))
      records = @repo_key |> RunStore.list_ticket_states() |> Enum.map(&TicketState.normalize/1)

      assert 1 = PlanBrief.retry_failed(@repo_key, records, linear_client: answering(plan_node()), settings: settings())
      assert %{plan_brief: %{brief: %{format: "parsed"}}, plan_brief_error: nil} = record()
    end

    test "is off unless the application env turns it on" do
      put_record("Plan Review", %{plan_brief_error: ":timeout"})
      assert 0 = PlanBrief.retry_failed(@repo_key, [record()], settings: settings())
    end

    test "the reconciler's follow-up retries a failed capture" do
      Application.put_env(:symphony_elixir, :plan_brief_capture, true)
      Application.put_env(:symphony_elixir, :plan_brief_opts, opts())
      put_record("Plan Review", %{plan_brief_error: ":timeout"})

      TicketObservation.reconcile_all(@repo_key, [], tracker: SymphonyElixir.Tracker.Memory)
      assert_receive {:linear_read, _query, %{id: @issue_id}}, 5_000
      eventually(fn -> match?(%{plan_brief: %{}, plan_brief_error: nil}, record()) end)
    end
  end

  test "a stored brief reads back in its shape; anything else reads as none" do
    assert PlanBrief.normalize(nil) == nil

    assert PlanBrief.normalize(%{brief: "text", sub_tickets: [%{identifier: "TP-1"}, "junk"], choices: nil, read_at: "today"}) == %{
             brief: nil,
             sub_tickets: [%{identifier: "TP-1"}],
             choices: [],
             read_at: nil
           }

    assert PlanBrief.from_record(nil) == nil
    stored = TicketState.normalize(%{plan_brief: %{read_at: @read_at}})
    assert stored.plan_brief == %{brief: nil, sub_tickets: [], choices: [], read_at: @read_at}
  end
end
