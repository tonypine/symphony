---
# Tip: run `symphony workflow preview` to see the fully assembled prompt — managed
# context, expanded `{% render %}` partials, and sample issue values — exactly as the
# agent receives it. This comment lives in front matter so it never renders.
hooks:
  after_create: |
    # Runs .githooks/pre-push on every push. The setting lands in the shared repo config,
    # and the relative path resolves in each worktree.
    git config core.hooksPath .githooks
    # Test deps compile here, outside the sandbox: `lazy_html` downloads its precompiled NIF,
    # and the sandbox's proxy refuses `elixir_make`'s download (no proxy credentials).
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get && MIX_ENV=test mise exec -- mix deps.compile
    fi
  # Closes the branch's open PRs. It runs in the agent's checkout, so it runs nothing from it:
  # no `mix` or `mise`, which would evaluate the agent's `mix.exs`, `deps/`, `_build/` or mise
  # config, and it leaves the checkout before calling `gh`.
  before_remove: |
    cd / || exit 0
    if [ -n "${SYMPHONY_REPO:-}" ] && [ -n "${SYMPHONY_BRANCH:-}" ] && command -v gh >/dev/null 2>&1; then
      gh pr list --repo "$SYMPHONY_REPO" --head "$SYMPHONY_BRANCH" --state open --json number --jq '.[].number' |
        while read -r number; do
          gh pr close "$number" --repo "$SYMPHONY_REPO" \
            --comment "Closing because the Linear issue for branch $SYMPHONY_BRANCH entered a terminal state without merge."
        done
    fi
# `github_push_branch` pushes with repo hooks off, so it refuses a push that changes one of
# `paths` until `command`, run by the agent in its sandbox, records a pass for that commit in
# `result_file`. Symphony only reads the file; it never runs the command.
push_check:
  command: .githooks/pre-push --head
  result_file: tmp/push-check
  paths: ["*.ex", "*.exs", "*.heex", "*.eex", "mix.lock"]
# Used only when the operator sets `verification.enabled: true` in symphony.yml. Serves the
# dashboard with an in-memory tracker; Auto Review's web playbook tests dashboard changes on it.
verification:
  dev_server:
    start_cmd: scripts/qa-dashboard-server.sh
    health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
    health_timeout_ms: 600000
playbook:
  lockfile: mix.lock
prompts:
  pr: |
    You are working on an existing GitHub pull request.

    PR: {{ pr.url }}
    Number: {{ pr.number }}
    Title: {{ pr.title }}
    Base: {{ pr.base_ref }}
    Head: {{ pr.head_ref }}
    Intent: {{ pr.intent }}

    Description:
    <github_pr_body>
    {{ pr.body }}
    </github_pr_body>

    Follow the managed Symphony PR runtime context, complete the requested PR
    intent in this repository, and validate before handoff.
---

{% render "playbook" %}
