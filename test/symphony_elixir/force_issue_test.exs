defmodule SymphonyElixir.ForceIssueTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{ControlClient, ControlToken}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint
  @now ~U[2026-10-04 06:00:00.000000Z]

  defmodule FakeLinearClient do
    def fetch_issue_by_identifier(identifier) do
      send(self(), {:fetch_issue_by_identifier_called, identifier})
      Process.get({__MODULE__, :issue_result})
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})
      [result | rest] = Process.get({__MODULE__, :graphql_results})
      Process.put({__MODULE__, :graphql_results}, rest)
      result
    end
  end

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-force-#{System.unique_integer([:positive])}")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :audit_log_dir, Path.join(test_root, "audit"))

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :audit_log_dir, previous_audit_dir)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if previous_client,
        do: Application.put_env(:symphony_elixir, :linear_client_module, previous_client),
        else: Application.delete_env(:symphony_elixir, :linear_client_module)

      File.rm_rf(test_root)
    end)

    %{test_root: test_root}
  end

  describe "symphony force against a running Symphony" do
    setup ctx do
      memory_workflow!(ctx.test_root)
      {:ok, clock} = Agent.start_link(fn -> @now end)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      # An open blocker keeps the Todo tickets from being dispatched.
      blocker = %{id: "blocker-1", identifier: "MT-B1", state: "In Progress"}

      tracked([
        %{issue("id-1", "MT-1", "Todo", []) | blocked_by: [blocker]},
        %{issue("id-2", "MT-2", "Todo", ["bug"]) | blocked_by: [blocker]},
        issue("id-3", "MT-3", "Backlog", []),
        issue("id-4", "MT-4", "Done", []),
        %{issue("id-5", "MT-5", "Todo", []) | blocked_by: [blocker]}
      ])

      name = Module.concat(__MODULE__, :Orchestrator)
      {:ok, pid} = Orchestrator.start_link(name: name, clock: fn -> Agent.get(clock, & &1) end)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end)

      wait_until(fn ->
        state = :sys.get_state(pid)
        not state.poll_check_in_progress and is_nil(state.repo_poll_task_ref)
      end)

      start_test_endpoint(orchestrator: name)

      %{pid: pid, clock: clock}
    end

    test "forces a ticket, queues a second one behind it and clears it", %{pid: pid, clock: clock} do
      assert {{:halt, 0}, "MT-1 forced (slot 1 of 1)\n"} = force(["MT-1"])
      assert_received {:memory_tracker_label_added, "id-1", "expedite"}
      assert labels("id-1") == ["expedite"]
      assert %{"id-1" => %{forced_since: @now}} = :sys.get_state(pid).forced
      assert %{"id-1" => %{}} = RunStore.get_forced(Config.repo_key!())

      Agent.update(clock, &DateTime.add(&1, 60))
      assert {{:halt, 0}, "MT-2 forced (queued #2; MT-1 holds the forced slot)\n"} = force(["MT-2"])
      assert labels("id-2") == ["bug", "expedite"]

      # Forcing a ticket that already carries the label leaves Linear alone.
      assert {{:halt, 0}, "MT-1 forced (slot 1 of 1)\n"} = force(["MT-1"])
      refute_received {:memory_tracker_label_added, "id-1", _label}

      assert {{:halt, 0}, "MT-2 no longer forced\n"} = force(["--clear", "MT-2"])
      assert_received {:memory_tracker_label_removed, "id-2", "expedite"}
      assert labels("id-2") == ["bug"]
      assert Map.keys(:sys.get_state(pid).forced) == ["id-1"]

      # Clearing a ticket without the label changes nothing.
      assert {{:halt, 0}, "MT-2 no longer forced\n"} = force(["--clear", "MT-2"])
      refute_received {:memory_tracker_label_removed, "id-2", _label}

      assert {:ok, events} = SymphonyElixir.AuditLog.query(event_type: "forced_end")
      assert [%{"issue_identifier" => "MT-2", "reason" => "label_removed"}] = Enum.to_list(events)
    end

    test "says a Backlog ticket is not promoted and keeps it out of the queue", %{pid: pid} do
      assert {{:halt, 0}, "MT-3 forced (it is in Backlog; forcing doesn't promote it)\n"} = force(["MT-3"])
      assert labels("id-3") == ["expedite"]
      assert :sys.get_state(pid).forced == %{}
    end

    test "names every ticket holding the forced slots", %{clock: clock, test_root: test_root} do
      write_workflow_file!(Workflow.workflow_file_path(), memory_workflow_opts(test_root, forced_max: 2))

      assert {{:halt, 0}, "MT-1 forced (slot 1 of 2)\n"} = force(["MT-1"])
      Agent.update(clock, &DateTime.add(&1, 60))
      assert {{:halt, 0}, "MT-2 forced (slot 2 of 2)\n"} = force(["MT-2"])
      Agent.update(clock, &DateTime.add(&1, 60))
      assert {{:halt, 0}, "MT-5 forced (queued #3; MT-1 and MT-2 hold the forced slots)\n"} = force(["MT-5"])
    end

    test "an unknown, closed or failing ticket gives a clear message and a non-zero exit" do
      assert {{:error, "MT-404 was not found in Linear"}, ""} = force(["MT-404"])
      assert {{:error, "MT-4 is Done; only an open ticket can be forced"}, ""} = force(["MT-4"])

      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, :boom})
      assert {{:error, "Linear request failed: :boom"}, ""} = force(["MT-5"])

      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, {:error, {:label_not_found, "expedite"}})
      assert {{:error, "Linear has no expedite label; create it in Linear, then force again"}, ""} = force(["MT-5"])

      retry_ms = DateTime.to_unix(~U[2026-10-04 06:05:00.123Z], :millisecond)
      rate_limited = {:error, {:linear_rate_limited, retry_ms}}
      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, rate_limited)

      assert {{:error, "Linear is rate-limiting Symphony until 2026-10-04T06:05:00Z; try again then"}, ""} =
               force(["MT-5"])

      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, {:error, :boom})
      tracked([issue("id-6", "MT-6", "Todo", ["Expedite"])])
      assert {{:error, "Linear request failed: :boom"}, ""} = force(["--clear", "MT-6"])
      assert labels("id-6") == ["Expedite"]
      refute_received {:memory_tracker_label_added, _id, _label}
    end

    test "the control API needs the token and an identifier" do
      assert {{:error, "The running Symphony rejected the control token; check SYMPHONY_CONTROL_TOKEN"}, ""} =
               force(["MT-1"], "wrong-token")

      conn = post_force(%{"clear" => false}, control_token())
      assert conn.status == 422
      assert %{"error" => %{"code" => "invalid_request", "message" => "identifier is required"}} = json_response(conn, 422)
      assert labels("id-1") == []
    end

    test "the control API answers 503 while the orchestrator is down", %{pid: pid} do
      GenServer.stop(pid)

      assert {{:error, "Symphony's orchestrator is unavailable; try again once it has started"}, ""} = force(["MT-1"])
    end
  end

  describe "Orchestrator.force_issue/3 with the Linear adapter" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      server = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(server, :kill) end)
      %{server: server}
    end

    test "maps Linear's entity-not-found error to an unknown ticket", %{server: server} do
      Process.put({FakeLinearClient, :issue_result}, {:error, {:linear_graphql_errors, [%{"message" => "Entity not found: Issue"}]}})
      assert {:error, :issue_not_found} = Orchestrator.force_issue(server, "MT-404", false)
      assert_received {:fetch_issue_by_identifier_called, "MT-404"}

      other_error = {:linear_graphql_errors, [%{"message" => "Argument Validation Error"}, :not_a_map]}
      Process.put({FakeLinearClient, :issue_result}, {:error, other_error})
      assert {:error, ^other_error} = Orchestrator.force_issue(server, "MT-1", false)

      Process.put({FakeLinearClient, :issue_result}, {:error, {:linear_api_status, 500, "down"}})
      assert {:error, {:linear_api_status, 500, "down"}} = Orchestrator.force_issue(server, "MT-1", true)
    end

    test "is unavailable without a running orchestrator" do
      assert :unavailable = Orchestrator.force_issue(Module.concat(__MODULE__, :Missing), "MT-1", false)
    end
  end

  describe "Linear adapter labels" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      :ok
    end

    test "adds the team label, else the workspace label, and only when the issue lacks it" do
      labels = [label("workspace-label", nil), label("other-team-label", "team-2"), label("team-label", "team-1")]

      script([lookup([], labels), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}])
      assert :ok = Adapter.add_issue_label("issue-1", "Expedite")
      assert_received {:graphql_called, lookup_query, %{issueId: "issue-1", labelName: "Expedite"}}
      assert lookup_query =~ "eqIgnoreCase"
      assert_received {:graphql_called, add_query, %{issueId: "issue-1", labelId: "team-label"}}
      assert add_query =~ "issueAddLabel"

      script([lookup([], [label("workspace-label", nil)]), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => true}}}}])
      assert :ok = Adapter.add_issue_label("issue-1", "expedite")
      assert_received {:graphql_called, _lookup, _variables}
      assert_received {:graphql_called, _add, %{labelId: "workspace-label"}}

      script([lookup(["on-issue"], labels)])
      assert :ok = Adapter.add_issue_label("issue-1", "expedite")
      assert_received {:graphql_called, _lookup, _variables}
      refute_received {:graphql_called, _add, _variables}

      script([lookup([], [label("other-team-label", "team-2")])])
      assert {:error, {:label_not_found, "expedite"}} = Adapter.add_issue_label("issue-1", "expedite")

      script([lookup([], labels), {:ok, %{"data" => %{"issueAddLabel" => %{"success" => false}}}}])
      assert {:error, :issue_label_update_failed} = Adapter.add_issue_label("issue-1", "expedite")

      script([lookup([], labels), {:error, :boom}])
      assert {:error, :boom} = Adapter.add_issue_label("issue-1", "expedite")

      script([{:error, {:linear_rate_limited, 1}}])
      assert {:error, {:linear_rate_limited, 1}} = Adapter.add_issue_label("issue-1", "expedite")

      script([{:ok, %{"errors" => [%{"message" => "Entity not found: Issue"}], "data" => nil}}])
      assert {:error, :issue_label_lookup_failed} = Adapter.add_issue_label("issue-1", "expedite")
    end

    test "removes every matching label on the issue and stops at the first failure" do
      removed = {:ok, %{"data" => %{"issueRemoveLabel" => %{"success" => true}}}}

      script([lookup(["label-a", "label-b"], []), removed, removed])
      assert :ok = Adapter.remove_issue_label("issue-1", "expedite")
      assert_received {:graphql_called, _lookup, _variables}
      assert_received {:graphql_called, remove_query, %{issueId: "issue-1", labelId: "label-a"}}
      assert remove_query =~ "issueRemoveLabel"
      assert_received {:graphql_called, _remove, %{labelId: "label-b"}}

      script([lookup([], [])])
      assert :ok = Adapter.remove_issue_label("issue-1", "expedite")
      assert_received {:graphql_called, _lookup, _variables}
      refute_received {:graphql_called, _remove, _variables}

      script([lookup(["label-a", "label-b"], []), {:ok, %{"data" => %{}}}])
      assert {:error, :issue_label_update_failed} = Adapter.remove_issue_label("issue-1", "expedite")

      script([{:error, :boom}])
      assert {:error, :boom} = Adapter.remove_issue_label("issue-1", "expedite")
    end
  end

  describe "memory tracker labels" do
    test "edits the configured issues and reports scripted failures" do
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      tracked([issue("id-1", "MT-1", "Todo", ["Expedite"]), issue("id-2", "MT-2", "Todo", [])])

      assert :ok = Memory.add_issue_label("id-1", "expedite")
      assert labels("id-1") == ["Expedite"]
      assert :ok = Memory.add_issue_label("id-2", "expedite")
      assert labels("id-2") == ["expedite"]
      assert_received {:memory_tracker_label_added, "id-2", "expedite"}

      assert :ok = Memory.remove_issue_label("id-1", "EXPEDITE")
      assert labels("id-1") == []
      assert_received {:memory_tracker_label_removed, "id-1", "EXPEDITE"}

      Application.put_env(:symphony_elixir, :memory_tracker_add_issue_label_result, [{:error, :boom}])
      assert {:error, :boom} = Memory.add_issue_label("id-1", "expedite")
      assert labels("id-1") == []
      assert :ok = Memory.add_issue_label("id-1", "expedite")
      assert labels("id-1") == ["expedite"]
    end

    test "edits the issues file", %{test_root: test_root} do
      issues_file = Path.join(test_root, "issues.json")
      File.mkdir_p!(test_root)

      File.write!(
        issues_file,
        Jason.encode!([
          %{"id" => "id-1", "identifier" => "MT-1", "state" => "Todo", "labels" => ["bug", 7]},
          %{"id" => "id-2", "identifier" => "MT-2", "state" => "Todo"}
        ])
      )

      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_memory_issues_file: issues_file)

      assert :ok = Memory.add_issue_label("id-1", "expedite")
      assert {:ok, %Issue{labels: ["bug", "expedite"]}} = Memory.fetch_issue_by_identifier("MT-1")
      assert {:ok, %Issue{labels: []}} = Memory.fetch_issue_by_identifier("MT-2")

      assert :ok = Memory.remove_issue_label("id-1", "Expedite")
      assert {:ok, %Issue{labels: ["bug"]}} = Memory.fetch_issue_by_identifier("MT-1")

      # Without an issues file there is nothing to edit.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      assert :ok = Memory.add_issue_label("id-1", "expedite")
    end
  end

  defp force(args, token \\ nil) do
    token = token || control_token()

    deps = %{
      control_url: fn -> "http://symphony.test" end,
      force_issue: fn identifier, clear? ->
        ControlClient.force_issue(identifier, clear?,
          prefer_local?: false,
          control_url: "http://symphony.test",
          control_token: token,
          http_post: fn "http://symphony.test/api/v1/control/force", body, token ->
            conn = post_force(body, token)
            {:ok, conn.status, Jason.decode!(conn.resp_body)}
          end
        )
      end
    }

    parent = self()
    output = capture_io(fn -> send(parent, {:result, CLI.evaluate(["force" | args], deps)}) end)
    assert_received {:result, result}
    {result, output}
  end

  defp post_force(body, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/control/force", Jason.encode!(body))
  end

  # The bearer plug caches the daemon's token for the BEAM's lifetime.
  defp control_token do
    case :persistent_term.get(SymphonyElixirWeb.Plugs.BearerToken, :unresolved) do
      :unresolved -> ControlToken.current()
      token -> token
    end
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp memory_workflow!(test_root), do: write_workflow_file!(Workflow.workflow_file_path(), memory_workflow_opts(test_root, []))

  defp memory_workflow_opts(test_root, overrides) do
    Keyword.merge(
      [
        tracker_kind: "memory",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Canceled"],
        workspace_root: Path.join(test_root, "workspaces")
      ],
      overrides
    )
  end

  defp script(results), do: Process.put({FakeLinearClient, :graphql_results}, results)

  defp lookup(on_issue, labels) do
    {:ok,
     %{
       "data" => %{
         "issue" => %{"team" => %{"id" => "team-1"}, "labels" => %{"nodes" => Enum.map(on_issue, &%{"id" => &1})}},
         "issueLabels" => %{"nodes" => labels}
       }
     }}
  end

  defp label(id, nil), do: %{"id" => id, "team" => nil}
  defp label(id, team_id), do: %{"id" => id, "team" => %{"id" => team_id}}

  defp labels(issue_id) do
    :symphony_elixir
    |> Application.fetch_env!(:memory_tracker_issues)
    |> Enum.find(&(&1.id == issue_id))
    |> Map.fetch!(:labels)
  end

  defp tracked(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp issue(id, identifier, state, labels) do
    %Issue{id: id, identifier: identifier, title: "Ticket #{identifier}", state: state, labels: labels, team: %{key: "Test"}}
  end

  defp wait_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(25)
        do_wait_until(fun, deadline)
    end
  end
end
