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
end
