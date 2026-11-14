defmodule SymphonyElixir.QaBuildHoldTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Pauses, QaBuildHold}

  @repo_key "default"
  @issue_id "issue-qa-build-hold"
  @ticket {:ticket, @repo_key, @issue_id}
  @head "e44298c8123456789abcdef0123456789abcdef0"
  @new_head "d20a8a83123456789abcdef0123456789abcdef0"
  @tree "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @setter %{kind: :rule, name: "QA build hold"}
  @failed %{
    status: :failed,
    repo_key: @repo_key,
    tree: @tree,
    sha: @head,
    command: "make app",
    exit_status: 65,
    output: "error: no such module\n",
    reworked: []
  }

  # The builder as the hold reads it: what the test put for the record and the answers.
  defmodule Builder do
    @moduledoc false
    def builds?(_repo_key), do: Process.get(:qa_builds?, true)
    def lookup(_repo_key, head), do: Map.get(Process.get(:qa_build_records, %{}), head)

    def request(repo_key, head, ticket) do
      send(self(), {:requested, repo_key, head, ticket})
      :ok
    end

    def mark_reworked(repo_key, tree, issue_id) do
      send(self(), {:marked, repo_key, tree, issue_id})
      Process.get(:qa_build_mark, :ok)
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok = RunStore.clear()
    on_exit(fn -> :ok = RunStore.clear() end)
  end

  defp issue(attrs \\ %{}), do: struct!(%Issue{id: @issue_id, identifier: "TP-7", title: "Build it", state: "QA", repo_key: @repo_key}, attrs)

  defp record!(head, record), do: Process.put(:qa_build_records, Map.put(Process.get(:qa_build_records, %{}), head, record))

  defp resolve(head, opts \\ []), do: QaBuildHold.resolve(@repo_key, issue(), head, [builder: Builder] ++ opts)

  defp commits, do: for(reason <- QaBuildHold.reasons(@repo_key, @issue_id), do: reason.waits_on.commit)

  # Runs the move where the test can see it, as the task would.
  defp inline(fun) do
    fun.()
    {:ok, self()}
  end

  describe "a head with no build yet" do
    test "asks for the build and holds the ticket on it, once" do
      log = capture_log(fn -> assert resolve(@head) == :held end)
      assert log =~ "Holding QA for its build: issue_id=#{@issue_id} issue_identifier=TP-7 repo_key=default head_sha=#{@head}"
      assert_received {:requested, @repo_key, @head, %{identifier: "TP-7", issue_id: @issue_id, held: true}}

      assert [%{kind: :build, waits_on: %{commit: @head}, text: "Waiting for the QA build of e44298c", set_by: @setter} = reason] =
               QaBuildHold.reasons(@repo_key, @issue_id)

      assert QaBuildHold.reason?(reason)
      assert QaBuildHold.lines([reason]) == ["Waiting for the QA build of e44298c"]

      # While it builds the ticket stays held on the one reason, and the builder hears who waits.
      record!(@head, %{status: :building, tree: @tree})
      assert capture_log(fn -> assert resolve(@head) == :held end) == ""
      assert_received {:requested, @repo_key, @head, %{held: true}}
      assert commits() == [@head]
    end

    test "a head that moved while the ticket was held replaces the reason" do
      capture_log(fn ->
        assert resolve(@head) == :held
        assert resolve(@new_head) == :held
      end)

      assert commits() == [@new_head]
    end

    test "a reason that can't be set is logged and holds nothing" do
      log = capture_log(fn -> assert resolve("not-a-commit") == :held end)
      assert log =~ "Could not hold QA for its build: issue_id=#{@issue_id} issue_identifier=TP-7"
      assert commits() == []
    end
  end

  describe "a build that ended" do
    test "ready or unavailable: QA dispatches and the hold goes" do
      for status <- [:ready, :unavailable] do
        Process.delete(:qa_build_records)
        capture_log(fn -> assert resolve(@head) == :held end)
        record!(@head, %{status: status, tree: @tree})

        log = capture_log(fn -> assert resolve(@head) == :dispatch end)
        assert log =~ "Released from the QA build hold: issue_id=#{@issue_id} issue_identifier=TP-7 repo_key=default"
        assert commits() == []
      end

      refute_received {:marked, _repo_key, _tree, _issue_id}
    end

    test "failed: the ticket goes to Rework once, held while the move is made" do
      record!(@head, @failed)
      test = self()

      rework = fn repo_key, issue, head, record ->
        send(test, {:rework, repo_key, issue.identifier, head, record, commits()})
        :ok
      end

      log = capture_log(fn -> assert resolve(@head, rework: rework, start_task: &inline/1) == :held end)

      assert_received {:marked, @repo_key, @tree, @issue_id}
      assert_received {:rework, @repo_key, "TP-7", @head, @failed, [@head]}
      refute_received {:requested, _repo_key, _head, _ticket}
      assert log =~ "QA build failed; moving the ticket to Rework issue_id=#{@issue_id} issue_identifier=TP-7 repo_key=default head_sha=#{@head} tree=#{@tree} outcome=:ok"
      assert commits() == []

      # Back in QA on the same tree, it is not sent back again: QA runs.
      Process.put(:qa_build_mark, :already)
      assert resolve(@head, rework: rework, start_task: &inline/1) == :dispatch
      refute_received {:rework, _repo_key, _identifier, _head, _record, _held}
    end

    test "failed: a move that can't start lets the ticket go" do
      record!(@head, @failed)

      log = capture_log(fn -> assert resolve(@head, start_task: fn _fun -> {:error, :max_children} end) == :held end)

      assert log =~ "QA build failed, but the move to Rework could not start issue_id=#{@issue_id} issue_identifier=TP-7 reason={:error, :max_children}"
      assert commits() == []
    end

    test "failed: the move is the QA fail move, made in a task" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)
      record!(@head, @failed)

      capture_log(fn ->
        assert resolve(@head) == :held
        assert_receive {:memory_tracker_state_update, @issue_id, "Rework"}
        assert_receive {:memory_tracker_comment, @issue_id, report}
        assert report =~ "Symphony ran the build command `make app` on the QA host and it exited with status 65."
        eventually(fn -> commits() == [] end)
      end)
    end

    test "failed: a repository whose settings can't be read moves nothing" do
      Process.put(:qa_build_records, %{@head => @failed})
      issue = issue(%{repo_key: "no-such-repo"})

      opts = [builder: Builder, start_task: &inline/1]
      log = capture_log(fn -> assert QaBuildHold.resolve("no-such-repo", issue, @head, opts) == :held end)

      assert log =~ "QA build failed; moving the ticket to Rework"
      assert log =~ "outcome={:error,"
      assert QaBuildHold.reasons("no-such-repo", @issue_id) == []
    end
  end

  describe "nothing to wait for" do
    test "no head, no identifier, or no builder for the repository: QA dispatches, and a leftover hold goes" do
      capture_log(fn -> assert resolve(@head) == :held end)
      assert capture_log(fn -> assert resolve(nil) == :dispatch end) =~ "Released from the QA build hold"
      assert commits() == []

      assert QaBuildHold.resolve(@repo_key, issue(%{identifier: nil}), @head, builder: Builder) == :dispatch

      Process.put(:qa_builds?, false)
      assert resolve(@head) == :dispatch
      refute_received {:requested, @repo_key, @head, %{identifier: nil}}
      assert commits() == []
    end

    test "without the builder nothing is held" do
      assert QaBuildHold.resolve(@repo_key, issue(), @head) == :dispatch
      assert commits() == []
    end
  end

  describe "reasons/2" do
    test "reads only this hold's reasons" do
      {:ok, _pause} = Pauses.set(@ticket, %{kind: :build, waits_on: %{commit: @head}}, set_by: %{kind: :rule, name: "Instructions update hold"})
      {:ok, _pause} = Pauses.set(@ticket, Pauses.ticket_reason(:dependency, "TP-9"))

      assert QaBuildHold.reasons(@repo_key, @issue_id) == []
      assert QaBuildHold.reasons(nil, @issue_id) == []
      assert QaBuildHold.reasons(@repo_key, nil) == []
      refute QaBuildHold.reason?(%{kind: :build, waits_on: %{version: "0.0.1.2"}, set_by: @setter})
      assert QaBuildHold.release(@repo_key, @issue_id, "TP-7") == :ok
      assert length(Pauses.why(@ticket)) == 2
    end
  end
end
