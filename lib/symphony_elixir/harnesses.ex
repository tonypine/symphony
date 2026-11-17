defmodule SymphonyElixir.Harnesses do
  @moduledoc """
  The harnesses a run can start on, and what each one can do.

  A harness is the agent program that runs a session: `claude`, `codex` or `opencode`. A run
  picks one in its `runs:` entry, with the provider that serves its model and the model itself;
  the three are independent choices, bound only by which providers a harness can reach.

  Every fact here is per harness:

    * the providers it reaches (`providers/1`, `supports?/2`);
    * whether it makes background calls to a second, small model (`small_model?/1`). Such a
      harness needs that model named for the run's provider, since a session talks to one
      provider only: `execution.harnesses.<harness>.small_model.<provider>`.

  A new harness is a new entry here and its launcher.
  """

  @type id :: String.t()
  @type provider :: String.t()

  @harnesses [
    {"claude", %{providers: ["anthropic", "openrouter", "opencode-go"], small_model?: true}},
    {"codex", %{providers: ["openai", "opencode-go"], small_model?: false}},
    {"opencode", %{providers: ["opencode-go"], small_model?: true}}
  ]
  @facts Map.new(@harnesses)
  @ids Enum.map(@harnesses, &elem(&1, 0))
  @providers @harnesses |> Enum.flat_map(fn {_id, facts} -> facts.providers end) |> Enum.uniq()

  @doc "Every harness id, in the order messages list them."
  @spec ids() :: [id()]
  def ids, do: @ids

  @doc "Every provider some harness reaches."
  @spec all_providers() :: [provider()]
  def all_providers, do: @providers

  @doc "The providers `harness` reaches; none for an unknown id."
  @spec providers(id()) :: [provider()]
  def providers(harness), do: @facts |> Map.get(harness, %{providers: []}) |> Map.fetch!(:providers)

  @doc "Whether `harness` can run a session served by `provider`."
  @spec supports?(id(), provider()) :: boolean()
  def supports?(harness, provider), do: provider in providers(harness)

  @doc "Whether `harness` makes background calls to a small model of its own."
  @spec small_model?(id()) :: boolean()
  def small_model?(harness), do: @facts |> Map.get(harness, %{small_model?: false}) |> Map.fetch!(:small_model?)
end
