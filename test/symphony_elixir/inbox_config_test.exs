defmodule SymphonyElixir.InboxConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Inbox

  test "starts with the application only for a Linear tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker())
    assert Inbox in SymphonyElixir.Application.child_specs_for_runtime(%{})
    assert SymphonyElixir.Initiatives in SymphonyElixir.Application.child_specs_for_runtime(%{})

    write_workflow_file!(Workflow.workflow_file_path())
    refute Inbox in SymphonyElixir.Application.child_specs_for_runtime(%{})
    refute SymphonyElixir.Initiatives in SymphonyElixir.Application.child_specs_for_runtime(%{})
  end

  test "reads every Linear repository route in the scope it polls, on the poll interval" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: "cycle",
        poll_interval_ms: 12_345
      )
    )

    test_pid = self()

    plan = %{
      "id" => "id-MT-1",
      "identifier" => "MT-1",
      "title" => "A plan",
      "url" => "https://linear.app/acme/issue/MT-1",
      "state" => %{"name" => "Plan Review"},
      "labels" => %{"nodes" => [%{"name" => "plan"}]},
      "comments" => %{"nodes" => []},
      "history" => %{"nodes" => []}
    }

    linear_client = fn query, variables, _opts ->
      if query =~ "SymphonyInboxList" do
        send(test_pid, {:filter, variables.filter})
        {:ok, %{"data" => %{"issues" => %{"nodes" => [%{"id" => "id-MT-1", "updatedAt" => "2026-10-01T00:00:00Z"}]}}}}
      else
        {:ok, %{"data" => %{"issues" => %{"nodes" => [plan]}}}}
      end
    end

    name = {:test, make_ref()}
    server_state = %{opts: [name: name, linear_client: linear_client], nodes: %{}, timer: make_ref()}
    assert {:noreply, state} = Inbox.handle_info(:tick, server_state)

    assert_received {:filter, %{"and" => [%{"project" => %{"slugId" => %{"eq" => "cycle"}}}, %{"or" => _states}]}}
    assert [%{identifier: "MT-1", kind: :plan, review: %{sub_tickets: []}}] = Inbox.cached(name)
    assert Process.read_timer(state.timer) in 12_000..12_345
  end

  test "the initiatives server reads every Linear repository route on the poll interval" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      linear_tracker(
        tracker_project_slug: "cycle",
        poll_interval_ms: 12_345
      )
    )

    test_pid = self()

    plan = %{
      "id" => "id-MT-1",
      "identifier" => "MT-1",
      "state" => %{"name" => "In Progress", "type" => "started"},
      "children" => %{"nodes" => []}
    }

    linear_client = fn _query, variables, _opts ->
      send(test_pid, {:filter, variables.filter})
      {:ok, %{"data" => %{"issues" => %{"nodes" => [plan], "pageInfo" => %{"hasNextPage" => false}}}}}
    end

    name = {:test, make_ref()}
    server_state = %{opts: [name: name, linear_client: linear_client], timer: make_ref()}
    assert {:noreply, state} = SymphonyElixir.Initiatives.handle_info(:tick, server_state)

    assert_received {:filter, %{"and" => [%{"project" => %{"slugId" => %{"eq" => "cycle"}}} | _rest]}}
    assert [%{identifier: "MT-1", group: "active"}] = SymphonyElixir.Initiatives.cached(name)
    assert Process.read_timer(state.timer) in 12_000..12_345
  end
end
