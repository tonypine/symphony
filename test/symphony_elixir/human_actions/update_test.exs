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
        why: "Every Release run on main fails at the signing step without them.",
        if_unanswered: "Every Release run on main keeps failing, so no build ships.",
        unblocks: "the Release workflow on main",
        question: "Add the signing secrets, or ship unsigned builds?",
        options: [
          "**Add the secrets** (recommended): you add the signing certificate and its password to the repository's Actions secrets; releases are signed again.",
          "**Ship unsigned**: the agent drops the signing step; Gatekeeper warns on first launch."
        ],
        done_when: "you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request.",
        issue: issue("MOT-24", "Make the Release workflow green"),
        project: @project
      },
      %Action{
        key: "request:comment-2",
        kind: :request,
        title: "Turn on the pre-push hook on your laptop",
        unblocks: "clean pushes from your laptop",
        steps: ["Run `git config core.hooksPath .githooks` in your cycle checkout."],
        done_when: "you reply to the request, or the agent withdraws the request.",
        issue: issue("MOT-31", "Turn on the pre-push hook on your laptop"),
        project: @project
      }
    ]
  end

  test "renders the documented format, by issue" do
    {body, []} = Update.render(example_actions())

    assert body == """
           **2 actions need you.**

           ### 1. Add the release signing secrets

           Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24): the Release workflow on main

           **Why:** Every Release run on main fails at the signing step without them.

           **If unanswered:** Every Release run on main keeps failing, so no build ships.

           **Decide:** Add the signing secrets, or ship unsigned builds?

           1. **Add the secrets** (recommended): you add the signing certificate and its password to the repository's Actions secrets; releases are signed again.
           2. **Ship unsigned**: the agent drops the signing step; Gatekeeper warns on first launch.

           **Done when:** you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request.

           ### 2. Turn on the pre-push hook on your laptop

           Unblocks [MOT-31](https://linear.app/acme/issue/MOT-31): clean pushes from your laptop

           1. Run `git config core.hooksPath .githooks` in your cycle checkout.

           **Done when:** you reply to the request, or the agent withdraws the request.

           ---
           _Symphony posts a new update when this list changes · list `#{Update.list_id(example_actions())}`_\
           """

    assert Update.health(example_actions()) == "atRisk"
  end

  test "renders exactly the example docs/configuration.md shows" do
    docs = File.read!(Path.expand("../../../docs/configuration.md", __DIR__))
    [_before, after_intro] = String.split(docs, "A rendered example, for a mix of", parts: 2)
    [_intro, example | _rest] = String.split(after_intro, ["```md\n", "\n```\n"], parts: 3)

    assert {^example, []} = Update.render(example_actions())
  end

  test "renders a single action and the empty list" do
    [request | _rest] = example_actions()
    {single, []} = Update.render([%{request | unblocks: nil, if_unanswered: nil, why: nil, question: nil, options: [], done_when: nil}])

    assert single =~ "**1 action needs you.**\n\n### 1. Add the release signing secrets\n\nUnblocks [MOT-24](https://linear.app/acme/issue/MOT-24) Make the Release workflow green\n\n---"

    {no_url, []} = Update.render([%{request | issue: %{request.issue | url: nil}}])
    assert no_url =~ "Unblocks MOT-24: the Release workflow"

    {empty, []} = Update.render([])
    assert empty == "**Nothing needs you.** Every action from the last update is closed.\n\n---\n_Symphony posts a new update when this list changes · list `#{Update.list_id([])}`_"
    assert Update.health([]) == "onTrack"
  end

  test "renders a workflow failing on a missing secret, which belongs to no issue" do
    ci_secret = %Action{
      key: "ci_secret:acme/cycle:Release:SIGNING_KEY",
      kind: :ci_secret,
      title: "Add the SIGNING_KEY secret",
      unblocks: "the Release workflow on main in the cycle repository",
      steps: ["Open https://github.com/acme/cycle/settings/secrets/actions."],
      done_when: "the next run of `Release` on `main` is green.",
      issue: nil,
      project: @project
    }

    {body, []} = Update.render(example_actions() ++ [ci_secret])

    assert body =~ """
           ### 1. Add the SIGNING_KEY secret

           Unblocks the Release workflow on main in the cycle repository

           1. Open https://github.com/acme/cycle/settings/secrets/actions.

           **Done when:** the next run of `Release` on `main` is green.

           ### 2. Add the release signing secrets
           """
  end

  test "lists at most 25 actions and points to the held issues for the rest" do
    [request | _rest] = example_actions()
    actions = for index <- 1..27, do: %{request | key: "request:#{index}", title: "Action #{index}"}

    {body, []} = Update.render(actions)

    assert body =~ "**27 actions need you.**"
    assert body =~ "### 25. "
    refute body =~ "### 26. "
    assert body =~ "_…and 2 more: see the issues labelled `Needs Decision`._"
  end

  test "never renders a secret value from any field" do
    [request | _rest] = example_actions()
    secret = "ghp_" <> String.duplicate("a", 36)

    {body, patterns} = Update.render([%{request | why: "Use #{secret}", steps: ["Paste #{secret}"]}])

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

    {body, []} = Update.render(actions)
    assert Update.list_id_from_body(body) == list_id
    assert Update.list_id_from_body("Shipped the wrapper.") == nil
    assert Update.list_id_from_body(nil) == nil
  end

  defp issue(identifier, title) do
    %{id: "id-" <> identifier, identifier: identifier, title: title, url: "https://linear.app/acme/issue/" <> identifier, state: "Backlog"}
  end
end
