defmodule SymphonyElixir.PrDecision.ActionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PrDecision.Action

  test "builds an action with its rule, kind, args and reason" do
    assert {:ok, %Action{rule: "R29", kind: :merge_now, args: %{}, reason: "PR #1 is green", owner: nil, clears_when: nil}} =
             Action.new("R29", :merge_now, reason: "PR #1 is green")

    assert %Action{kind: :ci_fix, args: %{origin: :qa}} = Action.new!("R21", :ci_fix, args: %{origin: :qa}, reason: "red")
  end

  test "refuses a waiting kind without an owner and a clearing condition" do
    for kind <- Action.waiting_kinds() do
      assert {:error, :wait_needs_owner_and_clears_when} = Action.new("R9", kind, reason: "waiting")
      assert {:error, :wait_needs_owner_and_clears_when} = Action.new("R9", kind, reason: "waiting", owner: :agent)
      assert {:error, :wait_needs_owner_and_clears_when} = Action.new("R9", kind, reason: "waiting", owner: :agent, clears_when: "  ")
      assert {:error, :wait_needs_owner_and_clears_when} = Action.new("R9", kind, reason: "waiting", owner: :nobody, clears_when: "the run ends")
      assert {:ok, action} = Action.new("R9", kind, reason: "waiting", owner: :agent, clears_when: "the run ends")
      assert Action.waiting?(action)
    end
  end

  test "refuses an unknown kind and a missing reason" do
    assert {:error, :unknown_kind} = Action.new("R1", :panic, reason: "no")
    assert {:error, :reason_required} = Action.new("R1", :arm, [])
    assert {:error, :reason_required} = Action.new("R1", :arm, reason: "")
  end

  test "new!/3 raises naming the rule and the refusal" do
    assert_raise ArgumentError, "R4: cannot build a :wait action (wait_needs_owner_and_clears_when)", fn -> Action.new!("R4", :wait, reason: "held") end
  end

  test "lists its kinds and owners" do
    assert :wait_for_competitors in Action.kinds() and :file_fix_ticket in Action.kinds()
    assert Action.waiting_kinds() -- Action.kinds() == []
    assert Action.owners() == [:agent, :ci, :github, :person, :symphony]
  end
end
