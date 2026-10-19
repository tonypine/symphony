defmodule SymphonyElixir.StateProvisioningTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.StateProvisioning

  @machine_states [
    {"issues.states.code_review", "Code Review"},
    {"issues.states.qa", "QA"},
    {"issues.states.plan_review", "Plan Review"},
    {"issues.states.epic_review", "Epic Review"},
    {"issues.states.ci_fix", "CI Fix"}
  ]

  @symphony_project %{id: "p1", name: "Symphony", slug_id: "s1", team_keys: ["TP"]}
  @memory_keys [
    :memory_tracker_recipient,
    :memory_tracker_projects_list,
    :memory_tracker_workflow_states_list,
    :memory_tracker_labels_list
  ]

  defmodule FakeTracker do
    def workflow_states, do: Process.get({__MODULE__, :states}, {:ok, []})
    def labels, do: Process.get({__MODULE__, :labels}, {:ok, []})

    def create_workflow_state(name, team, color) do
      send(self(), {:create_workflow_state, name, team})
      send(self(), {:create_workflow_state_color, name, color})
      Process.get({__MODULE__, :create_state_result}, {:ok, %{name: name, team_id: team}})
    end

    def create_label(name, team) do
      send(self(), {:create_label, name, team})
      Process.get({__MODULE__, :create_label_result}, {:ok, %{name: name, team_id: team}})
    end
  end

  describe "issues.states machine-owned names config" do
    test "defaults to the five phase states the design names" do
      settings = Config.settings!()
      tracker = settings.tracker

      assert tracker.code_review_state == "Code Review"
      assert tracker.qa_state == "QA"
      assert tracker.plan_review_state == "Plan Review"
      assert tracker.epic_review_state == "Epic Review"
      assert tracker.ci_fix_state == "CI Fix"

      assert StateProvisioning.machine_states(settings) == @machine_states
    end

    test "round-trips a renamed state, and turns one off with null or a blank string" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md"}]

      for {value, expected} <- [{"Verification", "Verification"}, {nil, nil}, {" ", nil}] do
        assert {:ok, system_config} =
                 SystemSchema.parse(%{
                   "issues" => %{"provider" => "memory", "states" => %{"qa" => value}},
                   "repositories" => repositories
                 })

        tracker = SystemSchema.to_config_map(system_config)["tracker"]
        assert {:ok, %Schema{tracker: parsed}} = Schema.parse(%{"tracker" => tracker})
        assert parsed.qa_state == expected
        assert parsed.code_review_state == "Code Review"
      end
    end

    test "rejects two phases sharing one name" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md"}]

      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "issues" => %{"states" => %{"code_review" => "Review", "qa" => "review"}},
                 "repositories" => repositories
               })

      assert message =~ "machine-owned state names must be distinct"
    end

    test "rejects unknown issues.states keys" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "issues" => %{"states" => %{"code_reviews" => "x"}},
                 "repositories" => [%{"key" => "default", "workflow" => "WORKFLOW.md"}]
               })

      assert message =~ "issues.states"
    end
  end

  describe "configured_teams/2" do
    test "the issues team and each repository's team, once each, skipping blank ones" do
      {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory", "team" => "TP"}})

      assert StateProvisioning.configured_teams(settings, [%{team: "TP"}, %{team: "APP"}, %{team: " "}, %{}]) == ["TP", "APP"]
    end

    test "a repo routed only by project adds its project's team, and with route.team set nothing is looked up" do
      {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
      lookup = fn -> send(self(), :lookup) && {:ok, [@symphony_project]} end
      repos = [%{name: "app", team: "APP"}, %{name: "web", projects: ["Symphony"]}]

      assert StateProvisioning.configured_teams(settings, repos, projects: lookup) == ["APP", "TP"]

      assert_received :lookup
      assert StateProvisioning.configured_teams(settings, [%{name: "app", team: "APP"}], projects: lookup) == ["APP"]
      refute_received :lookup
    end

    # Walkthrough 1: the memory tracker, a repo routed only by a project of team TP, no route.team.
    test "startup provisioning creates a state missing from a project-routed repo's team" do
      path = Workflow.workflow_file_path()
      repos = [%{key: "app", workflow: path, projects: ["Symphony"]}]
      write_workflow_file!(path, tracker_kind: "memory", tracker_project_slug: nil, repos: repos)
      code_review = %{id: "s1", name: "Code Review", team_id: "t1", team_key: "TP"}
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      Application.put_env(:symphony_elixir, :memory_tracker_projects_list, [@symphony_project])
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states_list, [code_review])

      on_exit(fn ->
        for key <- @memory_keys, do: Application.delete_env(:symphony_elixir, key)
      end)

      settings = Config.settings!()
      {:ok, repos} = Config.repos()
      teams = StateProvisioning.configured_teams(settings, repos)
      assert teams == ["TP"]

      capture_log(fn -> assert :ok = StateProvisioning.provision(settings, teams) end)

      assert_received {:memory_tracker_created_workflow_state, "QA", "TP"}
      refute_received {:memory_tracker_created_workflow_state, "Code Review", _team}
    end
  end

  describe "provision/3" do
    test "creates the five states and five labels in a team, and a second run creates nothing" do
      settings = Config.settings!()

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      for {_key, name} <- @machine_states, do: assert_received({:create_workflow_state, ^name, "TP"})
      for name <- StateProvisioning.labels(), do: assert_received({:create_label, ^name, "TP"})

      assert log =~ "Created Linear workflow state \"QA\" in team \"TP\""
      assert log =~ "Created Linear label \"Blocked\" in team \"TP\""
      assert log =~ "10 created, 0 already present, 0 failed"

      # A second startup finds every state and label it created, so it creates nothing.
      states = Enum.map(@machine_states, fn {_key, name} -> %{name: name, team_key: "TP"} end)
      labels = Enum.map(StateProvisioning.labels(), &%{name: &1, team_key: "TP"})
      Process.put({FakeTracker, :states}, {:ok, states})
      Process.put({FakeTracker, :labels}, {:ok, labels})

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      refute_received {:create_workflow_state, _name, _team}
      refute_received {:create_label, _name, _team}
      assert log =~ "0 created, 10 already present, 0 failed"
    end

    test "creates each phase state with its own hex color, and a renamed one keeps its phase's color" do
      settings = Config.settings!()
      assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)

      colors =
        for {_key, name} <- @machine_states do
          assert_received {:create_workflow_state_color, ^name, color}
          assert color =~ ~r/\A#[0-9a-f]{6}\z/
          color
        end

      assert colors == Enum.uniq(colors)

      renamed = %{settings | tracker: %{settings.tracker | qa_state: "Verification"}}
      assert :ok = StateProvisioning.provision(renamed, ["TP"], tracker: FakeTracker)

      qa_color = Enum.at(colors, 1)
      assert_received {:create_workflow_state_color, "Verification", ^qa_color}
    end

    test "reports a missing state with its exact name and the config key before creating it" do
      settings = Config.settings!()
      Process.put({FakeTracker, :states}, {:ok, [%{name: "In Progress", team_key: "TP"}]})

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      assert log =~ "Linear workflow state \"QA\" is missing from team \"TP\""
      assert log =~ "point issues.states.qa at the new name"
      assert_received {:create_workflow_state, "QA", "TP"}
    end

    test "treats a state or label that already carries the name as present, ignoring case and a workspace label" do
      settings = Config.settings!()

      states = Enum.map(@machine_states, fn {_key, name} -> %{name: String.upcase(name), team_key: "TP"} end)
      # A workspace label (no team) counts for every team.
      labels = Enum.map(StateProvisioning.labels(), &%{name: &1, team_id: nil})
      Process.put({FakeTracker, :states}, {:ok, states})
      Process.put({FakeTracker, :labels}, {:ok, labels})

      assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)

      refute_received {:create_workflow_state, _name, _team}
      refute_received {:create_label, _name, _team}
    end

    test "provisions the teams the existing states belong to when no team is configured" do
      settings = Config.settings!()
      Process.put({FakeTracker, :states}, {:ok, [%{name: "Todo", team_key: "TP"}, %{name: "Todo", team_id: "team-other"}]})

      assert :ok = StateProvisioning.provision(settings, [], tracker: FakeTracker)

      assert_received {:create_workflow_state, "QA", "TP"}
      assert_received {:create_workflow_state, "QA", "team-other"}
    end

    test "does nothing when there is no team to provision in" do
      settings = Config.settings!()

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, [], tracker: FakeTracker)
               end)

      refute_received {:create_workflow_state, _name, _team}
      assert log =~ "State provisioning skipped: no Linear team"
    end

    test "logs a warning and carries on when the tracker cannot be read" do
      settings = Config.settings!()
      Process.put({FakeTracker, :states}, {:error, :unavailable})

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      refute_received {:create_workflow_state, _name, _team}
      assert log =~ "State provisioning skipped: could not read the Linear states and labels: :unavailable"
    end

    test "logs a warning and carries on when a create fails" do
      settings = Config.settings!()
      Process.put({FakeTracker, :create_state_result}, {:error, :forbidden})

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      assert log =~ "Could not create the Linear workflow state \"Code Review\" in team \"TP\": :forbidden"
      assert log =~ "5 created, 0 already present, 5 failed"
    end

    test "logs a warning and carries on when a label create fails" do
      settings = Config.settings!()
      Process.put({FakeTracker, :create_label_result}, {:error, :forbidden})

      assert log =
               capture_log(fn ->
                 assert :ok = StateProvisioning.provision(settings, ["TP"], tracker: FakeTracker)
               end)

      assert log =~ "Could not create the Linear label \"Blocked\" in team \"TP\": :forbidden"
      assert log =~ "5 created, 0 already present, 5 failed"
    end

    test "labels/0 names the machine-owned labels" do
      assert StateProvisioning.labels() == ["Blocked", "Needs Decision", "CI green", "CI red", "CI running"]
    end

    test "machine_states/1 is empty for settings that are not a Schema" do
      assert StateProvisioning.machine_states(%{}) == []
    end
  end
end
