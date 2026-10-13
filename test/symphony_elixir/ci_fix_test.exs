defmodule SymphonyElixir.CiFixTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{CiFix, CodeReview, Config, Handoff, RunStore}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @repo_key "default"
  @issue_id "issue-ci-fix"

  defp settings!(attrs) do
    assert {:ok, settings} = Schema.parse(attrs)
    settings
  end

  defp designed_settings(extra \\ %{}) do
    settings!(%{"tracker" => %{"kind" => "memory"}} |> Map.merge(extra))
  end

  defp legacy_settings(extra \\ %{}) do
    settings!(%{"tracker" => Map.merge(%{"kind" => "memory"}, extra)})
  end

  defp issue(state), do: %Issue{id: @issue_id, identifier: "ACME-1", title: "Fix", state: state, labels: []}

  describe "state/1" do
    test "is the configured CI Fix state, defaulting to CI Fix" do
      assert CiFix.state(designed_settings()) == "CI Fix"

      renamed = designed_settings(%{"tracker" => %{"kind" => "memory", "ci_fix_state" => "  Repair  "}})
      assert CiFix.state(renamed) == "Repair"
    end

    test "defaults when the settings carry no tracker or a blank state" do
      assert CiFix.state(nil) == "CI Fix"
      assert CiFix.state(%{}) == "CI Fix"
      assert CiFix.state(%{tracker: %{ci_fix_state: "   "}}) == "CI Fix"
      assert CiFix.state(%{tracker: %{ci_fix_state: 5}}) == "CI Fix"

      blank = designed_settings(%{"tracker" => %{"kind" => "memory", "ci_fix_state" => "   "}})
      assert CiFix.state(blank) == "CI Fix"
    end
  end

  describe "designed?/1" do
    test "follows the repo's machine version" do
      assert CiFix.designed?(designed_settings())
      refute CiFix.designed?(legacy_settings())
    end
  end

  describe "in_state?/2" do
    test "is true only for a designed repo's CI Fix ticket" do
      designed = designed_settings()
      legacy = legacy_settings()

      assert CiFix.in_state?(issue("CI Fix"), designed)
      assert CiFix.in_state?(" ci fix ", designed)
      refute CiFix.in_state?(issue("Code Review"), designed)
      # A legacy repo that happens to name the state the same way has no lane.
      refute CiFix.in_state?(issue("CI Fix"), legacy)
      refute CiFix.in_state?(nil, designed)
      refute CiFix.in_state?("CI Fix", nil)
    end
  end

  describe "entry/2" do
    test "answers the edge that enters the lane from each phase, with the configured origin" do
      settings = designed_settings()

      assert CiFix.entry("Code Review", settings) == {:ok, :ci_fix_enter_code_review, "Code Review"}
      assert CiFix.entry("QA", settings) == {:ok, :ci_fix_enter_qa, "QA"}
      assert CiFix.entry("Merging", settings) == {:ok, :ci_fix_enter_merging, "Merging"}
      assert CiFix.entry("Rework", settings) == {:ok, :ci_fix_enter_rework, "Rework"}
    end

    test "records the phase's configured name, so a renamed phase returns to its own state" do
      settings =
        designed_settings(%{
          "tracker" => %{"kind" => "memory", "code_review_state" => "Review", "qa_state" => "Verification"}
        })

      assert CiFix.entry("Review", settings) == {:ok, :ci_fix_enter_code_review, "Review"}
      assert CiFix.entry("Verification", settings) == {:ok, :ci_fix_enter_qa, "Verification"}
    end

    test "is :none for every state the lane is not entered from, and for every legacy repo" do
      assert CiFix.entry("In Progress", designed_settings()) == :none
      assert CiFix.entry("In Review", designed_settings()) == :none
      assert CiFix.entry(nil, designed_settings()) == :none
      assert CiFix.entry("Code Review", legacy_settings()) == :none
      assert CiFix.entry("Merging", nil) == :none
    end
  end

  describe "record_origin/4 and origin/3" do
    test "round-trips the phase the ticket's stay came from, and clears it with nil" do
      assert :ok = CiFix.record_origin(@repo_key, @issue_id, "QA")
      assert CiFix.origin(@repo_key, @issue_id) == "QA"

      assert :ok = CiFix.record_origin(@repo_key, @issue_id, nil)
      assert CiFix.origin(@repo_key, @issue_id) == nil
    end

    test "origin/3 is nil for a ticket with no record" do
      assert CiFix.origin(@repo_key, "issue-never-seen") == nil
      assert CiFix.origin(@repo_key, nil) == nil
    end

    test "falls back to the configured repo when none is given" do
      assert :ok = CiFix.record_origin(nil, @issue_id, "Merging")
      assert CiFix.origin(nil, @issue_id) == "Merging"
    end
  end

  describe "verdict_for_move/3" do
    test "is substantive for a move from CI Fix to Rework, nil otherwise" do
      designed = designed_settings()

      assert CiFix.verdict_for_move("CI Fix", "Rework", designed) == "substantive"
      assert CiFix.verdict_for_move("CI Fix", "Merging", designed) == nil
      assert CiFix.verdict_for_move("Code Review", "Rework", designed) == nil
      assert CiFix.verdict_for_move("CI Fix", "Rework", legacy_settings()) == nil
      assert CiFix.verdict_for_move("CI Fix", nil, designed) == nil
    end
  end

  describe "hold_verdict/2" do
    test "is cannot_fix for a hold set on a CI Fix ticket, nil otherwise" do
      assert CiFix.hold_verdict("CI Fix", designed_settings()) == "cannot_fix"
      assert CiFix.hold_verdict("QA", designed_settings()) == nil
      assert CiFix.hold_verdict("CI Fix", legacy_settings()) == nil
    end
  end

  describe "verdict_kind/0" do
    test "is the ledger name a fix verdict is recorded under" do
      assert CiFix.verdict_kind() == "fix verdict"
    end
  end

  describe "record_verdict/4" do
    test "appends the outcome and details to the ticket's signals ledger" do
      assert :ok = CiFix.record_verdict(@repo_key, @issue_id, "mechanical", %{to: "Merging", origin: "Merging"})

      assert %{signals: [signal | _]} = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert signal.name == "fix verdict"
      assert signal.details == %{outcome: "mechanical", to: "Merging", origin: "Merging"}
    end

    test "takes no details when none are given" do
      assert :ok = CiFix.record_verdict(@repo_key, @issue_id, "cannot_fix")

      assert %{signals: [signal | _]} = RunStore.get_ticket_state(@repo_key, @issue_id)
      assert signal.details == %{outcome: "cannot_fix"}
    end
  end

  describe "carry_verdict/5" do
    test "re-binds a Code Review approve to the head the mechanical repair left" do
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "old-head", "approve")

      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "Code Review", "new-head", designed_settings())

      assert [%{head_sha: "new-head", outcome: "approve"} | _] = Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end

    test "re-binds a QA pass to the head the mechanical repair left" do
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "qa", "old-head", "pass")

      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "QA", "new-head", designed_settings())

      assert [%{head_sha: "new-head", outcome: "pass"} | _] = Handoff.verdicts(@repo_key, @issue_id, "qa")
    end

    test "carries nothing for an origin that holds no verdict" do
      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "Merging", "new-head", designed_settings())
      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "Rework", "new-head", designed_settings())
      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, nil, "new-head", designed_settings())

      assert Handoff.verdicts(@repo_key, @issue_id, "code_review") == []
      assert Handoff.verdicts(@repo_key, @issue_id, "qa") == []
    end

    test "carries nothing when the newest verdict is not a carrying one" do
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "old-head", "approve")
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "old-head", "request_changes")

      assert :ok = CiFix.carry_verdict(@repo_key, @issue_id, "Code Review", "new-head", designed_settings())

      assert [%{head_sha: "old-head", outcome: "request_changes"} | _] = Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end

    test "falls back to the configured repo when none is given" do
      assert Config.repo_key_or_nil() == @repo_key
      assert :ok = CiFix.carry_verdict(nil, @issue_id, "Merging", "new-head", designed_settings())
    end
  end

  describe "CodeReview.carry_verdict/3" do
    test "re-records the newest approve against the new head" do
      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "old-head", "approve")

      assert :ok = CodeReview.carry_verdict(@repo_key, @issue_id, "new-head")

      assert [%{head_sha: "new-head", outcome: "approve"} | _] = Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end

    test "is a no-op with no verdict, a non-approve newest verdict, or no head" do
      assert :ok = CodeReview.carry_verdict(@repo_key, @issue_id, "new-head")

      assert :ok = RunStore.record_ticket_verdict(@repo_key, @issue_id, "code_review", "old-head", "request_changes")
      assert :ok = CodeReview.carry_verdict(@repo_key, @issue_id, "new-head")

      assert [%{head_sha: "old-head", outcome: "request_changes"} | _] = Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert :ok = RunStore.record_ticket_verdict(@repo_key, "issue-no-head", "code_review", "old-head", "approve")
      assert :ok = CodeReview.carry_verdict(@repo_key, "issue-no-head", nil)
    end
  end
end
