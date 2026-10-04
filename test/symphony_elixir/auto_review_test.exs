defmodule SymphonyElixir.AutoReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.AutoReview
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(Application.fetch_env!(:symphony_elixir, :auto_review_test_recipient), {:graphql, query, variables})
      Application.fetch_env!(:symphony_elixir, :auto_review_test_response)
    end
  end

  defmodule StateTracker do
    def workflow_state_exists?(state_name, teams) do
      recipient = Application.fetch_env!(:symphony_elixir, :auto_review_test_recipient)
      send(recipient, {:workflow_state_exists?, state_name, teams})
      Application.fetch_env!(:symphony_elixir, :auto_review_test_state_result)
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :auto_review_test_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :auto_review_test_recipient)
      Application.delete_env(:symphony_elixir, :auto_review_test_response)
      Application.delete_env(:symphony_elixir, :auto_review_test_state_result)
      Application.delete_env(:symphony_elixir, :linear_client_module)
      Application.delete_env(:symphony_elixir, :memory_tracker_workflow_states)
    end)

    :ok
  end

  describe "auto_review config" do
    test "defaults to disabled when the section is absent" do
      assert {:ok, %Schema{auto_review: auto_review} = settings} = Config.settings()

      assert %Schema.AutoReview{
               enabled: false,
               state: "Auto Review",
               kind: nil,
               command: nil,
               max_turns: 20,
               timeout_ms: 1_800_000,
               max_concurrent: 1,
               max_fix_attempts: 2,
               run_on: "every_push",
               skip_globs: [],
               playbooks: %{}
             } = auto_review

      refute AutoReview.enabled?(settings)
      assert AutoReview.post_pr_state(settings) == "In Review"
    end

    test "accepts every field and maps runtime to kind" do
      write_workflow_file!(Workflow.workflow_file_path(),
        auto_review: %{
          enabled: true,
          state: "QA",
          runtime: "claude",
          command: "claude",
          max_turns: 5,
          timeout_ms: 60_000,
          max_concurrent: 2,
          max_fix_attempts: 0,
          run_on: "first_pass",
          skip_globs: ["docs/**"],
          playbooks: %{web: %{paths: ["assets/**"]}},
          worker_host: "qa@qa-vm.local:2222"
        }
      )

      assert {:ok, %Schema{auto_review: auto_review} = settings} = Config.settings()

      assert %Schema.AutoReview{
               enabled: true,
               state: "QA",
               kind: "claude",
               command: "claude",
               max_turns: 5,
               timeout_ms: 60_000,
               max_concurrent: 2,
               max_fix_attempts: 0,
               run_on: "first_pass",
               skip_globs: ["docs/**"],
               playbooks: %{"web" => %{"paths" => ["assets/**"]}},
               worker_host: "qa@qa-vm.local:2222"
             } = auto_review

      assert AutoReview.enabled?(settings)
      assert AutoReview.state(settings) == "QA"
      assert AutoReview.post_pr_state(settings) == "QA"
    end

    test "rejects unknown keys and reports invalid values under operator names" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]

      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{"auto_review" => %{"temperature" => "x"}, "repositories" => repositories})

      assert message =~ "auto_review"
      assert message =~ "temperature"

      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{"auto_review" => %{"runtime" => "gpt"}, "repositories" => repositories})

      assert message =~ "auto_review.runtime"

      for {key, value} <- [
            {"run_on", "never"},
            {"max_turns", 0},
            {"timeout_ms", 0},
            {"max_concurrent", 0},
            {"max_fix_attempts", -1},
            {"state", ""},
            {"worker_host", "-oProxyCommand=sh"},
            {"worker_host", "qa vm"}
          ] do
        assert {:error, {:invalid_symphony_config, message}} =
                 SystemSchema.parse(%{"auto_review" => %{key => value}, "repositories" => repositories})

        assert message =~ "auto_review.#{key}"
      end
    end

    test "parses auto_review.android with its defaults" do
      assert %Schema.AutoReview.Android{avd: nil, sdk_root: nil, boot_timeout_ms: 180_000, idle_timeout_ms: 600_000} =
               Config.settings!().auto_review.android

      write_workflow_file!(Workflow.workflow_file_path(),
        auto_review: %{android: %{avd: "Pixel_3a_API_34", sdk_root: "/opt/android-sdk", boot_timeout_ms: 1_000, idle_timeout_ms: 2_000}}
      )

      settings = Config.settings!()

      assert %Schema.AutoReview.Android{avd: "Pixel_3a_API_34", sdk_root: "/opt/android-sdk", boot_timeout_ms: 1_000, idle_timeout_ms: 2_000} =
               settings.auto_review.android

      assert Config.auto_review_android(settings, %{"ANDROID_HOME" => "/env/home"}) == %{
               avd: "Pixel_3a_API_34",
               sdk_root: "/opt/android-sdk",
               boot_timeout_ms: 1_000,
               idle_timeout_ms: 2_000
             }
    end

    test "auto_review_android/2 falls back to ANDROID_HOME, ANDROID_SDK_ROOT, then ~/Library/Android/sdk" do
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{android: %{avd: "Pixel_3a_API_34"}})
      settings = Config.settings!()

      assert %{avd: "Pixel_3a_API_34", sdk_root: "/env/home", boot_timeout_ms: 180_000, idle_timeout_ms: 600_000} =
               Config.auto_review_android(settings, %{"ANDROID_HOME" => "/env/home", "ANDROID_SDK_ROOT" => "/env/sdk-root"})

      assert Config.auto_review_android(settings, %{"ANDROID_HOME" => " ", "ANDROID_SDK_ROOT" => "/env/sdk-root"}).sdk_root == "/env/sdk-root"
      assert Config.auto_review_android(settings, %{}).sdk_root == Path.expand("~/Library/Android/sdk")
      assert is_binary(Config.auto_review_android(settings).sdk_root)

      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{android: %{sdk_root: "~/sdk"}})
      assert Config.auto_review_android(Config.settings!(), %{"ANDROID_HOME" => "/env/home"}).sdk_root == Path.expand("~/sdk")
    end

    test "rejects invalid auto_review.android values with clear messages" do
      repositories = [%{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}]

      for {android, expected} <- [
            {%{"avd" => 34}, "auto_review.android.avd must be a string"},
            {%{"avd" => "Pixel 3a; rm -rf"}, "auto_review.android.avd must be an AVD name such as Pixel_3a_API_34"},
            {%{"sdk_root" => ["/opt"]}, "auto_review.android.sdk_root must be a string"},
            {%{"sdk_root" => " "}, "auto_review.android.sdk_root must not be blank"},
            {%{"boot_timeout_ms" => 0}, "auto_review.android.boot_timeout_ms must be a positive integer"},
            {%{"idle_timeout_ms" => -1}, "auto_review.android.idle_timeout_ms must be a positive integer"},
            {%{"boot_timeout_ms" => "slow"}, "auto_review.android.boot_timeout_ms must be a positive integer"},
            {%{"emulator" => "x"}, "unknown symphony.yml key `auto_review.android.emulator`"},
            {"Pixel_3a_API_34", "`auto_review.android` must be an object"}
          ] do
        assert {:error, {:invalid_symphony_config, message}} =
                 SystemSchema.parse(%{"auto_review" => %{"android" => android}, "repositories" => repositories})

        assert message =~ expected
      end
    end

    test "round-trips through the system config map" do
      assert {:ok, system_config} =
               SystemSchema.parse(%{
                 "auto_review" => %{"enabled" => true, "runtime" => "codex"},
                 "repositories" => [%{"key" => "default", "workflow" => "WORKFLOW.md"}]
               })

      assert %{"auto_review" => %{"enabled" => true, "kind" => "codex", "state" => "Auto Review"}} =
               SystemSchema.to_config_map(system_config)
    end
  end

  describe "configured_teams/2" do
    test "collects the tracker team and repository teams once each" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_team: "TP")
      settings = Config.settings!()

      assert AutoReview.configured_teams(settings, [%{team: "TP"}, %{team: "ENG"}, %{team: " "}, %{team: nil}, %{}]) ==
               ["TP", "ENG"]
    end
  end

  describe "check_tracker_state/3" do
    test "skips when Auto Review is off" do
      assert :skipped = AutoReview.check_tracker_state(Config.settings!(), ["TP"], tracker: StateTracker)
      refute_received {:workflow_state_exists?, _state, _teams}
    end

    test "turns Auto Review off with a warning when CI polling is off" do
      write_workflow_file!(Workflow.workflow_file_path(), auto_review: %{enabled: true, state: "QA no CI"})
      on_exit(fn -> AutoReview.reset_for_test("QA no CI") end)
      settings = Config.settings!()

      log =
        capture_log(fn ->
          assert :disabled = AutoReview.check_tracker_state(settings, ["TP"], tracker: StateTracker)
        end)

      assert log =~ "Auto Review disabled"
      assert log =~ "pull_requests.checks.enabled: true"
      refute_received {:workflow_state_exists?, _state, _teams}
      refute AutoReview.enabled?(settings)
      assert AutoReview.post_pr_state(settings) == "In Review"
    end

    test "keeps Auto Review on when the Linear state exists" do
      settings = enabled_settings("QA present")
      Application.put_env(:symphony_elixir, :auto_review_test_state_result, {:ok, true})

      assert :ok = AutoReview.check_tracker_state(settings, ["TP"], tracker: StateTracker)
      assert_received {:workflow_state_exists?, "QA present", ["TP"]}
      assert AutoReview.enabled?(settings)
      assert AutoReview.post_pr_state(settings) == "QA present"
    end

    test "turns Auto Review off with a warning when the Linear state is missing" do
      settings = enabled_settings("QA missing")
      Application.put_env(:symphony_elixir, :auto_review_test_state_result, {:ok, false})

      log =
        capture_log(fn ->
          assert :disabled = AutoReview.check_tracker_state(settings, ["TP", "ENG"], tracker: StateTracker)
        end)

      assert log =~ ~s[Auto Review disabled: Linear state "QA missing" is missing for team(s) TP, ENG]
      refute AutoReview.enabled?(settings)
      assert AutoReview.post_pr_state(settings) == "In Review"

      log =
        capture_log(fn ->
          assert :disabled = AutoReview.check_tracker_state(settings, [], tracker: StateTracker)
        end)

      assert log =~ ~s(Linear state "QA missing" is missing; add it)

      Application.put_env(:symphony_elixir, :auto_review_test_state_result, {:ok, true})
      assert :ok = AutoReview.check_tracker_state(settings, [], tracker: StateTracker)
      assert AutoReview.enabled?(settings)
    end

    test "leaves Auto Review on when the tracker cannot be asked" do
      settings = enabled_settings("QA unknown")
      Application.put_env(:symphony_elixir, :auto_review_test_state_result, {:error, :timeout})

      log =
        capture_log(fn ->
          assert {:error, :timeout} = AutoReview.check_tracker_state(settings, [], tracker: StateTracker)
        end)

      assert log =~ "leaving it on"
      assert AutoReview.enabled?(settings)
    end

    test "uses the configured tracker by default" do
      settings = enabled_settings("QA memory")
      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["Todo"])

      capture_log(fn -> assert :disabled = AutoReview.check_tracker_state(settings, []) end)
      refute AutoReview.enabled?(settings)
    end
  end

  describe "enabled?/1" do
    test "is false for anything other than settings" do
      refute AutoReview.enabled?(nil)
    end
  end

  describe "Tracker.Memory.workflow_state_exists?/2" do
    test "assumes every state exists unless states are configured" do
      assert {:ok, true} = Memory.workflow_state_exists?("Auto Review", [])

      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, ["auto review "])
      assert {:ok, true} = Memory.workflow_state_exists?("Auto Review", ["TP"])
      assert {:ok, false} = Memory.workflow_state_exists?("QA", ["TP"])

      Application.put_env(:symphony_elixir, :memory_tracker_workflow_states, {:error, :down})
      assert {:error, :down} = Memory.workflow_state_exists?("QA", [])
    end
  end

  describe "Linear.Adapter.workflow_state_exists?/2" do
    setup do
      Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
      :ok
    end

    test "checks the state exists in every team, by key or id" do
      put_states([%{"team" => %{"id" => "team-uuid", "key" => "TP"}}, %{"team" => %{"id" => "other", "key" => "ENG"}}])

      assert {:ok, true} = Adapter.workflow_state_exists?("Auto Review", ["tp", "OTHER"])
      assert_received {:graphql, query, %{stateName: "Auto Review"}}
      assert query =~ "workflowStates"

      assert {:ok, true} = Adapter.workflow_state_exists?("Auto Review", [])
      assert {:ok, false} = Adapter.workflow_state_exists?("Auto Review", ["TP", "OPS"])
    end

    test "reports a missing state when no team has it" do
      put_states([])
      assert {:ok, false} = Adapter.workflow_state_exists?("Auto Review", [])
    end

    test "treats a state without a team as not matching any team" do
      put_states([%{"id" => "state-1"}])
      assert {:ok, false} = Adapter.workflow_state_exists?("Auto Review", ["TP"])
    end

    test "returns client errors and malformed responses as errors" do
      Application.put_env(:symphony_elixir, :auto_review_test_response, {:error, :unauthorized})
      assert {:error, :unauthorized} = Adapter.workflow_state_exists?("Auto Review", [])

      Application.put_env(:symphony_elixir, :auto_review_test_response, {:ok, %{"errors" => [%{"message" => "bad"}]}})
      assert {:error, :workflow_states_unavailable} = Adapter.workflow_state_exists?("Auto Review", [])
    end

    test "is reached through the Tracker boundary" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
      put_states([%{"team" => %{"id" => "team-uuid", "key" => "TP"}}])

      assert {:ok, true} = SymphonyElixir.Tracker.workflow_state_exists?("Auto Review", ["TP"])
    end
  end

  defp enabled_settings(state) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true},
      auto_review: %{enabled: true, state: state}
    )

    on_exit(fn -> AutoReview.reset_for_test(state) end)
    Config.settings!()
  end

  defp put_states(nodes) do
    Application.put_env(:symphony_elixir, :auto_review_test_response, {:ok, %{"data" => %{"workflowStates" => %{"nodes" => nodes}}}})
  end
end
