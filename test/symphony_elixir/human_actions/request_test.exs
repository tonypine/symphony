defmodule SymphonyElixir.HumanActions.RequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanActions.Request

  @created_at ~U[2026-10-04 10:00:00Z]

  test "renders a request comment that parses back to the same request" do
    request = %{
      title: "Add the release\nsigning secrets",
      why: "Every Release run on `main` fails without them.",
      unblocks: "the Release workflow on `main`",
      est_minutes: 10,
      steps: ["Open Settings → Secrets.", "## Add `MACOS_CERTIFICATE`\nwith the certificate."]
    }

    body = Request.render(request, "Human Review")

    assert body == """
           ## Action needed: Add the release signing secrets

           **Why:** Every Release run on `main` fails without them.
           **Unblocks:** the Release workflow on `main`
           **Time:** about 10 min

           **Steps:**
           1. Open Settings → Secrets.
           2. Add `MACOS_CERTIFICATE` with the certificate.

           _Symphony lists this in the project update until this issue moves on. Once it is done, move the issue out of Human Review._\
           """

    assert Request.parse(body, @created_at) == %{
             title: "Add the release signing secrets",
             why: "Every Release run on `main` fails without them.",
             unblocks: "the Release workflow on `main`",
             est_minutes: 10,
             steps: ["Open Settings → Secrets.", "Add `MACOS_CERTIFICATE` with the certificate."],
             created_at: @created_at
           }
  end

  test "renders only the fields that are given" do
    body = Request.render(%{title: "Decide the pricing", why: "The page needs a price.", steps: ["Pick one."]}, "In Review")

    refute body =~ "**Unblocks:**"
    refute body =~ "**Time:**"
    assert body =~ "move the issue out of In Review."
    refute body =~ "label"
    assert %{unblocks: nil, est_minutes: nil, steps: ["Pick one."]} = Request.parse(body)
  end

  test "parses hand-written requests leniently" do
    assert %{title: "Turn on the git hook", why: nil, steps: ["Run `git config core.hooksPath .githooks`", "Push once"]} =
             Request.parse("""
             ## Action needed: Turn on the git hook
             **Why:**
             - Run `git config core.hooksPath .githooks`
             * [ ] Push once
             """)

    assert %{steps: ["Install the build from TestFlight and check the login screen."], est_minutes: nil} =
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

  test "reads steps from free text such as a task description" do
    assert Request.text_steps("Context.\n\n1. Create the key\n2) Paste it into 1Password") == ["Create the key", "Paste it into 1Password"]
    assert Request.text_steps("Just do it.") == ["Just do it."]
    assert Request.text_steps(nil) == []
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
    assert Request.heading() == "## Action needed:"
    assert Request.normalize_title("  Add the   Release\nSecrets ") == "add the release secrets"
    assert Request.one_line("### Heading\n  text") == "Heading text"
  end
end
