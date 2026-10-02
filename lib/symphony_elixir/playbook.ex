defmodule SymphonyElixir.Playbook do
  @moduledoc """
  Symphony-owned generic orchestration playbook, shipped as Solid partials that a
  repo `WORKFLOW.md` pulls in with `{% render "<name>" %}`.

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
    scoped_tools
    status_map
    workpad_bootstrap
    workpad_template
  )

  @source_root Path.expand(Path.join([__DIR__, "..", "..", "priv", "playbook"]))

  for name <- @partial_names do
    @external_resource Path.join(@source_root, name <> ".liquid")
  end

  @partials (for name <- @partial_names, into: %{} do
               {name, File.read!(Path.join(@source_root, name <> ".liquid"))}
             end)

  @names Enum.sort(@partial_names)

  @doc "Names of the available playbook partials, sorted."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Raw partial bodies keyed by name."
  @spec partials() :: %{String.t() => String.t()}
  def partials, do: @partials

  @doc "Fetch a partial body by name."
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(name) when is_binary(name), do: Map.fetch(@partials, name)
end
