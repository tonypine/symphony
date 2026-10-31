defmodule SymphonyElixir.CommentParsersRetiredTest do
  @moduledoc """
  Answers come from the Director (TP-1255): no module in `lib/` reads a Linear comment for a
  decision, a reply or a ruling, and no Setup check reports hold labels that drifted. The old entry
  points are named here; one that comes back fails this test.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Each retired entry point: where it was defined, and how a caller would name it.
  @retired [
    {"lib/symphony_elixir/decisions.ex", ~r/\bdef (rulings|sync|sweep|answered)\(/, ~r/Decisions\.(rulings|sync|sweep|answered)\b/},
    {"lib/symphony_elixir/inbox/item.ex", ~r/\bdef from_node\(/, ~r/Item\.from_node\b/}
  ]

  # The Needs Decision hold's modules are retired with it (TP-1256): its sweep, sync and drift
  # repair cannot come back with them.
  @deleted_files [
    "lib/symphony_elixir/hold/drift.ex",
    "lib/symphony_elixir/setup/checks/hold_drift.ex",
    "lib/symphony_elixir/hold.ex",
    "lib/symphony_elixir/needs_decision_hold.ex"
  ]

  defp lib_files do
    for path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")), do: {Path.relative_to(path, @root), File.read!(path)}
  end

  test "no retired comment or label parser is defined or called in lib/" do
    files = lib_files()

    for {file, definition, call} <- @retired do
      refute File.read!(Path.join(@root, file)) =~ definition, "#{file} defines #{inspect(definition.source)} again"

      for {path, text} <- files, call != nil do
        refute text =~ call, "#{path} calls #{inspect(call.source)} again"
      end
    end
  end

  test "the hold-drift table and its Setup check are gone" do
    for file <- @deleted_files, do: refute(File.exists?(Path.join(@root, file)), "#{file} is back")

    for {path, text} <- lib_files() do
      refute text =~ ~r/Hold\.Drift\b|Checks\.HoldDrift\b/, "#{path} names the hold-drift table or check again"
      refute text =~ ~r/\bNeedsDecisionHold\b|SymphonyElixir\.Hold\b|[^e]Hold\.(get|set|clear|held)/, "#{path} names a retired hold module again"
    end

    refute Enum.any?(SymphonyElixir.Setup.checks(), &(&1.id() == "hold_drift"))
  end

  test "the orchestrator's poll writes no rulings into the Decisions sections" do
    refute File.read!(Path.join(@root, "lib/symphony_elixir/orchestrator.ex")) =~ "Decisions."
  end
end
