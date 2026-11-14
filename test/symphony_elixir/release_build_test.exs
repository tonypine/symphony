defmodule SymphonyElixir.ReleaseBuildTest do
  @moduledoc """
  The release build of a fix the app update hold waits on (TP-1307): rerun by Symphony when GitHub
  cancels it for lack of a machine, twice at most, then asked; a real failure pauses Symphony and
  asks; the held ticket reads what the build is at.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{
    BuildInfo,
    DecisionRequest,
    DirectorMoves,
    Inbox,
    Pauses,
    Questions,
    ReleaseBuild,
    TicketEvents,
    TicketState,
    UpdateHold
  }

  alias SymphonyElixir.PrWatch.Ingest

  @repo "acme/symphony"
  @repo_key "symphony"
  @sha "9f54098b96666e6e233247d53fc995c3b293c4f2"
  @created ~U[2026-10-30 16:02:00Z]
  @now ~U[2026-10-30 16:25:00Z]
  @ticket %{id: "issue-1251", identifier: "TP-1251", state: "Todo"}
  @condition "release_build:#{@repo_key}:#{@sha}"

  defmodule Gate do
    @moduledoc false
    def failed(build, _opts) do
      send(Process.get(:release_gate_test), {:gate_failed, build})
      Process.get(:release_gate_reply, {:filed, "TP-1520"})
    end
  end

  setup do
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
    test = self()
    {:ok, github} = Agent.start_link(fn -> %{runs: [], started: :auto, rerun: :ok, main: []} end)
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
      ["run", "list", "-R", @repo, "--commit", _sha, "--workflow", "release", "--limit", "5", "--json", _fields], _opts ->
        case Agent.get(github, & &1.runs) do
          :down -> {"HTTP 502", 1}
          runs -> {Jason.encode!(runs), 0}
        end

      ["run", "list", "-R", @repo, "--branch", "main", "--workflow", "release", "--event", "push", "--limit", "1", "--json", _fields], _opts ->
        send(test, :main_read)

        case Agent.get(github, & &1.main) do
          :down -> {"HTTP 502", 1}
          runs -> {Jason.encode!(runs), 0}
        end

      ["run", "view", id, "--json", "jobs", "-R", @repo], _opts ->
        case jobs(Agent.get(github, & &1)) do
          :down -> {"HTTP 502", 1}
          jobs -> {Jason.encode!(%{"jobs" => Enum.map(jobs, &Map.put(&1, "databaseId", id))}), 0}
        end

      ["run", "rerun", id, "-R", @repo], _opts ->
        send(test, {:rerun, id})
        if Agent.get(github, & &1.rerun) == :ok, do: {"", 0}, else: {"HTTP 403", 1}
    end
  end

  # A run's jobs: by default, a cancelled run's job ran no step and any other run's job ran a step
  # that failed; `started: false`, `true` or a list of jobs says otherwise.
  defp jobs(%{started: :auto, runs: [%{"conclusion" => "cancelled"} | _rest]}), do: jobs(%{started: false})

  defp jobs(%{started: :auto}),
    do: [%{"name" => "release", "conclusion" => "failure", "steps" => [%{"name" => "Checkout", "conclusion" => "success"}, %{"name" => "Build the app", "conclusion" => "failure"}]}]

  defp jobs(%{started: false}), do: [%{"name" => "release", "conclusion" => "cancelled", "steps" => []}]
  defp jobs(%{started: true}), do: [%{"name" => "release", "conclusion" => "cancelled", "steps" => [%{"name" => "Checkout", "conclusion" => "success"}]}]
  defp jobs(%{started: started}), do: started

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
    test "a read that finds the run finished lifts the CI wait of a ticket paused on the commit (TP-1376)", %{github: github, opts: opts} do
      ticket = {:ticket, @repo_key, "epic-1320"}
      {:ok, _pause} = SymphonyElixir.CiWait.pause(@repo_key, "epic-1320", @sha)

      runs(github, [run(1, "in_progress")])
      assert {:ok, %{state: :running}} = check(opts)
      assert Pauses.paused?(ticket)

      runs(github, [run(1, "completed", "failure")])
      assert {:ok, %{state: :failed}} = check(opts)
      refute Pauses.paused?(ticket)

      {:ok, _pause} = SymphonyElixir.CiWait.pause(@repo_key, "epic-1320", @sha)
      assert {:ok, %{state: :failed}} = check(opts)
      assert Pauses.paused?(ticket)
    end

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
      assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (the step “Build the app” of the job “release” failed); TP-1251 waits for it"]
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

    test "a failed release gate files a fix ticket once per attempt, asks nobody and pauses nothing", %{github: github, opts: opts} do
      Process.put(:release_gate_test, self())
      opts = Keyword.put(opts, :release_gate, __MODULE__.Gate)
      set(github, :started, [%{"name" => "release gate", "conclusion" => "failure", "steps" => [%{"name" => "Test the update", "conclusion" => "failure"}]}])
      runs(github, [run(1, "completed", "failure")])

      assert {:ok, %{state: :failed, question: nil, fix: %{identifier: "TP-1520", attempt: 1}}} = check(opts)
      assert_received {:gate_failed, %{sha: @sha, run_id: "41086214847", failure: %{job: "release gate", step: "Test the update"}} = build}
      refute Map.has_key?(build, :opts)
      refute_received {:asked, _ticket, _request}
      assert symphony_conditions() == []
      assert line(opts) == "Waiting for the v#{version()} build with TP-1238's fix: failed its release gate; TP-1520 was opened to fix it"

      assert {:ok, %{state: :failed, fix: %{attempt: 1}}} = check(opts)
      refute_received {:gate_failed, _build}

      Process.put(:release_gate_reply, {:error, :linear_down})
      runs(github, [run(2, "completed", "failure")])
      assert {:ok, %{state: :failed, fix: %{attempt: 1}}} = check(opts)
      assert_received {:gate_failed, _build}

      Process.put(:release_gate_reply, {:attached, "TP-1520"})
      assert {:ok, %{state: :failed, fix: %{identifier: "TP-1520", attempt: 2}}} = check(opts)
      assert_received {:gate_failed, %{attempt: 2}}
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

    test "a run GitHub ended as failure with its job cancelled before any step ran is rerun, not asked (TP-1368)", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      set(github, :started, false)

      assert {:ok, %{state: :queued, reruns: 1, rerun_attempt: 1}} = check(opts)
      assert_received {:rerun, "41086214847"}
      refute_received {:asked, _ticket, _request}
      assert symphony_conditions() == []

      runs(github, [run(2, "completed", "failure")])
      assert {:ok, %{reruns: 2}} = check(opts)
      runs(github, [run(3, "completed", "failure")])
      assert {:ok, %{state: :asked, question: %{kind: :cancelled, attempt: 3}}} = check(opts)
      assert_received {:asked, _ticket, %{title: "The Symphony v" <> _rest}}
    end

    test "a failed run whose job ran steps asks, naming the job and the step that failed, or only what is known", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])

      assert {:ok, %{state: :failed, failure: %{job: "release", step: "Build the app"}}} = check(opts)
      assert_received {:asked, _ticket, %{question: question}}
      assert question =~ "GitHub's Symphony v#{version()} build failed: the step “Build the app” of the job “release” failed."
      refute_received {:rerun, _id}

      for {jobs, words} <- [
            {[%{"name" => "release", "conclusion" => "failure", "steps" => [%{"name" => "Checkout", "conclusion" => "success"}]}], "the job “release” failed"},
            {[%{"name" => "release", "conclusion" => "success", "steps" => [%{"name" => "Checkout", "conclusion" => "success"}]}], "GitHub doesn't say which step failed"}
          ] do
        :ok = RunStore.clear()
        set(github, :started, jobs)
        assert {:ok, %{state: :failed}} = check(opts)
        assert Pauses.why(:symphony) == ["The v#{version()} build failed on GitHub (#{words}); TP-1251 waits for it"]
        refute Enum.any?(Pauses.why(:symphony), &(&1 =~ "a step failed"))
      end
    end

    test "a build that failed to start with no job ran is a failure, never starved", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "startup_failure")])
      set(github, :started, [])

      assert {:ok, %{state: :failed}} = check(opts)
      refute_received {:rerun, _id}
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

      refusing = Keyword.put(opts, :questions, __MODULE__.RefusingQuestions)
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{state: :failed, question: nil}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], refusing) end)
      assert log =~ "Could not ask Symphony about the release build of #{@sha}: :store_down"
      refute_received {:asked, _ticket, _request}
      assert ReleaseBuild.line(@sha, nil, opts) == "Waiting for the v#{version()} build: failed on GitHub"

      # Cancelled a third time and the question refused: the line says Symphony stopped rerunning it.
      :ok = RunStore.put_github_updates({:release_build, @sha}, %{ReleaseBuild.get(@sha) | reruns: 2, rerun_attempt: 2, state: :queued})
      runs(github, [run(3, "completed", "cancelled")])
      ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{state: :cancelled, question: nil}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], refusing) end)
      assert ReleaseBuild.line(@sha, nil, opts) == "Waiting for the v#{version()} build: cancelled for lack of a machine 3 times; Symphony stopped rerunning it"
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

  # The Question service as a store that refuses every write.
  defmodule RefusingQuestions do
    def ask(_subject, _request, _opts), do: {:error, :store_down}
    def find(_subject, _id), do: nil
    def open(_subject), do: [%{id: "q-old", step: "release_build:0000000000000000000000000000000000000000"}]
    def withdraw(_subject, "q-old", _reason, _opts), do: {:error, {:question_not_open, :answered}}
    def withdraw(_subject, _id, _reason, _opts), do: {:error, :store_down}
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
      assert %{title: ^title} = SymphonyElixir.Questions.deciding({:ticket, @repo_key, "issue-1251"})

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

  describe "every merge to main, held ticket or not (TP-1340)" do
    @build %{version: "0.0.1.749", sha: "d3d301b0", repo: "https://github.com/acme/symphony"}

    defp main_run(attempt, status, conclusion \\ nil), do: Map.put(run(attempt, status, conclusion), "headSha", String.upcase(@sha))

    defp release_delivery(extra \\ %{}) do
      Map.merge(
        %{
          event: "workflow_run",
          action: "completed",
          head_sha: String.upcase(@sha),
          conclusion: "cancelled",
          completed_at: nil,
          pr_urls: [],
          merged: false,
          base_ref: nil,
          workflow: "release",
          head_branch: "main",
          repo: "acme/symphony"
        },
        extra
      )
    end

    test "with no ticket held, a cancelled release run on main is rerun on the poll, logged and kept", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "cancelled")])
      set(github, :main, [main_run(1, "completed", "cancelled")])

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, opts) end)
      assert_received {:rerun, "41086214847"}
      assert log =~ "Reran the release build of #{@sha}"
      assert %{state: :queued, reruns: 1, tickets: [], url: "https://github.com/acme/symphony/actions/runs/41086214847"} = ReleaseBuild.get(@sha)
      assert symphony_conditions() == []

      assert %{sha: @sha, version: version, state: "queued", reruns: 1, since: @now, line: line} =
               ReleaseBuild.latest_build(now: @now)

      assert version == version()
      assert line == "The v#{version()} build: queued on GitHub for less than a minute; cancelled for lack of a machine, rerun 1 of 2"

      # Read at most once a minute.
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, opts)
      assert_received :main_read
      assert_received :main_read
      refute_received :main_read
      later = Keyword.put(opts, :now, DateTime.add(@now, 61, :second))
      runs(github, [run(2, "completed", "success")])
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, later)
      assert_received :main_read
      assert %{state: :built} = ReleaseBuild.get(@sha)
      assert %{state: "built", line: nil} = ReleaseBuild.latest_build(later)

      # A published build is not read again.
      runs(github, :down)
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, Keyword.put(opts, :now, DateTime.add(@now, 125, :second)))
      assert %{state: :built} = ReleaseBuild.get(@sha)
    end

    test "a release run on main of Symphony's own repository starts the watch on its delivery", %{github: github, opts: opts} do
      supervisor = start_supervised!(Task.Supervisor)
      runs(github, [run(1, "completed", "cancelled")])
      opts = [supervisor: supervisor, build: @build] ++ opts

      assert :unavailable = Ingest.deliver({:ci, release_delivery()}, "https://github.com/acme/symphony", [watchers: []] ++ opts)
      assert_receive {:rerun, "41086214847"}, 1_000
      await_checks(supervisor)
      assert %{sha: @sha} = ReleaseBuild.latest_build(opts)
      assert %{state: :queued, reruns: 1} = ReleaseBuild.get(@sha)

      # Another workflow, branch or repository on an unwatched commit is not a merge's build.
      other = "0000000000000000000000000000000000000000"
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: other, workflow: "ci"}), opts) == :ignored
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: other, head_branch: "auto/TP-1"}), opts) == :ignored
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: other, repo: "acme/other"}), opts) == :ignored
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: other}), Keyword.put(opts, :build, %{@build | repo: nil})) == :ignored
    end

    test "an older release run's delivery doesn't move the newest merge", %{github: github, opts: opts} do
      supervisor = start_supervised!(Task.Supervisor)
      opts = [supervisor: supervisor, build: @build] ++ opts
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "newer", number: 800, read_at: @now})
      runs(github, [run(1, "queued")])

      assert ReleaseBuild.delivered(release_delivery(), opts) == :started
      await_checks(supervisor)
      assert %{state: :queued} = ReleaseBuild.get(@sha)
      assert %{sha: "newer"} = RunStore.get_github_updates({:release_build, :latest})

      # A newest merge with no run number yet is replaced; a delivery GitHub can't answer changes nothing.
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "newer", number: nil, read_at: @now})
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: "1111111111111111111111111111111111111111"}), opts) == :started
      await_checks(supervisor)
      assert %{sha: "1111111111111111111111111111111111111111"} = RunStore.get_github_updates({:release_build, :latest})

      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "newer", number: 900, read_at: @now})
      runs(github, [%{run(1, "queued") | "number" => nil}])
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: "2222222222222222222222222222222222222222"}), opts) == :started
      await_checks(supervisor)
      assert %{state: :queued} = ReleaseBuild.get("2222222222222222222222222222222222222222")
      assert %{sha: "newer"} = RunStore.get_github_updates({:release_build, :latest})

      # A build whose run carries no number yet has no version.
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "2222222222222222222222222222222222222222", number: nil, read_at: @now})
      assert %{version: nil, line: "The release build: queued on GitHub for 23 min"} = ReleaseBuild.latest_build(now: @now)

      # The newest merge's own run, published and read again, stays the newest.
      :ok = RunStore.put_github_updates({:release_build, "2222222222222222222222222222222222222222"}, %{ReleaseBuild.get("2222222222222222222222222222222222222222") | state: :built})
      runs(github, [%{run(1, "completed", "success") | "number" => nil}])
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: "2222222222222222222222222222222222222222"}), opts) == :started
      await_checks(supervisor)
      assert %{sha: "2222222222222222222222222222222222222222", read_at: @now} = RunStore.get_github_updates({:release_build, :latest})

      runs(github, :down)
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: "3333333333333333333333333333333333333333"}), opts) == :started
      await_checks(supervisor)
      assert ReleaseBuild.get("3333333333333333333333333333333333333333") == nil
    end

    defp store_cancelled_twice do
      record = %{sha: @sha, repo: @repo, repo_key: @repo_key, tickets: [], state: :queued, run_id: "41086214847", url: nil}
      record = Map.merge(record, %{number: 750, attempt: 3, conclusion: nil})
      :ok = RunStore.put_github_updates({:release_build, @sha}, Map.merge(record, %{since: @created, since_attempt: 3, reruns: 2, rerun_attempt: 2, question: nil, answer: nil}))
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: @sha, number: 750, read_at: @now})
    end

    defp inbox, do: Inbox.items(%{}, name: {:test, make_ref()}, records: fn -> [] end, github_repos: %{})

    test "with no ticket held, a third cancellation asks on Symphony itself: one Inbox row, and Rerun the build reruns it at once (TP-1341)",
         %{github: github, opts: opts} do
      supervisor = start_supervised!(Task.Supervisor)
      store_cancelled_twice()
      runs(github, [run(3, "completed", "cancelled")])

      {result, log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{state: :asked, question: %{subject: :symphony, question_id: _id}}} = result
      assert log =~ "The release build of #{@sha} was cancelled for lack of a machine again and no held ticket waits on it: run_id=41086214847"
      refute_received {:asked, _ticket, _request}

      assert [%{subject: :symphony, title: "Symphony", identifier: nil, kind: :action, ask: title, review: review}] = inbox()
      assert title == "The Symphony v#{version()} build keeps being cancelled"
      assert %{question_id: id, options: [%{label: "Rerun the build", recommended: true}, %{label: "Wait for a fix"}]} = review
      assert review.question =~ "No ticket waits on it"
      assert ReleaseBuild.latest_build(now: @now).line == "The v#{version()} build: cancelled for lack of a machine 3 times; you were asked whether to rerun it"
      assert symphony_conditions() == []
      assert {:ok, pause} = Pauses.get(:symphony)
      assert Pauses.dispatch_reasons(pause) == []

      # Checked again unanswered: still one question, asked once.
      assert {:ok, %{state: :asked}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      assert [%{id: ^id}] = Questions.open(:symphony)

      decide = %{question_id: id, picks: [%{question: title, answer: "Rerun the build"}]}
      release_build_opts = [supervisor: supervisor] ++ opts

      assert {:ok, %{move: "decide", subject: "symphony", question_id: ^id, option: 1}} =
               DirectorMoves.decide_subject(decide, release_build_opts: release_build_opts)

      await_checks(supervisor)

      assert_received {:rerun, "41086214847"}
      assert %{state: :queued, reruns: 1, question: nil} = ReleaseBuild.get(@sha)
      assert inbox() == []
      assert Pauses.get(:symphony) == {:ok, nil}
      assert ["question.asked", "question.answered"] = :symphony |> TicketEvents.query_subject() |> Enum.map(& &1.type)

      assert DirectorMoves.decide_subject(decide) == {:error, :question_not_found}
    end

    test "with no ticket held, a failed build asks on Symphony; Wait for a fix keeps it unbuilt and asks nothing more", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{state: :failed, question: %{subject: :symphony, question_id: id}}} = result
      assert [%{title: title, question: question}] = Questions.open(:symphony)
      assert title == "The Symphony v#{version()} build failed"
      assert question =~ "the step “Build the app” of the job “release” failed"
      assert symphony_conditions() == []

      {:ok, _answered} = Questions.answer(:symphony, id, "Wait for a fix")
      assert {:ok, %{state: :failed, answer: %{kind: :failed, attempt: 1}}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      refute_received {:rerun, _id}
      assert Questions.open(:symphony) == []
      assert ReleaseBuild.line(@sha, nil, opts) =~ "failed on GitHub; waiting for a fix"
    end

    test "Rerun the build on a failed build no ticket waits on reruns it once", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{question: %{question_id: id}}} = result

      # Unanswered, the check keeps the question.
      assert {:ok, %{question: %{question_id: ^id}}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)

      {:ok, _answered} = Questions.answer(:symphony, id, "1")
      assert {:ok, %{state: :queued, question: nil}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      assert_received {:rerun, "41086214847"}
    end

    test "the question on Symphony is withdrawn once the build starts again on GitHub, or once withdrawn elsewhere", %{github: github, opts: opts} do
      store_cancelled_twice()
      runs(github, [run(3, "completed", "cancelled")])
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{question: %{question_id: id}}} = result

      # A person reran it on GitHub.
      runs(github, [run(4, "queued")])
      assert {:ok, %{state: :queued, question: nil}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      assert [%{state: :withdrawn, withdrawn: %{reason: "The build started again on GitHub, so nobody needs to answer."}}] = Questions.find(:symphony, id) |> List.wrap()
      assert inbox() == []

      # A question withdrawn by anyone else is dropped from the build's record.
      runs(github, [run(4, "completed", "failure")])
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{question: %{question_id: failed_id}}} = result
      {:ok, _withdrawn} = Questions.withdraw(:symphony, failed_id, "Not needed")
      assert {:ok, %{state: :failed, question: nil, answer: %{kind: :failed, attempt: 4}}} = ReleaseBuild.check(@sha, @repo, @repo_key, [], opts)
      assert Questions.open(:symphony) == []
    end

    test "a newer merge watched withdraws the questions about older builds", %{github: github, opts: opts} do
      store_cancelled_twice()
      runs(github, [run(3, "completed", "cancelled")])
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{question: %{question_id: id}}} = result

      newer = "1111111111111111111111111111111111111111"
      set(github, :main, [%{main_run(1, "queued") | "headSha" => newer, "number" => 751}])
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, Keyword.put(opts, :now, DateTime.add(@now, 61, :second)))

      assert %{state: :withdrawn, withdrawn: %{reason: "A newer merge's build is the one the app waits for now."}} = Questions.find(:symphony, id)
      assert inbox() == []
    end

    test "a newer merge's delivery withdraws them too, and a withdrawal the store refuses is logged", %{github: github, opts: opts} do
      supervisor = start_supervised!(Task.Supervisor)
      store_cancelled_twice()
      runs(github, [run(3, "completed", "cancelled")])
      {result, _log} = ExUnit.CaptureLog.with_log(fn -> ReleaseBuild.check(@sha, @repo, @repo_key, [], opts) end)
      assert {:ok, %{question: %{question_id: id}}} = result

      newer = "2222222222222222222222222222222222222222"
      runs(github, [%{run(1, "queued") | "number" => 751}])
      delivery_opts = [supervisor: supervisor, build: @build] ++ opts
      assert ReleaseBuild.delivered(release_delivery(%{head_sha: newer}), delivery_opts) == :started
      await_checks(supervisor)
      assert %{state: :withdrawn} = Questions.find(:symphony, id)

      # The Question service refusing the withdrawal: logged, the build's record goes on.
      refusing = Keyword.put(opts, :questions, __MODULE__.RefusingQuestions)
      record = Map.put(ReleaseBuild.get(newer), :question, %{kind: :cancelled, title: "t", attempt: 1, subject: :symphony, question_id: "q-1"})
      :ok = RunStore.put_github_updates({:release_build, newer}, record)
      log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{question: nil}} = ReleaseBuild.check(newer, @repo, @repo_key, [], refusing) end)
      assert log =~ "Could not withdraw the question q-1 about the release build of #{newer}: :store_down"

      # A question no longer open when a newer merge is watched is left as it is.
      set(github, :main, [%{main_run(1, "queued") | "headSha" => newer, "number" => 751}])
      later = Keyword.put(refusing, :now, DateTime.add(@now, 3_600, :second))
      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ReleaseBuild.watch_main(@repo, @repo_key, [], later) end)
      assert_received :main_read
      refute log =~ "Could not withdraw"
    end

    test "an older release run cancelled before it started while a newer run exists is replaced, never rerun", %{github: github, opts: opts} do
      supervisor = start_supervised!(Task.Supervisor)
      opts = [supervisor: supervisor, build: @build] ++ opts
      # GitHub cancels run 750, still pending, once run 751 of a newer push queues behind a running release.
      runs(github, [run(1, "completed", "cancelled")])
      set(github, :main, [%{main_run(1, "queued") | "number" => 751, "headSha" => "ABCDEF0123456789ABCDEF0123456789ABCDEF01"}])

      assert ReleaseBuild.delivered(release_delivery(), opts) == :started
      await_checks(supervisor)
      refute_received {:rerun, _id}
      refute_received {:asked, _ticket, _request}
      assert %{state: :superseded, reruns: 0, question: nil} = ReleaseBuild.get(@sha)
      assert ReleaseBuild.line(@sha, nil, opts) == "Waiting for the v#{version()} build: replaced by a newer build"

      # A held ticket waiting on the replaced commit doesn't rerun it either, and it is not read again.
      assert {:ok, %{state: :superseded}} = check(opts)
      refute_received {:rerun, _id}
      assert ReleaseBuild.delivered(@sha, opts) == :ignored
      runs(github, :down)
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, opts)
      assert %{state: :superseded} = ReleaseBuild.get(@sha)

      # The newest run of main, or one GitHub can't number, is starved, not replaced: it is rerun.
      runs(github, [run(1, "completed", "cancelled")])

      for {sha, newest} <- [{String.duplicate("4", 40), 750}, {String.duplicate("5", 40), nil}] do
        set(github, :main, [%{main_run(1, "queued") | "number" => newest}])
        assert {:ok, %{state: :queued, reruns: 1}} = ReleaseBuild.check(sha, @repo, @repo_key, [], opts)
        assert_received {:rerun, "41086214847"}
      end

      # When GitHub can't say whether a newer run exists, nothing is rerun and the check tries again later.
      set(github, :main, :down)
      assert {:ok, %{state: :not_started, reruns: 0}} = ReleaseBuild.check(String.duplicate("6", 40), @repo, @repo_key, [], opts)
      refute_received {:rerun, _id}
    end

    test "a failed build several unnamed held tickets wait on names them together", %{github: github, opts: opts} do
      runs(github, [run(1, "completed", "failure")])
      unnamed = [%{id: "issue-1", identifier: nil, state: "Todo"}, %{id: "issue-2", identifier: nil, state: "Todo"}]

      assert {:ok, %{state: :failed}} = ReleaseBuild.check(@sha, @repo, @repo_key, unnamed, opts)
      assert {:ok, %{reasons: [%{text: text}]}} = Pauses.get(:symphony)
      assert text =~ "the held tickets wait for it"
    end

    test "nothing watched yet, or main unreadable, changes nothing", %{github: github, opts: opts} do
      assert ReleaseBuild.latest_build() == nil
      :ok = RunStore.put_github_updates({:release_build, :latest}, %{sha: "unknown", number: nil, read_at: nil})
      assert ReleaseBuild.latest_build() == nil

      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, opts)
      assert_received :main_read
      set(github, :main, :down)
      assert :ok = ReleaseBuild.watch([], @build, %{}, @repo_key, opts)
      assert :ok = ReleaseBuild.watch_main(nil, @repo_key, [], opts)

      # The newest merge, kept nowhere, is read again next time.
      set(github, :main, [main_run(1, "queued")])
      runs(github, [run(1, "queued")])
      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ReleaseBuild.watch_main(@repo, @repo_key, [], Keyword.put(opts, :run_store, FailingStore)) end)
      assert log =~ "Could not record the newest release build"

      # A merge a held ticket waits on was checked already.
      assert :ok = ReleaseBuild.watch_main(@repo, @repo_key, [@sha], opts)
      refute_received {:rerun, _id}
      assert ReleaseBuild.get(@sha) == nil
      assert ReleaseBuild.latest_build() == nil
    end
  end

  # Waits for the checks a delivery started under `supervisor` to finish.
  defp await_checks(supervisor) do
    for pid <- Task.Supervisor.children(supervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    :ok
  end
end
