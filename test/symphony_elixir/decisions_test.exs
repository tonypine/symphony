defmodule SymphonyElixir.DecisionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Decisions, IssueSummary, RunStore}
  alias SymphonyElixir.HumanActions.Request
  alias SymphonyElixir.Linear.{Adapter, Client}
  alias SymphonyElixir.Tracker.Memory

  @issue_id "issue-1"
  @date ~D[2026-10-13]
  @repo_key "decisions-test"

  # Records the writes, and answers reads from the process dictionary.
  defmodule FakeTracker do
    def fetch_issue_description(_issue_id), do: Process.get({__MODULE__, :description}, {:ok, "Fix it."})

    def update_issue_description(issue_id, description) do
      send(self(), {:description_written, issue_id, description})
      Process.get({__MODULE__, :update}, :ok)
    end
  end

  # A run store that can't be read.
  defmodule DownStore do
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :down}
  end

  # A run store that reads, but refuses to record a decision.
  defmodule WriteFailingStore do
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
    def record_ticket_decisions(_repo_key, _issue_id, _entries, _backfill), do: {:error, :disk_full}
  end

  # Answers the description query and the update mutation by operation name.
  defmodule FakeClient do
    def graphql(query, variables) do
      cond do
        String.contains?(query, "SymphonyIssueDescription") -> Process.get({__MODULE__, :read})
        String.contains?(query, "SymphonyUpdateIssueDescription") -> send(self(), {:update_variables, variables}) && Process.get({__MODULE__, :update})
      end
    end
  end

  defp memory_issue, do: %Issue{id: @issue_id, identifier: "TP-1", description: "Fix it."}

  defp entry(attrs \\ %{}) do
    Map.merge(
      Decisions.entry("comment-1", @date, "Keep the legacy partials", "Remove the legacy partials here, or leave them for TP-891?", "Defer to TP-891: don't make that change."),
      attrs
    )
  end

  defp request_body(title \\ "Keep the legacy partials") do
    Request.render_hold(
      %{
        title: title,
        question: "Remove the legacy partials here, or leave them for TP-891?",
        why: "The reviewer keeps flagging them.",
        options: [
          %{label: "Defer to TP-891", effect: "The partials stay; TP-891 removes them.", recommended: true},
          %{label: "Remove them here", effect: "This PR removes the partials."}
        ]
      },
      "Code Review"
    )
  end

  # What Linear stores of a written description: `*` bullets, nested ones indented by four.
  defp linear_stored(description), do: description |> String.replace("\n  - ", "\n    * ") |> String.replace("\n- ", "\n* ")

  # The section's entries written `copies` times, the last copy after a blank line, as on TP-892.
  defp repeated(description, copies) do
    [before, section] = String.split(description, Decisions.start_marker())
    [head, entries] = String.split(section, "\n\n* **D1**", parts: 2)
    [entries, _end] = String.split("* **D1**" <> entries, "\n\n" <> Decisions.end_marker())
    copies = Enum.join(List.duplicate(entries, copies - 1), "\n") <> "\n\n" <> entries
    before <> Decisions.start_marker() <> head <> "\n\n" <> copies <> "\n" <> Decisions.end_marker()
  end

  defp ticket(comments, attrs \\ %{}), do: Map.merge(%{"id" => @issue_id, "description" => "Fix it.", "comments" => %{"nodes" => comments}}, attrs)

  defp comment(id, body, created_at \\ "2026-10-13T05:40:00Z", parent \\ nil),
    do: %{"id" => id, "body" => body, "createdAt" => created_at, "parent" => parent && %{"id" => parent}}

  describe "entry/5 and scope/1" do
    test "reads the scope from the answer" do
      assert entry().scope == "Deferred to TP-891"
      assert Decisions.scope("Defer it, please") == "Out of scope"
      assert Decisions.scope("This is out of scope for now") == "Out of scope"
      assert Decisions.scope("Leave them for later") == "Out of scope"
      assert Decisions.scope("Do not touch the partials") == "As answered"
      assert Decisions.scope("Yes, that's in scope") == "In scope"
      assert Decisions.scope("Ship unsigned builds") == "As answered"
    end

    test "a negated deferral or removal is no scope" do
      assert Decisions.scope("do not defer to TP-891") == "As answered"
      assert Decisions.scope("Don't worry, include it") == "As answered"
      assert Decisions.scope("No need to defer this") == "As answered"
      assert Decisions.scope("Never leave it out") == "As answered"
      assert Decisions.scope("Don't defer to TP-891; it is in scope") == "In scope"
      assert Decisions.scope("Don't defer to TP-891, defer to TP-900") == "Deferred to TP-900"
      assert Decisions.scope("No, defer it to TP-891") == "Deferred to TP-891"
      assert Decisions.scope("Defer it, but name no ticket") == "Out of scope"
    end

    test "folds text onto one line and drops comment markers, so it can't close the section" do
      decision = Decisions.entry("c", @date, nil, "Which\n\nway? <!-- x -->", "## Left -->\n now")

      assert decision.title == "Which way? x"
      assert decision.question == "Which way? x"
      assert decision.answer == "Left now"
      assert %{title: "", question: ""} = Decisions.entry("c", @date, nil, nil, "Yes")
    end
  end

  describe "put/2" do
    test "appends the section to a description with none, and leaves the rest as it is" do
      assert {:ok, description} = Decisions.put("Fix it.\n", [entry()])

      assert String.starts_with?(description, "Fix it.\n\n" <> Decisions.start_marker() <> "\n### Decisions")
      assert String.ends_with?(description, Decisions.end_marker())

      assert description =~
               "- **D1** · 2026-10-13 · Keep the legacy partials <!-- symphony:decision:comment-1 -->\n" <>
                 "  - **Question:** Remove the legacy partials here, or leave them for TP-891?\n" <>
                 "  - **Answer:** Defer to TP-891: don't make that change.\n" <>
                 "  - **Scope:** Deferred to TP-891"
    end

    test "starts an empty description with the section" do
      assert {:ok, description} = Decisions.put(nil, [entry()])
      assert String.starts_with?(description, Decisions.start_marker())
    end

    test "goes before the summary block, which stays last" do
      {:ok, summary} = IssueSummary.new(%{"status" => "PR open", "changelog_entry" => "Opened the PR"})
      {:ok, with_summary} = IssueSummary.put("Fix it.", summary, @date)

      assert {:ok, description} = Decisions.put(with_summary, [entry()])

      [before_summary, _summary] = String.split(description, IssueSummary.start_marker())
      assert before_summary =~ "Fix it.\n\n" <> Decisions.start_marker()
      assert String.ends_with?(before_summary, Decisions.end_marker() <> "\n\n")
      assert IssueSummary.strip(description) =~ "Fix it."
    end

    test "adds a new decision at the end of the section, numbered after the ones there" do
      {:ok, first} = Decisions.put("Fix it.", [entry()])
      second = entry(%{key: "comment-2", title: "Sign the builds", question: "Sign them?", answer: "Yes, in scope", scope: "In scope"})

      assert {:ok, description} = Decisions.put(first <> "\n\nA person's note.", [second, second])

      assert [%{id: "D1", key: "comment-1"}, %{id: "D2", key: "comment-2", scope: "In scope"}] = Decisions.recorded(description)
      assert String.ends_with?(description, Decisions.end_marker() <> "\n\nA person's note.")
    end

    test "changes nothing when every decision is already recorded" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])

      assert {:ok, ^description} = Decisions.put(description, [entry(%{answer: "Something else"})])
      assert {:ok, "Fix it."} = Decisions.put("Fix it.", [])
    end

    test "changes nothing on a section as Linear stores it, and numbers a new decision after it" do
      {:ok, written} = Decisions.put("Fix it.", [entry()])
      stored = linear_stored(written)
      second = entry(%{key: "comment-2", title: "Sign the builds"})

      assert {:ok, ^stored} = Decisions.put(stored, [entry()])
      assert [%{id: "D1", key: "comment-1", date: "2026-10-13", scope: "Deferred to TP-891"}] = Decisions.recorded(stored)

      assert {:ok, description} = Decisions.put(stored, [entry(), second])
      assert [%{id: "D1", key: "comment-1"}, %{id: "D2", key: "comment-2"}] = Decisions.recorded(description)
      assert String.ends_with?(description, "Scope:** Deferred to TP-891\n\n" <> Decisions.end_marker())
    end

    test "rewrites a section that holds a decision more than once, and drops the empty heading above it" do
      second = entry(%{key: "comment-2", title: "Sign the builds"})
      {:ok, written} = Decisions.put("Fix it.\n\n##", [entry(), second])
      repeated = written |> linear_stored() |> repeated(4)

      assert [%{id: "D1", key: "comment-1"}, %{id: "D2", key: "comment-2"}] = Decisions.recorded(repeated)
      assert {:ok, repaired} = Decisions.put(repeated <> "\n\nAfter.", [])

      assert String.starts_with?(repaired, "Fix it.\n\n" <> Decisions.start_marker())
      assert String.ends_with?(repaired, Decisions.end_marker() <> "\n\nAfter.")
      assert length(Regex.scan(~r/symphony:decision:comment-1/, repaired)) == 1
      assert [%{id: "D1", date: "2026-10-13"}, %{id: "D2", key: "comment-2"}] = Decisions.recorded(repaired)
      assert {:ok, ^repaired} = Decisions.put(repaired, [entry()])

      third = entry(%{key: "comment-3", title: "Ship it"})
      assert {:ok, extended} = Decisions.put(repeated, [third])
      assert [%{id: "D1"}, %{id: "D2"}, %{id: "D3", key: "comment-3"}] = Decisions.recorded(extended)
    end

    test "goes before the empty heading Linear made of the summary's marker line, and drops it" do
      summary = IssueSummary.start_marker() <> "\n\n### Symphony summary\n" <> IssueSummary.end_marker()

      assert {:ok, description} = Decisions.put("Fix it.\n\n## " <> summary, [entry()])

      assert String.starts_with?(description, "Fix it.\n\n" <> Decisions.start_marker())
      assert String.ends_with?(description, Decisions.end_marker() <> "\n\n" <> summary)
    end

    test "refuses a section with no end marker" do
      assert {:error, :decisions_block_unterminated} = Decisions.put("Fix it.\n" <> Decisions.start_marker() <> "\nhalf", [entry()])
    end
  end

  describe "recorded/1, find/3 and strip/1" do
    test "reads each decision back with its label" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])

      assert [
               %{
                 id: "D1",
                 key: "comment-1",
                 title: "Keep the legacy partials",
                 question: "Remove the legacy partials here, or leave them for TP-891?",
                 answer: "Defer to TP-891: don't make that change.",
                 scope: "Deferred to TP-891"
               }
             ] = Decisions.recorded(description)

      assert Decisions.recorded("Fix it.") == []
      assert Decisions.recorded(nil) == []
      assert Decisions.recorded(Decisions.start_marker() <> "\nstray line\n  - **Answer:** orphan\n" <> Decisions.end_marker()) == []
    end

    test "finds a decision by its title or its question, ignoring case and spacing" do
      decisions = [entry()]

      assert Decisions.find(decisions, "  keep the LEGACY   partials ", nil) == entry()
      assert Decisions.find(decisions, "Another title", "Remove the legacy partials here, or leave them for TP-891?") == entry()
      assert Decisions.find(decisions, "Another title", "Another question") == nil
      assert Decisions.find(decisions, nil, nil) == nil
    end

    test "strips the section and keeps the person's text" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])

      assert Decisions.strip(description <> "\n\nAfter.") == "Fix it.\n\nAfter."
      assert Decisions.strip("Fix it.") == "Fix it."
      assert Decisions.strip(nil) == nil
    end
  end

  describe "stored/2 and prompt_section/1" do
    test "renders the decisions the store records as untrusted Linear text, with no Linear read" do
      Process.put({FakeTracker, :description}, {:ok, "Fix it."})
      assert :ok = Decisions.record(@issue_id, [entry()], tracker: FakeTracker, repo_key: @repo_key)

      # The description lost its section: the store still holds the decision.
      decisions = Decisions.stored(%{id: @issue_id, description: "Fix it.", repo_key: @repo_key})
      assert [%{id: "D1", key: "comment-1", date: @date}] = decisions

      section = Decisions.prompt_section(decisions)

      assert section =~ "Recorded decisions (a person's answers to this ticket's decision requests and the rulings they gave in comments; they are part of its scope):"
      assert section =~ "<linear_issue_decisions>"
      assert section =~ "D1: Remove the legacy partials here, or leave them for TP-891? Answer: Defer to TP-891: don't make that change. Scope: Deferred to TP-891."
    end

    test "is empty without decisions" do
      assert Decisions.stored(%{id: "undecided", description: "Fix it.", repo_key: @repo_key}) == []
      assert Decisions.prompt_section([]) == ""
    end

    test "backfills a store with no decision from the description's section, once" do
      {:ok, description} = Decisions.put("Fix it.", [entry(), entry(%{key: "comment-2", date: "someday"})])
      issue = %{id: @issue_id, description: description}

      assert [%{id: "D1", key: "comment-1", date: @date}, %{id: "D2", key: "comment-2", date: "someday"}] = Decisions.stored(issue, repo_key: @repo_key)
      assert [%{key: "comment-1"}, %{key: "comment-2"}] = RunStore.get_ticket_state(@repo_key, @issue_id).decisions

      # A section that later holds another entry is not backfilled again: the store is the truth.
      {:ok, edited} = Decisions.put(description, [entry(%{key: "comment-3"})])
      assert [%{key: "comment-1"}, %{key: "comment-2"}] = Decisions.stored(%{issue | description: edited}, repo_key: @repo_key)
      assert [%{key: "comment-1"}, %{key: "comment-2"}] = RunStore.get_ticket_state(@repo_key, @issue_id).decisions
    end

    test "reads the description's section when the store can't be read" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])

      assert [%{id: "D1", key: "comment-1"}] = Decisions.stored(%{id: @issue_id, description: description}, repo_key: @repo_key, store: DownStore)
      assert [%{id: "D1"}] = Decisions.stored(%{description: description})
      assert Decisions.stored(%{id: @issue_id, description: nil}, repo_key: "") == []
    end
  end

  describe "the store record" do
    test "an answer to a decision request is in the ticket's store record and in its description" do
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")])

      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)

      assert_received {:description_written, @issue_id, description}
      assert [%{id: "D1", key: "c1", scope: "Deferred to TP-891"}] = Decisions.recorded(description)
      assert [%{key: "c1", date: ~D[2026-10-13], title: "Keep the legacy partials", scope: "Deferred to TP-891"}] = RunStore.get_ticket_state(@repo_key, @issue_id).decisions
    end

    test "a section removed by hand is rewritten from the store on the next read, with the same entries" do
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1"), comment("c2", "Ruling: keep the flag")])
      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)
      assert_received {:description_written, @issue_id, written}

      # A person deletes the section, and the comments that recorded the answers are gone too.
      Process.put({FakeTracker, :description}, {:ok, "Fix it."})
      assert :ok = Decisions.sync(ticket([]), tracker: FakeTracker, repo_key: @repo_key)
      assert_received {:description_written, @issue_id, ^written}

      # The poll rewrites it the same way, and leaves a section that shows every decision alone.
      issues = [%Issue{id: @issue_id, description: "Fix it."}, %Issue{id: "other", description: "Other."}]
      assert Decisions.sweep(issues, tracker: FakeTracker, repo_key: @repo_key) == 1
      assert_received {:description_written, @issue_id, ^written}

      Process.put({FakeTracker, :description}, {:error, :must_not_read})
      assert Decisions.sweep([%Issue{id: @issue_id, description: written}], tracker: FakeTracker, repo_key: @repo_key) == 0
      refute_received {:description_written, _issue_id, _description}
    end

    test "an existing ticket's section is backfilled into the store once, with no duplicate entries" do
      {:ok, description} = Decisions.put("Fix it.", [entry(%{key: "c1"})])
      Process.put({FakeTracker, :description}, {:error, :must_not_read})
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")], %{"description" => description})

      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)
      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)

      refute_received {:description_written, _issue_id, _description}
      assert [%{key: "c1", date: @date}] = RunStore.get_ticket_state(@repo_key, @issue_id).decisions
    end

    test "refuses a write with no repo to keep it in" do
      assert capture_log(fn -> assert {:error, :missing_repo_key} = Decisions.record(@issue_id, [entry()], tracker: FakeTracker, repo_key: "") end) =~
               "missing_repo_key"

      refute_received {:description_written, _issue_id, _description}
    end
  end

  describe "the events an answer records" do
    test "a reply records one decision.recorded by the Director, naming its request, however often it is synced" do
      decision = %{title: "Keep the legacy partials", question: "Remove the legacy partials here, or leave them for TP-891?"}
      :ok = SymphonyElixir.Hold.set(@repo_key, @issue_id, :needs_decision, %{reason: decision.question, decision: decision})
      [%{id: request_id}] = RunStore.list_ticket_events(@repo_key, @issue_id, [])
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")])

      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)
      assert :ok = Decisions.sync(node, tracker: FakeTracker, repo_key: @repo_key)
      assert :ok = Decisions.record(@issue_id, Decisions.answered(node), tracker: FakeTracker, repo_key: @repo_key)

      assert [_requested, %{type: "decision.recorded", actor: %{kind: :person, name: "the Director"}, idempotency: "decision.recorded:c1"} = recorded] =
               RunStore.list_ticket_events(@repo_key, @issue_id, [])

      assert %{answer: "Defer to TP-891 (option: **Defer to TP-891** (recommended): The partials stay; TP-891 removes them.)", key: "c1", request: ^request_id} =
               recorded.payload

      assert recorded.payload.title == "Keep the legacy partials"
    end

    test "a ruling records its decision.recorded naming no request" do
      :ok = SymphonyElixir.Hold.set(@repo_key, @issue_id, :needs_decision, %{decision: %{title: "Keep the flag", question: "Keep it?"}})

      assert :ok = Decisions.sync(ticket([comment("c2", "Ruling: Keep the flag")]), tracker: FakeTracker, repo_key: @repo_key)

      assert [{"decision.requested", _requested}, {"decision.recorded", %{answer: "Keep the flag", key: "ruling-c2"} = ruling}] =
               ticket_events(@repo_key, @issue_id)

      refute Map.has_key?(ruling, :request)
    end

    test "the decisions backfilled from the description and a write the store refuses record nothing" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])
      assert [%{key: "comment-1"}] = Decisions.stored(%{id: @issue_id, description: description}, repo_key: @repo_key)

      log =
        capture_log(fn ->
          assert {:error, :down} = Decisions.record("issue-2", [entry()], tracker: FakeTracker, repo_key: @repo_key, store: DownStore)
          assert {:error, :disk_full} = Decisions.record("issue-2", [entry()], tracker: FakeTracker, repo_key: @repo_key, store: WriteFailingStore)
        end)

      assert log =~ ":down"
      assert log =~ ":disk_full"

      assert ticket_events(@repo_key, @issue_id) == []
      assert ticket_events(@repo_key, "issue-2") == []
    end
  end

  describe "answered/1" do
    test "reads a request answered by a reply, with the option the reply picks" do
      node =
        ticket([
          comment("c1", request_body()),
          comment("r2", "Something later", "2026-10-14T09:00:00Z", "c1"),
          comment("r1", "Defer to TP-891", "2026-10-13T05:48:00Z", "c1")
        ])

      assert [
               %{
                 key: "c1",
                 date: ~D[2026-10-13],
                 title: "Keep the legacy partials",
                 answer: "Defer to TP-891 (option: **Defer to TP-891** (recommended): The partials stay; TP-891 removes them.)",
                 scope: "Deferred to TP-891"
               }
             ] = Decisions.answered(node)
    end

    test "keeps a reply that already says what the option does as it is" do
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891: The partials stay; TP-891 removes them.", nil, "c1")])

      assert [%{answer: "Defer to TP-891: The partials stay; TP-891 removes them.", date: ~D[2026-10-13]}] = Decisions.answered(node)
    end

    test "takes the request's date when the reply has none it can read, and today when neither does" do
      assert [%{date: ~D[2026-10-13]}] = Decisions.answered(ticket([comment("c1", request_body()), comment("r1", "Remove them", "not a date", "c1")]))
      assert [%{date: today}] = Decisions.answered(ticket([comment("c1", request_body(), nil), comment("r1", "Remove them", nil, "c1")]))
      assert today == Date.utc_today()
    end

    test "is no decision while unanswered, when withdrawn, or for an ordinary comment" do
      assert Decisions.answered(ticket([comment("c1", request_body())])) == []
      withdrawal = comment("w1", Request.render_withdrawal("Not needed"), nil, "c1")
      assert Decisions.answered(ticket([comment("c1", request_body()), withdrawal])) == []
      assert Decisions.answered(ticket([comment("c1", "Just a note"), comment("r1", "Reply", nil, "c1")])) == []
      assert Decisions.answered(%{"id" => @issue_id}) == []
      assert Decisions.answered(nil) == []
    end
  end

  describe "ruling?/1 and rulings/1" do
    test "a comment opening with Decision: or Ruling: is a ruling, in any case and bold or not" do
      for body <- ["Decision: defer it to TP-891", "ruling: keep it", "  **Decision:** keep it", "**Ruling**: keep it", "DECISION : keep it"],
          do: assert(Decisions.ruling?(body), body)

      for body <- ["Decision:", "Decision:   ", "## Decision needed: Keep it", "The decision: keep it", "Decisions: keep it", nil],
          do: refute(Decisions.ruling?(body), inspect(body))
    end

    test "reads a person's ruling, keyed by its comment, titled by its first sentence and scoped by its text" do
      node = ticket([comment("c1", "Decision: defer the legacy partials to TP-891. They go with the retired states.", "2026-10-13T05:48:00Z")])

      assert [
               %{
                 key: "ruling-c1",
                 date: ~D[2026-10-13],
                 title: "defer the legacy partials to TP-891.",
                 question: "Ruling given in a comment.",
                 answer: "defer the legacy partials to TP-891. They go with the retired states.",
                 scope: "Deferred to TP-891"
               }
             ] = Decisions.rulings(node)
    end

    test "cuts a long first sentence on a word for the title" do
      long = "keep " <> String.duplicate("every legacy partial ", 6) <> "here"
      assert [%{title: title, answer: "keep every" <> _rest}] = Decisions.rulings(ticket([comment("c1", "Ruling: " <> long)]))
      assert String.ends_with?(title, " every legacy…")
      assert String.length(title) <= 81
    end

    test "Symphony's own comments, a supervisor's note and a reply under a decision request are no ruling" do
      node =
        ticket([
          comment("w1", "## Symphony Workpad\n\nDecision: keep the partials"),
          comment("b1", "## Review brief\n\n**Decisions needed:**\n\nNone."),
          comment("s1", "Supervisor note: Decision: keep the partials"),
          comment("c1", request_body()),
          comment("r1", "Decision: Defer to TP-891", nil, "c1"),
          comment("n1", "Just a note"),
          %{"id" => "x1", "body" => nil},
          %{"body" => "Decision: no id"},
          comment("t1", "Ruling: keep it", nil, "n1")
        ])

      assert [%{key: "ruling-t1", answer: "keep it"}] = Decisions.rulings(node)
      assert [%{key: "c1"}] = Decisions.answered(node)
      assert Decisions.rulings(%{"id" => @issue_id}) == []
      assert Decisions.rulings(nil) == []
    end
  end

  describe "sync/2 and record/3" do
    test "writes a person's ruling once, and the same ruling commented again adds nothing" do
      ruling = comment("c1", "Decision: defer the legacy partials to TP-891", "2026-10-14T05:00:00Z")
      node = ticket([comment("w1", "## Symphony Workpad\n\nWorking."), ruling])

      assert :ok = Decisions.sync(node, tracker: FakeTracker)

      assert_received {:description_written, @issue_id, description}
      assert [%{id: "D1", key: "ruling-c1", answer: "defer the legacy partials to TP-891", scope: "Deferred to TP-891"}] = Decisions.recorded(description)

      Process.put({FakeTracker, :description}, {:error, :must_not_read})
      again = comment("c2", "**Decision:** Defer the legacy partials to TP-891 ", "2026-10-14T06:00:00Z")
      stored = linear_stored(description)

      assert :ok = Decisions.sync(%{node | "description" => stored, "comments" => %{"nodes" => [ruling, again]}}, tracker: FakeTracker)
      refute_received {:description_written, _issue_id, _description}

      # Two copies of a new ruling in one read are written once, after an answered request.
      Process.put({FakeTracker, :description}, {:ok, "Fix it."})
      node = ticket([comment("r0", request_body()), comment("a0", "Remove them", nil, "r0"), ruling, again], %{"id" => "issue-2"})

      assert :ok = Decisions.sync(node, tracker: FakeTracker)
      assert_received {:description_written, "issue-2", description}
      assert [%{id: "D1", key: "r0"}, %{id: "D2", key: "ruling-c1"}] = Decisions.recorded(description)
    end

    test "a ruling the section already records as a request's answer adds nothing, an escaped one neither" do
      {:ok, description} = Decisions.put("Fix it.", [entry(%{key: "r0", answer: "Keep the \\_legacy\\_ partials"})])
      Process.put({FakeTracker, :description}, {:ok, description})

      assert :ok = Decisions.record(@issue_id, Decisions.rulings(ticket([comment("c1", "Ruling: keep the _legacy_ partials")])), tracker: FakeTracker)
      refute_received {:description_written, _issue_id, _description}
    end

    test "writes an answered request that the description does not record yet" do
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")])

      assert :ok = Decisions.sync(node, tracker: FakeTracker)

      assert_received {:description_written, @issue_id, description}
      assert [%{id: "D1", key: "c1", scope: "Deferred to TP-891"}] = Decisions.recorded(description)
      assert String.starts_with?(description, "Fix it.\n\n")
    end

    test "costs no Linear call when the node already records every answer" do
      {:ok, description} = Decisions.put("Fix it.", [entry(%{key: "c1"})])
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")], %{"description" => description})

      Process.put({FakeTracker, :description}, {:error, :must_not_read})

      assert :ok = Decisions.sync(node, tracker: FakeTracker)
      assert :ok = Decisions.sync(%{"comments" => %{"nodes" => []}}, tracker: FakeTracker)
      refute_received {:description_written, _issue_id, _description}
    end

    test "rewrites a section that holds an answer twice once, then writes nothing" do
      {:ok, once} = Decisions.put("Fix it.", [entry(%{key: "c1"})])
      twice = once |> linear_stored() |> repeated(2)
      node = ticket([comment("c1", request_body()), comment("r1", "Defer to TP-891", nil, "c1")], %{"description" => twice})
      Process.put({FakeTracker, :description}, {:ok, twice})

      assert :ok = Decisions.sync(node, tracker: FakeTracker)

      assert_received {:description_written, @issue_id, repaired}
      assert [%{id: "D1", key: "c1"}] = Decisions.recorded(repaired)
      assert length(Regex.scan(~r/symphony:decision:c1/, repaired)) == 1

      assert :ok = Decisions.sync(%{node | "description" => repaired}, tracker: FakeTracker)
      refute_received {:description_written, _issue_id, _description}
    end

    test "writes nothing when the description read again already records it" do
      {:ok, description} = Decisions.put("Fix it.", [entry()])
      Process.put({FakeTracker, :description}, {:ok, description})

      assert :ok = Decisions.record(@issue_id, [entry()], tracker: FakeTracker)
      refute_received {:description_written, _issue_id, _description}
    end

    test "reports a failed read, a refused write and a broken section" do
      Process.put({FakeTracker, :description}, {:error, :rate_limited})
      assert capture_log(fn -> assert {:error, :rate_limited} = Decisions.record(@issue_id, [entry()], tracker: FakeTracker) end) =~ "Failed to record decisions on issue_id=#{@issue_id}"

      Process.put({FakeTracker, :description}, {:ok, "Fix it."})
      Process.put({FakeTracker, :update}, {:error, :boom})
      assert capture_log(fn -> assert {:error, :boom} = Decisions.record(@issue_id, [entry()], tracker: FakeTracker) end) =~ ":boom"

      Process.put({FakeTracker, :description}, {:ok, Decisions.start_marker()})
      assert capture_log(fn -> assert {:error, :decisions_block_unterminated} = Decisions.record(@issue_id, [entry()], tracker: FakeTracker) end) =~ "unterminated"
    end

    test "goes through the configured tracker by default" do
      other = %Issue{id: "other", identifier: "TP-2", description: "Other."}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [other, memory_issue()])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      assert :ok = Decisions.record(@issue_id, [entry()], tracker: Memory)
      assert_received {:memory_tracker_description_update, @issue_id, description}
      assert {:ok, ^description} = Memory.fetch_issue_description(@issue_id)
      assert {:ok, "Other."} = Memory.fetch_issue_description("other")
      assert {:error, :issue_not_found} = Memory.fetch_issue_description("missing")
    end
  end

  describe "the poll" do
    test "a polled issue carries the rulings its comments give" do
      issue =
        Client.normalize_issue_for_test(%{
          "id" => @issue_id,
          "identifier" => "TP-1",
          "description" => "Fix it.",
          "comments" => %{
            "nodes" => [
              comment("w1", "## Symphony Workpad\n\nWorking."),
              comment("c1", "Decision: defer the legacy partials to TP-891", "2026-10-14T05:00:00Z")
            ]
          }
        })

      assert [%{key: "ruling-c1", scope: "Deferred to TP-891"}] = issue.rulings
      assert Client.normalize_issue_for_test(%{"id" => @issue_id}).rulings == []
    end

    test "sweep/2 writes the rulings a description does not record yet, and costs nothing otherwise" do
      rulings = Decisions.rulings(ticket([comment("c1", "Decision: defer the legacy partials to TP-891")]))
      {:ok, recorded} = Decisions.put("Fix it.", rulings)

      Process.put({FakeTracker, :description}, {:ok, "Fix it."})

      issues = [
        %Issue{id: @issue_id, description: "Fix it.", rulings: rulings},
        %Issue{id: "recorded", description: recorded, rulings: rulings},
        %Issue{id: "none", description: "Fix it."},
        %Issue{id: nil, rulings: rulings}
      ]

      assert Decisions.sweep(issues, tracker: FakeTracker) == 1
      assert_received {:description_written, @issue_id, description}
      assert [%{id: "D1", key: "ruling-c1"}] = Decisions.recorded(description)
      refute_received {:description_written, _issue_id, _description}

      Process.put({FakeTracker, :update}, {:error, :boom})
      assert capture_log(fn -> assert Decisions.sweep(issues, tracker: FakeTracker) == 0 end) =~ ":boom"
      assert Decisions.sweep(nil) == 0
    end

    test "a poll cycle writes a person's ruling into the ticket's description" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      ruling = comment("c1", "Decision: defer the legacy partials to TP-891", "2026-10-14T05:00:00Z")

      issue = %Issue{
        id: "ruled",
        identifier: "TP-2",
        title: "Remove the legacy partials",
        description: "Remove them.",
        state: "In Progress",
        team: %{key: "Test"},
        rulings: Decisions.rulings(ticket([ruling])),
        # Polled, never dispatched: the test starts no agent.
        assigned_to_worker: false
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      end)

      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :RulingOrchestrator))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      send(pid, :run_poll_cycle)

      assert_receive {:memory_tracker_description_update, "ruled", description}, 2_000
      assert String.starts_with?(description, "Remove them.\n\n")
      assert [%{id: "D1", key: "ruling-c1", answer: "defer the legacy partials to TP-891", scope: "Deferred to TP-891"}] = Decisions.recorded(description)
    end
  end

  describe "the trackers' description calls" do
    test "the memory tracker reports a refused write and leaves a file-backed list alone" do
      Application.put_env(:symphony_elixir, :memory_tracker_update_issue_description_result, [{:error, :boom}])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_description_result) end)

      assert {:error, :boom} = Memory.update_issue_description(@issue_id, "New")
      assert :ok = Memory.update_issue_description(@issue_id, "New")
    end

    test "the Linear adapter reads and writes the description" do
      previous = Application.get_env(:symphony_elixir, :linear_client_module)
      Application.put_env(:symphony_elixir, :linear_client_module, FakeClient)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:symphony_elixir, :linear_client_module, previous),
          else: Application.delete_env(:symphony_elixir, :linear_client_module)
      end)

      Process.put({FakeClient, :read}, {:ok, %{"data" => %{"issue" => %{"description" => "Fix it."}}}})
      assert {:ok, "Fix it."} = Adapter.fetch_issue_description(@issue_id)

      Process.put({FakeClient, :read}, {:ok, %{"data" => %{"issue" => nil}}})
      assert {:error, :issue_not_found} = Adapter.fetch_issue_description(@issue_id)

      Process.put({FakeClient, :read}, {:error, :timeout})
      assert {:error, :timeout} = Adapter.fetch_issue_description(@issue_id)

      Process.put({FakeClient, :update}, {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}})
      assert :ok = Adapter.update_issue_description(@issue_id, "New")
      assert_received {:update_variables, %{issueId: @issue_id, description: "New"}}

      Process.put({FakeClient, :update}, {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}})
      assert {:error, :issue_update_failed} = Adapter.update_issue_description(@issue_id, "New")

      Process.put({FakeClient, :update}, {:error, :timeout})
      assert {:error, :timeout} = Adapter.update_issue_description(@issue_id, "New")
    end

    test "the tracker boundary goes to the configured adapter" do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [memory_issue()])
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert :ok = Tracker.update_issue_description(@issue_id, "New")
      assert {:ok, "New"} = Tracker.fetch_issue_description(@issue_id)
    end
  end
end
