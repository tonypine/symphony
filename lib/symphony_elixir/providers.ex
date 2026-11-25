defmodule SymphonyElixir.Providers do
  @moduledoc """
  Every provider some harness reaches (`SymphonyElixir.Harnesses.all_providers/0`) as the state
  the Mac app reads lists it (`/api/v1/state`'s `providers`), so the Providers page, the Runs page
  and the menu bar draw from Symphony's facts and never from a guess.

  Each entry says:

    * `provider` and `name`, its id and its name for a person
      (`SymphonyElixir.AgentProviders.display_name/1`);
    * `in_use`: a kind of run, or one of its fallbacks, names it, in Symphony's own `runs:` or a
      repository's;
    * `paused` and `paused_since`: the Director paused it (`SymphonyElixir.Pauses`, subject
      `{:provider, provider}`), since when;
    * `held` and `held_until`: a usage limit holds new runs on it (`SymphonyElixir.UsageLimit`),
      until the latest of its holds' resume times;
    * `usage_windows`: the windows Symphony read for it (name, `utilization` from 0 to 1,
      `resets_at`), by name: Anthropic's from its runs, OpenCode Go's from its usage API; empty when
      Symphony can read none;
    * `harnesses`: the harnesses that reach it;
    * `kinds` and `fallback_for`: the kinds of run whose own choice is on it, and those one of
      whose fallbacks is, in `SymphonyElixir.RunKind`'s order;
    * `working`: how many runs work on it now;
    * `tokens_today`: the tokens its runs used since the start of the daily budget's day;
    * `reserve`: where new runs on it stop, a share of any of its usage windows
      (`execution.providers.<provider>.reserve`); nil when it has none, and always for a provider
      whose usage Symphony can't read (`usage_readable/0`);
    * `at_reserve`: a window reached the reserve, so a hold keeps new runs off it (a headroom hold,
      `SymphonyElixir.UsageLimit`) until the window resets.

  Providers in use come first, then those not in use, each group in the harnesses' order.

  `list/1` builds the list from facts its caller reads, so it reads nothing itself.
  """

  alias SymphonyElixir.{AgentProviders, Config, Harnesses, RunKind, UsageLimit}
  alias SymphonyElixir.Config.Runs.Run
  alias SymphonyElixir.Config.Schema

  @type entry :: %{
          provider: String.t(),
          name: String.t(),
          in_use: boolean(),
          paused: boolean(),
          paused_since: DateTime.t() | nil,
          held: boolean(),
          held_until: DateTime.t() | nil,
          usage_windows: [%{name: String.t(), utilization: number() | nil, resets_at: DateTime.t() | nil}],
          harnesses: [String.t()],
          kinds: [String.t()],
          fallback_for: [String.t()],
          working: non_neg_integer(),
          tokens_today: non_neg_integer(),
          reserve: float() | nil,
          at_reserve: boolean()
        }

  @typedoc """
  What the list is built from:

    * `runs`: every run a kind may start with, its own choice and its fallbacks
      (`configured_runs/1`);
    * `pauses`: each paused provider's pause record (`%{since: DateTime.t()}`), by provider;
    * `usage_limits`: the usage-limit holds (`provider` and `resume_at`);
    * `usage_windows`: the windows seen, `%{{provider, window} => %{resets_at:, utilization:}}`;
    * `working`: the provider of each run working now;
    * `tokens_today`: the tokens used today, by provider;
    * `reserves`: each provider's reserve, by provider.
  """
  @type facts :: %{
          optional(:runs) => [Run.t() | map()],
          optional(:pauses) => %{optional(String.t()) => map() | nil},
          optional(:usage_limits) => [map()],
          optional(:usage_windows) => map(),
          optional(:working) => [String.t() | nil],
          optional(:tokens_today) => %{optional(String.t()) => non_neg_integer()},
          optional(:reserves) => %{optional(String.t()) => float() | nil}
        }

  # The providers whose usage Symphony reads: Claude Code reports Anthropic's windows from its runs,
  # and OpenCode Go's usage API reports its own (`SymphonyElixir.ProviderUsage`).
  @usage_readable ["anthropic", "opencode-go"]

  @doc "Every provider and its state, in use first (see the module doc)."
  @spec list(facts()) :: [entry()]
  def list(facts) when is_map(facts) do
    runs = Map.get(facts, :runs, [])
    pauses = Map.get(facts, :pauses, %{})
    usage_limits = Map.get(facts, :usage_limits, [])
    windows = Map.get(facts, :usage_windows, %{})
    working = Map.get(facts, :working, [])
    tokens_today = Map.get(facts, :tokens_today, %{})
    reserves = Map.get(facts, :reserves, %{})

    Harnesses.all_providers()
    |> Enum.map(fn provider ->
      kinds = kinds(runs, provider, &is_nil/1)
      fallback_for = kinds(runs, provider, &(not is_nil(&1)))
      pause = Map.get(pauses, provider)
      holds = Enum.filter(usage_limits, &(Map.get(&1, :provider) == provider))

      %{
        provider: provider,
        name: AgentProviders.display_name(provider),
        in_use: kinds != [] or fallback_for != [],
        paused: not is_nil(pause),
        paused_since: pause && Map.get(pause, :since),
        held: holds != [],
        held_until: held_until(holds),
        usage_windows: usage_windows(windows, provider),
        harnesses: Enum.filter(Harnesses.ids(), &Harnesses.supports?(&1, provider)),
        kinds: kinds,
        fallback_for: fallback_for,
        working: Enum.count(working, &(&1 == provider)),
        tokens_today: Map.get(tokens_today, provider, 0),
        reserve: if(provider in @usage_readable, do: Map.get(reserves, provider)),
        at_reserve: Enum.any?(holds, &UsageLimit.headroom?/1)
      }
    end)
    |> Enum.sort_by(&if(&1.in_use, do: 0, else: 1))
  end

  @doc "The providers whose usage Symphony reads, so they take a reserve (`execution.providers`)."
  @spec usage_readable() :: [String.t()]
  def usage_readable, do: @usage_readable

  @doc "Each provider's reserve in `settings`, by provider; a provider with none is left out."
  @spec reserves(Schema.t()) :: %{optional(String.t()) => float()}
  def reserves(%Schema{execution: execution}) do
    for provider <- @usage_readable,
        reserve = Schema.Execution.reserve(execution, provider),
        into: %{},
        do: {provider, reserve}
  end

  @doc """
  Every run a kind may start with across `settings` (Symphony's own and each repository's): each
  kind's own choice and its fallbacks (`SymphonyElixir.Config.runs/2`).
  """
  @spec configured_runs([Schema.t()]) :: [Run.t()]
  def configured_runs(settings) when is_list(settings) do
    for settings <- settings, kind <- RunKind.names(), run <- Config.runs(settings, kind), do: run
  end

  # The kinds of run, in `RunKind`'s order, with a run on `provider` whose `fallback` passes
  # `fallback?`: nil for a kind's own choice.
  defp kinds(runs, provider, fallback?) do
    named =
      for run <- runs, Map.get(run, :provider) == provider, fallback?.(Map.get(run, :fallback)), into: MapSet.new() do
        to_string(Map.get(run, :kind))
      end

    Enum.filter(RunKind.names(), &MapSet.member?(named, &1))
  end

  defp held_until(holds) do
    holds
    |> Enum.map(&Map.get(&1, :resume_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp usage_windows(windows, provider) do
    for {{^provider, name}, seen} <- windows, is_binary(name) do
      %{name: name, utilization: Map.get(seen, :utilization), resets_at: Map.get(seen, :resets_at)}
    end
    |> Enum.sort_by(& &1.name)
  end
end
