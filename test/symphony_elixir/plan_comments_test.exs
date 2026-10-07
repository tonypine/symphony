defmodule SymphonyElixir.PlanCommentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BreakdownReview, PlanComments, SubIssueWait, Tracker}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.QaAgent.Report

  defmodule CommentsClient do
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})
      Process.get(:comments_client_result)
    end
  end

  @waiting "Waiting on sub-tickets"
  @terminal ["Done", "Canceled"]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    SubIssueWait.reset_for_test(@waiting)
    on_exit(fn -> SubIssueWait.reset_for_test(@waiting) end)
    :ok
  end

  describe "action/3" do
    test "revises a plan under review and answers comments on an approved one" do
      settings = Config.settings!()
      backlog = [%{id: "c1", identifier: "MT-2", state: "Backlog"}]
      parent = %Issue{id: "p", identifier: "MT-1", state: "In Review", labels: ["breakdown"], sub_issues: backlog}

      assert PlanComments.action(parent, @terminal, settings) == :revise
      assert PlanComments.action(%{parent | sub_issues: []}, @terminal, settings) == :revise
      assert PlanComments.action(%{parent | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Todo"}]}, @terminal, settings) == :answer
      assert PlanComments.action(%{parent | state: @waiting}, @terminal, settings) == :answer
      # Human Review waits for the operator: a comment there revises nothing, and an approved plan still gets its reply.
      refute PlanComments.action(%{parent | state: "Human Review"}, @terminal, settings)
      refute PlanComments.action(%{parent | state: "Human Review"}, @terminal, %{settings | tracker: %{settings.tracker | human_review_state: nil}})
      assert PlanComments.action(%{parent | state: "Human Review", sub_issues: [%{id: "c1", identifier: "MT-2", state: "Todo"}]}, @terminal, settings) == :answer

      # Close-out, other states, other issues: nothing.
      refute PlanComments.action(%{parent | sub_issues: [%{id: "c1", identifier: "MT-2", state: "Done"}]}, @terminal, settings)
      refute PlanComments.action(%{parent | state: "In Progress"}, @terminal, settings)
      refute PlanComments.action(%{parent | state: "Rework"}, @terminal, settings)
      refute PlanComments.action(%{parent | labels: ["feature"]}, @terminal, settings)
      refute PlanComments.action(%{parent | state: nil}, @terminal, settings)
      refute PlanComments.action(nil, @terminal, settings)
    end
  end

  describe "pending/5" do
    test "without the last run's comments, keeps people's comments since the parent entered its state and the run ended" do
      feedback = %{
        state_changes: [
          change(~U[2026-10-04 10:00:00Z], "In Progress", "In Review"),
          change(~U[2026-10-04 11:00:00Z], "In Review", "In Progress"),
          change(~U[2026-10-04 12:00:00Z], "In Progress", "In Review"),
          change(~U[2026-10-04 12:30:00Z], "In Review", nil)
        ],
        comments: [
          comment("old", "Before the plan was handed over", ~U[2026-10-04 11:30:00Z]),
          comment("second", "Merge MT-3 into MT-2", ~U[2026-10-04 12:20:00Z]),
          comment("first", "Split the history screen", ~U[2026-10-04 12:10:00Z]),
          comment("bot", "Linked a pull request", ~U[2026-10-04 12:15:00Z], bot?: true),
          comment("own", "## Symphony Workpad\n\nPlan", ~U[2026-10-04 12:16:00Z]),
          comment("no-body", nil, ~U[2026-10-04 12:17:00Z]),
          comment("no-time", "Undated", nil)
        ]
      }

      assert ids(PlanComments.pending(:revise, feedback, "In Review", nil, nil)) == ["first", "second"]
      # A run from before a restart: its comments are unknown, so only comments after it ended count.
      restored = %{started_at: ~U[2026-10-04 12:05:00Z], ended_at: ~U[2026-10-04 12:15:00Z], comment_ids: nil}
      assert ids(PlanComments.pending(:revise, feedback, "in review", restored, nil)) == ["second"]
      assert PlanComments.pending(:revise, feedback, @waiting, nil, nil) == []
      assert PlanComments.pending(:revise, %{feedback | state_changes: []}, "In Review", nil, nil) == []
    end

    test "keeps a person's comment made while the revision run worked, but not the run's own comments" do
      feedback = %{
        state_changes: [
          change(~U[2026-10-04 10:00:00Z], "In Progress", "In Review"),
          change(~U[2026-10-04 11:00:00Z], "In Review", "In Progress"),
          change(~U[2026-10-04 11:40:00Z], "In Progress", "In Review")
        ],
        comments: [
          comment("asked", "Split the history screen", ~U[2026-10-04 10:30:00Z]),
          comment("during", "Also rename MT-3", ~U[2026-10-04 11:10:00Z]),
          comment("answered", "And drop MT-4", ~U[2026-10-04 11:12:00Z]),
          comment("run-reply", "Done: MT-2 is now two tickets.", ~U[2026-10-04 11:20:00Z], parent_id: "asked"),
          comment("run-reply-2", "Done: MT-4 is cancelled.", ~U[2026-10-04 11:21:00Z], parent_id: "answered"),
          comment("run-artifact", "## Journeys (changed: history split)", ~U[2026-10-04 11:22:00Z]),
          comment("after-move", "Thanks, one more: keep MT-5", ~U[2026-10-04 11:45:00Z], parent_id: "asked")
        ]
      }

      run = %{started_at: ~U[2026-10-04 11:05:00Z], ended_at: ~U[2026-10-04 11:50:00Z], comment_ids: ["run-reply", "run-reply-2", "run-artifact"]}

      # "asked" came before the run started, "answered" got a reply from it, and its own comments never count.
      assert ids(PlanComments.pending(:revise, feedback, "In Review", run, nil)) == ["during", "after-move"]
      # Measured from the run's start, even with no move into In Review in the history.
      assert ids(PlanComments.pending(:revise, %{feedback | state_changes: []}, "In Review", run, nil)) == ["during", "after-move"]
    end

    test "a review brief on a plan under review is Symphony's own, so it never starts a revision" do
      backlog = [%{id: "c1", identifier: "MT-2", state: "Backlog"}]
      parent = %Issue{id: "p", identifier: "MT-1", state: "In Review", labels: ["breakdown"], sub_issues: backlog}
      assert PlanComments.action(parent, @terminal, Config.settings!()) == :revise

      brief = "## Review brief\n\n**What to review:** the plan for MT-1\n\n**What changed since the last brief:**\n\n- Split MT-2"

      feedback = %{
        state_changes: [change(~U[2026-10-04 10:00:00Z], "In Progress", "In Review")],
        comments: [
          comment("brief", brief, ~U[2026-10-04 10:05:00Z]),
          comment("indented-brief", "\n  " <> brief, ~U[2026-10-04 10:06:00Z])
        ]
      }

      assert PlanComments.pending(:revise, feedback, "In Review", nil, nil) == []

      person = comment("person", "Quote from the ## Review brief: split MT-2 again", ~U[2026-10-04 10:07:00Z])
      with_person = %{feedback | comments: [person | feedback.comments]}
      assert ids(PlanComments.pending(:revise, with_person, "In Review", nil, nil)) == ["person"]
    end

    test "answers each top-level comment on an approved plan once, and nothing from before Symphony started" do
      feedback = %{
        state_changes: [change(~U[2026-10-04 10:00:00Z], "In Review", @waiting)],
        comments: [
          comment("a", "Can we drop the history screen?", ~U[2026-10-04 11:00:00Z]),
          comment("a-reply", PlanComments.reply("MT-1"), ~U[2026-10-04 11:01:00Z], parent_id: "a"),
          comment("a-follow-up", "Why not?", ~U[2026-10-04 11:05:00Z], parent_id: "a"),
          comment("b", "MT-2 landed, MT-3 is next", ~U[2026-10-04 11:02:00Z]),
          comment("b-note", "FYI the design review is Friday", ~U[2026-10-04 11:03:00Z], parent_id: "b"),
          comment("c", "Answered already", ~U[2026-10-04 10:30:00Z]),
          comment("c-reply", PlanComments.reply(nil), ~U[2026-10-04 10:31:00Z], parent_id: "c"),
          comment("before-approval", "Looks good", ~U[2026-10-04 09:30:00Z]),
          comment("no-body", nil, ~U[2026-10-04 11:04:00Z])
        ]
      }

      assert ids(PlanComments.pending(:answer, feedback, @waiting, nil, nil)) == ["b"]
      assert PlanComments.pending(:answer, feedback, @waiting, nil, ~U[2026-10-04 11:10:00Z]) == []
      ended = %{started_at: nil, ended_at: ~U[2026-10-04 11:10:00Z], comment_ids: nil}
      assert PlanComments.pending(:answer, feedback, @waiting, ended, nil) == []
      assert PlanComments.pending(:answer, %{feedback | state_changes: []}, @waiting, nil, nil) == []
    end
  end

  describe "human?/1" do
    test "skips integration bots and every comment Symphony posts itself" do
      assert PlanComments.human?(comment("x", "Please split MT-2"))
      assert PlanComments.human?(comment("x", "Agree with the Supervisor review: split MT-2"))
      refute PlanComments.human?(comment("x", "Please split MT-2", nil, bot?: true))
      refute PlanComments.human?(%{bot?: false, body: nil})
      refute PlanComments.human?(nil)

      for body <- [
            "## Symphony Workpad\n\n...",
            "## Review brief\n\n**What to review:** the plan",
            "## Codex Workpad\n\n...",
            Report.heading() <> "\n\nPASS",
            "## Decision needed: add a secret",
            "## Action needed: add a secret",
            BreakdownReview.comment(:promote, ["MT-2"]),
            BreakdownReview.comment(:replace, ["MT-2"]),
            "  Symphony stopped this run without retrying because ...",
            "Symphony parked this issue in Backlog: ...",
            "Symphony couldn't land the PR ...",
            "Symphony turned off GitHub auto-merge ...",
            "Symphony quality gate: skipped (score 2 < threshold 3).",
            PlanComments.reply("MT-1"),
            "Supervisor review: plan reviewed, Tony decides",
            "\nSupervisor note: MT-2 overlaps MT-3"
          ] do
        refute PlanComments.human?(comment("x", body)), body
      end
    end
  end

  test "reply/1 is guidance for a change request, points at Rework and names the parent" do
    assert PlanComments.reply("MT-1") =~ ~r/^If this asks for a change to the plan: /
    assert PlanComments.reply("MT-1") =~ "Move MT-1 to Rework"
    assert PlanComments.reply(nil) =~ "Move the parent to Rework"
    refute PlanComments.reply("MT-1") =~ "changed nothing"
  end

  describe "Linear adapter and memory tracker" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, CommentsClient)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_module) end)
    end

    test "reads the parent's state changes and comments, telling integrations apart" do
      Process.put(
        :comments_client_result,
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "history" => %{
                 "nodes" => [%{"createdAt" => "2026-10-04T12:00:00Z", "fromState" => %{"name" => "In Progress"}, "toState" => %{"name" => "In Review"}}]
               },
               "comments" => %{
                 "nodes" => [
                   %{"id" => "c1", "body" => "Split it", "createdAt" => "2026-10-04T12:10:00Z", "parent" => nil, "user" => %{"id" => "u1"}, "botActor" => nil},
                   %{"id" => "c2", "body" => "Done", "createdAt" => "2026-10-04T12:11:00Z", "parent" => %{"id" => "c1"}, "user" => %{"id" => "u1"}},
                   %{"id" => "c3", "body" => "Linked", "createdAt" => "bad", "user" => %{"id" => "u2"}, "botActor" => %{"id" => "github"}},
                   %{"id" => "c4", "body" => "Synced", "createdAt" => nil, "user" => nil}
                 ]
               }
             }
           }
         }}
      )

      assert {:ok, feedback} = Adapter.fetch_plan_comments("parent")
      assert_received {:graphql_called, query, %{id: "parent"}}
      assert query =~ "SymphonyPlanComments"
      assert feedback.state_changes == [%{at: ~U[2026-10-04 12:00:00Z], from: "In Progress", to: "In Review"}]

      assert feedback.comments == [
               %{id: "c1", body: "Split it", created_at: ~U[2026-10-04 12:10:00Z], parent_id: nil, bot?: false},
               %{id: "c2", body: "Done", created_at: ~U[2026-10-04 12:11:00Z], parent_id: "c1", bot?: false},
               %{id: "c3", body: "Linked", created_at: nil, parent_id: nil, bot?: true},
               %{id: "c4", body: "Synced", created_at: nil, parent_id: nil, bot?: true}
             ]

      Process.put(:comments_client_result, {:ok, %{"data" => %{"issue" => %{}}}})
      assert {:ok, %{state_changes: [], comments: []}} = Adapter.fetch_plan_comments("parent")

      Process.put(:comments_client_result, {:ok, %{"data" => %{"issue" => nil}}})
      assert {:error, :issue_not_found} = Adapter.fetch_plan_comments("parent")

      Process.put(:comments_client_result, {:error, :timeout})
      assert {:error, :timeout} = Adapter.fetch_plan_comments("parent")
    end

    test "posts a reply under a comment" do
      Process.put(:comments_client_result, {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}})
      assert :ok = Adapter.create_reply("parent", "c1", "Answered")
      assert_received {:graphql_called, query, %{issueId: "parent", parentId: "c1", body: "Answered"}}
      assert query =~ "SymphonyCreateReply"

      Process.put(:comments_client_result, {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}})
      assert {:error, :comment_create_failed} = Adapter.create_reply("parent", "c1", "Answered")

      Process.put(:comments_client_result, {:error, :timeout})
      assert {:error, :timeout} = Adapter.create_reply("parent", "c1", "Answered")
    end

    test "the memory tracker serves configured comments and records replies" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      assert {:ok, %{state_changes: [], comments: []}} = Tracker.fetch_plan_comments("parent")
      assert_received {:memory_tracker_plan_comments, "parent"}

      assert :ok = Tracker.create_reply("parent", "c1", "Answered")
      assert_received {:memory_tracker_reply, "parent", "c1", "Answered"}

      Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, {:error, :boom})
      assert {:error, :boom} = Tracker.create_reply("parent", "c1", "Answered")
    end
  end

  defp change(at, from, to), do: %{at: at, from: from, to: to}

  defp comment(id, body, created_at \\ ~U[2026-10-04 12:00:00Z], opts \\ []) do
    %{id: id, body: body, created_at: created_at, parent_id: Keyword.get(opts, :parent_id), bot?: Keyword.get(opts, :bot?, false)}
  end

  defp ids(comments), do: Enum.map(comments, & &1.id)
end
