defmodule SymphonyElixir.PausesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, TicketState}

  @repo_key "repo-a"
  @issue_id "issue-1"
  @ticket {:ticket, @repo_key, @issue_id}
  @at ~U[2026-10-30 04:00:00Z]
  @later ~U[2026-10-30 05:00:00Z]
  @question %{kind: :question, waits_on: %{question_id: "q-1"}}
  @dependency %{kind: :ticket, waits_on: %{identifier: "TP-1194"}}
  @person %{kind: :person, name: "Tony"}
  @symphony %{kind: :symphony, name: "Symphony"}

  setup do
    :ok = RunStore.clear()
  end

  defp kinds(subject), do: subject |> Pauses.get() |> elem(1) |> Map.fetch!(:reasons) |> Enum.map(& &1.kind)

  describe "a ticket's pause" do
    test "a ticket paused on a question that then gains a dependency shows both reasons, and answering the question leaves it paused on the dependency" do
      assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.set(@ticket, @question, at: @at)
      assert {:ok, %{reasons: [_question, _dependency]}} = Pauses.add_reason(@ticket, @dependency, at: @later)

      assert Pauses.why(@ticket) == ["Waiting for your answer", "Waiting for TP-1194 to finish"]
      assert Enum.map(TicketState.pause_reasons(RunStore.get_ticket_state(@repo_key, @issue_id)), & &1.kind) == [:question, :ticket]

      assert {:ok, %{reasons: [%{kind: :ticket}], since: @at, set_by: @symphony}} =
               Pauses.clear_reason(@ticket, @question, by: @person, at: @later)

      assert Pauses.paused?(@ticket)
      assert Pauses.why(@ticket) == ["Waiting for TP-1194 to finish"]

      assert ticket_events(@repo_key, @issue_id) == [
               {"pause.set", %{reason: "question", text: "Waiting for your answer", waits_on: %{question_id: "q-1"}, set_by: @symphony, releasable: false}},
               {"pause.reason_added", %{reason: "ticket", text: "Waiting for TP-1194 to finish", waits_on: %{identifier: "TP-1194"}, set_by: @symphony, releasable: false}},
               {"pause.reason_cleared", %{reason: "question", text: "Waiting for your answer", waits_on: %{question_id: "q-1"}, by: @person}}
             ]
    end

    test "a pause with two reasons stays until both are cleared; clearing the last records pause.cleared" do
      {:ok, _pause} = Pauses.set(@ticket, @question, set_by: @person, at: @at)
      {:ok, _pause} = Pauses.set(@ticket, @dependency, at: @at)

      assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.clear_reason(@ticket, @dependency)
      assert Pauses.paused?(@ticket)
      assert {:ok, nil} = Pauses.clear_reason(@ticket, @question, at: @later)

      refute Pauses.paused?(@ticket)
      assert Pauses.why(@ticket) == []
      assert RunStore.get_ticket_state(@repo_key, @issue_id).pause == nil

      assert {"pause.cleared", %{cleared: [%{reason: :question, text: "Waiting for your answer", waits_on: %{question_id: "q-1"}}], by: @symphony}} =
               List.last(ticket_events(@repo_key, @issue_id))

      assert [%{summary: %{title: "Moving again"}}] = RunStore.list_ticket_events(@repo_key, @issue_id, types: ["pause.cleared"])
    end

    test "setting a reason of the same kind and waits_on twice adds no reason and records no event" do
      {:ok, pause} = Pauses.set(@ticket, @question, at: @at)

      assert Pauses.set(@ticket, Map.put(@question, :text, "Another line"), at: @later) == {:ok, pause}
      assert Pauses.add_reason(@ticket, @question, at: @later) == {:ok, pause}
      other = %{@question | waits_on: %{question_id: "q-2"}}
      assert {:ok, %{reasons: [_question, _other]}} = Pauses.add_reason(@ticket, other)

      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set", "pause.reason_added"]
    end

    test "the events carry the summaries readers show" do
      {:ok, _pause} = Pauses.set(@ticket, @question)
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency)

      assert [%{summary: %{title: "Paused: waiting for your answer"}}, %{summary: %{title: "Also paused: waiting for TP-1194 to finish"}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "pauses a ticket whose record exists without touching the rest of it" do
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{phase: "In Progress", issue_identifier: "TP-1230"}))

      {:ok, _pause} = Pauses.set(@ticket, @dependency, at: @at)

      record = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert %{phase: "In Progress", issue_identifier: "TP-1230", pause: %{since: @at}, updated_at: @at} = record
    end

    test "clear/2 clears every reason at once, recording pause.cleared with them" do
      {:ok, _pause} = Pauses.set(@ticket, @question)
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency)

      assert Pauses.clear(@ticket, by: @person) == {:ok, nil}
      refute Pauses.paused?(@ticket)

      assert {"pause.cleared", %{cleared: [%{reason: :question}, %{reason: :ticket}], by: @person}} = List.last(ticket_events(@repo_key, @issue_id))
    end

    test "clearing what is not there changes nothing and records nothing" do
      assert Pauses.clear(@ticket) == {:ok, nil}
      assert Pauses.clear_reason(@ticket, @question) == {:ok, nil}

      {:ok, pause} = Pauses.set(@ticket, @question)
      assert Pauses.clear_reason(@ticket, @dependency) == {:ok, pause}

      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set"]
    end

    test "a reason or a time the ledger would refuse leaves the ticket's record and its events as they were" do
      long = %{kind: :question, waits_on: %{question_id: "q-9"}, text: String.duplicate("word ", 70)}
      long_default = %{kind: :ticket, waits_on: %{identifier: String.duplicate("T", 290)}}

      for reason <- [long, long_default] do
        assert Pauses.set(@ticket, reason, at: @at) == {:error, {:invalid_reason, reason}}
      end

      assert Pauses.set(@ticket, @question, at: "now") == {:error, {:invalid_option, :at}}
      refute Pauses.paused?(@ticket)
      assert RunStore.get_ticket_state(@repo_key, @issue_id) == nil

      {:ok, pause} = Pauses.set(@ticket, @question, at: @at)
      assert Pauses.add_reason(@ticket, long, at: @later) == {:error, {:invalid_reason, long}}
      assert Pauses.clear_reason(@ticket, @question, at: "now") == {:error, {:invalid_option, :at}}
      assert Pauses.clear(@ticket, at: "now") == {:error, {:invalid_option, :at}}

      assert Pauses.get(@ticket) == {:ok, pause}
      assert %{pause: ^pause, updated_at: @at} = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set"]

      at_limit = %{long | text: String.duplicate("w", 300)}
      assert {:ok, %{reasons: [_question, %{text: text}]}} = Pauses.add_reason(@ticket, at_limit, at: @later)
      assert String.length(text) == 300
      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set", "pause.reason_added"]
    end

    test "add_reason/3 needs a pause to add to" do
      assert Pauses.add_reason(@ticket, @dependency) == {:error, :not_paused}
      refute Pauses.paused?(@ticket)
      assert ticket_events(@repo_key, @issue_id) == []
    end
  end

  describe "why/1" do
    test "gives one line per reason in plain words, with no code, paths or identifiers other than ticket identifiers" do
      reasons = [
        @question,
        @dependency,
        %{kind: :build, waits_on: %{version: "1.4.0"}},
        %{kind: :build, waits_on: %{pull_request: 448}},
        %{kind: :person, waits_on: %{action: :unblock}},
        %{kind: :person, waits_on: %{action: "restart"}},
        %{kind: :environment, waits_on: %{condition: "github_rate_limit"}},
        %{kind: :environment, waits_on: %{condition: "linear_down"}, text: "Waiting for\n  Linear to answer again"}
      ]

      for reason <- reasons, do: {:ok, _pause} = Pauses.set(@ticket, reason)

      assert Pauses.why(@ticket) == [
               "Waiting for your answer",
               "Waiting for TP-1194 to finish",
               "Waiting for Symphony version 1.4.0, which has the fix",
               "Waiting for a Symphony build with the fix",
               "Waiting for you to unblock it",
               "Waiting for you to restart it",
               "Waiting for the environment to be ready",
               "Waiting for Linear to answer again"
             ]

      for line <- Pauses.why(@ticket), do: refute(line =~ ~r/[_\/`{}:#]|\n/, line)
    end

    test "a subject not paused, or one that can't be read, has no reasons" do
      assert Pauses.why(:symphony) == []
      assert Pauses.why(:nonsense) == []
      refute Pauses.paused?(:nonsense)
      refute Pauses.releasable?(:nonsense)
    end
  end

  describe "releasable?/1" do
    test "is true when a reason is the person's, or a ticket or environment reason the person may release" do
      {:ok, _pause} = Pauses.set(@ticket, @question)
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency)
      {:ok, _pause} = Pauses.add_reason(@ticket, %{kind: :build, waits_on: %{version: "1.4.0"}, releasable: true})
      refute Pauses.releasable?(@ticket)

      {:ok, _pause} = Pauses.add_reason(@ticket, %{kind: :environment, waits_on: %{condition: "linear_down"}, releasable: true})
      assert Pauses.releasable?(@ticket)

      repository = {:repository, @repo_key}
      {:ok, _pause} = Pauses.set(repository, %{@dependency | waits_on: %{identifier: "TP-1"}} |> Map.put(:releasable, true))
      assert Pauses.releasable?(repository)

      {:ok, _pause} = Pauses.set(:symphony, %{kind: :person, waits_on: %{action: "unblock"}, releasable: false})
      assert Pauses.releasable?(:symphony)
    end
  end

  describe "a repository's and Symphony's pause" do
    test "is kept by subject, records no event and clears like a ticket's" do
      repository = {:repository, @repo_key}
      environment = %{kind: :environment, waits_on: %{condition: "github_down"}}

      assert {:ok, %{subject: ^repository, set_by: @person, since: @at}} = Pauses.set(repository, environment, set_by: @person, at: @at)
      assert {:ok, %{subject: :symphony}} = Pauses.set(:symphony, %{kind: :build, waits_on: %{version: "1.4.0"}})
      assert {:ok, _pause} = Pauses.add_reason(repository, @question)

      assert kinds(repository) == [:environment, :question]
      assert Pauses.why(:symphony) == ["Waiting for Symphony version 1.4.0, which has the fix"]
      refute Pauses.paused?({:repository, "repo-b"})

      assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.clear_reason(repository, environment)
      assert {:ok, nil} = Pauses.clear_reason(repository, @question)
      refute Pauses.paused?(repository)
      assert RunStore.get_subject_pause(repository) == nil

      assert {:ok, nil} = Pauses.clear(:symphony)
      refute Pauses.paused?(:symphony)

      assert RunStore.list_ticket_events(@repo_key, @issue_id, []) == []
    end
  end

  describe "errors" do
    test "refuses a subject, a reason or a setter it doesn't know" do
      subjects = [{:ticket, @repo_key, " "}, {:ticket, @repo_key, nil}, {:repository, ""}, {:repository, :x}, "TP-1", nil]

      for subject <- subjects do
        assert Pauses.set(subject, @question) == {:error, {:invalid_subject, subject}}
        assert Pauses.get(subject) == {:error, {:invalid_subject, subject}}
      end

      for reason <- [
            %{kind: :hold, waits_on: %{}},
            %{kind: :question, waits_on: %{}},
            %{kind: :question, waits_on: %{question_id: "  "}},
            %{kind: :ticket, waits_on: "TP-1"},
            %{kind: :build, waits_on: %{pull_request: 0}},
            %{kind: :person, waits_on: %{action: "decide"}},
            %{kind: :person, waits_on: %{action: :decide}},
            %{kind: :person, waits_on: %{}},
            :question
          ] do
        assert Pauses.set(@ticket, reason) == {:error, {:invalid_reason, reason}}
      end

      for set_by <- [%{kind: :robot, name: "R2"}, %{kind: :person, name: " "}, "Tony"] do
        assert Pauses.set(@ticket, @question, set_by: set_by) == {:error, {:invalid_set_by, set_by}}
        assert Pauses.clear(@ticket, by: set_by) == {:error, {:invalid_set_by, set_by}}
      end

      assert Pauses.add_reason(:symphony, @question) == {:error, :not_paused}
      refute Pauses.paused?(@ticket)
    end
  end

  describe "normalize/1" do
    test "keeps each kind and waits_on once, fills defaults and reads anything else as no pause" do
      stored = %{
        subject: @ticket,
        reasons: [
          Map.merge(@question, %{set_by: @person, set_at: @at}),
          Map.merge(@question, %{text: "Duplicate", set_at: @later}),
          %{kind: :person, waits_on: %{action: "unblock"}, set_by: %{kind: :run, name: 7}},
          :junk
        ]
      }

      assert %{
               subject: @ticket,
               set_by: @person,
               since: @at,
               reasons: [
                 %{kind: :question, text: "Waiting for your answer", set_by: @person, set_at: @at, releasable: false},
                 %{kind: :person, set_by: @symphony, set_at: nil, releasable: true}
               ]
             } = Pauses.normalize(stored)

      assert %{set_by: @symphony, since: @later} = Pauses.normalize(Map.merge(stored, %{set_by: @symphony, since: @later}))
      assert Pauses.normalize(%{stored | reasons: [:junk]}) == nil
      assert Pauses.normalize(%{stored | subject: :nowhere}) == nil
      assert Pauses.normalize(%{subject: @ticket}) == nil
      assert Pauses.normalize(nil) == nil
    end
  end
end
