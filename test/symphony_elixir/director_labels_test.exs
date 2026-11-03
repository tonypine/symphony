defmodule SymphonyElixir.DirectorLabelsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AuditLog, DirectorLabels, RunStore, TicketState}
  alias SymphonyElixir.Dispatch.Candidates
  alias SymphonyElixir.Linear.Issue

  @moduletag :tmp_dir

  defmodule Writer do
    @moduledoc false
    def add_issue_label(issue_id, label), do: reply({:tracker, :add, issue_id, label})
    def remove_issue_label(issue_id, label), do: reply({:tracker, :remove, issue_id, label})

    defp reply(message) do
      send(self(), message)
      Process.get(:tracker_reply, :ok)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    repo = "labels-#{n}"
    ticket = %{repo_key: repo, issue_id: "issue-#{n}", issue_identifier: "LAB-#{n}", phase: "Todo", title: "Export", labels: ["frontend"]}
    :ok = RunStore.put_ticket_state(ticket)
    records = RunStore.list_ticket_states(repo)

    opts = [
      tracker: Writer,
      orchestrator: self(),
      audit_log: [dir: tmp_dir],
      records: records,
      escalate_labels: ["needs-human", "plan", "breakdown", "security"],
      force_label: "expedite"
    ]

    %{repo: repo, ticket: ticket, opts: opts}
  end

  defp record(%{issue_id: id}), do: id |> RunStore.get_ticket_state() |> TicketState.normalize()

  defp actions(%{issue_id: id}), do: id |> RunStore.list_ticket_events([]) |> Enum.filter(&(&1.type == "person.action"))

  defp refresh_opts(ctx), do: Keyword.put(ctx.opts, :records, RunStore.list_ticket_states(ctx.repo))

  defp on(payload), do: for(%{on: true, label: label} <- payload.labels, do: label)

  test "lists the toggles: the labels Symphony reads, then the escalate labels they don't name" do
    toggles = DirectorLabels.toggles(escalate_labels: ["needs-human", "Plan", " security ", "Security", "Blocked", "expedite", "", nil], force_label: "Expedite")

    assert Enum.map(toggles, & &1.label) ==
             ~w(plan type:bug type:feature qa:skip skip-update-hold qa:live qa:fixture needs-human security)

    assert %{title: "Plan", aliases: ["breakdown"], effect: "Groom into sub-tickets before any work starts"} = hd(toggles)
    assert %{title: "Skip QA", effect: "Once approved, it goes on without a QA pass"} = Enum.find(toggles, &(&1.label == "qa:skip"))
    assert %{title: "security", effect: "Code Review asks you before approving"} = List.last(toggles)
    assert Enum.map(DirectorLabels.toggles(), & &1.label) == ~w(plan type:bug type:feature qa:skip skip-update-hold qa:live qa:fixture)
  end

  test "adds Plan: Linear first, then the record, the event, the audit and a refresh at once", ctx do
    %{ticket: ticket, repo: repo} = ctx
    refute Issue.breakdown?(Candidates.issue_from_record(record(ticket)))

    assert {:ok, payload} = DirectorLabels.set(ticket.issue_identifier, "Plan", :add, ctx.opts)
    assert payload.action == "add_label"
    assert payload.issue_identifier == ticket.issue_identifier
    assert on(payload) == ["plan"]
    assert %{label: "plan", title: "Plan", on: true} = hd(payload.labels)

    issue_id = ticket.issue_id
    assert_received {:tracker, :add, ^issue_id, "plan"}
    assert_received {:"$gen_cast", {:request_refresh, ^repo, :now}}
    assert record(ticket).labels == ["frontend", "plan"]
    assert Issue.breakdown?(Candidates.issue_from_record(record(ticket)))

    assert [%{payload: %{action: "add_label", label: "plan"}, summary: %{title: "The Director added the plan label"}}] = actions(ticket)

    {:ok, stream} = AuditLog.query(dir: ctx.tmp_dir, event_type: "director_move")
    assert [%{"move" => "add_label", "label" => "plan", "label_title" => "Plan"}] = Enum.to_list(stream)
  end

  test "removes a label, and Plan off removes the older breakdown name too", ctx do
    assert {:ok, _payload} = DirectorLabels.set(ctx.ticket.issue_id, "qa:skip", :add, ctx.opts)
    assert {:ok, payload} = DirectorLabels.set(ctx.ticket.issue_identifier, "QA:SKIP", :remove, refresh_opts(ctx))
    assert payload.action == "remove_label"
    assert on(payload) == []
    assert record(ctx.ticket).labels == ["frontend"]
    assert_received {:tracker, :remove, _issue_id, "qa:skip"}

    old = %{ctx.ticket | labels: ["Breakdown", "plan", "frontend"]}
    assert {:ok, %{labels: [%{label: "plan", on: true} | _rest]}} = DirectorLabels.labels(old.issue_id, Keyword.put(ctx.opts, :records, [old]))
    assert {:ok, payload} = DirectorLabels.set(old.issue_identifier, "breakdown", :remove, Keyword.put(ctx.opts, :records, [old]))
    assert on(payload) == []
    assert_received {:tracker, :remove, _issue_id, "Breakdown"}
    assert_received {:tracker, :remove, _issue_id, "plan"}
    assert record(ctx.ticket).labels == ["frontend"]

    assert ctx.ticket |> actions() |> Enum.map(&{&1.payload.action, &1.summary.title}) |> Enum.sort() == [
             {"add_label", "The Director added the qa:skip label"},
             {"remove_label", "The Director removed the plan label"},
             {"remove_label", "The Director removed the qa:skip label"}
           ]
  end

  test "an escalate label from the settings is a toggle; any other label is refused, changing nothing", ctx do
    assert {:ok, payload} = DirectorLabels.set(ctx.ticket.issue_identifier, "security", :add, ctx.opts)
    assert "security" in on(payload)

    id = ctx.ticket.issue_identifier
    opts = refresh_opts(ctx)

    for {label, message} <- [
          {"frontend", ~s("frontend" isn't a label Symphony reads, so it can't be changed on #{id} from here.)},
          {"Blocked", "Blocked is Symphony's own label: it sets and clears it itself, so it can't be changed on #{id}."},
          {"Needs Decision", "Needs Decision is Symphony's own label: it sets and clears it itself, so it can't be changed on #{id}."},
          {"CI red", "CI red is Symphony's own label: it sets and clears it itself, so it can't be changed on #{id}."},
          {"expedite", "expedite is the force label: Force (or Stop Forcing) on #{id} sets it."}
        ] do
      assert {:error, {:conflict, ^message}} = DirectorLabels.set(id, label, :add, opts)
      assert {:error, {:conflict, ^message}} = DirectorLabels.set(id, label, :remove, opts)
    end

    assert {:error, {:conflict, "Symphony doesn't track ZZZ-1, so it can't change its labels."}} = DirectorLabels.set("ZZZ-1", "plan", :add, opts)
    assert {:error, {:conflict, "#{id} already has security on."}} == DirectorLabels.set(id, "security", :add, opts)
    assert {:error, {:conflict, "#{id} doesn't have Bug on."}} == DirectorLabels.set(id, "type:bug", :remove, opts)

    assert_received {:tracker, :add, _issue_id, "security"}
    refute_received {:tracker, _action, _issue_id, _label}
    assert record(ctx.ticket).labels == ["frontend", "security"]
    assert length(actions(ctx.ticket)) == 1
  end

  test "a write Linear refuses changes nothing and says why", ctx do
    id = ctx.ticket.issue_identifier

    for {reply, message} <- [
          {{:error, :issue_update_failed}, "Linear didn't turn on Skip QA on #{id}, so nothing changed. Try again in a moment."},
          {{:error, {:label_not_found, "qa:skip"}}, "Linear has no qa:skip label, so Symphony couldn't turn on Skip QA on #{id}. Create the label in Linear, then try again."},
          {{:error, :missing_linear_api_token}, "Symphony has no Linear API key, so it couldn't turn on Skip QA on #{id} in Linear."},
          {{:error, {:linear_api_request, :missing_linear_api_token}}, "Symphony has no Linear API key, so it couldn't turn on Skip QA on #{id} in Linear."}
        ] do
      Process.put(:tracker_reply, reply)
      log = capture_log(fn -> assert {:error, {:linear, ^message}} = DirectorLabels.set(id, "qa:skip", :add, ctx.opts) end)
      assert log =~ "Failed to write a label"
    end

    Process.put(:tracker_reply, {:error, :issue_update_failed})
    on = %{ctx.ticket | labels: ["qa:skip"]}
    capture_log(fn -> assert {:error, {:linear, "Linear didn't turn off Skip QA" <> _}} = DirectorLabels.set(id, "qa:skip", :remove, Keyword.put(ctx.opts, :records, [on])) end)

    assert record(ctx.ticket).labels == ["frontend"]
    assert actions(ctx.ticket) == []
  end

  test "a record that can't be written or an audit log that can't is logged, and the change still answers", ctx do
    ghost = %{ctx.ticket | issue_id: "ghost-#{System.unique_integer([:positive])}", labels: []}

    log =
      capture_log(fn ->
        opts = ctx.opts |> Keyword.put(:records, [ghost]) |> Keyword.put(:audit_log, dir: "/dev/null/audit")
        assert {:ok, payload} = DirectorLabels.set(ghost.issue_identifier, "type:bug", :add, opts)
        assert on(payload) == ["type:bug"]
      end)

    assert log =~ "Failed to write the labels of issue_id=#{ghost.issue_id}"
    assert log =~ "Failed to record director_move audit event"
  end

  test "takes the escalate labels and the force label from the ticket's repository's settings", ctx do
    settings = %{auto_review: %{acceptance_gate: %{escalate: %{labels: ["needs-human", "security"]}}}, agent: %{force_label: "rush"}}
    repo = ctx.repo
    opts = Keyword.drop(ctx.opts, [:escalate_labels, :force_label])

    found = fn
      ^repo -> {:ok, settings}
      _other -> {:error, :unknown_repo}
    end

    assert {:ok, %{labels: labels}} = DirectorLabels.labels(ctx.ticket.issue_id, Keyword.put(opts, :settings_for_repo, found))
    assert Enum.map(Enum.take(labels, -2), & &1.label) == ["needs-human", "security"]

    assert {:error, {:conflict, "rush is the force label" <> _}} =
             DirectorLabels.set(ctx.ticket.issue_id, "rush", :add, Keyword.put(opts, :settings_for_repo, found))

    # Without its settings: the built-in escalate labels and `expedite`.
    missing = Keyword.put(opts, :settings_for_repo, fn _repo -> {:error, :unknown_repo} end)
    assert {:ok, %{labels: labels}} = DirectorLabels.labels(ctx.ticket.issue_id, missing)
    refute Enum.any?(labels, &(&1.label == "security"))
    assert {:error, {:conflict, "expedite is the force label" <> _}} = DirectorLabels.set(ctx.ticket.issue_id, "expedite", :add, missing)
  end

  test "reads the run store's records and the repository's settings by default" do
    n = System.unique_integer([:positive])
    :ok = RunStore.put_ticket_state(%{repo_key: "labels-default-#{n}", issue_id: "issue-d-#{n}", issue_identifier: "LBD-#{n}", labels: ["qa:live"]})
    assert {:ok, %{labels: labels}} = DirectorLabels.labels("lbd-#{n}")
    assert %{label: "qa:live", on: true} = Enum.find(labels, &(&1.label == "qa:live"))
    # The built-in escalate labels, as the settings give them.
    assert Enum.any?(labels, &(&1.label == "needs-human"))
    assert {:error, {:conflict, _message}} = DirectorLabels.labels("LBD-none-#{n}")
    assert {:error, {:conflict, "expedite is the force label" <> _}} = DirectorLabels.set("LBD-#{n}", "expedite", :add)
  end
end
