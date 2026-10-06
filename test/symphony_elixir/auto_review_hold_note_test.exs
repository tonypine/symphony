defmodule SymphonyElixir.AutoReviewHoldNoteTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AutoReview.HoldNote

  @now ~U[2026-10-06 10:00:00Z]
  @limit %{provider: "anthropic", scope: :all, window: "five_hour", source: :rate_limit_event}

  defp issue, do: %Issue{id: "issue-hold", identifier: "TP-563", title: "Hold note", state: "Auto Review"}

  defp client(comments) do
    recipient = self()

    fn query, variables, _opts ->
      send(recipient, {:linear, query, variables})

      cond do
        query =~ "comments(" -> {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => comments}}}}}
        query =~ "commentDelete" -> {:ok, %{"data" => %{"commentDelete" => %{"success" => true}}}}
      end
    end
  end

  test "render/3 says when the usage limit resets, or when an unreachable API is tried again, in local time" do
    opts = [now: @now, to_local: & &1]

    assert HoldNote.render(@limit, ~U[2026-10-06 14:05:00Z], opts) ==
             "QA is waiting for the usage limit to reset at 14:05. " <>
               "Auto Review runs the pass again then, and Symphony removes this note when it does.\n"

    assert HoldNote.render(@limit, ~U[2026-10-07 09:30:00Z], opts) =~ "QA is waiting for the usage limit to reset at Oct 7 09:30."

    unreachable = %{provider: "anthropic", scope: :all, source: :api_unreachable, error: "ENOTFOUND"}
    assert HoldNote.render(unreachable, ~U[2026-10-06 10:01:00Z], opts) =~ "QA is waiting for the model API to come back; it tries again at 10:01."
    assert HoldNote.render(@limit, DateTime.add(DateTime.utc_now(), 60)) =~ "QA is waiting for the usage limit to reset at "
  end

  test "post/4 leaves other trackers alone, since they can't edit or delete a comment" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

    assert :skipped = HoldNote.post(issue(), @limit, ~U[2026-10-06 14:05:00Z])
    refute_received {:memory_tracker_comment, _issue_id, _body}
  end

  test "withdraw/2 deletes only the note, and an issue without one is fine" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    workpad = %{"id" => "w", "body" => "## Symphony Workpad"}
    note = %{"id" => "c-note", "body" => "QA is waiting for the usage limit to reset at 14:05."}

    assert :ok = HoldNote.withdraw(issue(), linear_client: client([workpad, note]))
    assert_receive {:linear, delete, %{id: "c-note"}}
    assert delete =~ "commentDelete"
    assert_receive {:linear, _comments_query, %{id: "issue-hold", limit: _limit}}

    assert :ok = HoldNote.withdraw(issue(), linear_client: client([workpad]))
    assert_receive {:linear, _comments_query, %{id: "issue-hold", limit: _limit}}
    refute_received {:linear, _query, _variables}
  end
end
