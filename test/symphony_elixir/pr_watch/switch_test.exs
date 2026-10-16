defmodule SymphonyElixir.PrWatch.SwitchTest do
  @moduledoc """
  The PR and CI watcher deciding and acting on every CI and merge row (TP-941), tick by tick: the
  incidents it replaces the pollers' stopgaps for, replayed as fixtures, and one test per deciding
  branch the switch deleted from `CiPoller`, `PrReviewPoller`, `AutoMerge` and the orchestrator,
  named after the rule that now covers it.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BlockedHold, CiFix, Hold, PrWatch, TicketPullRequest, TicketState}
  alias SymphonyElixir.PrWatch.{Attempts, Repo}

  @repo_key "default"

  # What the fakes did, in order, and the issues and PRs they serve, kept in one agent.
  defmodule World do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{issues: %{}, prs: %{}, calls: [], fix_tickets: %{}, open_pulls: nil, now: ~U[2026-10-16 12:00:00Z]} end, name: __MODULE__)
    end

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
    def call(name, args), do: update(:calls, &(&1 ++ [{name, args}]))
    def calls(name), do: for({^name, args} <- get(:calls), do: args)
    def all_calls, do: get(:calls)
    def clear_calls, do: Agent.update(__MODULE__, &%{&1 | calls: []})
  end

  defmodule Tracker do
    alias SymphonyElixir.Linear.Issue
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def fetch_issues_by_states_with_failures(states) do
      wanted = MapSet.new(states, &String.downcase/1)
      {:ok, World.get(:issues) |> Map.values() |> Enum.filter(&MapSet.member?(wanted, String.downcase(&1.state))), []}
    end

    def update_issue_state(issue_id, state) do
      World.call(:move, {issue_id, state})
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))
    end

    def create_comment(issue_id, body), do: World.call(:comment, {issue_id, body})
    def set_machine_label(issue_id, label), do: World.call(:label, {issue_id, label})
    def clear_machine_label(_issue_id, _label), do: :ok

    def fetch_issue_by_identifier(identifier) do
      case Map.fetch(World.get(:fix_tickets), identifier) do
        {:ok, state} -> {:ok, %Issue{id: "fix-#{identifier}", identifier: identifier, state: state}}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule GitHub do
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def list_open_pull_requests(_pr_url, _opts) do
      case World.get(:open_pulls) do
        nil -> {:ok, []}
        pulls -> {:ok, pulls}
      end
    end

    def rerun_failed(run_id, _opts), do: World.call(:rerun, run_id)
    def fetch_failed_log(_run_id, _opts), do: {:ok, "setup\nERROR: specs failed at stub_test.exs:21\nstack"}

    def enable_auto_merge(pr_url, request, _opts) do
      World.call(:arm, {pr_url, request.head_sha})
      set_pr(pr_url, auto_merge: :armed)
    end

    def disable_auto_merge(pr_url, _node_id, _opts) do
      World.call(:disarm, pr_url)
      set_pr(pr_url, auto_merge: :off)
    end

    def squash_merge(pr_url, request, _opts), do: World.call(:merge, {pr_url, request.head_sha})
    def update_branch(pr_url, head, _opts), do: World.call(:update_branch, {pr_url, head})

    def cancel_stale_runs(pr_url, head, _opts) do
      World.call(:cancel_stale_runs, {pr_url, head})
      {:ok, [1]}
    end

    defp set_pr(pr_url, attrs), do: World.update(:prs, &Map.update!(&1, pr_url, fn pr -> Map.merge(pr, Map.new(attrs)) end))
  end

  defmodule Fetch do
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def read(pr_url, _opts), do: {:ok, Map.fetch!(World.get(:prs), pr_url)}
  end

  defmodule Fixer do
    alias SymphonyElixir.PrWatch.SwitchTest.World

    def create(attrs, _opts) do
      identifier = "TP-FIX#{length(World.calls(:fix_ticket)) + 1}"
      World.call(:fix_ticket, {identifier, attrs})
      World.update(:fix_tickets, &Map.put(&1, identifier, "Todo"))
      {:ok, %{identifier: identifier, url: "https://linear.app/i/#{identifier}"}}
    end

    def attach(identifier, body, _opts), do: World.call(:evidence, {identifier, body})
    def block(issue, ticket, _opts), do: World.call(:blocked_by, {issue.id, ticket.identifier})
  end

  setup do
    start_supervised!(World)
    workflow!()
    :ok
  end

  defp workflow!(ci \\ %{}) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: Map.merge(%{enabled: true, log_excerpt_lines: 20}, ci)
    )
  end

  # A ticket in `state` with an open PR whose read `attrs` override a green, clean one.
  defp ticket!(id, state, attrs \\ []) do
    pr_url = "https://github.com/acme/app/pull/#{id}"
    issue = %Issue{id: "issue-#{id}", identifier: "TP-#{id}", title: "Ticket #{id}", state: state, url: "https://linear.app/i/TP-#{id}", labels: []}
    World.update(:issues, &Map.put(&1, issue.id, issue))
    :ok = TicketPullRequest.record_created(@repo_key, issue.id, pr_url, "auto/TP-#{id}")
    World.update(:prs, &Map.put(&1, pr_url, Map.merge(read(id), Map.new(attrs))))
    issue.id
  end

  defp read(id) do
    %{
      pr_url: "https://github.com/acme/app/pull/#{id}",
      pr_number: String.to_integer(id),
      pr: :open,
      base: :ok,
      base_ref: "main",
      base_sha: "base-1",
      head_sha: "head-#{id}-1",
      head_ref: "auto/TP-#{id}",
      auto_merge: :off,
      review_comments: :none,
      mergeable: :clean,
      ci: :green,
      missing_checks: [],
      red_kind: :failure,
      failing_check: nil,
      failed_checks: [],
      check_names: ["specs"],
      pr_node_id: "PR_#{id}",
      pr_title: "Ticket #{id}",
      pr_description: "Body",
      rate_limit: %{remaining: 4000, reset_at: nil},
      required: nil
    }
  end

  defp red, do: [ci: :red, failing_check: "specs", failed_checks: [%{name: "specs", run_id: "77", workflow_name: "ci", conclusion: "FAILURE"}]]
  defp dirty, do: [mergeable: :dirty]

  defp pr!(id, attrs), do: World.update(:prs, &Map.update!(&1, "https://github.com/acme/app/pull/#{id}", fn pr -> Map.merge(pr, Map.new(attrs)) end))
  defp pr(id), do: Map.fetch!(World.get(:prs), "https://github.com/acme/app/pull/#{id}")
  defp state(issue_id), do: World.get(:issues) |> Map.fetch!(issue_id) |> Map.fetch!(:state)
  defp move!(issue_id, state), do: World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))

  defp start!(opts \\ []) do
    defaults = [repo_key: @repo_key, name: nil, auto: false, tracker: Tracker, github: GitHub, fetch: Fetch, fixer: Fixer, interval_ms: 30_000, now: fn -> now() end]
    start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  # The watcher's clock, which the test moves on.
  defp now, do: World.get(:now)
  defp advance!(ms), do: World.update(:now, &DateTime.add(&1, ms, :millisecond))

  defp tick!(pid, times \\ 1) do
    for _n <- 1..times, do: assert({:ok, _summary} = Repo.poll(pid))
    :ok
  end

  defp watch(issue_id), do: @repo_key |> RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()
  defp decision(issue_id), do: watch(issue_id).decision
  defp attempts(issue_id), do: watch(issue_id).attempts

  defp moves(issue_id), do: for({^issue_id, state} <- World.calls(:move), do: state)
  defp comments(issue_id), do: for({^issue_id, body} <- World.calls(:comment), do: body)

  defp run!(issue_id, status) do
    :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "run-#{issue_id}", issue_id: issue_id, status: status, started_at: now(), workspace_path: "/tmp/ws"})
  end

  # The CI Fix run pushed `head` and handed the ticket back to `origin`, as `AgentRunner` does.
  defp fix_run_returns!(issue_id, id, origin, head, attrs) do
    assert state(issue_id) == "CI Fix"
    move!(issue_id, origin)
    pr!(id, Keyword.merge([head_sha: head], attrs))
  end

  defp seed_attempts!(issue_id, attempts) do
    SymphonyElixir.PrWatchSupport.update_watch!(@repo_key, issue_id, &%{&1 | attempts: Map.merge(&1.attempts, attempts)})
  end

  defp clear_fix_ticket_hold!(issue_id) do
    issue = %{Map.fetch!(World.get(:issues), issue_id) | repo_key: @repo_key}
    assert :clear = BlockedHold.sync(issue, Config.settings!().tracker.terminal_states, tracker: Tracker, build: %{sha: nil}, settings: Config.settings!())
  end

  describe "the red head of a reviewed ticket (TP-920/TP-892, D15 (c))" do
    test "reruns once, goes to CI Fix with its origin, again for each red head, and at 10 red runs files a fix ticket for CI" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()

      for run <- 1..10 do
        head = "head-1-#{run}"
        pr!("1", head_sha: head)

        # The first read of a red head reruns its failed check; the head still red goes to CI Fix.
        tick!(pid)
        assert %{rule: "R22", kind: :rerun_failed} = decision(issue_id)
        tick!(pid)
        assert %{rule: "R21", kind: :ci_fix, reason: reason} = decision(issue_id)
        assert reason == "The `specs` check failed on PR #1: CI Fix run #{run} of 10"
        assert state(issue_id) == "CI Fix"
        assert CiFix.origin(@repo_key, issue_id) == "Code Review"

        # The run fixed nothing: it pushed a new head, still red, and handed the ticket back.
        fix_run_returns!(issue_id, "1", "Code Review", "head-1-#{run + 1}", red())
      end

      assert length(World.calls(:rerun)) == 10
      assert moves(issue_id) == List.duplicate("CI Fix", 10)
      assert %{red: 10, fix_failures: failures} = attempts(issue_id)
      assert length(failures) == 10
      assert hd(failures) == %{check: "specs", error: "ERROR: specs failed at stub_test.exs:21"}

      # The backstop: one fix ticket for the failing check, linked as a blocker, and a Blocked hold.
      tick!(pid)
      assert [{"TP-FIX1", %{component: "ci:specs", scope: @repo_key, title: "Self-heal: CI keeps failing the specs check", description: description}}] = World.calls(:fix_ticket)
      assert description =~ "The failure may be that pull request's own rather than this repo's CI"
      assert description =~ "https://github.com/acme/app/pull/1"
      assert World.calls(:blocked_by) == [{issue_id, "TP-FIX1"}]
      assert %{waits_on: %{type: "fix_ticket", keys: ["TP-FIX1"]}} = Hold.get(@repo_key, issue_id, :blocked)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)

      assert %{rule: "R20", kind: :file_fix_ticket, reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check", owner: :symphony} =
               decision(issue_id)

      assert decision(issue_id).waits_on == %{type: "fix_ticket", keys: ["TP-FIX1"]}
      assert state(issue_id) == "Code Review"
      assert moves(issue_id) == List.duplicate("CI Fix", 10)

      # Held, the ticket waits on its fix ticket, and nothing is filed or moved again.
      tick!(pid, 3)
      assert %{rule: "R4", reason: "CI keeps failing: waiting on TP-FIX1, a fix ticket for the `specs` check"} = decision(issue_id)
      assert decision(issue_id).waits_on == %{type: "fix_ticket", keys: ["TP-FIX1"]}
      assert length(World.calls(:fix_ticket)) == 1
      assert moves(issue_id) == List.duplicate("CI Fix", 10)

      # The R20 wait as the state API shows it.
      assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) =~ "waiting on TP-FIX1"
    end

    test "a second ticket at the backstop on the same check reuses the open fix ticket, with its own evidence" do
      first = ticket!("1", "Code Review", red())
      second = ticket!("2", "QA", red())
      pid = start!()
      tick!(pid)

      for issue_id <- [first, second], do: seed_attempts!(issue_id, %{red: 10, fix_failures: [%{check: "specs", error: "ERROR in #{issue_id}"}]})
      tick!(pid)

      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)
      assert World.calls(:blocked_by) == [{first, "TP-FIX1"}, {second, "TP-FIX1"}]

      for issue_id <- [first, second] do
        assert %{waits_on: %{type: "fix_ticket", keys: ["TP-FIX1"]}} = Hold.get(@repo_key, issue_id, :blocked)
      end

      assert [{"TP-FIX1", evidence}] = World.calls(:evidence)
      assert evidence =~ "TP-2"
      assert evidence =~ "ERROR in #{second}"
      assert evidence =~ "https://github.com/acme/app/pull/2"
    end

    test "the fix ticket landing clears the hold and restarts the red count; the same failure after it escalates once" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)
      assert Hold.held?(@repo_key, issue_id, :blocked)

      # The fix ticket goes to Done: the hold clears by itself and the red count restarts.
      World.update(:fix_tickets, &Map.put(&1, "TP-FIX1", "Done"))
      clear_fix_ticket_hold!(issue_id)
      refute Hold.held?(@repo_key, issue_id, :blocked)

      # The red count reads 0 of 10, and the head, still red (and rerun already), goes to CI Fix again.
      tick!(pid)
      assert %{red_attempts: 0, max_red_attempts: 10} = watch(issue_id).facts
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 1 of 10"} = decision(issue_id)
      assert %{red: 1, fix_ticket: nil} = attempts(issue_id)
      assert state(issue_id) == "CI Fix"

      # The same failure reaches the backstop again on the next head: the lane asks a person, once.
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-2", red())
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid, 3)

      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)
      assert %{decision: %{title: "Self-heal is stuck on the ci:specs block"}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert [_one] = Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Self-heal is stuck"))
      assert %{rule: "R4", owner: :person} = decision(issue_id)
    end

    test "a Merging ticket at the backstop has auto-merge turned off before the hold is set" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()
      tick!(pid)
      World.clear_calls()
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)

      order = World.all_calls() |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in [:disarm, :fix_ticket, :label]))
      assert [:disarm, :fix_ticket, :label | _rest] = order
      assert pr("1").auto_merge == :off
      assert Hold.held?(@repo_key, issue_id, :blocked)
      assert state(issue_id) == "Merging"
    end

    test "max_fix_attempts set to 4 files the fix ticket at 4, while a conflict still gets 3 fix runs" do
      workflow!(%{max_retries: 4})
      red_id = ticket!("1", "QA", red())
      conflict_id = ticket!("2", "QA", dirty())
      pid = start!()
      tick!(pid)

      assert %{max_red_attempts: 4} = watch(red_id).facts
      assert %{rule: "R14", reason: "PR #2 conflicts with main: conflict fix run 1 of 3"} = decision(conflict_id)
      seed_attempts!(red_id, %{red: 3})
      tick!(pid)
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 4 of 4"} = decision(red_id)

      fix_run_returns!(red_id, "1", "QA", "head-1-2", red())
      tick!(pid)
      assert %{rule: "R20"} = decision(red_id)
      assert [{"TP-FIX1", _attrs}] = World.calls(:fix_ticket)

      # In CI Fix, the run sent for the conflict takes it: no second attempt.
      assert %{rule: "R14", reason: "The CI Fix run already sent for this head takes the fix"} = decision(conflict_id)
      assert %{conflict: 1} = attempts(conflict_id)
      fix_run_returns!(conflict_id, "2", "QA", "head-2-2", dirty())
      seed_attempts!(conflict_id, %{conflict: 3})
      tick!(pid)
      assert %{rule: "R15a", kind: :to_rework} = decision(conflict_id)
    end

    test "red and conflict keep separate counts: after 2 red and 1 conflict, a red head still goes to CI Fix as run 3 of 10" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 2, conflict: 1})
      tick!(pid)

      assert %{red_attempts: 2, conflict_attempts: 1} = watch(issue_id).facts
      assert %{rule: "R21", reason: "The `specs` check failed on PR #1: CI Fix run 3 of 10"} = decision(issue_id)
      assert %{red: 3, conflict: 1} = attempts(issue_id)
    end

    test "a conflicting PR whose checks read green resets neither count; a green, conflict-free head resets both" do
      issue_id = ticket!("1", "Code Review", dirty() ++ [head_sha: "head-1-9"])
      pid = start!()
      tick!(pid)
      assert state(issue_id) == "CI Fix"
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-10", dirty())
      seed_attempts!(issue_id, %{red: 2, conflict: 2})

      tick!(pid)
      assert %{red: 2, conflict: 3} = attempts(issue_id)

      fix_run_returns!(issue_id, "1", "Code Review", "head-1-11", ci: :green, mergeable: :clean)
      tick!(pid)
      assert %{red: 0, conflict: 0} = attempts(issue_id)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)

      # A later conflict starts again at attempt 1.
      pr!("1", dirty())
      tick!(pid)
      assert %{rule: "R14", reason: "PR #1 conflicts with main: conflict fix run 1 of 3"} = decision(issue_id)
    end
  end

  describe "Merging (TP-896, TP-921/TP-891, D4)" do
    test "a red, armed Merging PR has auto-merge turned off and goes to CI Fix; back on a new head, auto-merge is on again" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()

      tick!(pid)
      # A rerun of the same commit keeps auto-merge on.
      assert %{rule: "R22"} = decision(issue_id)
      assert World.calls(:disarm) == []

      tick!(pid)
      assert %{rule: "R21"} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert state(issue_id) == "CI Fix"
      assert CiFix.origin(@repo_key, issue_id) == "Merging"
      assert %{ci_failure: %{approved: true}} = watch(issue_id).fix
      assert Enum.any?(comments(issue_id), &(&1 =~ "because CI failed and a fix run may push new code"))

      fix_run_returns!(issue_id, "1", "Merging", "head-1-2", ci: :pending, mergeable: :blocked, failed_checks: [])
      tick!(pid)
      assert %{rule: "R30", kind: :arm} = decision(issue_id)
      assert World.calls(:arm) == [{"https://github.com/acme/app/pull/1", "head-1-2"}]

      # Auto-merge lands it once the checks pass, and the ticket is Done.
      pr!("1", pr: :merged)
      tick!(pid)
      assert %{rule: "R2", kind: :close_out} = decision(issue_id)
      assert List.last(moves(issue_id)) == "Done"
      assert %{state: "merged"} = TicketPullRequest.get(@repo_key, issue_id)
    end

    test "a conflicting Merging PR waits for its run to end, then goes to CI Fix, with no arm/disarm flapping over 10 ticks" do
      issue_id = ticket!("1", "Merging", dirty() ++ [auto_merge: :armed])
      run!(issue_id, "running")
      pid = start!()

      tick!(pid, 3)
      assert %{rule: "R9", kind: :wait} = decision(issue_id)
      assert moves(issue_id) == []

      run!(issue_id, "success")
      tick!(pid, 10)

      assert moves(issue_id) == ["CI Fix"]
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert World.calls(:arm) == []
      assert %{conflict: 1} = attempts(issue_id)
      assert %{pr_conflict: %{approved: true, retry_count: 1}} = watch(issue_id).fix
    end

    test "a Merging PR that conflicts while a PR sharing its files is ahead waits, auto-merge off, and gets one CI Fix once that one merged" do
      leader = ticket!("1", "Merging", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "Merging", dirty() ++ [auto_merge: :armed])

      World.update(:open_pulls, fn _ ->
        [%{number: 1, head_sha: "head-1-1", files: ["lib/a.ex"]}, %{number: 2, head_sha: "head-2-1", files: ["lib/a.ex", "lib/b.ex"]}]
      end)

      pid = start!()
      # The leader entered Merging first.
      tick!(pid)
      tick!(pid, 2)

      assert %{rule: "R14a", kind: :wait_for_competitors, reason: "Lands after TP-1: they change the same files (lib/a.ex)", owner: :symphony} =
               decision(follower)

      assert decision(follower).waits_on == %{type: "pull_request", keys: ["TP-1"]}
      assert moves(follower) == []
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/2"]
      assert [%{issue_identifier: "TP-2", waits_for: %{issue_identifier: "TP-1"}, reason: "Lands after TP-1" <> _}] = PrWatch.landing_waits()

      # The leader merged and left the open PRs: the follower's conflict gets one fix run.
      pr!("1", pr: :merged)
      World.update(:open_pulls, fn _ -> [%{number: 2, head_sha: "head-2-1", files: ["lib/a.ex", "lib/b.ex"]}] end)
      tick!(pid, 3)

      assert moves(leader) == ["Done"]
      assert moves(follower) == ["CI Fix"]
      assert %{rule: "R14"} = decision(follower)
    end

    test "a third conflict fix run that leaves the PR conflicting, with nobody competing, sends it to Rework (D16), with no question" do
      issue_id = ticket!("1", "Merging", dirty() ++ [auto_merge: :armed])
      pid = start!()

      for run <- 1..3 do
        tick!(pid)
        assert %{rule: "R14", reason: reason} = decision(issue_id)
        assert reason == "PR #1 conflicts with main: conflict fix run #{run} of 3"
        fix_run_returns!(issue_id, "1", "Merging", "head-1-#{run + 1}", dirty())
      end

      tick!(pid)
      reason = "The conflict with main came back after 3 fix runs and no open PR competes"
      assert %{rule: "R15a", kind: :to_rework, reason: ^reason} = decision(issue_id)
      assert List.last(moves(issue_id)) == "Rework"
      assert Enum.any?(comments(issue_id), &(&1 =~ reason))
      assert pr("1").auto_merge == :off
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "a person's push in Merging turns auto-merge off and sends the ticket back to Code Review (D4)" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean, auto_merge: :armed)
      pid = start!()
      tick!(pid)
      assert %{rule: "R32"} = decision(issue_id)

      pr!("1", head_sha: "head-1-person")
      tick!(pid)

      assert %{rule: "R11", kind: :to_code_review} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert moves(issue_id) == ["Code Review"]
    end

    test "BEHIND gets one update-branch per head, whose old head's runs are cancelled; BEHIND behind another PR waits" do
      issue_id = ticket!("1", "Merging", mergeable: :behind, ci: :green)
      pid = start!()

      tick!(pid, 3)
      assert %{rule: "R28", kind: :update_branch} = decision(issue_id)
      assert World.calls(:update_branch) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]

      # GitHub merged the base in: a new head, behind again once the base moved on.
      pr!("1", head_sha: "head-1-2")
      tick!(pid, 2)
      assert World.calls(:cancel_stale_runs) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
      assert World.calls(:update_branch) == [{"https://github.com/acme/app/pull/1", "head-1-1"}, {"https://github.com/acme/app/pull/1", "head-1-2"}]
      # An update-branch's head is Symphony's, not a person's.
      assert moves(issue_id) == []

      follower = ticket!("2", "Merging", mergeable: :behind)
      World.update(:open_pulls, fn _ -> [%{number: 1, head_sha: "head-1-2", files: ["x"]}, %{number: 2, head_sha: "head-2-1", files: ["x"]}] end)
      tick!(pid, 2)
      assert %{rule: "R28", kind: :wait, reason: "PR #2 is behind main and lands after TP-1: they change the same files (x)"} = decision(follower)
      refute Enum.any?(World.calls(:update_branch), &match?({"https://github.com/acme/app/pull/2", _head}, &1))
    end

    test "CLEAN and green merges now, once" do
      issue_id = ticket!("1", "Merging")
      pid = start!()
      tick!(pid, 3)

      assert %{rule: "R29", kind: :merge_now} = decision(issue_id)
      assert World.calls(:merge) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
    end

    test "BLOCKED on a green head past the merge wait hands the PR to the landing agent" do
      issue_id = ticket!("1", "Merging", mergeable: :blocked, auto_merge: :armed)
      pid = start!()
      tick!(pid)
      assert %{rule: "R33"} = decision(issue_id)
      refute PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil

      advance!(Config.settings!().ci.merging_wait_timeout_ms)
      tick!(pid, 2)

      assert %{rule: "R31", kind: :land_agent} = decision(issue_id)
      assert [_one] = Enum.filter(comments(issue_id), &(&1 =~ "so a landing agent will merge it instead"))
      assert PrWatch.dispatch_reason(Map.fetch!(World.get(:issues), issue_id), Config.settings!()) == nil
    end
  end

  describe "holds and phases (G7, G8)" do
    test "a ticket on a Needs Decision hold with a red head is not moved" do
      issue_id = ticket!("1", "Code Review", red())
      :ok = Hold.set(@repo_key, issue_id, :needs_decision, %{reason: "a question"}, tracker: Tracker)
      pid = start!()
      tick!(pid, 3)

      assert %{rule: "R4", owner: :person} = decision(issue_id)
      assert moves(issue_id) == []
      assert World.calls(:rerun) == []
    end

    test "a Rework ticket with a red head and no run goes to CI Fix" do
      issue_id = ticket!("1", "Rework", red())
      pid = start!()
      tick!(pid, 2)

      assert moves(issue_id) == ["CI Fix"]
      assert CiFix.origin(@repo_key, issue_id) == "Rework"
    end

    test "a ticket that left Merging with auto-merge on has it turned off (R3), once" do
      issue_id = ticket!("1", "QA", auto_merge: :armed)
      pid = start!()
      tick!(pid, 3)

      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert Enum.any?(comments(issue_id), &(&1 =~ "because this ticket left Merging for QA"))
    end

    test "a repeated tick never repeats a move, a rerun, an update-branch or a fix-ticket filing" do
      red_id = ticket!("1", "Code Review", red())
      behind_id = ticket!("2", "Merging", mergeable: :behind)
      pid = start!()
      tick!(pid)
      seed_attempts!(red_id, %{red: 0})

      tick!(pid, 5)
      assert length(World.calls(:rerun)) == 1
      assert length(World.calls(:update_branch)) == 1
      assert moves(red_id) == ["CI Fix"]

      assert moves(behind_id) == []

      seed_attempts!(red_id, %{red: 10})
      tick!(pid, 4)
      assert length(World.calls(:fix_ticket)) == 1
    end
  end

  describe "each deleted deciding branch, and the rule that covers it now" do
    test "CiPoller.handle_ci_failure's first rerun of a red head → R22 rerun_failed, once per head" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      assert %{rule: "R22"} = decision(issue_id)
      assert World.calls(:rerun) == ["77"]
      assert %{reruns: %{"head-1-1" => ["specs"]}} = attempts(issue_id)
    end

    test "CiPoller's rerun-pending mark → Attempts.rerun_pending?: a rerun whose checks left the rollup reads running (R24)" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)

      pr!("1", ci: :green, failed_checks: [], check_names: [])
      tick!(pid)
      assert %{ci: :pending} = watch(issue_id).facts
      assert %{rule: "R24"} = decision(issue_id)
    end

    test "CiPoller.dispatch_ci_failure → R21 ci_fix: CI Fix with its origin, the failure kept for the run's prompt" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      assert %{ci_failure: %{commit_sha: "head-1-1", log_excerpt: "ERROR: specs failed at stub_test.exs:21\nstack"}} = watch(issue_id).fix
      assert PrWatch.pending_ci_failure(issue_id)[:commit_sha] == "head-1-1"
    end

    test "CiPoller.escalate_ci_failure (a question after max retries) → R20 file_fix_ticket, no Needs Decision hold" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      seed_attempts!(issue_id, %{red: 10})
      tick!(pid)
      assert %{rule: "R20"} = decision(issue_id)
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "CiPoller.back_from_ci_fix_on_red_head? → R21: a ticket back from CI Fix on the same red head goes to CI Fix again" do
      issue_id = ticket!("1", "Code Review", red())
      pid = start!()
      tick!(pid, 2)
      fix_run_returns!(issue_id, "1", "Code Review", "head-1-1", red())
      tick!(pid)
      assert moves(issue_id) == ["CI Fix", "CI Fix"]
      assert %{red: 2} = attempts(issue_id)
    end

    test "CiPoller.await_waiver → R18: a protected paths check that only a person clears is left alone outside Merging" do
      issue_id = ticket!("1", "QA", ci: :red, red_kind: :human_only, failing_check: "protected paths", failed_checks: [%{name: "protected paths", run_id: "5"}])
      pid = start!()
      tick!(pid, 2)
      assert %{rule: "R18", kind: :decision, outcome: :recorded} = decision(issue_id)
      assert moves(issue_id) == []
      assert World.calls(:rerun) == []
    end

    test "AutoMerge's protected paths gate → R18 in Merging: auto-merge off and a person asked, once" do
      issue_id = ticket!("1", "Merging", ci: :red, red_kind: :human_only, auto_merge: :armed, failing_check: "protected paths", failed_checks: [%{name: "protected paths", run_id: "5"}])
      pid = start!()
      tick!(pid, 3)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
      assert %{decision: %{title: "Protected files changed on TP-1"}} = Hold.get(@repo_key, issue_id, :needs_decision)
      assert [_one] = Enum.filter(comments(issue_id), &String.starts_with?(&1, "## Decision needed: Protected files"))
    end

    test "CiPoller/PrReviewPoller parked_for_person → R4: a held ticket waits, whatever its PR" do
      issue_id = ticket!("1", "QA", dirty())
      :ok = Hold.set(@repo_key, issue_id, :blocked, %{reason: "waiting"}, tracker: Tracker)
      pid = start!()
      tick!(pid)
      assert %{rule: "R4", owner: :symphony} = decision(issue_id)
      assert moves(issue_id) == []
    end

    test "CiPoller.mark_ci_green → Attempts reset: a green, conflict-free head clears the counts and its failure" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      fix_run_returns!(issue_id, "1", "QA", "head-1-2", ci: :green, failed_checks: [])
      tick!(pid)
      assert %{red: 0} = attempts(issue_id)
      assert watch(issue_id).fix == %{ci_failure: nil, pr_conflict: nil}
    end

    test "CiPoller.hold_auto_merge_for_fix → R21 in Merging: auto-merge off before CI Fix" do
      issue_id = ticket!("1", "Merging", red() ++ [auto_merge: :armed])
      pid = start!()
      tick!(pid, 2)
      assert [{:disarm, _url}, {:move, {^issue_id, "CI Fix"}}] = Enum.filter(World.all_calls(), &(elem(&1, 0) in [:disarm, :move]))
    end

    test "CiPoller.track_landing_wait (land past pending checks after 15 minutes) → R30: auto-merge lands it" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :unstable)
      pid = start!()
      tick!(pid)
      assert %{rule: "R30", kind: :arm} = decision(issue_id)
    end

    test "CiPoller.rework_in_progress? and PrReviewPoller's active-run check → R9: nothing while a run works on the ticket" do
      issue_id = ticket!("1", "QA", red())
      run!(issue_id, "running")
      pid = start!()
      tick!(pid, 2)
      assert %{rule: "R9"} = decision(issue_id)
      assert World.calls(:rerun) == []
    end

    test "PrReviewPoller.maybe_transition_conflict → R14 ci_fix: a conflict goes to CI Fix with its context" do
      issue_id = ticket!("1", "Code Review", dirty())
      pid = start!()
      tick!(pid)
      assert moves(issue_id) == ["CI Fix"]
      assert %{conflict_key: "head-1-1|base-1", retry_count: 1, approved: false} = PrWatch.pending_pr_conflict(issue_id)
    end

    test "PrReviewPoller.back_from_ci_fix_on_conflict? → R14: back from CI Fix on the same conflict, it goes to CI Fix again" do
      issue_id = ticket!("1", "QA", dirty())
      pid = start!()
      tick!(pid)
      fix_run_returns!(issue_id, "1", "QA", "head-1-1", dirty())
      tick!(pid)
      assert moves(issue_id) == ["CI Fix", "CI Fix"]
    end

    test "PrReviewPoller.escalate_conflict and its silent `conflict_escalated` record (G3) → R15a to_rework" do
      issue_id = ticket!("1", "QA", dirty())
      pid = start!()
      tick!(pid)
      fix_run_returns!(issue_id, "1", "QA", "head-1-2", dirty())
      seed_attempts!(issue_id, %{conflict: 3})
      tick!(pid)
      assert List.last(moves(issue_id)) == "Rework"
      refute Hold.held?(@repo_key, issue_id, :needs_decision)
    end

    test "PrReviewPoller.wait_to_land and AutoMerge's landing-order check → R14a and R28: wait for the PR ahead" do
      ticket!("1", "Merging", ci: :pending, mergeable: :blocked)
      follower = ticket!("2", "QA", dirty())
      World.update(:open_pulls, fn _ -> [%{number: 1, head_sha: "head-1-1", files: ["x"]}, %{number: 2, head_sha: "head-2-1", files: ["x"]}] end)
      pid = start!()
      tick!(pid, 2)
      assert %{rule: "R14a"} = decision(follower)
      assert moves(follower) == []
    end

    test "PrReviewPoller.turn_off_auto_merge_on_exit → R3 disarm" do
      issue_id = ticket!("1", "Rework", auto_merge: :armed, ci: :pending)
      pid = start!()
      tick!(pid)
      assert %{rule: "R3"} = decision(issue_id)
      assert World.calls(:disarm) == ["https://github.com/acme/app/pull/1"]
    end

    test "PrReviewPoller.finish_merged's move to Done → R2 close_out" do
      issue_id = ticket!("1", "Merging", pr: :merged)
      pid = start!()
      tick!(pid, 2)
      assert moves(issue_id) == ["Done"]
    end

    test "AutoMerge.step's merge_if_ready and refused-merge path → R29 merge_now" do
      issue_id = ticket!("1", "Merging", mergeable: :unstable)
      pid = start!()
      tick!(pid)
      assert %{rule: "R29"} = decision(issue_id)
    end

    test "AutoMerge.step's enable once per head → R30 arm, once per head and stay" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean)
      pid = start!()
      tick!(pid, 3)
      assert World.calls(:arm) == [{"https://github.com/acme/app/pull/1", "head-1-1"}]
      assert %{rule: "R32"} = decision(issue_id)
    end

    test "AutoMerge's head-moved retries → an error leaves the record re-decidable on the next tick" do
      issue_id = ticket!("1", "Merging", ci: :pending, mergeable: :clean)
      Process.put(:never, :used)

      defmodule MovingGitHub do
        alias SymphonyElixir.PrWatch.SwitchTest.{GitHub, World}
        defdelegate list_open_pull_requests(url, opts), to: GitHub

        def enable_auto_merge(_url, request, _opts) do
          World.call(:arm_attempt, request.head_sha)
          {:error, :head_moved}
        end
      end

      pid = start!(github: MovingGitHub)
      capture_log(fn -> tick!(pid, 2) end)
      assert World.calls(:arm_attempt) == ["head-1-1", "head-1-1"]
      assert %{rule: "R30", outcome: :error, error: ":head_moved"} = decision(issue_id)
      assert watch(issue_id).applied == []
    end

    test "AutoMerge.check_stalled and owns_issue? → R31 land_agent and the orchestrator's gate read from the decision" do
      issue_id = ticket!("1", "Merging", mergeable: :blocked)
      pid = start!()
      tick!(pid)
      issue = Map.fetch!(World.get(:issues), issue_id)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) =~ "the PR watcher (R30)"
    end

    test "AutoMerge's held?/conflict? stopgaps (TP-896, TP-921) → R30 needs a conflict-free head: no re-arm while dirty" do
      issue_id = ticket!("1", "Merging", dirty())
      run!(issue_id, "running")
      pid = start!()
      tick!(pid, 5)
      assert World.calls(:arm) == []
    end

    test "the orchestrator's 'waits for its head to go green' gate → R27: a Code Review run on a green head only" do
      issue_id = ticket!("1", "Code Review", ci: :pending)
      pid = start!()
      tick!(pid)
      issue = Map.fetch!(World.get(:issues), issue_id)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) =~ "the PR watcher (R24): Checks are running"

      pr!("1", ci: :green)
      tick!(pid)
      assert PrWatch.dispatch_reason(issue, Config.settings!()) == nil
    end

    test "a CI Fix ticket left in the lane on a green, conflict-free head → R25 return_to_origin" do
      issue_id = ticket!("1", "CI Fix")
      :ok = CiFix.record_origin(@repo_key, issue_id, "QA")
      pid = start!()
      tick!(pid)
      assert moves(issue_id) == ["QA"]
      assert CiFix.origin(@repo_key, issue_id) == nil
    end

    test "a ticket in CI Fix that entered it for its red head spends no second attempt on the run already sent" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid, 2)
      assert state(issue_id) == "CI Fix"
      tick!(pid, 2)
      assert %{red: 1} = attempts(issue_id)

      # A new red head the run pushed while the ticket stayed in the lane is another fix run, once
      # its rerun failed too.
      pr!("1", head_sha: "head-1-2")
      tick!(pid, 2)
      assert %{red: 2, sent: %{head_sha: "head-1-2", cause: :red}} = attempts(issue_id)
      assert moves(issue_id) == ["CI Fix"]
    end

    test "Attempts is the watcher's own: a ticket that left the watched phases starts again" do
      issue_id = ticket!("1", "QA", red())
      pid = start!()
      tick!(pid)
      move!(issue_id, "Todo")
      tick!(pid)
      assert watch(issue_id) == nil
      assert Attempts.normalize(nil) == Attempts.new()
    end
  end
end
