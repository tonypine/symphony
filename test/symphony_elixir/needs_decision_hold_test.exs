defmodule SymphonyElixir.NeedsDecisionHoldTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Hold, MergeConfirmation, NeedsDecisionHold, RunStore, Workflow}
  alias SymphonyElixir.HumanActions.{Collector, Request}
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-a"
  @issue_id "issue-1"
  @comment_id "comment-1"

  defmodule FailingStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(_repo_key, _issue_id), do: {:error, :boom}
  end

  # Reads succeed (through the real store) but writes fail, so a clear can be driven into its
  # failure path without losing the hold the read needs.
  defmodule ReadOnlyStore do
    def set_ticket_hold(_repo_key, _issue_id, _kind, _attrs), do: {:error, :boom}
    def clear_ticket_hold(_repo_key, _issue_id, _kind), do: {:error, :boom}
    def get_ticket_state(repo_key, issue_id), do: RunStore.get_ticket_state(repo_key, issue_id)
  end

  # The labels project fine; only the move a confirmation performs fails, so a clear reaches the
  # continue and is driven into its failure path.
  defmodule FailingMoveTracker do
    def set_machine_label(_issue_id, _name), do: :ok
    def clear_machine_label(_issue_id, _name), do: :ok
    def update_issue_state(_issue_id, _state), do: {:error, :rate_limited}
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    :ok = RunStore.clear()
    :ok
  end

  defp designed_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}, "state_machine" => "designed"})
    settings
  end

  defp legacy_settings do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    settings
  end

  defp issue(attrs \\ %{}) do
    struct!(%Issue{id: @issue_id, identifier: "TP-818", title: "T", state: "In Progress", repo_key: @repo_key}, attrs)
  end

  # The request as the tool builds it from the agent's attrs: what `Request.render_hold/2` renders.
  defp request(attrs \\ %{}) do
    Map.merge(
      %{
        title: "Add the release signing secrets",
        question: "Add the signing secrets, or ship unsigned builds?",
        why: "Every Release run on main fails without them.",
        unblocks: "the Release workflow on main",
        est_minutes: 10,
        options: [%{label: "Add the secrets", effect: "Releases are signed again.", recommended: true}, %{label: "Ship unsigned", effect: "The agent drops the signing step."}],
        steps: [],
        created_at: nil
      },
      attrs
    )
  end

  # The request as Linear reads it back: the comment parsed, its options as rendered lines.
  defp parsed_request(attrs \\ %{}) do
    request() |> Request.render_hold("In Progress") |> Request.parse(DateTime.utc_now()) |> Map.merge(attrs)
  end

  defp request_comment(id \\ @comment_id, body \\ nil, created_at \\ "2026-10-04T10:00:00.000Z") do
    %{"id" => id, "body" => body || Request.render_hold(request(), "In Progress"), "createdAt" => created_at}
  end

  defp reply(comment_id \\ @comment_id, body \\ "Close as duplicate") do
    %{"id" => "reply-1", "body" => body, "parent" => %{"id" => comment_id}}
  end

  defp ticket_node(attrs) do
    Map.merge(
      %{
        "id" => @issue_id,
        "labels" => %{"nodes" => []},
        "comments" => %{"nodes" => []},
        "history" => %{"nodes" => []}
      },
      attrs
    )
  end

  defp with_labels(labels), do: ticket_node(%{"labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})}})

  defp labels do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == @issue_id))
    |> Map.fetch!(:labels)
  end

  defp stored_hold do
    RunStore.get_ticket_state(@repo_key, @issue_id) |> SymphonyElixir.TicketState.get_hold(:needs_decision)
  end

  describe "desired/2" do
    test "an open request with no hold wants the hold set with the decision recorded" do
      assert {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      assert attrs.reason == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.clearing_condition == "when the decision is recorded"
      assert attrs.decision.question == "Add the signing secrets, or ship unsigned builds?"
      assert attrs.decision.title == "Add the release signing secrets"
      assert attrs.decision.why == "Every Release run on main fails without them."
      assert attrs.decision.options == ["**Add the secrets** (recommended): Releases are signed again.", "**Ship unsigned**: The agent drops the signing step."]
    end

    test "a request with no question records its title as the reason" do
      assert {:set, %{reason: "Add the release signing secrets"}} = NeedsDecisionHold.desired(parsed_request(%{question: nil}), nil)
    end

    test "a hold that already carries the request wants nothing" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)

      assert NeedsDecisionHold.desired(parsed_request(), %{kind: :needs_decision, decision: attrs.decision}) == :none
    end

    test "a hold carrying a different request is replaced" do
      {:set, attrs} = NeedsDecisionHold.desired(parsed_request(), nil)
      other = parsed_request(%{title: "Something else", question: "Something else?"})

      assert {:set, %{decision: %{title: "Something else"}}} =
               NeedsDecisionHold.desired(other, %{kind: :needs_decision, decision: attrs.decision})
    end

    test "no open request clears the hold it left behind and leaves other holds alone" do
      assert NeedsDecisionHold.desired(nil, %{kind: :needs_decision}) == :clear
      assert NeedsDecisionHold.desired(nil, %{kind: :blocked}) == :none
      assert NeedsDecisionHold.desired(nil, nil) == :none
    end
  end

  describe "sync/3" do
    test "sets the Needs Decision hold on a designed repo and projects the label" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set
      assert %{reason: "Add the signing secrets, or ship unsigned builds?"} = stored_hold()
      assert stored_hold().decision.title == "Add the release signing secrets"
      assert labels() == ["Needs Decision"]
    end

    test "clears the hold once the person answers, leaving the ticket in place" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      assert stored_hold() == nil
      assert labels() == []
    end

    test "answering a merge confirmation's hold continues the ticket into Merging" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))

      node =
        ticket_node(%{
          "comments" => %{"nodes" => [request_comment(@comment_id, Request.render_hold(merge_request, "In Progress")), reply()]}
        })

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
      assert_received {:memory_tracker_state_update, @issue_id, "Merging"}
      assert stored_hold() == nil
      assert labels() == []
    end

    test "a reply naming Send to Rework moves the ticket to Rework through the guard, and one naming Merge to Merging" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      body = Request.render_hold(merge_request, "In Progress")

      for {answer, state} <- [{"send to rework, the tests are thin", "Rework"}, {"Merge", "Merging"}] do
        :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))
        withdrawn = %{"id" => "other", "body" => Request.render_withdrawal("Send to Rework is moot"), "parent" => %{"id" => @comment_id}}
        unrelated = %{"id" => "loose", "body" => "Send to Rework", "parent" => %{"id" => "elsewhere"}}
        comments = [request_comment(@comment_id, body), unrelated, withdrawn, reply(@comment_id, answer)]
        node = ticket_node(%{"comments" => %{"nodes" => comments}})

        assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :clear
        assert_received {:memory_tracker_state_update, @issue_id, ^state}
        assert stored_hold() == nil
      end
    end

    test "a confirmation whose move fails reports it and leaves the ticket where it is" do
      merge_request = MergeConfirmation.request(issue(), %{recommendation: "ready to merge", review: nil, qa: nil, pr: nil})
      :ok = RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, MergeConfirmation.attrs(merge_request))

      node =
        ticket_node(%{
          "comments" => %{"nodes" => [request_comment(@comment_id, Request.render_hold(merge_request, "In Progress")), reply()]}
        })

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings(), tracker: FailingMoveTracker) == :clear
        end)

      assert log =~ "Failed to continue issue_id=#{@issue_id} to Merging after its decision"
      assert stored_hold() == nil
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "an ordinary decision's hold continues in place, moving nothing" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_recipient) end)

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :clear
      refute_received {:memory_tracker_state_update, _issue_id, _state}
    end

    test "clears the hold when the run withdraws the request" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :set

      withdrawn = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply(@comment_id, Request.render_withdrawal("no longer needed"))]}})
      assert NeedsDecisionHold.sync(@repo_key, withdrawn, settings: designed_settings()) == :clear
      assert stored_hold() == nil
    end

    test "reads the newest open request, and another still open leaves the hold in place" do
      older = request_comment(@comment_id, Request.render_hold(request(%{title: "Older", question: "Older?"}), "In Progress"), "2026-10-04T09:00:00.000Z")
      newer = request_comment("comment-2", Request.render_hold(request(%{title: "Newer", question: "Newer?"}), "In Progress"), "2026-10-04T11:00:00.000Z")
      both = ticket_node(%{"comments" => %{"nodes" => [older, newer]}})

      assert NeedsDecisionHold.sync(@repo_key, both, settings: designed_settings()) == :set
      assert stored_hold().decision.title == "Newer"

      # The newest is answered but the older one still waits, so the hold is rewritten for it.
      answered = ticket_node(%{"comments" => %{"nodes" => [older, newer, reply("comment-2")]}})
      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :set
      assert stored_hold().decision.title == "Older"

      assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings()) == :none
    end

    test "does nothing when the request has not changed" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
    end

    test "leaves a legacy repo untouched: a request there moves the ticket" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sync(@repo_key, node, settings: legacy_settings()) == :skipped
      assert stored_hold() == nil
      assert labels() == []
    end

    test "resolves the repo's settings from its key when the caller passes none" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        repos: [[key: @repo_key, workflow: Workflow.workflow_file_path(), team: "Test", state_machine: "designed"]]
      )

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert NeedsDecisionHold.sync(@repo_key, node) == :set
      assert stored_hold() != nil
    end

    test "skips when no settings can be resolved or the node is not one" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sync(nil, node) == :skipped
      assert NeedsDecisionHold.sync("missing-repo", node) == :skipped
      assert NeedsDecisionHold.sync(:not_a_repo_key, node, settings: designed_settings()) == :skipped
      assert NeedsDecisionHold.sync(@repo_key, %{"id" => nil}, settings: designed_settings()) == :none
      assert NeedsDecisionHold.sync(@repo_key, :not_a_node, settings: designed_settings()) == :none
    end

    test "reports and clears a hand-added Needs Decision label with no store hold" do
      node = with_labels(["Needs Decision"])

      log = capture_log(fn -> assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none end)

      assert log =~ "with no store hold"
      assert labels() == []
      assert stored_hold() == nil
    end

    test "re-projects a store hold whose Needs Decision label is missing" do
      :ok =
        RunStore.set_ticket_hold(@repo_key, @issue_id, :needs_decision, %{
          reason: "Add the signing secrets, or ship unsigned builds?",
          clearing_condition: "when the decision is recorded",
          decision: %{title: "Add the release signing secrets", question: "Add the signing secrets, or ship unsigned builds?"}
        })

      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      assert labels() == []

      assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings()) == :none
      assert labels() == ["Needs Decision"]
      assert stored_hold() != nil
    end

    test "a store failure on set is logged and reports no change" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings(), store: FailingStore) == :none
        end)

      assert log =~ "Failed to set the Needs Decision hold"
    end

    test "a failed clear is logged and reports no change" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})

      log =
        capture_log(fn ->
          assert NeedsDecisionHold.sync(@repo_key, answered, settings: designed_settings(), store: ReadOnlyStore) == :none
        end)

      assert log =~ "Failed to clear the Needs Decision hold"
    end
  end

  describe "sweep/3" do
    test "counts the holds it set and cleared over the tickets a route read" do
      open = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      other = ticket_node(%{"id" => "issue-2"})

      assert NeedsDecisionHold.sweep(@repo_key, [open, other], settings: designed_settings()) == 1

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert NeedsDecisionHold.sweep(@repo_key, [answered, other], settings: designed_settings()) == 1
    end

    test "counts nothing on a legacy repo or without a list" do
      open = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert NeedsDecisionHold.sweep(@repo_key, [open], settings: legacy_settings()) == 0
      assert NeedsDecisionHold.sweep(@repo_key, :not_a_list, settings: designed_settings()) == 0
      # Without the caller's settings the repo is resolved from the key.
      assert NeedsDecisionHold.sweep(@repo_key, [open]) == 0
    end
  end

  describe "the Hold read path and the collector's request read" do
    test "get/4 reads the decision the hold carries" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})
      :set = NeedsDecisionHold.sync(@repo_key, node, settings: designed_settings())

      assert %{decision: %{title: "Add the release signing secrets"}} = Hold.get(@repo_key, @issue_id, :needs_decision)
      assert Hold.held_any?(@repo_key, @issue_id)
      assert Hold.held?(@repo_key, @issue_id, :needs_decision)
      refute Hold.held?(@repo_key, @issue_id, :blocked)
    end

    test "newest_open_request/2 hands back the comment id a reply answers" do
      node = ticket_node(%{"comments" => %{"nodes" => [request_comment()]}})

      assert {@comment_id, %{title: "Add the release signing secrets"}} = Collector.newest_open_request(node, designed_settings())
      assert %{title: "Add the release signing secrets"} = Collector.newest_request(node, designed_settings())

      answered = ticket_node(%{"comments" => %{"nodes" => [request_comment(), reply()]}})
      assert Collector.newest_open_request(answered, designed_settings()) == nil
      assert Collector.newest_request(answered, designed_settings()) == nil

      # On a legacy repo a reply under the request is not the answer: the move is.
      assert {@comment_id, _request} = Collector.newest_open_request(answered, legacy_settings())
      assert %{title: "Add the release signing secrets"} = Collector.newest_request(answered, legacy_settings())
    end
  end

  describe "pause/4" do
    defmodule CommentTracker do
      def create_comment(issue_id, body) do
        send(self(), {:commented, issue_id, body})
        Process.get(:pause_comment_result, :ok)
      end

      def set_machine_label(_issue_id, _name), do: :ok
      def clear_machine_label(_issue_id, _name), do: :ok
    end

    test "posts the request, rendered to stay in the phase, and sets the hold with its confirmation" do
      assert :ok = NeedsDecisionHold.pause(issue(%{state: "Code Review"}), request(), [tracker: CommentTracker], "QA")

      assert_received {:commented, @issue_id, body}
      assert body =~ "the ticket stays in Code Review until the decision is recorded"
      assert MergeConfirmation.confirm_target(Hold.get(@repo_key, @issue_id, :needs_decision)) == "QA"
    end

    test "without a confirmation the ticket continues in place once decided" do
      assert :ok = NeedsDecisionHold.pause(issue(), request(), tracker: CommentTracker)

      assert %{decision: decision} = Hold.get(@repo_key, @issue_id, :needs_decision)
      refute Map.has_key?(decision, :confirm)
    end

    test "a request that can't be posted sets no hold, and a hold that can't be set is reported" do
      Process.put(:pause_comment_result, {:error, :rate_limited})
      assert {:error, {:decision_request_failed, :rate_limited}} = NeedsDecisionHold.pause(issue(), request(), tracker: CommentTracker)
      assert Hold.get(@repo_key, @issue_id, :needs_decision) == nil

      Process.delete(:pause_comment_result)
    end

    test "a hold that can't be set posts nothing, so the retry posts the comment once" do
      assert {:error, {:decision_hold_failed, :boom}} =
               NeedsDecisionHold.pause(issue(), request(), tracker: CommentTracker, store: FailingStore, repo_key: @repo_key)

      refute_received {:commented, _issue_id, _body}

      assert :ok = NeedsDecisionHold.pause(issue(), request(), tracker: CommentTracker)
      assert_received {:commented, @issue_id, _body}
      refute_received {:commented, _issue_id, _body}
      assert Hold.get(@repo_key, @issue_id, :needs_decision)
    end
  end
end
