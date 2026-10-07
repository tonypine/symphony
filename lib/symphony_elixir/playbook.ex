defmodule SymphonyElixir.Playbook do
  @moduledoc """
  Symphony-owned generic orchestration playbook, shipped as Solid partials that a
  repo `WORKFLOW.md` pulls in with `{% render "<name>" %}`.

  A repo can also take the whole playbook at once: a `{% render "playbook" %}` line in
  its `WORKFLOW.md` body expands to `aggregate/0`, merged with the repo's own
  instruction files (see `SymphonyElixir.Playbook.Assembly`), so a partial added
  here reaches that repo without a `WORKFLOW.md` edit.

  Each partial is one `priv/playbook/<name>.liquid` file (the single source of
  truth for that block of prose, so it stops drifting across repos). The bytes are
  embedded at compile time via `@external_resource` so they ride along even in
  escript builds where `priv/` is dropped, mirroring
  `SymphonyElixir.SharedSkills`. `SymphonyElixir.Playbook.FileSystem` serves them
  to Solid from the in-memory map below.
  """

  # Explicit list (sorted), like `SharedSkills`: adding a partial means editing
  # this list, which forces a recompile so the new file is embedded. A compile-time
  # wildcard would not — `@external_resource` only tracks changes to listed files,
  # not newly added ones.
  @partial_names ~w(
    ci_triage
    completion_bar
    continuation_context
    default_posture
    dependency_guardrail
    escape_hatches
    guardrails
    issue_context
    out_of_scope_backlog
    parent_tickets
    pr_feedback_sweep
    reproduce_and_blast_radius
    review_brief
    scoped_tools
    status_map
    ticket_types
    workpad_bootstrap
    workpad_template
  )

  # The partials `{% render "playbook" %}` renders, in canonical order, each on a slot.
  # A repo's numbered instruction files (`NNN-name.md`) sit between them by number, so
  # the slots are spaced to leave room. A new partial takes a free slot; moving an
  # existing one moves the repo text around it.
  @aggregate [
    {"continuation_context", 10},
    {"issue_context", 20},
    {"default_posture", 30},
    {"scoped_tools", 40},
    {"status_map", 50},
    {"ticket_types", 52},
    {"pr_feedback_sweep", 60},
    {"ci_triage", 70},
    {"escape_hatches", 80},
    {"parent_tickets", 90},
    {"review_brief", 95},
    {"completion_bar", 100},
    {"guardrails", 110},
    {"out_of_scope_backlog", 120},
    {"dependency_guardrail", 130},
    {"workpad_template", 140}
  ]

  @source_root Path.expand(Path.join([__DIR__, "..", "..", "priv", "playbook"]))

  for name <- @partial_names do
    @external_resource Path.join(@source_root, name <> ".liquid")
  end

  @partials (for name <- @partial_names, into: %{} do
               {name, File.read!(Path.join(@source_root, name <> ".liquid"))}
             end)

  @names Enum.sort(@partial_names)

  # The variables each partial's `{% comment %}` header lists under `vars:`.
  @vars (for {name, body} <- @partials, into: %{} do
           [_line, vars] = Regex.run(~r/^vars: \[(.*)\]$/m, body)
           {name, String.split(vars, ~r/,\s*/, trim: true)}
         end)

  @doc "Names of the available playbook partials, sorted."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Raw partial bodies keyed by name."
  @spec partials() :: %{String.t() => String.t()}
  def partials, do: @partials

  @doc "The partials `{% render \"playbook\" %}` renders, with their slots, in canonical order."
  @spec aggregate() :: [{String.t(), non_neg_integer()}]
  def aggregate, do: @aggregate

  @doc "The variables a partial takes, from its header's `vars:` line; `[]` for an unknown name."
  @spec vars(String.t()) :: [String.t()]
  def vars(name) when is_binary(name), do: Map.get(@vars, name, [])

  @doc "Fetch a partial body by name."
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@partials, name)
end
