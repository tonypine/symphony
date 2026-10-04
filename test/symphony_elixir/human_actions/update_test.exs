defmodule SymphonyElixir.HumanActions.UpdateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.HumanActions.{Action, Update}

  @project %{id: "project-1", name: "Cycle"}

  # The mix the documentation shows in `docs/configuration.md` (`human_actions`).
  defp example_actions do
    [
      %Action{
        key: "request:comment-1",
        kind: :request,
        title: "Add the release signing secrets",
        why: "Every Release run on `main` fails at the signing step without them.",
        unblocks: "the Release workflow on `main`",
        est_minutes: 10,
        steps: [
          "Open github.com/acme/cycle → Settings → Secrets and variables → Actions.",
          "Add `MACOS_CERTIFICATE` with the base64 of the Developer ID certificate (.p12).",
          "Add `MACOS_CERTIFICATE_PASSWORD` with its password.",
          "Move MOT-24 to Todo."
        ],
        done_when: "you remove the `human-action` label from MOT-24, or move it on once it is unblocked.",
        issue: issue("MOT-24", "Make the Release workflow green"),
        project: @project
      },
      %Action{
        key: "task:id-MOT-31",
        kind: :task,
        title: "Turn on the pre-push hook on your laptop",
        steps: ["Run `git config core.hooksPath .githooks` in your cycle checkout."],
        done_when: "you close MOT-31, or remove its `human-action` label.",
        issue: issue("MOT-31", "Turn on the pre-push hook on your laptop"),
        project: @project
      },
      %Action{
        key: "plan:id-MOT-40",
        kind: :plan_review,
        title: "Approve the breakdown plan for MOT-40",
        why: "MOT-40 is split into sub-tickets, and none of them starts before you approve the plan.",
        unblocks: "its sub-tickets, waiting in Backlog",
        est_minutes: 10,
        steps: [
          "Read the plan in the `## Symphony Workpad` comment on MOT-40.",
          "To approve, move MOT-40 to `Waiting on sub-tickets`; Symphony moves its sub-tickets to Todo.",
          "To reject it, comment what to change and move MOT-40 to `Rework`."
        ],
        done_when: "MOT-40 leaves In Review.",
        issue: issue("MOT-40", "Offline mode"),
        project: @project
      },
      %Action{
        key: "qa:id-MOT-52",
        kind: :qa_blocked,
        title: "Unblock QA for MOT-52",
        why: "Auto Review could not test the PR: the QA host has no Screen Recording permission for the app.",
        unblocks: "the review of its PR",
        steps: [
          "Fix the cause above, on the machine QA runs on.",
          "Then test the PR yourself and move MOT-52 to `Merging` to approve it, or to `Rework` to send it back."
        ],
        done_when: "MOT-52 leaves In Review, or its next QA report is not blocked.",
        issue: issue("MOT-52", "Widget refresh"),
        project: @project
      }
    ]
  end

  test "renders the documented format, quickest first" do
    {body, []} = Update.render(example_actions(), "human-action")

    assert body == """
           **4 actions need you.** Quickest first.

           ### 1. Add the release signing secrets

           **~10 min** · Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24): the Release workflow on `main`

           **Why:** Every Release run on `main` fails at the signing step without them.

           1. Open github.com/acme/cycle → Settings → Secrets and variables → Actions.
           2. Add `MACOS_CERTIFICATE` with the base64 of the Developer ID certificate (.p12).
           3. Add `MACOS_CERTIFICATE_PASSWORD` with its password.
           4. Move MOT-24 to Todo.

           **Done when:** you remove the `human-action` label from MOT-24, or move it on once it is unblocked.

           ### 2. Approve the breakdown plan for MOT-40

           **~10 min** · Unblocks [MOT-40](https://linear.app/acme/issue/MOT-40): its sub-tickets, waiting in Backlog

           **Why:** MOT-40 is split into sub-tickets, and none of them starts before you approve the plan.

           1. Read the plan in the `## Symphony Workpad` comment on MOT-40.
           2. To approve, move MOT-40 to `Waiting on sub-tickets`; Symphony moves its sub-tickets to Todo.
           3. To reject it, comment what to change and move MOT-40 to `Rework`.

           **Done when:** MOT-40 leaves In Review.

           ### 3. Turn on the pre-push hook on your laptop

           Tracked in [MOT-31](https://linear.app/acme/issue/MOT-31)

           1. Run `git config core.hooksPath .githooks` in your cycle checkout.

           **Done when:** you close MOT-31, or remove its `human-action` label.

           ### 4. Unblock QA for MOT-52

           Unblocks [MOT-52](https://linear.app/acme/issue/MOT-52): the review of its PR

           **Why:** Auto Review could not test the PR: the QA host has no Screen Recording permission for the app.

           1. Fix the cause above, on the machine QA runs on.
           2. Then test the PR yourself and move MOT-52 to `Merging` to approve it, or to `Rework` to send it back.

           **Done when:** MOT-52 leaves In Review, or its next QA report is not blocked.

           ---
           _Symphony posts a new update when this list changes · list `#{Update.list_id(example_actions())}`_\
           """

    assert Update.health(example_actions()) == "atRisk"
  end

  test "renders exactly the example docs/configuration.md shows" do
    docs = File.read!(Path.expand("../../../docs/configuration.md", __DIR__))
    [_before, after_intro] = String.split(docs, "A rendered example, for a mix of", parts: 2)
    [_intro, example | _rest] = String.split(after_intro, ["```md\n", "\n```\n"], parts: 3)

    assert {^example, []} = Update.render(example_actions(), "human-action")
  end

  test "renders a single action and the empty list" do
    [request | _rest] = example_actions()
    {single, []} = Update.render([%{request | unblocks: nil, est_minutes: nil, why: nil, steps: [], done_when: nil}], "human-action")

    assert single =~ "**1 action needs you.**\n\n### 1. Add the release signing secrets\n\nUnblocks [MOT-24](https://linear.app/acme/issue/MOT-24) Make the Release workflow green\n\n---"

    {no_url, []} = Update.render([%{request | issue: %{request.issue | url: nil}}], "human-action")
    assert no_url =~ "Unblocks MOT-24: the Release workflow"

    {empty, []} = Update.render([], "human-action")
    assert empty == "**Nothing needs you.** Every action from the last update is closed.\n\n---\n_Symphony posts a new update when this list changes · list `#{Update.list_id([])}`_"
    assert Update.health([]) == "onTrack"
  end

  test "lists at most 25 actions and points to the label for the rest" do
    [request | _rest] = example_actions()
    actions = for index <- 1..27, do: %{request | key: "request:#{index}", title: "Action #{index}"}

    {body, []} = Update.render(actions, "needs-tony")

    assert body =~ "**27 actions need you.**"
    assert body =~ "### 25. "
    refute body =~ "### 26. "
    assert body =~ "_…and 2 more: see the issues labelled `needs-tony`._"
  end

  test "never renders a secret value from any field" do
    [request | _rest] = example_actions()
    secret = "ghp_" <> String.duplicate("a", 36)

    {body, patterns} = Update.render([%{request | why: "Use #{secret}", steps: ["Paste #{secret}"]}], "human-action")

    refute body =~ secret
    assert body =~ "[REDACTED:github_token]"
    assert :github_token in patterns
  end

  test "identifies a list by its keys, whatever the order, and reads the id back from an update" do
    actions = example_actions()
    list_id = Update.list_id(actions)

    assert list_id =~ ~r/\A[0-9a-f]{8}\z/
    assert Update.list_id(Enum.reverse(actions)) == list_id
    refute Update.list_id(tl(actions)) == list_id

    {body, []} = Update.render(actions, "human-action")
    assert Update.list_id_from_body(body) == list_id
    assert Update.list_id_from_body("Shipped the wrapper.") == nil
    assert Update.list_id_from_body(nil) == nil
  end

  defp issue(identifier, title) do
    %{id: "id-" <> identifier, identifier: identifier, title: title, url: "https://linear.app/acme/issue/" <> identifier, state: "Backlog"}
  end
end
