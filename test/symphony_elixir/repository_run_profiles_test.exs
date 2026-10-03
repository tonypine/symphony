defmodule SymphonyElixir.RepositoryRunProfilesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{RepoWorkflowSchema, SystemSchema}
  alias SymphonyElixir.RunKind

  # Highest precedence first.
  @layers [:repo_profile, :repo, :agent_profile, :agent]
  @efforts %{repo_profile: "max", repo: "xhigh", agent_profile: "high", agent: "medium"}
  @flip %{"openrouter" => "anthropic", "anthropic" => "openrouter"}

  # `layers` maps a layer to the fields it sets for the `breakdown` run kind; the repository
  # layers apply to `api` only, so `web` resolves from the `agent` section alone.
  defp write_layers!(layers, overrides \\ []) do
    agent = Map.get(layers, :agent, %{})
    repo_profile = Map.get(layers, :repo_profile)
    repo_agent = Map.get(layers, :repo, %{})
    repo_agent = if repo_profile, do: Map.put(repo_agent, "run_profiles", %{"breakdown" => repo_profile}), else: repo_agent

    write_repos!(
      [repo("api", ["api"], if(repo_agent == %{}, do: nil, else: repo_agent)), repo("web", ["web"], nil)],
      Keyword.merge(
        [
          agent_model: agent["model"],
          agent_effort: agent["effort"],
          agent_provider: agent["provider"],
          agent_run_profiles: if(profile = layers[:agent_profile], do: %{"breakdown" => profile})
        ],
        overrides
      )
    )
  end

  defp write_repos!(repos, overrides) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", agent_kind: "claude", agent_command: "claude", repos: repos], overrides)
    )
  end

  defp repo(key, labels, agent) do
    %{
      "name" => key,
      "path" => Path.dirname(Workflow.workflow_file_path()),
      "workflow" => Path.basename(Workflow.workflow_file_path()),
      "team" => "Test",
      "labels" => labels,
      "agent" => agent
    }
  end

  defp breakdown(repo_key), do: repo_key |> Config.settings_for_repo!() |> Config.run_profile(:breakdown)

  defp issue(attrs) do
    struct(%Issue{id: "i-1", identifier: "MT-1", title: "Profile", state: "In Progress", labels: []}, attrs)
  end

  # For each layer: set it and every lower layer, so it has to beat all of them.
  defp value_rows(field, value_for) do
    none = {%{}, nil}

    rows =
      for {layer, index} <- Enum.with_index(@layers) do
        layers = @layers |> Enum.drop(index) |> Map.new(&{&1, %{field => value_for.(&1)}})
        {layers, value_for.(layer)}
      end

    [none | rows]
  end

  defp expected_for_web(layers, field, default) do
    Enum.find_value([:agent_profile, :agent], default, &get_in(layers, [&1, field]))
  end

  describe "precedence for each field" do
    test "model: repository profile, repository, agent profile, agent, then nil" do
      for {layers, expected} <- value_rows("model", &"model-#{&1}") do
        write_layers!(layers)

        assert breakdown("api").model == expected, "layers: #{inspect(layers)}"
        assert breakdown("web").model == expected_for_web(layers, "model", nil)
      end
    end

    test "effort: repository profile, repository, agent profile, agent, then nil" do
      for {layers, expected} <- value_rows("effort", &@efforts[&1]) do
        write_layers!(layers)

        assert breakdown("api").effort == expected, "layers: #{inspect(layers)}"
        assert breakdown("web").effort == expected_for_web(layers, "effort", nil)
      end
    end

    test "provider: repository profile, repository, agent profile, agent, then anthropic" do
      rows =
        for winner <- ["openrouter", "anthropic"], {layer, index} <- Enum.with_index(@layers) do
          lower = @layers |> Enum.drop(index + 1) |> Map.new(&{&1, %{"provider" => @flip[winner]}})
          {Map.put(lower, layer, %{"provider" => winner}), winner}
        end

      for {layers, expected} <- [{%{}, "anthropic"} | rows] do
        # Every run OpenRouter serves needs a model; `agent.model` covers them all.
        write_layers!(Map.update(layers, :agent, %{"model" => "m"}, &Map.put(&1, "model", "m")))

        assert breakdown("api").provider == expected, "layers: #{inspect(layers)}"
        assert breakdown("web").provider == expected_for_web(layers, "provider", "anthropic")
      end
    end
  end

  describe "routed repository" do
    setup do
      write_repos!(
        [
          repo("api", ["api"], %{
            "provider" => "openrouter",
            "model" => "anthropic/claude-sonnet-4.5",
            "run_profiles" => %{"breakdown" => %{"provider" => "anthropic", "model" => "claude-opus-5-5", "effort" => "xhigh"}}
          }),
          repo("web", ["web"], %{"effort" => "low", "run_profiles" => %{"qa" => %{"model" => "claude-haiku-4-5"}}})
        ],
        agent_model: "claude-sonnet-5-5",
        agent_effort: "medium",
        review_agent: %{effort: "max"}
      )
    end

    test "two repositories resolve the same run kind differently" do
      api = Config.settings_for_repo!("api")
      web = Config.settings_for_repo!("web")
      breakdown = issue(%{labels: ["breakdown"]})

      assert AgentRunner.run_profile(breakdown, api) == %{kind: :breakdown, model: "claude-opus-5-5", effort: "xhigh", provider: "anthropic"}
      assert AgentRunner.run_profile(breakdown, web) == %{kind: :breakdown, model: "claude-sonnet-5-5", effort: "low", provider: "anthropic"}

      assert AgentRunner.run_profile(issue(%{state: "Merging"}), api) ==
               %{kind: :landing, model: "anthropic/claude-sonnet-4.5", effort: "medium", provider: "openrouter"}

      assert AgentRunner.run_profile(issue(%{state: "Merging"}), web) ==
               %{kind: :landing, model: "claude-sonnet-5-5", effort: "low", provider: "anthropic"}
    end

    test "the reviewer and QA agent use the routed repository, below their own fields" do
      assert Config.pre_push_review_profile(Config.settings_for_repo!("api")) ==
               %{kind: :pre_push_review, model: "anthropic/claude-sonnet-4.5", effort: "max", provider: "openrouter"}

      assert Config.pre_push_review_profile(Config.settings_for_repo!("web")) ==
               %{kind: :pre_push_review, model: "claude-sonnet-5-5", effort: "max", provider: "anthropic"}

      assert Config.qa_profile(Config.settings_for_repo!("web")) == %{kind: :qa, model: "claude-haiku-4-5", effort: "low", provider: "anthropic"}
    end
  end

  test "repositories without an agent block resolve exactly as before" do
    run_profiles = %{"breakdown" => %{"model" => "claude-opus-5-5", "effort" => "xhigh"}, "landing" => %{"provider" => "openrouter", "model" => "x/y"}}
    write_repos!([repo("api", ["api"], nil)], agent_model: "claude-sonnet-5-5", agent_effort: "medium", agent_run_profiles: run_profiles)
    settings = Config.settings_for_repo!("api")

    assert settings.agent.repository == nil

    for kind <- RunKind.kinds() do
      profile = Map.get(run_profiles, Atom.to_string(kind), %{})

      assert Config.run_profile(settings, kind) == %{
               model: Map.get(profile, "model", "claude-sonnet-5-5"),
               effort: Map.get(profile, "effort", "medium"),
               provider: Map.get(profile, "provider", "anthropic")
             }
    end
  end

  describe "repository-level validation names repositories[<key>].agent" do
    defp symphony(repo_agent, sections \\ %{}) do
      Map.merge(
        %{
          "issues" => %{"provider" => "memory"},
          "agent" => %{"runtime" => "claude", "command" => "claude"},
          "repositories" => [%{"key" => "app", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}, "agent" => repo_agent}]
        },
        sections
      )
    end

    defp error!(repo_agent, sections \\ %{}) do
      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(symphony(repo_agent, sections))
      message
    end

    test "invalid field values" do
      for {repo_agent, expected} <- [
            {%{"effort" => "extreme"}, "repositories[app].agent.effort must be one of: low, medium, high, xhigh, max"},
            {%{"model" => "  "}, "repositories[app].agent.model must not be blank"},
            {%{"model" => 5}, "repositories[app].agent.model is invalid"},
            {%{"provider" => "bedrock"}, "repositories[app].agent.provider must be one of: anthropic, openrouter"},
            {%{"run_profiles" => "fast"}, "repositories[app].agent.run_profiles is invalid"},
            {%{"run_profiles" => %{"bogus" => %{}}}, "repositories[app].agent.run_profiles has unknown run kind `bogus`; expected one of: implementation"},
            {%{"run_profiles" => %{"qa" => "fast"}}, "repositories[app].agent.run_profiles.qa must be an object with model, effort and/or provider"},
            {%{"run_profiles" => %{"qa" => %{"temperature" => 1}}}, "repositories[app].agent.run_profiles.qa has unknown key `temperature`"},
            {%{"run_profiles" => %{"qa" => %{"effort" => "extreme"}}}, "repositories[app].agent.run_profiles.qa.effort must be one of"},
            {%{"run_profiles" => %{"qa" => %{"provider" => "bedrock"}}}, "repositories[app].agent.run_profiles.qa.provider must be one of"},
            {%{"run_profiles" => %{"qa" => %{"model" => 5}}}, "repositories[app].agent.run_profiles.qa.model must be a string"}
          ] do
        assert error!(repo_agent) =~ expected
      end
    end

    test "unknown keys and a non-object block" do
      assert error!(%{"temperature" => 1}) =~ "unknown symphony.yml key `repositories[app].agent.temperature`"
      assert error!("fast") =~ "`repositories[app].agent` must be an object"

      config = symphony(%{"temperature" => 1})
      config = update_in(config, ["repositories"], fn [repo] -> [Map.delete(repo, "key")] end)

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(config)
      assert message =~ "unknown symphony.yml key `repositories[0].agent.temperature`"
    end

    test "openrouter without a resolved model names the repository key that picked it" do
      message = error!(%{"provider" => "openrouter", "run_profiles" => %{"qa" => %{"model" => "openai/gpt-5"}}})

      assert message =~
               "repositories[app].agent.provider openrouter needs an OpenRouter model id; set repositories[app].agent.model, repositories[app].agent.run_profiles.<kind>.model or agent.model (missing for: implementation, breakdown,"

      refute message =~ "qa"

      assert error!(%{"run_profiles" => %{"landing" => %{"provider" => "openrouter"}}}) =~
               "repositories[app].agent.run_profiles.landing.provider openrouter needs an OpenRouter model id; set repositories[app].agent.run_profiles.landing.model, repositories[app].agent.model or agent.model"
    end

    test "openrouter with a non-claude runtime" do
      codex = %{"agent" => %{"runtime" => "codex", "command" => "codex app-server"}}

      assert error!(%{"provider" => "openrouter", "model" => "openai/gpt-5"}, codex) =~
               "repositories[app].agent.provider openrouter is only supported with agent.runtime: claude"

      assert error!(%{"run_profiles" => %{"qa" => %{"provider" => "openrouter", "model" => "openai/gpt-5"}}}, codex) =~
               "repositories[app].agent.run_profiles.qa.provider openrouter is only supported with agent.runtime: claude"
    end

    test "a model from the agent section satisfies openrouter, and the agent section's own openrouter is not repeated" do
      assert {:ok, %SystemSchema{repos: [%{agent: %{provider: "openrouter"}}]}} =
               SystemSchema.parse(symphony(%{"provider" => "openrouter"}, %{"agent" => %{"runtime" => "claude", "command" => "claude", "model" => "m"}}))

      assert {:ok, _system} =
               SystemSchema.parse(symphony(%{"effort" => "low"}, %{"agent" => %{"runtime" => "claude", "command" => "claude", "provider" => "openrouter", "model" => "m"}}))

      assert {:ok, _system} =
               SystemSchema.parse(symphony(%{"provider" => "anthropic"}, %{"agent" => %{"runtime" => "codex", "command" => "codex app-server"}}))
    end

    test "--model / --effort in a command a repository profile reaches" do
      assert error!(%{"model" => "x"}, %{"agent" => %{"runtime" => "claude", "command" => "claude --model y"}}) =~
               "agent.command must not pass --model when repositories[app].agent sets a model, effort or run_profiles; remove it from agent.command"

      assert error!(%{"run_profiles" => %{"pre_push_review" => %{"effort" => "low"}}}, %{"pre_push_review" => %{"command" => "claude --effort high"}}) =~
               "pre_push_review.command must not pass --effort when repositories[app].agent sets"

      assert error!(%{"run_profiles" => %{"qa" => %{"model" => "x"}}}, %{"auto_review" => %{"command" => "claude --model y"}}) =~
               "auto_review.command must not pass --model when repositories[app].agent sets"

      assert {:ok, _system} =
               SystemSchema.parse(
                 symphony(%{"run_profiles" => %{"breakdown" => %{"model" => "x"}}}, %{
                   "pre_push_review" => %{"command" => "claude --model y"},
                   "auto_review" => %{"command" => "claude --model y"}
                 })
               )

      assert {:ok, _system} = SystemSchema.parse(symphony(%{"provider" => "anthropic"}, %{"agent" => %{"runtime" => "claude", "command" => "claude --model y"}}))
    end

    test "errors from several repositories are reported together" do
      config =
        update_in(symphony(%{"effort" => "extreme"}), ["repositories"], fn [repo] ->
          [repo, %{"key" => "web", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Web"}, "agent" => %{"model" => " "}}]
        end)

      assert {:error, {:invalid_symphony_config, message}} = SystemSchema.parse(config)
      assert message =~ "repositories[app].agent.effort must be one of"
      assert message =~ "repositories[web].agent.model must not be blank"
    end
  end

  test "WORKFLOW.md front matter cannot set the agent" do
    assert {:error, {:invalid_repo_workflow_config, message}} = RepoWorkflowSchema.parse(%{"agent" => %{"model" => "x"}})
    assert message =~ "operator-level key `agent`"
  end
end
