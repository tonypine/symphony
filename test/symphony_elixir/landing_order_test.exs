defmodule SymphonyElixir.LandingOrderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LandingOrder

  @now ~U[2026-10-13 12:00:00Z]

  describe "waits/2" do
    test "each PR waits for the first PR above it that shares a file, furthest along first" do
      members = [
        member("c", 3, ["lib/a.ex", "lib/c.ex"], pr_number: 3),
        member("a", 5, ["lib/a.ex", "lib/b.ex"], pr_number: 1),
        member("b", 4, ["lib/b.ex", "lib/a.ex", "README.md"], pr_number: 2)
      ]

      waits = LandingOrder.waits(members, @now)

      refute Map.has_key?(waits, "a")
      assert %{issue_id: "a", issue_identifier: "TP-a", shared_files: 2, files: ["lib/b.ex", "lib/a.ex"]} = waits["b"]
      assert %{issue_id: "a", shared_files: 1, files: ["lib/a.ex"]} = waits["c"]
    end

    test "a PR that shares files only with the second waits for the second" do
      waits =
        LandingOrder.waits(
          [member("a", 5, ["lib/a.ex"]), member("b", 4, ["lib/a.ex", "lib/b.ex"]), member("c", 3, ["lib/b.ex"])],
          @now
        )

      assert waits["b"].issue_id == "a"
      assert waits["c"].issue_id == "b"
    end

    test "a PR that conflicts with the base lands after the ones that don't, whatever its state" do
      waits = LandingOrder.waits([member("merging", 5, ["lib/a.ex"], conflicting: true), member("qa", 4, ["lib/a.ex"])], @now)

      assert waits["merging"].issue_id == "qa"
      refute Map.has_key?(waits, "qa")
    end

    test "PRs that share no file are unaffected" do
      assert LandingOrder.waits([member("a", 5, ["lib/a.ex"]), member("b", 5, ["lib/b.ex"]), member("c", 1, [])], @now) == %{}
    end

    test "within a state the one longer in it lands first, then the lower PR number" do
      older = member("older", 4, ["x"], state_since: DateTime.add(@now, -600), pr_number: 9)
      newer = member("newer", 4, ["x"], state_since: DateTime.add(@now, -60), pr_number: 1)
      assert %{"newer" => %{issue_id: "older"}} = LandingOrder.waits([newer, older], @now)

      low = member("low", 4, ["x"], pr_number: 1)
      high = member("high", 4, ["x"], pr_number: 2)
      assert %{"high" => %{issue_id: "low"}} = LandingOrder.waits([high, low], @now)

      unnumbered = member("unnumbered", 4, ["x"], pr_number: nil)
      assert %{"unnumbered" => %{issue_id: "low"}} = LandingOrder.waits([unnumbered, low], @now)
    end

    test "a held or idle leader leads no one, and the next PR goes ahead" do
      held = member("held", 5, ["x"], held: true)
      idle = member("idle", 5, ["x"], progress_at: DateTime.add(@now, -2 * 60 * 60))
      follower = member("follower", 3, ["x"])

      assert LandingOrder.waits([held, follower], @now) == %{}
      assert LandingOrder.waits([idle, follower], @now) == %{}

      # A busy PR below the held one leads instead.
      assert %{"follower" => %{issue_id: "busy"}} = LandingOrder.waits([held, member("busy", 4, ["x"]), follower], @now)
    end

    test "a PR that stepped behind others (R15) ranks after each of them, so none waits for it" do
      ahead = member("ahead", 5, ["x"])
      stepped = member("stepped", 4, ["x"], behind: ["ahead", "behind"])
      behind = member("behind", 1, ["x"])

      # Before the step, the PR behind waits for it.
      assert %{"behind" => %{issue_id: "stepped"}} = LandingOrder.waits([member("stepped", 4, ["x"]), behind], @now)

      waits = LandingOrder.waits([stepped, behind], @now)
      assert waits["stepped"].issue_id == "behind"
      refute Map.has_key?(waits, "behind")

      waits = LandingOrder.waits([ahead, stepped, behind], @now)
      assert waits["behind"].issue_id == "ahead"
      assert waits["stepped"].issue_id == "ahead"
    end

    test "a forced ticket never waits" do
      assert LandingOrder.waits([member("a", 5, ["x"]), member("b", 3, ["x"], forced: true)], @now) == %{}
    end
  end

  test "reason/1 names the leader and the files they share" do
    assert LandingOrder.reason(%{issue_id: "i", issue_identifier: "TP-1", shared_files: 3}) == "waits for TP-1 to land (shares 3 files)"
    assert LandingOrder.reason(%{issue_id: "i", issue_identifier: nil, pr_url: "https://x/pull/1", shared_files: 1}) == "waits for https://x/pull/1 to land (shares 1 file)"
    assert LandingOrder.reason(%{issue_id: "i", shared_files: 1}) == "waits for i to land (shares 1 file)"
  end

  test "rank/2 orders the states by how far along they are" do
    settings = %{tracker: %{qa_state: "Testing", code_review_state: "Review"}}

    assert Enum.map(["merging", " Testing", "REVIEW", "Rework", "In Progress"], &LandingOrder.rank(&1, settings)) == [5, 4, 3, 2, 1]
    assert LandingOrder.rank(nil, settings) == 0
    assert Enum.map(["QA", "Code Review"], &LandingOrder.rank(&1, %{})) == [4, 3]
  end

  defp member(id, rank, files, attrs \\ []) do
    Map.merge(
      %{
        issue_id: id,
        issue_identifier: "TP-#{id}",
        pr_url: "https://x/pull/#{id}",
        pr_number: nil,
        state: nil,
        files: files,
        rank: rank,
        state_since: @now,
        progress_at: @now
      },
      Map.new(attrs)
    )
  end
end
