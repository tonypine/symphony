defmodule SymphonyElixir.ReleaseBuildTest do
  @moduledoc """
  The release build of a fix the app update hold waits on (TP-1307): rerun by Symphony when GitHub
  cancels it for lack of a machine, twice at most, then asked; a real failure pauses Symphony and
  asks; the held ticket reads what the build is at.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BuildInfo, DecisionRequest, Pauses, ReleaseBuild, TicketState, UpdateHold}
  alias SymphonyElixir.PrWatch.Ingest

  @repo "acme/symphony"
  @repo_key "symphony"
  @sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @created ~U[2026-10-30 16:02:00Z]
  @now ~U[2026-10-30 16:25:00Z]
  @ticket %{id: "issue-1251", identifier: "TP-1251", state: "Todo"}
  @condition "release_build:#{@repo_key}:#{@sha}"

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
    test = self()
    {:ok, github} = Agent.start_link(fn -> %{runs: [], started: false, rerun: :ok} end)
    {:ok, decisions} = Agent.start_link(fn -> [] end)

    opts = [
      now: @now,
      gh_runner: gh(github, test),
      ask: fn ticket, request ->
        send(test, {:asked, ticket, request})
        DecisionRequest.check(request)
      end,
      decisions: fn @repo_key, issue_id ->
        send(test, {:decisions_read, issue_id})
        Agent.get(decisions, & &1)
      end
    ]

    %{github: github, decisions: decisions, opts: opts}
  end

  # `gh` as GitHub answers the release runs of the commit, a run's jobs and a rerun.
  defp gh(github, test) do
    fn
      ["run", "list", "-R", @repo, "--commit", @sha, "--workflow", "release", "--limit", "5", "--json", _fields], _opts ->
        case Agent.get(github, & &1.runs) do
          :down -> {"HTTP 502", 1}
          runs -> {Jason.encode!(runs), 0}
        end

      ["run", "view", id, "--json", "jobs", "-R", @repo], _opts ->
        case Agent.get(github, & &1.started) do
          :down -> {"HTTP 502", 1}
          false -> {Jason.encode!(%{"jobs" => [%{"name" => "release", "conclusion" => "cancelled", "steps" => []}]}), 0}
          true -> {Jason.encode!(%{"jobs" => [%{"name" => "release", "steps" => [%{"name" => "Checkout"}], "databaseId" => id}]}), 0}
        end

      ["run", "rerun", id, "-R", @repo], _opts ->
        send(test, {:rerun, id})
        if Agent.get(github, & &1.rerun) == :ok, do: {"", 0}, else: {"HTTP 403", 1}
    end
  end

  defp run(attempt, status, conclusion \\ nil) do
    %{
      "databaseId" => 41_086_214_847,
      "number" => 750,
      "attempt" => attempt,
      "status" => status,
      "conclusion" => conclusion,
      "url" => "https://github.com/acme/symphony/actions/runs/41086214847",
      "createdAt" => DateTime.to_iso8601(@created)
    }
  end

  defp set(github, key, value), do: Agent.update(github, &Map.put(&1, key, value))
  defp runs(github, runs), do: set(github, :runs, runs)

  defp check(opts, extra \\ []), do: ReleaseBuild.check(@sha, @repo, @repo_key, [@ticket], Keyword.merge(opts, extra))

  defp line(opts), do: ReleaseBuild.line(@sha, "TP-1238's fix", opts)

  defp version, do: BuildInfo.release_version(750)

  defp answer(decisions, title, answer), do: Agent.update(decisions, &(&1 ++ [%{title: title, answer: answer}]))

  defp symphony_conditions do
    case Pauses.get(:symphony) do
      {:ok, %{reasons: reasons}} -> for %{kind: :environment, waits_on: %{condition: c}} <- reasons, do: c
      _none -> []
    end
  end

  describe "check/5" do
    test "a queued build reads how long GitHub has had it in its queue", %{github: github, opts: opts} do
      runs(github, [run(1, "queued")])

      assert {:ok, %{state: :queued, number: 750, since: @created}} = check(opts)
      assert line(opts) == "Waiting for the v#{version()} build with TP-1238's fix: queued on GitHub for 23 min"
      assert ReleaseBuild.line(@sha, nil, opts) == "Waiting for the v#{version()} build: queued on GitHub for 23 min"
      assert ReleaseBuild.line(@sha, nil, now: @created) =~ "queued on GitHub for less than a minute"
      assert ReleaseBuild.line(@sha, nil, now: DateTime.add(@created, 125, :minute)) =~ "queued on GitHub for 2 h 5 min"

      runs(github, [run(1, "in_progress")])
      assert {:ok, %{state: :running}} = check(opts)
      assert line(opts) == "Waiting for the v#{version()} build with TP-1238's fix: building on GitHub"
    end

    test "a build GitHub cancelled before any job started is rerun twice, then a person is asked", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "cancelled")])

      assert {:ok, %{state: :queued, reruns: 1, rerun_attempt: 1, since: @now}} = check(opts)
      assert_received {:rerun, "41086214847"}
      assert line(opts) =~ "queued on GitHub for less than a minute; cancelled for lack of a machine, rerun 1 of 2"

      # GitHub hasn't started the rerun's attempt yet: nothing to do again.
      assert {:ok, %{state: :queued, reruns: 1}} = check(opts)
      refute_received {:rerun, _id}

      later = DateTime.add(@now, 3, :minute)
      runs(github, [run(2, "queued")])
      assert {:ok, %{state: :queued, since: @now}} = check(opts, now: later)
      assert ReleaseBuild.line(@sha, nil, now: later) =~ "queued on GitHub for 3 min; cancelled for lack of a machine, rerun 1 of 2"

      runs(github, [run(2, "completed", "cancelled")])
      assert {:ok, %{state: :queued, reruns: 2}} = check(opts)
      assert_received {:rerun, "41086214847"}

      runs(github, [run(3, "completed", "cancelled")])
      assert {:ok, %{state: :asked, reruns: 2, question: question}} = check(opts)
      assert question == %{kind: :cancelled, attempt: 3, issue_id: "issue-1251", prior: 0, title: question.title}
      refute_received {:rerun, _id}
      assert_received {:asked, %{id: "issue-1251", state: "Todo", repo_key: @repo_key}, request}
      assert request.title == "The Symphony v#{version()} build keeps being cancelled"
      assert Enum.map(request.options, & &1.label) == ["Keep retrying", "Wait"]
      assert line(opts) =~ "cancelled for lack of a machine 3 times; you were asked whether to keep retrying"

      # Asked once per attempt.
      assert {:ok, %{state: :asked}} = check(opts)
      refute_received {:asked, _ticket, _request}
      refute_received {:rerun, _id}
    end

    test "keep retrying starts the reruns again; wait leaves the build", %{github: github, decisions: decisions, opts: opts} do
      runs(github, [run(3, "completed", "cancelled")])
      store_asked(3)
      title = "The Symphony v#{version()} build keeps being cancelled"

      answer(decisions, "Other question", "1")
      assert {:ok, %{state: :asked}} = check(opts)

      answer(decisions, title, "1. Keep retrying")
      assert {:ok, %{state: :queued, reruns: 1, question: nil}} = check(opts)
      assert_received {:rerun, "41086214847"}

      runs(github, [run(4, "completed", "cancelled")])
      assert {:ok, %{reruns: 2}} = check(opts)
      assert_received {:rerun, "41086214847"}
      runs(github, [run(5, "completed", "cancelled")])
      assert {:ok, %{state: :asked, question: %{attempt: 5, prior: 1}}} = check(opts)

      answer(decisions, title, "Wait")
      assert {:ok, %{state: :waiting, answer: %{kind: :cancelled, attempt: 5}}} = check(opts)
      assert line(opts) =~ "cancelled for lack of a machine; you chose to wait"
      assert {:ok, %{state: :waiting}} = check(opts)
      refute_received {:rerun, _id}
    end

    test "a real failure pauses Symphony with the reason and asks", %{github: github, decisions: decisions, opts: opts} do
      runs(github, [run(1, "completed", "failure")])

      assert {:ok, %{state: :failed, question: %{kind: :failed, attempt: 1}}} = check(opts)
      assert_received {:asked, _ticket, %{title: title} = request}
      assert title == "The Symphony v#{version()} build failed"
      assert Enum.map(request.options, & &1.label) == ["Rerun the build", "Wait for a fix"]
      assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (a step failed); TP-1251 waits for it"]
      assert symphony_conditions() == [@condition]
      assert line(opts) =~ "failed on GitHub; you were asked what to do"

      assert {:ok, %{state: :failed}} = check(opts)
      refute_received {:asked, _ticket, _request}

      answer(decisions, title, "Rerun the build")
      assert {:ok, %{state: :queued, question: nil, rerun_attempt: 1}} = check(opts)
      assert_received {:rerun, "41086214847"}
      assert symphony_conditions() == []

      runs(github, [run(2, "completed", "timed_out")])
      assert {:ok, %{state: :failed, question: %{attempt: 2, prior: 1}}} = check(opts)
      assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (it ran out of time); TP-1251 waits for it"]

      answer(decisions, title, "2")
      assert {:ok, %{state: :failed, answer: %{kind: :failed, attempt: 2}}} = check(opts)
      assert symphony_conditions() == []
      assert line(opts) =~ "failed on GitHub; waiting for a fix"
    end

    test "rerun the build after a person already reran it on GitHub sends nothing", %{github: github, decisions: decisions, opts: opts} do
      runs(github, [run(1, "completed", "startup_failure")])
      assert {:ok, %{state: :failed}} = check(opts)
      assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (it failed to start); TP-1251 waits for it"]

      runs(github, [run(2, "queued")])
      answer(decisions, "The Symphony v#{version()} build failed", "Rerun the build")
      assert {:ok, %{state: :queued, question: nil}} = check(opts)
      refute_received {:rerun, _id}
      assert symphony_conditions() == []
    end

    test "a build cancelled once a job had started is a failure", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "cancelled")])
      set(github, :started, true)

      assert {:ok, %{state: :failed, reruns: 0}} = check(opts)
      refute_received {:rerun, _id}
      assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (it was cancelled while building); TP-1251 waits for it"]
    end

    test "a published build, no run yet, and reads that fail", %{github: github, opts: opts} do
      assert {:ok, %{state: :not_started}} = check(opts)
      assert line(opts) == nil

      runs(github, [run(1, "completed", "success")])
      assert {:ok, %{state: :built}} = check(opts)
      assert line(opts) == nil

      runs(github, :down)
      assert {:error, {:gh_failed, _args, 1, "HTTP 502"}} = check(opts)

      runs(github, [run(2, "completed", "cancelled")])
      set(github, :started, :down)
      assert {:ok, %{state: :built, attempt: 2}} = check(opts)
      refute_received {:rerun, _id}

      runs(github, [%{"databaseId" => 1, "status" => "queued"}, "not a run"])
      assert {:ok, %{state: :queued, attempt: 1, number: nil}} = check(opts)
      assert line(opts) =~ "Waiting for the release build with TP-1238's fix: queued on GitHub for less than a minute"

      runs(github, %{"not" => "a list"})
      assert {:error, :invalid_workflow_runs_payload} = check(opts)

      assert {:error, :no_repository} = ReleaseBuild.check(@sha, nil, @repo_key, [@ticket], opts)
    end

    test "a rerun or a question that fails is tried again on the next check", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "cancelled")])
      set(github, :rerun, :error)

      assert {:ok, %{state: :cancelled, reruns: 0}} = check(opts)
      assert line(opts) =~ "cancelled for lack of a machine, rerunning it"

      set(github, :rerun, :ok)
      assert {:ok, %{state: :queued, reruns: 1}} = check(opts)

      runs(github, [run(3, "completed", "cancelled")])
      store_asked(nil)
      failing = Keyword.put(opts, :ask, fn _ticket, _request -> {:error, :linear_down} end)
      assert {:ok, %{state: :cancelled, question: nil}} = check(failing)

      runs(github, [run(3, "completed", "failure")])
      assert {:ok, %{state: :failed, question: nil}} = check(failing)

      assert {:ok, %{state: :failed, question: nil}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      refute_received {:asked, _ticket, _request}
    end

    test "a person's answer is read from the ticket's recorded decisions by default", %{github: github, opts: opts} do
      runs(github, [run(3, "completed", "cancelled")])
      store_asked(3)

      assert {:ok, %{state: :asked}} = check(Keyword.delete(opts, :decisions))
      refute_received {:decisions_read, _issue_id}
    end
  end

  defmodule CommentTracker do
    def create_comment(issue_id, body) do
      send(self(), {:commented, issue_id, body})
      :ok
    end

    def set_machine_label(_issue_id, _name), do: :ok
    def remove_machine_label(_issue_id, _name), do: :ok
  end

  defmodule FailingStore do
    def get_github_updates(_key), do: nil
    def put_github_updates(_key, _value), do: {:error, :store_down}
  end

  describe "the decision path and the store" do
    test "asks through the one decision path, and reads the answer the ticket recorded", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      opts = opts |> Keyword.drop([:ask, :decisions]) |> Keyword.put(:tracker, CommentTracker)

      assert {:ok, %{state: :failed, question: %{title: title}}} = check(opts)
      assert_received {:commented, "issue-1251", body}
      assert body =~ "Rerun the build"
      assert SymphonyElixir.Hold.get(@repo_key, "issue-1251", :needs_decision)

      decision = %{key: "comment-1", date: ~D[2026-10-30], title: title, question: "Rerun?", answer: "Wait for a fix", scope: "As answered"}
      :ok = RunStore.put_ticket_state(TicketState.put_decisions(TicketState.new(@repo_key, "issue-1251"), [decision], []))

      assert {:ok, %{state: :failed, answer: %{kind: :failed, attempt: 1}}} = check(opts)
    end

    test "a failed rerun after a person's answer asks nothing new and is tried again", %{github: github, decisions: decisions, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      assert {:ok, %{state: :failed}} = check(opts)

      set(github, :rerun, :error)
      answer(decisions, "The Symphony v#{version()} build failed", "Rerun the build")
      assert {:ok, %{state: :failed, question: %{attempt: 1}, answer: nil}} = check(opts)
      assert_received {:rerun, _id}
    end

    test "a build kept nowhere, and one with no repository key, still answer", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])

      kept_nowhere = Keyword.put(opts, :run_store, FailingStore)
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{state: :failed}} = check(kept_nowhere) end)
      assert log =~ "Could not record the release build"

      assert {:ok, %{state: :failed}} = ReleaseBuild.check(@sha, @repo, nil, [@ticket], Keyword.put(opts, :decisions, fn nil, _issue_id -> [] end))
      assert ReleaseBuild.delivered(nil) == :ignored
    end

    test "a queued build with no known start reads as waiting a while" do
      record = %{sha: @sha, state: :queued, number: 750, reruns: 0, since: nil}
      :ok = RunStore.put_github_updates({:release_build, @sha}, record)
      assert ReleaseBuild.line(@sha, nil) == "Waiting for the v#{version()} build: queued on GitHub for a while"
      assert ReleaseBuild.line(nil, nil) == nil
    end
  end

  # A record whose reruns are spent, asked about `attempt` (nil: not asked).
  defp store_asked(attempt) do
    question = if attempt, do: %{kind: :cancelled, title: "The Symphony v#{version()} build keeps being cancelled", attempt: attempt, issue_id: "issue-1251", prior: 0}

    record = %{
      sha: @sha,
      repo: @repo,
      repo_key: @repo_key,
      tickets: [@ticket],
      state: :asked,
      run_id: "41086214847",
      number: 750,
      attempt: attempt || 3,
      conclusion: "CANCELLED",
      since: @created,
      since_attempt: attempt || 3,
      reruns: 2,
      rerun_attempt: 2,
      question: question,
      answer: nil
    }

    :ok = RunStore.put_github_updates({:release_build, @sha}, record)
  end

  describe "watch/5, delivered/2 and UpdateHold.lines/4" do
    setup %{github: github} do
      runs(github, [run(1, "queued")])
      blocker = %{id: "id-TP-1238", identifier: "TP-1238", state: "Done"}
      issue = %Issue{id: "issue-1251", identifier: "TP-1251", state: "Todo", repo_key: @repo_key, blocked_by: [blocker]}
      reason = %{kind: :build, waits_on: %{pull_request: 722}, text: "Waiting for a Symphony update that includes TP-1238's fix"}
      {:ok, _pause} = Pauses.set({:ticket, @repo_key, issue.id}, reason, set_by: %{kind: :rule, name: "App update hold"})
      cache = %{blockers: %{"id-TP-1238" => {:merged, "https://github.com/acme/symphony/pull/722", @sha}}, included: %{}}
      %{issue: issue, cache: cache}
    end

    test "checks the build of each fix a held ticket waits on", %{issue: issue, cache: cache, github: github, opts: opts} do
      build = %{version: "0.0.1.749", sha: "d3d301b0", repo: "https://github.com/acme/symphony"}
      other = %Issue{id: "issue-9", identifier: "TP-9", state: "Todo", repo_key: @repo_key, blocked_by: []}

      assert :ok = ReleaseBuild.watch([issue, other, %Issue{id: nil}], build, cache, @repo_key, opts)
      assert %{state: :queued, tickets: [@ticket]} = ReleaseBuild.get(@sha)

      reasons = UpdateHold.reasons(@repo_key, issue.id)
      assert UpdateHold.lines(issue, reasons, cache, now: @now) == ["Waiting for the v#{version()} build with TP-1238's fix: queued on GitHub for 23 min"]
      assert UpdateHold.lines(issue, reasons, %{cache | blockers: %{}}, now: @now) == ["Waiting for a Symphony update that includes TP-1238's fix"]

      assert :ok = ReleaseBuild.watch([issue], %{build | repo: nil}, cache, @repo_key, opts)

      # Published: the run is not read again.
      runs(github, [run(1, "completed", "success")])
      assert :ok = ReleaseBuild.watch([issue], build, cache, @repo_key, opts)
      assert %{state: :built} = ReleaseBuild.get(@sha)
      runs(github, :down)
      assert :ok = ReleaseBuild.watch([issue], build, cache, @repo_key, opts)
      assert %{state: :built} = ReleaseBuild.get(@sha)
    end

    test "a failed build's pause clears once no held ticket waits on it", %{github: github, issue: issue, cache: cache, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      build = %{version: "0.0.1.749", sha: "d3d301b0", repo: "https://github.com/acme/symphony"}
      {:ok, _pause} = Pauses.set(:symphony, %{kind: :environment, waits_on: %{condition: "release_build:other:#{@sha}"}, text: "Another repo's build"})

      assert :ok = ReleaseBuild.watch([issue], build, cache, @repo_key, opts)
      assert symphony_conditions() == ["release_build:other:#{@sha}", @condition]

      {:ok, nil} = Pauses.clear({:ticket, @repo_key, issue.id})
      assert :ok = ReleaseBuild.watch([issue], build, cache, @repo_key, opts)
      assert symphony_conditions() == ["release_build:other:#{@sha}"]
    end

    test "a finished workflow run on a watched commit checks its build at once", %{issue: issue, cache: cache, github: github, opts: opts} do
      build = %{version: "0.0.1.749", sha: "d3d301b0", repo: "https://github.com/acme/symphony"}
      :ok = ReleaseBuild.watch([issue], build, cache, @repo_key, opts)
      supervisor = start_supervised!(Task.Supervisor)
      runs(github, [run(1, "completed", "cancelled")])

      delivery = {:ci, %{event: "workflow_run", action: "completed", head_sha: String.upcase(@sha), conclusion: "cancelled", completed_at: nil, pr_urls: [], merged: false, base_ref: nil}}
      assert :unavailable = Ingest.deliver(delivery, "https://github.com/acme/symphony", [watchers: [], supervisor: supervisor] ++ opts)
      assert_receive {:rerun, "41086214847"}, 1_000

      assert ReleaseBuild.delivered("0000000000000000000000000000000000000000", opts) == :ignored
      assert ReleaseBuild.delivered(nil, opts) == :ignored
      assert Ingest.deliver({:ci, %{elem(delivery, 1) | event: "check_run"}}, nil, watchers: []) == :unavailable
    end
  end
end
