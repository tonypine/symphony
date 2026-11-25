defmodule SymphonyElixir.QaAgent.StepPrompts do
  @moduledoc """
  Symphony's own prompts for the agent steps of a stepped QA pass (`SymphonyElixir.QaAgent.Steps`),
  one file per playbook kind and step id: `priv/qa_steps/<playbook kind>/<step id>.md`. A QA
  playbook's step list in `symphony.yml` (`phases.qa.playbooks.<kind>.steps`) takes the file of an
  orchestrated step that names no `prompt` of its own, and the playbook's default list
  (`SymphonyElixir.Config.Schema.Phases.default_qa_steps/1`) takes all of them.

  Each prompt carries only the rules of the playbook (`priv/qa_playbooks/<kind>.md`) its step needs;
  the playbook itself stays whole for a pass that is one agent session. The rules that name a screen
  (its fixtures, stand-ins and what each one shows) go to the plan alone, which passes on what
  applies in each step's brief (`screen_rules/1`).

  The `macos_app` prompts are built at compile time by `SymphonyElixir.QaAgent.PromptTerms`: their
  step statuses come from `SymphonyElixir.QaAgent.Steps.statuses/0` and the QA tools they list from
  `SymphonyElixir.QaDriver.tools/0`, and none writes a window size: the QA target and each step's
  setting are stated by the text Symphony adds around them (`SymphonyElixir.QaAgent.prompt_parts/3`
  and `SymphonyElixir.QaAgent.Steps`). A prompt that names a QA tool the driver does not serve, a
  status outside the list or a size by hand does not compile.
  """

  alias SymphonyElixir.QaAgent.PromptTerms

  @source_root Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "qa_steps"]))
  @files Path.wildcard(Path.join([@source_root, "*", "*.md"]))

  for file <- @files do
    @external_resource file
  end

  # The playbook kinds whose prompts are built from the terms' definitions.
  @built_kinds ~w(macos_app)
  @terms PromptTerms.terms()

  @prompts (for file <- @files, into: %{} do
              kind = file |> Path.dirname() |> Path.basename()
              text = File.read!(file)
              name = Path.relative_to(file, Path.dirname(Path.dirname(@source_root)))
              {{kind, Path.basename(file, ".md")}, if(kind in @built_kinds, do: PromptTerms.build!(name, text, @terms), else: text)}
            end)

  # The plan's share of the `macos_app` playbook: from its servers and stand-ins, through every
  # screen's fixtures, up to the numbered procedure the steps split between them; and the release
  # pair.
  @screen_rules_start "Servers the app talks to"
  @screen_rules_end "QA does three things"
  @release_pair_start "After an update: the signed release pair."
  @release_pair_end "\n1. Run `qa_build`."

  @doc "Symphony's prompt for step `id` of playbook `kind`'s list, or nil when it has none."
  @spec prompt(String.t(), String.t()) :: String.t() | nil
  def prompt(kind, id) when is_binary(kind) and is_binary(id), do: Map.get(@prompts, {kind, id})

  @doc "The playbook kinds and step ids Symphony has a prompt for."
  @spec known() :: [{String.t(), String.t()}]
  def known, do: @prompts |> Map.keys() |> Enum.sort()

  @doc """
  The screen rules of the `macos_app` playbook text `playbook` (the servers and stand-ins, the
  fixtures and what each screen shows, and the signed release pair), which only the plan reads.
  A playbook whose text lacks the sections (one a repo replaced) is given whole.
  """
  @spec screen_rules(String.t()) :: String.t()
  def screen_rules(playbook) when is_binary(playbook) do
    screens = between(playbook, @screen_rules_start, @screen_rules_end)

    case {screens, between(playbook, @release_pair_start, @release_pair_end)} do
      {nil, _pair} -> playbook
      {screens, nil} -> screens
      {screens, pair} -> screens <> "\n\n" <> pair
    end
  end

  defp between(text, start, stop) do
    with [_before, rest] <- String.split(text, start, parts: 2),
         [inside, _after] <- String.split(rest, stop, parts: 2) do
      String.trim(start <> inside)
    else
      _missing -> nil
    end
  end
end
