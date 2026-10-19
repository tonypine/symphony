defmodule SymphonyElixir.Setup.ConfigLinesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup.ConfigLines

  @yaml """
  # Symphony
  issues:
    provider: linear
  auto_review:
    acceptance_gate:
      enabled: false

      mode: shadow
    # the old flag
    enabled: true
  "quoted":
    'inner': 1
  repositories:
    - key: app
      state_machine: v2
  flow: {enabled: true}
  """

  test "follows a dotted path through the block indentation" do
    assert ConfigLines.line(@yaml, "issues") == 2
    assert ConfigLines.line(@yaml, "auto_review.enabled") == 10
    assert ConfigLines.line(@yaml, "auto_review.acceptance_gate.mode") == 8
    assert ConfigLines.line(@yaml, "quoted.inner") == 12
  end

  test "a key it can't find, a list item or a flow mapping has no line" do
    assert ConfigLines.line(@yaml, "issues.states") == nil
    assert ConfigLines.line(@yaml, "pull_requests") == nil
    assert ConfigLines.line(@yaml, "repositories[app].state_machine") == nil
    assert ConfigLines.line(@yaml, "flow.enabled") == nil
    assert ConfigLines.line("", "issues") == nil
  end
end
