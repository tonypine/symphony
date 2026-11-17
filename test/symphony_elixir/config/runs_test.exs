defmodule SymphonyElixir.Config.RunsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Runs
  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.{Harnesses, RunKind}

  @harnesses %{
    "claude" => %{command: "claude --verbose", small_model: %{"anthropic" => "claude-haiku-4-5", "openrouter" => "deepseek/flash"}},
    "codex" => %{command: "codex app-server", small_model: %{}},
    "opencode" => %{command: nil, small_model: %{}}
  }
  @default %{"harness" => "claude", "provider" => "anthropic", "model" => "claude-opus-5-5", "effort" => "medium"}

  describe "Harnesses" do
    test "lists each harness with the providers it reaches" do
      assert Harnesses.ids() == ["claude", "codex", "opencode"]
      assert Harnesses.all_providers() == ["anthropic", "openrouter", "opencode-go", "openai"]
      assert Harnesses.providers("claude") == ["anthropic", "openrouter", "opencode-go"]
      assert Harnesses.providers("codex") == ["openai", "opencode-go"]
      assert Harnesses.providers("opencode") == ["opencode-go"]
      assert Harnesses.providers("cursor") == []
    end

    test "answers whether a harness reaches a provider and calls a small model" do
      assert Harnesses.supports?("codex", "openai")
      refute Harnesses.supports?("codex", "anthropic")
      refute Harnesses.supports?("cursor", "anthropic")

      assert Harnesses.small_model?("claude")
      assert Harnesses.small_model?("opencode")
      refute Harnesses.small_model?("codex")
      refute Harnesses.small_model?("cursor")
    end
  end

  describe "parse/2" do
    test "an unset block is empty" do
      assert Runs.parse(nil, "runs") == {:ok, %{}}
    end

    test "keeps each entry's fields, trimmed, with atom or string keys" do
      raw = %{:default => %{harness: "claude", model: " opus "}, "qa" => %{"effort" => "high", "command" => "claude --qa"}}

      assert Runs.parse(raw, "runs") ==
               {:ok, %{"default" => %{"harness" => "claude", "model" => "opus"}, "qa" => %{"effort" => "high", "command" => "claude --qa"}}}
    end

    test "names every problem by its key" do
      raw = %{
        "zeta" => %{},
        "qa" => "claude",
        "landing" => %{"runtime" => "claude", "harness" => "cursor", "provider" => "bedrock", "effort" => "extreme", "model" => " ", "small_model" => 1},
        "default" => %{"command" => "claude"},
        "rework" => %{"command" => "claude --model opus --effort high"}
      }

      assert {:error, errors} = Runs.parse(raw, "repositories[web].runs")

      assert errors == [
               "repositories[web].runs.default.command is a run kind's own; a harness's command for every run is execution.harnesses.<harness>.command",
               "repositories[web].runs.landing has unknown key `runtime`; expected any of: harness, provider, model, effort, small_model, command, fallbacks",
               "repositories[web].runs.landing.effort must be one of: low, medium, high, xhigh, max",
               "repositories[web].runs.landing.harness must be one of: claude, codex, opencode",
               "repositories[web].runs.landing.model must not be blank",
               "repositories[web].runs.landing.provider must be one of: anthropic, openrouter, opencode-go, openai",
               "repositories[web].runs.landing.small_model must be a string",
               "repositories[web].runs.qa must be a map with any of: harness, provider, model, effort, small_model, command",
               "repositories[web].runs.rework.command must not pass --model or --effort; the run's entry sets the model and effort",
               "repositories[web].runs.zeta is not a run kind; expected default or one of: #{Enum.join(RunKind.names(), ", ")}"
             ]
    end

    test "a block that is not a map is refused" do
      assert Runs.parse(["qa"], "runs") == {:error, ["runs must be a map of run kinds"]}
    end

    test "exposes the names the settings surfaces list" do
      assert Runs.default() == "default"
      assert Runs.entry_keys() == ["harness", "provider", "model", "effort", "small_model", "command"]
      assert Runs.efforts() == ["low", "medium", "high", "xhigh", "max"]
    end
  end

  describe "parse_harnesses/1" do
    test "an unset map is empty" do
      assert Runs.parse_harnesses(nil) == {:ok, %{}}
    end

    test "keeps each harness's command and small models" do
      raw = %{claude: %{command: " claude --verbose ", small_model: %{anthropic: " haiku "}}, codex: %{"command" => "codex app-server"}, opencode: %{}}

      assert Runs.parse_harnesses(raw) ==
               {:ok,
                %{
                  "claude" => %{command: "claude --verbose", small_model: %{"anthropic" => "haiku"}},
                  "codex" => %{command: "codex app-server", small_model: %{}},
                  "opencode" => %{command: nil, small_model: %{}}
                }}
    end

    test "names every problem by its key" do
      raw = %{
        "cursor" => %{},
        "codex" => "codex app-server",
        "claude" => %{"model" => "opus", "command" => "claude --model opus", "small_model" => %{"openai" => "gpt", "anthropic" => ""}},
        "opencode" => %{"command" => 1, "small_model" => "glm"}
      }

      assert {:error, errors} = Runs.parse_harnesses(raw)

      assert errors == [
               "execution.harnesses.claude has unknown key `model`; expected any of: command, small_model",
               "execution.harnesses.claude.command must not pass --model; the run's entry sets the model and effort",
               "execution.harnesses.claude.small_model.anthropic must not be blank",
               "execution.harnesses.claude.small_model.openai is not a provider the claude harness reaches; expected one of: anthropic, openrouter, opencode-go",
               "execution.harnesses.codex must be a map with any of: command, small_model",
               "execution.harnesses.cursor is not a harness; expected one of: claude, codex, opencode",
               "execution.harnesses.opencode.command must be a string",
               "execution.harnesses.opencode.small_model must be a map of provider to model"
             ]
    end

    test "a value that is not a map is refused" do
      assert Runs.parse_harnesses("claude") == {:error, ["execution.harnesses must be a map of harnesses"]}
    end
  end

  describe "resolve/4" do
    test "a kind with no entry takes every field from default" do
      assert Runs.resolve(nil, %{"default" => @default}, @harnesses, :implementation) ==
               {:ok,
                %Run{
                  kind: :implementation,
                  harness: "claude",
                  command: "claude --verbose",
                  provider: "anthropic",
                  model: "claude-opus-5-5",
                  effort: "medium",
                  small_model: "claude-haiku-4-5"
                }}
    end

    test "each field resolves on its own: the repository's kind, its default, the kind, then default" do
      runs = %{"default" => @default, "landing" => %{"model" => "sonnet", "effort" => "low", "provider" => "openrouter"}}
      repo = {"repositories[web].runs", %{"default" => %{"effort" => "high"}, "landing" => %{"model" => "haiku"}}}

      assert {:ok, %Run{model: "haiku", effort: "high", provider: "openrouter", harness: "claude", small_model: "deepseek/flash"}} =
               Runs.resolve(repo, runs, @harnesses, "landing")

      assert {:ok, %Run{model: "sonnet", effort: "low"}} = Runs.resolve(nil, runs, @harnesses, "landing")
      assert {:ok, %Run{model: "claude-opus-5-5", effort: "high"}} = Runs.resolve(repo, runs, @harnesses, "rework")
    end

    test "a run kind's own command wins over its harness's, and never comes from another kind" do
      runs = %{"default" => @default, "code_review" => %{"command" => "claude --review"}}
      repo = {"repositories[web].runs", %{"code_review" => %{"command" => "claude --repo-review"}}}

      assert {:ok, %Run{command: "claude --review"}} = Runs.resolve(nil, runs, @harnesses, :code_review)
      assert {:ok, %Run{command: "claude --repo-review"}} = Runs.resolve(repo, runs, @harnesses, :code_review)
      assert {:ok, %Run{command: "claude --verbose"}} = Runs.resolve(repo, runs, @harnesses, :qa)
    end

    test "an entry's small model wins over the harness's, and a harness without one gets none" do
      runs = %{"default" => @default, "qa" => %{"small_model" => "own-haiku"}, "ci_fix" => %{"harness" => "codex", "provider" => "openai"}}

      assert {:ok, %Run{small_model: "own-haiku"}} = Runs.resolve(nil, runs, @harnesses, :qa)
      assert {:ok, %Run{harness: "codex", command: "codex app-server", small_model: nil}} = Runs.resolve(nil, runs, @harnesses, :ci_fix)
    end

    test "a run that resolves no harness, provider or model names its entry" do
      assert Runs.resolve(nil, %{}, @harnesses, :qa) == {:error, ["runs.qa resolves no harness; set `harness` there or in runs.default"]}

      assert Runs.resolve(nil, %{"qa" => %{"harness" => "claude"}}, @harnesses, :qa) ==
               {:error, ["runs.qa resolves no provider; set `provider` there or in runs.default"]}

      repo = {"repositories[web].runs", %{}}

      assert Runs.resolve(repo, %{"default" => %{"harness" => "claude", "provider" => "anthropic"}}, @harnesses, :qa) ==
               {:error, ["repositories[web].runs.qa resolves no model; set `model` there or in runs.default"]}
    end

    test "a provider the harness cannot reach is refused" do
      runs = %{"default" => @default, "qa" => %{"harness" => "codex"}}

      assert Runs.resolve(nil, runs, @harnesses, :qa) ==
               {:error, ["runs.qa runs the codex harness on anthropic, which it cannot reach; codex runs on: openai, opencode-go"]}
    end

    test "a harness with no command, or no small model for the provider, is refused" do
      runs = %{"default" => @default, "qa" => %{"harness" => "opencode", "provider" => "opencode-go"}, "landing" => %{"provider" => "opencode-go"}}

      assert Runs.resolve(nil, runs, @harnesses, :qa) ==
               {:error, ["runs.qa runs the opencode harness, which has no command; set execution.harnesses.opencode.command"]}

      assert Runs.resolve(nil, runs, %{}, :rework) ==
               {:error, ["runs.rework runs the claude harness, which has no command; set execution.harnesses.claude.command"]}

      assert Runs.resolve(nil, runs, @harnesses, :landing) ==
               {:error,
                [
                  "runs.landing runs the claude harness on opencode-go with no small model for its background calls; " <>
                    "set execution.harnesses.claude.small_model.opencode-go"
                ]}
    end
  end

  describe "fallbacks" do
    @openrouter %{"provider" => "openrouter", "model" => "acme/chat"}
    @codex %{"harness" => "codex", "provider" => "openai", "model" => "gpt-5.5", "effort" => "high"}

    test "an entry's own choice comes first, then each fallback in order" do
      runs = %{"default" => Map.put(@default, "fallbacks", [@openrouter, @codex, %{"model" => "claude-sonnet-5-5"}])}

      assert {:ok, [own, openrouter, codex, sonnet]} = Runs.candidates(nil, runs, @harnesses, :landing)

      assert %Run{fallback: nil, harness: "claude", provider: "anthropic", model: "claude-opus-5-5"} = own
      assert %Run{fallback: 0, harness: "claude", provider: "openrouter", model: "acme/chat", effort: "medium", small_model: "deepseek/flash"} = openrouter
      assert %Run{fallback: 1, harness: "codex", command: "codex app-server", provider: "openai", model: "gpt-5.5", effort: "high", small_model: nil} = codex
      assert %Run{fallback: 2, provider: "anthropic", model: "claude-sonnet-5-5", small_model: "claude-haiku-4-5", command: "claude --verbose"} = sonnet

      assert Runs.resolve(nil, runs, @harnesses, :landing) == {:ok, own}
      assert Runs.candidates(nil, %{"default" => @default}, @harnesses, :landing) == {:ok, [own]}
    end

    test "the list is taken whole from the first entry that sets one, and a kind's own command stays with its harness" do
      runs = %{
        "default" => Map.put(@default, "fallbacks", [@openrouter]),
        "code_review" => %{"command" => "claude --review", "small_model" => "own-small", "fallbacks" => [%{"model" => "claude-sonnet-5-5"}, @codex]}
      }

      repo = {"repositories[web].runs", %{"default" => %{"fallbacks" => [@codex]}}}

      assert {:ok, [_own, %Run{model: "claude-sonnet-5-5", command: "claude --review", small_model: "own-small"}, %Run{command: "codex app-server"}]} =
               Runs.candidates(nil, runs, @harnesses, :code_review)

      assert {:ok, [_own, %Run{provider: "openrouter"}]} = Runs.candidates(nil, runs, @harnesses, :qa)
      assert {:ok, [_own, %Run{harness: "codex"}]} = Runs.candidates(repo, runs, @harnesses, :qa)
    end

    test "a fallback that changes the harness or the provider names its own model, and must resolve like any run" do
      runs = fn fallbacks -> %{"default" => Map.put(@default, "fallbacks", fallbacks)} end

      assert Runs.candidates(nil, runs.([%{"provider" => "openrouter"}]), @harnesses, :qa) ==
               {:error, ["runs.qa.fallbacks[0] changes the harness or the provider, so it must set `model`"]}

      assert Runs.candidates(nil, runs.([@openrouter, %{"harness" => "codex", "model" => "gpt-5.5"}]), @harnesses, :qa) ==
               {:error, ["runs.qa.fallbacks[1] runs the codex harness on anthropic, which it cannot reach; codex runs on: openai, opencode-go"]}

      assert Runs.candidates(nil, %{}, @harnesses, :qa) == {:error, ["runs.qa resolves no harness; set `harness` there or in runs.default"]}

      assert Runs.errors(runs.([%{"provider" => "opencode-go", "model" => "kimi-k3"}]), [], @harnesses) |> hd() ==
               "runs.implementation.fallbacks[0] runs the claude harness on opencode-go with no small model for its background calls; " <>
                 "set execution.harnesses.claude.small_model.opencode-go"
    end

    test "a fallbacks list is parsed like an entry, without a command or fallbacks of its own" do
      raw = %{"default" => %{"harness" => "claude", "fallbacks" => [%{provider: "openrouter", model: " acme/chat "}]}}
      assert Runs.parse(raw, "runs") == {:ok, %{"default" => %{"harness" => "claude", "fallbacks" => [@openrouter]}}}

      bad = %{"qa" => %{"fallbacks" => "codex"}, "landing" => %{"fallbacks" => ["codex", %{"command" => "x", "effort" => "extreme", "fallbacks" => []}]}}

      assert Runs.parse(bad, "runs") ==
               {:error,
                [
                  "runs.landing.fallbacks[0] must be a map with any of: harness, provider, model, effort, small_model",
                  "runs.landing.fallbacks[1] has unknown key `command`; expected any of: harness, provider, model, effort, small_model",
                  "runs.landing.fallbacks[1] has unknown key `fallbacks`; expected any of: harness, provider, model, effort, small_model",
                  "runs.landing.fallbacks[1].effort must be one of: low, medium, high, xhigh, max",
                  "runs.qa.fallbacks must be a list of alternatives"
                ]}
    end
  end

  describe "key/4" do
    test "names the entry that sets a field, most specific first" do
      runs = %{"default" => @default, "landing" => %{"model" => "sonnet"}}
      repo = {"repositories[web].runs", %{"default" => %{"effort" => "high"}, "landing" => %{"provider" => "openrouter"}}}

      assert Runs.key(repo, runs, :landing, "provider") == "repositories[web].runs.landing.provider"
      assert Runs.key(repo, runs, :landing, "effort") == "repositories[web].runs.default.effort"
      assert Runs.key(repo, runs, "landing", "model") == "runs.landing.model"
      assert Runs.key(nil, runs, :landing, "harness") == "runs.default.harness"
      assert Runs.key(nil, runs, :landing, "small_model") == nil
    end
  end

  describe "errors/3" do
    test "none when every run kind resolves, for the operator and each repository" do
      assert Runs.errors(%{"default" => @default}, [{"repositories[web].runs", %{"qa" => %{"effort" => "high"}}}], @harnesses) == []
    end

    test "each broken entry once, the operator's and the repository's" do
      runs = %{"default" => @default, "qa" => %{"harness" => "codex"}}
      repos = [{"repositories[web].runs", %{"landing" => %{"provider" => "openai"}}}]

      assert Runs.errors(runs, repos, @harnesses) == [
               "runs.qa runs the codex harness on anthropic, which it cannot reach; codex runs on: openai, opencode-go",
               "repositories[web].runs.landing runs the claude harness on openai, which it cannot reach; claude runs on: anthropic, openrouter, opencode-go",
               "repositories[web].runs.qa runs the codex harness on anthropic, which it cannot reach; codex runs on: openai, opencode-go"
             ]
    end
  end
end
