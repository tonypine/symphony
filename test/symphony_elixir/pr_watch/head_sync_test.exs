defmodule SymphonyElixir.PrWatch.HeadSyncTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PrWatch.HeadSync
  alias SymphonyElixir.TicketEvents

  @pr_url "https://github.com/tonypine/symphony/pull/820"
  @head "280641b1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @stale "353903e1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defmodule FakeGitHub do
    # The PR head GitHub shows on each read (the last one repeats), and the nudge's result.
    def fetch_ci_status(pr_url, _opts) do
      reads = Process.get(:head_sync_reads)
      count = Process.get(:head_sync_read_count, 0)
      Process.put(:head_sync_read_count, count + 1)
      send(self(), {:pr_read, pr_url})
      Enum.at(reads, count) || List.last(reads)
    end

    def change_base(pr_url, base, _opts) do
      send(self(), {:nudged, pr_url, base})
      Process.get(:head_sync_nudge_result, :ok)
    end
  end

  setup do
    :ok = RunStore.clear()
    Process.put(:head_sync_clock, 0)
    :ok
  end

  defp target(attrs \\ %{}) do
    Map.merge(%{repo_key: "repo-a", issue_id: "issue-1", pr_url: @pr_url, head: @head, workspace: "/tmp/none", run_id: nil}, attrs)
  end

  defp pr(head, attrs \\ %{}), do: {:ok, Map.merge(%{commit_sha: head, head_ref_name: "auto/TP-1420", base_ref_name: "main", checks: []}, attrs)}

  defp opts(tip, extra \\ []) do
    [
      github: FakeGitHub,
      branch_tip_reader: fn _workspace, _host, branch ->
        send(self(), {:tip_read, branch})
        tip
      end,
      monotonic_ms: fn -> Process.get(:head_sync_clock) end,
      sleep: fn ms -> Process.put(:head_sync_clock, Process.get(:head_sync_clock) + ms) end
    ] ++ extra
  end

  defp notes, do: "issue-1" |> TicketEvents.query(types: ["note"]) |> Enum.map(& &1.payload.text)

  test "a PR on the run's head is in sync, with nothing waited for or recorded" do
    Process.put(:head_sync_reads, [pr(@head)])

    assert HeadSync.await(target(), opts(@head)) == :in_sync
    refute_received {:tip_read, _branch}
    assert notes() == []
  end

  test "a PR on another head whose branch is there too reads as not pushed, so the PR is right" do
    Process.put(:head_sync_reads, [pr(@stale)])

    assert HeadSync.await(target(), opts(@stale)) == :not_on_origin
    assert_received {:tip_read, "auto/TP-1420"}
    assert HeadSync.await(target(), opts(nil)) == :not_on_origin
    assert notes() == []
  end

  test "an unreadable PR is unknown" do
    Process.put(:head_sync_reads, [{:error, :gh_unavailable}])

    assert HeadSync.await(target(), opts(@head)) == :unknown
  end

  test "a branch ahead of its PR is nudged after a minute, and the PR's pick-up ends the wait" do
    # Seven reads 10 s apart: 0 s .. 60 s still show the old head, the nudge goes out at 60 s, and the
    # read after it shows the pushed head.
    Process.put(:head_sync_reads, List.duplicate(pr(@stale), 7) ++ [pr(@head)])

    log = capture_log(fn -> assert HeadSync.await(target(), opts(@head)) == :in_sync end)

    assert_received {:nudged, @pr_url, "main"}
    refute_received {:nudged, _url, _base}
    assert Process.get(:head_sync_clock) == HeadSync.nudge_after_ms() + 10_000
    refute log =~ "still waiting"

    assert notes() == [
             "Waiting for GitHub to pick up 280641b1: the branch is at it, but PR #820 still shows 353903e1",
             "GitHub had not attached 280641b1 to PR #820; nudged it",
             "GitHub picked up 280641b1 on PR #820; CI running on 280641b1"
           ]

    assert [%{head_sha: @head} | _rest] = TicketEvents.query("issue-1", types: ["note"])
  end

  test "a PR GitHub still has not re-synced after the wait is still lagging, nudged once" do
    Process.put(:head_sync_reads, [pr(@stale)])

    log = capture_log(fn -> assert HeadSync.await(target(), opts(@head)) == {:lagging, @head} end)

    assert log =~ "GitHub has not attached #{@head} to #{@pr_url} yet"
    assert_received {:nudged, @pr_url, "main"}
    refute_received {:nudged, _url, _base}
    assert length(notes()) == 2

    # A second wait on the same head records nothing new: each note is kept once per head.
    capture_log(fn -> HeadSync.await(target(), opts(@head)) end)
    assert length(notes()) == 2
  end

  test "the wait is bounded by its reads too, whatever the clock says" do
    Process.put(:head_sync_reads, [pr(@stale)])
    frozen = Keyword.merge(opts(@head), sleep: fn _ms -> :ok end)

    capture_log(fn -> assert HeadSync.await(target(), frozen ++ [wait_ms: 30, poll_ms: 10]) == {:lagging, @head} end)
    assert Process.get(:head_sync_read_count) == 5
  end

  test "a nudge GitHub refuses is logged and tried again on the next read" do
    Process.put(:head_sync_reads, [pr(@stale)])
    Process.put(:head_sync_nudge_result, {:error, :forbidden})

    log = capture_log(fn -> HeadSync.await(target(), opts(@head, nudge_after_ms: 0, wait_ms: 10)) end)

    assert log =~ "Could not nudge #{@pr_url} to pick up #{@head}: :forbidden"
    assert_received {:nudged, @pr_url, "main"}
    assert_received {:nudged, @pr_url, "main"}
    refute Enum.any?(notes(), &(&1 =~ "nudged it"))
  end

  test "a PR whose base can't be read is not nudged, and a lagging read that turns unreadable ends the wait" do
    Process.put(:head_sync_reads, [pr(@stale, %{base_ref_name: nil}), {:error, :gh_unavailable}])

    assert HeadSync.await(target(), opts(@head, nudge_after_ms: 0)) == :unknown
    refute_received {:nudged, _url, _base}
  end

  test "a ticket with no record key or a PR url without a number still waits, naming the PR plainly" do
    Process.put(:head_sync_reads, [pr(nil)])

    capture_log(fn -> assert HeadSync.await(target(%{repo_key: nil}), opts(@head, wait_ms: 0)) == {:lagging, @head} end)
    assert notes() == []

    Process.put(:head_sync_read_count, 0)
    capture_log(fn -> HeadSync.await(target(%{pr_url: "https://example.com/pr"}), opts(@head, wait_ms: 0)) end)
    assert notes() == ["Waiting for GitHub to pick up 280641b1: the branch is at it, but its PR still shows an older head"]
  end

  describe "origin_tip/3" do
    test "reads the branch's commit on the workspace's origin, the current branch when none is named" do
      root = Path.join(System.tmp_dir!(), "symphony-head-sync-#{System.unique_integer([:positive])}")
      remote = Path.join(root, "remote.git")
      workspace = Path.join(root, "workspace")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      git!(root, ["init", "--bare", "-b", "main", remote])
      git!(root, ["clone", remote, workspace])
      git!(workspace, ["checkout", "-b", "auto/TP-1420"])
      File.write!(Path.join(workspace, "README.md"), "readme")
      git!(workspace, ["add", "README.md"])
      git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "readme"])
      head = workspace |> git!(["rev-parse", "HEAD"]) |> String.trim()

      assert HeadSync.origin_tip(workspace, nil, "auto/TP-1420") == nil
      git!(workspace, ["push", "origin", "auto/TP-1420"])

      assert HeadSync.origin_tip(workspace, nil, "auto/TP-1420") == head
      assert HeadSync.origin_tip(workspace, nil, nil) == head

      git!(workspace, ["checkout", "--detach"])
      assert HeadSync.origin_tip(workspace, nil, nil) == nil
    end

    test "is nil for an SSH worker's workspace or a missing directory" do
      assert HeadSync.origin_tip("/tmp/none", "worker-1", "main") == nil
      assert HeadSync.origin_tip(Path.join(System.tmp_dir!(), "symphony-head-sync-missing"), nil, "main") == nil
      assert HeadSync.origin_tip(nil, nil, "main") == nil
    end
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
