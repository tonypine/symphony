defmodule SymphonyElixir.Setup.NearMatchTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup.NearMatch

  test "case and spaces never matter" do
    assert NearMatch.near?("Needs decision ", "Needs Decision")
    assert NearMatch.near?("tp", "TP")
    assert NearMatch.same_but_case_and_space?("CI  Red", "ci red")
    refute NearMatch.same_but_case_and_space?("CI rex", "CI red")
  end

  test "the edits allowed grow with the name" do
    assert NearMatch.near?("Blocker", "Blocked")
    assert NearMatch.near?("Blockd", "Blocked")
    assert NearMatch.near?("qa skip", "qa:skip")
    assert NearMatch.near?("plam", "plan")
    refute NearMatch.near?("flag", "plan")
    refute NearMatch.near?("TQ", "TP")
    refute NearMatch.near?("CI green", "CI red")
    refute NearMatch.near?("anything", nil)
  end
end
