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
        question: "Add the signing secrets, or ship unsigned builds?",
        options: [
          "**Add the secrets** (recommended): you add `MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PASSWORD` in the repository's Actions secrets; releases are signed again.",
          "**Ship unsigned**: the agent drops the signing step; Gatekeeper warns on first launch."
        ],
        done_when: "you reply with your pick and move MOT-24 out of Human Review, or the agent withdraws the request.",
        issue: issue("MOT-24", "Make the Release workflow green"),
        project: @project
      },
      %Action{
        key: "task:id-MOT-31",
        kind: :task,
        title: "Turn on the pre-push hook on your laptop",
        steps: ["Run `git config core.hooksPath .githooks` in your cycle checkout."],
        done_when: "you close MOT-31, or move it on.",
        issue: issue("MOT-31", "Turn on the pre-push hook on your laptop"),
        project: @project
      },
      %Action{
        key: "plan:id-MOT-40",
        kind: :plan_review,
        title: "Approve the plan for MOT-40",
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
        key: "qa:app_update:id-MOT-52,id-MOT-53",
        kind: :qa_blocked,
        title: "Update the Symphony app",
        why:
          "MOT-52: QA needs `api_fixtures`, which the running app (0.0.1.384) lacks. " <>
            "MOT-53: QA needs `qa_put_file`, which the running app (0.0.1.384) lacks.",
        unblocks: "the QA of [MOT-52](https://linear.app/acme/issue/MOT-52) and [MOT-53](https://linear.app/acme/issue/MOT-53)",
        est_minutes: 5,
        steps: ["Update the Symphony app to its latest release."],
        done_when: "MOT-52 and MOT-53 each leave their review state, or their next QA reports are not blocked.",
        issue: nil,
        project: @project
      }
    ]
  end

  test "renders the documented format, quickest first" do
    {body, []} = Update.render(example_actions(), ["In Review", "Human Review"])

    assert body == """
           **4 actions need you.** Quickest first.

           ### 1. Update the Symphony app

           **~5 min** · Unblocks the QA of [MOT-52](https://linear.app/acme/issue/MOT-52) and [MOT-53](https://linear.app/acme/issue/MOT-53)

           **Why:** MOT-52: QA needs `api_fixtures`, which the running app (0.0.1.384) lacks. MOT-53: QA needs `qa_put_file`, which the running app (0.0.1.384) lacks.

           1. Update the Symphony app to its latest release.

           **Done when:** MOT-52 and MOT-53 each leave their review state, or their next QA reports are not blocked.

           ### 2. Add the release signing secrets

           **~10 min** · Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24): the Release workflow on `main`

           **Why:** Every Release run on `main` fails at the signing step without them.

           **Decide:** Add the signing secrets, or ship unsigned builds?

           1. **Add the secrets** (recommended): you add `MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PASSWORD` in the repository's Actions secrets; releases are signed again.
           2. **Ship unsigned**: the agent drops the signing step; Gatekeeper warns on first launch.

           **Done when:** you reply with your pick and move MOT-24 out of Human Review, or the agent withdraws the request.

           ### 3. Approve the plan for MOT-40

           **~10 min** · Unblocks [MOT-40](https://linear.app/acme/issue/MOT-40): its sub-tickets, waiting in Backlog

           **Why:** MOT-40 is split into sub-tickets, and none of them starts before you approve the plan.

           1. Read the plan in the `## Symphony Workpad` comment on MOT-40.
           2. To approve, move MOT-40 to `Waiting on sub-tickets`; Symphony moves its sub-tickets to Todo.
           3. To reject it, comment what to change and move MOT-40 to `Rework`.

           **Done when:** MOT-40 leaves In Review.

           ### 4. Turn on the pre-push hook on your laptop

           Tracked in [MOT-31](https://linear.app/acme/issue/MOT-31)

           1. Run `git config core.hooksPath .githooks` in your cycle checkout.

           **Done when:** you close MOT-31, or move it on.

           ---
           _Symphony posts a new update when this list changes · list `#{Update.list_id(example_actions())}`_\
           """

    assert Update.health(example_actions()) == "atRisk"
  end

  test "lists actions on Human Review issues first, and says so" do
    review = %Action{
      key: "review:id-MOT-63",
      kind: :human_review,
      title: "Review MOT-63",
      est_minutes: 30,
      steps: ["Move MOT-63 to `Merging` to approve its PR."],
      issue: %{issue("MOT-63", "Final verification: OpenRouter") | state: "Human Review"},
      project: @project,
      human_review: true
    }

    {body, []} = Update.render(example_actions() ++ [review], ["In Review", "Human Review"])

    assert body =~ "**5 actions need you.** Human Review tickets first, then quickest first.\n\n### 1. Review MOT-63\n\n**Human Review** · **~30 min** · Unblocks"
    assert body =~ "### 2. Update the Symphony app"
    assert [%Action{key: "review:id-MOT-63"} | _rest] = Update.sort(example_actions() ++ [review])
  end

  test "renders exactly the example docs/configuration.md shows" do
    docs = File.read!(Path.expand("../../../docs/configuration.md", __DIR__))
    [_before, after_intro] = String.split(docs, "A rendered example, for a mix of", parts: 2)
    [_intro, example | _rest] = String.split(after_intro, ["```md\n", "\n```\n"], parts: 3)

    assert {^example, []} = Update.render(example_actions(), ["In Review", "Human Review"])
  end

  test "renders a single action and the empty list" do
    [request | _rest] = example_actions()
    {single, []} = Update.render([%{request | unblocks: nil, est_minutes: nil, why: nil, question: nil, options: [], done_when: nil}], ["In Review", "Human Review"])

    assert single =~ "**1 action needs you.**\n\n### 1. Add the release signing secrets\n\nUnblocks [MOT-24](https://linear.app/acme/issue/MOT-24) Make the Release workflow green\n\n---"

    {no_url, []} = Update.render([%{request | issue: %{request.issue | url: nil}}], ["In Review", "Human Review"])
    assert no_url =~ "Unblocks MOT-24: the Release workflow"

    {empty, []} = Update.render([], ["In Review", "Human Review"])
    assert empty == "**Nothing needs you.** Every action from the last update is closed.\n\n---\n_Symphony posts a new update when this list changes · list `#{Update.list_id([])}`_"
    assert Update.health([]) == "onTrack"
  end

  test "renders a workflow failing on a missing secret, which belongs to no issue" do
    ci_secret = %Action{
      key: "ci_secret:acme/cycle:Release:SIGNING_KEY",
      kind: :ci_secret,
      title: "Add the `SIGNING_KEY` secret",
      unblocks: "the `Release` workflow on `main` in acme/cycle",
      est_minutes: 5,
      steps: ["Open https://github.com/acme/cycle/settings/secrets/actions."],
      done_when: "the next run of `Release` on `main` is green.",
      issue: nil,
      project: @project
    }

    {body, []} = Update.render(example_actions() ++ [ci_secret], ["In Review", "Human Review"])

    assert body =~ """
           ### 1. Add the `SIGNING_KEY` secret

           **~5 min** · Unblocks the `Release` workflow on `main` in acme/cycle

           1. Open https://github.com/acme/cycle/settings/secrets/actions.

           **Done when:** the next run of `Release` on `main` is green.

           ### 2. Update the Symphony app
           """
  end

  test "lists at most 25 actions and points to the review states for the rest" do
    [request | _rest] = example_actions()
    actions = for index <- 1..27, do: %{request | key: "request:#{index}", title: "Action #{index}"}

    {body, []} = Update.render(actions, ["In Review", "Human Review"])

    assert body =~ "**27 actions need you.**"
    assert body =~ "### 25. "
    refute body =~ "### 26. "
    assert body =~ "_…and 2 more: see the issues in `In Review` and `Human Review`._"
  end

  test "never renders a secret value from any field" do
    [request | _rest] = example_actions()
    secret = "ghp_" <> String.duplicate("a", 36)

    {body, patterns} = Update.render([%{request | why: "Use #{secret}", steps: ["Paste #{secret}"]}], ["In Review", "Human Review"])

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

    {body, []} = Update.render(actions, ["In Review", "Human Review"])
    assert Update.list_id_from_body(body) == list_id
    assert Update.list_id_from_body("Shipped the wrapper.") == nil
    assert Update.list_id_from_body(nil) == nil
  end

  defp issue(identifier, title) do
    %{id: "id-" <> identifier, identifier: identifier, title: title, url: "https://linear.app/acme/issue/" <> identifier, state: "Backlog"}
  end
end
