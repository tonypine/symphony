defmodule SymphonyElixir.QaModeContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.QaAndroid.Driver, as: AndroidDriver
  alias SymphonyElixir.{QaDriver, QaModeContract, QaPolicy, Verification, WorkflowPreview}

  @heading "QA mode, what Symphony's driver gives the app:"
  @macos_app %{"build" => "make app", "app" => "build/App.app"}
  @pr %{url: "https://github.com/o/r/pull/1", number: 1, title: "QA", base_ref: "main", head_ref: "qa", intent: "fix", body: ""}

  defp preview!(auto_review) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, prompt: "You are working on `{{ issue.identifier }}`", auto_review: auto_review)
    assert {:ok, prompt} = WorkflowPreview.render(file: path, agent_kind: "claude", repo_key: "default")
    prompt
  end

  defp settings!(playbooks) do
    config = %{
      "tracker" => %{"kind" => "memory"},
      "auto_review" => %{"playbooks" => playbooks},
      "verification" => %{"dev_server" => %{"start_cmd" => "mix phx.server", "health_check_url" => "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/health"}}
    }

    assert {:ok, settings} = Schema.parse(config)
    settings
  end

  test "the preview of a macos_app repo names the QA root, the fixtures copy and the appearance by the driver's names" do
    prompt = preview!(%{playbooks: %{macos_app: @macos_app}})
    contract = QaDriver.app_contract()

    assert prompt =~ @heading
    assert contract.qa_root_env == "SYMPHONY_BAR_QA_ROOT"
    assert contract.api_requests_log == "api-requests.jsonl"
    assert prompt =~ "- `#{contract.qa_root_env}`: the QA root, the launch's run directory on the QA host."
    assert prompt =~ "`qa_api_requests` reads `#{contract.api_requests_log}` from the QA root."
    assert prompt =~ "- `#{contract.api_fixtures_env}`: read-only, set on a launch with `api_fixtures`."
    assert prompt =~ "- `#{contract.appearance_env}`: `light` or `dark` when the launch asks for an appearance."

    assert prompt =~
             "- Write what QA must read into the QA root (`$SYMPHONY_BAR_QA_ROOT`); read what the ticket committed from the fixtures copy (`$SYMPHONY_BAR_QA_API_FIXTURES`)."

    # It sits in the managed context, ahead of the repository's workflow.
    [managed, _workflow] = String.split(prompt, "You are working on `ABC-123`", parts: 2)
    assert managed =~ "- Repo key: `default`."
    assert managed =~ @heading
    refute prompt =~ "dev server runs on the QA host"
  end

  test "a repo without an app playbook gets no QA-mode section" do
    refute preview!(%{playbooks: %{}}) =~ @heading
    refute preview!(%{playbooks: %{macos_app: Map.put(@macos_app, "enabled", false)}}) =~ @heading
  end

  test "a PR run, and a run whose settings cannot be read, get no QA-mode section" do
    settings = settings!(%{"macos_app" => @macos_app})
    issue = %Issue{identifier: "MT-QA", title: "QA mode", state: "In Progress"}
    workflow = %{config: %{}, prompt: "Work on {{ issue.identifier }}", prompt_template: "Work on {{ issue.identifier }}"}

    build = fn opts -> PromptBuilder.build_prompt(issue, [workflow: workflow] ++ opts) end

    assert build.(settings: settings) =~ @heading
    refute build.(settings: settings, prompt_mode: :pr, pr_context: @pr) =~ @heading
    refute build.(settings: %{agent: %{kind: "claude"}}) =~ @heading
    refute build.(agent_kind: "claude", repo_key: "missing-repo") =~ @heading
  end

  test "a dev server playbook names its port and the URL variables the app gets" do
    launch_env = %{"HUB_API_URL" => "http://127.0.0.1:$SYMPHONY_VERIFICATION_PORT"}
    playbook = Map.merge(@macos_app, %{"dev_server" => true, "dev_server_port" => 8123, "launch_env" => launch_env})
    section = settings!(%{"macos_app" => playbook}) |> QaPolicy.enabled_playbooks() |> QaModeContract.section()

    assert section =~
             "- The dev server runs on the QA host on port 8123 (`#{Verification.env_var()}`). " <>
               "The app gets `HUB_API_URL=http://127.0.0.1:8123`."

    bare = QaModeContract.section([%{kind: "macos_app", dev_server: true}])
    assert bare =~ "on port 8090 (`SYMPHONY_VERIFICATION_PORT`). The playbook's `launch_env` names the variables that carry its URL to the app."
  end

  test "an android_app playbook names the folder the driver puts files in" do
    section = QaModeContract.section([%{kind: "cli"}, %{kind: "android_app"}])

    assert section =~ @heading
    assert section =~ "`qa_android_put_file` puts a fixture file in `#{AndroidDriver.downloads_dir()}` on the emulator"
    assert section =~ "`qa_android_dark_mode`"
    refute section =~ "SYMPHONY_BAR_QA_ROOT"
    assert QaModeContract.section([%{kind: "cli"}, %{kind: "web"}]) == nil
  end
end
