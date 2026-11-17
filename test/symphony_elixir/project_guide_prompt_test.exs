defmodule SymphonyElixir.ProjectGuidePromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectGuidePrompt

  defmodule NoAppendProjectGuides do
  end

  defmodule RaisingProjectGuides do
    def append_to_prompt(_prompt, _workspace, _settings, _runner) do
      raise "guide failure"
    end
  end

  defmodule UndefinedAppendProjectGuides do
    def append_to_prompt(_prompt, _workspace, _settings, _runner) do
      raise %UndefinedFunctionError{module: __MODULE__, function: :append_to_prompt, arity: 4}
    end
  end

  defmodule UndefinedOtherProjectGuides do
    def append_to_prompt(_prompt, _workspace, _settings, _runner) do
      raise %UndefinedFunctionError{module: SymphonyElixir.OtherProjectGuides, function: :missing, arity: 1}
    end
  end

  defmodule ThrowingProjectGuides do
    def append_to_prompt(_prompt, _workspace, _settings, _runner) do
      throw(Application.fetch_env!(:symphony_elixir, :project_guide_prompt_throw_reason))
    end
  end

  test "delegates to the default project guides injector" do
    settings = Config.settings!()
    settings = %{settings | execution: %{settings.execution | include_project_guides: false}}

    assert {:ok, "Prompt"} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :claude)
  end

  test "continues without guides when the guide injector is unavailable" do
    settings = Config.settings!()
    prompt = "Prompt with secret-token-value"

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, ^prompt} =
                 ProjectGuidePrompt.append_to_prompt(
                   prompt,
                   "/tmp/workspace",
                   settings,
                   :codex,
                   SymphonyElixir.MissingProjectGuides
                 )

        assert {:ok, ^prompt} =
                 ProjectGuidePrompt.append_to_prompt(prompt, "/tmp/workspace", settings, :claude, NoAppendProjectGuides)
      end)

    assert log =~ "Project guide injection unavailable"
    assert log =~ "continuing without project guides"
    refute log =~ "secret-token-value"
  end

  test "returns compact errors from unexpected guide injector failures" do
    settings = Config.settings!()

    assert {:error, {:project_guides_failed, RuntimeError}} =
             ProjectGuidePrompt.append_to_prompt(
               "Prompt with secret-token-value",
               "/tmp/workspace",
               settings,
               :codex,
               RaisingProjectGuides
             )
  end

  test "continues without guides when append_to_prompt becomes undefined at call time" do
    settings = Config.settings!()
    prompt = "Prompt with secret-token-value"

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, ^prompt} =
                 ProjectGuidePrompt.append_to_prompt(prompt, "/tmp/workspace", settings, :codex, UndefinedAppendProjectGuides)
      end)

    assert log =~ "reason=undefined_function"
    refute log =~ "secret-token-value"
  end

  test "returns compact errors for unrelated undefined functions" do
    settings = Config.settings!()

    assert {:error, {:project_guides_failed, {:undefined_function, SymphonyElixir.OtherProjectGuides, :missing, 1}}} =
             ProjectGuidePrompt.append_to_prompt(
               "Prompt with secret-token-value",
               "/tmp/workspace",
               settings,
               :codex,
               UndefinedOtherProjectGuides
             )
  end

  test "returns compact errors for thrown guide injector failures" do
    settings = Config.settings!()

    Application.put_env(:symphony_elixir, :project_guide_prompt_throw_reason, :bad_guides)

    assert {:error, {:project_guides_failed, :throw, :bad_guides}} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :codex, ThrowingProjectGuides)

    Application.put_env(:symphony_elixir, :project_guide_prompt_throw_reason, "short reason")

    assert {:error, {:project_guides_failed, :throw, "short reason"}} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :codex, ThrowingProjectGuides)

    Application.put_env(:symphony_elixir, :project_guide_prompt_throw_reason, String.duplicate("x", 300))

    assert {:error, {:project_guides_failed, :throw, truncated}} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :codex, ThrowingProjectGuides)

    assert byte_size(truncated) < 300
    assert truncated =~ "(truncated)"

    Application.put_env(:symphony_elixir, :project_guide_prompt_throw_reason, %RuntimeError{})

    assert {:error, {:project_guides_failed, :throw, RuntimeError}} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :codex, ThrowingProjectGuides)

    Application.put_env(:symphony_elixir, :project_guide_prompt_throw_reason, [1, 2, 3])

    assert {:error, {:project_guides_failed, :throw, "[1, 2, 3]"}} =
             ProjectGuidePrompt.append_to_prompt("Prompt", "/tmp/workspace", settings, :codex, ThrowingProjectGuides)
  after
    Application.delete_env(:symphony_elixir, :project_guide_prompt_throw_reason)
  end
end
