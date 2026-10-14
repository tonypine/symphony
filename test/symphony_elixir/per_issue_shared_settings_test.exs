defmodule SymphonyElixir.PerIssueSharedSettingsTest do
  @moduledoc """
  Guards the per-issue decisions that read the shared settings (`Config.settings!/0`) instead of
  the issue's repo settings (`Config.settings_for_repo/1`). They are right only while no
  repository can set its own states, finished states or force label. These tests fail the
  moment one can.

  When one fails, switch each of these reads to the issue's repo settings, falling back to the
  shared settings only when the issue has no repo (TP-880, TP-899 fixed the earlier ones):

  - `DirectorMoves.do_move/4` → `target/3`: Plan Review, the waiting state, the terminal states.
  - `DirectorMoves` restart: the guard ctx's settings.
  - `Orchestrator`: park and close plan parents, breakdown review, plan comments, replan pending,
    finishing (the run kind's phase states), forced issues and their signals (force label,
    terminal states, Plan Review), the sub-issue wait, and the terminal and active state sets.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{RepoWorkflowSchema, SystemSchema}

  # The `repositories[]` sections a repository may set, none of which holds a state, the
  # finished states or the force label. A new one fails the first test: check it doesn't, then add it.
  @repo_sections ~w(acceptance_gate agent base_branch default key manual_review route workflow workflow_source workspace)

  test "no repository key in symphony.yml names a state, the finished states or the force label" do
    sections =
      SystemSchema.operator_key_paths()
      |> Enum.flat_map(fn
        "repositories[]." <> rest -> [rest |> String.split(".") |> hd()]
        _other -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert sections == Enum.sort(@repo_sections)
  end

  test "a repository's WORKFLOW.md can't set the states, the finished states or the force label" do
    for {key, value} <- [
          {"issues", %{"states" => %{"plan_review" => "Plan Check"}}},
          {"tracker", %{"terminal_states" => ["Shipped"]}},
          {"agent", %{"force_label" => "rush"}},
          {"state_machine", "designed"}
        ] do
      assert {:error, {:invalid_repo_workflow_config, message}} = RepoWorkflowSchema.parse(%{key => value})
      assert message =~ "operator-level key `#{key}`"
    end
  end

  test "a repository that sets everything it may still reads the shared states and force label" do
    workflow_path = Workflow.workflow_file_path()
    api_workflow = Path.join(Path.dirname(workflow_path), "API_WORKFLOW.md")

    File.write!(api_workflow, """
    ---
    prompts:
      issue: "API {{ issue.identifier }}"
    validation:
      - mix test
    human_actions:
      enabled: false
    hooks:
      before_run: echo api
    ---
    API prompt
    """)

    capture_log(fn ->
      write_workflow_file!(workflow_path,
        tracker_plan_review_state: "Plan Check",
        tracker_active_states: ["Todo", "Doing"],
        tracker_terminal_states: ["Shipped", "Dropped"],
        force_label: "rush",
        repos: [
          [key: "web", workflow: workflow_path, team: "Test", labels: ["web"], default: true],
          [
            key: "api",
            workflow: api_workflow,
            team: "Test",
            labels: ["api"],
            agent: %{"effort" => "low"},
            acceptance_gate: %{"mode" => "shadow"},
            manual_review: "on"
          ]
        ]
      )
    end)

    shared = Config.settings!()
    api = Config.settings_for_repo!("api")

    # The repository's own settings apply...
    assert api.manual_review == "on"
    assert api.hooks.before_run == "echo api"
    refute api.human_actions.enabled

    # ...and the ones the per-issue decisions read stay the shared ones.
    assert shared.tracker.plan_review_state == "Plan Check"
    assert shared.tracker.terminal_states == ["Shipped", "Dropped"]
    assert shared.agent.force_label == "rush"
    assert api.tracker == shared.tracker
    assert api.agent.force_label == shared.agent.force_label
  end
end
