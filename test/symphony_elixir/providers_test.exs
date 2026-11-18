defmodule SymphonyElixir.ProvidersTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.Providers

  @since ~U[2026-11-18 09:00:00Z]
  @resume ~U[2026-11-18 14:05:00Z]
  @later_resume ~U[2026-11-20 08:00:00Z]
  @five_hour_reset ~U[2026-11-18 14:00:00Z]
  @weekly_reset ~U[2026-11-21 10:00:00Z]

  # Anthropic is paused and held, OpenRouter is a fallback and available, OpenCode Go and OpenAI
  # no run names.
  defp facts do
    %{
      runs: [
        run(:implementation, "anthropic", nil),
        run(:implementation, "openrouter", 0),
        run(:code_review, "anthropic", nil),
        run(:qa, "anthropic", nil),
        run(:qa, "openrouter", 1)
      ],
      pauses: %{"anthropic" => %{since: @since, reasons: []}},
      usage_limits: [
        %{provider: "anthropic", scope: :all, resume_at: @resume},
        %{provider: "anthropic", scope: "opus", resume_at: @later_resume}
      ],
      usage_windows: %{
        {"anthropic", "seven_day"} => %{resets_at: @weekly_reset, utilization: 0.42},
        {"anthropic", "five_hour"} => %{resets_at: @five_hour_reset, utilization: 0.91}
      },
      working: ["anthropic", "openrouter", "anthropic", nil],
      tokens_today: %{"anthropic" => 120_000, "openrouter" => 3_400}
    }
  end

  defp run(kind, provider, fallback), do: %Run{kind: kind, harness: "claude", command: "claude", provider: provider, model: "m", fallback: fallback}

  defp entry(list, provider), do: Enum.find(list, &(&1.provider == provider))

  describe "list/1" do
    test "lists every provider some harness reaches, in use first, each group in the harnesses' order" do
      assert facts() |> Providers.list() |> Enum.map(&{&1.provider, &1.in_use}) ==
               [{"anthropic", true}, {"openrouter", true}, {"opencode-go", false}, {"openai", false}]
    end

    test "a paused provider held by a usage limit, with its windows, harnesses, kinds, runs and tokens" do
      assert %{
               provider: "anthropic",
               name: "Anthropic",
               in_use: true,
               paused: true,
               paused_since: @since,
               held: true,
               held_until: @later_resume,
               usage_windows: [
                 %{name: "five_hour", utilization: 0.91, resets_at: @five_hour_reset},
                 %{name: "seven_day", utilization: 0.42, resets_at: @weekly_reset}
               ],
               harnesses: ["claude"],
               kinds: ["implementation", "code_review", "qa"],
               fallback_for: [],
               working: 2,
               tokens_today: 120_000,
               reserve: nil
             } = entry(Providers.list(facts()), "anthropic")
    end

    test "an available provider a fallback names, with no readable usage" do
      assert %{
               name: "OpenRouter",
               in_use: true,
               paused: false,
               paused_since: nil,
               held: false,
               held_until: nil,
               usage_windows: [],
               harnesses: ["claude"],
               kinds: [],
               fallback_for: ["implementation", "qa"],
               working: 1,
               tokens_today: 3_400,
               reserve: nil
             } = entry(Providers.list(facts()), "openrouter")
    end

    test "a provider no run names is not in use, and two harnesses reach OpenCode Go" do
      list = Providers.list(facts())

      assert %{in_use: false, kinds: [], fallback_for: [], working: 0, tokens_today: 0, harnesses: ["claude", "codex", "opencode"]} =
               entry(list, "opencode-go")

      assert %{name: "OpenAI", in_use: false, harnesses: ["codex"], usage_windows: []} = entry(list, "openai")
    end

    test "a hold whose resume time is unknown still holds, until an unknown time" do
      list = Providers.list(%{usage_limits: [%{provider: "openai", resume_at: nil}]})
      assert %{held: true, held_until: nil} = entry(list, "openai")
    end

    test "with no facts every provider is listed, none in use, paused or held" do
      list = Providers.list(%{})
      assert length(list) == 4
      assert Enum.all?(list, &(not &1.in_use and not &1.paused and not &1.held and &1.usage_windows == [] and &1.tokens_today == 0))
    end
  end

  describe "configured_runs/1" do
    test "gives each kind's own choice, then its fallbacks, for every settings given" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        agent_run_profiles: %{"implementation" => %{"fallbacks" => [%{"provider" => "openrouter", "model" => "openai/gpt-5"}]}}
      )

      settings = Config.settings!()
      runs = Providers.configured_runs([settings, settings])

      assert Enum.count(runs, &(&1.kind == :implementation and &1.provider == "openrouter" and &1.fallback == 0)) == 2

      assert %{in_use: true, fallback_for: ["implementation"]} = entry(Providers.list(%{runs: runs}), "openrouter")
      assert %{in_use: true, kinds: kinds} = entry(Providers.list(%{runs: runs}), "anthropic")
      assert "implementation" in kinds
    end
  end
end
