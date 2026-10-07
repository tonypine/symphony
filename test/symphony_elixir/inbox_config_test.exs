defmodule SymphonyElixir.InboxConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Inbox

  test "starts with the application only for a Linear tracker" do
    write_workflow_file!(Workflow.workflow_file_path())
    assert Inbox in SymphonyElixir.Application.child_specs_for_runtime(%{})

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    refute Inbox in SymphonyElixir.Application.child_specs_for_runtime(%{})
  end

  test "reads every Linear repository route in the scope it polls, on the poll interval, with Symphony's own CI and gate records" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: "cycle",
      poll_interval_ms: 12_345
    )

    test_pid = self()

    pr = %{
      "id" => "id-MT-1",
      "identifier" => "MT-1",
      "title" => "A PR",
      "url" => "https://linear.app/acme/issue/MT-1",
      "state" => %{"name" => "In Review"},
      "comments" => %{"nodes" => []},
      "history" => %{"nodes" => []}
    }

    linear_client = fn query, variables, _opts ->
      if query =~ "SymphonyInboxList" do
        send(test_pid, {:filter, variables.filter})
        {:ok, %{"data" => %{"issues" => %{"nodes" => [%{"id" => "id-MT-1", "updatedAt" => "2026-10-01T00:00:00Z"}]}}}}
      else
        {:ok, %{"data" => %{"issues" => %{"nodes" => [pr]}}}}
      end
    end

    name = {:test, make_ref()}
    server_state = %{opts: [name: name, linear_client: linear_client], nodes: %{}, timer: make_ref()}
    assert {:noreply, state} = Inbox.handle_info(:tick, server_state)

    assert_received {:filter, %{"and" => [%{"project" => %{"slugId" => %{"eq" => "cycle"}}}, %{"or" => _states}]}}
    assert [%{identifier: "MT-1", kind: :pr, review: %{pull_request: %{ci: nil, gate: nil}}}] = Inbox.cached(name)
    assert Process.read_timer(state.timer) in 12_000..12_345
  end
end
