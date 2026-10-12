defmodule SymphonyElixir.CodeReviewTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CodeReview
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunStore

  @repo_key "repo-code-review"
  @issue_id "issue-code-review"

  defmodule FakeReviewAgent do
    def evaluate(issue, _workspace, _settings, _opts) do
      send(self(), {:reviewed, issue.id, issue.state})
      Process.get(:fake_review_result, {:ok, %{verdict: :approve, comments: [], reason: "looks good"}})
    end
  end

  defmodule FakeTracker do
    def update_issue_state(issue_id, state) do
      send(self(), {:moved, issue_id, state})
      Process.get(:fake_tracker_result, :ok)
    end
  end

  defmodule OptsReviewAgent do
    def evaluate(_issue, _workspace, _settings, opts) do
      send(self(), {:review_opts, opts})
      {:ok, %{verdict: :approve, comments: [], reason: nil}}
    end
  end

  setup do
    RunStore.delete_ticket_state(@repo_key, @issue_id)
    on_exit(fn -> RunStore.delete_ticket_state(@repo_key, @issue_id) end)
    :ok
  end

  defp settings!(attrs) do
    assert {:ok, settings} = Schema.parse(attrs)
    settings
  end

  defp designed_settings(extra \\ %{}) do
    settings!(Map.merge(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"}, extra))
  end

  defp legacy_settings(extra \\ %{}) do
    settings!(Map.merge(%{"tracker" => %{"kind" => "memory"}}, extra))
  end

  defp issue(state \\ "Code Review") do
    %Issue{
      id: @issue_id,
      identifier: "TP-815",
      title: "Land the Code Review state",
      state: state,
      repo_key: @repo_key
    }
  end

  # A real checkout, so the verdict really binds to the head the reviewer judged.
  defp git_workspace! do
    dir = Path.join(System.tmp_dir!(), "code-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "first"], cd: dir)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, String.trim(head)}
  end

  defp run(workspace, opts, state \\ "Code Review") do
    CodeReview.run(issue(state), workspace, [review_agent: FakeReviewAgent, tracker: FakeTracker] ++ opts)
  end

  describe "reviewer_run?/2" do
    test "is true only for a designed repo's configured Code Review state" do
      assert CodeReview.reviewer_run?(issue(), designed_settings())
      assert CodeReview.reviewer_run?(issue(" code review "), designed_settings())
      refute CodeReview.reviewer_run?(issue("In Progress"), designed_settings())
      refute CodeReview.reviewer_run?(issue(), legacy_settings())
      refute CodeReview.reviewer_run?(issue("Code Review"), legacy_settings())
      refute CodeReview.reviewer_run?(%Issue{id: "x", state: nil}, designed_settings())
    end
  end

  describe "run/3" do
    test "skips every ticket that is not a designed repo's Code Review ticket" do
      assert :skip = run("/tmp/workspace", [settings: designed_settings()], "In Progress")
      assert :skip = run("/tmp/workspace", settings: legacy_settings())
      refute_received {:reviewed, _, _}
    end

    test "skips a non-issue or a workspace-less call" do
      assert :skip = CodeReview.run(%{}, "/tmp/workspace", settings: designed_settings())
      assert :skip = CodeReview.run(issue(), nil, settings: designed_settings())
    end

    test "an approve verdict records the verdict against the head and moves to Merging" do
      {workspace, head} = git_workspace!()

      assert :ok = run(workspace, settings: designed_settings())
      assert_received {:reviewed, @issue_id, "Code Review"}
      assert_received {:moved, @issue_id, "Merging"}

      assert [%{kind: "code_review", head_sha: ^head, outcome: "approve"}] =
               SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_approve", target: "Merging"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "a request_changes verdict moves to Rework" do
      Process.put(:fake_review_result, {:ok, %{verdict: :request_changes, comments: ["Rename this"], reason: nil}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert_received {:moved, @issue_id, "Rework"}

      assert [%{outcome: "request_changes"}] = SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")
    end

    test "a block verdict escalates through the configured escalation state" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: [], reason: "touches protected files"}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert_received {:moved, @issue_id, "In Review"}

      assert [%{outcome: "block"}] = SymphonyElixir.Handoff.verdicts(@repo_key, @issue_id, "code_review")

      assert [%{name: "code_review", details: %{signal: "code_review_escalate", reason: "touches protected files"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "an unknown verdict is refused without a move" do
      Process.put(:fake_review_result, {:ok, %{verdict: :shrug, comments: []}})

      assert {:error, {:code_review_unknown_verdict, :shrug}} = run("/tmp/workspace", settings: designed_settings())
      refute_received {:moved, _, _}
    end

    test "a reviewer failure is reported, not retried here" do
      Process.put(:fake_review_result, {:error, :model_unreachable})

      assert {:error, {:code_review_failed, :model_unreachable}} =
               run("/tmp/workspace", settings: designed_settings())
    end

    test "a tracker failure surfaces as a move failure" do
      Process.put(:fake_tracker_result, {:error, :rate_limited})

      assert {:error, {:code_review_move_failed, :code_review_approve, :rate_limited}} =
               run("/tmp/workspace", settings: designed_settings())
    end

    test "moves through the configured tracker when no tracker override is given" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      assert :ok = CodeReview.run(issue(), "/tmp/workspace", settings: designed_settings(), review_agent: FakeReviewAgent)
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
    end

    test "an issue with no identifier is labelled by its id" do
      no_identifier = %Issue{id: @issue_id, state: "Code Review", repo_key: @repo_key}

      assert :ok =
               CodeReview.run(no_identifier, "/tmp/workspace",
                 settings: designed_settings(),
                 review_agent: FakeReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:moved, @issue_id, "Merging"}
    end

    test "a block verdict with only comments uses the first comment as the reason" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block, comments: ["Say why this is blocked."]}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert [%{name: "code_review", details: %{reason: "Say why this is blocked."}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end

    test "a block verdict with nothing recorded falls back to a default reason" do
      Process.put(:fake_review_result, {:ok, %{verdict: :block}})

      assert :ok = run("/tmp/workspace", settings: designed_settings())

      assert [%{name: "code_review", details: %{reason: "reviewer blocked the change"}}] =
               SymphonyElixir.Handoff.signals(@repo_key, @issue_id)
    end
  end

  describe "the reviewer's options" do
    test "passes the repo's configured base branch to the reviewer" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: "reviewed-repo", workflow: Workflow.workflow_file_path(), team: "Test", base_branch: "develop"]]
      )

      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 repo_key: "reviewed-repo",
                 review_agent: OptsReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:review_opts, opts}
      assert opts[:base_branch] == "develop"
    end

    test "an unknown repo key gives no base branch" do
      assert :ok =
               CodeReview.run(issue(), "/tmp/workspace",
                 settings: designed_settings(),
                 repo_key: "missing-repo",
                 review_agent: OptsReviewAgent,
                 tracker: FakeTracker
               )

      assert_received {:review_opts, opts}
      refute Keyword.has_key?(opts, :base_branch)
    end
  end

  describe "inconclusive reviews" do
    test "retry boundedly on the same head, then escalate" do
      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, :no_grounding}})

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      refute_received {:moved, _, _}

      # The third attempt has run out of retries, so it escalates instead of failing again.
      assert :ok = run("/tmp/workspace", settings: designed_settings())
      assert_received {:moved, @issue_id, "In Review"}

      outcomes = @repo_key |> SymphonyElixir.Handoff.verdicts(@issue_id, "code_review") |> Enum.map(& &1.outcome)

      assert Enum.sort(outcomes) == ["inconclusive", "inconclusive", "inconclusive_escalated"]
    end

    test "a retry on a different head starts its own count" do
      Process.put(:fake_review_result, {:error, {:review_agent_inconclusive, :no_grounding}})

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run("/tmp/workspace", settings: designed_settings())

      {other_workspace, _head} = git_workspace!()

      assert {:error, {:code_review_inconclusive, :no_grounding}} =
               run(other_workspace, settings: designed_settings())
    end
  end
end
