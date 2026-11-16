defmodule SymphonyElixir.StartNowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StartNow

  @facts %{phase: "In Progress", symphony_pause: nil, repository_pause: nil, open_question?: false, running?: false}

  describe "check/1" do
    test "an open ticket with nothing stopping it may be started" do
      assert :ok = StartNow.check(@facts)
      assert :ok = StartNow.check(%{@facts | phase: "Todo"})
      assert :ok = StartNow.check(%{@facts | phase: "Code Review"})
      assert :ok = StartNow.check(%{@facts | phase: "QA"})
      assert :ok = StartNow.check(%{@facts | phase: "CI Fix"})
      assert :ok = StartNow.check(%{@facts | phase: "Rework"})
    end

    test "a ticket in Backlog is refused with move it first" do
      assert {:error, "The ticket is in Backlog; move it to Todo with Move to… first."} = StartNow.check(%{@facts | phase: "Backlog"})
    end

    test "a closed ticket is refused, naming its state" do
      assert {:error, "The ticket is done."} = StartNow.check(%{@facts | phase: "Done"})
      assert {:error, "The ticket is cancelled."} = StartNow.check(%{@facts | phase: "Canceled"})
    end

    test "a ticket whose plan waits on a person is refused" do
      assert {:error, "The ticket's plan waits on a person."} = StartNow.check(%{@facts | phase: "Plan Review"})
    end

    test "a ticket waiting on its sub-tickets is refused" do
      assert {:error, "The ticket waits on its sub-tickets."} = StartNow.check(%{@facts | phase: "Waiting on sub-tickets"})
    end

    test "a ticket without a phase is refused as untracked" do
      assert {:error, "The ticket is not one Symphony tracks."} = StartNow.check(%{@facts | phase: nil})
    end

    test "Symphony's pause is the refusal, in the line the paused pass skips with" do
      assert {:error, "dispatch is paused by the operator"} =
               StartNow.check(%{@facts | symphony_pause: "dispatch is paused by the operator"})
    end

    test "the repository's pause is the refusal, in the line its candidates are skipped with" do
      assert {:error, "the repository is paused by you"} =
               StartNow.check(%{@facts | repository_pause: "the repository is paused by you"})
    end

    test "an open Question is the refusal" do
      assert {:error, "It waits on your answer first."} = StartNow.check(%{@facts | open_question?: true})
    end

    test "a run already working on the ticket is the refusal" do
      assert {:error, "A run is already working on it."} = StartNow.check(%{@facts | running?: true})
    end

    test "the refusals answer in order: the pauses before the Question before the run" do
      paused = %{
        @facts
        | symphony_pause: "dispatch is paused: updating to v0.0.1.42",
          repository_pause: "the repository is paused by you",
          open_question?: true,
          running?: true
      }

      assert {:error, "dispatch is paused: updating to v0.0.1.42"} = StartNow.check(paused)
      assert {:error, "the repository is paused by you"} = StartNow.check(%{paused | symphony_pause: nil})
      assert {:error, "It waits on your answer first."} = StartNow.check(%{paused | symphony_pause: nil, repository_pause: nil})
    end
  end

  describe "TP-1518: follow/2, Start does what the machine decided" do
    alias SymphonyElixir.Linear.Issue
    alias SymphonyElixir.PrDecision.Facts

    @fix %{kind: :ci_fix, rule: "R14", args: %{origin: :qa, cause: :conflict}, reason: "PR #915 conflicts with main: conflict fix run 1 of 3"}

    defp issue(state), do: %Issue{id: "issue-1", identifier: "TP-1508", state: state}
    defp watch(decision, facts \\ %{}), do: %{facts: struct(Facts, Map.merge(%{phase: :qa, pr_number: 915, mergeable: :dirty}, facts)), decision: decision}
    defp record(decision, facts \\ %{}), do: %{repo_key: "default", issue_id: "issue-1", pr_watch: watch(decision, facts)}

    defp follow(issue, watch, check \\ fn _id -> flunk("no Check Now expected") end, fetch \\ fn _id -> flunk("no read expected") end) do
      StartNow.follow(issue, watch: fn "issue-1" -> watch end, check: check, fetch: fetch)
    end

    test "a ticket whose watcher decided a conflict fix is sent to CI Fix by the watcher and started there" do
      check = fn "TP-1508" -> send(self(), :checked) && {:ok, record(@fix)} end
      fetch = fn "TP-1508" -> {:ok, issue("CI Fix")} end

      assert {:ok, %Issue{state: "CI Fix"}} = follow(issue("QA"), watch(@fix), check, fetch)
      assert_received :checked

      # From Merging or Code Review the same.
      assert {:ok, %Issue{state: "CI Fix"}} = follow(issue("Merging"), watch(@fix), check, fetch)
      assert {:ok, %Issue{state: "CI Fix"}} = follow(issue("Code Review"), watch(@fix), check, fetch)
    end

    test "a ticket in CI Fix starts its fix run as it is, and a ticket with no fix decided its phase's run" do
      assert {:ok, %Issue{state: "CI Fix"}} = follow(issue("CI Fix"), watch(@fix))
      assert {:ok, %Issue{state: "QA"}} = follow(issue("QA"), watch(%{kind: :dispatch, rule: "R27"}, %{mergeable: :clean}))
      assert {:ok, %Issue{state: "In Progress"}} = follow(issue("In Progress"), nil)
      assert {:ok, %Issue{state: "Rework"}} = follow(issue("Rework"), watch(%{kind: :dispatch, rule: "R26"}, %{mergeable: :dirty}))
    end

    test "a review or QA run never starts on a PR that conflicts with its base" do
      wait = %{kind: :wait, rule: "R14a", owner: :symphony}

      for state <- ["QA", "Code Review"] do
        assert {:error, {:start_refused, "PR #915 conflicts with its base: a conflict fix runs first, never a review on it."}} = follow(issue(state), watch(wait))
      end

      assert {:error, {:start_refused, "Its PR conflicts with its base: a conflict fix runs first, never a review on it."}} =
               follow(issue("QA"), watch(wait, %{pr_number: nil}))
    end

    test "a fix the watcher could not apply refuses the start, and one no longer decided starts the phase's run" do
      refused = {:error, {:start_refused, "Its PR needs a CI Fix run first, and Symphony could not send it to CI Fix yet; try again in a moment."}}
      in_qa = fn "TP-1508" -> {:ok, issue("QA")} end

      assert ^refused = follow(issue("QA"), watch(@fix), fn _id -> {:error, :watcher_not_running} end, in_qa)
      not_found = fn _id -> {:error, :issue_not_found} end
      assert ^refused = follow(issue("QA"), watch(@fix), fn _id -> {:ok, record(@fix)} end, not_found)
      # The watcher read the PR and still decides a fix, but the ticket did not move.
      assert ^refused = follow(issue("QA"), watch(@fix), fn _id -> {:ok, record(@fix)} end, in_qa)

      # Someone resolved the conflict meanwhile: the phase's run starts, unless the PR still conflicts.
      clean = record(%{kind: :dispatch, rule: "R27"}, %{mergeable: :clean})
      assert {:ok, %Issue{state: "QA"}} = follow(issue("QA"), watch(@fix), fn _id -> {:ok, clean} end, in_qa)

      still = record(%{kind: :wait, rule: "R14a", owner: :symphony})
      assert {:error, {:start_refused, "PR #915 conflicts" <> _rest}} = follow(issue("QA"), watch(@fix), fn _id -> {:ok, still} end, in_qa)
    end

    test "the defaults read the watcher's record and run Check Now" do
      assert {:ok, %Issue{state: "In Progress"}} = StartNow.follow(issue("In Progress"), fetch: fn _id -> flunk("no read expected") end)
    end
  end
end
