defmodule SymphonyElixir.Setup.FixesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Hold
  alias SymphonyElixir.Hold.Drift
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Checks.{HoldDrift, Labels, Statuses}
  alias SymphonyElixir.Setup.Fixes
  alias SymphonyElixir.StateProvisioning

  @create %{"kind" => "linear", "action" => "create_label", "team" => "TP", "name" => "Needs Decision", "type" => nil}

  setup do
    on_exit(fn ->
      for key <- [:memory_tracker_labels_list, :memory_tracker_create_label_result, :memory_tracker_recipient],
          do: Application.delete_env(:symphony_elixir, key)
    end)

    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory", repos: [%{key: "app", team: "TP", workflow: path}])

    labels = for %{names: [name | _]} <- StateProvisioning.machine_labels("expedite", ["needs-human"]), name != "Needs Decision", do: name
    Application.put_env(:symphony_elixir, :memory_tracker_labels_list, Enum.map(labels, &%{id: &1, name: &1, team_id: "TP", team_key: "TP"}))

    server = Module.concat(__MODULE__, "Setup#{System.unique_integer([:positive])}")
    start_supervised!({Setup, name: server, checks: [Labels, HoldDrift], linear_api_key?: true})
    Setup.refresh(server)
    {:ok, server: server}
  end

  defp ids(payload), do: Enum.map(payload.problems, & &1.id)

  test "a proposed create_label creates exactly that label in that team, and the next check is clean", %{server: server} do
    assert ids(Setup.payload(server)) == ["labels:missing:TP:Needs Decision"]
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert {:ok, payload} = Fixes.run(@create, server: server)
    assert_received {:memory_tracker_created_label, "Needs Decision", "TP"}
    refute_received {:memory_tracker_created_label, _name, _team}
    assert payload.problems == []
    assert Setup.payload(server).problems == []
  end

  test "a descriptor the latest check didn't propose is refused, and nothing is created", %{server: server} do
    # A near miss next to the missing label: a problem whose fix opens Linear.
    labels = Application.get_env(:symphony_elixir, :memory_tracker_labels_list)
    near_miss = %{id: "nd", name: "Needs decision ", team_id: "TP", team_key: "TP"}
    Application.put_env(:symphony_elixir, :memory_tracker_labels_list, labels ++ [near_miss])
    Setup.refresh(server)
    assert [%{fix: %{kind: "linear"}}, %{fix: %{kind: "open"}}] = Setup.payload(server).problems
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    for descriptor <- [
          %{@create | "team" => "OPS"},
          %{@create | "name" => "Blocked"},
          %{@create | "action" => "delete_label"},
          %{"kind" => "linear", "action" => "resync_hold", "repo" => "app", "tickets" => ["TP-1"]},
          %{"kind" => "config_edit", "path" => "x", "action" => "remove"},
          "create_label"
        ] do
      assert Fixes.run(descriptor, server: server) == {:error, :not_proposed}
    end

    refute_received {:memory_tracker_created_label, _name, _team}
  end

  test "a create Linear refuses says why in plain words and leaves the problem in place", %{server: server} do
    refusals = [
      {{:linear_graphql_errors, [%{"message" => "Label name already taken"}]}, "Label name already taken. Fix it in Linear"},
      {{:linear_graphql_errors, [%{"message" => "x", "extensions" => %{"userPresentableMessage" => "You lack permission"}}, :odd]}, "You lack permission; :odd"},
      {:label_create_failed, "a label with that name may already exist"},
      {{:team_not_found, "TP"}, "it has no team TP"},
      {{:linear_api_status, 403, nil}, "the Linear API key isn't allowed to (HTTP 403)"},
      {{:linear_api_status, 500, nil}, "Linear answered HTTP 500"},
      {:boom, ":boom. Fix it in Linear"}
    ]

    for {reason, expected} <- refusals do
      Application.put_env(:symphony_elixir, :memory_tracker_create_label_result, [{:error, reason}])

      assert {:error, {:refused, message}} = Fixes.run(@create, server: server)
      assert message =~ ~s(Linear refused to create the label "Needs Decision" in team TP: )
      assert message =~ expected
    end

    assert ids(Setup.payload(server)) == ["labels:missing:TP:Needs Decision"]
    assert {:ok, %{problems: []}} = Fixes.run(@create, server: server)
  end

  describe "create_state" do
    setup do
      on_exit(fn ->
        for key <- [:memory_tracker_workflow_states_list, :memory_tracker_create_workflow_state_result],
            do: Application.delete_env(:symphony_elixir, key)
      end)

      board =
        Enum.with_index(
          ["In Progress", "Code Review", "QA", "Merging", "Rework", "Plan Review", "Waiting on sub-tickets", "CI Fix"],
          &%{id: &1, name: &1, team_id: "TP", team_key: "TP", type: "started", position: &2 + 1}
        )

      others =
        for {name, type} <- [{"Todo", "unstarted"}, {"Done", "completed"}, {"Canceled", "canceled"}],
            do: %{id: name, name: name, team_id: "TP", team_key: "TP", type: type, position: 0}

      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, others ++ board)

      server = Module.concat(__MODULE__, "Statuses#{System.unique_integer([:positive])}")
      start_supervised!({Setup, name: server, checks: [Statuses], linear_api_key?: true}, id: :statuses)
      Setup.refresh(server)
      assert [%{fix: fix}] = Setup.payload(server).problems
      {:ok, server: server, fix: fix |> Map.new(fn {key, value} -> {to_string(key), value} end)}
    end

    test "a proposed create_state creates that state, of that type and in that place, and the next check is clean", %{server: server, fix: fix} do
      assert fix == %{
               "kind" => "linear",
               "action" => "create_state",
               "team" => "TP",
               "name" => "Epic Review",
               "type" => "started",
               "after" => "Plan Review",
               "position" => 6.5
             }

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      assert {:ok, %{problems: []}} = Fixes.run(fix, server: server)
      assert_received {:memory_tracker_created_workflow_state, "Epic Review", "TP"}
      assert %{type: "started", position: 6.5} = List.last(Application.get_env(:symphony_elixir, :memory_tracker_workflow_states_list))
    end

    test "a create_state another place, type or team than proposed is refused", %{server: server, fix: fix} do
      for descriptor <- [%{fix | "position" => 9}, %{fix | "type" => "unstarted"}, %{fix | "team" => "OPS"}, %{fix | "after" => nil}] do
        assert Fixes.run(descriptor, server: server) == {:error, :not_proposed}
      end
    end

    test "a create Linear refuses says why and leaves the problem in place", %{server: server, fix: fix} do
      failed = [{:error, :workflow_state_create_failed}]
      Application.put_env(:symphony_elixir, :memory_tracker_create_workflow_state_result, failed)

      assert {:error, {:refused, message}} = Fixes.run(fix, server: server)
      assert message =~ ~s(Linear refused to create the state "Epic Review" in team TP: a state with that name may already exist)
      assert [%{id: "statuses:missing:TP:Epic Review"}] = Setup.payload(server).problems
    end
  end

  describe "resync_hold" do
    setup %{server: server} do
      issues = for {id, identifier} <- [{"i1", "TP-1"}, {"i2", "TP-2"}], do: %Issue{id: id, identifier: identifier, labels: ["Blocked"]}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      labels = Application.get_env(:symphony_elixir, :memory_tracker_labels_list)
      needs_decision = %{id: "nd", name: "Needs Decision", team_id: "TP", team_key: "TP"}
      Application.put_env(:symphony_elixir, :memory_tracker_labels_list, [needs_decision | labels])

      # Two polls, each followed by a check, see both tickets drift.
      for _round <- 1..2 do
        capture_log(fn -> for issue <- issues, do: Hold.report_drift("app", issue.id, ["Blocked"], identifier: issue.identifier) end)
        Setup.refresh(server)
      end

      assert [%{fix: %{action: "resync_hold", tickets: ["TP-1", "TP-2"]}}] = Setup.payload(server).problems
      :ok
    end

    defp resync(tickets), do: %{"kind" => "linear", "action" => "resync_hold", "repo" => "app", "tickets" => tickets}

    defp labels(id), do: Enum.find(Application.get_env(:symphony_elixir, :memory_tracker_issues), &(&1.id == id)).labels

    test "one ticket re-syncs alone, and only the other is left to propose", %{server: server} do
      assert {:ok, %{problems: [problem]}} = Fixes.run(resync(["TP-1"]), server: server)
      assert labels("i1") == []
      assert labels("i2") == ["Blocked"]
      assert problem.tickets == [%{identifier: "TP-2", url: nil}]

      assert Fixes.run(resync(["TP-1"]), server: server) == {:error, :not_proposed}
      assert Fixes.run(resync([]), server: server) == {:error, :not_proposed}
      assert Fixes.run(%{resync(["TP-2"]) | "repo" => "other"}, server: server) == {:error, :not_proposed}
    end

    test "every listed ticket at once", %{server: server} do
      assert {:ok, %{problems: []}} = Fixes.run(resync(["TP-1", "TP-2"]), server: server)
      assert labels("i1") == []
      assert labels("i2") == []
    end

    test "a ticket whose drift cleared before the fix ran is left alone", %{server: server} do
      Drift.forget("app", "i2")

      assert {:ok, _payload} = Fixes.run(resync(["TP-1", "TP-2"]), server: server)
      assert labels("i2") == ["Blocked"]
    end

    test "a label write Linear refuses names the ticket and keeps the warning", %{server: server} do
      Application.put_env(:symphony_elixir, :memory_tracker_remove_issue_label_result, [:ok, {:error, :forbidden}])

      assert {:error, {:refused, message}} = Fixes.run(resync(["TP-1", "TP-2"]), server: server)
      assert message == "Linear refused to re-sync the hold label of TP-2: :forbidden. Fix it in Linear, then check again."
      assert labels("i1") == []
      assert labels("i2") == ["Blocked"]
      assert [%{id: "hold_drift:app"}] = Setup.payload(server).problems
    end
  end
end
