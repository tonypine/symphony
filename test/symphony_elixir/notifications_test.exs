defmodule SymphonyElixir.NotificationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Notifications.Channel, as: NotificationChannel
  alias SymphonyElixir.Notifications.Channels.{Slack, Webhook}
  alias SymphonyElixir.Notifications.Event
  alias SymphonyElixir.Notifications.Formatter
  alias SymphonyElixir.Notifications.Notifier
  alias SymphonyElixir.Secret
  alias SymphonyElixir.Workflow

  test "notifications default to disabled while notifier remains supervised" do
    config = Config.settings!()

    refute config.notifications.enabled
    assert config.notifications.channels == []
    assert Enum.member?(SymphonyElixir.Application.child_specs_for_runtime(%{}), Notifier)

    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-0"})

    opts = [
      task_starter: fn _fun -> flunk("disabled notifications should not start delivery tasks") end
    ]

    assert :ok =
             Notifier.deliver_for_test(event, config.notifications, opts)
  end

  test "notification PubSub events carry repo_key" do
    assert :ok = SymphonyElixir.Notifications.subscribe()
    assert :ok = SymphonyElixir.Notifications.emit_event(:run_failed, issue_identifier: "ACME-0")

    assert_receive {:notification_event, %Event{repo_key: "default", issue_identifier: "ACME-0"}}
  end

  test "notifier delivers non-primary repo PubSub events" do
    test_pid = self()

    SymphonyElixir.TestSupport.ensure_pubsub_started!()

    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{
        enabled: true,
        channels: [
          %{kind: "webhook", url: "https://webhook.test/events", events: ["run_failed"]}
        ]
      }
    )

    request_fun = fn url, payload, headers, _timeout_ms ->
      send(test_pid, {:post, url, payload, headers})
      {:ok, %{status: 200, body: "ok"}}
    end

    notifier_name = :"#{__MODULE__}.Notifier#{System.unique_integer([:positive])}"

    {:ok, notifier_pid} =
      Notifier.start_link(
        name: notifier_name,
        task_starter: fn fun ->
          fun.()
          :ok
        end,
        request_fun: request_fun
      )

    on_exit(fn ->
      if Process.alive?(notifier_pid), do: GenServer.stop(notifier_pid)
    end)

    {:ok, event} =
      Event.new(:run_failed,
        repo_key: "github.com/acme/repo",
        issue_identifier: "ACME-99"
      )

    send(notifier_pid, {:notification_event, event})

    assert_receive {:post, "https://webhook.test/events", %{"repo_key" => "github.com/acme/repo", "issue_identifier" => "ACME-99"}, []}
  end

  test "notifications resolve channel env values and optional headers" do
    slack_env = "SYMP_TEST_SLACK_WEBHOOK_#{System.unique_integer([:positive])}"
    webhook_env = "SYMP_TEST_NOTIFY_WEBHOOK_#{System.unique_integer([:positive])}"
    auth_env = "SYMP_TEST_NOTIFY_AUTH_#{System.unique_integer([:positive])}"

    previous_slack = System.get_env(slack_env)
    previous_webhook = System.get_env(webhook_env)
    previous_auth = System.get_env(auth_env)

    System.put_env(slack_env, "https://hooks.slack.test/services/T000/B000/XXX")
    System.put_env(webhook_env, "https://notify.test/events")
    System.put_env(auth_env, "Bearer token")

    on_exit(fn ->
      restore_env(slack_env, previous_slack)
      restore_env(webhook_env, previous_webhook)
      restore_env(auth_env, previous_auth)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{
        enabled: true,
        redact_titles: true,
        channels: [
          %{kind: "slack", webhook_url: "$#{slack_env}", events: ["pr_opened", "reviewer_commented", "rework_pushed", "run_failed"]},
          %{kind: "webhook", url: "$#{webhook_env}", headers: %{Authorization: "$#{auth_env}"}}
        ]
      }
    )

    config = Config.settings!()

    assert config.notifications.enabled
    assert config.notifications.redact_titles

    assert [
             %{
               kind: "slack",
               webhook_url: slack_webhook_url,
               events: ["pr_opened", "reviewer_commented", "rework_pushed", "run_failed"]
             },
             %{kind: "webhook", url: webhook_url, headers: %{"Authorization" => auth_header}, events: nil}
           ] = config.notifications.channels

    assert Secret.unwrap(slack_webhook_url) == "https://hooks.slack.test/services/T000/B000/XXX"
    assert Secret.unwrap(webhook_url) == "https://notify.test/events"
    assert Secret.unwrap(auth_header) == "Bearer token"

    assert Enum.member?(SymphonyElixir.Application.child_specs_for_runtime(%{}), Notifier)
  end

  test "notifications normalize optional channel headers and invalid event filters" do
    missing_env = "SYMP_TEST_MISSING_NOTIFY_URL_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)

    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{
        enabled: false,
        channels: [
          %{
            kind: "webhook",
            url: "$#{missing_env}",
            events: [" REWORK_PUSHED ", " RUN_FAILED ", "", "run_failed"],
            headers: %{
              Authorization: " Bearer token ",
              Blank: "  ",
              Count: 2,
              Enabled: true,
              Missing: nil
            }
          }
        ]
      }
    )

    assert [
             %{
               url: nil,
               events: ["rework_pushed", "run_failed"],
               headers: %{
                 "Authorization" => auth_header,
                 "Count" => count_header,
                 "Enabled" => enabled_header
               }
             }
           ] = Config.settings!().notifications.channels

    assert Secret.unwrap(auth_header) == "Bearer token"
    assert Secret.unwrap(count_header) == "2"
    assert Secret.unwrap(enabled_header) == "true"

    write_workflow_file!(Workflow.workflow_file_path(),
      notifications: %{
        enabled: false,
        channels: [%{kind: "webhook", url: "https://notify.test/events", events: ["bogus"]}]
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "must include only supported notification events"
  end

  test "notification schema treats nil headers and nil header values as empty" do
    assert {:ok, %{notifications: %{channels: [%{headers: %{}}]}}} =
             Schema.parse(%{
               "notifications" => %{
                 "enabled" => false,
                 "channels" => [%{"kind" => "webhook", "url" => "https://notify.test/events", "headers" => nil}]
               }
             })

    assert {:ok, %{notifications: %{channels: [%{headers: %{}}]}}} =
             Schema.parse(%{
               "notifications" => %{
                 "enabled" => false,
                 "channels" => [
                   %{
                     "kind" => "webhook",
                     "url" => "https://notify.test/events",
                     "headers" => %{"Drop" => %{"nested" => "value"}}
                   }
                 ]
               }
             })
  end

  test "notification schema validates webhook URL scheme and private literal hosts" do
    invalid_urls = [
      "http://notify.test/events",
      "https://localhost/events",
      "https://127.0.0.1/events",
      "https://[::1]/events",
      "https://169.254.169.254/latest/meta-data",
      "https://10.0.0.1/events",
      "https://172.16.0.1/events",
      "https://192.168.0.1/events",
      "https://[fe80::1]/events",
      "https://[fd00::1]/events"
    ]

    for url <- invalid_urls do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "notifications" => %{
                   "enabled" => true,
                   "channels" => [%{"kind" => "webhook", "url" => url}]
                 }
               })

      assert message =~ "notifications.channels"
    end

    assert {:ok,
            %{
              notifications: %{
                channels: [
                  %{kind: "webhook", url: slack_url},
                  %{kind: "webhook", url: discord_url},
                  %{kind: "webhook", url: private_url, allow_private: true}
                ]
              }
            }} =
             Schema.parse(%{
               "notifications" => %{
                 "enabled" => true,
                 "channels" => [
                   %{"kind" => "webhook", "url" => "https://hooks.slack.com/services/T000/B000/XXX"},
                   %{"kind" => "webhook", "url" => "https://discord.com/api/webhooks/123/secret"},
                   %{"kind" => "webhook", "url" => "https://10.0.0.1/events", "allow_private" => true}
                 ]
               }
             })

    assert Secret.unwrap(slack_url) == "https://hooks.slack.com/services/T000/B000/XXX"
    assert Secret.unwrap(discord_url) == "https://discord.com/api/webhooks/123/secret"
    assert Secret.unwrap(private_url) == "https://10.0.0.1/events"
  end

  test "notification schema validates webhook URLs resolved from environment" do
    unsafe_env = "SYMP_TEST_UNSAFE_NOTIFY_WEBHOOK_#{System.unique_integer([:positive])}"
    previous_unsafe = System.get_env(unsafe_env)
    System.put_env(unsafe_env, "https://169.254.169.254/latest/meta-data")

    on_exit(fn -> restore_env(unsafe_env, previous_unsafe) end)

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "notifications" => %{
                 "enabled" => true,
                 "channels" => [%{"kind" => "webhook", "url" => "$#{unsafe_env}"}]
               }
             })

    assert message =~ "notifications.channels[0].url"
    assert message =~ "allow_private"
  end

  test "notification webhook URL validator handles empty, non-string, and public IP literals" do
    assert :ok = NotificationChannel.validate_webhook_url(nil, false)
    assert :ok = NotificationChannel.validate_webhook_url("  ", false)
    assert :ok = NotificationChannel.validate_webhook_url("https://203.0.113.10/events", false)

    assert {:error, "must be a string URL"} = NotificationChannel.validate_webhook_url(123, false)

    assert {:error, message} = NotificationChannel.validate_webhook_url("https://[::ffff:127.0.0.1]/events", false)
    assert message =~ "allow_private"
  end

  test "event builder normalizes attrs, issue structs, and transcript links" do
    write_workflow_file!(Workflow.workflow_file_path(), server_port: 4105, server_host: "0.0.0.0")

    assert Event.known_events() == [
             "pr_opened",
             "awaiting_review",
             "run_failed",
             "run_stuck",
             "issue_completed",
             "budget_exceeded",
             "dependency_pending_approval",
             "reviewer_commented",
             "rework_pushed",
             "ci_failed",
             "ci_escalated",
             "qa_passed",
             "qa_failed",
             "usage_limit_paused",
             "usage_limit_resumed"
           ]

    assert Event.known_event?(" RUN_FAILED ")
    assert Event.known_event?("reviewer_commented")

    {:ok, default_event} = Event.new(:run_failed)
    assert default_event.event == "run_failed"
    assert default_event.repo_key == "default"
    assert default_event.issue_id == nil
    assert default_event.transcript_url == nil

    {:ok, event} =
      Event.new(:run_failed,
        issue_id: 123,
        issue_identifier: "ACME-6",
        issue_title: " ",
        pr_title: %{unexpected: true},
        reason: {:exit, :killed},
        state: :done,
        timestamp: ~U[2026-05-06 09:00:00Z]
      )

    assert event.issue_id == "123"
    assert event.issue_identifier == "ACME-6"
    assert event.issue_title == nil
    assert event.pr_title == nil
    assert event.reason == "{:exit, :killed}"
    assert event.state == "done"
    assert event.repo_key == "default"
    assert event.transcript_url == "http://127.0.0.1:4105/repos/default/issues/ACME-6/transcript"

    assert {:error, {:unknown_notification_event, 123}} = Event.new(123, %{})
    assert {:ok, %Event{issue_identifier: nil}} = Event.new(:run_failed, :invalid_attrs)
    assert {:ok, %Event{reason: nil}} = Event.new(:run_failed, %{reason: " "})

    issue = %Issue{
      id: "issue-7",
      identifier: "ACME-7",
      title: "Needs review",
      state: "In Review",
      url: " https://linear.test/ACME-7 ",
      pr_urls: ["", "https://github.test/org/repo/pull/7"]
    }

    assert {:ok,
            %Event{
              repo_key: "default",
              issue_id: "issue-7",
              issue_identifier: "ACME-7",
              issue_title: "Needs review",
              issue_url: "https://linear.test/ACME-7",
              pr_url: "https://github.test/org/repo/pull/7",
              state: "In Review"
            }} = Event.from_issue(:awaiting_review, issue)

    assert {:ok, %Event{issue_identifier: "ACME-8"}} =
             Event.from_issue(:budget_exceeded, :not_an_issue, issue_identifier: "ACME-8")
  end

  test "event transcript link falls back cleanly when config cannot load" do
    workflow_path = Workflow.workflow_file_path()
    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")

    Enum.each(["default", "symphony", Application.get_env(:symphony_elixir, :primary_repo_name)], fn
      nil ->
        :ok

      repo_name ->
        supervisor = SymphonyElixir.Repo.Supervisor.supervisor_name(repo_name)

        if GenServer.whereis(supervisor) do
          Supervisor.terminate_child(supervisor, {SymphonyElixir.WorkflowStore, repo_name})
        end
    end)

    if pid = Process.whereis(SymphonyElixir.WorkflowStore), do: GenServer.stop(pid)

    try do
      Workflow.set_workflow_file_path(missing_path)
      assert {:ok, %Event{transcript_url: nil}} = Event.new(:run_failed, %{issue_identifier: "ACME-9"})
    after
      Workflow.set_workflow_file_path(workflow_path)

      Enum.each(["default", "symphony", Application.get_env(:symphony_elixir, :primary_repo_name)], fn
        nil ->
          :ok

        repo_name ->
          supervisor = SymphonyElixir.Repo.Supervisor.supervisor_name(repo_name)

          if GenServer.whereis(supervisor) do
            Supervisor.restart_child(supervisor, {SymphonyElixir.WorkflowStore, repo_name})
          end
      end)
    end
  end

  test "formatter builds stable webhook payload and redacts titles" do
    {:ok, event} =
      Event.new(:pr_opened, %{
        issue_id: "issue-1",
        issue_identifier: "ACME-1",
        issue_title: "Sensitive title",
        issue_url: "https://linear.test/ACME-1",
        pr_url: "https://github.test/org/repo/pull/1",
        transcript_url: "http://127.0.0.1:4000/issues/ACME-1/transcript",
        timestamp: ~U[2026-05-06 08:00:00Z]
      })

    payload = Formatter.webhook_payload(event)
    redacted = Formatter.webhook_payload(event, redact_titles: true)

    assert payload["event"] == "pr_opened"
    assert payload["repo_key"] == "default"
    assert payload["issue_identifier"] == "ACME-1"
    assert payload["issue_title"] == "Sensitive title"
    assert payload["state_url"] == "https://github.test/org/repo/pull/1"
    assert payload["transcript_url"] == "http://127.0.0.1:4000/issues/ACME-1/transcript"
    refute Map.has_key?(redacted, "issue_title")
    assert redacted["issue_identifier"] == "ACME-1"
    assert redacted["issue_url"] == "https://linear.test/ACME-1"
  end

  test "formatter builds Slack block attachment payload with state URL and transcript link" do
    {:ok, event} =
      Event.new("run_failed", %{
        issue_identifier: "ACME-2",
        issue_title: "Broken run",
        issue_url: "https://linear.test/ACME-2",
        pr_url: "https://github.test/org/repo/pull/2",
        transcript_url: "http://127.0.0.1:4000/issues/ACME-2/transcript",
        reason: "agent exited"
      })

    payload = Formatter.slack_payload(event)
    encoded = Jason.encode!(payload)

    assert payload["text"] == "Run failed: ACME-2"
    assert [%{"blocks" => blocks}] = payload["attachments"]
    assert is_list(blocks)
    assert encoded =~ "ACME-2"
    assert encoded =~ "Broken run"
    assert encoded =~ "https://github.test/org/repo/pull/2"
    assert encoded =~ "http://127.0.0.1:4000/issues/ACME-2/transcript"

    redacted = Formatter.slack_payload(event, redact_titles: true)
    refute Jason.encode!(redacted) =~ "Broken run"
  end

  test "formatter shows which usage limit paused or resumed dispatch, without an issue link" do
    metadata = %{provider: "anthropic", scope: "all", window: "five_hour", resume_at: ~U[2026-05-06 14:05:00Z]}

    {:ok, paused} =
      Event.new(:usage_limit_paused, %{
        issue_identifier: "ACME-3",
        reason: "Claude 5-hour limit; resumes at 2026-05-06T14:05:00Z",
        metadata: metadata,
        timestamp: ~U[2026-05-06 09:00:00Z]
      })

    {:ok, resumed} = Event.new("usage_limit_resumed", %{reason: "Claude 5-hour limit", metadata: metadata})

    paused_slack = Formatter.slack_payload(paused)
    resumed_slack = Formatter.slack_payload(resumed)

    assert paused_slack["text"] == "Usage limit paused: Claude 5-hour limit; resumes at 2026-05-06T14:05:00Z"
    assert [%{"color" => "warning", "blocks" => [headline | _]}] = paused_slack["attachments"]
    assert headline["text"]["text"] == "*Usage limit paused* - Claude 5-hour limit; resumes at 2026-05-06T14:05:00Z"

    assert resumed_slack["text"] == "Usage limit resumed: Claude 5-hour limit"
    assert [%{"color" => "good", "blocks" => [resumed_headline | _]}] = resumed_slack["attachments"]
    assert resumed_headline["text"]["text"] == "*Usage limit resumed* - Claude 5-hour limit"

    webhook = Formatter.webhook_payload(paused)
    assert webhook["event"] == "usage_limit_paused"
    assert webhook["issue_identifier"] == "ACME-3"
    assert webhook["reason"] == "Claude 5-hour limit; resumes at 2026-05-06T14:05:00Z"
    assert webhook["metadata"] == metadata
    assert Jason.decode!(Jason.encode!(webhook))["metadata"]["resume_at"] == "2026-05-06T14:05:00Z"
    assert Formatter.webhook_payload(resumed)["event"] == "usage_limit_resumed"
  end

  test "formatter includes reviewer feedback context for webhook and Slack payloads" do
    issue_url = "https://linear.test/ACME-2407"
    pr_url = "https://github.test/org/repo/pull/2407"
    transcript_url = "http://127.0.0.1:4000/issues/ACME-2407/transcript"

    for {event_name, title} <- [
          {"reviewer_commented", "Reviewer commented"},
          {"rework_pushed", "Rework pushed"}
        ] do
      {:ok, event} =
        Event.new(event_name, %{
          issue_id: "issue-2407",
          issue_identifier: "ACME-2407",
          issue_title: "Reviewer feedback",
          issue_url: issue_url,
          pr_url: pr_url,
          transcript_url: transcript_url,
          timestamp: ~U[2026-05-06 08:00:00Z]
        })

      payload = Formatter.webhook_payload(event)
      redacted_payload = Formatter.webhook_payload(event, redact_titles: true)

      assert payload["event"] == event_name
      assert payload["issue_identifier"] == "ACME-2407"
      assert payload["issue_title"] == "Reviewer feedback"
      assert payload["issue_url"] == issue_url
      assert payload["pr_url"] == pr_url
      assert payload["state_url"] == pr_url
      assert payload["transcript_url"] == transcript_url
      assert payload["timestamp"] == "2026-05-06T08:00:00Z"
      refute Map.has_key?(redacted_payload, "issue_title")

      slack_payload = Formatter.slack_payload(event)
      encoded_slack = Jason.encode!(slack_payload)

      assert slack_payload["text"] == "#{title}: ACME-2407"

      for value <- [title, "ACME-2407", "Reviewer feedback", issue_url, pr_url, transcript_url, "2026-05-06T08:00:00Z"] do
        assert encoded_slack =~ value
      end

      redacted_slack = Formatter.slack_payload(event, redact_titles: true)
      refute Jason.encode!(redacted_slack) =~ "Reviewer feedback"
    end
  end

  test "formatter covers event titles, fallback URLs, empty fields, and escaping" do
    for {event_name, expected_title} <- [
          {"pr_opened", "PR opened"},
          {"awaiting_review", "Awaiting review"},
          {"run_stuck", "Run stuck"},
          {"dependency_pending_approval", "Dependency approval needed"},
          {"issue_completed", "Issue completed"},
          {"budget_exceeded", "Budget exceeded"},
          {"ci_failed", "CI failed"},
          {"ci_escalated", "CI escalated"},
          {"qa_passed", "QA passed"},
          {"qa_failed", "QA failed"},
          {"custom_event", "custom_event"}
        ] do
      event = %Event{
        event: event_name,
        issue_id: "issue-#{event_name}",
        issue_identifier: 123,
        issue_url: "https://linear.test/#{event_name}<filter|ok>",
        pr_url: nil,
        issue_title: nil,
        state: :done,
        reason: "",
        transcript_url: "",
        timestamp: ~U[2026-05-06 10:00:00Z],
        tokens: %{},
        metadata: %{}
      }

      payload = Formatter.slack_payload(event)
      encoded = Jason.encode!(payload)

      assert payload["text"] == "#{expected_title}: 123"
      assert encoded =~ expected_title
      assert encoded =~ "https://linear.test/#{event_name}%3Cfilter%7Cok%3E"
      refute encoded =~ "Transcript"
    end

    issue_event = %Event{
      event: "issue_completed",
      issue_identifier: "ACME-10",
      issue_url: "https://linear.test/ACME-10",
      timestamp: ~U[2026-05-06 10:00:00Z],
      tokens: %{},
      metadata: %{}
    }

    assert Formatter.state_url(issue_event) == "https://linear.test/ACME-10"
    assert Formatter.webhook_payload(issue_event)["state_url"] == "https://linear.test/ACME-10"

    budget_payload = Formatter.slack_payload(%{issue_event | event: "budget_exceeded"})
    completed_payload = Formatter.slack_payload(issue_event)

    assert [%{"color" => "warning"}] = budget_payload["attachments"]
    assert [%{"color" => "good"}] = completed_payload["attachments"]
  end

  test "notifier honors per-channel event filters" do
    test_pid = self()
    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-3"})

    notifications = %{
      enabled: true,
      redact_titles: false,
      channels: [
        %{kind: "slack", webhook_url: "https://slack.test", events: ["pr_opened"]},
        %{kind: "webhook", url: "https://webhook.test", events: ["run_failed"], headers: %{"Authorization" => "token"}}
      ]
    }

    request_fun = fn url, payload, headers, _timeout_ms ->
      send(test_pid, {:post, url, payload, headers})
      {:ok, %{status: 200, body: "ok"}}
    end

    assert :ok =
             Notifier.deliver_for_test(event, notifications,
               task_starter: fn fun ->
                 fun.()
                 :ok
               end,
               request_fun: request_fun
             )

    assert_receive {:post, "https://webhook.test", %{"event" => "run_failed"}, [{"Authorization", "token"}]}
    refute_receive {:post, "https://slack.test", _payload, _headers}, 50
  end

  test "notifier honors reviewer feedback event filters" do
    test_pid = self()
    {:ok, reviewer_event} = Event.new(:reviewer_commented, %{issue_identifier: "ACME-2407"})
    {:ok, rework_event} = Event.new(:rework_pushed, %{issue_identifier: "ACME-2407"})

    notifications = %{
      enabled: true,
      redact_titles: false,
      channels: [
        %{kind: "slack", webhook_url: "https://slack.test", events: ["reviewer_commented"]},
        %{kind: "webhook", url: "https://webhook.test", events: ["rework_pushed"], headers: %{}}
      ]
    }

    request_fun = fn url, payload, headers, _timeout_ms ->
      send(test_pid, {:post, url, payload, headers})
      {:ok, %{status: 200, body: "ok"}}
    end

    opts = [
      task_starter: fn fun ->
        fun.()
        :ok
      end,
      request_fun: request_fun
    ]

    assert :ok = Notifier.deliver_for_test(reviewer_event, notifications, opts)
    assert_receive {:post, "https://slack.test", slack_payload, []}
    assert Jason.encode!(slack_payload) =~ "Reviewer commented"
    refute_receive {:post, "https://webhook.test", _payload, _headers}, 50

    assert :ok = Notifier.deliver_for_test(rework_event, notifications, opts)
    assert_receive {:post, "https://webhook.test", %{"event" => "rework_pushed"}, []}
    refute_receive {:post, "https://slack.test", _payload, _headers}, 50
  end

  test "notifier retries Slack 429 with retry-after before dropping" do
    test_pid = self()
    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-4"})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    notifications = %{
      enabled: true,
      redact_titles: false,
      channels: [%{kind: "slack", webhook_url: "https://slack.test", events: ["run_failed"]}]
    }

    request_fun = fn url, payload, headers, _timeout_ms ->
      attempt = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
      send(test_pid, {:post, attempt, url, payload, headers})

      case attempt do
        1 -> {:ok, %{status: 429, headers: [{"retry-after", "2"}], body: "rate limited"}}
        _ -> {:ok, %{status: 200, body: "ok"}}
      end
    end

    assert :ok =
             Notifier.deliver_for_test(event, notifications,
               task_starter: fn fun ->
                 fun.()
                 :ok
               end,
               request_fun: request_fun,
               sleep_fun: fn delay_ms -> send(test_pid, {:sleep, delay_ms}) end
             )

    assert_receive {:post, 1, "https://slack.test", _payload, []}
    assert_receive {:sleep, 2_000}
    assert_receive {:post, 2, "https://slack.test", _payload, []}
  end

  test "Slack channel reports retry delay from 429 response" do
    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-5"})

    request_fun = fn _url, _payload, _headers, _timeout_ms ->
      {:ok, %{status: 429, headers: [{"Retry-After", "3"}], body: "rate limited"}}
    end

    assert {:retry, 3_000} =
             Slack.deliver(%{webhook_url: "https://slack.test"}, event, request_fun: request_fun)
  end

  test "webhook channel disables redirects for outbound requests" do
    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-3022"})

    request_fun = fn url, payload, headers, timeout_ms, request_opts ->
      assert url == "https://webhook.test/events"
      assert %{"event" => "run_failed"} = payload
      assert headers == [{"Authorization", "token"}]
      assert timeout_ms == 5_000
      assert request_opts[:redirect] == false

      {:ok, %{status: 302, body: "redirect"}}
    end

    assert {:error, {:http_status, 302, "redirect"}} =
             Webhook.deliver(
               %{url: "https://webhook.test/events", headers: %{"Authorization" => "token"}},
               event,
               request_fun: request_fun
             )
  end

  test "notifier drops Slack delivery after max attempts" do
    test_pid = self()
    {:ok, event} = Event.new(:run_failed, %{issue_identifier: "ACME-6"})

    notifications = %{
      enabled: true,
      redact_titles: false,
      channels: [%{kind: "slack", webhook_url: "https://slack.test", events: ["run_failed"]}]
    }

    request_fun = fn _url, _payload, _headers, _timeout_ms ->
      send(test_pid, :attempted)
      {:error, :nxdomain}
    end

    log =
      capture_log(fn ->
        assert :ok =
                 Notifier.deliver_for_test(event, notifications,
                   task_starter: fn fun ->
                     fun.()
                     :ok
                   end,
                   request_fun: request_fun,
                   sleep_fun: fn _delay_ms -> :ok end
                 )
      end)

    assert_receive :attempted
    assert_receive :attempted
    assert_receive :attempted
    refute_receive :attempted, 50
    assert log =~ "Dropping notification after 3 attempts"
  end
end
