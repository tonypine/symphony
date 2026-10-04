defmodule SymphonyElixir.Config.RequiredFieldsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  # Config changesets cast with `empty_values: []`, and since Ecto 3.14
  # `validate_required/3` only counts the changeset's empty values as missing.
  # Every required string field must still reject a blank string (TP-404). A
  # field whose inclusion check runs first reports that error instead.
  @blank_required_fields [
    {Schema.Agent, %{}, :kind, "can't be blank"},
    {Schema.Agent, %{}, :command, "can't be blank"},
    {Schema.Agent, %{}, :force_label, "can't be blank"},
    {Schema.Agent.NetworkAccess, %{}, :mode, "can't be blank"},
    {Schema.Agent.SandboxRuntime, %{}, :kind, "can't be blank"},
    {Schema.Agent.SandboxRuntime, %{"kind" => "srt"}, :command, "can't be blank"},
    {Schema.Agent.Mcp, %{}, :inherit, "can't be blank"},
    {Schema.Agent.Mcp.Server, %{}, :name, "can't be blank"},
    {Schema.Agent.Mcp.Server, %{}, :transport, "can't be blank"},
    {Schema.Agent.Mcp.Server, %{"transport" => "stdio"}, :command, "can't be blank"},
    {Schema.Agent.Mcp.Server, %{"transport" => "http"}, :url, "can't be blank"},
    {Schema.PrReview, %{}, :mode, "can't be blank"},
    {Schema.QualityGate, %{"enabled" => true}, :provider, "must be one of: anthropic, openai"},
    {Schema.QualityGate, %{"enabled" => true}, :model, "is required when quality_gate.enabled is true"},
    {Schema.Learnings, %{"enabled" => true}, :provider, "must be one of: anthropic, openai"},
    {Schema.Learnings, %{"enabled" => true}, :model, "is required when learnings.enabled is true"},
    {Schema.ReviewAgent, %{"enabled" => true}, :kind, "is invalid"},
    {Schema.ReviewAgent, %{"enabled" => true}, :command, "is required when review_agent.enabled is true"},
    {Schema.AutoReview, %{}, :state, "can't be blank"},
    {Schema.Notifications.Channel, %{}, :kind, "can't be blank"},
    {SystemSchema.Repo, %{}, :name, "can't be blank"},
    {SystemSchema.Repo, %{}, :workflow, "can't be blank"}
  ]

  test "every required string field rejects a blank string" do
    unreported =
      for {module, attrs, field, message} <- @blank_required_fields,
          changeset = module.changeset(struct(module), Map.put(attrs, Atom.to_string(field), "")),
          message not in Enum.map(Keyword.get_values(changeset.errors, field), &elem(&1, 0)),
          do: "#{inspect(module)}.#{field}: #{inspect(changeset.errors)}"

    assert unreported == []
  end

  test "validate_present/3 counts only nil and an exact blank string as missing" do
    types = %{name: :string, label: :string, note: :string}
    params = %{"name" => "", "label" => "   ", "note" => nil}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
      |> Schema.validate_present([:name, :label, :note], message: "is missing")

    assert changeset.errors == [
             name: {"is missing", [validation: :required]},
             note: {"is missing", [validation: :required]}
           ]

    assert changeset.changes == %{label: "   "}
    assert changeset.required == [:name, :label, :note]
    assert changeset.empty_values == []
  end
end
