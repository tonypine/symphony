defmodule SymphonyElixir.RestartTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Restart

  @pr_url "https://github.com/acme/widgets/pull/41"
  @other_pr_url "https://github.com/acme/widgets/pull/42"

  defmodule FakeGitHub do
    def fetch_activity(pr_url, _opts) do
      send(self(), {:fetch_activity, pr_url})
      Application.fetch_env!(:symphony_elixir, :restart_test_activity)
    end

    def close(pr_url, _opts) do
      send(self(), {:close, pr_url})
      Application.get_env(:symphony_elixir, :restart_test_close, :ok)
    end
  end

  defmodule FakeWorkspace do
    def remove_issue_workspaces(issue) do
      send(self(), {:remove_workspaces, issue.identifier})
      Application.get_env(:symphony_elixir, :restart_test_workspace, :ok)
    end
  end

  defmodule RaisingWorkspace do
    def remove_issue_workspaces(_issue), do: raise("workspace store is down")
  end

  defp issue(fields) do
    struct(
      %Issue{id: "issue-restart", identifier: "MT-RESTART", title: "Restart me", state: "Rework"},
      fields
    )
  end

  defp opts(extra \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", agent_kind: "claude")
    Keyword.merge([github: FakeGitHub, workspace: FakeWorkspace, settings: Config.settings!()], extra)
  end

  defp activity(fields), do: {:ok, Map.merge(%{pr_url: @pr_url, state: "OPEN"}, Map.new(fields))}

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :restart_test_activity)
      Application.delete_env(:symphony_elixir, :restart_test_close)
      Application.delete_env(:symphony_elixir, :restart_test_workspace)
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    :ok
  end

  describe "perform/2" do
    test "closes the ticket's open pull request, removes the workspace, then supersedes the workpad" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      assert :ok = Restart.perform(issue(pr_urls: [@pr_url]), opts())

      assert_received {:fetch_activity, @pr_url}
      assert_received {:close, @pr_url}
      assert_received {:remove_workspaces, "MT-RESTART"}
    end

    test "closes every open pull request on the ticket" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      assert :ok = Restart.perform(issue(pr_urls: [@pr_url, @other_pr_url]), opts())

      assert_received {:fetch_activity, @pr_url}
      assert_received {:close, @pr_url}
      assert_received {:fetch_activity, @other_pr_url}
      assert_received {:close, @other_pr_url}
    end

    test "a ticket with no pull request at all still resets" do
      for pr_urls <- [nil, []] do
        assert :ok = Restart.perform(issue(pr_urls: pr_urls), opts())
      end

      refute_received {:close, _pr_url}
      assert_received {:remove_workspaces, "MT-RESTART"}
    end

    test "an already-closed or merged pull request is left alone" do
      for state <- ["CLOSED", "closed", "MERGED", nil, 5] do
        Application.put_env(:symphony_elixir, :restart_test_activity, activity(state: state))

        assert :ok = Restart.perform(issue(pr_urls: [@pr_url]), opts())
        assert_received {:fetch_activity, @pr_url}
        refute_received {:close, _pr_url}
      end
    end

    test "a pull request entry that is not a URL stops the reset" do
      assert {:error, {:restart, message}} = Restart.perform(issue(pr_urls: [:nope]), opts())

      assert message == "the pull request :nope is not a URL"
      refute_received {:remove_workspaces, _identifier}
    end

    test "a pull request GitHub cannot read stops the reset before the workspace is touched" do
      Application.put_env(:symphony_elixir, :restart_test_activity, {:error, :gh_down})

      assert {:error, {:restart, message}} = Restart.perform(issue(pr_urls: [@pr_url]), opts())

      assert message == "couldn't read #{@pr_url} (:gh_down)"
      refute_received {:remove_workspaces, _identifier}
    end

    test "a pull request GitHub refuses to close stops the reset" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))
      Application.put_env(:symphony_elixir, :restart_test_close, {:error, :forbidden})

      assert {:error, {:restart, message}} = Restart.perform(issue(pr_urls: [@pr_url]), opts())

      assert message == "GitHub refused to close #{@pr_url} (:forbidden)"
      refute_received {:remove_workspaces, _identifier}
    end

    test "a workspace that cannot be removed stops the reset" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))
      Application.put_env(:symphony_elixir, :restart_test_workspace, {:error, :busy})

      assert {:error, {:restart, message}} = Restart.perform(issue(pr_urls: [@pr_url]), opts())

      assert message == "couldn't remove the workspace of MT-RESTART ({:error, :busy})"
    end

    test "a workspace that raises is reported as a failed step, not a crash" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      assert {:error, {:restart, message}} =
               Restart.perform(issue(pr_urls: [@pr_url]), opts(workspace: RaisingWorkspace))

      assert message == "couldn't remove the workspace of MT-RESTART (workspace store is down)"
    end
  end

  describe "the workpad supersession" do
    test "a ticket whose workpad cannot be superseded reports the step" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      opts =
        opts(
          settings: linear_settings(),
          linear_client: fn _query, _variables, _opts -> {:error, :comment_failed} end
        )

      assert {:error, {:restart, message}} = Restart.perform(issue(pr_urls: [@pr_url]), opts)

      assert message =~ "couldn't supersede the workpad of MT-RESTART"
    end

    test "a linear ticket's workpad is superseded after the workspace is gone" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      linear_client = fn query, variables, _opts ->
        cond do
          String.contains?(query, "SymphonyAgentIssueComments") ->
            send(self(), {:workpad_read, variables})

            {:ok,
             %{
               "data" => %{
                 "issue" => %{
                   "comments" => %{
                     "nodes" => [
                       %{
                         "id" => "comment-workpad",
                         "body" => "## Symphony Workpad\n\n### Plan\n\n- [x] The old attempt",
                         "user" => %{"name" => "Symphony"}
                       }
                     ]
                   }
                 }
               }
             }}

          String.contains?(query, "SymphonyAgentUpdateComment") ->
            send(self(), {:workpad_written, variables})
            {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
        end
      end

      assert :ok =
               Restart.perform(issue(pr_urls: [@pr_url]), opts(settings: linear_settings(), linear_client: linear_client))

      assert_received {:workpad_read, %{id: "issue-restart", limit: 100}}
      assert_received {:workpad_written, %{id: "comment-workpad", body: body}}
      assert body =~ "## Symphony Workpad"
      assert body =~ "### Superseded — attempt 1"
      assert body =~ "#### Plan"
      assert body =~ "A person restarted this ticket"
    end

    test "a linear ticket with no workpad comment is still reset" do
      Application.put_env(:symphony_elixir, :restart_test_activity, activity([]))

      linear_client = fn query, _variables, _opts ->
        if String.contains?(query, "SymphonyAgentIssueComments"),
          do: {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}},
          else: flunk("a ticket with no workpad must not have one written")
      end

      assert :ok =
               Restart.perform(issue(pr_urls: [@pr_url]), opts(settings: linear_settings(), linear_client: linear_client))

      assert_received {:remove_workspaces, "MT-RESTART"}
    end
  end

  defp linear_settings do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: "token", agent_kind: "claude")
    Config.settings!()
  end
end
