defmodule SymphonyElixir.WalkthroughTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Decisions, IssueSummary, RunStore, TicketEvents, Walkthrough}

  @description """
  ## Goal

  Plain steps. Proved by: nothing here, this is the goal.

  ## User walkthrough

  Nothing changes on screen.

  1. Write a ticket. Expected: it is saved.
  2. Push the branch.
     Expected: the steps end with their proofs.
     Proved by: `ci` › test/old_test.exs

  3. Look at the menu. Expected: it looks finished. Proved by: QA
  4. Reach QA. Expected: QA links the tests.

  ## After release

  1. Check it on your own machine.
  """

  @proofs [%{step: 1, test: "test/a_test.exs"}]

  describe "section/1" do
    test "returns the walkthrough's body up to the next heading" do
      description = """
      ## Why

      Because.

      ## User walkthrough

      Nothing changes on screen.

      1. Do a thing → see it.

      ## After release

      1. Check it on your own machine.
      """

      assert Walkthrough.section(description) == "Nothing changes on screen.\n\n1. Do a thing → see it."
    end

    test "is nil without a walkthrough, or with an empty one" do
      assert Walkthrough.section("## Acceptance criteria\n\n- works") == nil
      assert Walkthrough.section("## User walkthrough\n\n## After release\n") == nil
      assert Walkthrough.section(nil) == nil
    end

    test "leaves the projected Proved by: block out" do
      description = Walkthrough.put_proofs(@description, [%{step: 1, test: "test/a_test.exs"}])

      assert description =~ Walkthrough.proofs_start_marker()
      assert Walkthrough.section(description) == Walkthrough.section(@description)
    end

    test "stops at a Symphony marker, so a block that follows is no part of the last step" do
      summary = summarized("## User walkthrough\n\n1. Do it.")
      decisions = "## User walkthrough\n\n1. Do it.\n\n#{Decisions.start_marker()}\n### Decisions\n\n#{Decisions.end_marker()}\n"

      assert Walkthrough.section(summary) == "1. Do it."
      assert Walkthrough.section(decisions) == "1. Do it."
      assert [%{text: "Do it."}] = summary |> Walkthrough.section() |> Walkthrough.steps()
      assert Walkthrough.section(summarized("## User walkthrough\n")) == nil
    end
  end

  describe "steps/1" do
    test "reads each numbered step as its author wrote it, every one QA's, whatever its Proved by: line says" do
      assert [first, second, third, fourth] = @description |> Walkthrough.section() |> Walkthrough.steps()

      assert first == %{number: 1, text: "Write a ticket. Expected: it is saved.", proof: %{by: :qa}}
      assert second.text == "Push the branch.\n   Expected: the steps end with their proofs.\n   Proved by: `ci` › test/old_test.exs"
      assert third.text == "Look at the menu. Expected: it looks finished. Proved by: QA"
      assert %{number: 4, proof: %{by: :qa}} = fourth
      refute Enum.any?([first, second, third, fourth], &Walkthrough.named_test?/1)
      assert Walkthrough.proof_line(second) == "Proved by: QA"
    end

    test "has no step before the first number, and none in nil" do
      assert Walkthrough.steps("Nothing changes on screen.") == []
      assert Walkthrough.steps(nil) == []
    end
  end

  describe "check_proofs/2" do
    test "returns the proofs, trimmed, without writing the description" do
      assert {:ok, [%{step: 1, test: "test/a_test.exs"}, %{step: 2, test: ~s(scenario "pushes the branch")}]} =
               Walkthrough.check_proofs(@description, [
                 %{"step" => 1, "test" => " test/a_test.exs "},
                 %{"step" => 2, "test" => ~s(scenario "pushes the branch")}
               ])
    end

    test "a step that quotes a proof line in its prose takes a proof" do
      description = "## User walkthrough\n\n1. Steps end with `Proved by: QA` and the third is unchanged.\n"
      assert {:ok, [%{step: 1}]} = Walkthrough.check_proofs(description, [%{"step" => 1, "test" => "test/x_test.exs"}])
    end

    test "refuses a check name, a QA proof, a step the walkthrough lacks and an author's Proved by: QA" do
      for {proofs, message} <- [
            {[%{"step" => 1, "test" => "make-all › test/x_test.exs"}], "name the test only, never a check"},
            {[%{"step" => 1, "test" => "ci > test/x_test.exs"}], "name the test only, never a check"},
            {[%{"step" => 1, "test" => "QA"}], "`QA` is not a test"},
            {[%{"step" => 1, "test" => "`test/x_test.exs`"}], "one non-blank line without backticks"},
            {[%{"step" => 1, "test" => " "}], "one non-blank line without backticks"},
            {[%{"step" => 1, "test" => "a\nb"}], "one non-blank line without backticks"},
            {[%{"step" => 0, "test" => "test/x_test.exs"}], "positive integer `step`"},
            {[%{"step" => "1", "test" => "test/x_test.exs"}], "positive integer `step`"},
            {[], "non-empty list"},
            {nil, "non-empty list"},
            {[%{"step" => 9, "test" => "test/x_test.exs"}], "the walkthrough has no step 9"},
            {[%{"step" => 1, "test" => "test/x_test.exs"}, %{"step" => 3, "test" => "test/y_test.exs"}], "step 3 ends with `Proved by: QA`"}
          ] do
        assert {:error, {:invalid_walkthrough_proof, error}} = Walkthrough.check_proofs(@description, proofs)
        assert error =~ message
      end
    end

    test "a lone backtick quotes nothing, so the author's Proved by: QA after it stands" do
      description = "## User walkthrough\n\n1. Type a ` in the box. Proved by: QA\n"

      assert {:error, {:invalid_walkthrough_proof, "step 1 ends with `Proved by: QA`" <> _rest}} =
               Walkthrough.check_proofs(description, [%{"step" => 1, "test" => "test/x_test.exs"}])
    end

    test "an empty Proved by: is no request for QA" do
      assert {:ok, [%{step: 1}]} = Walkthrough.check_proofs("## User walkthrough\n\n1. Undo. Proved by:\n", [%{"step" => 1, "test" => "test/x_test.exs"}])
    end

    test "refuses a description without a walkthrough" do
      for description <- ["## Goal\n\n1. Not a walkthrough.", nil, "## User walkthrough"] do
        assert {:error, {:invalid_walkthrough_proof, "the description has no `## User walkthrough` section"}} =
                 Walkthrough.check_proofs(description, [%{"step" => 1, "test" => "test/x_test.exs"}])
      end
    end
  end

  describe "recorded_proofs/1 and proofs_of/1" do
    test "reads the proofs of the ticket's evidence events, oldest first, and nothing else" do
      :ok = RunStore.clear()
      issue_id = "issue-walkthrough-#{System.unique_integer([:positive])}"

      for payload <- [
            %{caption: "step 2", proof: %{step: 2, test: "test/b_test.exs"}},
            %{caption: "a screenshot"},
            %{caption: "step 1", proof: %{step: 1, test: "test/c_test.exs"}}
          ] do
        {:ok, _event} = TicketEvents.record("repo-a", issue_id, "evidence", payload, actor: {:agent, "run-1", "implementation"})
      end

      assert Walkthrough.recorded_proofs(issue_id) == [%{step: 2, test: "test/b_test.exs"}, %{step: 1, test: "test/c_test.exs"}]
      assert Walkthrough.recorded_proofs(nil) == []
      assert Walkthrough.proofs_of([%{type: "note", payload: %{proof: %{step: 1, test: "x"}}}]) == []
    end
  end

  describe "with_recorded_proofs/3 and proof_steps/2" do
    test "lays the recorded proofs over the steps, the latest a step's, and leaves every step QA's without a proof check" do
      steps = Walkthrough.steps("1. Do it.\n2. Look.")
      recorded = [%{step: 2, test: "test/a_test.exs"}, %{step: 2, test: "test/b_test.exs"}, %{step: 9, test: "test/c_test.exs"}]

      assert [%{proof: %{by: :qa}}, %{proof: %{by: :test, check: "make-all", test: "test/b_test.exs"}} = second] =
               Walkthrough.with_recorded_proofs(steps, recorded, "make-all")

      assert Walkthrough.named_test?(second)
      assert Walkthrough.proof_line(second) == "Proved by: `make-all` › test/b_test.exs"
      assert Walkthrough.with_recorded_proofs(steps, recorded, " ") == steps
    end

    test "the pre-check's steps come from the events alone, by step number" do
      recorded = [%{step: 3, test: "test/a_test.exs"}, %{step: 1, test: "test/b_test.exs"}, %{step: 3, test: "test/c_test.exs"}]

      assert Walkthrough.proof_steps(recorded, "make-all") == [
               %{number: 1, text: "", proof: %{by: :test, check: "make-all", test: "test/b_test.exs"}},
               %{number: 3, text: "", proof: %{by: :test, check: "make-all", test: "test/c_test.exs"}}
             ]

      assert Walkthrough.proof_steps(recorded, nil) == []
      assert Walkthrough.proof_line(%{proof: %{by: :test, check: "make-all", test: nil}}) == "Proved by: `make-all`"
    end
  end

  describe "put_proofs/2" do
    test "renders one Proved by: line per proved step at the walkthrough's end, leaving every other byte" do
      proofs = [%{step: 2, test: "test/a_test.exs"}, %{step: 1, test: "test/b_test.exs"}, %{step: 2, test: "test/c_test.exs"}]
      description = Walkthrough.put_proofs(@description, proofs)

      block =
        Enum.join(
          [
            Walkthrough.proofs_start_marker(),
            "_Symphony shows here the test the implementer recorded for each step it proves; QA walks the others._",
            "",
            "- Step 1 · Proved by: `test/b_test.exs`",
            "- Step 2 · Proved by: `test/c_test.exs`",
            Walkthrough.proofs_end_marker()
          ],
          "\n"
        )

      assert description ==
               String.replace(@description, "4. Reach QA. Expected: QA links the tests.\n\n", "4. Reach QA. Expected: QA links the tests.\n\n" <> block <> "\n\n")
    end

    test "replaces the block where it stands, also after Linear rewrote its markdown, and never shows it twice" do
      once = Walkthrough.put_proofs(@description, [%{step: 1, test: "test/a_test.exs"}])

      # Linear stores `- ` as `* `, escapes the underscores and adds blank lines.
      rewritten =
        once
        |> String.replace("- Step 1", "* Step 1")
        |> String.replace("_Symphony shows", "\\_Symphony shows")
        |> String.replace(Walkthrough.proofs_end_marker(), "\n" <> Walkthrough.proofs_end_marker())

      twice = Walkthrough.put_proofs(rewritten, [%{step: 1, test: "test/b_test.exs"}])

      assert length(String.split(twice, Walkthrough.proofs_start_marker())) == 2
      assert twice =~ "- Step 1 · Proved by: `test/b_test.exs`"
      refute twice =~ "test/a_test.exs"
      assert twice == String.replace(once, "test/a_test.exs", "test/b_test.exs")

      doubled = once <> "\n" <> (once |> String.split(Walkthrough.proofs_start_marker()) |> Enum.at(1) |> then(&(Walkthrough.proofs_start_marker() <> &1)))
      assert doubled |> Walkthrough.put_proofs([%{step: 1, test: "test/b_test.exs"}]) |> String.split(Walkthrough.proofs_start_marker()) |> length() == 2
    end

    test "a test is written as one plain line that cannot close the block" do
      description = Walkthrough.put_proofs("## User walkthrough\n\n1. Do it.", [%{step: 1, test: "a `b`\n --> c"}])

      assert description =~ "- Step 1 · Proved by: `a b c`\n#{Walkthrough.proofs_end_marker()}"
      assert String.ends_with?(description, Walkthrough.proofs_end_marker())
    end

    test "with no proof, or no walkthrough, writes no block and removes one already there" do
      with_block = Walkthrough.put_proofs(@description, [%{step: 1, test: "test/a_test.exs"}])

      assert Walkthrough.put_proofs(with_block, []) == @description
      assert Walkthrough.put_proofs(@description, []) == @description
      assert Walkthrough.put_proofs("## Goal\n\nNo steps.", [%{step: 1, test: "test/a_test.exs"}]) == "## Goal\n\nNo steps."
      assert Walkthrough.put_proofs(nil, []) == ""

      only_block = Walkthrough.put_proofs("## User walkthrough\n\n1. Do it.", [%{step: 1, test: "x"}])
      [_before, block_and_after] = String.split(only_block, Walkthrough.proofs_start_marker())
      assert Walkthrough.put_proofs(Walkthrough.proofs_start_marker() <> block_and_after, []) == ""
      assert Walkthrough.put_proofs("Intro." <> "\n\n" <> Walkthrough.proofs_start_marker() <> block_and_after, []) == "Intro.\n"
    end

    test "a start marker with no end ends at its own line" do
      description = "## User walkthrough\n\n1. Do it.\n\n#{Walkthrough.proofs_start_marker()} stray\n\n## After release\n"

      assert Walkthrough.put_proofs(description, []) == "## User walkthrough\n\n1. Do it.\n\n## After release\n"
    end

    test "stops at the summary block's marker, so writing the summary again keeps the proofs" do
      walkthrough = "## User walkthrough\n\n1. Do it."
      {block, description} = proofs_before_summary(walkthrough)

      assert description == summarized(walkthrough <> "\n\n" <> block)
      assert Walkthrough.put_proofs(description, @proofs) == description
      assert Walkthrough.put_proofs(description, []) == summarized(walkthrough)

      {:ok, summary} = IssueSummary.new(%{"status" => "PR open", "changelog_entry" => "Handed off"})
      {:ok, rewritten} = IssueSummary.put(description, summary, ~D[2026-11-07])

      assert rewritten =~ block
      assert IssueSummary.strip(rewritten) == walkthrough <> "\n\n" <> block
    end

    test "stops at the Decisions section's marker" do
      walkthrough = "## User walkthrough\n\n1. Do it."
      decisions = Enum.join([Decisions.start_marker(), "### Decisions", "", Decisions.end_marker()], "\n")
      description = Walkthrough.put_proofs(walkthrough <> "\n\n" <> decisions <> "\n", @proofs)

      assert description == walkthrough <> "\n\n" <> proofs_block() <> "\n\n" <> decisions <> "\n"
    end

    test "moves a block already inside another Symphony block to the walkthrough's end" do
      walkthrough = "## User walkthrough\n\n1. Do it."
      {_block, healthy} = proofs_before_summary(walkthrough)
      inside = String.replace(summarized(walkthrough), "### Symphony summary", proofs_block() <> "\n\n### Symphony summary")

      assert Walkthrough.put_proofs(inside, @proofs) == healthy
      assert Walkthrough.put_proofs(inside, []) == summarized(walkthrough)

      # Linear may store a marker line as a heading; the block is still inside.
      heading = String.replace(inside, IssueSummary.start_marker(), "## " <> IssueSummary.start_marker())
      refute Walkthrough.put_proofs(heading, @proofs) =~ ~r/---\s+#{Walkthrough.proofs_start_marker()}/
    end

    test "leaves a block after another Symphony block where it stands" do
      description = "#{Decisions.start_marker()}\n#{Decisions.end_marker()}\n\n## User walkthrough\n\n1. Do it.\n\n" <> proofs_block() <> "\n\nTail.\n"

      assert Walkthrough.put_proofs(description, @proofs) == description
    end
  end

  defp summarized(description) do
    {:ok, summary} = IssueSummary.new(%{"status" => "PR open", "changelog_entry" => "Opened the PR"})
    {:ok, summarized} = IssueSummary.put(description, summary, ~D[2026-11-06])
    summarized
  end

  defp proofs_before_summary(walkthrough), do: {proofs_block(), Walkthrough.put_proofs(summarized(walkthrough), @proofs)}

  defp proofs_block do
    Enum.join(
      [
        Walkthrough.proofs_start_marker(),
        "_Symphony shows here the test the implementer recorded for each step it proves; QA walks the others._",
        "",
        "- Step 1 · Proved by: `test/a_test.exs`",
        Walkthrough.proofs_end_marker()
      ],
      "\n"
    )
  end
end
