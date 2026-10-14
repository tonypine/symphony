defmodule SymphonyElixir.HumanActions.RequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanActions.Request

  @created_at ~U[2026-10-04 10:00:00Z]

  test "renders a decision with its options and the recommended one, which parses back" do
    request = %{
      title: "Close TP-612 as a\nduplicate of TP-668",
      question: "TP-668 (Company search) already shipped this. Close TP-612 (Search companies by name) as its duplicate?",
      why: "Nothing is left to build.",
      unblocks: "the Companies board",
      options: [
        %{label: "Close as *duplicate*", effect: "TP-612 moves to Done,\nlinked to TP-668.", recommended: true},
        %{label: "Keep it open", effect: "## The next run looks for what TP-668 missed.", recommended: false}
      ]
    }

    body = Request.render_hold(request, "Code Review")

    assert body == """
           ## Decision needed: Close TP-612 as a duplicate of TP-668

           **Question:** TP-668 (Company search) already shipped this. Close TP-612 (Search companies by name) as its duplicate?
           **Why:** Nothing is left to build.
           **Unblocks:** the Companies board

           **Options:**
           1. **Close as duplicate** (recommended): TP-612 moves to Done, linked to TP-668.
           2. **Keep it open**: The next run looks for what TP-668 missed.

           _Reply with the option you pick, or answer it in the Symphony Inbox: the ticket stays in Code Review until the decision is recorded. Symphony lists this in the project update until then._\
           """

    refute body =~ "Steps:"

    assert Request.parse(body, @created_at) == %{
             title: "Close TP-612 as a duplicate of TP-668",
             question: "TP-668 (Company search) already shipped this. Close TP-612 (Search companies by name) as its duplicate?",
             options: [
               "**Close as duplicate** (recommended): TP-612 moves to Done, linked to TP-668.",
               "**Keep it open**: The next run looks for what TP-668 missed."
             ],
             tradeoffs: [[], []],
             why: "Nothing is left to build.",
             if_unanswered: nil,
             recommendation_reason: nil,
             unblocks: "the Companies board",
             steps: [],
             created_at: @created_at
           }
  end

  test "renders what waits if unanswered, each option's trade-offs and why one is recommended, which parse back" do
    request = %{
      title: "Leave the old text to TP-891",
      question: "Should TP-892 (Retire two old review steps) leave the old text to TP-891 (Remove the retired review states)?",
      why: "Code Review sent PR #448 back a second time.\nIts only finding is the old text.",
      if_unanswered: "TP-892 stays in Rework.",
      options: [
        %{
          label: "Leave it to TP-891",
          effect: "You add one line to TP-892's description.",
          recommended: true,
          tradeoffs: [%{kind: "good", text: "TP-892 can merge today."}, %{kind: "cost", text: "The old text stays\nuntil TP-891 lands."}]
        },
        %{label: "Remove it now", effect: "The next run deletes the old text.", tradeoffs: [%{kind: "risk", text: "It clashes with PR #454."}, %{kind: "good", text: " "}]},
        %{label: "Wait for TP-891", effect: "TP-892 waits.", tradeoffs: []}
      ],
      recommendation_reason: "It is one line of text."
    }

    body = Request.render_hold(request, "Rework")

    assert body =~ """
           **Why:** Code Review sent PR #448 back a second time. Its only finding is the old text.
           **If unanswered:** TP-892 stays in Rework.

           **Options:**
           1. **Leave it to TP-891** (recommended): You add one line to TP-892's description.
              - Good: TP-892 can merge today.
              - Cost: The old text stays until TP-891 lands.
           2. **Remove it now**: The next run deletes the old text.
              - Risk: It clashes with PR #454.
           3. **Wait for TP-891**: TP-892 waits.

           **Why recommended:** It is one line of text.

           _Reply with the option you pick\
           """

    refute body =~ "**Time:**"

    assert %{
             if_unanswered: "TP-892 stays in Rework.",
             recommendation_reason: "It is one line of text.",
             options: [
               "**Leave it to TP-891** (recommended): You add one line to TP-892's description.",
               "**Remove it now**: The next run deletes the old text.",
               "**Wait for TP-891**: TP-892 waits."
             ],
             tradeoffs: [
               [%{kind: "good", text: "TP-892 can merge today."}, %{kind: "cost", text: "The old text stays until TP-891 lands."}],
               [%{kind: "risk", text: "It clashes with PR #454."}],
               []
             ]
           } = Request.parse(body)
  end

  test "reads an older comment with a time estimate, and ignores the estimate" do
    body = """
    ## Decision needed: Close TP-612 as a duplicate of TP-668

    **Question:** Close TP-612?
    **Why:** Nothing is left to build.
    **Time:** about 2 min

    **Options:**
    1. **Close as duplicate** (recommended): TP-612 moves to Done.
    2. **Keep it open**: the next run looks again.
    """

    assert %{question: "Close TP-612?", why: "Nothing is left to build.", if_unanswered: nil, tradeoffs: [[], []]} = parsed = Request.parse(body)
    refute Map.has_key?(parsed, :est_minutes)
  end

  test "renders only the fields that are given" do
    options = [%{label: "A", effect: "Ship A."}, %{label: "B", effect: "Ship B.", recommended: true}]
    body = Request.render_hold(%{title: "Decide the pricing", question: "Which price?", why: "The page needs a price.", options: options}, nil)

    refute body =~ "**Unblocks:**"
    refute body =~ "**If unanswered:**"
    refute body =~ "**Why recommended:**"
    assert body =~ "1. **A**: Ship A.\n2. **B** (recommended): Ship B.\n\n_Reply"
    assert body =~ "the ticket stays in its phase until the decision is recorded."
    refute body =~ "label"
    assert %{unblocks: nil, if_unanswered: nil, options: ["**A**: Ship A.", "**B** (recommended): Ship B."]} = Request.parse(body)
  end

  test "names a pull request by its number" do
    assert Request.pull_request("https://github.com/acme/web/pull/448") == "PR #448"
    assert Request.pull_request("https://gitlab.example.com/acme/web/-/merge_requests/3") == nil
    assert Request.pull_request(nil) == nil
  end

  test "parses a hand-written decision without options" do
    assert %{title: "Pick a name", question: nil, options: [], steps: []} = Request.parse("## Decision needed: Pick a name\n\n- not an option")
  end

  test "parses hand-written requests leniently" do
    assert %{title: "Turn on the git hook", why: nil, steps: ["Run `git config core.hooksPath .githooks`", "Push once"]} =
             Request.parse("""
             ## Action needed: Turn on the git hook
             **Why:**
             - Run `git config core.hooksPath .githooks`
             * [ ] Push once
             """)

    assert %{steps: ["Install the build from TestFlight and check the login screen."]} =
             Request.parse("""
             ## Action needed: Check the app on a phone
             **Time:** whenever
             Install the build from TestFlight
             and check the login screen.

             _Remove the label when done._
             """)

    assert %{steps: []} = Request.parse("## Action needed: Onboard Sam")
    assert Request.parse("## Action needed:   ") == nil
    assert Request.parse("Some other comment") == nil
    assert Request.parse(nil) == nil
  end

  test "renders and recognises the reply that withdraws a request" do
    body = Request.render_withdrawal("  The CI run had only just started.\n")

    assert body == "## Action withdrawn\n\nThe CI run had only just started."
    assert Request.withdrawal?(body)
    assert Request.withdrawal?("\n## Action withdrawn")
    refute Request.withdrawal?("The request above is no longer needed.")
    refute Request.withdrawal?(nil)
    assert Request.parse(body) == nil
  end

  test "stays open until the issue leaves a state a person moves it out of" do
    request = %{created_at: @created_at}
    active = ["Todo", "In Progress"]

    # The requesting agent parks the issue: that move comes from an active state.
    parked = [%{at: ~U[2026-10-04 10:05:00Z], from: "In Progress", to: "Backlog"}]
    assert Request.open?(request, parked, active)

    # A person moves it on from Backlog after the request.
    moved_on = parked ++ [%{at: ~U[2026-10-04 12:00:00Z], from: "Backlog", to: "Todo"}]
    refute Request.open?(request, moved_on, active)

    # A move out of Backlog before the request does not close it.
    earlier = [%{at: ~U[2026-10-04 09:00:00Z], from: "Backlog", to: "Todo"}]
    assert Request.open?(request, earlier, active)

    # Entries without a source state (the issue's creation) are ignored; without a creation time
    # any human move closes the request.
    assert Request.open?(request, [%{at: ~U[2026-10-04 12:00:00Z], from: nil, to: "Todo"}], active)
    refute Request.open?(%{created_at: nil}, earlier, active)
  end

  test "normalizes titles and single-line fields" do
    assert Request.headings() == ["## Decision needed:", "## Action needed:"]
    assert Request.normalize_title("  Add the   Release\nSecrets ") == "add the release secrets"
    assert Request.one_line("### Heading\n  text") == "Heading text"
  end
end
