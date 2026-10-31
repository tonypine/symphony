defmodule SymphonyElixir.InboxConfigTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.{Inbox, Pauses, TicketState}
  alias SymphonyElixir.Inbox.References

  test "no Inbox server starts with the application: the Inbox is read from the records" do
    write_workflow_file!(Workflow.workflow_file_path(), linear_tracker())
    specs = SymphonyElixir.Application.child_specs_for_runtime(%{})
    refute Enum.any?(specs, &match?(Inbox, &1))
    refute Enum.any?(specs, &match?({Inbox, _opts}, &1))
    assert SymphonyElixir.Initiatives in specs

    write_workflow_file!(Workflow.workflow_file_path())
    refute SymphonyElixir.Initiatives in SymphonyElixir.Application.child_specs_for_runtime(%{})
  end

  test "over a memory tracker's issues file the initiatives server does not start" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_memory_issues_file: "issues.json")
    refute SymphonyElixir.Initiatives in SymphonyElixir.Application.child_specs_for_runtime(%{})

    settings = Config.settings!()
    assert Inbox.enabled?(settings, :memory)
    refute Inbox.enabled?(settings)
  end

  describe "the Inbox over the configured repositories" do
    setup do
      :ok = RunStore.clear()
      key = {References, :github_repos}
      previous = :persistent_term.get(key, nil)

      on_exit(fn ->
        RunStore.clear()
        if previous, do: :persistent_term.put(key, previous), else: :persistent_term.erase(key)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), linear_tracker())
      :ok
    end

    defp pause_reason, do: %{kind: :environment, waits_on: %{condition: "the registry token"}, text: "Waits on #7", releasable: true}

    test "lists a configured repository's records with its settings, and leaves out a record of a repository no longer configured" do
      repo_key = Config.repo_key!()

      for {repo, id} <- [{repo_key, "id-MT-1"}, {"gone", "id-MT-2"}] do
        :ok = RunStore.put_ticket_state(TicketState.new(repo, id, %{issue_identifier: String.replace(id, "id-", "")}))
        {:ok, _pause} = Pauses.set({:ticket, repo, id}, pause_reason())
      end

      assert [%{identifier: "MT-1", kind: :blocked}] = Inbox.items(%{})
      assert [%{identifier: "MT-1"}] = Inbox.rows()
    end

    test "reads each repo's GitHub repository once, and again when the repos change" do
      {:ok, repos} = Config.repos()
      repo_key = Config.repo_key!()
      :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "id-MT-3", %{issue_identifier: "MT-3"}))
      {:ok, _pause} = Pauses.set({:ticket, repo_key, "id-MT-3"}, pause_reason())
      inbox = [name: {:test, make_ref()}, pull_request: &{:error, {:unread, &1}}]

      :persistent_term.put({References, :github_repos}, {:stale, %{repo_key => "acme/stale"}})
      capture_log(fn -> Inbox.items(%{}, inbox) end)
      assert {^repos, github_repos} = :persistent_term.get({References, :github_repos})
      refute github_repos[repo_key] == "acme/stale"

      :persistent_term.put({References, :github_repos}, {repos, %{repo_key => "acme/app"}})
      assert [%{references: %{"#7" => %{url: "https://github.com/acme/app/pull/7"}}}] = capture_log_result(fn -> Inbox.items(%{}, inbox) end)
    end

    test "resolves no pull request when the configuration can't be read" do
      repo_key = Config.repo_key!()
      :ok = RunStore.put_ticket_state(TicketState.new(repo_key, "id-MT-4", %{issue_identifier: "MT-4"}))
      {:ok, _pause} = Pauses.set({:ticket, repo_key, "id-MT-4"}, pause_reason())
      settings = Config.settings_for_repo!(repo_key)

      broken = Path.join(System.tmp_dir!(), "inbox-config-#{System.unique_integer([:positive])}.yml")
      File.write!(broken, "repositories: 5\n")
      SymphonyElixir.Workflow.set_symphony_file_path(broken)

      assert [%{references: %{"#7" => %{kind: "missing", url: nil}}}] = Inbox.items(%{}, settings_fun: fn _repo_key -> settings end)
    end
  end

  defp capture_log_result(fun) do
    send(self(), {:log_result, nil})
    capture_log(fn -> send(self(), {:log_result, fun.()}) end)
    assert_received {:log_result, nil}
    assert_received {:log_result, result}
    result
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
