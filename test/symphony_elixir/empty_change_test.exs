defmodule SymphonyElixir.EmptyChangeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{EmptyChange, Handoff, Pauses, RunStore}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-empty-change"
  @pr_url "https://github.com/acme/repo/pull/901"
  @pr_head "1111111111111111111111111111111111111111"
  @base "2222222222222222222222222222222222222222"
  @workspace_head "3333333333333333333333333333333333333333"

  setup do
    issue_id = "issue-empty-change-#{System.unique_integer([:positive])}"
    on_exit(fn -> RunStore.delete_ticket_state(issue_id) end)
    %{issue: %Issue{id: issue_id, identifier: "TP-901", state: "QA", repo_key: @repo_key}}
  end

  defp github(changed_files) do
    fn
      ["api", "repos/acme/repo/pulls/901", "--jq", _jq], _opts -> {Jason.encode!(%{head: @pr_head, base_ref: "main"}), 0}
      ["api", "repos/acme/repo/compare/main..." <> @pr_head, "--jq", _jq], _opts -> {Jason.encode!(%{base: @base, changed_files: changed_files}), 0}
    end
  end

  defp heads(changed_files), do: %{workspace: @workspace_head, pr: @pr_head, base: @base, base_ref: "main", changed_files: changed_files}

  describe "check/4" do
    test "an empty compare on GitHub is empty, and the commits compared go on the ticket's history", %{issue: issue} do
      assert {:empty, heads} = EmptyChange.check(issue, @pr_url, @workspace_head, gh_runner: github(0))
      assert heads == heads(0)

      assert [%{name: "empty_change_checked", details: details} | _] = Handoff.signals(@repo_key, issue.id)
      assert details[:pr] == @pr_head or details["pr"] == @pr_head
    end

    test "a compare that changes files is not empty", %{issue: issue} do
      assert {:not_empty, %{changed_files: 4}} = EmptyChange.check(issue, @pr_url, @workspace_head, gh_runner: github(4), repo_key: @repo_key)
    end

    test "a diff GitHub cannot answer is an error, never an empty change", %{issue: issue} do
      refused = fn _args, _opts -> {"HTTP 502", 1} end
      assert {:error, {:pr_diff_unreadable, {:gh_failed, _args, 1, "HTTP 502"}}} = EmptyChange.check(issue, @pr_url, @workspace_head, gh_runner: refused)
    end
  end

  describe "reason/2 and pause/3" do
    test "the pause names the three commits and is released with Unblock", %{issue: issue} do
      reason = EmptyChange.reason(heads(4), "QA")

      assert reason.text ==
               "QA found no change in its workspace at 333333333333, but GitHub's PR head 111111111111 changes 4 files against main at 222222222222. Unblock runs it again."

      assert %{kind: :environment, waits_on: %{condition: "empty_change:111111111111"}, releasable: true} = reason
      assert EmptyChange.reason(%{heads(1) | workspace: nil}, "QA").text =~ "at an unreadable commit, but GitHub's PR head 111111111111 changes 1 file against"

      assert :ok = EmptyChange.pause(issue, heads(4), run: "QA")
      assert {:ok, %{reasons: [%{text: text, releasable: true, set_by: %{kind: :rule}}]}} = Pauses.get({:ticket, @repo_key, issue.id})
      assert text == reason.text
    end

    test "a pause the store refuses is reported" do
      issue = %Issue{id: "issue-empty-change-nameless"}
      log = capture_log(fn -> assert {:error, {:empty_change_pause_failed, {:invalid_subject, _subject}}} = EmptyChange.pause(issue, heads(2), []) end)
      assert log =~ "Pausing \"issue-empty-change-nameless\": The run found no change"
    end
  end

  describe "resync/4" do
    test "a workspace that cannot be re-synced pauses the ticket on the Unblock reason", %{issue: issue} do
      workspace = Path.join(System.tmp_dir!(), "empty-change-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      log = capture_log(fn -> assert :ok = EmptyChange.resync(issue, workspace, heads(4), run: "Code Review", sync_opts: [repo_key: @repo_key]) end)
      assert log =~ "TP-901's workspace could not be re-synced to GitHub's PR head 111111111111"

      assert {:ok, %{reasons: [%{text: "Code Review found no change in its workspace at 333333333333" <> _rest}]}} = Pauses.get({:ticket, @repo_key, issue.id})
    end
  end
end
