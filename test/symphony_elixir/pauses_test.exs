defmodule SymphonyElixir.PausesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Pauses, TicketState}
  alias SymphonyElixirWeb.ObservabilityPubSub

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

  # Runs `fun` on every input at once, each in its own process, and returns the results.
  defp concurrently(inputs, fun) do
    inputs
    |> Task.async_stream(fun, max_concurrency: Enum.count(inputs), ordered: false)
    |> Enum.map(fn {:ok, result} -> result end)
  end

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

      assert {:ok, %{reasons: [%{kind: :question}]}} = Pauses.clear_reason(@ticket, @dependency, at: @later)
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
      assert {:ok, %{reasons: [_question, _other]}} = Pauses.add_reason(@ticket, other, at: @later)

      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set", "pause.reason_added"]
    end

    test "the events carry the summaries readers show" do
      {:ok, _pause} = Pauses.set(@ticket, @question)
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency)

      assert [%{summary: %{title: "Paused: waiting for your answer"}}, %{summary: %{title: "Also paused: waiting for TP-1194 to finish"}}] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])
    end

    test "each change sends the live channel one notice of its event once stored; a no-op sends none" do
      :ok = ObservabilityPubSub.subscribe_ticket_events()
      :ok = RunStore.put_ticket_state(TicketState.new(@repo_key, @issue_id, %{issue_identifier: "TP-1230"}))

      {:ok, _pause} = Pauses.set(@ticket, @question, at: @at)
      {:ok, _pause} = Pauses.set(@ticket, @question, at: @at)
      {:ok, nil} = Pauses.clear(@ticket, at: @later)

      [set, cleared] = RunStore.list_ticket_events(@repo_key, @issue_id, [])
      assert_receive {:ticket_event, %{event_id: id, type: "pause.set", issue_identifier: "TP-1230"}} when id == set.id
      assert_receive {:ticket_event, %{event_id: id, type: "pause.cleared"}} when id == cleared.id
      refute_received {:ticket_event, _notice}
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

  describe "a backfilled reason" do
    test "records its event once, marked as the backfill's, whatever writes it again" do
      assert {:ok, _pause} = Pauses.set(@ticket, @dependency, at: @at, backfilled: true)
      assert {:ok, _pause} = Pauses.set(@ticket, @question, at: @at, backfilled: true)
      assert {:ok, _pause} = Pauses.set(@ticket, @dependency, at: @later, backfilled: true)

      assert [
               %{type: "pause.set", payload: %{source: "backfill", reason: "ticket"}, idempotency: "backfill:pause.set:ticket:" <> _},
               %{type: "pause.reason_added", payload: %{source: "backfill", reason: "question"}, idempotency: "backfill:pause.reason_added:question:" <> _}
             ] = RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert {:ok, _pause} = Pauses.add_reason(@ticket, %{kind: :environment, waits_on: %{condition: "CI"}}, at: @later)
      assert %{payload: payload, idempotency: nil} = List.last(RunStore.list_ticket_events(@repo_key, @issue_id, []))
      refute Map.has_key?(payload, :source)
    end
  end

  describe "a change for another writer of the ticket's record" do
    test "set_change/4 and clear_reason_change/4 give the pause and its events as set/3 and clear_reason/3 make them, and write nothing" do
      assert {:ok, %{reasons: [%{kind: :question, set_by: @person}], since: @at} = paused, [set]} =
               Pauses.set_change(@ticket, nil, @question, set_by: @person, at: @at)

      assert %{type: "pause.set", issue_id: @issue_id, at: @at, payload: %{reason: "question", waits_on: %{question_id: "q-1"}}} = set

      assert {:ok, %{reasons: [_question, %{kind: :ticket}]} = both, [%{type: "pause.reason_added"}]} =
               Pauses.set_change(@ticket, paused, @dependency, at: @later)

      assert Pauses.set_change(@ticket, both, @question, at: @later) == {:ok, both, []}

      assert {:ok, ^paused, [%{type: "pause.reason_cleared", payload: %{by: @person}}]} =
               Pauses.clear_reason_change(@ticket, both, @dependency, by: @person, at: @later)

      assert {:ok, nil, [%{type: "pause.cleared"}]} = Pauses.clear_reason_change(@ticket, paused, @question, at: @later)
      assert Pauses.clear_reason_change(@ticket, paused, @dependency, at: @later) == {:ok, paused, []}
      assert Pauses.clear_reason_change(@ticket, nil, @question, at: @later) == {:ok, nil, []}

      refute Pauses.paused?(@ticket)
      assert RunStore.get_ticket_state(@repo_key, @issue_id) == nil
      assert ticket_events(@repo_key, @issue_id) == []
    end

    test "refuses a subject that is not a ticket, and a reason, setter or time it doesn't know" do
      for subject <- [{:repository, "repo-a"}, :symphony, {:ticket, @repo_key, " "}] do
        assert Pauses.set_change(subject, nil, @question, []) == {:error, {:invalid_subject, subject}}
        assert Pauses.clear_reason_change(subject, nil, @question, []) == {:error, {:invalid_subject, subject}}
      end

      assert Pauses.set_change(@ticket, nil, :question, []) == {:error, {:invalid_reason, :question}}
      assert Pauses.set_change(@ticket, nil, @question, set_by: "Tony") == {:error, {:invalid_set_by, "Tony"}}
      assert Pauses.clear_reason_change(@ticket, nil, @question, by: "Tony") == {:error, {:invalid_set_by, "Tony"}}
      assert Pauses.clear_reason_change(@ticket, nil, @question, at: "now") == {:error, {:invalid_option, :at}}
    end
  end

  describe "concurrent writers" do
    test "adding distinct reasons at once keeps every reason and records one pause.reason_added each" do
      {:ok, _pause} = Pauses.set(@ticket, @question, at: @at)
      identifiers = for n <- 1..20, do: "TP-#{n}"

      add = &Pauses.add_reason(@ticket, %{kind: :ticket, waits_on: %{identifier: &1}}, at: @later)

      for result <- concurrently(identifiers, add) do
        assert {:ok, %{reasons: [%{kind: :question} | _dependencies]}} = result
      end

      assert {:ok, %{reasons: [%{kind: :question} | dependencies]}} = Pauses.get(@ticket)
      assert dependencies |> Enum.map(& &1.waits_on.identifier) |> Enum.sort() == Enum.sort(identifiers)

      added = for {"pause.reason_added", %{waits_on: %{identifier: identifier}}} <- ticket_events(@repo_key, @issue_id), do: identifier
      assert Enum.sort(added) == Enum.sort(identifiers)
      assert ticket_events(@repo_key, @issue_id, "pause.set") |> length() == 1
    end

    test "setting the same reason at once pauses once, with one pause.set" do
      for result <- concurrently(1..20, fn _n -> Pauses.set(@ticket, @question, at: @at) end) do
        assert {:ok, %{reasons: [%{kind: :question}]}} = result
      end

      assert kinds(@ticket) == [:question]
      assert ticket_events(@repo_key, @issue_id) |> Enum.map(&elem(&1, 0)) == ["pause.set"]
    end

    test "clearing two reasons at once clears the pause, with one pause.reason_cleared and one pause.cleared" do
      {:ok, _pause} = Pauses.set(@ticket, @question, at: @at)
      {:ok, _pause} = Pauses.add_reason(@ticket, @dependency, at: @at)

      reasons = List.duplicate(@question, 10) ++ List.duplicate(@dependency, 10)
      concurrently(reasons, &Pauses.clear_reason(@ticket, &1, at: @later))

      refute Pauses.paused?(@ticket)
      # Unsorted: the ledger keeps the order the changes were written in.
      cleared = for {type, _payload} <- ticket_events(@repo_key, @issue_id), type != "pause.set" and type != "pause.reason_added", do: type
      assert cleared == ["pause.reason_cleared", "pause.cleared"]
    end

    test "a repository's pause keeps every reason added at once" do
      repository = {:repository, @repo_key}
      conditions = for n <- 1..20, do: "condition-#{n}"

      concurrently(conditions, &Pauses.set(repository, %{kind: :environment, waits_on: %{condition: &1}}))

      assert {:ok, %{reasons: reasons}} = Pauses.get(repository)
      assert reasons |> Enum.map(& &1.waits_on.condition) |> Enum.sort() == Enum.sort(conditions)
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

    test "a ticket reason's line says why the ticket is waited on: a blocker, a fix ticket or a competing pull request" do
      for {source, identifier} <- [dependency: "TP-1", fix_ticket: "TP-2", landing: "TP-3"] do
        {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(source, identifier))
      end

      assert Pauses.why(@ticket) == [
               "Waiting for TP-1 to finish",
               "Waiting for TP-2 to finish: it fixes what stopped this ticket",
               "Waiting for TP-3 to land: it changes the same files"
             ]

      assert Pauses.ticket_reason(:dependency, "TP-1") == %{kind: :ticket, waits_on: %{identifier: "TP-1"}, text: "Waiting for TP-1 to finish"}
      assert Enum.map(["TP-12", "MT-9", "tp-12", "blocker-uuid", "TP-", nil], &Pauses.identifier?/1) == [true, true, false, false, false, false]
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
            %{kind: :ticket, waits_on: %{identifier: "3f2a9c1e-0000"}},
            %{kind: :ticket, waits_on: %{identifier: "tp-1"}},
            %{kind: :build, waits_on: %{version: "e6d62a75"}},
            %{kind: :build, waits_on: %{version: "lib/symphony"}},
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
