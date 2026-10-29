defmodule SymphonyElixir.TicketObservationTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{TicketObservation, TicketState}

  @linear_at ~U[2026-10-29 09:00:00Z]
  @now ~U[2026-10-29 09:05:00Z]
  @created_at ~U[2026-10-01 08:00:00Z]

  setup do
    TicketObservation.reset()
    on_exit(&TicketObservation.reset/0)
    %{repo_key: Config.repo_key!()}
  end

  defp linear_issue(attrs \\ %{}) do
    struct!(
      %Issue{
        id: "issue-observed",
        identifier: "ACME-7",
        title: "Observe every poll",
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
               compare: %{webhook_first: 0, poll_first: 0, poll_first_recent: []}
             }

    assert :ok = TicketObservation.reset()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, TicketObservation)
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

      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60)) == :updated

      record = RunStore.get_ticket_state(repo_key, "issue-observed")
      assert %{issue_identifier: "ACME-7", priority: 1, observed_from: :webhook} = record
      assert record.observed_at == DateTime.add(@now, 60)
      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60)) == :unchanged
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

    test "a ticket held in several repos is unrouted, and both records are left" do
      held = Enum.map([@default_repo, @project_repo], &poll!/1)

      edited = delivery(%{priority: 1, updated_at: DateTime.add(@linear_at, 60)})
      assert TicketObservation.observe_delivery(edited, now: DateTime.add(@now, 60), repos: @slug_routes) == :unrouted
      assert Enum.map([@default_repo, @project_repo], &RunStore.get_ticket_state(&1, "issue-observed")) == held
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
      assert TicketObservation.observe_delivery({:issue_removed, "issue-never-seen", nil}, now: @now) == :no_record

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

  defp counts, do: Map.delete(TicketObservation.summary(), :compare)
  defp compare, do: TicketObservation.summary().compare
end
