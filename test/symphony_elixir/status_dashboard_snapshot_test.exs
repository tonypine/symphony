defmodule SymphonyElixir.StatusDashboardSnapshotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StatusDashboard.Renderer
  alias SymphonyElixir.TestSupport.Snapshot

  @terminal_columns 115

  test "snapshot fixture: idle dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle", render_snapshot(snapshot_data, 0.0))
  end

  test "dashboard renders workspace quota pause reason when configured" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         workspace_lifecycle: %{
           quota_configured: true,
           quota_paused: true,
           quota_reason: "workspace free space below threshold host=local free_bytes=1024 min_free_bytes=2048",
           free_bytes: 1024,
           min_free_bytes: 2048
         }
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Workspace:"
    assert rendered =~ "paused"
    assert rendered =~ "free 1.0 KiB / min 2.0 KiB"
    assert rendered =~ "Workspace reason:"
    assert rendered =~ "workspace free space below threshold"
  end

  test "snapshot fixture: idle dashboard with observability url" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle_with_dashboard_url", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: super busy dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             codex_total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_codex_event: "turn_completed",
             last_codex_message: turn_completed_message("completed"),
             run_profile: %{kind: :implementation, model: "claude-opus-5-5", effort: "high"},
             reviewer_run_profile: %{kind: :pre_push_review, model: "claude-sonnet-5-5", effort: nil}
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             codex_app_server_pid: "5252",
             codex_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_codex_event: "codex/event/task_started",
             last_codex_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         run_history: [
           %{
             issue_identifier: "MT-099",
             status: "qa_pass",
             run_kind: "qa",
             model: "claude-haiku-4-5",
             effort: "low",
             tokens: %{total_tokens: 18_200}
           },
           %{
             issue_identifier: "MT-098",
             status: "success",
             run_kind: "landing",
             model: nil,
             effort: "low",
             tokens: %{total_tokens: 4_100},
             reviewer_profile: %{run_kind: "pre_push_review", model: "claude-sonnet-5-5", effort: "medium"}
           },
           %{issue_id: "issue-old", status: nil, tokens: nil}
         ],
         codex_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         },
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 12_345, limit: 20_000, reset_in_seconds: 30},
           secondary: %{remaining: 45, limit: 60, reset_in_seconds: 12},
           credits: %{has_credits: true, balance: 9_876.5}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("super_busy", render_snapshot(snapshot_data, 1_842.7))
  end

  test "snapshot fixture: backoff queue pressure" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             codex_total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_codex_event: :notification,
             last_codex_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }),
           retry_entry(%{
             identifier: "MT-451",
             attempt: 2,
             due_in_ms: 3_900,
             error: "retrying after API timeout with jitter"
           }),
           retry_entry(%{
             identifier: "MT-452",
             attempt: 6,
             due_in_ms: 8_100,
             error: "worker crashed\nrestarting cleanly"
           }),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         codex_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 0, limit: 20_000, reset_in_seconds: 95},
           secondary: %{remaining: 0, limit: 60, reset_in_seconds: 45},
           credits: %{has_credits: false}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("backoff_queue", render_snapshot(snapshot_data, 15.4))
  end

  test "dashboard renders continuation retries as follow-up checks" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{identifier: "MT-CHECK", due_in_ms: 900, error: nil, delay_type: :continuation}),
           retry_entry(%{identifier: "MT-BACK", due_in_ms: 3_900, error: "agent exited: :boom"})
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Follow-up checks"
    assert rendered =~ "state check"

    [before_backoff, backoff_and_after] = String.split(rendered, "Backoff queue", parts: 2)
    assert before_backoff =~ "MT-CHECK"
    refute backoff_and_after =~ "MT-CHECK"
    assert backoff_and_after =~ "MT-BACK"
  end

  test "snapshot fixture: watching issues" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         watching: [
           watching_entry(%{
             identifier: "MT-901",
             state: "In Review",
             seconds_since_last_run: 7_200,
             url: "https://linear.app/example/issue/MT-901"
           }),
           watching_entry(%{
             identifier: "MT-902",
             state: "Human Review",
             seconds_since_last_run: 2_700,
             url: "https://linear.app/example/issue/MT-902"
           })
         ],
         retrying: [],
         codex_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("watching_issues", render_snapshot(snapshot_data, 0.0))
  end

  test "skipped section renders quality-gate skips with score and reason" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         skipped: [
           %{
             kind: :scored,
             issue_id: "issue-skip-1",
             identifier: "MT-SKIP",
             url: "https://example.org/MT-SKIP",
             score: 3,
             reason: "vague description",
             error: nil,
             updated_at: ~U[2026-05-05 03:00:00Z]
           },
           %{
             kind: :error,
             issue_id: "issue-skip-2",
             identifier: "MT-ERR",
             url: nil,
             score: nil,
             reason: "LLM call failed: :boom",
             error: :boom,
             updated_at: ~U[2026-05-05 03:00:00Z]
           }
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Skipped (quality gate)"
    assert rendered =~ "MT-SKIP"
    assert rendered =~ "score=3"
    assert rendered =~ "vague description"
    assert rendered =~ "MT-ERR"
    assert rendered =~ "error"
    assert rendered =~ "LLM call failed"
  end

  test "skipped section shows empty state when no issues are skipped" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         skipped: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Skipped (quality gate)"
    assert rendered =~ "No issues skipped this session"
  end

  test "awaiting clarification section renders issue identifier, round, and url" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         awaiting_clarification: [
           %{
             kind: :clarification,
             issue_id: "issue-await-1",
             identifier: "MT-AWAIT",
             url: "https://example.org/MT-AWAIT",
             score: 5,
             reason: "needs acceptance criteria",
             rounds_asked: 2,
             updated_at: ~U[2026-05-05 03:00:00Z]
           }
         ],
         skipped: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Awaiting clarification"
    assert rendered =~ "MT-AWAIT"
    assert rendered =~ "round=2"
    assert rendered =~ "https://example.org/MT-AWAIT"
  end

  test "backoff queue row escapes escaped newline sequences" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    backoff_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert length(backoff_lines) == 1

    [backoff_line] = backoff_lines

    assert backoff_line =~ "error=error with newline"
    refute backoff_line =~ "\\n"
  end

  test "backoff queue row preserves comma-space sequences in retry errors" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-981",
             attempt: 1,
             due_in_ms: 1_500,
             error: "rate limit, quota, retry after delay"
           })
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")
    [backoff_line] = plain |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-981"))

    assert backoff_line =~ "error=rate limit, quota, retry after delay"
    refute plain =~ ~r/error=rate limit\r?\nquota/
  end

  test "snapshot fixture: unlimited credits variant" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "codex/event/token_count",
             last_codex_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         codex_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75},
         rate_limits: %{
           limit_id: "priority-tier",
           primary: %{remaining: 100, limit: 100, reset_in_seconds: 1},
           secondary: %{remaining: 500, limit: 500, reset_in_seconds: 1},
           credits: %{unlimited: true}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("credits_unlimited", render_snapshot(snapshot_data, 42.0))
  end

  test "snapshot fixture: dispatch paused with operational blockers" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         dispatch_state: %{
           active?: false,
           blockers: [
             %{
               kind: :budget,
               used: 88_402_765,
               limit: 5_000_000,
               day_started_on: ~D[2026-05-08],
               resets_on: ~D[2026-05-09]
             },
             %{
               kind: :workspace_dirty,
               repo: "/Users/chihsuan/Projects/symphony",
               dirty_summary: "M WORKFLOW.md"
             }
           ]
         }
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Dispatch: "
    assert rendered =~ "paused"
    assert rendered =~ "1 blocker"
    assert rendered =~ "daily budget exhausted"
    assert rendered =~ "88,402,765 / 5,000,000"
    assert rendered =~ "resets 2026-05-09"
    refute rendered =~ "primary worktree dirty"
    refute rendered =~ "M WORKFLOW.md"
  end

  test "snapshot fixture: dispatch paused by tracker unavailable reasons" do
    for {reason, expected} <- [
          {:missing_linear_api_token, "invalid or missing API key"},
          {:linear_api_request, "Linear API request failed"},
          {:unknown, "unknown tracker failure"}
        ] do
      snapshot_data =
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil,
           dispatch_state: %{
             active?: false,
             blockers: [
               %{
                 kind: :tracker_unavailable,
                 tracker: :linear,
                 reason: reason,
                 since: ~U[2026-05-08 13:48:09Z],
                 consecutive_failures: 3
               }
             ]
           }
         }}

      rendered = render_snapshot(snapshot_data, 0.0)

      assert rendered =~ "linear tracker unavailable"
      assert rendered =~ expected
      assert rendered =~ "3 consecutive failures since 13:48:09"

      if is_atom(reason) and reason != :unknown do
        refute rendered =~ Atom.to_string(reason)
      end
    end
  end

  test "snapshot fixture: dispatch paused by invalid config blocker" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         dispatch_state: %{
           active?: false,
           blockers: [
             %{
               kind: :config_invalid,
               message: "Invalid WORKFLOW.md config: notifications.channels entries with kind: slack require webhook_url",
               since: ~U[2026-05-08 13:48:09Z],
               consecutive_failures: 3
             }
           ]
         }
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "config invalid"
    assert rendered =~ "Invalid WORKFLOW.md config: notifications.channels entries with kind: slack require webhook_url"
    assert rendered =~ "3 consecutive failures since 13:48:09"
    refute rendered =~ "linear tracker unavailable"
  end

  test "snapshot fixture: workspace dirty blocker alone does not pause dispatch" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil,
         dispatch_state: %{
           active?: false,
           blockers: [
             %{
               kind: :workspace_dirty,
               repo: "/Users/chihsuan/Projects/symphony",
               dirty_summary: "M WORKFLOW.md"
             }
           ]
         }
       }}

    rendered = render_snapshot(snapshot_data, 0.0)

    assert rendered =~ "Dispatch: "
    assert rendered =~ "active"
    refute rendered =~ "paused"
    refute rendered =~ "primary worktree dirty"
  end

  defp render_snapshot(snapshot_data, tps) do
    Renderer.format_snapshot_content(snapshot_data, tps, @terminal_columns)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_codex_event: :notification,
        last_codex_message: turn_started_message()
      },
      overrides
    )
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp watching_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-watch",
        identifier: "MT-000",
        state: "In Review",
        seconds_since_last_run: 60,
        url: "https://linear.app/example/issue/MT-000"
      },
      overrides
    )
  end

  defp turn_started_message do
    %{
      event: :notification,
      message: %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-1"}}
      }
    }
  end

  defp turn_completed_message(status) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => status}}
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{"msg" => %{"payload" => %{"delta" => delta}}}
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      }
    }
  end
end
