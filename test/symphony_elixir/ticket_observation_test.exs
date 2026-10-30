defmodule SymphonyElixir.TicketObservationTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{AgentTools, TicketObservation, TicketSignals, TicketState, TransitionGuard}

  @linear_at ~U[2026-10-29 09:00:00Z]
  @now ~U[2026-10-29 09:05:00Z]
  @created_at ~U[2026-10-01 08:00:00Z]
  @phase_at ~U[2026-10-29 09:01:00Z]
  @moved_at ~U[2026-10-29 09:02:00Z]
  # The drift's moves back run under this supervisor, so a test waits for them (`settle/0`).
  @moves SymphonyElixir.TicketObservationTest.Moves

  # The reconcile's Linear writes and by-id read: each call is sent to the test (`ReconcileProbe`) and
  # answers what the test set for it (`reply/2`), `:raise` raising.
  defmodule ReconcileTracker do
    def update_issue_state(issue_id, state), do: answer({:update_issue_state, issue_id, state}, :ok)
    def set_machine_label(issue_id, name), do: answer({:set_machine_label, issue_id, name}, :ok)
    def clear_machine_label(issue_id, name), do: answer({:clear_machine_label, issue_id, name}, :ok)
    def fetch_issue_states_by_ids(issue_ids), do: answer({:fetch_issue_states_by_ids, issue_ids}, {:ok, []})

    defp answer(call, default) do
      send(ReconcileProbe, {:tracker, call})

      case :persistent_term.get({__MODULE__, elem(call, 0)}, default) do
        :raise -> raise "Linear is down"
        result -> result
      end
    end
  end

  setup do
    TicketObservation.reset()
    on_exit(&TicketObservation.reset/0)
    start_supervised!({Task.Supervisor, name: @moves})
    %{repo_key: Config.repo_key!()}
  end

  defp linear_issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-observed",
        identifier: "ACME-7",
        title: "Observe every poll",
        description: "## Why\n\nThe record learns from every poll.",
        team: %{key: "Test", name: "Test"},
        project: %{id: "project-1", name: "Symphony", slug_id: "symphony-1a2b"},
        state: "Todo",
        labels: ["backend"],
        priority: 2,
        assignee_id: "user-1",
        blocked_by: [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}, %{id: "issue-b", identifier: "ACME-6", state: "Done"}],
        sub_issues: [%{id: "issue-c", identifier: "ACME-8", state: "Todo"}],
        url: "https://linear.app/acme/issue/ACME-7",
        created_at: @created_at,
        updated_at: @linear_at
      },
      attrs
    )
  end

  test "a ticket without a record gets one holding what Linear says, with no ledger event", %{repo_key: repo_key} do
    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    record = RunStore.get_ticket_state(repo_key, "issue-observed")

    assert %{
             issue_identifier: "ACME-7",
             phase: "Todo",
             title: "Observe every poll",
             description: "## Why\n\nThe record learns from every poll.",
             team: %{key: "Test", name: "Test"},
             project: %{id: "project-1", name: "Symphony", slug_id: "symphony-1a2b"},
             labels: ["backend"],
             priority: 2,
             assignee: "user-1",
             blockers: [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}],
             sub_issues: [%{id: "issue-c", identifier: "ACME-8", state: "Todo"}],
             parent: nil,
             url: "https://linear.app/acme/issue/ACME-7",
             created_at: @created_at,
             linear_updated_at: @linear_at,
             observed_at: @now
           } = record

    assert ticket_events(repo_key, "issue-observed") == []
  end

  test "the same issue again writes nothing", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    stored = RunStore.get_ticket_state(repo_key, "issue-observed")

    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed") == stored
  end

  test "an edited description is written once", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    edited = linear_issue(%{description: "## Why\n\nEdited.", updated_at: DateTime.add(@linear_at, 60)})
    assert {:ok, :updated} = TicketObservation.observe(repo_key, edited, now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").description == "## Why\n\nEdited."
    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, edited, now: DateTime.add(@now, 120))
  end

  test "a sub-ticket or a blocker that moves is written, at the same updatedAt", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    started = linear_issue(%{sub_issues: [%{id: "issue-c", identifier: "ACME-8", state: "In Progress"}]})
    assert {:ok, :updated} = TicketObservation.observe(repo_key, started, now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").sub_issues == [%{id: "issue-c", identifier: "ACME-8", state: "In Progress"}]

    reviewed = %{started | blocked_by: [%{id: "issue-a", identifier: "ACME-5", state: "Code Review"}]}
    assert {:ok, :updated} = TicketObservation.observe(repo_key, reviewed, now: DateTime.add(@now, 120))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: "issue-a", identifier: "ACME-5", state: "Code Review"}]
  end

  test "a record that kept its blockers by identifier alone is written once with their ids and states", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    :ok = RunStore.update_ticket_state(repo_key, "issue-observed", %{blockers: ["ACME-5"]})
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: nil, identifier: "ACME-5", state: nil}]

    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}]
    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 120))
  end

  test "a newer title reaches an existing record and leaves its other fields", %{repo_key: repo_key} do
    held = repo_key |> TicketState.new("issue-observed") |> TicketState.set_hold(:needs_decision, %{reason: "asked"}, @now)
    :ok = RunStore.put_ticket_state(held)
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    renamed = linear_issue(%{title: "Observe every poll, renamed", updated_at: DateTime.add(@linear_at, 300)})
    assert {:ok, :updated} = TicketObservation.observe(repo_key, renamed, now: DateTime.add(@now, 300))

    record = RunStore.get_ticket_state(repo_key, "issue-observed")
    assert record.title == "Observe every poll, renamed"
    assert record.linear_updated_at == DateTime.add(@linear_at, 300)
    assert [%{kind: :needs_decision, reason: "asked"}] = record.holds
  end

  test "an older issue is dropped, counted as stale, and the record untouched", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    stored = RunStore.get_ticket_state(repo_key, "issue-observed")

    older = linear_issue(%{title: "Before the rename", state: "Backlog", updated_at: DateTime.add(@linear_at, -60)})
    assert {:ok, :stale} = TicketObservation.observe(repo_key, older, now: DateTime.add(@now, 60))

    assert RunStore.get_ticket_state(repo_key, "issue-observed") == stored
    assert counts() == %{updated: 1, unchanged: 0, stale: 1, unrouted: 0, errors: 0}
  end

  test "blockers keep the open ones: the given terminal states, else the repo's", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, terminal_states: ["In Progress"])
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: "issue-b", identifier: "ACME-6", state: "Done"}]

    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{updated_at: DateTime.add(@linear_at, 1)}), now: @now)
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}]
  end

  test "an unknown blocker list keeps the known blockers", %{repo_key: repo_key} do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(%{blocked_by: :unknown}), now: DateTime.add(@now, 60))
    assert RunStore.get_ticket_state(repo_key, "issue-observed").blockers == [%{id: "issue-a", identifier: "ACME-5", state: "In Progress"}]
  end

  test "a repo Symphony has no settings for keeps every blocker" do
    assert {:ok, :updated} = TicketObservation.observe("observation-other-repo", linear_issue())

    record = RunStore.get_ticket_state("observation-other-repo", "issue-observed")
    assert Enum.map(record.blockers, & &1.identifier) == ["ACME-5", "ACME-6"]
    assert %DateTime{} = record.observed_at
  end

  test "a store refusal is returned and counted" do
    assert {:error, :invalid_repo_key} = TicketObservation.observe("  ", linear_issue(), now: @now, terminal_states: [])
    assert TicketObservation.summary().errors == 1
  end

  test "observe_all observes each issue and logs the ones it could not", %{repo_key: repo_key} do
    other = linear_issue(%{id: "issue-observed-2", identifier: "ACME-8"})

    log =
      capture_log(fn ->
        issues = [linear_issue(), other, %Issue{id: nil, identifier: "ACME-9"}, :junk]

        assert TicketObservation.observe_all(repo_key, issues, now: @now) ==
                 %{updated: 2, unchanged: 0, stale: 0, errors: 2}
      end)

    assert log =~ "Ticket observation failed for issue_id= issue_identifier=ACME-9 repo_key=#{repo_key}: :invalid_issue"
    assert log =~ "issue_id= issue_identifier= repo_key=#{repo_key}"
    assert RunStore.get_ticket_state(repo_key, "issue-observed-2").issue_identifier == "ACME-8"
    assert counts() == %{updated: 2, unchanged: 0, stale: 0, unrouted: 0, errors: 2}
  end

  test "observe_routed writes each issue under the repo it routes to and skips the ones no repo takes", %{repo_key: repo_key} do
    routed = linear_issue(%{team: %{key: "Test", name: "Test"}})
    keyed = linear_issue(%{id: "issue-observed-keyed", identifier: "OTHER-1", repo_key: "observation-routed-repo"})
    unrouted = linear_issue(%{id: "issue-observed-unrouted", team: %{key: "NOPE", name: "Nope"}})

    assert TicketObservation.observe_routed([routed, keyed, unrouted, :junk], now: @now) ==
             %{updated: 2, unchanged: 0, stale: 0, errors: 0}

    assert RunStore.get_ticket_state(repo_key, "issue-observed").issue_identifier == "ACME-7"
    assert RunStore.get_ticket_state("observation-routed-repo", "issue-observed-keyed").issue_identifier == "OTHER-1"
    assert RunStore.get_ticket_state(repo_key, "issue-observed-unrouted") == nil

    # With no repos, only an issue that carries its repo key is observed.
    assert TicketObservation.observe_routed([routed, keyed], now: @now, repos: []) ==
             %{updated: 0, unchanged: 1, stale: 0, errors: 0}
  end

  test "observe_routed routes nothing while the repos cannot be read" do
    File.write!(Workflow.symphony_file_path(), "repositories: [\n")
    Cache.clear()
    assert {:error, _reason} = Config.repos()

    issue = linear_issue(%{id: "issue-observed-unreadable", team: %{key: "Test", name: "Test"}})
    assert TicketObservation.observe_routed([issue]) == %{updated: 0, unchanged: 0, stale: 0, errors: 0}
  end

  test "without the server, observing still writes and the summary is all zeros", %{repo_key: repo_key} do
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, TicketObservation)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, TicketObservation) end)

    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, source: :webhook)
    assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{priority: 4}), now: @now, compare: true)

    assert TicketObservation.summary() ==
             %{
               updated: 0,
               unchanged: 0,
               stale: 0,
               unrouted: 0,
               errors: 0,
               compare: %{webhook_first: 0, poll_first: 0, poll_first_recent: []},
               drift: %{detected: 0, reverted: 0, revert_failed: 0, recent: []},
               reconcile: %{last_run_at: nil, applied: 0, reapplied: 0, unobserved_filled: 0}
             }

    owned!(repo_key, "Code Review")
    assert {:ok, :updated} = on_record(repo_key, hand_move("Done"), @now)
    assert %{phase: "Code Review"} = RunStore.get_ticket_state(repo_key, "issue-observed")
    assert TicketObservation.summary().drift == %{detected: 0, reverted: 0, revert_failed: 0, recent: []}

    assert %{updated: 0} = TicketObservation.reconcile_all(repo_key, [], now: @now, task_supervisor: @moves)
    settle()
    assert TicketObservation.summary().reconcile == %{last_run_at: nil, applied: 0, reapplied: 0, unobserved_filled: 0}

    assert :ok = TicketObservation.reset()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, TicketObservation)
  end

  test "a changed record is announced with the fields it changed, except by the poll and a by-id read, whose cycle dispatches from it",
       %{repo_key: repo_key} do
    :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{priority: 1}), now: @now, source: :by_id)
    refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}

    reassigned = linear_issue(%{assignee_id: "user-9", priority: 1})
    {:ok, :updated} = TicketObservation.observe(repo_key, reassigned, now: @now, source: :watcher)
    assert_received {:ticket_record, ^repo_key, "issue-observed", :changed, [:assignee]}

    {:ok, :unchanged} = TicketObservation.observe(repo_key, reassigned, now: @now, source: :watcher)
    moved = linear_issue(%{assignee_id: "user-9", priority: 1, state: "In Progress", title: "Renamed"})
    {:ok, :updated} = TicketObservation.observe(repo_key, moved, now: @now, source: :webhook)
    assert_received {:ticket_record, ^repo_key, "issue-observed", :changed, fields}
    assert Enum.sort(fields) == [:phase, :title]
    refute_received {:ticket_record, _repo_key, _issue_id, :changed, _fields}

    assert TicketObservation.observe_delivery({:issue_removed, "issue-observed", "ACME-7"}, now: @now) == :removed
    assert_received {:ticket_record, ^repo_key, "issue-observed", :changed, [:removed_at]}
  end

  test "a new record is announced with every field it observed", %{repo_key: repo_key} do
    :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_records()

    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, source: :watcher)
    assert_received {:ticket_record, ^repo_key, "issue-observed", :changed, fields}
    assert :phase in fields and :title in fields and :blockers in fields
  end

  describe "the comparison with the webhook" do
    test "a read keeps its source on the record: the poll by default", %{repo_key: repo_key} do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)
      assert RunStore.get_ticket_state(repo_key, "issue-observed").observed_from == :poll

      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{priority: 1}), now: @now, source: :by_id)
      assert RunStore.get_ticket_state(repo_key, "issue-observed").observed_from == :by_id
    end

    test "a later read that finds nothing to change counts webhook first, once for each webhook change", %{repo_key: repo_key} do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, source: :webhook)

      assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 30), compare: true)
      assert {:ok, :unchanged} = TicketObservation.observe(repo_key, linear_issue(), now: DateTime.add(@now, 60), source: :watcher)
      assert compare() == %{webhook_first: 1, poll_first: 0, poll_first_recent: []}

      # A second change through the webhook, then a read that only learns the blockers it doesn't carry.
      edited = linear_issue(%{priority: 1, updated_at: DateTime.add(@linear_at, 120)})
      {:ok, :updated} = TicketObservation.observe(repo_key, %{edited | blocked_by: :unknown}, now: DateTime.add(@now, 120), source: :webhook)

      assert {:ok, :updated} = TicketObservation.observe(repo_key, %{edited | blocked_by: []}, now: DateTime.add(@now, 150), compare: true)
      assert compare().webhook_first == 2

      # The record's last change is now the poll's: a read finding nothing counts neither.
      assert {:ok, :unchanged} = TicketObservation.observe(repo_key, %{edited | blocked_by: []}, now: DateTime.add(@now, 180), compare: true)
      assert compare() == %{webhook_first: 2, poll_first: 0, poll_first_recent: []}
    end

    test "a read that changes a field the webhook carries counts poll first, with the ticket and the fields", %{repo_key: repo_key} do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, source: :webhook)

      changed = linear_issue(%{priority: 4, title: "Retitled", updated_at: DateTime.add(@linear_at, 60)})
      assert {:ok, :updated} = TicketObservation.observe(repo_key, changed, now: DateTime.add(@now, 60), source: :by_id, compare: true)

      assert compare() == %{
               webhook_first: 0,
               poll_first: 1,
               poll_first_recent: [%{identifier: "ACME-7", fields: [:title, :priority], source: :by_id, at: DateTime.add(@now, 60)}]
             }
    end

    test "poll first counts only while Linear webhooks are on, and never for a new record or a webhook", %{repo_key: repo_key} do
      # A new record: nothing to compare with.
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now, compare: true)

      # Linear webhooks are off in the test config.
      assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{priority: 4}), now: @now)
      webhook_opts = [now: @now, source: :webhook, compare: true]
      assert {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{priority: 3}), webhook_opts)

      assert compare() == %{webhook_first: 0, poll_first: 0, poll_first_recent: []}
    end

    test "keeps the last ten poll first, newest first, and counts every one", %{repo_key: repo_key} do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

      for n <- 1..12 do
        {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{title: "Title #{n}"}), now: DateTime.add(@now, n), compare: true)
      end

      assert %{poll_first: 12, poll_first_recent: recent} = compare()
      assert Enum.map(recent, & &1.at) == for(n <- 12..3//-1, do: DateTime.add(@now, n))
    end
  end

  describe "observe_delivery/2" do
    defp delivery(attrs \\ %{}) do
      issue = linear_issue(Map.merge(%{team: %{key: "Test", name: "Test"}, blocked_by: :unknown, sub_issues: :unknown}, attrs))
      {:issue, :update, issue, issue.updated_at}
    end

    # The record the regular poll keeps, which a delivery updates.
    defp poll!(repo_key, attrs \\ %{}) do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(Map.put(attrs, :blocked_by, [])), now: @now, terminal_states: [])
      RunStore.get_ticket_state(repo_key, "issue-observed")
    end

    test "an Issue delivery updates the record the poll keeps, from the webhook", %{repo_key: repo_key} do
      poll!(repo_key)
      edited = delivery(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})

      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60), orchestrator: self()) == :updated
      assert_receive {:"$gen_cast", {:request_refresh, ^repo_key, :now}}

      record = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert %{issue_identifier: "ACME-7", priority: 1, observed_from: :webhook} = record
      assert record.observed_at == DateTime.add(@now, 60)
      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60), orchestrator: self()) == :unchanged
      refute_received {:"$gen_cast", _request}
    end

    test "a delivery keeps the slug id the poll recorded, and the description and team it leaves out", %{repo_key: repo_key} do
      polled = poll!(repo_key)
      renamed = delivery(%{description: nil, team: nil, project: %{id: "project-1", name: "Symphony Engine"}, updated_at: DateTime.add(@linear_at, 60)})

      assert TicketObservation.observe_delivery(renamed, now: DateTime.add(@now, 60)) == :updated

      record = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert record.project == %{id: "project-1", name: "Symphony Engine", slug_id: "symphony-1a2b"}
      assert {record.description, record.team} == {polled.description, %{key: "Test", name: "Test"}}
    end

    test "an older delivery is dropped as stale", %{repo_key: repo_key} do
      stored = poll!(repo_key)

      assert TicketObservation.observe_delivery(delivery(%{priority: 4, updated_at: DateTime.add(@linear_at, -60)}), now: @now) == :stale
      assert RunStore.get_ticket_state(repo_key, "issue-observed") == stored
      assert counts().stale == 1
    end

    test "a ticket no repo has a record of is unrouted and writes nothing, whatever its fields match", %{repo_key: repo_key} do
      assert TicketObservation.observe_delivery(delivery(), now: @now) == :unrouted
      assert TicketObservation.observe_delivery(delivery(%{team: %{key: "NOPE", name: "Nope"}}), now: @now) == :unrouted
      assert RunStore.get_ticket_state(repo_key, "issue-observed") == nil

      poll!(repo_key)
      assert TicketObservation.observe_delivery(delivery(), now: @now, repos: []) == :unrouted
    end

    # The operator's routes: a project named by its slug, which a delivery's project never carries,
    # beside a team default the delivery's team alone would match.
    @project_repo "observation-project-repo"
    @default_repo "observation-default-repo"
    @slug_routes [
      %{name: @default_repo, team: "Test", default: true},
      %{name: @project_repo, team: "Test", projects: ["building-the-harness-f469eb38bbc5"]}
    ]
    @project %{id: "project-harness", name: "Building the harness"}

    test "a delivery goes to the repo whose record the poll keeps, not the one its fields would match" do
      poll!(@project_repo, %{project: @project})

      edited = delivery(%{project: @project, priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      opts = [now: DateTime.add(@now, 60), repos: @slug_routes, terminal_states: []]
      assert TicketObservation.observe_delivery(edited, opts) == :updated

      assert %{priority: 1, observed_from: :webhook} = RunStore.get_ticket_state(@project_repo, "issue-observed")
      assert RunStore.get_ticket_state(@default_repo, "issue-observed") == nil

      repolled = linear_issue(%{project: @project, blocked_by: [], priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      opts = [now: DateTime.add(@now, 120), terminal_states: [], compare: true]
      assert {:ok, :unchanged} = TicketObservation.observe(@project_repo, repolled, opts)
      assert compare() == %{webhook_first: 1, poll_first: 0, poll_first_recent: []}
    end

    test "a new ticket's first delivery is unrouted and writes nothing; once the poll files it, a delivery updates it" do
      created = delivery(%{project: @project})
      assert TicketObservation.observe_delivery(created, now: @now, repos: @slug_routes) == :unrouted
      assert Enum.map([@default_repo, @project_repo], &RunStore.get_ticket_state(&1, "issue-observed")) == [nil, nil]

      poll!(@project_repo, %{project: @project})

      edited = delivery(%{project: @project, priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60), repos: @slug_routes) == :updated
      assert %{priority: 1, observed_from: :webhook} = RunStore.get_ticket_state(@project_repo, "issue-observed")
      assert RunStore.get_ticket_state(@default_repo, "issue-observed") == nil
    end

    test "a ticket held in several repos is unrouted, both records are left and no poll is asked for" do
      held = Enum.map([@default_repo, @project_repo], &poll!/1)

      edited = delivery(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60), repos: @slug_routes, orchestrator: self()) == :unrouted
      assert Enum.map([@default_repo, @project_repo], &RunStore.get_ticket_state(&1, "issue-observed")) == held
      refute_received {:"$gen_cast", _request}
    end

    test "a removal asks for a poll of each repo whose record it marked, and only those" do
      poll!(@project_repo)
      removal = {:issue_removed, "issue-observed", "ACME-7"}

      opts = [now: @now, repos: @slug_routes, orchestrator: self()]
      assert TicketObservation.observe_delivery(removal, opts) == :removed
      assert_receive {:"$gen_cast", {:request_refresh, @project_repo, :now}}
      refute_received {:"$gen_cast", {:request_refresh, @default_repo, :now}}
    end

    test "a store refusal is logged and is an error" do
      log =
        capture_log(fn ->
          assert TicketObservation.observe_delivery(delivery(), now: @now, repos: [:junk, %{name: "  "}]) == :error
        end)

      assert log =~ "Ticket observation failed for issue_id=issue-observed issue_identifier=ACME-7 repo_key=  : :invalid_repo_key"
      assert counts().errors == 1
    end

    test "a removal marks the ticket's record and leaves the rest", %{repo_key: repo_key} do
      stored = poll!(repo_key)
      removed_at = DateTime.add(@now, 60)

      assert TicketObservation.observe_delivery({:issue_removed, "issue-observed", "ACME-7"}, now: removed_at) == :removed

      record = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert {record.removed_at, record.updated_at} == {removed_at, removed_at}
      assert Map.drop(record, [:removed_at, :updated_at]) == Map.drop(stored, [:removed_at, :updated_at])
    end

    test "a removal of a ticket without a record writes nothing; a store refusal is an error" do
      unknown = {:issue_removed, "issue-never-seen", nil}
      assert TicketObservation.observe_delivery(unknown, now: @now, orchestrator: self()) == :no_record
      refute_received {:"$gen_cast", _request}

      log =
        capture_log(fn ->
          removal = {:issue_removed, "issue-never-seen", nil}
          assert TicketObservation.observe_delivery(removal, now: @now, repos: [:junk, %{name: "  "}]) == :error
        end)

      assert log =~ "Ticket removal failed for issue_id=issue-never-seen repo_key=  : :invalid_repo_key"
    end

    test "comments and other deliveries are not observed" do
      assert TicketObservation.observe_delivery({:comment, :create, "issue-observed", %{id: "c1"}}) == nil
      assert TicketObservation.observe_delivery(:ignored) == nil
      assert TicketObservation.observe_delivery({:error, :malformed}) == nil
    end

    test "an observation that crashes or hangs is logged and is an error, never raised" do
      log =
        capture_log(fn ->
          crash = fn _parsed, _opts -> raise "boom" end
          assert TicketObservation.observe_delivery(delivery(), observe_fun: crash) == :error

          hang = fn _parsed, _opts -> Process.sleep(:infinity) end
          removal = {:issue_removed, "issue-observed", nil}
          assert TicketObservation.observe_delivery(removal, observe_fun: hang, timeout_ms: 10) == :error
        end)

      assert log =~ "Linear webhook observation failed for issue_id=issue-observed: {:exit, {%RuntimeError{message: \"boom\"}"
      assert log =~ "Linear webhook observation failed for issue_id=issue-observed: :timeout"
      assert counts().errors == 2
    end
  end

  describe "observe_held/2" do
    defp by_id(attrs) do
      linear_issue(Map.merge(%{project: @project, team: %{key: "Test", name: "Test"}, blocked_by: []}, attrs))
    end

    test "a by-id read updates the record a project slug's poll keeps, as a by-id read, and nothing under the team default" do
      poll!(@project_repo, %{project: @project})

      edited = by_id(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      opts = [now: DateTime.add(@now, 60), source: :by_id, repos: @slug_routes, terminal_states: []]

      assert TicketObservation.observe_held([edited], opts) ==
               %{updated: 1, unchanged: 0, stale: 0, unrouted: 0, errors: 0}

      record = RunStore.get_ticket_state(@project_repo, "issue-observed")
      assert %{priority: 1, observed_from: :by_id, repo_key: @project_repo} = record
      assert record.observed_at == DateTime.add(@now, 60)
      assert RunStore.get_ticket_state(@default_repo, "issue-observed") == nil

      stale = by_id(%{priority: 4, updated_at: @linear_at})

      assert TicketObservation.observe_held([edited, stale], opts) ==
               %{updated: 0, unchanged: 1, stale: 1, unrouted: 0, errors: 0}
    end

    test "the configured repos are the default", %{repo_key: repo_key} do
      assert TicketObservation.observe_held([]) == %{updated: 0, unchanged: 0, stale: 0, unrouted: 0, errors: 0}
      poll!(repo_key)

      edited = linear_issue(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      assert %{updated: 1} = TicketObservation.observe_held([edited], now: DateTime.add(@now, 60), source: :by_id)
      assert %{priority: 1, observed_from: :by_id} = RunStore.get_ticket_state(repo_key, "issue-observed")
    end

    test "a ticket no repo has a record of is skipped and counted, whatever its fields match" do
      assert TicketObservation.observe_held([by_id(%{}), by_id(%{project: nil})], now: @now, repos: @slug_routes) ==
               %{updated: 0, unchanged: 0, stale: 0, unrouted: 2, errors: 0}

      assert Enum.map([@default_repo, @project_repo], &RunStore.get_ticket_state(&1, "issue-observed")) == [nil, nil]
      assert counts().unrouted == 2
    end

    test "a ticket held in several repos is skipped, as the poll counts it a conflict, and both records are left" do
      held = Enum.map([@default_repo, @project_repo], &poll!/1)

      edited = by_id(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      assert %{unrouted: 1, updated: 0} = TicketObservation.observe_held([edited], now: DateTime.add(@now, 60), repos: @slug_routes)
      assert Enum.map([@default_repo, @project_repo], &RunStore.get_ticket_state(&1, "issue-observed")) == held
    end

    test "a store refusal is logged and counted under errors, and so is anything but an issue" do
      log =
        capture_log(fn ->
          assert TicketObservation.observe_held([by_id(%{}), :junk], now: @now, repos: [:junk, %{name: "  "}]) ==
                   %{updated: 0, unchanged: 0, stale: 0, unrouted: 0, errors: 2}
        end)

      assert log =~ "Ticket observation failed for issue_id=issue-observed issue_identifier=ACME-7 repo_key=  : :invalid_repo_key"
      assert counts().errors == 2
    end
  end

  describe "drift on a phase Symphony owns" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      :ok
    end

    test "on the record source, a hand move is kept off the record, recorded and moved back in Linear", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")

      assert {:ok, :updated} = on_record(repo_key, hand_move("Done", %{title: "Renamed"}), @now)

      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}

      assert %{phase: "Code Review", phase_owner: :symphony, phase_at: @phase_at, title: "Renamed", linear_updated_at: @moved_at} =
               RunStore.get_ticket_state(repo_key, "issue-observed")

      phases = %{record_phase: "Code Review", linear_phase: "Done"}
      assert ticket_events(repo_key, "issue-observed") == [{"drift.detected", phases}, {"drift.reverted", phases}]

      assert TicketObservation.summary().drift == %{
               detected: 1,
               reverted: 1,
               revert_failed: 0,
               recent: [%{identifier: "ACME-7", record_phase: "Code Review", linear_phase: "Done", outcome: :reverted, at: @now}]
             }
    end

    test "a webhook delivery of a hand move is moved back, on the configured record source, with no question",
         %{repo_key: repo_key} do
      File.write!(Workflow.symphony_file_path(), File.read!(Workflow.symphony_file_path()) <> "dispatch:\n  source: record\n")
      Cache.clear()
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{state: "In Progress"}), now: @now)
      :ok = TicketSignals.record_phase(repo_key, "issue-observed", "Code Review")

      later = DateTime.add(DateTime.utc_now(), 60)
      moved = linear_issue(%{state: "Done", blocked_by: :unknown, sub_issues: :unknown, updated_at: later})
      delivery = {:issue, :update, moved, later}
      assert TicketObservation.observe_delivery(delivery, orchestrator: self(), task_supervisor: @moves) == :updated
      settle()

      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}
      assert %{phase: "Code Review", phase_owner: :symphony} = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert event_types(repo_key) == ["drift.detected", "drift.reverted"]
      assert RunStore.get_ticket_state(repo_key, "issue-observed").holds == []
    end

    test "a failed move back is recorded and tried again by the next observation, never sooner", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [{:error, :linear_down}])

      log =
        capture_log(fn ->
          assert {:ok, :updated} = on_record(repo_key, hand_move("Done"), @now)
        end)

      assert log =~ "Ticket drift: moving back to Code Review failed issue_id=issue-observed issue_identifier=ACME-7: :linear_down"
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert %{phase: "Code Review"} = RunStore.get_ticket_state(repo_key, "issue-observed")

      phases = %{record_phase: "Code Review", linear_phase: "Done"}
      assert ticket_events(repo_key, "issue-observed") == [{"drift.detected", phases}, {"drift.revert_failed", Map.put(phases, :error, ":linear_down")}]

      # The same Linear fact read again: the record already holds it, the move back is tried again,
      # and the drift it already recorded is not recorded twice.
      assert {:ok, :unchanged} = on_record(repo_key, hand_move("Done"), DateTime.add(@now, 30))
      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}

      assert event_types(repo_key) == ["drift.detected", "drift.revert_failed", "drift.reverted"]

      assert %{detected: 2, reverted: 1, revert_failed: 1, recent: recent} = drift()
      assert Enum.map(recent, & &1.outcome) == [:reverted, :revert_failed]
    end

    test "an agent's own move through its Linear tool is not drift: a CI Fix ticket it sends to Rework stays there",
         %{repo_key: repo_key} do
      owned!(repo_key, "CI Fix")
      context = %{issue_id: "issue-observed", issue: %{repo_key: repo_key}}

      assert {:ok, _response} = AgentTools.Linear.update_state(context, "Rework", linear_client: agent_linear("CI Fix", "Rework"))

      # Linear's read of the agent's move, after the record took it.
      moved_at = DateTime.add(DateTime.utc_now(), 60)
      assert {:ok, :updated} = on_record(repo_key, hand_move("Rework", %{updated_at: moved_at}), moved_at)

      assert %{phase: "Rework", phase_owner: :symphony} = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert ticket_events(repo_key, "issue-observed", ["drift.detected", "drift.reverted", "drift.revert_failed"]) == []
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert drift().detected == 0
    end

    test "a ticket Symphony never moved follows Linear: a new Todo ticket moved to Backlog by hand", %{repo_key: repo_key} do
      {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(), now: @now)

      assert {:ok, :updated} = on_record(repo_key, hand_move("Backlog"), @now)

      assert %{phase: "Backlog", phase_owner: :external, phase_at: @now} = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert ticket_events(repo_key, "issue-observed") == []
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert drift().detected == 0
    end

    test "on the poll source a hand move applies as before, and the phase is Linear's", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")

      assert {:ok, :updated} = TicketObservation.observe(repo_key, hand_move("Done"), now: @now, dispatch_source: "poll")
      assert %{phase: "Done", phase_owner: :external} = RunStore.get_ticket_state(repo_key, "issue-observed")

      assert {:ok, :unchanged} = TicketObservation.observe(repo_key, hand_move("Done"), now: @now)
      assert ticket_events(repo_key, "issue-observed") == []
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "Linear's state read before Symphony wrote the phase keeps the phase and moves nothing; an older fact is dropped",
         %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")

      before_move = hand_move("In Progress", %{title: "Renamed", updated_at: DateTime.add(@phase_at, -1)})
      assert {:ok, :updated} = on_record(repo_key, before_move, @now)
      assert %{phase: "Code Review", phase_owner: :symphony, title: "Renamed"} = RunStore.get_ticket_state(repo_key, "issue-observed")

      stale = hand_move("Done", %{updated_at: @linear_at})
      assert {:ok, :stale} = on_record(repo_key, stale, @now)

      assert ticket_events(repo_key, "issue-observed") == []
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert drift().detected == 0
    end

    test "a read without Linear's updatedAt is drift each time, and the last ten are kept, newest first", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")

      for n <- 1..11 do
        at = DateTime.add(@now, n)
        assert {:ok, _outcome} = on_record(repo_key, hand_move("Done", %{updated_at: nil}), at)
      end

      assert length(ticket_events(repo_key, "issue-observed", "drift.reverted")) == 11
      drift = drift()
      assert {drift.detected, drift.reverted, length(drift.recent)} == {11, 11, 10}
      assert drift.recent |> hd() |> Map.fetch!(:at) == DateTime.add(@now, 11)
      assert drift.recent |> List.last() |> Map.fetch!(:at) == DateTime.add(@now, 2)
    end

    test "the move back outlasts the webhook delivery's bound, and its outcome is still recorded", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_events()
      # Linear answers the move after the delivery's bound: the delivery is not cut off, and the move
      # is not either.
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_sleep_ms, 400)

      delivery = {:issue, :update, hand_move("Done", %{blocked_by: :unknown, sub_issues: :unknown}), @moved_at}
      opts = [orchestrator: self(), task_supervisor: @moves, timeout_ms: 200, dispatch_source: "record", now: @now]
      assert TicketObservation.observe_delivery(delivery, opts) == :updated
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      assert_receive {:ticket_event, %{issue_id: "issue-observed", type: "drift.reverted"}}, 2_000
      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}
      assert event_types(repo_key) == ["drift.detected", "drift.reverted"]
      assert %{detected: 1, reverted: 1} = drift()
    end

    test "a move back that crashes is recorded as failed, and tried again by the next observation", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [:not_an_answer])

      log =
        capture_log(fn ->
          assert {:ok, :updated} = on_record(repo_key, hand_move("Done"), @now)
        end)

      assert log =~ "Ticket drift: moving back to Code Review failed issue_id=issue-observed"
      assert [{"drift.detected", _phases}, {"drift.revert_failed", %{error: error}}] = ticket_events(repo_key, "issue-observed")
      assert error == "{:error, {:case_clause, :not_an_answer}}"

      assert {:ok, :unchanged} = on_record(repo_key, hand_move("Done"), DateTime.add(@now, 30))
      assert event_types(repo_key) == ["drift.detected", "drift.revert_failed", "drift.reverted"]
    end

    test "a move back that can't start is logged and left to the next observation, as the record keeps its phase",
         %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")

      opts = [now: @now, dispatch_source: "record", task_supervisor: SymphonyElixir.TicketObservationTest.Missing]

      log =
        capture_log(fn ->
          assert {:ok, :updated} = TicketObservation.observe(repo_key, hand_move("Done"), opts)
        end)

      assert log =~ "Ticket drift: the move back did not start issue_id=issue-observed issue_identifier=ACME-7"
      assert %{phase: "Code Review"} = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert ticket_events(repo_key, "issue-observed") == []
      refute_received {:memory_tracker_state_update, _issue_id, _state}

      assert {:ok, :unchanged} = on_record(repo_key, hand_move("Done"), DateTime.add(@now, 30))
      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}
      assert event_types(repo_key) == ["drift.detected", "drift.reverted"]
    end

    test "a ticket has one move back under way at a time, and one whose task was killed is taken over", %{repo_key: repo_key} do
      owned!(repo_key, "Code Review")
      :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe_ticket_events()
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_sleep_ms, 10_000)

      # Two observations while Linear is slow: one move back waits on Linear, the other adds nothing.
      assert {:ok, :updated} = observe_on_record(repo_key, hand_move("Done"), @now)
      assert {:ok, :unchanged} = observe_on_record(repo_key, hand_move("Done"), DateTime.add(@now, 10))
      assert_receive {:ticket_event, %{issue_id: "issue-observed", type: "drift.detected"}}, 2_000
      mover = eventually(&only_move_back/0)

      # The move back is killed while it waits: the next observation takes the ticket over.
      ref = Process.monitor(mover)
      Process.exit(mover, :kill)
      assert_receive {:DOWN, ^ref, :process, ^mover, :killed}
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_sleep_ms, 0)

      assert {:ok, :unchanged} = on_record(repo_key, hand_move("Done"), DateTime.add(@now, 20))
      assert_received {:memory_tracker_state_update, "issue-observed", "Code Review"}
      refute_received {:memory_tracker_state_update, _issue_id, _state}
      assert event_types(repo_key) == ["drift.detected", "drift.reverted"]
      assert %{detected: 1, reverted: 1, revert_failed: 0} = drift()
    end
  end

  # A record Symphony moved into `phase` at `@phase_at`, after the poll observed the ticket at `@linear_at`.
  defp owned!(repo_key, phase) do
    {:ok, :updated} = TicketObservation.observe(repo_key, linear_issue(%{state: "In Progress"}), now: @now)
    record = repo_key |> RunStore.get_ticket_state("issue-observed") |> TicketState.put_phase(phase, @phase_at)
    :ok = RunStore.put_ticket_state(record)
  end

  # Linear as the agent's Linear tool sees it: the ticket in `from`, its team's `to` state, and the
  # move made.
  defp agent_linear(from, to) do
    fn query, _variables, _opts ->
      if query =~ "SymphonyAgentIssueTeamStates" do
        states = [%{"id" => "state-to", "name" => to}]
        {:ok, %{"data" => %{"issue" => %{"state" => %{"name" => from, "type" => "started"}, "team" => %{"states" => %{"nodes" => states}}}}}}
      else
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  describe "reconcile_all/3" do
    # Linear's read before any move of Symphony's: older than every phase the tests write.
    @read_at ~U[2026-01-01 00:00:00Z]

    setup do
      Process.register(self(), ReconcileProbe)
      on_exit(fn -> for call <- [:update_issue_state, :set_machine_label, :clear_machine_label, :fetch_issue_states_by_ids], do: :persistent_term.erase({ReconcileTracker, call}) end)
      :ok
    end

    test "a move whose Linear write failed is re-applied on the next reconcile, once, and its mark cleared", %{repo_key: repo_key} do
      issue = linear_issue(%{state: "In Progress", updated_at: @read_at})
      {:ok, :updated} = TicketObservation.observe(repo_key, issue, now: @now)
      reply(:update_issue_state, {:error, :unavailable})

      capture_log(fn ->
        ctx = %{target: "Code Review", repo_key: repo_key}
        assert {:error, :unavailable} = TransitionGuard.perform("issue-observed", :director_move, ctx, tracker: ReconcileTracker)
      end)

      assert_received {:tracker, {:update_issue_state, "issue-observed", "Code Review"}}
      assert %{phase: "Code Review", pending_projection: [%{type: :phase, error: ":unavailable"}]} = record(repo_key)

      reply(:update_issue_state, :ok)
      assert %{unchanged: 1} = reconcile(repo_key, [issue])
      assert_received {:tracker, {:update_issue_state, "issue-observed", "Code Review"}}
      assert %{phase: "Code Review", pending_projection: []} = record(repo_key)
      assert %{reapplied: 1, last_run_at: @now} = TicketObservation.summary().reconcile

      # The next reconcile finds nothing to project.
      reconcile(repo_key, [issue])
      refute_received {:tracker, {:update_issue_state, _issue_id, _state}}
      assert TicketObservation.summary().reconcile.reapplied == 1
    end

    test "a failed write that fails again keeps its mark for the next run", %{repo_key: repo_key} do
      marked!(repo_key, "Code Review", :phase)
      reply(:update_issue_state, {:error, :unavailable})

      log = capture_log(fn -> reconcile(repo_key, []) end)
      assert log =~ "Ticket reconcile: projecting :phase again failed issue_id=issue-observed issue_identifier=ACME-7: :unavailable"
      assert [%{type: :phase}] = record(repo_key).pending_projection

      reply(:update_issue_state, :raise)
      log = capture_log(fn -> reconcile(repo_key, []) end)
      assert log =~ "projecting :phase again failed"
      assert [%{type: :phase}] = record(repo_key).pending_projection
      assert TicketObservation.summary().reconcile.reapplied == 0
    end

    test "a mark Linear already shows, one whose phase is not Symphony's, and a removed ticket's are dropped with no write",
         %{repo_key: repo_key} do
      marked!(repo_key, "Code Review", :phase)
      reconcile(repo_key, [linear_issue(%{state: "Code Review", updated_at: @read_at})])
      assert record(repo_key).pending_projection == []

      external = repo_key |> RunStore.get_ticket_state("issue-observed") |> Map.put(:phase_owner, :external) |> TicketState.mark_projection(:phase, :down, @now)
      :ok = RunStore.put_ticket_state(external)
      reconcile(repo_key, [])
      assert record(repo_key).pending_projection == []

      removed =
        repo_key
        |> RunStore.get_ticket_state("issue-observed")
        |> TicketState.mark_removed(@now)
        |> TicketState.mark_projection({:hold_label, :blocked}, :down, @now)

      :ok = RunStore.put_ticket_state(removed)
      reconcile(repo_key, [])
      assert record(repo_key).pending_projection == []

      refute_received {:tracker, _call}
      assert TicketObservation.summary().reconcile.reapplied == 0
    end

    test "a hold's label is set or cleared as the record holds the hold, unless the poll shows it already", %{repo_key: repo_key} do
      marked!(repo_key, "Todo", {:hold_label, :blocked})
      :ok = RunStore.set_ticket_hold(repo_key, "issue-observed", :blocked, %{reason: "waits"})
      reconcile(repo_key, [linear_issue(%{labels: ["backend"], updated_at: @read_at})])
      assert_received {:tracker, {:set_machine_label, "issue-observed", "Blocked"}}
      assert record(repo_key).pending_projection == []

      marked!(repo_key, "Todo", {:hold_label, :needs_decision})
      reconcile(repo_key, [])
      assert_received {:tracker, {:clear_machine_label, "issue-observed", "Needs Decision"}}
      assert record(repo_key).pending_projection == []

      marked!(repo_key, "Todo", {:hold_label, :blocked})
      reconcile(repo_key, [linear_issue(%{labels: ["backend", "blocked"], updated_at: @read_at})])
      refute_received {:tracker, {:set_machine_label, _issue_id, _label}}
      assert record(repo_key).pending_projection == []
      assert TicketObservation.summary().reconcile.reapplied == 2
    end

    test "a new ticket in Linear gets its record, counted as applied", %{repo_key: repo_key} do
      assert %{updated: 1} = reconcile(repo_key, [linear_issue(%{id: "issue-new", identifier: "ACME-9"})])
      assert %{issue_identifier: "ACME-9", phase: "Todo"} = RunStore.get_ticket_state(repo_key, "issue-new")
      assert %{applied: 1, last_run_at: @now} = TicketObservation.summary().reconcile
    end

    test "records no read observed are read by id and filled; removed and polled ones are not read", %{repo_key: repo_key} do
      for {id, attrs} <- [{"never-1", %{}}, {"never-removed", %{removed_at: @now}}, {"never-polled", %{}}],
          do: :ok = RunStore.put_ticket_state(TicketState.new(repo_key, id, attrs))

      filled = linear_issue(%{id: "never-1", identifier: "ACME-11", state: "Done"})
      reply(:fetch_issue_states_by_ids, {:ok, [filled]})

      reconcile(repo_key, [linear_issue(%{id: "never-polled", identifier: "ACME-12"})])
      assert_received {:tracker, {:fetch_issue_states_by_ids, ["never-1"]}}
      assert %{issue_identifier: "ACME-11", phase: "Done", observed_from: :by_id} = RunStore.get_ticket_state(repo_key, "never-1")
      assert TicketObservation.summary().reconcile.unobserved_filled == 1

      # Nothing left unobserved: no read.
      reconcile(repo_key, [])
      refute_received {:tracker, {:fetch_issue_states_by_ids, _ids}}
    end

    test "a by-id read that fails or crashes is logged and fills nothing", %{repo_key: repo_key} do
      :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "never-1"))

      for result <- [{:error, :unavailable}, :raise] do
        reply(:fetch_issue_states_by_ids, result)
        log = capture_log(fn -> reconcile(repo_key, []) end)
        assert log =~ "Ticket reconcile: reading the unobserved records failed repo_key=#{repo_key}"
      end

      assert TicketObservation.summary().reconcile.unobserved_filled == 0
    end

    test "a follow-up that can't start or can't read the records is logged; the observations still count", %{repo_key: repo_key} do
      # Without `:now` the run is stamped now.
      opts = [tracker: ReconcileTracker, task_supervisor: SymphonyElixir.TicketObservationTest.Missing]
      log = capture_log(fn -> assert %{updated: 1} = reconcile_unsupervised(repo_key, opts) end)
      assert log =~ "Ticket reconcile: the follow-up did not start repo_key=#{repo_key}"

      log = capture_log(fn -> reconcile("", []) end)
      assert log =~ "Ticket reconcile: the records could not be read repo_key="
    end
  end

  # Linear's read of the ticket after a person moved it to `state` by hand at `@moved_at`.
  defp hand_move(state, attrs \\ %{}), do: linear_issue(Map.merge(%{state: state, updated_at: @moved_at}, attrs))

  # Observes on the record source and waits for the move back it started.
  defp on_record(repo_key, issue, now) do
    result = observe_on_record(repo_key, issue, now)
    settle()
    result
  end

  defp observe_on_record(repo_key, issue, now),
    do: TicketObservation.observe(repo_key, issue, now: now, dispatch_source: "record", task_supervisor: @moves)

  # The one move back under way, once the others have finished; nil until then.
  defp only_move_back do
    case Task.Supervisor.children(@moves) do
      [mover] -> mover
      _none_or_several -> nil
    end
  end

  # Waits for every move back under way to finish.
  defp settle do
    for pid <- Task.Supervisor.children(@moves) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    :ok
  end

  defp event_types(repo_key), do: repo_key |> ticket_events("issue-observed") |> Enum.map(&elem(&1, 0))

  defp drift, do: TicketObservation.summary().drift

  defp counts, do: Map.drop(TicketObservation.summary(), [:compare, :drift, :reconcile])

  # Reconciles on the record source with the fake tracker, and waits for the follow-up.
  defp reconcile(repo_key, issues) do
    opts = [now: @now, dispatch_source: "record", tracker: ReconcileTracker, task_supervisor: @moves]
    counts = TicketObservation.reconcile_all(repo_key, issues, opts)
    settle()
    counts
  end

  defp reconcile_unsupervised(repo_key, opts), do: TicketObservation.reconcile_all(repo_key, [linear_issue()], opts)

  defp record(repo_key), do: RunStore.get_ticket_state(repo_key, "issue-observed")

  # A record whose phase Symphony wrote, with a failed projection marked.
  defp marked!(repo_key, phase, projection) do
    {:ok, _outcome} = TicketObservation.observe(repo_key, linear_issue(%{updated_at: ~U[2026-01-01 00:00:00Z]}), now: @now)
    record = repo_key |> RunStore.get_ticket_state("issue-observed") |> TicketState.put_phase(phase, @phase_at)
    :ok = RunStore.put_ticket_state(TicketState.mark_projection(record, projection, :unavailable, @phase_at))
  end

  defp reply(call, result), do: :persistent_term.put({ReconcileTracker, call}, result)
  defp compare, do: TicketObservation.summary().compare
end
