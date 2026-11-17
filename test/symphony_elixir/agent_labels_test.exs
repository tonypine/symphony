defmodule SymphonyElixir.AgentLabelsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentLabels

  test "returns configured display labels for known agent kinds" do
    assert AgentLabels.display_name("codex") == "Codex"
    assert AgentLabels.display_name(:claude) == "Claude"
    assert AgentLabels.display_name("opencode") == "OpenCode"

    assert AgentLabels.update_label("codex") == "Codex update"
    assert AgentLabels.workpad_heading(:claude) == "## Symphony Workpad"
  end

  test "falls back to generic agent labels for unknown or blank kinds" do
    assert AgentLabels.display_name("custom") == "Agent"
    assert AgentLabels.display_name(nil) == "Agent"
    assert AgentLabels.display_name(123) == "Agent"

    assert AgentLabels.update_label(" ") == "Agent update"
    assert AgentLabels.workpad_heading("unknown") == "## Symphony Workpad"
    assert AgentLabels.workpad_heading(%{}) == "## Symphony Workpad"
  end

  test "normalizes kind values" do
    assert AgentLabels.normalize_kind(:Codex) == "codex"
    assert AgentLabels.normalize_kind(" Claude ") == "claude"
    assert AgentLabels.normalize_kind(" ") == nil
    assert AgentLabels.normalize_kind(nil) == nil
    assert AgentLabels.normalize_kind(%{}) == nil
  end

  test "returns known workpad markers" do
    assert AgentLabels.known_workpad_markers() == [
             "## Symphony Workpad",
             "## Codex Workpad",
             "## Claude Workpad"
           ]
  end

  test "builds prompt context from normalized kind" do
    assert AgentLabels.prompt_context(" CODEX ") == %{
             kind: "codex",
             display_name: "Codex",
             update_label: "Codex update",
             workpad_heading: "## Symphony Workpad"
           }

    assert AgentLabels.prompt_context("custom").display_name == "Agent"
  end
end
