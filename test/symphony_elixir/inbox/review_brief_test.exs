defmodule SymphonyElixir.Inbox.ReviewBriefTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Inbox.ReviewBrief

  @plan_brief """
  ## Review brief

  **What to review:** The plan for the gift card checkout, in 4 sub-tickets.

  - [Domain brief](https://linear.app/acme/document/domain-brief-1)
  - Screens: https://example.com/screens.html
  - SHOP-331 Add the gift card model
    with its migration
  - **SHOP-332** Checkout step

  **What changed since the last brief:**

  - Split SHOP-332 in two, as asked in the comment on the screens.

  **Decisions needed:**

  1. Where are gift cards bought?
     - Options: A. In the checkout; B. On a separate page
     - Recommendation: A, because it keeps one path to pay.
     - Note: the screens show both.
  2. Which currency?
     - Options: Store currency; Buyer's currency (converted)
     - Recommendation: Buyer's currency, so the amount reads right.
  3. How long does a card last?
     - Options: One year; Two years

  **How to approve / change / reject:**

  - Approve: move SHOP-330 to `Waiting on sub-tickets`; Symphony promotes its sub-tickets.
  - Change: comment on any part of the plan.
  - Reject: move SHOP-330 to `Rework`.

  ## Supervisor check

  **Verify:** the importer runs on the device.
  """

  test "parses a plan's brief into what to review with its links, what changed, decisions and moves" do
    assert %{
             format: "parsed",
             headline: "The plan for the gift card checkout, in 4 sub-tickets.",
             what_to_review: [
               %{text: "Domain brief", links: [%{label: "Domain brief", url: "https://linear.app/acme/document/domain-brief-1"}]},
               %{text: "Screens: https://example.com/screens.html", links: [%{label: "https://example.com/screens.html", url: "https://example.com/screens.html"}]},
               %{text: "SHOP-331 Add the gift card model with its migration", links: []},
               %{text: "SHOP-332 Checkout step", links: []}
             ],
             what_changed: ["Split SHOP-332 in two, as asked in the comment on the screens."],
             decisions: [
               %{
                 question: "Where are gift cards bought?",
                 options: ["A. In the checkout", "B. On a separate page"],
                 recommendation: "A, because it keeps one path to pay.",
                 recommended: 0
               },
               %{
                 question: "Which currency?",
                 options: ["Store currency", "Buyer's currency (converted)"],
                 recommendation: "Buyer's currency, so the amount reads right.",
                 recommended: 1
               },
               %{question: "How long does a card last?", options: ["One year", "Two years"], recommendation: nil, recommended: nil}
             ],
             moves: [
               %{move: "approve", text: "move SHOP-330 to Waiting on sub-tickets; Symphony promotes its sub-tickets."},
               %{move: "change", text: "comment on any part of the plan."},
               %{move: "reject", text: "move SHOP-330 to Rework."}
             ],
             supervisor_check: "## Supervisor check\n**Verify:** the importer runs on the device."
           } = ReviewBrief.parse(@plan_brief)
  end

  test "reads `None.` as no decisions and an empty headline as none, and skips a section it doesn't know" do
    brief = """
    ## Review brief

    **What to review:**

    - [PR #12](https://github.com/acme/shop/pull/12)

    **Decisions needed:**

    None.

    **Notes:** anything
    """

    assert %{headline: nil, what_to_review: [%{text: "PR #12"}], what_changed: [], decisions: [], moves: []} =
             ReviewBrief.parse(brief)
  end

  test "keeps a brief without `What to review` as raw markdown" do
    assert ReviewBrief.parse("## Review brief\n\nJust read the PR.\n") == %{format: "raw", markdown: "## Review brief\n\nJust read the PR."}
  end

  test "tells a review brief comment from another" do
    assert ReviewBrief.brief?("  ## Review brief\n")
    refute ReviewBrief.brief?("## Symphony Workpad")
    refute ReviewBrief.brief?(nil)
  end

  test "finds the recommended option by its text, then by its letter, else not at all" do
    assert ReviewBrief.recommended_index(["Keep it", "Close it: moves to Done"], "Close it, since it shipped") == 1
    assert ReviewBrief.recommended_index(["Yes", "No"], "Option B") == 1
    assert ReviewBrief.recommended_index(["Yes", "No"], "C, a third way") == nil
    assert ReviewBrief.recommended_index(["Yes", "No"], "Nothing fits") == nil
    assert ReviewBrief.recommended_index(["Yes"], nil) == nil
    assert ReviewBrief.recommended_index([], "Yes") == nil
    assert ReviewBrief.recommended_index([": no name"], "Keep") == nil
  end
end
