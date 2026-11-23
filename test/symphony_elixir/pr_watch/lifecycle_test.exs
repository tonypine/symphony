defmodule SymphonyElixir.PrWatch.LifecycleTest do
  @moduledoc """
  The PR and CI watcher on a PR's life (TP-944), tick by tick: a PR merged in any phase, closed
  without merging, marked draft, retargeted to another base, its branch deleted, missing from the
  ticket, and left with review comments. Each test asserts the action and that the ticket is never
  left in an active phase with neither a run nor a recorded wait (`accounted!/1`).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ClosedPullRequest, IdlePark, Pauses, PrWatch, Questions, TicketPullRequest, TicketState}
  alias SymphonyElixir.Dispatch.Slots
  alias SymphonyElixir.PrDecision.{Action, Facts}
  alias SymphonyElixir.PrWatch.Repo

  @repo_key "default"

  # What the fakes did, in order, and the issues and PRs they serve, kept in one agent.
  defmodule World do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{issues: %{}, prs: %{}, calls: [], now: ~U[2026-10-16 12:00:00Z]} end, name: __MODULE__)
    end

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))
    def call(name, args), do: update(:calls, &(&1 ++ [{name, args}]))
    def calls(name), do: for({^name, args} <- get(:calls), do: args)
  end

  defmodule Tracker do
    alias SymphonyElixir.PrWatch.LifecycleTest.World

    def fetch_issues_by_states_with_failures(states) do
      wanted = MapSet.new(states, &String.downcase/1)
      {:ok, World.get(:issues) |> Map.values() |> Enum.filter(&MapSet.member?(wanted, String.downcase(&1.state))), []}
    end

    def update_issue_state(issue_id, state) do
      World.call(:move, {issue_id, state})
      World.update(:issues, &Map.update!(&1, issue_id, fn issue -> %{issue | state: state} end))
    end

    def create_comment(issue_id, body), do: World.call(:comment, {issue_id, body})
    def set_machine_label(_issue_id, _label), do: :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  defmodule GitHub do
    alias SymphonyElixir.PrWatch.LifecycleTest.World

    def list_open_pull_requests(_pr_url, _opts), do: {:ok, []}

    def enable_auto_merge(pr_url, request, _opts) do
      World.call(:arm, {pr_url, request.head_sha})
      set_pr(pr_url, auto_merge: :armed)
    end

    def disable_auto_merge(pr_url, _node_id, _opts) do
      World.call(:disarm, pr_url)
      set_pr(pr_url, auto_merge: :off)
    end

    def change_base(pr_url, base, _opts) do
      World.call(:change_base, {pr_url, base})
      set_pr(pr_url, base_ref: base, base: :ok)
    end

    def squash_merge(pr_url, request, _opts), do: World.call(:merge, {pr_url, request.head_sha})
    def update_branch(pr_url, head, _opts), do: World.call(:update_branch, {pr_url, head})
    def rerun_failed(run_id, _opts), do: World.call(:rerun, run_id)
    def cancel_stale_runs(_pr_url, _head, _opts), do: {:ok, []}

    defp set_pr(pr_url, attrs), do: World.update(:prs, &Map.update!(&1, pr_url, fn pr -> Map.merge(pr, Map.new(attrs)) end))
  end

  defmodule Fetch do
    alias SymphonyElixir.PrWatch.LifecycleTest.World

    def read(pr_url, opts) do
      World.call(:read, {pr_url, Keyword.get(opts, :base_branch)})
      {:ok, Map.fetch!(World.get(:prs), pr_url)}
    end
  end

  setup do
    start_supervised!(World)
    write_workflow_file!(Workflow.workflow_file_path(), pr_review_mode: "polling", ci: %{enabled: true})
    :ok
  end

  # A ticket in `state` with an open PR whose read `attrs` override a green, clean one.
  defp ticket!(id, state, attrs \\ [], issue_attrs \\ []) do
    issue = struct!(%Issue{id: "issue-#{id}", identifier: "TP-#{id}", title: "Ticket #{id}", state: state, labels: []}, issue_attrs)
    World.update(:issues, &Map.put(&1, issue.id, issue))
    open_pr!(issue.id, id, attrs)
    issue.id
  end

  # A ticket in `state` with no PR at all.
  defp bare_ticket!(id, state, issue_attrs \\ []) do
    issue = struct!(%Issue{id: "issue-#{id}", identifier: "TP-#{id}", title: "Ticket #{id}", state: state, labels: []}, issue_attrs)
    World.update(:issues, &Map.put(&1, issue.id, issue))
    issue.id
  end

  # The ticket's run opened PR `number`: Symphony records it, as `TicketPullRequest.record_created/4` does.
  defp open_pr!(issue_id, number, attrs \\ []) do
    pr_url = url(number)
    :ok = TicketPullRequest.record_created(@repo_key, issue_id, pr_url, "auto/#{issue_id}")
    World.update(:prs, &Map.put(&1, pr_url, Map.merge(read(number), Map.new(attrs))))
  end

  defp url(number), do: "https://github.com/acme/app/pull/#{number}"

  defp read(number) do
    number = to_string(number)

    %{
      pr_url: url(number),
      pr_number: String.to_integer(number),
      pr: :open,
      base: :ok,
      base_ref: "main",
      base_branch: "main",
      base_sha: "base-1",
      head_sha: "head-#{number}-1",
      head_ref: "auto/TP-#{number}",
      auto_merge: :off,
      mergeable: :clean,
      ci: :green,
      missing_checks: [],
      red_kind: :failure,
      past_human_only: nil,
      failing_check: nil,
      failed_checks: [],
      check_names: ["specs"],
      pr_node_id: "PR_#{number}",
      pr_title: "Ticket #{number}",
      pr_description: "Body",
      rate_limit: %{remaining: 4000, reset_at: nil},
      required: nil
    }
  end

  defp pr!(number, attrs), do: World.update(:prs, &Map.update!(&1, url(number), fn pr -> Map.merge(pr, Map.new(attrs)) end))
  defp state(issue_id), do: World.get(:issues) |> Map.fetch!(issue_id) |> Map.fetch!(:state)
  defp issue(issue_id), do: %{Map.fetch!(World.get(:issues), issue_id) | repo_key: @repo_key}

  defp start!(opts \\ []) do
    defaults = [
      repo_key: @repo_key,
      name: nil,
      auto: false,
      tracker: Tracker,
      github: GitHub,
      fetch: Fetch,
      interval_ms: 30_000,
      now: fn -> World.get(:now) end,
      follow_records: false,
      holds_slot: fn _record -> true end
    ]

    start_supervised!({Repo, Keyword.merge(defaults, opts)})
  end

  defp tick!(pid, times \\ 1) do
    for _n <- 1..times, do: assert({:ok, _summary} = Repo.poll(pid))
    :ok
  end

  defp watch(issue_id), do: RunStore.get_ticket_state(issue_id) |> TicketState.pr_watch()
  defp decision(issue_id), do: watch(issue_id).decision
  defp moves(issue_id), do: for({^issue_id, state} <- World.calls(:move), do: state)
  defp comments(issue_id), do: for({^issue_id, body} <- World.calls(:comment), do: body)

  defp run!(issue_id, status) do
    :ok = RunStore.put_run(%{repo_key: @repo_key, run_id: "run-#{issue_id}", issue_id: issue_id, status: status, started_at: World.get(:now), workspace_path: "/tmp/ws"})
  end

  # Nothing waits silently: a ticket the watcher keeps in an active phase is dispatched, or waits on
  # someone for something named, and a ticket it moved is decided again in its new phase.
  defp accounted!(issue_id) do
    case decision(issue_id) do
      %{kind: :dispatch} ->
        :ok

      %{kind: kind, owner: owner, clears_when: clears_when} = decision ->
        assert kind in Action.waiting_kinds(), "#{issue_id} in #{state(issue_id)} has no run and no recorded wait: #{inspect(decision)}"
        assert owner in Action.owners() and is_binary(clears_when)
    end
  end

  describe "a PR merged anywhere (R2, G5)" do
    test "a PR a person merged while its ticket is in QA closes the ticket" do
      issue_id = ticket!("1", "QA")
      pid = start!()
      tick!(pid)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)

      pr!("1", pr: :merged)
      tick!(pid)

      assert state(issue_id) == "Done"
      assert moves(issue_id) == ["Done"]
      assert %{rule: "R2", kind: :close_ticket, reason: "PR #1 was merged", outcome: :applied} = decision(issue_id)
      assert %{state: "merged"} = TicketPullRequest.get(@repo_key, issue_id)

      # Done is not watched: the record goes, nothing moves again.
      tick!(pid, 2)
      assert moves(issue_id) == ["Done"]
      assert watch(issue_id) == nil
    end

    test "in every watched phase, even after the PR review poller marked the PR merged first" do
      pid = start!()

      for {state, n} <- Enum.with_index(["In Progress", "Code Review", "Rework", "CI Fix"], 2) do
        issue_id = ticket!(n, state)
        tick!(pid)

        pr!(n, pr: :merged)
        TicketPullRequest.mark_finished(@repo_key, url(n), "merged")
        tick!(pid)

        assert state(issue_id) == "Done", state
        assert %{rule: "R2", kind: :close_ticket} = decision(issue_id)
      end
    end

    test "a ticket whose started sub-tickets are open waits on them instead" do
      issue_id = ticket!("6", "Code Review", [], sub_issues: [%{id: "sub-1", identifier: "TP-60", state: "In Progress"}])
      pid = start!()
      tick!(pid)

      pr!("6", pr: :merged)
      tick!(pid)
      assert state(issue_id) == "Waiting on sub-tickets"
    end

    test "a reopened ticket whose PR merged before the watcher followed it has no PR yet: the agent opens one (R5)" do
      issue_id = ticket!("7", "In Progress", pr: :merged)
      TicketPullRequest.mark_finished(@repo_key, url(7), "merged")
      pid = start!()
      tick!(pid)

      assert state(issue_id) == "In Progress"
      assert %{facts: %Facts{pr: :missing}, pr_url: nil} = watch(issue_id)
      assert %{rule: "R5", kind: :wait, owner: :agent} = decision(issue_id)
      accounted!(issue_id)
    end
  end

  describe "a PR closed without merging (R8, G4, D5)" do
    test "in Code Review with no run: Rework with the reason, no question; the rework run is dispatched and never moved again" do
      issue_id = ticket!("10", "Code Review")
      pid = start!()
      tick!(pid)

      pr!("10", pr: :closed)
      tick!(pid)

      assert state(issue_id) == "Rework"
      assert %{rule: "R8", kind: :to_rework, reason: "PR #10 was closed without merging", outcome: :applied} = decision(issue_id)
      assert %{facts: %Facts{auto_merge: :off}} = watch(issue_id)
      refute deciding(issue_id)
      assert ["Symphony moved this ticket to Rework: PR #10 was closed without merging. A rework run opens a new pull request from main."] = comments(issue_id)

      # The next ticks dispatch the rework run on the same closed PR and never move it again; the
      # closed-PR guard lets that run start.
      tick!(pid, 3)
      assert %{rule: "R8", kind: :dispatch, reason: "PR #10 was closed without merging: the next run opens a new PR from main"} = decision(issue_id)
      assert moves(issue_id) == ["Rework"]
      assert :run = ClosedPullRequest.guard(issue(issue_id), Config.settings!(), repo_key: @repo_key)
      refute deciding(issue_id)
      accounted!(issue_id)
    end

    test "the rework run's new PR: the facts follow it" do
      issue_id = ticket!("11", "QA")
      pid = start!()
      tick!(pid)
      pr!("11", pr: :closed)
      tick!(pid)
      assert state(issue_id) == "Rework"

      # While the run works, the watcher waits for it.
      run!(issue_id, "running")
      tick!(pid)
      assert %{rule: "R8", kind: :wait, owner: :agent} = decision(issue_id)
      accounted!(issue_id)

      # The run opens a new PR from main.
      open_pr!(issue_id, 12)
      run!(issue_id, "success")
      tick!(pid)

      assert %{pr_url: "https://github.com/acme/app/pull/12", head_sha: "head-12-1", facts: %Facts{pr: :open, pr_number: 12}} = watch(issue_id)
      assert %{rule: "R26", kind: :dispatch} = decision(issue_id)
      assert moves(issue_id) == ["Rework"]
    end

    test "in Merging: auto-merge off first, then Rework" do
      issue_id = ticket!("13", "Merging", pr: :closed, auto_merge: :armed)
      pid = start!()
      tick!(pid)

      assert World.calls(:disarm) == [url(13)]
      assert state(issue_id) == "Rework"
      assert %{rule: "R8", kind: :to_rework} = decision(issue_id)
    end

    test "a closed PR the PR review poller marked first still reads as closed, in CI Fix too" do
      issue_id = ticket!("14", "CI Fix", pr: :closed)
      TicketPullRequest.mark_finished(@repo_key, url(14), "closed")
      pid = start!()
      tick!(pid)

      assert state(issue_id) == "Rework"
      assert %{facts: %Facts{pr: :closed}, decision: %{rule: "R8", kind: :to_rework}} = watch(issue_id)
    end

    test "with a run active it waits for the run; in In Progress the next run opens a new PR" do
      busy = ticket!("15", "Code Review", pr: :closed)
      run!(busy, "running")
      idle = ticket!("16", "In Progress", pr: :closed)
      pid = start!()
      tick!(pid)

      assert state(busy) == "Code Review"
      assert %{rule: "R8", kind: :wait, owner: :agent, clears_when: "the run ends"} = decision(busy)
      assert state(idle) == "In Progress"
      assert %{rule: "R8", kind: :dispatch} = decision(idle)
      Enum.each([busy, idle], &accounted!/1)
    end

    test "a deleted branch reads as a closed PR, and goes to Rework like one" do
      issue_id = ticket!("17", "QA")
      pull = %{"number" => 17, "state" => "OPEN", "isDraft" => false, "merged" => false, "baseRefName" => "main", "headRef" => nil, "headRefOid" => "head-17-1"}
      body = Jason.encode!(%{"data" => %{"repository" => %{"defaultBranchRef" => %{"name" => "main"}, "pullRequest" => pull}}})
      gh = fn ["api", "--include", "graphql" | _rest], _opts -> {"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4000\r\n\r\n" <> body, 0} end

      pid = start!(fetch: SymphonyElixir.PrWatch.Fetch, gh_runner: gh)
      tick!(pid)

      assert %{facts: %Facts{pr: :closed}, decision: %{rule: "R8", kind: :to_rework}} = watch(issue_id)
      assert state(issue_id) == "Rework"
    end
  end

  describe "a draft PR (R10, G11)" do
    test "in Merging: auto-merge off while a person holds it; marked ready, landing resumes" do
      issue_id = ticket!("20", "Merging", pr: :draft, auto_merge: :armed, mergeable: :blocked, ci: :pending)
      pid = start!()
      tick!(pid)

      assert World.calls(:disarm) == [url(20)]
      assert %{rule: "R10", kind: :wait, owner: :person, reason: "A person marked PR #20 as a draft"} = decision(issue_id)
      accounted!(issue_id)

      # The next read finds auto-merge off; the wait goes on, nothing is turned off twice.
      tick!(pid, 2)
      assert %{facts: %Facts{auto_merge: :off}, decision: %{rule: "R10", kind: :wait}} = watch(issue_id)
      assert World.calls(:disarm) == [url(20)]

      pr!("20", pr: :open, mergeable: :clean)
      tick!(pid)
      assert [{_url, "head-20-1"}] = World.calls(:arm)
      assert state(issue_id) == "Merging"
    end

    test "in Code Review or QA it waits for the person, and the reviewer isn't dispatched" do
      issue_id = ticket!("21", "Code Review", pr: :draft)
      pid = start!()
      tick!(pid)

      assert %{rule: "R10", kind: :wait, owner: :person, clears_when: "the PR is marked ready for review"} = decision(issue_id)
      assert SymphonyElixir.PrWatch.dispatch_reason(issue(issue_id), Config.settings!()) =~ "R10"
      accounted!(issue_id)
    end
  end

  describe "a PR on another base (R7, G11)" do
    test "a person is asked; accepting the base lets the ticket go on" do
      issue_id = ticket!("30", "QA", base: :changed, base_ref: "release")
      pid = start!()
      tick!(pid)

      assert %{rule: "R7", kind: :decision, owner: :person} = decision(issue_id)
      assert deciding(issue_id)
      assert [request] = comments(issue_id)
      assert request =~ "## Decision needed: PR #30 of TP-30 merges into release, not main"

      tick!(pid)
      assert %{rule: "R4", kind: :wait, owner: :person} = decision(issue_id)

      answer!(issue_id, "PR #30 of TP-30 merges into release, not main", "Accept the new base")
      tick!(pid)

      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
      assert World.calls(:change_base) == []
      assert state(issue_id) == "QA"
    end

    test "the Director's answer reads from its Question before any decision is recorded (TP-1240)" do
      issue_id = ticket!("33", "QA", base: :changed, base_ref: "release")
      pid = start!()
      tick!(pid)
      assert %{rule: "R7", kind: :decision} = decision(issue_id)

      # Decide writes the Question first; the Decisions section follows once Linear answers.
      %{id: id} = deciding(issue_id)
      {:ok, _answered} = Questions.answer({:ticket, @repo_key, issue_id}, id, "Accept the new base")
      assert RunStore.get_ticket_state(issue_id).decisions == []
      tick!(pid)

      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
      assert World.calls(:change_base) == []
    end

    test "an answer the Director took back with Undo no longer counts, though its decision stays recorded (TP-1240)" do
      issue_id = ticket!("34", "QA", base: :changed, base_ref: "release")
      pid = start!()
      tick!(pid)
      assert %{rule: "R7", kind: :decision} = decision(issue_id)

      # Decide: the Question is answered and the decision recorded.
      %{id: id} = deciding(issue_id)
      ticket = {:ticket, @repo_key, issue_id}
      {:ok, question} = SymphonyElixir.Questions.answer(ticket, id, "Accept the new base")
      answer!(issue_id, question.title, "Accept the new base")

      # Undo: the Question is open again; the decision stays.
      {:ok, _reopened} = Questions.reopen(ticket, id)
      assert [%{answer: "Accept the new base"}] = RunStore.get_ticket_state(issue_id).decisions
      tick!(pid)

      # The base still reads as changed: the ticket waits on the person, asked again.
      assert %{facts: %Facts{base: :changed}, decision: %{rule: "R4", kind: :wait, owner: :person}} = watch(issue_id)
      assert World.calls(:change_base) == []
    end

    test "the base is the repo's `base_branch` when its configuration names one" do
      write_workflow_file!(Workflow.workflow_file_path(),
        pr_review_mode: "polling",
        repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test", base_branch: "develop"]]
      )

      ticket!("32", "QA")
      tick!(start!())
      assert [{_url, "develop"}] = World.calls(:read)
    end

    test "putting the base back retargets the PR once, and the ticket goes on" do
      issue_id = ticket!("31", "Code Review", base: :changed, base_ref: "release")
      pid = start!()
      tick!(pid)
      assert %{rule: "R7"} = decision(issue_id)

      answer!(issue_id, "PR #31 of TP-31 merges into release, not main", "1")
      tick!(pid)
      assert World.calls(:change_base) == [{url(31), "main"}]

      tick!(pid, 2)
      assert World.calls(:change_base) == [{url(31), "main"}]
      assert %{rule: "R27", kind: :dispatch, outcome: :recorded} = decision(issue_id)
      assert length(comments(issue_id)) == 2
    end
  end

  describe "no PR on the ticket (R5, R6)" do
    test "past In Progress a person is asked to attach it, restart or cancel; In Progress waits for the agent" do
      asked = bare_ticket!("40", "Code Review")
      waiting = bare_ticket!("41", "In Progress")
      plan = bare_ticket!("42", "Rework", labels: ["plan"])
      pid = start!()
      tick!(pid)

      assert %{rule: "R6", kind: :decision, owner: :person, outcome: :applied} = decision(asked)
      assert %{title: "No pull request on TP-40"} = deciding(asked)
      assert %{rule: "R5", kind: :wait, owner: :agent} = decision(waiting)
      assert RunStore.get_ticket_state(plan) == nil
      Enum.each([asked, waiting], &accounted!/1)

      # Asked once a stay: answered and still without a PR, it isn't asked again.
      withdraw!(asked)
      tick!(pid)
      assert %{rule: "R6", outcome: :recorded} = decision(asked)
      assert length(comments(asked)) == 1
    end
  end

  describe "review comments (R13, G12, D8)" do
    test "in Code Review they send the ticket back to In Progress on the same PR; the pushed fix doesn't loop" do
      issue_id = ticket!("50", "Code Review")
      review!(issue_id, url(50), "head-50-1", minutes_ago: 11)
      pid = start!()
      tick!(pid)

      assert state(issue_id) == "In Progress"
      assert %{rule: "R13", kind: :to_in_progress, reason: "PR #50 has review comments to address", outcome: :applied} = decision(issue_id)

      # In Progress on the same PR, the agent is dispatched.
      tick!(pid)
      assert %{pr_url: "https://github.com/acme/app/pull/50", decision: %{rule: "R12", kind: :dispatch}} = watch(issue_id)

      # The run pushes its fix and hands off: the comments were left on the old head, so the reviewer runs.
      pr!("50", head_sha: "head-50-2")
      Tracker.update_issue_state(issue_id, "Code Review")
      tick!(pid, 2)
      assert %{rule: "R27", kind: :dispatch} = decision(issue_id)
      assert moves(issue_id) == ["In Progress", "Code Review"]
    end

    test "in Merging auto-merge goes off first; before the rework delay, or for another PR, nothing moves" do
      merging = ticket!("51", "Merging", auto_merge: :armed, ci: :pending)
      review!(merging, url(51), "head-51-1", minutes_ago: 30)
      fresh = ticket!("52", "QA")
      review!(fresh, url(52), "head-52-1", minutes_ago: 2)
      other = ticket!("53", "QA")
      review!(other, url(99), "head-53-1", minutes_ago: 30)
      pid = start!()
      tick!(pid)

      assert World.calls(:disarm) == [url(51)]
      assert state(merging) == "In Progress"
      assert %{rule: "R27"} = decision(fresh)
      assert %{rule: "R27"} = decision(other)
    end
  end

  # A person answered the request titled `title`: the answer is recorded and its question no longer
  # waits.
  defp answer!(issue_id, title, answer) do
    record = RunStore.get_ticket_state(issue_id)
    entry = %{key: "comment-#{issue_id}", date: "2026-10-16", title: title, question: "", answer: answer, scope: ""}
    :ok = RunStore.put_ticket_state(TicketState.put_decisions(record, [entry]))
    withdraw!(issue_id)
  end

  describe "a ticket without a slot (TP-1606)" do
    # The watcher reads each ticket's slot from its record, as Symphony runs it.
    defp start_by_record!, do: start!(holds_slot: &Slots.held?/1)

    defp take_slot!(issue_id), do: :ok = RunStore.put_slot_holder(issue_id, World.get(:now))

    defp withheld(issue_id) do
      case decision(issue_id) do
        %{kind: :wait, owner: :symphony, clears_when: "the ticket takes a slot", args: %{withheld: kind}} -> kind
        _other -> nil
      end
    end

    test "its PR is read and recorded and nothing is done on it, when main moves too; once it takes a slot it catches up" do
      behind = ticket!("40", "Code Review", mergeable: :behind)
      red = ticket!("41", "QA", ci: :red, red_kind: :failure, failing_check: "specs", failed_checks: [%{name: "specs", run_id: "77", workflow_name: "ci", conclusion: "FAILURE"}])
      conflict = ticket!("42", "QA", mergeable: :dirty)
      green = ticket!("43", "QA")
      running = ticket!("49", "QA", ci: :pending)
      no_pr = bare_ticket!("50", "Code Review")
      pid = start_by_record!()
      tick!(pid)

      # What the reads found is recorded, so the ticket's status stays true.
      assert %{facts: %Facts{mergeable: :behind}, head_sha: "head-40-1"} = watch(behind)
      assert %{facts: %Facts{ci: :red, failing_check: "specs"}} = watch(red)
      assert %{facts: %Facts{mergeable: :dirty}} = watch(conflict)
      assert %{facts: %Facts{ci: :green, mergeable: :clean}} = watch(green)

      # No branch update, no rerun, no CI Fix, no move: each step waits for a slot, naming its rule.
      assert withheld(behind) == :update_branch
      assert %{rule: "U1", reason: "Waits for a slot before U1 acts (the branch is updated with the base): " <> _rest} = decision(behind)
      assert withheld(red) == :rerun_failed
      assert withheld(conflict) == :ci_fix
      # QA's run needs its app built first: it waits for the slot too, and holds its run back.
      assert withheld(green) == :dispatch
      assert PrWatch.waits_for_slot?(watch(green))
      assert PrWatch.dispatch_reason(issue(green), Config.settings!()) =~ "the PR watcher (R27): Waits for a slot"
      # A question is held back too, with what it would ask; a plain wait is the decision as it is.
      assert withheld(no_pr) == :decision
      assert %{rule: "R6", reason: "Waits for a slot before R6 acts (" <> _rest} = decision(no_pr)
      refute deciding(no_pr)
      assert %{rule: "R24", kind: :wait, owner: :ci} = decision(running)
      for issue_id <- [behind, red, conflict, green, running, no_pr], do: accounted!(issue_id)
      assert World.calls(:update_branch) == []
      assert World.calls(:rerun) == []
      assert World.calls(:move) == []
      assert %{silent: nil} = watch(behind)

      # Main moves: the PRs are read again, and left as they are.
      pr!("40", base_sha: "base-2")
      pr!("42", base_sha: "base-2")
      tick!(pid, 2)
      assert World.calls(:update_branch) == []
      assert World.calls(:move) == []
      assert withheld(behind) == :update_branch

      # The tickets take their slots: the next read updates the branch, reruns the red head's failed
      # check, sends the conflict to CI Fix, and QA's run is no longer held back.
      for issue_id <- [behind, red, conflict, green], do: take_slot!(issue_id)
      tick!(pid)
      assert World.calls(:update_branch) == [{url(40), "head-40-1"}]
      assert World.calls(:rerun) == ["77"]
      assert %{rule: "R22", kind: :rerun_failed} = decision(red)
      assert moves(conflict) == ["CI Fix"]
      assert %{rule: "R27", kind: :dispatch} = decision(green)
      refute PrWatch.waits_for_slot?(watch(green))
      assert PrWatch.dispatch_reason(issue(green), Config.settings!()) == nil
      for issue_id <- [behind, red, conflict, green], do: assert(withheld(issue_id) == nil)
    end

    test "a hold is never dropped: a blocker's pause stays on a held conflict behind main, and an idle run's hold stays on a new head" do
      # The incident of 2026-11-21: a held ticket's conflict was fixed and its blocker's hold dropped.
      blocked = ticket!("44", "QA", mergeable: :dirty)
      blocker = Pauses.ticket_reason(:dependency, "TP-9")
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, blocked}, blocker)
      behind = ticket!("45", "QA", mergeable: :behind)
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, behind}, blocker)
      idle = ticket!("46", "In Progress", ci: :pending)
      pid = start_by_record!()
      tick!(pid)

      :ok = IdlePark.hold({:ticket, @repo_key, idle}, "TP-46", "In Progress", 2, watch(idle))
      pr!("46", head_sha: "head-46-2", ci: :green)
      tick!(pid, 2)

      assert %{rule: "R4", kind: :wait} = decision(blocked)
      assert %{rule: "R4", kind: :wait} = decision(behind)
      assert %{rule: "R4", kind: :wait} = decision(idle)
      assert World.calls(:update_branch) == []
      assert World.calls(:move) == []
      assert {:ok, %{reasons: [%{kind: :ticket, waits_on: %{identifier: "TP-9"}}]}} = Pauses.get({:ticket, @repo_key, blocked})
      assert {:ok, %{reasons: [%{kind: :ticket, waits_on: %{identifier: "TP-9"}}]}} = Pauses.get({:ticket, @repo_key, behind})
      assert {:ok, %{reasons: idle_reasons}} = Pauses.get({:ticket, @repo_key, idle})
      assert [%{waits_on: %{condition: "idle_park"}}] = Enum.filter(idle_reasons, &(&1.kind == :environment))
      assert [_question] = Questions.open({:ticket, @repo_key, idle})
    end

    test "a merge or a close by a person still moves it: Done, and Rework" do
      merged = ticket!("47", "Code Review")
      closed = ticket!("48", "Code Review")
      pid = start_by_record!()
      tick!(pid)

      pr!("47", pr: :merged)
      pr!("48", pr: :closed)
      tick!(pid)

      assert state(merged) == "Done"
      assert %{rule: "R2", kind: :close_ticket, outcome: :applied} = decision(merged)
      assert state(closed) == "Rework"
      assert %{rule: "R8", kind: :to_rework, outcome: :applied} = decision(closed)
    end
  end

  # The decision request's question the ticket waits on, or nil.
  defp deciding(issue_id), do: Questions.deciding({:ticket, @repo_key, issue_id})

  # Withdraws every open question on the ticket.
  defp withdraw!(issue_id) do
    ticket = {:ticket, @repo_key, issue_id}
    for question <- Questions.open(ticket), do: {:ok, _withdrawn} = Questions.withdraw(ticket, question.id, "The test answers it.")
    :ok
  end

  # The PR review poller's record of the ticket: one reviewer comment left on `head`.
  defp review!(issue_id, pr_url, head, minutes_ago: minutes) do
    at = DateTime.add(World.get(:now), -minutes, :minute)

    :ok =
      RunStore.put_pr_review(%{
        repo_key: @repo_key,
        issue_id: issue_id,
        pr_url: pr_url,
        status: "watching",
        pending_reviewer_comments: [%{id: "c-#{issue_id}", kind: "inline_comment", author: "reviewer", body: "Please split this.", created_at: at, updated_at: at}],
        pending_last_addressed_comment_id: "c-#{issue_id}",
        pending_reviewer_comments_reviewed_head_sha: head,
        last_unaddressed_comment_at: at
      })
  end
end
