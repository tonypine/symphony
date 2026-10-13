defmodule SymphonyElixir.LandingOrderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LandingOrder
  alias SymphonyElixir.Linear.Issue

  @now ~U[2026-10-13 12:00:00Z]
  @repo_key "default"

  defmodule OpenPullsGitHub do
    @spec list_open_pull_requests(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
    def list_open_pull_requests(pr_url, opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :landing_order_test_recipient)
      send(recipient, {:list_open_pull_requests, pr_url, opts})
      Application.fetch_env!(:symphony_elixir, :landing_order_test_open_pulls)
    end
  end

  defmodule NoListGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts), do: {:ok, %{}}
  end

  setup do
    Application.put_env(:symphony_elixir, :landing_order_test_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :landing_order_test_recipient)
      Application.delete_env(:symphony_elixir, :landing_order_test_open_pulls)
    end)

    :ok
  end

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

  describe "refresh/5" do
    test "reads the open PRs once and keeps each record's files, state and wait" do
      open_pulls([pull(1, ["lib/a.ex"]), pull(2, ["lib/a.ex", "lib/b.ex"]), pull(9, ["x"])])

      reviews = [record("a", 1, workspace_path: "/w/a"), record("b", 2), record("gone", 3), %{issue_id: "no-pr"}]
      issues = [issue("a", "Merging"), issue("b", "QA")]

      assert [{_a, a}, {_b, b}, {_gone, nil}, {_no_pr, nil}] = refresh(reviews, issues, @now)
      assert_receive {:list_open_pull_requests, "https://github.com/acme/repo/pull/1", [cwd: "/w/a"]}

      assert a == landing(files: ["lib/a.ex"], state: "Merging")
      assert %{state: "QA", waits_for: %{issue_id: "a", issue_identifier: "TP-a", shared_files: 1}, waits_since: @now} = b
      assert b.waits_for.files == ["lib/a.ex"]
    end

    test "keeps when a record entered its state, moved and started waiting, and refreshes progress while it waits" do
      open_pulls([pull(1, ["x"]), pull(2, ["x"])])
      earlier = DateTime.add(@now, -3600)
      later = DateTime.add(@now, 60)
      reviews = [record("a", 1), record("b", 2)]
      issues = [issue("a", "Merging"), issue("b", "QA")]

      [{_, a}, {_, b}] = refresh(reviews, issues, earlier)
      reviews = [Map.put(record("a", 1), :landing, a), Map.put(record("b", 2), :landing, b)]

      assert [{_, a2}, {_, b2}] = refresh(reviews, issues, later)
      assert %{state_since: ^earlier, progress_at: ^earlier} = a2
      assert %{state_since: ^earlier, progress_at: ^later, waits_since: ^earlier} = b2

      # A new head is progress; a new state starts the state over.
      open_pulls([%{pull(1, ["x"]) | head_sha: "new"}, pull(2, ["x"])])

      assert [{_, %{progress_at: ^later, state_since: ^earlier}}, {_, %{state_since: ^later}}] =
               refresh(reviews, [issue("a", "Merging"), issue("b", "Code Review")], later)
    end

    test "a record whose ticket this poll didn't read keeps the state it was last read in" do
      open_pulls([pull(1, ["x"]), pull(2, ["x"])])
      reviews = [Map.put(record("a", 1), :landing, landing(files: ["x"], state: "QA")), record("b", 2)]

      assert [{_, %{state: "QA", waits_for: nil}}, {_, %{state: "Code Review", waits_for: %{issue_id: "a"}}}] =
               refresh(reviews, [issue("b", "Code Review")], @now)
    end

    test "when the read fails, each record keeps the files it last had" do
      Application.put_env(:symphony_elixir, :landing_order_test_open_pulls, {:error, :rate_limited})
      reviews = [Map.put(record("a", 1), :landing, landing(files: ["x"], state: "QA")), record("b", 2)]

      log =
        capture_log(fn ->
          assert [{_, %{files: ["x"], head_sha: "sha-1"}}, {_, nil}] = refresh(reviews, [], @now)
        end)

      assert log =~ "Landing order: reading the open pull requests failed"
    end

    test "a held leader leads no one and a forced follower never waits" do
      open_pulls([pull(1, ["x"]), pull(2, ["x"]), pull(3, ["x"])])
      :ok = RunStore.set_ticket_hold(@repo_key, "a", :blocked, %{})
      forced = %{issue("c", "Code Review") | labels: [Config.settings!().agent.force_label]}

      assert [{_, %{waits_for: nil}}, {_, %{waits_for: nil}}, {_, %{waits_for: nil}}] =
               refresh([record("a", 1), record("b", 2), record("c", 3)], [issue("a", "Merging"), issue("b", "QA"), forced], @now)
    end

    test "is off without a way to list open PRs or with fewer than two tracked PRs" do
      reviews = [record("a", 1), record("b", 2)]
      assert [{_, nil}, {_, nil}] = refresh(reviews, [], @now, github: NoListGitHub, repo_key: @repo_key)
      assert [{_, nil}, {_, nil}] = refresh([record("a", 1), %{issue_id: "b", pr_url: "nope"}], [], @now)
      refute_received {:list_open_pull_requests, _url, _opts}
    end
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

  defp record(id, number, attrs \\ []) do
    %{issue_id: id, issue_identifier: "TP-#{id}", repo_key: @repo_key, pr_url: "https://github.com/acme/repo/pull/#{number}"}
    |> Map.merge(Map.new(attrs))
  end

  defp pull(number, files),
    do: %{number: number, url: "https://github.com/acme/repo/pull/#{number}", title: "PR #{number}", head_sha: "sha-#{number}", files: files}

  defp issue(id, state), do: %Issue{id: id, identifier: "TP-#{id}", state: state, labels: []}

  defp open_pulls(pulls), do: Application.put_env(:symphony_elixir, :landing_order_test_open_pulls, {:ok, pulls})

  defp refresh(reviews, issues, now, opts \\ [github: OpenPullsGitHub, repo_key: @repo_key]),
    do: LandingOrder.refresh(reviews, issues, Config.settings!(), opts, now)

  defp landing(attrs) do
    Map.merge(
      %{files: [], head_sha: "sha-1", state: nil, state_since: @now, progress_at: @now, waits_for: nil, waits_since: nil},
      Map.new(attrs)
    )
  end
end
