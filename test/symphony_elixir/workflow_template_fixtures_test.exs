defmodule SymphonyElixir.WorkflowTemplateFixturesTest do
  # The macOS app's Add Repo sheet drafts a `WORKFLOW.md` for a repo that has none
  # (`macos/Sources/SymphonyBarCore/WorkflowTemplate.swift`). Its tests keep one draft per
  # stack in these fixtures; each must load as a repo workflow and build its prompt.
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Workflow, WorkflowPreview}

  @fixtures Path.expand("../../macos/Tests/SymphonyBarCoreTests/Fixtures/WorkflowTemplates", __DIR__)

  for name <- ~w(elixir android node unknown) do
    test "the #{name} draft loads and builds its prompt" do
      path = Path.join(@fixtures, "#{unquote(name)}.md")

      assert {:ok, %{prompt_template: template}} = Workflow.parse_repo_workflow(File.read!(path))
      assert template =~ ~s({% render "status_map" %})

      assert {:ok, prompt} = WorkflowPreview.render(file: path)
      assert prompt =~ "You are working on a Linear ticket `ABC-123`"
      refute prompt =~ "{% render"
    end
  end

  test "the Android draft turns on the android_app QA playbook" do
    {:ok, %{config: config}} = Workflow.parse_repo_workflow(File.read!(Path.join(@fixtures, "android.md")))

    assert %{"build" => build, "apk_path" => "app/build/outputs/apk/debug/app-debug.apk", "application_ids" => ["com.acme.notes"]} =
             config["auto_review"]["playbooks"]["android_app"]

    assert build =~ "./gradlew :app:assembleDebug"
  end
end
