defmodule SymphonyElixir.WorkpadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Workpad

  @now_ms 1_791_000_000_000

  defmodule FailingCreateCommentClient do
    @spec graphql(String.t(), map()) :: {:error, :comment_failed}
    def graphql(_query, _variables), do: {:error, :comment_failed}
  end

  defp linear_retry_opts do
    parent = self()
    [now_ms_fun: fn -> @now_ms end, sleep_fun: &send(parent, {:linear_wait_slept, &1})]
  end

  test "bootstrap two-arity reuses existing workpad comments" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")

    issue = %Issue{
      id: "issue-existing-workpad",
      identifier: "MT-EXISTING",
      title: "Existing workpad",
      state: "In Progress",
      comments: [%{author: "Codex", body: "## Codex Workpad\nExisting", created_at: nil}]
    }

    assert {:ok, ^issue} = Workpad.bootstrap(issue, System.tmp_dir!())
  end

  test "bootstrap moves Todo issues to In Progress before creating the workpad" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    workspace = Path.join(System.tmp_dir!(), "symphony-workpad-bootstrap")

    issue = %Issue{
      id: "issue-workpad-bootstrap",
      identifier: "MT-WORKPAD",
      title: "Bootstrap workpad",
      state: "Todo"
    }

    now = ~U[2026-05-21 04:30:00Z]

    assert {:ok, updated_issue} =
             Workpad.bootstrap(issue, workspace,
               settings: Config.settings!(),
               now: now,
               short_sha: "abc1234"
             )

    assert_receive {:memory_tracker_state_update, "issue-workpad-bootstrap", "In Progress"}
    assert_receive {:memory_tracker_comment, "issue-workpad-bootstrap", body}

    assert updated_issue.state == "In Progress"
    assert [%{author: "Symphony", body: ^body, created_at: ^now}] = updated_issue.comments
    assert body =~ "## Symphony Workpad"
    assert body =~ "#{Path.expand(workspace)}@abc1234"
    assert body =~ "Symphony created this bootstrap workpad before the first agent turn."
  end

  test "bootstrap returns an error when the Todo state update fails" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :rate_limited})

    issue = %Issue{
      id: "issue-workpad-state-failed",
      identifier: "MT-STATE-FAILED",
      title: "State failure",
      state: "Todo"
    }

    assert {:error, {:workpad_bootstrap_state_update_failed, :rate_limited}} =
             Workpad.bootstrap(issue, System.tmp_dir!(), settings: Config.settings!())
  end

  test "bootstrap waits out a Linear rate limit on the Todo state move and the workpad comment" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    rate_limited = {:error, {:linear_rate_limited, @now_ms + 30_000}}
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, [rate_limited])
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_result, [rate_limited])

    issue = %Issue{id: "issue-workpad-rate-limited", identifier: "MT-RATE", title: "Rate limited", state: "Todo"}

    log =
      capture_log(fn ->
        assert {:ok, updated_issue} =
                 Workpad.bootstrap(issue, System.tmp_dir!(),
                   settings: Config.settings!(),
                   linear_retry_opts: linear_retry_opts()
                 )

        assert updated_issue.state == "In Progress"
        assert [%{author: "Symphony"}] = updated_issue.comments
      end)

    assert_received {:linear_wait_slept, 30_000}
    assert_received {:linear_wait_slept, 30_000}
    assert_received {:memory_tracker_state_update, "issue-workpad-rate-limited", "In Progress"}
    assert_received {:memory_tracker_comment, "issue-workpad-rate-limited", _body}
    assert log =~ "Linear call failed while moving issue_id=issue-workpad-rate-limited issue_identifier=MT-RATE to In Progress; retrying in 30000ms"
    assert log =~ "Linear call failed while posting the workpad for issue_id=issue-workpad-rate-limited issue_identifier=MT-RATE"
  end

  test "bootstrap reads the comments again before creating a Linear workpad whose create timed out" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")
    {:ok, registry} = CommentRegistry.start_link([])
    issue = %Issue{id: "issue-workpad-timeout", identifier: "MT-TIMEOUT", title: "Create timed out", state: "In Progress"}
    saved_workpad = %{"id" => "comment-saved", "body" => "## Symphony Workpad\nSaved", "user" => %{"name" => "Symphony"}}

    # The first create times out after Linear saved the comment; the next read sees it.
    linear_client = fn query, _variables, _opts ->
      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          nodes = if Process.get(:workpad_create_timed_out), do: [saved_workpad], else: []
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => nodes}}}}}

        String.contains?(query, "SymphonyAgentAddComment") ->
          send(self(), :linear_add_comment)
          Process.put(:workpad_create_timed_out, true)
          {:error, {:linear_api_request, %Req.TransportError{reason: :timeout}}}
      end
    end

    log =
      capture_log(fn ->
        assert {:ok, updated_issue} =
                 Workpad.bootstrap(issue, System.tmp_dir!(),
                   settings: Config.settings!(),
                   linear_client: linear_client,
                   comment_registry: registry,
                   linear_retry_opts: linear_retry_opts()
                 )

        assert [%{body: "## Symphony Workpad\nSaved"}] = updated_issue.comments
      end)

    assert_received :linear_add_comment
    refute_received :linear_add_comment
    assert_received {:linear_wait_slept, 5_000}
    assert CommentRegistry.owned?(registry, "comment-saved")
    assert log =~ "Linear call failed while bootstrapping the workpad for issue_id=issue-workpad-timeout issue_identifier=MT-TIMEOUT"
  end

  test "bootstrap handles fallback settings and sparse issue comments" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-sparse-workpad",
      identifier: "MT-SPARSE",
      title: "Sparse workpad",
      state: nil,
      comments: :not_loaded
    }

    assert {:ok, updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: %{},
               now: ~U[2026-05-21 04:30:00Z]
             )

    assert_receive {:memory_tracker_comment, "issue-sparse-workpad", body}
    assert [%{author: "Symphony", body: ^body}] = updated_issue.comments
    assert String.starts_with?(body, "## Symphony Workpad")
  end

  test "bootstrap ignores malformed comments while searching for an existing workpad" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-malformed-comments",
      identifier: "MT-MALFORMED",
      title: "Malformed comments",
      state: "In Progress",
      comments: [123]
    }

    assert {:ok, updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(), settings: Config.settings!())

    assert_receive {:memory_tracker_comment, "issue-malformed-comments", body}
    assert [%{author: "Symphony", body: ^body}, 123] = updated_issue.comments
  end

  test "bootstrap skips tracker comment creation when issue id is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      identifier: "MT-NO-ID",
      title: "Missing id",
      state: "In Progress"
    }

    assert {:ok, ^issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(), settings: Config.settings!())

    refute_receive {:memory_tracker_comment, _issue_id, _body}, 50
  end

  test "bootstrap skips PR-mode runs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-pr-mode",
      identifier: "MT-PR",
      title: "PR mode",
      state: "Todo"
    }

    assert {:ok, ^issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               prompt_mode: :pr
             )

    refute_receive {:memory_tracker_state_update, "issue-pr-mode", _state}, 50
    refute_receive {:memory_tracker_comment, "issue-pr-mode", _body}, 50
  end

  test "bootstrap reuses existing Linear workpad comments" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    issue = %Issue{
      id: "issue-existing-linear-workpad",
      identifier: "MT-LINEAR",
      title: "Linear workpad",
      state: "In Progress",
      comments: [%{author: "Reporter", body: "Recent context", created_at: nil}]
    }

    linear_client = fn query, variables, _opts ->
      send(self(), {:linear_query, query, variables})

      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{
                       "id" => "comment-workpad",
                       "body" => "## Codex Workpad\nExisting notes with <pending> & follow-up",
                       "createdAt" => "2026-05-21T04:00:00Z",
                       "updatedAt" => "2026-05-21T04:00:00Z",
                       "user" => %{"id" => "user-1", "name" => "Codex"}
                     }
                   ]
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyAgentAddComment") ->
          flunk("bootstrap must not create a duplicate workpad")
      end
    end

    assert {:ok, updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client
             )

    assert_receive {:linear_query, query, %{id: "issue-existing-linear-workpad", limit: 100}}
    assert query =~ "SymphonyAgentIssueComments"

    assert [
             %{author: "Codex", body: "## Codex Workpad\nExisting notes with <pending> & follow-up", created_at: nil},
             %{author: "Reporter", body: "Recent context", created_at: nil}
           ] = updated_issue.comments
  end

  test "bootstrap returns Linear comment lookup failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    issue = %Issue{
      id: "issue-linear-lookup-failure",
      identifier: "MT-LINEAR-LOOKUP",
      title: "Linear lookup failure",
      state: "In Progress"
    }

    linear_client = fn query, variables, _opts ->
      send(self(), {:linear_query, query, variables})
      {:error, :lookup_failed}
    end

    assert {:error, {:workpad_bootstrap_comment_failed, :lookup_failed}} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client
             )

    assert_receive {:linear_query, _query, %{id: "issue-linear-lookup-failure", limit: 100}}
  end

  test "bootstrap creates a Linear workpad when none exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    issue = %Issue{
      id: "issue-new-linear-workpad",
      identifier: "MT-LINEAR-NEW",
      title: "New Linear workpad",
      state: "In Progress"
    }

    linear_client = fn query, variables, _opts ->
      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          send(self(), {:linear_comments_query, variables})
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        String.contains?(query, "SymphonyAgentAddComment") ->
          send(self(), {:linear_add_comment, variables})

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-new", "body" => variables.body, "url" => "https://linear.test/comment-new"}
               }
             }
           }}
      end
    end

    assert {:ok, updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client,
               now: ~U[2026-05-21 04:30:00Z]
             )

    assert_receive {:linear_comments_query, %{id: "issue-new-linear-workpad", limit: 100}}
    assert_receive {:linear_add_comment, %{issueId: "issue-new-linear-workpad", body: body}}

    assert [%{author: "Symphony", body: ^body}] = updated_issue.comments
    assert String.starts_with?(body, "## Symphony Workpad")
  end

  test "bootstrap records the created workpad comment in the comment registry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    {:ok, registry} = CommentRegistry.start_link([])

    issue = %Issue{
      id: "issue-registry-new-workpad",
      identifier: "MT-REGISTRY-NEW",
      title: "Registry new workpad",
      state: "In Progress"
    }

    linear_client = fn query, variables, _opts ->
      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        String.contains?(query, "SymphonyAgentAddComment") ->
          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-owned", "body" => variables.body, "url" => "https://linear.test/comment-owned"}
               }
             }
           }}
      end
    end

    assert {:ok, _updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client,
               comment_registry: registry
             )

    assert CommentRegistry.owned?(registry, "comment-owned")
  end

  test "bootstrap records an existing workpad comment in the comment registry" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    {:ok, registry} = CommentRegistry.start_link([])

    issue = %Issue{
      id: "issue-registry-existing-workpad",
      identifier: "MT-REGISTRY-EXISTING",
      title: "Registry existing workpad",
      state: "In Progress"
    }

    linear_client = fn query, _variables, _opts ->
      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{
                       "id" => "comment-existing-workpad",
                       "body" => "## Symphony Workpad\nExisting",
                       "createdAt" => "2026-05-21T04:00:00Z",
                       "updatedAt" => "2026-05-21T04:00:00Z",
                       "user" => %{"id" => "user-1", "name" => "Symphony"}
                     }
                   ]
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyAgentAddComment") ->
          flunk("bootstrap must not create a duplicate workpad")
      end
    end

    assert {:ok, _updated_issue} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client,
               comment_registry: registry
             )

    assert CommentRegistry.owned?(registry, "comment-existing-workpad")
  end

  test "bootstrap returns Linear comment creation failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")

    issue = %Issue{
      id: "issue-linear-create-failure",
      identifier: "MT-LINEAR-CREATE",
      title: "Linear create failure",
      state: "In Progress"
    }

    linear_client = fn query, variables, _opts ->
      cond do
        String.contains?(query, "SymphonyAgentIssueComments") ->
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        String.contains?(query, "SymphonyAgentAddComment") ->
          send(self(), {:linear_add_comment, variables})
          {:error, :create_failed}
      end
    end

    assert {:error, {:workpad_bootstrap_comment_failed, :create_failed}} =
             Workpad.bootstrap(issue, System.tmp_dir!(),
               settings: Config.settings!(),
               linear_client: linear_client
             )

    assert_receive {:linear_add_comment, %{issueId: "issue-linear-create-failure"}}
  end

  test "bootstrap returns tracker comment creation failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", agent_kind: "claude")
    Application.put_env(:symphony_elixir, :linear_client_module, FailingCreateCommentClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    issue = %Issue{
      id: "issue-tracker-create-failure",
      identifier: "MT-TRACKER-CREATE",
      title: "Tracker create failure",
      state: "In Progress"
    }

    assert {:error, {:workpad_bootstrap_comment_failed, :comment_failed}} =
             Workpad.bootstrap(issue, System.tmp_dir!(), settings: %{agent: %{kind: "claude"}, tracker: %{kind: "memory"}})
  end

  test "bootstrap body uses remote worker path without local expansion" do
    assert Workpad.bootstrap_body("## Claude Workpad", "/remote/workspace",
             worker_host: "worker-a",
             short_sha: "def5678",
             now: ~U[2026-05-21 04:30:00Z]
           ) =~ "worker-a:/remote/workspace@def5678"

    assert Workpad.bootstrap_body("## Codex Workpad", System.tmp_dir!()) =~ "## Codex Workpad"

    assert Workpad.bootstrap_body("## Codex Workpad", "/local/workspace",
             hostname_result: {:error, :nxdomain},
             short_sha: "unknown-host-sha",
             now: ~U[2026-05-21 04:30:00Z]
           ) =~ "unknown-host:/local/workspace@unknown-host-sha"
  end
end
