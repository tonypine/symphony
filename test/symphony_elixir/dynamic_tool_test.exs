defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config.Schema

  test "tool_specs advertises scoped Linear tools and not raw GraphQL" do
    tool_names = Enum.map(DynamicTool.tool_specs(), & &1["name"])

    assert "linear_get_current_issue" in tool_names
    assert "linear_update_state" in tool_names
    assert "linear_attach_file" in tool_names
    assert "github_get_pull_request" in tool_names
    assert "github_fetch_origin" in tool_names
    assert "github_create_pull_request" in tool_names
    assert "github_reply_to_review_comment" in tool_names
    assert "github_push_branch" in tool_names
    assert "github_merge_pull_request" in tool_names
    assert "github_get_pr_checks" in tool_names
    assert "github_list_pr_comments" in tool_names
    assert "github_list_pr_review_comments" in tool_names
    assert "github_list_pr_reviews" in tool_names
    assert "github_get_failed_run_log" in tool_names
    refute "linear_graphql" in tool_names
    refute "linear_set_assignee" in tool_names
    refute "linear.get_current_issue" in tool_names
    refute "linear.set_assignee" in tool_names
    refute "github.get_pull_request" in tool_names

    assert Enum.all?(tool_names, &Regex.match?(~r/^[a-zA-Z0-9_-]+$/, &1))

    assert Enum.all?(DynamicTool.tool_specs(), fn spec ->
             get_in(spec, ["inputSchema", "additionalProperties"]) == false
           end)

    assert %{
             "inputSchema" => %{
               "properties" => %{
                 "make_public" => %{"type" => "boolean", "default" => false, "description" => make_public_description}
               }
             }
           } = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "linear_attach_file"))

    assert make_public_description =~ "world-readable"
  end

  test "unsupported raw linear_graphql returns tool_not_found" do
    response = DynamicTool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "tool_not_found",
               "supportedTools" => supported_tools
             }
           } = Jason.decode!(response["output"])

    refute "linear_graphql" in supported_tools
  end

  test "removed linear_set_assignee tool and legacy alias return tool_not_found" do
    for tool <- ["linear_set_assignee", "linear.set_assignee"] do
      response = DynamicTool.execute(tool, %{"assignee" => "self"})

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "tool_not_found",
                 "supportedTools" => supported_tools
               }
             } = Jason.decode!(response["output"])

      refute "linear_set_assignee" in supported_tools
      refute "linear.set_assignee" in supported_tools
    end
  end

  test "update_state resolves against the current issue team and updates current issue only" do
    test_pid = self()
    issue = %Issue{id: "issue-current", identifier: "ACME-1"}

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Progress"},
        issue: issue,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            query =~ "SymphonyAgentIssueTeamStates" ->
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "team" => %{
                       "states" => %{
                         "nodes" => [
                           %{"id" => "state-started", "name" => "In Progress", "type" => "started"}
                         ]
                       }
                     }
                   }
                 }
               }}

            query =~ "SymphonyAgentUpdateIssueState" ->
              {:ok,
               %{
                 "data" => %{
                   "issueUpdate" => %{
                     "success" => true,
                     "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
                   }
                 }
               }}
          end
        end
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current"}, []}
    assert query =~ "SymphonyAgentIssueTeamStates"
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: "state-started"}, []}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "update_state returns state_not_found with available states when name is unknown" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Shipped"},
        issue: %Issue{id: "issue-current"},
        linear_client: fn query, _variables, _opts ->
          true = query =~ "SymphonyAgentIssueTeamStates"

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "team" => %{
                   "states" => %{
                     "nodes" => [
                       %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"},
                       %{"id" => "state-2", "name" => "In Progress", "type" => "started"},
                       %{"id" => "state-3", "name" => "Done", "type" => "completed"}
                     ]
                   }
                 }
               }
             }
           }}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "state_not_found",
               "available_states" => ["Todo", "In Progress", "Done"]
             }
           } = Jason.decode!(response["output"])
  end

  test "update_state skips team introspection when given a UUID state id" do
    test_pid = self()
    state_uuid = "11111111-2222-3333-4444-555555555555"

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => state_uuid},
        issue: %Issue{id: "issue-current"},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:linear_client_called, query, variables})

          if query =~ "SymphonyAgentIssueTeamStates" do
            flunk("team states introspection should be skipped for UUID state ids")
          end

          {:ok,
           %{
             "data" => %{
               "issueUpdate" => %{
                 "success" => true,
                 "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
               }
             }
           }}
        end
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: ^state_uuid}}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "add_comment surfaces commentCreate success=false from Linear as a failure" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "blocked"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => false, "comment" => nil}}}}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "linear_mutation_failed",
               "field" => "commentCreate"
             }
           } = Jason.decode!(response["output"])

    refute CommentRegistry.owned?(registry, "any-id")
  end

  test "legacy dotted tool aliases are accepted but still reject smuggled issue ids" do
    response =
      DynamicTool.execute(
        "linear.update_state",
        %{"issue_id" => "issue-other", "state_name_or_id" => "Done"},
        issue: %Issue{id: "issue-current"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected"}} =
             Jason.decode!(response["output"])
  end

  test "add_comment records ownership and update_comment allows owned comments" do
    {:ok, registry} = CommentRegistry.start_link()
    test_pid = self()

    add_response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "first"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-owned", "body" => variables.body, "url" => "https://linear/comment"}
               }
             }
           }}
        end
      )

    assert add_response["success"] == true
    add_comment = get_in(Jason.decode!(add_response["output"]), ["data", "commentCreate", "comment"])
    refute Map.has_key?(add_comment, "body")
    assert add_comment["bodyLength"] == String.length("first")
    assert CommentRegistry.owned?(registry, "comment-owned")

    update_response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-owned", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentUpdate" => %{
                 "success" => true,
                 "comment" => %{"id" => variables.id, "body" => variables.body}
               }
             }
           }}
        end
      )

    assert update_response["success"] == true
    update_comment = get_in(Jason.decode!(update_response["output"]), ["data", "commentUpdate", "comment"])
    refute Map.has_key?(update_comment, "body")
    assert update_comment["bodyLength"] == String.length("edited")
    assert_received {:linear_client_called, query, %{id: "comment-owned", body: "edited"}, []}
    assert query =~ "SymphonyAgentUpdateComment"
  end

  test "add_comment logs a warning when Linear response omits the expected comment shape" do
    {:ok, registry} = CommentRegistry.start_link()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response =
          DynamicTool.execute(
            "linear_add_comment",
            %{"body" => "shape-drift"},
            issue: %Issue{id: "issue-current", identifier: "MT-DRIFT"},
            comment_registry: registry,
            linear_client: fn _query, _variables, _opts ->
              # success=true with no `comment` key — a plausible API drift shape that previously
              # passed through compact_comment_mutation_response/2 silently and would leak the
              # full body back into the Codex stream if the body key ever moved.
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
            end
          )

        assert response["success"] == true
        decoded = Jason.decode!(response["output"])
        refute get_in(decoded, ["data", "commentCreate", "comment"])
      end)

    assert log =~ "comment-body compaction skipped"
    assert log =~ "commentCreate"
    assert log =~ ~s(issue_identifier="MT-DRIFT")
  end

  test "add_comment tolerates Linear response with data=nil without raising" do
    {:ok, registry} = CommentRegistry.start_link()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response =
          DynamicTool.execute(
            "linear_add_comment",
            %{"body" => "nil-data"},
            issue: %Issue{id: "issue-current", identifier: "MT-NIL"},
            comment_registry: registry,
            linear_client: fn _query, _variables, _opts ->
              # Linear can return data=nil when check_mutation_success treats a missing
              # `success` field as success — the warning branch must not crash on it.
              {:ok, %{"data" => nil}}
            end
          )

        assert response["success"] == true
      end)

    assert log =~ "comment-body compaction skipped"
    assert log =~ "data_keys=[]"
    assert log =~ ~s(issue_identifier="MT-NIL")
  end

  test "update_comment rejects comments not created in this run" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-other", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for unowned comments")
        end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => ":comment_not_owned_by_run"}} =
             Jason.decode!(response["output"])
  end

  test "attach_file rejects paths outside the workspace before upload" do
    test_root = Path.join(System.tmp_dir!(), "linear-attach-file-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    outside = Path.join(test_root, "outside.txt")

    try do
      File.mkdir_p!(workspace)
      File.write!(outside, "outside")

      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => outside, "title" => "outside"},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for outside paths")
          end
        )

      assert response["success"] == false

      assert %{"error" => %{"code" => ":path_outside_workspace"}} =
               Jason.decode!(response["output"])
    after
      File.rm_rf(test_root)
    end
  end

  test "attach_file uploads privately by default" do
    workspace = tmp_workspace!("linear-attach-file-private")
    path = Path.join(workspace, "screenshot.png")
    File.write!(path, "png")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "title" => "Screenshot"},
          successful_attach_file_opts(workspace, test_pid)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "screenshot.png", size: 3, contentType: "image/png", makePublic: false}}

      assert_received {:file_uploaded, "https://linear-upload.example", [headers: [{"x-upload", "1"}, {"content-type", "image/png"}], body: "png"]}

      assert_received {:attachment_created, %{issueId: "issue-current", url: "https://linear-asset.example/screenshot.png", title: "Screenshot"}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file supports explicit public upload opt-in" do
    workspace = tmp_workspace!("linear-attach-file-public")
    path = Path.join(workspace, "screenshot.png")
    File.write!(path, "png")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "title" => "Screenshot", "make_public" => true},
          successful_attach_file_opts(workspace, test_pid)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "screenshot.png", size: 3, makePublic: true}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects public uploads for extensions outside the allowlist" do
    workspace = tmp_workspace!("linear-attach-file-public-extension")

    disallowed_files = [
      {"notes.txt", ".txt"},
      {"data.json", ".json"},
      {"output", ""},
      {"screenshot.png.txt", ".txt"}
    ]

    try do
      Enum.each(disallowed_files, fn {filename, expected_extension} ->
        path = Path.join(workspace, filename)
        File.write!(path, "ordinary proof")

        response =
          DynamicTool.execute(
            "linear_attach_file",
            %{"local_path" => path, "make_public" => true},
            issue: %Issue{id: "issue-current"},
            workspace: workspace,
            linear_client: fn _query, _variables, _opts ->
              flunk("linear client should not be called for denied public extension")
            end,
            upload_client: fn _url, _opts ->
              flunk("disallowed public extensions should not be uploaded")
            end
          )

        assert response["success"] == false

        assert %{
                 "error" => %{
                   "code" => "public_extension_not_allowed",
                   "extension" => ^expected_extension
                 }
               } = Jason.decode!(response["output"])
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file applies configured public upload extension overrides" do
    workspace = tmp_workspace!("linear-attach-file-public-extension-override")
    path = Path.join(workspace, "diagnostic.log")
    File.write!(path, "ordinary proof")
    test_pid = self()

    settings = %Schema{
      workspace: %Schema.Workspace{
        attachments: %Schema.Workspace.Attachments{public_upload_extensions: [".png", ".log"]}
      }
    }

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          successful_attach_file_opts(workspace, test_pid)
          |> Keyword.put(:settings, settings)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "diagnostic.log", makePublic: true}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file private uploads are not constrained by the public size cap" do
    workspace = tmp_workspace!("linear-attach-file-private-size")
    path = Path.join(workspace, "artifact.txt")
    File.write!(path, "123456")
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path},
          successful_attach_file_opts(workspace, test_pid)
          |> Keyword.put(:max_public_upload_bytes, 5)
        )

      assert response["success"] == true
      assert_received {:file_upload_requested, %{filename: "artifact.txt", size: 6, makePublic: false}}
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects public uploads for sensitive basenames before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-sensitive")
    path = Path.join(workspace, ".env")
    File.write!(path, "TOKEN=secret")

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for denied public sensitive upload")
          end
        )

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "public_upload_denied_sensitive_filename",
                 "filename" => ".env"
               }
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file rejects private uploads for sensitive basenames before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-private-sensitive")

    sensitive_files = [
      {".env.local", "private_upload_denied_sensitive_filename"},
      {"deploy.pem", "private_upload_denied_sensitive_filename"},
      {"deploy.key", "private_upload_denied_sensitive_filename"}
    ]

    try do
      Enum.each(sensitive_files, fn {filename, expected_code} ->
        path = Path.join(workspace, filename)
        File.write!(path, "ordinary test fixture")

        response =
          DynamicTool.execute(
            "linear_attach_file",
            %{"local_path" => path},
            issue: %Issue{id: "issue-current"},
            workspace: workspace,
            linear_client: fn _query, _variables, _opts ->
              flunk("linear client should not be called for denied private sensitive upload")
            end,
            upload_client: fn _url, _opts ->
              flunk("sensitive private files should not be uploaded")
            end
          )

        assert response["success"] == false

        assert %{
                 "error" => %{
                   "code" => ^expected_code,
                   "filename" => ^filename
                 }
               } = Jason.decode!(response["output"])
      end)
    after
      File.rm_rf(workspace)
    end
  end

  test "attach_file enforces the public upload size cap before requesting an upload" do
    workspace = tmp_workspace!("linear-attach-file-size")
    path = Path.join(workspace, "large.png")
    File.write!(path, "123456")

    try do
      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => path, "make_public" => true},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          max_public_upload_bytes: 5,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for oversized public upload")
          end
        )

      assert response["success"] == false

      assert %{
               "error" => %{
                 "code" => "file_upload_too_large",
                 "actual_bytes" => 6,
                 "max_bytes" => 5,
                 "make_public" => true
               }
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.create_pull_request uses current branch and configured origin repo" do
    workspace = tmp_workspace!("github-create-pr")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        [
          "pr",
          "create",
          "--repo",
          "acme/symphony",
          "--head",
          "auto/ACME-3051",
          "--title",
          "Add tools",
          "--body",
          "Body",
          "--draft"
        ],
        opts ->
          assert opts[:cd] == workspace
          {"https://github.com/acme/symphony/pull/3051\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_create_pull_request",
          %{"title" => "Add tools", "body" => "Body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/acme/symphony/pull/3051",
               "repo" => "acme/symphony",
               "head" => "auto/ACME-3051"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.create_pull_request rejects smuggled repo arguments" do
    response =
      DynamicTool.execute(
        "github_create_pull_request",
        %{"title" => "Add tools", "body" => "Body", "repo" => "attacker/repo"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "acme/symphony"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected", "message" => message}} =
             Jason.decode!(response["output"])

    assert message =~ "configured origin"
  end

  test "github tools reject smuggled branch and remote arguments" do
    for {tool, args} <- [
          {"github_create_pull_request", %{"title" => "Add tools", "body" => "Body", "head" => "owned"}},
          {"github_get_pull_request", %{"branch" => "owned"}},
          {"github_fetch_origin", %{"refspec" => "main:refs/heads/owned"}},
          {"github_add_pr_comment", %{"body" => "Looks good", "remote" => "evil"}},
          {"github_reply_to_review_comment", %{"comment_id" => 123, "body" => "Acked.", "repo" => "attacker/repo"}},
          {"github_get_pr_checks", %{"base" => "owned"}},
          {"github_list_pr_comments", %{"repo" => "attacker/repo"}},
          {"github_list_pr_review_comments", %{"repository" => "attacker/repo"}},
          {"github_list_pr_reviews", %{"current_branch" => "owned"}},
          {"github_get_failed_run_log", %{"ref" => "owned"}}
        ] do
      response =
        DynamicTool.execute(
          tool,
          args,
          workspace: System.tmp_dir!(),
          command_security: %{origin_repo: "acme/symphony"}
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end
  end

  test "github.push_branch rejects smuggled refspec arguments" do
    response =
      DynamicTool.execute(
        "github_push_branch",
        %{"refspec" => "main:refs/heads/owned"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "acme/symphony"}
      )

    assert response["success"] == false
    assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
  end

  test "github.push_branch pushes origin current branch only" do
    workspace = tmp_workspace!("github-push-branch")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}

        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["push", "origin", "auto/ACME-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/ACME-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github_merge_pull_request merges through the scoped GitHub tool" do
    workspace = tmp_workspace!("github-merge-pull-request")

    try do
      response =
        DynamicTool.execute(
          "github_merge_pull_request",
          %{},
          merge_tool_opts(workspace, "Merging", [%{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "SUCCESS"}])
        )

      assert response["success"] == true
      assert %{"merged" => true, "head_sha" => "abc123"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github_merge_pull_request explains each refusal to the agent" do
    workspace = tmp_workspace!("github-merge-pull-request-refusals")

    try do
      failing_check = %{"name" => "mix test", "status" => "COMPLETED", "conclusion" => "FAILURE"}

      unapproved = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "In Review", []))
      assert %{"error" => %{"code" => "issue_not_in_merging_state", "message" => message}} = Jason.decode!(unapproved["output"])
      assert message =~ ~s("In Review")

      failing = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "Merging", [failing_check]))
      assert %{"error" => %{"code" => "checks_not_passing", "reason" => reason}} = Jason.decode!(failing["output"])
      assert reason =~ "mix test"

      closed = DynamicTool.execute("github_merge_pull_request", %{}, merge_tool_opts(workspace, "Merging", [], "CLOSED"))
      assert %{"error" => %{"code" => "pull_request_not_open", "message" => message}} = Jason.decode!(closed["output"])
      assert message =~ ~s("CLOSED")
    after
      File.rm_rf(workspace)
    end
  end

  test "github.fetch_origin fetches the scoped origin only" do
    workspace = tmp_workspace!("github-fetch-origin")

    try do
      git_runner = fn
        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["fetch", "origin"], opts ->
          assert opts[:cd] == workspace
          {"fetched\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_fetch_origin",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "output" => "fetched"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "legacy dotted github aliases are accepted but not advertised" do
    workspace = tmp_workspace!("github-legacy-alias")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}

        ["remote", "get-url", "origin"], opts ->
          assert opts[:cd] == workspace
          {"git@github.com:acme/symphony.git\n", 0}

        ["push", "origin", "auto/ACME-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github.push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/ACME-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pull_request resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => "https://github.com/acme/symphony/pull/3051",
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pull_request",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/acme/symphony/pull/3051",
               "headRefName" => "auto/ACME-3051",
               "baseRefName" => "main"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pull_request uses captured remote metadata without local workspace access" do
    remote_workspace = "/remote/workspaces/MT-3187"

    gh_runner = fn
      ["pr", "view", "auto/ACME-3187", "--repo", "acme/symphony", "--json", fields], opts ->
        refute Keyword.has_key?(opts, :cd)
        assert fields == "number,state,title,body,url,headRefName,baseRefName"

        {Jason.encode!(%{
           "number" => 3187,
           "state" => "OPEN",
           "title" => "Remote PR",
           "body" => "Body",
           "url" => "https://github.com/acme/symphony/pull/3187",
           "headRefName" => "auto/ACME-3187",
           "baseRefName" => "main"
         }), 0}
    end

    git_runner = fn _args, _opts -> flunk("remote dynamic GitHub tools should not run local git") end

    response =
      DynamicTool.execute(
        "github_get_pull_request",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        },
        gh_runner: gh_runner,
        git_runner: git_runner
      )

    assert response["success"] == true
    assert %{"url" => "https://github.com/acme/symphony/pull/3187"} = Jason.decode!(response["output"])
  end

  test "github.push_branch returns a clear unsupported error for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    response =
      DynamicTool.execute(
        "github_push_branch",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        }
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "unsupported_for_ssh_worker",
               "message" => message
             }
           } = Jason.decode!(response["output"])

    assert message =~ "github_push_branch is not supported for SSH worker sessions"
  end

  test "github.fetch_origin returns a clear unsupported error for ssh workers" do
    remote_workspace = "/remote/workspaces/MT-3187"

    response =
      DynamicTool.execute(
        "github_fetch_origin",
        %{},
        workspace: remote_workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_url: "git@github.com:acme/symphony.git",
          current_branch: "auto/ACME-3187",
          workspace: remote_workspace,
          worker_host: "worker-01"
        }
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "unsupported_for_ssh_worker",
               "message" => message
             }
           } = Jason.decode!(response["output"])

    assert message =~ "github_fetch_origin is not supported for SSH worker sessions"
  end

  test "github.update_pull_request_body resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-update-pr-body")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Old body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "edit", ^pr_url, "--body", "New body"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_update_pull_request_body",
          %{"body" => "New body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.add_pr_comment resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-add-pr-comment")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "comment", ^pr_url, "--body", "Validation passed"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_add_pr_comment",
          %{"body" => "Validation passed"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment posts under the named inline thread" do
    workspace = tmp_workspace!("github-reply-review-comment")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Acked."], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!(%{"id" => 4242, "html_url" => "#{pr_url}#discussion_r4242"}), 0}
      end

      response =
        DynamicTool.execute(
          "github_reply_to_review_comment",
          %{"comment_id" => 123, "body" => "Acked."},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "pr_url" => ^pr_url,
               "comment_id" => "123",
               "reply_id" => 4242,
               "url" => reply_url
             } = Jason.decode!(response["output"])

      assert reply_url == "#{pr_url}#discussion_r4242"
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment surfaces invalid_comment_id without contacting gh" do
    workspace = tmp_workspace!("github-reply-review-comment-invalid-id")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid comment ids") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid comment ids") end

      for bad <- ["", "   ", "abc", 0] do
        response =
          DynamicTool.execute(
            "github_reply_to_review_comment",
            %{"comment_id" => bad, "body" => "Acked."},
            github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
          )

        assert response["success"] == false
        assert %{"error" => %{"code" => "invalid_comment_id"}} = Jason.decode!(response["output"])
      end
    after
      File.rm_rf(workspace)
    end
  end

  test "github.reply_to_review_comment surfaces invalid_body without contacting gh" do
    workspace = tmp_workspace!("github-reply-review-comment-invalid-body")

    try do
      gh_runner = fn _args, _opts -> flunk("gh should not run for invalid body") end
      git_runner = fn _args, _opts -> flunk("git should not run for invalid body") end

      response =
        DynamicTool.execute(
          "github_reply_to_review_comment",
          %{"comment_id" => 123, "body" => nil},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "invalid_body"}} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "legacy github.reply_to_review_comment dotted alias dispatches the new tool" do
    workspace = tmp_workspace!("github-reply-review-comment-legacy-alias")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["api", "repos/acme/symphony/pulls/3051/comments/123/replies", "-f", "body=Hi"], _opts ->
          {Jason.encode!(%{"id" => 4242, "html_url" => "#{pr_url}#discussion_r4242"}), 0}
      end

      response =
        DynamicTool.execute(
          "github.reply_to_review_comment",
          %{"comment_id" => 123, "body" => "Hi"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"reply_id" => 4242} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pr_checks resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr-checks")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "__typename" => "CheckRun",
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/1"
               }
             ]
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pr_checks",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "pr_url" => ^pr_url,
               "commit_sha" => "abc123",
               "checks" => [%{"name" => "mix test", "conclusion" => "SUCCESS"}]
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github feedback read tools resolve the current branch PR server-side" do
    workspace = tmp_workspace!("github-feedback-read-tools")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/issues/3051/comments"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_issue_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/comments"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_review_comment(pr_url)]]), 0}

        ["api", "--paginate", "--slurp", "repos/acme/symphony/pulls/3051/reviews"], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!([[github_review_summary(pr_url)]]), 0}
      end

      comments =
        DynamicTool.execute(
          "github_list_pr_comments",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      review_comments =
        DynamicTool.execute(
          "github_list_pr_review_comments",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      reviews =
        DynamicTool.execute(
          "github_list_pr_reviews",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert comments["success"] == true
      assert %{"comments" => [%{"body" => "Top-level note."}]} = Jason.decode!(comments["output"])

      assert review_comments["success"] == true

      assert %{"comments" => [%{"path" => "lib/example.ex", "position" => 8, "review_id" => "987"}]} =
               Jason.decode!(review_comments["output"])

      assert reviews["success"] == true
      assert %{"reviews" => [%{"state" => "APPROVED", "author" => "reviewer"}]} = Jason.decode!(reviews["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_failed_run_log returns a configured length-clamped excerpt" do
    workspace = tmp_workspace!("github-failed-run-log")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/ACME-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "FAILURE",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}

        ["run", "view", "987", "--log-failed"], _opts ->
          {"0123456789abcdef", 0}
      end

      settings = %Schema{github: %Schema.GitHub{failed_run_log_max_bytes: 10}}

      response =
        DynamicTool.execute(
          "github_get_failed_run_log",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner, settings: settings)
        )

      assert response["success"] == true

      assert %{"run_id" => "987", "log" => "0123456789", "truncated" => true, "max_bytes" => 10} =
               Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_failed_run_log surfaces no failed run cleanly" do
    workspace = tmp_workspace!("github-no-failed-run-log")

    try do
      pr_url = "https://github.com/acme/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "url" => pr_url}), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefName,headRefOid,isCrossRepository,headRepository,statusCheckRollup"], _opts ->
          {Jason.encode!(%{
             "url" => pr_url,
             "statusCheckRollup" => [
               %{
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/acme/symphony/actions/runs/987/jobs/654"
               }
             ]
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_failed_run_log",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "no_failed_github_actions_run"}} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp successful_attach_file_opts(workspace, test_pid) do
    [
      issue: %Issue{id: "issue-current"},
      workspace: workspace,
      linear_client: fn query, variables, _opts ->
        cond do
          query =~ "SymphonyAgentFileUpload" ->
            send(test_pid, {:file_upload_requested, variables})

            {:ok,
             %{
               "data" => %{
                 "fileUpload" => %{
                   "success" => true,
                   "uploadFile" => %{
                     "uploadUrl" => "https://linear-upload.example",
                     "assetUrl" => "https://linear-asset.example/#{variables.filename}",
                     "headers" => [%{"key" => "x-upload", "value" => "1"}]
                   }
                 }
               }
             }}

          query =~ "SymphonyAgentAttachFile" ->
            send(test_pid, {:attachment_created, variables})

            {:ok,
             %{
               "data" => %{
                 "attachmentCreate" => %{
                   "success" => true,
                   "attachment" => %{"id" => "attachment-id"}
                 }
               }
             }}
        end
      end,
      upload_client: fn upload_url, opts ->
        send(test_pid, {:file_uploaded, upload_url, opts})
        {:ok, %{status: 200, body: ""}}
      end
    ]
  end

  defp merge_tool_opts(workspace, issue_state_name, status_check_rollup, pr_state \\ "OPEN") do
    pr_url = "https://github.com/acme/symphony/pull/3051"

    git_runner = fn ["branch", "--show-current"], _opts -> {"auto/ACME-3051\n", 0} end

    gh_runner = fn
      ["pr", "view", "auto/ACME-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "title" => "Add tools", "body" => "Body", "url" => pr_url}), 0}

      ["pr", "view", ^pr_url, "--json", _fields], _opts ->
        {Jason.encode!(%{"state" => pr_state, "url" => pr_url, "headRefOid" => "abc123", "statusCheckRollup" => status_check_rollup}), 0}

      ["pr", "merge", ^pr_url, "--squash", "--match-head-commit", "abc123" | _rest], _opts ->
        {"", 0}
    end

    linear_client = fn _query, _variables, _opts ->
      {:ok, %{"data" => %{"issue" => %{"id" => "issue-3051", "state" => %{"name" => issue_state_name}}}}}
    end

    workspace
    |> github_tool_opts(git_runner: git_runner, gh_runner: gh_runner, linear_client: linear_client)
    |> Keyword.put(:issue_id, "issue-3051")
  end

  defp github_tool_opts(workspace, opts) do
    opts
    |> Keyword.put(:workspace, workspace)
    |> Keyword.put(:command_security, %{
      origin_repo: "acme/symphony",
      origin_url: "git@github.com:acme/symphony.git",
      workspace: workspace
    })
  end

  defp github_issue_comment(pr_url) do
    %{
      "id" => 11,
      "user" => %{"login" => "maintainer"},
      "body" => "Top-level note.",
      "html_url" => "#{pr_url}#issuecomment-11"
    }
  end

  defp github_review_comment(pr_url) do
    %{
      "id" => 22,
      "user" => %{"login" => "reviewer"},
      "body" => "Inline note.",
      "html_url" => "#{pr_url}#discussion_r22",
      "path" => "lib/example.ex",
      "position" => 8,
      "pull_request_review_id" => 987
    }
  end

  defp github_review_summary(pr_url) do
    %{
      "id" => 987,
      "user" => %{"login" => "reviewer"},
      "body" => "Looks good.",
      "html_url" => "#{pr_url}#pullrequestreview-987",
      "state" => "APPROVED"
    }
  end
end
