defmodule SymphonyElixir.AutoMergeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AutoMerge
  alias SymphonyElixir.Linear.Issue

  @pr_url "https://github.com/acme/app/pull/7"

  # GitHub: every call is reported to the test, and answers what the process dictionary says.
  defmodule GitHub do
    for {name, arity} <- [
          enable_auto_merge: 3,
          squash_merge: 3,
          disable_auto_merge: 3,
          update_branch: 3,
          cancel_stale_runs: 3
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)) do
        send(self(), {unquote(name), unquote_splicing(args)})
        Process.get(unquote(name), :ok)
      end
    end
  end

  defp pr(attrs \\ %{}) do
    Map.merge(%{pr_url: @pr_url, pr_node_id: "PR_node", head_sha: "head-1", pr_number: 7, pr_title: "Add it", pr_description: "Body"}, attrs)
  end

  test "enabled?/1 needs PR polling and auto_merge on; merging?/1 reads the issue's state" do
    assert AutoMerge.enabled?(%{pr_review: %{mode: "polling", auto_merge: true}})
    refute AutoMerge.enabled?(%{pr_review: %{mode: "polling", auto_merge: false}})
    refute AutoMerge.enabled?(%{pr_review: %{mode: "tracker", auto_merge: true}})
    refute AutoMerge.enabled?(%{})

    assert AutoMerge.merging?(%Issue{state: " merging "})
    refute AutoMerge.merging?(%Issue{state: "QA"})
    refute AutoMerge.merging?(%Issue{state: nil})
    refute AutoMerge.merging?(nil)
  end

  test "arm/2 and merge/2 send the squash request for the read's head, with the PR's title and body" do
    request = %{pr_node_id: "PR_node", head_sha: "head-1", pr_number: 7, pr_title: "Add it", pr_description: "Body"}

    assert :ok = AutoMerge.arm(pr(), github: GitHub, gh_runner: :runner)
    assert_received {:enable_auto_merge, @pr_url, ^request, [gh_runner: :runner]}

    assert :ok = AutoMerge.merge(pr(), github: GitHub)
    assert_received {:squash_merge, @pr_url, ^request, []}

    Process.put(:enable_auto_merge, {:error, :clean_status})
    assert {:error, :clean_status} = AutoMerge.arm(pr(), github: GitHub)

    # A read without a node id or a head can't name what to merge.
    assert {:error, :missing_pr_node_id} = AutoMerge.arm(pr(%{pr_node_id: nil}), github: GitHub)
    assert {:error, :missing_pr_node_id} = AutoMerge.merge(pr(%{head_sha: nil}), github: GitHub)
    refute_received {:squash_merge, _url, _request, _opts}
  end

  test "disarm/2 turns auto-merge off by the PR's node id" do
    assert :ok = AutoMerge.disarm(pr(), github: GitHub)
    assert_received {:disable_auto_merge, @pr_url, "PR_node", []}
    assert {:error, :missing_pr_node_id} = AutoMerge.disarm(pr(%{pr_node_id: nil}), github: GitHub)
  end

  test "update_branch/2 merges the base in only while the head is the read's, and cancel_stale_runs/3 cancels the old head's runs" do
    assert :ok = AutoMerge.update_branch(pr(), github: GitHub)
    assert_received {:update_branch, @pr_url, "head-1", []}
    assert {:error, :missing_head_sha} = AutoMerge.update_branch(pr(%{head_sha: nil}), github: GitHub)

    Process.put(:cancel_stale_runs, {:ok, [42]})
    assert {:ok, [42]} = AutoMerge.cancel_stale_runs(pr(), "head-0", github: GitHub)
    assert_received {:cancel_stale_runs, @pr_url, "head-0", []}
  end

  test "the comments say why auto-merge went off and that moving to Merging again turns it on" do
    for comment <- [
          AutoMerge.conflict_comment(@pr_url),
          AutoMerge.ci_fix_comment(@pr_url),
          AutoMerge.person_push_comment(@pr_url)
        ] do
      assert comment =~ "Symphony turned off GitHub auto-merge on #{@pr_url}"
      assert comment =~ "moving this ticket to Merging again turns auto-merge back on."
    end

    assert AutoMerge.conflict_comment(nil) =~ "on this PR because it conflicts"
    assert AutoMerge.exit_comment(@pr_url, "Code Review") =~ "because this ticket left Merging for Code Review"
    assert AutoMerge.exit_comment(nil, nil) =~ "on this PR because this ticket left Merging,"

    assert AutoMerge.fallback_comment(@pr_url, "Branch protection kept PR #7 from merging") ==
             "Symphony couldn't land #{@pr_url} with GitHub auto-merge (Branch protection kept PR #7 from merging), so a landing agent will merge it instead."

    assert AutoMerge.fallback_comment(nil, "x") =~ "land this PR"
  end
end
