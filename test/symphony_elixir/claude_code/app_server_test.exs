defmodule SymphonyElixir.ClaudeCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentSandboxConfig
  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.Config.Schema.Agent
  alias SymphonyElixir.OpenRouter.Models
  import Bitwise, only: [band: 2]

  defmodule StubSSH do
    def run(worker_host, command, opts) do
      send(self(), {:stub_ssh_run, worker_host, command, opts})
      Process.get(:stub_ssh_run_result, {:ok, {"", 0}})
    end

    def start_port(_worker_host, _command, _opts), do: {:error, :unexpected_start_port}
  end

  defp expect_stub_ssh_command do
    receive do
      {:stub_ssh_run, _worker_host, command, _opts} -> command
    after
      100 -> flunk("expected an SSH stub call but none arrived")
    end
  end

  describe "build_sandbox_settings/1" do
    test "allowlist mode includes built-in domains and sets allowManagedDomainsOnly" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: ["example.com"],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "allowUnsandboxedCommands"]) == false

      # Asserts against the canonical Claude filesystem settings (which include
      # both tilde and absolute forms of home-relative deny paths as
      # defense-in-depth — see AgentSandboxConfig.expand_home_paths/1).
      expected_filesystem = AgentSandboxConfig.claude_filesystem_settings()
      assert get_in(result, ["sandbox", "filesystem", "denyRead"]) == expected_filesystem["denyRead"]
      assert get_in(result, ["sandbox", "filesystem", "denyWrite"]) == expected_filesystem["denyWrite"]

      assert get_in(result, ["sandbox", "network", "allowManagedDomainsOnly"]) == true
      assert get_in(result, ["sandbox", "network", "allowLocalBinding"]) == true

      allowed = get_in(result, ["sandbox", "network", "allowedDomains"])
      assert is_list(allowed)
      assert "github.com" in allowed
      refute "api.github.com" in allowed
      refute "api.linear.app" in allowed
      assert "example.com" in allowed
    end

    test "allowlist mode excludes denied domains" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: [],
        denied_domains: ["github.com"]
      }

      result = AppServer.build_sandbox_settings(network_access)

      allowed = get_in(result, ["sandbox", "network", "allowedDomains"])
      refute "github.com" in allowed
      assert "registry.npmjs.org" in allowed
    end

    test "block mode sets empty allowedDomains" do
      network_access = %Agent.NetworkAccess{
        mode: "block",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "network", "allowedDomains"]) == []
      assert get_in(result, ["sandbox", "network", "allowManagedDomainsOnly"]) == true
      assert get_in(result, ["sandbox", "network", "allowLocalBinding"]) == true
    end

    test "open mode allows local binding without domain narrowing" do
      network_access = %Agent.NetworkAccess{
        mode: "open",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "network"]) == %{"allowLocalBinding" => true}
    end

    test "operator allow_read_paths drops entries from sandbox denyRead" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access, ["~/.npmrc"])

      deny_read = get_in(result, ["sandbox", "filesystem", "denyRead"])
      refute "~/.npmrc" in deny_read
      assert "~/.ssh" in deny_read
    end

    test "operator allow_write_paths flow into sandbox allowWrite" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access, [], ["/private/tmp/symphony-mcp"])

      assert get_in(result, ["sandbox", "filesystem", "allowWrite"]) == ["/private/tmp/symphony-mcp"]
    end

    test "omits allowWrite when no allow_write_paths supplied" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      refute Map.has_key?(result["sandbox"]["filesystem"], "allowWrite")
    end
  end

  describe "parse_event/1" do
    test "parses system event and returns session_started tuple" do
      line =
        ~s({"type":"system","subtype":"init","session_id":"sess-abc123","cwd":"/tmp/workspace","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"})

      assert {:session_started, "sess-abc123"} = AppServer.parse_event(line)
    end

    test "maps non-init system events to notifications instead of session_started" do
      line = ~s({"type":"system","subtype":"compact_boundary","session_id":"sess-abc123"})

      assert {:notification, "system compact_boundary"} = AppServer.parse_event(line)
    end

    test "maps system events without a subtype to a generic notification" do
      line = ~s({"type":"system","session_id":"sess-abc123"})

      assert {:notification, "system event"} = AppServer.parse_event(line)
    end

    test "parses result/success event and returns turn_completed with token counts" do
      line =
        ~s({"type":"result","subtype":"success","duration_ms":1500,"duration_api_ms":1200,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-abc","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}})

      assert {:turn_completed, result} = AppServer.parse_event(line)
      assert result.input_tokens == 100
      assert result.uncached_input_tokens == 100
      assert result.output_tokens == 50
      assert result.cached_input_tokens == 0
      assert result.cache_creation_input_tokens == 0
      assert result.total_tokens == 150
    end

    test "parses result/error event and returns turn_failed with reason" do
      line = ~s({"type":"result","subtype":"error","error":"something went wrong","session_id":"sess-xyz"})

      assert {:turn_failed, "something went wrong"} = AppServer.parse_event(line)
    end

    test "parses result/error event with no error field and returns unknown error" do
      line = ~s({"type":"result","subtype":"error","session_id":"sess-xyz"})

      assert {:turn_failed, "unknown error"} = AppServer.parse_event(line)
    end

    test "classifies rate_limit_error message as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"rate_limit_error: Number of request tokens has exceeded your per-minute rate limit","session_id":"sess-rl"})

      assert {:rate_limited, info, reason} = AppServer.parse_event(line)
      assert info.retry_after_seconds == nil
      assert reason =~ "rate_limit_error"
      assert info.message == reason
    end

    test "classifies plain 'rate limit' phrase as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"Rate limit exceeded, please slow down","session_id":"sess-rl"})

      assert {:rate_limited, _info, _reason} = AppServer.parse_event(line)
    end

    test "classifies HTTP 429 message as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"HTTP 429 Too Many Requests","session_id":"sess-rl"})

      assert {:rate_limited, _info, _reason} = AppServer.parse_event(line)
    end

    test "extracts retry_after_seconds from 'retry after Ns' message" do
      line =
        ~s({"type":"result","subtype":"error","error":"rate limit reached, retry after 42 seconds","session_id":"sess-rl"})

      assert {:rate_limited, %{retry_after_seconds: 42}, _reason} = AppServer.parse_event(line)
    end

    test "extracts retry_after_seconds from 'Retry-After: N' header-style message" do
      line =
        ~s({"type":"result","subtype":"error","error":"429 Too Many Requests Retry-After: 30","session_id":"sess-rl"})

      assert {:rate_limited, %{retry_after_seconds: 30}, _reason} = AppServer.parse_event(line)
    end

    test "non-rate-limit errors stay as turn_failed" do
      line =
        ~s({"type":"result","subtype":"error","error":"connection refused","session_id":"sess-x"})

      assert {:turn_failed, "connection refused"} = AppServer.parse_event(line)
    end

    test "returns malformed for invalid JSON" do
      line = "not valid json {"

      assert {:malformed, ^line} = AppServer.parse_event(line)
    end

    test "returns malformed for valid JSON with unrecognized shape" do
      line = ~s({"type":"unknown_event","data":"something"})

      assert {:malformed, ^line} = AppServer.parse_event(line)
    end

    test "parses assistant event and returns agent_text with token usage delta" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"I will help you."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-1"})

      assert {:multi,
              [
                {:agent_text, text},
                {:token_usage_delta, %{input_tokens: 10, output_tokens: 5, cached_input_tokens: 0}}
              ]} = AppServer.parse_event(line)

      assert text =~ "I will help you."
    end

    test "parses assistant event without usage and returns agent_text only" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"Hi."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}},"session_id":"sess-1"})

      assert {:agent_text, "Hi."} = AppServer.parse_event(line)
    end

    test "parses tool_use event and returns tool_use with tool name" do
      line = ~s({"type":"tool_use","name":"bash","id":"tool-1","input":{"command":"ls"}})

      assert {:tool_use, "bash"} = AppServer.parse_event(line)
    end

    test "parses assistant event with only tool_use block returns tool_use with usage delta" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-2","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t-1","name":"bash","input":{}}],"model":"claude-opus-4-5","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-2"})

      assert {:multi,
              [
                {:tool_use, "bash"},
                {:token_usage_delta, %{input_tokens: 10, output_tokens: 5, cached_input_tokens: 0}}
              ]} = AppServer.parse_event(line)
    end

    test "parses assistant event with text and tool_use returns multi event preserving order" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-2a","type":"message","role":"assistant","content":[{"type":"text","text":"Running ls"},{"type":"tool_use","id":"t-1","name":"bash","input":{}}],"model":"claude-opus-4-5","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-2a"})

      assert {:multi,
              [
                {:agent_text, "Running ls"},
                {:tool_use, "bash"},
                {:token_usage_delta, %{input_tokens: 10, output_tokens: 5, cached_input_tokens: 0}}
              ]} = AppServer.parse_event(line)
    end

    test "parses assistant event with multiple tool_use blocks returns multi event" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-2b","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t-1","name":"bash","input":{}},{"type":"tool_use","id":"t-2","name":"read","input":{}}],"model":"claude-opus-4-5","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-2b"})

      assert {:multi,
              [
                {:tool_use, "bash"},
                {:tool_use, "read"},
                {:token_usage_delta, %{input_tokens: 10, output_tokens: 5, cached_input_tokens: 0}}
              ]} = AppServer.parse_event(line)
    end

    test "parses assistant event with non-list content returns lone usage delta when usage present" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-3","type":"message","role":"assistant","content":"text response","model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2}},"session_id":"sess-3"})

      assert {:token_usage_delta, %{input_tokens: 5, output_tokens: 2, cached_input_tokens: 0}} =
               AppServer.parse_event(line)
    end

    test "parses assistant event with cache_read_input_tokens" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-cache","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":3,"output_tokens":2,"cache_read_input_tokens":50,"cache_creation_input_tokens":4}},"session_id":"sess-cache"})

      assert {:multi,
              [
                {:agent_text, "hi"},
                {:token_usage_delta,
                 %{
                   input_tokens: 57,
                   uncached_input_tokens: 3,
                   output_tokens: 2,
                   cached_input_tokens: 50,
                   cache_creation_input_tokens: 4
                 }}
              ]} = AppServer.parse_event(line)
    end

    test "preserves full assistant text without truncation" do
      long_text = String.duplicate("a", 500)

      line =
        ~s({"type":"assistant","message":{"id":"msg-4","type":"message","role":"assistant","content":[{"type":"text","text":"#{long_text}"}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-4"})

      assert {:multi, [{:agent_text, ^long_text}, {:token_usage_delta, _}]} =
               AppServer.parse_event(line)
    end

    test "returns malformed for assistant events without message" do
      line = ~s({"type":"assistant","session_id":"sess-1"})

      assert {:malformed, ^line} = AppServer.parse_event(line)
    end

    test "parses user/tool_result event with string content and returns tool_result" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"Hello world"}]},"session_id":"sess-1"})

      assert {:tool_result, "Hello world"} = AppServer.parse_event(line)
    end

    test "preserves full tool_result body without truncation" do
      long_text = String.duplicate("a", 500)

      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"#{long_text}"}]},"session_id":"sess-tr"})

      assert {:tool_result, ^long_text} = AppServer.parse_event(line)
    end

    test "parses user/tool_result event with nested tool_reference content" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":[{"type":"tool_reference","tool_name":"Read"}]}]},"session_id":"sess-1"})

      assert {:tool_result, "Read"} = AppServer.parse_event(line)
    end

    test "parses user event with multiple tool_result blocks returns multi event" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-1","content":"first"},{"type":"tool_result","tool_use_id":"t-2","content":"second"}]},"session_id":"sess-multi"})

      assert {:multi, [{:tool_result, "first"}, {:tool_result, "second"}]} =
               AppServer.parse_event(line)
    end

    test "parses user/tool_result event with no recognizable content and returns generic notification" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[]},"session_id":"sess-1"})

      assert {:notification, "tool_result"} = AppServer.parse_event(line)
    end

    test "parses rate_limit_event with allowed_warning status as a notification that remembers the window" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1778749200,"rateLimitType":"seven_day","utilization":0.93,"isUsingOverage":false,"surpassedThreshold":0.75},"uuid":"u-1","session_id":"sess-1"})

      assert {:usage_window, text, window} = AppServer.parse_event(line)
      assert text =~ "seven_day"
      assert text =~ "allowed_warning"
      assert text =~ "93"

      assert window == %{
               window: "seven_day",
               status: "allowed_warning",
               resets_at: DateTime.from_unix!(1_778_749_200),
               utilization: 0.93
             }
    end

    test "parses rate_limit_event with integer utilization" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"seven_day","utilization":1},"uuid":"u-1","session_id":"sess-1"})

      assert {:usage_window, text, %{resets_at: nil, utilization: 1}} = AppServer.parse_event(line)
      assert text =~ "seven_day"
      assert text =~ "allowed_warning"
      assert text =~ "100"
    end

    test "parses an allowed rate_limit_event without a usage window as a plain notification" do
      line = ~s({"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"sess-1"})

      assert {:notification, "rate_limit rate_limit allowed"} = AppServer.parse_event(line)
    end

    test "parses rate_limit_event with blocking status as rate_limited" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"exceeded","rateLimitType":"per_minute","utilization":1.05},"uuid":"u-1","session_id":"sess-1"})

      assert {:multi, [{:rate_limit_info, %{"rateLimitType" => "per_minute"}}, {:rate_limited, info, reason}]} =
               AppServer.parse_event(line)

      assert reason =~ "per_minute"
      assert reason =~ "exceeded"
      assert info.message == reason
      assert info.retry_after_seconds == nil
    end

    test "parses a rejected five_hour rate_limit_event as a usage limit with its reset time" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1759528800,"rateLimitType":"five_hour","utilization":1.0,"isUsingOverage":false,"overageStatus":"rejected"},"session_id":"sess-1"})

      assert {:multi, [{:rate_limit_info, %{"status" => "rejected"}}, {:usage_limited, info}]} =
               AppServer.parse_event(line)

      assert info == %{
               provider: "anthropic",
               window: "five_hour",
               scope: :all,
               resets_at: ~U[2025-10-03 22:00:00Z],
               utilization: 1.0,
               overage: "rejected",
               source: :rate_limit_event
             }
    end

    test "parses a rejected seven_day_opus rate_limit_event as an opus-scoped usage limit" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day_opus"},"session_id":"sess-1"})

      assert {:multi, [_raw, {:usage_limited, %{window: "seven_day_opus", scope: "opus", resets_at: nil, utilization: nil}}]} =
               AppServer.parse_event(line)
    end

    test "parses a rejected seven_day_sonnet rate_limit_event as a sonnet-scoped usage limit" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day_sonnet","resetsAt":-5},"session_id":"sess-1"})

      assert {:multi, [_raw, {:usage_limited, %{scope: "sonnet", resets_at: nil}}]} = AppServer.parse_event(line)
    end

    test "drops a resetsAt that is out of DateTime range" do
      line =
        ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":999999999999999},"session_id":"sess-1"})

      assert {:multi, [_raw, {:usage_limited, %{window: "seven_day", resets_at: nil}}]} = AppServer.parse_event(line)
    end

    test "does not treat a spent window as a usage limit while overage is in use" do
      for overage <- [~s("isUsingOverage":true), ~s("overageStatus":"allowed")] do
        line =
          ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour",#{overage}},"session_id":"sess-1"})

        assert {:multi, [_raw, {:rate_limited, %{retry_after_seconds: nil}, "rate_limit five_hour rejected"}]} =
                 AppServer.parse_event(line)
      end
    end

    test "parses the older usage-limit result text with and without an epoch reset time" do
      line =
        ~s({"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1759528800","session_id":"sess-1"})

      assert {:usage_limited, %{provider: "anthropic", window: nil, scope: :all, resets_at: ~U[2025-10-03 22:00:00Z], source: :result_text}} =
               AppServer.parse_event(line)

      line =
        ~s({"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached","session_id":"sess-1"})

      assert {:usage_limited, %{resets_at: nil, source: :result_text}} = AppServer.parse_event(line)
    end

    test "parses the newer usage-limit result text with and without a reset time" do
      line =
        ~s|{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 3pm (UTC)","session_id":"sess-1"}|

      assert {:usage_limited, %{source: :result_text, resets_at: %DateTime{} = resets_at}} = AppServer.parse_event(line)
      assert {resets_at.hour, resets_at.minute} == {15, 0}
      assert DateTime.diff(resets_at, DateTime.utc_now()) in 0..86_400

      line = ~s({"type":"result","subtype":"error","is_error":true,"error":"You've hit your weekly limit","session_id":"sess-1"})

      assert {:usage_limited, %{resets_at: nil, source: :result_text}} = AppServer.parse_event(line)
    end

    test "resolves newer usage-limit reset times in UTC-like zones and leaves other zones unknown" do
      parse = fn reset ->
        line =
          Jason.encode!(%{"type" => "result", "subtype" => "success", "is_error" => true, "result" => "You've hit your session limit · resets #{reset}"})

        assert {:usage_limited, %{resets_at: resets_at}} = AppServer.parse_event(line)
        resets_at
      end

      now = DateTime.utc_now()

      assert %DateTime{hour: 12, minute: 30} = parse.("12:30am (GMT+12)")
      assert %DateTime{hour: 15, minute: 15} = parse.("10:15 (UTC-05:00)")
      assert %DateTime{hour: 9, minute: 0} = parse.("9 (UTC)")
      assert %DateTime{hour: 0, minute: 0} = parse.("12am (Etc/UTC)")

      tomorrow = Date.add(DateTime.to_date(now), 1)
      month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), tomorrow.month - 1)
      dated = parse.("#{month} #{tomorrow.day}, 3pm (UTC)")
      assert DateTime.to_date(dated) == tomorrow

      yesterday = Date.add(DateTime.to_date(now), -1)
      month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), yesterday.month - 1)
      assert parse.("#{month} #{yesterday.day} at 3pm (UTC)").year > yesterday.year

      assert parse.("3pm (America/Los_Angeles)") == nil
      assert parse.("soon (UTC)") == nil
      assert parse.("25pm (UTC)") == nil
      assert parse.("Foo 3, 3pm (UTC)") == nil
      assert parse.("Feb 31, 3pm (UTC)") == nil
    end

    test "keeps a 429 result error on the throttle path" do
      line =
        ~s({"type":"result","subtype":"error","is_error":true,"error":"API Error: 429 Too Many Requests","session_id":"sess-1"})

      assert {:rate_limited, %{retry_after_seconds: nil}, "API Error: 429 Too Many Requests"} = AppServer.parse_event(line)
    end

    test "keeps today's parsing for error results without usage-limit text" do
      line = ~s({"type":"result","subtype":"success","is_error":true,"result":"Something else","usage":{}})
      assert {:turn_completed, _usage} = AppServer.parse_event(line)

      line = ~s({"type":"result","subtype":"success","is_error":true,"usage":{}})
      assert {:turn_completed, _usage} = AppServer.parse_event(line)

      line = ~s({"type":"result","subtype":"error_max_turns","is_error":false})
      assert {:malformed, ^line} = AppServer.parse_event(line)
    end
  end

  describe "event_to_update/1" do
    test "converts {:rate_limited, info} into a worker update map with synthesized rate_limits" do
      info = %{retry_after_seconds: 60, message: "rate limit exceeded"}

      assert %{event: :rate_limited, timestamp: %DateTime{}, rate_limits: rate_limits} =
               AppServer.event_to_update({:rate_limited, info})

      assert rate_limits.limit_id == "claude-throttled"
      assert rate_limits.primary == %{remaining: 0, reset_in_seconds: 60}
    end

    test "converts usage-limit and usage-window events into worker update maps" do
      info = %{
        provider: "anthropic",
        window: "five_hour",
        scope: :all,
        resets_at: ~U[2025-10-03 22:00:00Z],
        utilization: 1.0,
        overage: nil,
        source: :rate_limit_event
      }

      assert %{event: :usage_limited, timestamp: %DateTime{}, usage_limit: ^info, message: message} =
               AppServer.event_to_update({:usage_limited, info})

      assert message == "usage_limited five_hour resets_at=2025-10-03T22:00:00Z"

      assert %{message: "usage_limited unknown"} = AppServer.event_to_update({:usage_limited, %{info | window: nil, resets_at: nil}})

      windows = %{"five_hour" => %{status: "allowed", resets_at: nil, utilization: 0.5}}

      assert %{event: :notification, payload: "rate_limit five_hour allowed", usage_windows: ^windows} =
               update = AppServer.event_to_update({:usage_window, "rate_limit five_hour allowed", windows})

      refute Map.has_key?(update, :rate_limits)
    end

    test "omits reset_in_seconds when retry_after_seconds is nil" do
      info = %{retry_after_seconds: nil, message: "rate limited"}

      assert %{rate_limits: %{primary: primary}} =
               AppServer.event_to_update({:rate_limited, info})

      assert primary == %{remaining: 0}
    end

    test "converts Claude progress events into worker update maps" do
      assert %{
               event: :session_started,
               timestamp: %DateTime{},
               session_id: "sess-1",
               payload: %{session_id: "sess-1"}
             } = AppServer.event_to_update({:session_started, "sess-1"})

      assert %{
               event: :notification,
               timestamp: %DateTime{},
               payload: "hello"
             } = AppServer.event_to_update({:notification, "hello"})

      assert %{
               event: :agent_text,
               timestamp: %DateTime{},
               payload: %{method: "agent_message_delta", params: %{msg: %{content: "hi"}}}
             } = AppServer.event_to_update({:agent_text, "hi"})

      assert %{
               event: :tool_use,
               timestamp: %DateTime{},
               payload: %{method: "item/tool/call", params: %{tool: "bash"}}
             } = AppServer.event_to_update({:tool_use, "bash"})

      assert %{
               event: :tool_result,
               timestamp: %DateTime{},
               payload: %{method: "item/tool/result", params: %{text: "ok"}}
             } = AppServer.event_to_update({:tool_result, "ok"})

      usage = %{input_tokens: 10, cached_input_tokens: 3, output_tokens: 5, total_tokens: 15}

      assert %{
               event: :turn_completed,
               timestamp: %DateTime{},
               usage: ^usage,
               payload: %{method: "turn/completed", usage: ^usage}
             } = AppServer.event_to_update({:turn_completed, usage})

      assert %{
               event: :token_count,
               timestamp: %DateTime{},
               usage: ^usage,
               payload: %{method: "token_count", usage: ^usage}
             } = AppServer.event_to_update({:token_usage, usage})

      assert %{
               event: :turn_failed,
               timestamp: %DateTime{},
               reason: "boom",
               payload: %{method: "turn/failed", params: %{error: %{message: "boom"}}}
             } = AppServer.event_to_update({:turn_failed, "boom"})
    end

    test "returns nil for malformed events that don't need orchestrator state" do
      assert AppServer.event_to_update({:malformed, "not json"}) == nil
    end
  end

  describe "start_session/2" do
    test "writes private settings file and returns ok session for valid local workspace" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-start-session-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-1")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        assert {:ok, session} = AppServer.start_session(workspace)
        assert session.workspace == canonical_workspace
        assert session.worker_host == nil
        assert is_map(session.metadata)

        workspace_settings_path = Path.join(workspace, ".claude/settings.json")
        refute File.exists?(workspace_settings_path)

        settings_path = session.settings_path
        mcp_config_path = session.mcp_config_path
        refute String.starts_with?(settings_path, workspace)
        refute String.starts_with?(mcp_config_path, workspace)
        assert Path.dirname(mcp_config_path) == Path.dirname(settings_path)
        assert File.exists?(settings_path)
        assert File.exists?(mcp_config_path)
        assert band(File.stat!(Path.dirname(settings_path)).mode, 0o777) == 0o700
        assert band(File.stat!(settings_path).mode, 0o777) == 0o600
        assert band(File.stat!(mcp_config_path).mode, 0o777) == 0o600

        {:ok, contents} = Jason.decode(File.read!(settings_path))
        assert get_in(contents, ["sandbox", "enabled"]) == true
        refute Map.has_key?(contents, "mcpServers")

        {:ok, mcp_config} = Jason.decode(File.read!(mcp_config_path))

        {shim_command, shim_args, shim_env} =
          SymphonyElixir.McpShimCommand.build(
            session.mcp_session.shim_path,
            Enum.take(get_in(mcp_config, ["mcpServers", "symphony", "args"]), if(session.mcp_session.transport == :tcp, do: -4, else: -2))
          )

        assert get_in(mcp_config, ["mcpServers", "symphony", "command"]) == shim_command
        assert get_in(mcp_config, ["mcpServers", "symphony", "args"]) == shim_args
        assert Map.take(get_in(mcp_config, ["mcpServers", "symphony", "env"]), Map.keys(shim_env)) == shim_env

        assert_claude_mcp_config_matches_transport(mcp_config, session.mcp_session)

        assert get_in(mcp_config, ["mcpServers", "symphony", "env", "SYMPHONY_MCP_SESSION_TOKEN"]) ==
                 session.mcp_session.token

        assert get_in(mcp_config, ["mcpServers", "symphony", "env", "PATH"]) == System.get_env("PATH")
        assert get_in(mcp_config, ["mcpServers", "symphony", "alwaysLoad"]) == true

        assert get_in(contents, ["permissions", "deny"]) == [
                 "Bash(gh:*)",
                 "Bash(ghe:*)",
                 "Bash(git push:*)",
                 "Bash(git remote add:*)",
                 "Bash(git remote set-url:*)"
               ]

        if session.mcp_session.transport == :unix do
          assert File.exists?(session.mcp_session.socket_path)
        end

        # Shared skills are provisioned as a session-only Claude plugin outside the worktree.
        plugin_dir = session.plugin_dir
        assert Path.dirname(plugin_dir) == Path.dirname(settings_path)
        refute String.starts_with?(plugin_dir, workspace)

        {:ok, manifest} = Jason.decode(File.read!(Path.join(plugin_dir, ".claude-plugin/plugin.json")))
        assert manifest["name"] == SymphonyElixir.SharedSkills.plugin_name()

        for name <- SymphonyElixir.SharedSkills.names() do
          skill_path = Path.join([plugin_dir, "skills", name, "SKILL.md"])
          assert File.exists?(skill_path)
          assert File.read!(skill_path) =~ "name: #{name}"
        end

        assert :ok = AppServer.stop_session(session)
        refute File.exists?(settings_path)
        refute File.exists?(mcp_config_path)
        refute File.exists?(plugin_dir)
        refute File.exists?(Path.dirname(settings_path))

        if session.mcp_session.transport == :unix do
          refute File.exists?(session.mcp_session.socket_path)
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "emits workspace.sandbox.allow_write_paths into sandbox.filesystem.allowWrite" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-allow-write-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-ALLOW-WRITE")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          workspace_sandbox: %{allow_write_paths: ["/private/tmp/symphony-mcp", "/opt/cache"]}
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        {:ok, contents} = Jason.decode(File.read!(session.settings_path))

        assert get_in(contents, ["sandbox", "filesystem", "allowWrite"]) ==
                 ["/private/tmp/symphony-mcp", "/opt/cache"]

        assert :ok = AppServer.stop_session(session)
      after
        File.rm_rf(test_root)
      end
    end

    test "writes declared MCP servers for Claude and filters Codex-only declarations" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-mcp-config-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-MCP")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_mcp: %{
            servers: %{
              "stdio-server" => %{
                transport: "stdio",
                command: "node",
                args: ["/srv/stdio.js"],
                env: %{LOG_LEVEL: "info"},
                runtimes: ["claude", "codex"]
              },
              "http-server" => %{
                transport: "http",
                url: "https://mcp.example/http",
                headers: %{Authorization: "Bearer test"},
                runtimes: ["claude"]
              },
              "sse-server" => %{
                transport: "sse",
                url: "https://mcp.example/sse",
                runtimes: ["claude"]
              },
              "codex-only" => %{
                transport: "stdio",
                command: "codex-only",
                runtimes: ["codex"]
              }
            }
          }
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        {:ok, mcp_config} = Jason.decode(File.read!(session.mcp_config_path))
        servers = mcp_config["mcpServers"]

        assert Map.has_key?(servers, "symphony")

        assert servers["stdio-server"] == %{
                 "command" => "node",
                 "args" => ["/srv/stdio.js"],
                 "env" => %{"LOG_LEVEL" => "info"}
               }

        assert servers["http-server"] == %{
                 "type" => "http",
                 "url" => "https://mcp.example/http",
                 "headers" => %{"Authorization" => "Bearer test"}
               }

        assert servers["sse-server"] == %{
                 "type" => "sse",
                 "url" => "https://mcp.example/sse"
               }

        refute Map.has_key?(servers, "codex-only")
        assert :ok = AppServer.stop_session(session)
      after
        File.rm_rf(test_root)
      end
    end

    test "inherits allowlisted Claude MCP servers from user Claude config" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-mcp-inherit-#{System.unique_integer([:positive])}"
        )

      previous_home = System.get_env("HOME")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-MCP-INHERIT")
        fake_home = Path.join(test_root, "home")
        File.mkdir_p!(workspace)
        File.mkdir_p!(fake_home)
        System.put_env("HOME", fake_home)

        File.write!(
          Path.join(fake_home, ".claude.json"),
          Jason.encode!(%{
            "mcpServers" => %{
              "filesystem" => %{"command" => "node", "args" => ["/srv/filesystem.js"]},
              "github" => %{"type" => "http", "url" => "https://mcp.example/github"},
              "slack" => %{"command" => "slack-mcp"}
            }
          })
        )

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_mcp: %{
            inherit: "allowlist",
            allowed_servers: ["filesystem", "github", "missing"]
          }
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        {:ok, mcp_config} = Jason.decode(File.read!(session.mcp_config_path))
        servers = mcp_config["mcpServers"]

        assert Map.has_key?(servers, "symphony")
        assert servers["filesystem"] == %{"command" => "node", "args" => ["/srv/filesystem.js"]}
        assert servers["github"] == %{"type" => "http", "url" => "https://mcp.example/github"}
        refute Map.has_key?(servers, "slack")
        refute Map.has_key?(servers, "missing")

        assert :ok = AppServer.stop_session(session)
      after
        restore_env("HOME", previous_home)
        File.rm_rf(test_root)
      end
    end

    test "declared Claude MCP server overrides inherited server with the same name" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-mcp-override-#{System.unique_integer([:positive])}"
        )

      previous_home = System.get_env("HOME")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-MCP-OVERRIDE")
        fake_home = Path.join(test_root, "home")
        File.mkdir_p!(workspace)
        File.mkdir_p!(fake_home)
        System.put_env("HOME", fake_home)

        File.write!(
          Path.join(fake_home, ".claude.json"),
          Jason.encode!(%{
            "mcpServers" => %{
              "filesystem" => %{"command" => "host-node", "args" => ["/host/filesystem.js"]}
            }
          })
        )

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_mcp: %{
            inherit: "allowlist",
            allowed_servers: ["filesystem"],
            servers: %{
              "filesystem" => %{
                transport: "stdio",
                command: "declared-node",
                args: ["/declared/filesystem.js"],
                runtimes: ["claude"]
              }
            }
          }
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        {:ok, mcp_config} = Jason.decode(File.read!(session.mcp_config_path))

        assert get_in(mcp_config, ["mcpServers", "filesystem"]) == %{
                 "command" => "declared-node",
                 "args" => ["/declared/filesystem.js"]
               }

        assert :ok = AppServer.stop_session(session)
      after
        restore_env("HOME", previous_home)
        File.rm_rf(test_root)
      end
    end

    test "returns structured errors when inherited Claude config is malformed" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-mcp-error-#{System.unique_integer([:positive])}"
        )

      previous_home = System.get_env("HOME")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-MCP-ERROR")
        fake_home = Path.join(test_root, "home")
        claude_json_path = Path.join(fake_home, ".claude.json")
        File.mkdir_p!(workspace)
        File.mkdir_p!(fake_home)
        System.put_env("HOME", fake_home)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_mcp: %{
            inherit: "allowlist",
            allowed_servers: ["filesystem"]
          }
        )

        cases = [
          {"{", :decode_failed},
          {Jason.encode!(%{}), :missing_mcp_servers},
          {Jason.encode!(%{"mcpServers" => []}), :invalid_mcp_servers}
        ]

        for {contents, expected} <- cases do
          File.write!(claude_json_path, contents)

          case expected do
            :decode_failed ->
              assert {:error, {:claude_mcp_inheritance_decode_failed, ^claude_json_path, %Jason.DecodeError{}}} =
                       AppServer.start_session(workspace)

            reason ->
              assert {:error, {:claude_mcp_inheritance_invalid_config, ^claude_json_path, ^reason}} =
                       AppServer.start_session(workspace)
          end
        end
      after
        restore_env("HOME", previous_home)
        File.rm_rf(test_root)
      end
    end

    test "returns error for workspace outside workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-session-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
                 AppServer.start_session(outside_workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "does not use workspace .claude path for private settings" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-fail-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-SETTINGS")
        claude_path = Path.join(workspace, ".claude")
        File.mkdir_p!(workspace)
        File.write!(claude_path, "not a directory")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        refute String.starts_with?(session.settings_path, workspace)
        refute String.starts_with?(session.mcp_config_path, workspace)
        assert File.exists?(session.settings_path)
        assert File.exists?(session.mcp_config_path)
        assert File.read!(claude_path) == "not a directory"

        assert :ok = AppServer.stop_session(session)
      after
        File.rm_rf(test_root)
      end
    end

    test "leaves workspace settings untouched and writes token only to private MCP config" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-write-fail-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-SETTINGS-WRITE")
        settings_path = Path.join(workspace, ".claude/settings.json")
        File.mkdir_p!(Path.dirname(settings_path))
        File.write!(settings_path, ~s({"permissions":{"deny":[]}}))

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        refute session.settings_path == settings_path
        assert File.read!(settings_path) == ~s({"permissions":{"deny":[]}})
        refute File.read!(settings_path) =~ session.mcp_session.token
        refute File.read!(session.settings_path) =~ session.mcp_session.token
        assert File.read!(session.mcp_config_path) =~ session.mcp_session.token

        assert :ok = AppServer.stop_session(session)
      after
        File.rm_rf(test_root)
      end
    end

    test "returns structured error when settings JSON cannot be encoded" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-encode-fail-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:symphony_elixir, :claude_settings_json_encoder, fn _value, _opts ->
        {:error, :bad_json}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_settings_json_encoder) end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-SETTINGS-ENCODE")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:claude_settings_encode_failed, :bad_json}} =
                 AppServer.start_session(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when workspace path cannot be read due to permissions" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-unreadable-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        locked_dir = Path.join(workspace_root, "locked")
        workspace = Path.join(locked_dir, "ACME-99")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        # Remove read/execute permission on parent dir so lstat on workspace fails
        File.chmod!(locked_dir, 0o000)

        assert {:error, {:invalid_workspace_cwd, :path_unreadable, _, _}} =
                 AppServer.start_session(workspace)
      after
        locked_dir = Path.join(Path.join(test_root, "workspaces"), "locked")

        if File.exists?(locked_dir) or not is_nil(File.stat(locked_dir)) do
          File.chmod(locked_dir, 0o755)
        end

        File.rm_rf(test_root)
      end
    end

    test "returns error when workspace path equals the workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-workspace-root-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
                 AppServer.start_session(workspace_root)
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts remote worker host without validating against workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-session-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "remote-settings.trace")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, trace_only_ssh_script(trace_file))
        File.chmod!(fake_ssh, 0o755)

        assert {:ok, session} =
                 AppServer.start_session(test_root, worker_host: "worker-01")

        assert session.workspace == test_root
        assert session.worker_host == "worker-01"
        assert session.settings_path =~ "/tmp/symphony-claude-settings-"
        assert String.ends_with?(session.settings_path, "/settings.json")
        assert session.mcp_config_path =~ "/tmp/symphony-claude-settings-"
        assert String.ends_with?(session.mcp_config_path, "/mcp_config.json")
        refute File.exists?(session.settings_path)
        refute File.exists?(session.mcp_config_path)

        traced_command = File.read!(trace_file)
        assert traced_command =~ "umask 077"
        assert traced_command =~ "chmod 0700"
        assert traced_command =~ "chmod 0600"
        assert traced_command =~ "> '\"'\"'/tmp/symphony-claude-settings-"
        assert traced_command =~ "settings.json"
        assert traced_command =~ "mcp_config.json"
        assert traced_command =~ "mcpServers"
        assert traced_command =~ "alwaysLoad"
        assert traced_command =~ "symphony-mcp-shim"
        assert traced_command =~ "/tmp/symphony-mcp-"
        # Shared-skills plugin tree is provisioned on the remote worker too.
        assert session.plugin_dir =~ "/tmp/symphony-claude-settings-"
        assert String.ends_with?(session.plugin_dir, "/plugin")
        assert traced_command =~ "mkdir -p"
        assert traced_command =~ ".claude-plugin/plugin.json"
        assert traced_command =~ "SKILL.md"
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects empty workspace path for remote workers" do
      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, _}} =
               AppServer.start_session("   ", worker_host: "worker-01")
    end

    test "rejects workspace path with newline for remote workers" do
      assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, _, _}} =
               AppServer.start_session("/remote/work\nspace", worker_host: "worker-01")
    end

    test "returns structured error when remote shim install exits non-zero" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-settings-fail-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, failing_ssh_script(42))
        File.chmod!(fake_ssh, 0o755)

        assert {:error, {:claude_mcp_shim_install_failed, "worker-01", 42, output}} =
                 AppServer.start_session(test_root, worker_host: "worker-01")

        assert output =~ "ssh failed"
      after
        File.rm_rf(test_root)
      end
    end

    test "returns structured error when ssh is unavailable for remote shim install" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-settings-no-ssh-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root)

        assert {:error, {:claude_mcp_shim_install_failed, "worker-01", :ssh_not_found}} =
                 AppServer.start_session(test_root, worker_host: "worker-01")
      after
        File.rm_rf(test_root)
      end
    end

    test "installs MCP shim on remote worker and references it in settings.json" do
      Application.put_env(:symphony_elixir, :claude_code_ssh_module, StubSSH)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_code_ssh_module) end)

      assert {:ok, session} = AppServer.start_session("/remote/workspace", worker_host: "worker-01")

      install_command = expect_stub_ssh_command()
      assert install_command =~ "printf %s "
      assert install_command =~ "/tmp/symphony-mcp-shim-"
      assert install_command =~ "chmod 0700"

      settings_command = expect_stub_ssh_command()
      assert settings_command =~ "/tmp/symphony-claude-settings-"
      assert settings_command =~ "chmod 0600"
      assert settings_command =~ "> '/tmp/symphony-claude-settings-"
      assert settings_command =~ "settings.json"
      assert settings_command =~ "mcp_config.json"
      assert settings_command =~ "alwaysLoad"
      assert settings_command =~ session.mcp_remote_shim_path
      assert session.mcp_remote_shim_path =~ "/tmp/symphony-mcp-shim-"
    end
  end

  describe "stop_session/1" do
    test "always returns :ok" do
      assert :ok = AppServer.stop_session(%{workspace: "/tmp/ws", metadata: %{}, worker_host: nil})
    end

    test "returns ok when local Claude settings file is already gone without removing its shared parent dir" do
      missing_path = Path.join(System.tmp_dir!(), "missing-claude-settings-#{System.unique_integer([:positive])}.json")
      sibling_path = Path.join(System.tmp_dir!(), "claude-settings-sibling-#{System.unique_integer([:positive])}")
      File.write!(sibling_path, "keep")
      on_exit(fn -> File.rm(sibling_path) end)

      assert :ok =
               AppServer.stop_session(%{
                 workspace: "/tmp/ws",
                 metadata: %{},
                 worker_host: nil,
                 settings_path: missing_path
               })

      assert File.read!(sibling_path) == "keep"
    end

    test "logs and returns ok when local Claude settings cleanup fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-stop-session-fail-#{System.unique_integer([:positive])}"
        )

      try do
        settings_path = Path.join(test_root, ".claude/settings.json")
        File.mkdir_p!(settings_path)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: test_root,
                       metadata: %{},
                       worker_host: nil,
                       settings_path: settings_path
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
      after
        File.rm_rf(test_root)
      end
    end

    test "removes local Claude settings file when a session stops" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-stop-session-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-STOP")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        assert File.exists?(session.settings_path)
        assert File.exists?(session.mcp_config_path)

        assert :ok = AppServer.stop_session(session)
        refute File.exists?(session.settings_path)
        refute File.exists?(session.mcp_config_path)
      after
        File.rm_rf(test_root)
      end
    end

    test "removes remote Claude settings file over ssh when a session stops" do
      Application.put_env(:symphony_elixir, :claude_code_ssh_module, StubSSH)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_code_ssh_module) end)

      assert :ok =
               AppServer.stop_session(%{
                 workspace: "/remote/workspace",
                 metadata: %{},
                 worker_host: "worker-01",
                 settings_path: "/remote/workspace/.claude/settings.json",
                 mcp_config_path: "/remote/workspace/.claude/mcp_config.json",
                 mcp_remote_socket_path: "/tmp/symphony-mcp-remote.sock",
                 mcp_remote_shim_path: "/tmp/symphony-mcp-shim-remote"
               })

      assert_receive {:stub_ssh_run, "worker-01", command, [stderr_to_stdout: true]}
      assert command =~ "rm -f '/remote/workspace/.claude/settings.json'"
      assert command =~ "rm -f '/remote/workspace/.claude/mcp_config.json'"
      assert command =~ "rm -f '/tmp/symphony-mcp-remote.sock'"
      assert command =~ "rm -f '/tmp/symphony-mcp-shim-remote'"
      assert command =~ "rm -rf '/remote/workspace/.claude' 2>/dev/null || true"
    end

    test "logs and returns ok when stubbed remote Claude settings cleanup fails" do
      Application.put_env(:symphony_elixir, :claude_code_ssh_module, StubSSH)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_code_ssh_module) end)

      Process.put(:stub_ssh_run_result, {:ok, {"permission denied", 23}})

      log =
        capture_log(fn ->
          assert :ok =
                   AppServer.stop_session(%{
                     workspace: "/remote/workspace",
                     metadata: %{},
                     worker_host: "worker-01",
                     settings_path: "/remote/workspace/.claude/settings.json",
                     mcp_config_path: "/remote/workspace/.claude/mcp_config.json"
                   })
        end)

      assert_receive {:stub_ssh_run, "worker-01", command, [stderr_to_stdout: true]}
      assert command =~ ".claude/settings.json"
      assert command =~ ".claude/mcp_config.json"
      assert log =~ "Claude settings cleanup failed"
      assert log =~ "status=23"
      assert log =~ "permission denied"
    end

    test "removes remote Claude settings file through ssh command integration when a session stops" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-session-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "remote-stop.trace")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, trace_only_ssh_script(trace_file))
        File.chmod!(fake_ssh, 0o755)

        assert :ok =
                 AppServer.stop_session(%{
                   workspace: "/remote/workspace",
                   metadata: %{},
                   worker_host: "worker-01",
                   settings_path: "/remote/workspace/.claude/settings.json",
                   mcp_config_path: "/remote/workspace/.claude/mcp_config.json",
                   mcp_remote_socket_path: "/tmp/symphony-mcp-remote.sock"
                 })

        traced_command = File.read!(trace_file)
        assert traced_command =~ "rm -f"
        assert traced_command =~ ".claude/settings.json"
        assert traced_command =~ ".claude/mcp_config.json"
      after
        File.rm_rf(test_root)
      end
    end

    test "logs and returns ok when remote Claude settings cleanup fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-fail-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, failing_ssh_script(23))
        File.chmod!(fake_ssh, 0o755)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: "/remote/workspace",
                       metadata: %{},
                       worker_host: "worker-01",
                       settings_path: "/remote/workspace/.claude/settings.json"
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
        assert log =~ "status=23"
      after
        File.rm_rf(test_root)
      end
    end

    test "logs and returns ok when ssh is unavailable for remote settings cleanup" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-no-ssh-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: "/remote/workspace",
                       metadata: %{},
                       worker_host: "worker-01",
                       settings_path: "/remote/workspace/.claude/settings.json"
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
        assert log =~ ":ssh_not_found"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "run_turn/4" do
    test "runs a successful turn and returns token usage" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-1")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-run-1","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-run-1"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-run-1","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)
        assert result.input_tokens == 10
        assert result.output_tokens == 5
        refute Map.has_key?(result, :diagnostic_output_lines)

        assert_received {:turn_msg, {:agent_text, _}}
        assert_received {:turn_msg, {:token_usage, %{input_tokens: 10, output_tokens: 5, total_tokens: 15}}}
        assert_received {:turn_msg, {:turn_completed, _}}
      after
        File.rm_rf(test_root)
      end
    end

    test "logs the pid, command and run id of the Claude process it starts" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-priority-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-1")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-nice","usage":{"input_tokens":1,"output_tokens":1}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        log =
          capture_log(fn ->
            assert {:ok, _result} = AppServer.run_turn(session, "do the thing", %{}, run_id: "run-claude-nice")
          end)

        # Sandboxed test runs can't lower the priority, so either message is logged.
        assert log =~ ~r/Started agent (below|at) Symphony's CPU priority.* pid=\d+ run_id=run-claude-nice command="#{fake_claude}"/
      after
        File.rm_rf(test_root)
      end
    end

    @tag :process_table
    @tag :setpriority
    test "Claude and the processes it starts run below Symphony's CPU priority" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-niceness-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-1")
        fake_claude = Path.join(test_root, "fake-claude")
        trace = Path.join(test_root, "niceness.trace")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        ps -o nice= -p $$ > "#{trace}"
        sh -c 'ps -o nice= -p $$' >> "#{trace}"
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-nice","usage":{"input_tokens":1,"output_tokens":1}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        assert {:ok, _result} = AppServer.run_turn(session, "do the thing", %{}, [])

        {symphony, 0} = System.cmd("ps", ["-o", "nice=", "-p", System.pid()])
        assert [agent, child] = trace |> File.read!() |> String.split() |> Enum.map(&String.to_integer/1)
        assert agent > String.to_integer(String.trim(symphony))
        assert child == agent
      after
        File.rm_rf(test_root)
      end
    end

    test "returns a typed usage limit when Claude rejects the five-hour window" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-usage-limit-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-LIMIT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-limit","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"none"}'
        printf '%s\\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1759528800,"rateLimitType":"five_hour","utilization":0.9},"session_id":"sess-limit"}'
        printf '%s\\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1759528800,"rateLimitType":"five_hour","utilization":1.0,"overageStatus":"rejected"},"session_id":"sess-limit"}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1759532400","session_id":"sess-limit","usage":{}}'
        exit 1
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end
        issue = %{id: "issue-limit", identifier: "ACME-LIMIT"}

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(test_pid, {:result, AppServer.run_turn(session, "do the thing", issue, on_message: on_message)})
          end)

        assert_received {:result, {:error, {:usage_limited, %{window: "five_hour", resets_at: %DateTime{} = resets_at} = info}}}
        assert info.source == :rate_limit_event
        assert resets_at == ~U[2025-10-03 22:00:00Z]

        assert_received {:turn_msg, {:usage_window, _message, %{"five_hour" => five_hour}}}
        assert five_hour == %{status: "allowed_warning", resets_at: ~U[2025-10-03 22:00:00Z], utilization: 0.9}
        assert_received {:turn_msg, {:usage_limited, %{source: :rate_limit_event}}}
        refute_received {:turn_msg, {:usage_limited, %{source: :result_text}}}
        assert_received {:turn_msg, {:turn_failed, "usage_limited five_hour resets_at=2025-10-03T22:00:00Z"}}

        assert log =~ "Claude rate_limit_event not allowed"
        assert log =~ ~s(issue_id="issue-limit" issue_identifier="ACME-LIMIT" session_id="sess-limit")
        assert log =~ ~s(rate_limit_info=%{)
        assert log =~ ~s("status" => "rejected")
        assert length(String.split(log, "Claude rate_limit_event not allowed")) == 2
      after
        File.rm_rf(test_root)
      end
    end

    test "falls back to the result text when no rate_limit_event arrives" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-usage-limit-text-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-LIMIT-TEXT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached","session_id":"sess-limit-text","usage":{}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1759532400","session_id":"sess-limit-text","usage":{}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)

        assert {:error, {:usage_limited, %{window: nil, resets_at: ~U[2025-10-03 23:00:00Z], source: :result_text}}} =
                 AppServer.run_turn(session, "do the thing", nil, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "approved handoff fails fast when Symphony MCP server is missing" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-handoff-missing-mcp-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-HANDOFF-MISSING")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-handoff-missing","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-handoff-missing","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        prompt = "Reviewer agent approved the committed diff.\n\nContinue the PR handoff."

        assert {:error, {:turn_failed, reason}} =
                 AppServer.run_turn(session, prompt, %{}, on_message: on_message)

        assert reason =~ "missing_required_mcp_tools"
        assert reason =~ "Missing MCP server: symphony"
        assert_received {:turn_msg, {:turn_failed, ^reason}}
      after
        File.rm_rf(test_root)
      end
    end

    test "approved handoff continues when Symphony MCP server is loaded" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-handoff-tools-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-HANDOFF-TOOLS")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-handoff-tools","cwd":"/tmp","tools":[],"mcp_servers":["symphony"],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-handoff-tools","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)
        prompt = "Reviewer agent approved the committed diff.\n\nContinue the PR handoff."

        assert {:ok, result} = AppServer.run_turn(session, prompt, %{}, [])
        assert result.input_tokens == 10
        assert result.output_tokens == 5
      after
        File.rm_rf(test_root)
      end
    end

    test "logs a Symphony MCP server that failed to start on turn 1 with its stderr" do
      test_root = Path.join(System.tmp_dir!(), "symphony-elixir-claude-code-mcp-stderr-#{System.unique_integer([:positive])}")
      cache_root = Path.join(test_root, "cache")
      workspace = Path.join([test_root, "workspaces", "MOT-2"])
      log_dir = Path.join([cache_root, String.replace(workspace, ~r/[^A-Za-z0-9]/, "-"), "mcp-logs-symphony"])
      File.mkdir_p!(log_dir)
      # An entry that can't be read as a file is skipped.
      File.mkdir_p!(Path.join(log_dir, "2026-10-03T22-56-03-000Z.jsonl"))

      File.write!(Path.join(log_dir, "2026-10-03T22-56-02-307Z.jsonl"), """
      {"debug":"Starting connection with timeout of 30000ms","sessionId":"sess-mcp-failed"}
      not json
      {"error":"Server stderr: other session","sessionId":"sess-other"}
      {"error":"Server stderr: mise ERROR No version is set for shim: elixir","sessionId":"sess-mcp-failed"}
      """)

      init = ~s({"type":"system","subtype":"init","session_id":"sess-mcp-failed","mcp_servers":[{"name":"symphony","status":"failed"}]})

      log =
        with_claude_cache_root(cache_root, fn ->
          capture_log(fn -> assert {:ok, _result} = run_fake_init_turn(test_root, workspace, init) end)
        end)

      assert log =~ "Claude Symphony MCP server failed to start"
      assert log =~ ~s(issue_identifier="MOT-2")
      assert log =~ ~s(session_id="sess-mcp-failed")
      assert log =~ "mise ERROR No version is set for shim: elixir"
      refute log =~ "other session"
    end

    test "logs the Symphony MCP start failure without stderr when Claude left no log for the session" do
      test_root = Path.join(System.tmp_dir!(), "symphony-elixir-claude-code-mcp-no-stderr-#{System.unique_integer([:positive])}")
      workspace = Path.join([test_root, "workspaces", "MOT-3"])

      with_claude_cache_root(Path.join(test_root, "cache"), fn ->
        missing_dir_log =
          capture_log(fn ->
            init = ~s({"type":"system","subtype":"init","session_id":"sess-no-log","mcp_servers":[]})
            assert {:ok, _result} = run_fake_init_turn(test_root, workspace, init)
          end)

        assert missing_dir_log =~ "Claude Symphony MCP server failed to start"
        assert missing_dir_log =~ ~s(stderr="unavailable")

        no_session_log =
          capture_log(fn ->
            assert {:ok, _result} = run_fake_init_turn(test_root, workspace, ~s({"type":"system","subtype":"init"}))
          end)

        assert no_session_log =~ ~s(session_id=nil)
        assert no_session_log =~ ~s(stderr="unavailable")
      end)
    end

    test "default Claude cache root follows the platform cache dir" do
      home = System.user_home!()

      assert AppServer.default_claude_cache_root({:unix, :darwin}, "/xdg") ==
               Path.join([home, "Library", "Caches", "claude-cli-nodejs"])

      assert AppServer.default_claude_cache_root({:unix, :linux}, "/xdg") == "/xdg/claude-cli-nodejs"
      assert AppServer.default_claude_cache_root({:unix, :linux}, nil) == Path.join([home, ".cache", "claude-cli-nodejs"])
    end

    test "approved handoff ignores system events that arrive before init" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-handoff-pre-init-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-HANDOFF-PRE-INIT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"hook_started","session_id":"sess-handoff-pre-init"}'
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-handoff-pre-init","cwd":"/tmp","tools":[],"mcp_servers":[{"name":"symphony","status":"connected"}],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-handoff-pre-init","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)
        prompt = "Reviewer agent approved the committed diff.\n\nContinue the PR handoff."

        assert {:ok, result} = AppServer.run_turn(session, prompt, %{}, [])
        assert result.output_tokens == 5
      after
        File.rm_rf(test_root)
      end
    end

    test "strips provider, tracker, GitHub, and SSH agent secrets from the Claude subprocess env" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-env-strip-#{System.unique_integer([:positive])}"
        )

      secret_vars = %{
        "LINEAR_API_KEY" => "lin_api_REDACTED_#{System.unique_integer([:positive])}",
        "ANTHROPIC_API_KEY" => "sk-ant-REDACTED_#{System.unique_integer([:positive])}",
        "OPENAI_API_KEY" => "sk-REDACTED_#{System.unique_integer([:positive])}",
        "GH_TOKEN" => "gho_REDACTED_#{System.unique_integer([:positive])}",
        "GITHUB_TOKEN" => "ghp_REDACTED_#{System.unique_integer([:positive])}",
        "SSH_AUTH_SOCK" => "/tmp/ssh-REDACTED-#{System.unique_integer([:positive])}/agent.1"
      }

      previous = Enum.map(secret_vars, fn {name, _} -> {name, System.get_env(name)} end)
      on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
      Enum.each(secret_vars, fn {name, value} -> System.put_env(name, value) end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-ENVSTRIP")
        fake_claude = Path.join(test_root, "fake-claude")
        trace_file = Path.join(test_root, "claude-env-strip.trace")
        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "settings.gradle.kts"), "")

        File.write!(fake_claude, """
        #!/bin/sh
        trace_file="#{trace_file}"
        printf 'LINEAR=%s\\n' "${LINEAR_API_KEY-<unset>}" >> "$trace_file"
        printf 'ANTHROPIC=%s\\n' "${ANTHROPIC_API_KEY-<unset>}" >> "$trace_file"
        printf 'OPENAI=%s\\n' "${OPENAI_API_KEY-<unset>}" >> "$trace_file"
        printf 'GH=%s\\n' "${GH_TOKEN-<unset>}" >> "$trace_file"
        printf 'GITHUB=%s\\n' "${GITHUB_TOKEN-<unset>}" >> "$trace_file"
        printf 'SSH_AUTH_SOCK=%s\\n' "${SSH_AUTH_SOCK-<unset>}" >> "$trace_file"
        printf 'RUNTIME=%s\\n' "${SYMPHONY_AGENT_RUNTIME-<unset>}" >> "$trace_file"
        printf 'GRADLE_OPTS=%s\\n' "${GRADLE_OPTS-<unset>}" >> "$trace_file"
        printf 'CLAUDE_CODE_TMPDIR=%s\\n' "${CLAUDE_CODE_TMPDIR-<unset>}" >> "$trace_file"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-env-strip","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-env-strip","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, _result} = AppServer.run_turn(session, "confirm env strip", %{}, [])

        trace = File.read!(trace_file)
        assert trace =~ "LINEAR=<unset>"
        assert trace =~ "ANTHROPIC=<unset>"
        assert trace =~ "OPENAI=<unset>"
        assert trace =~ "GH=<unset>"
        assert trace =~ "GITHUB=<unset>"
        assert trace =~ "SSH_AUTH_SOCK=<unset>"
        assert trace =~ "RUNTIME=1"
        assert trace =~ ~r/^GRADLE_OPTS="-Dorg.gradle.daemon.registry.base=\S*\/workspaces\/[A-Z]+-ENVSTRIP\/.gradle-daemons"$/m
        assert trace =~ "CLAUDE_CODE_TMPDIR=<unset>"

        # A QA pass gives its session a temp folder of its own.
        File.rm!(trace_file)
        {:ok, qa_session} = AppServer.start_session(workspace, extra_env: %{"CLAUDE_CODE_TMPDIR" => "/tmp/symphony-qa-0123456789ab"})
        assert {:ok, _result} = AppServer.run_turn(qa_session, "confirm env strip", %{}, [])
        qa_trace = File.read!(trace_file)
        assert qa_trace =~ "CLAUDE_CODE_TMPDIR=/tmp/symphony-qa-0123456789ab"
        assert qa_trace =~ "LINEAR=<unset>"

        Enum.each(secret_vars, fn {_name, value} ->
          refute trace =~ value, "secret value leaked into Claude subprocess: #{value}"
        end)
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn using a command found on PATH" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-path-command-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-PATH")
        fake_claude = Path.join(test_root, "fake-claude-path")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_claude, successful_fake_claude_script("sess-path", 8, 4))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-path"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert result.input_tokens == 8
        assert result.output_tokens == 4
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn using a relative command path" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-relative-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-RELATIVE")
        bin_dir = Path.join(workspace, "bin")
        fake_claude = Path.join(bin_dir, "fake-claude")
        File.mkdir_p!(bin_dir)

        File.write!(fake_claude, successful_fake_claude_script("sess-relative", 7, 3))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "./bin/fake-claude"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert result.input_tokens == 7
        assert result.output_tokens == 3
      after
        File.rm_rf(test_root)
      end
    end

    test "omits remote-control flag for local Claude runs" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-no-remote-control-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-NO-REMOTE-CONTROL")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-no-remote-control"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} =
                 AppServer.run_turn(session, "normal run", %{identifier: "ACME-NO-REMOTE-CONTROL"}, run_id: "run-123")

        assert result.input_tokens == 6

        args =
          Path.join(workspace, "argv.trace")
          |> File.read!()
          |> String.split("\n", trim: false)
          |> Enum.drop(-1)

        refute "--remote-control" in args

        assert args == [
                 "--setting-sources",
                 "",
                 "--settings",
                 session.settings_path,
                 "--mcp-config",
                 session.mcp_config_path,
                 "--strict-mcp-config",
                 "--plugin-dir",
                 session.plugin_dir,
                 "--verbose",
                 "--output-format",
                 "stream-json",
                 "--print"
               ]

        assert File.read!(Path.join(workspace, "stdin.trace")) == "normal run"
      after
        File.rm_rf(test_root)
      end
    end

    test "appends the run profile's model and effort after the Claude flags" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-profile-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-RUN-PROFILE")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-run-profile"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} =
          AppServer.start_session(workspace, run_profile: %{kind: :ci_fix, model: "claude-haiku-4-5", effort: nil})

        assert {:ok, _result} = AppServer.run_turn(session, "fix ci", %{identifier: "ACME-RUN-PROFILE"}, [])

        args =
          Path.join(workspace, "argv.trace")
          |> File.read!()
          |> String.split("\n", trim: false)
          |> Enum.drop(-1)

        assert Enum.take(args, -5) == ["--output-format", "stream-json", "--print", "--model", "claude-haiku-4-5"]
        refute "--effort" in args
      after
        File.rm_rf(test_root)
      end
    end

    test "launches an OpenRouter profile against OpenRouter with the key only in the subprocess env" do
      key = "sk-or-v1-REDACTED_#{System.unique_integer([:positive])}"

      with_openrouter_key(key, fn ->
        with_provider_env_fake_claude("ACME-OPENROUTER", fn workspace ->
          profile = %{kind: :landing, model: "anthropic/claude-haiku-4.5", effort: nil, provider: "openrouter"}

          log =
            capture_log(fn ->
              {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
              assert {:ok, result} = AppServer.run_turn(session, "land it", %{identifier: "ACME-OPENROUTER"}, [])
              refute inspect(session, limit: :infinity) =~ key
              refute inspect(result, limit: :infinity) =~ key
              AppServer.stop_session(session)
            end)

          refute log =~ key

          assert provider_env_trace(workspace) == [
                   "BASE_URL=https://openrouter.ai/api",
                   "AUTH_TOKEN=#{key}",
                   "API_KEY=",
                   "SUBAGENT_MODEL=anthropic/claude-haiku-4.5",
                   "OPENROUTER_API_KEY=<unset>"
                 ]

          args = workspace |> Path.join("argv.trace") |> File.read!() |> String.split("\n", trim: true)
          assert Enum.take(args, -2) == ["--model", "anthropic/claude-haiku-4.5"]
          refute Enum.any?(args, &(&1 =~ key))
        end)
      end)
    end

    test "launches an Anthropic profile without OpenRouter env, even when the key is set" do
      with_openrouter_key("sk-or-v1-unused", fn ->
        with_provider_env_fake_claude("ACME-ANTHROPIC", fn workspace ->
          profile = %{kind: :ci_fix, model: "claude-haiku-4-5", effort: "low", provider: "anthropic"}

          {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
          assert {:ok, _result} = AppServer.run_turn(session, "fix ci", %{identifier: "ACME-ANTHROPIC"}, [])

          assert provider_env_trace(workspace) == [
                   "BASE_URL=<unset>",
                   "AUTH_TOKEN=<unset>",
                   "API_KEY=<unset>",
                   "SUBAGENT_MODEL=<unset>",
                   "OPENROUTER_API_KEY=<unset>"
                 ]

          args = workspace |> Path.join("argv.trace") |> File.read!() |> String.split("\n", trim: true)
          assert Enum.take(args, -7) == ["--output-format", "stream-json", "--print", "--model", "claude-haiku-4-5", "--effort", "low"]
        end)
      end)
    end

    test "fails an OpenRouter run before launch when OPENROUTER_API_KEY is missing" do
      with_openrouter_key("  ", fn ->
        with_provider_env_fake_claude("ACME-OPENROUTER-NOKEY", fn workspace ->
          profile = %{kind: :ci_fix, model: "anthropic/claude-haiku-4.5", effort: nil, provider: "openrouter"}

          log =
            capture_log(fn ->
              assert AppServer.start_session(workspace, run_profile: profile) ==
                       {:error, {:missing_provider_env, "OPENROUTER_API_KEY", :ci_fix}}
            end)

          assert log =~ "OpenRouter run cannot start: OPENROUTER_API_KEY is not set run_kind=ci_fix"
          refute File.exists?(Path.join(workspace, "argv.trace"))
        end)
      end)
    end

    test "fails the launch when OPENROUTER_API_KEY is removed after the session started" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_provider_env_fake_claude("ACME-OPENROUTER-GONE", fn workspace ->
          profile = %{kind: :landing, model: "anthropic/claude-haiku-4.5", effort: nil, provider: "openrouter"}
          {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
          System.delete_env("OPENROUTER_API_KEY")

          log =
            capture_log(fn ->
              assert AppServer.run_turn(session, "land it", %{}, []) ==
                       {:error, {:missing_provider_env, "OPENROUTER_API_KEY", :landing}}
            end)

          assert log =~ "run_kind=landing"
          refute File.exists?(Path.join(workspace, "argv.trace"))
          AppServer.stop_session(session)
        end)
      end)
    end

    test "fails an OpenRouter run before launch when the model does not support tools" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api(fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-NOTOOLS", fn workspace ->
            profile = %{kind: :landing, model: "acme/chat-only", effort: nil, provider: "openrouter"}

            log =
              capture_log(fn ->
                assert AppServer.start_session(workspace, run_profile: profile) ==
                         {:error, {:openrouter_model_unsupported, "acme/chat-only", :landing, :tools}}
              end)

            assert log =~
                     "OpenRouter run cannot start: model acme/chat-only does not support tools run_kind=landing; " <>
                       "set agent.model to a model that lists tools"

            refute File.exists?(Path.join(workspace, "argv.trace"))
          end)
        end)
      end)
    end

    test "names the key that set the model when a pre_push_review run model lacks tools" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api(fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-REVIEW-NOTOOLS", fn workspace ->
            settings = Config.settings!()
            settings = %{settings | review_agent: %{settings.review_agent | model: "acme/chat-only"}}
            profile = %{kind: :pre_push_review, model: "acme/chat-only", effort: nil, provider: "openrouter"}

            log =
              capture_log(fn ->
                assert AppServer.start_session(workspace, run_profile: profile, settings: settings) ==
                         {:error, {:openrouter_model_unsupported, "acme/chat-only", :pre_push_review, :tools}}
              end)

            assert log =~ "run_kind=pre_push_review; set pre_push_review.model to a model that lists tools"
          end)
        end)
      end)
    end

    test "names the repository key that set the model when a run model lacks tools" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api(fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-REPO-NOTOOLS", fn workspace ->
            settings = Config.settings!()
            repository = %Config.Schema.RepoAgent{key: "beta", provider: "openrouter", model: "acme/chat-only"}
            settings = %{settings | agent: %{settings.agent | repository: repository}}
            profile = %{kind: :ci_fix, model: "acme/chat-only", effort: nil, provider: "openrouter"}

            log =
              capture_log(fn ->
                assert AppServer.start_session(workspace, run_profile: profile, settings: settings) ==
                         {:error, {:openrouter_model_unsupported, "acme/chat-only", :ci_fix, :tools}}
              end)

            assert log =~ "run_kind=ci_fix; set repositories[beta].agent.model to a model that lists tools"
          end)
        end)
      end)
    end

    test "keeps --effort for an OpenRouter model that supports reasoning" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api(fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-REASONING", fn workspace ->
            profile = %{kind: :landing, model: "anthropic/claude-haiku-4.5", effort: "high", provider: "openrouter"}

            log =
              capture_log(fn ->
                {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
                assert {:ok, _result} = AppServer.run_turn(session, "land it", %{identifier: "ACME-OPENROUTER-REASONING"}, [])
                AppServer.stop_session(session)
              end)

            refute log =~ "OpenRouter"
            args = workspace |> Path.join("argv.trace") |> File.read!() |> String.split("\n", trim: true)
            assert Enum.take(args, -4) == ["--model", "anthropic/claude-haiku-4.5", "--effort", "high"]
          end)
        end)
      end)
    end

    test "drops --effort for an OpenRouter model without reasoning and warns once per model" do
      model = "acme/tools-only-#{System.unique_integer([:positive])}"

      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api([%{"id" => model, "supported_parameters" => ["tools"]}], fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-EFFORT", fn workspace ->
            profile = %{kind: :ci_fix, model: model, effort: "high", provider: "openrouter"}

            log =
              capture_log(fn ->
                for _run <- 1..2 do
                  {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
                  assert session.run_profile.effort == nil
                  assert {:ok, _result} = AppServer.run_turn(session, "fix ci", %{identifier: "ACME-OPENROUTER-EFFORT"}, [])
                  AppServer.stop_session(session)
                end
              end)

            warning = "OpenRouter model #{model} does not support reasoning; starting its runs without --effort high"
            assert log |> String.split(warning) |> length() == 2
            args = workspace |> Path.join("argv.trace") |> File.read!() |> String.split("\n", trim: true)
            assert Enum.take(args, -2) == ["--model", model]
            refute "--effort" in args
          end)
        end)
      end)
    end

    test "starts an OpenRouter run with a warning when the models API cannot be reached" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_provider_env_fake_claude("ACME-OPENROUTER-OFFLINE", fn workspace ->
          profile = %{kind: :landing, model: "acme/chat-only", effort: "low", provider: "openrouter"}

          log =
            capture_log(fn ->
              {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
              assert session.run_profile == profile
              AppServer.stop_session(session)
            end)

          assert log =~ "Could not check OpenRouter model acme/chat-only: :network_disabled_in_tests; starting anyway run_kind=landing"
        end)
      end)
    end

    test "starts an OpenRouter run with a warning when OpenRouter does not list the model" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_models_api(fn ->
          with_provider_env_fake_claude("ACME-OPENROUTER-UNKNOWN", fn workspace ->
            profile = %{kind: :landing, model: "acme/typo", effort: "low", provider: "openrouter"}

            log =
              capture_log(fn ->
                {:ok, session} = AppServer.start_session(workspace, run_profile: profile)
                assert session.run_profile == profile
                AppServer.stop_session(session)
              end)

            assert log =~ "OpenRouter does not list model acme/typo; starting anyway run_kind=landing"
          end)
        end)
      end)
    end

    test "rejects an OpenRouter profile on a remote worker" do
      with_openrouter_key("sk-or-v1-REDACTED", fn ->
        with_provider_env_fake_claude("ACME-OPENROUTER-REMOTE", fn workspace ->
          profile = %{kind: :landing, model: "anthropic/claude-haiku-4.5", effort: nil, provider: "openrouter"}

          assert AppServer.start_session(workspace, worker_host: "worker-01", run_profile: profile) ==
                   {:error, {:openrouter_remote_worker_unsupported, "worker-01"}}
        end)
      end)
    end

    test "resumes the given conversation when the turn names a session id" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-resume-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-RESUME")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-resume"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        trace = Path.join(workspace, "argv.trace")
        read_args = fn -> trace |> File.read!() |> String.split("\n", trim: true) end

        assert {:ok, _result} = AppServer.run_turn(session, "verdict please", %{identifier: "ACME-RESUME"}, resume_session_id: "sess-resume")
        assert Enum.take(read_args.(), -2) == ["--resume", "sess-resume"]

        assert {:ok, _result} = AppServer.run_turn(session, "fresh turn", %{identifier: "ACME-RESUME"}, [])
        refute "--resume" in read_args.()
      after
        File.rm_rf(test_root)
      end
    end

    test "uses a private prompt file for local Claude stdin and cleans it up" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-prompt-file-#{System.unique_integer([:positive])}"
        )

      previous_tmpdir = System.get_env("TMPDIR")

      on_exit(fn ->
        restore_env("TMPDIR", previous_tmpdir)
      end)

      try do
        prompt_tmp_root = Path.join(test_root, "prompt-tmp")
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-PROMPT-FILE")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)
        File.mkdir_p!(prompt_tmp_root)
        System.put_env("TMPDIR", prompt_tmp_root)

        File.write!(fake_claude, """
        #!/bin/sh
        prompt_file=$(find "${TMPDIR:-/tmp}" -path '*/symphony-claude-prompt-*/prompt' -type f | head -n 1)
        printf '%s' "$prompt_file" > "$PWD/prompt-path.trace"
        (stat -c '%a' "$prompt_file" 2>/dev/null || stat -f '%Lp' "$prompt_file") > "$PWD/prompt-mode.trace"
        (stat -c '%a' "$(dirname "$prompt_file")" 2>/dev/null || stat -f '%Lp' "$(dirname "$prompt_file")") > "$PWD/prompt-dir-mode.trace"
        cat > "$PWD/stdin.trace"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-prompt-file","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-prompt-file","total_cost_usd":0.001,"usage":{"input_tokens":6,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        prompt = "secret prompt body"

        assert {:ok, result} = AppServer.run_turn(session, prompt, %{}, [])
        assert result.input_tokens == 6
        assert File.read!(Path.join(workspace, "stdin.trace")) == prompt

        prompt_path = File.read!(Path.join(workspace, "prompt-path.trace"))
        assert String.starts_with?(prompt_path, prompt_tmp_root)
        refute String.starts_with?(prompt_path, workspace)
        assert String.trim(File.read!(Path.join(workspace, "prompt-mode.trace"))) == "600"
        assert String.trim(File.read!(Path.join(workspace, "prompt-dir-mode.trace"))) == "700"
        refute File.exists?(prompt_path)
        refute File.exists?(Path.dirname(prompt_path))
      after
        File.rm_rf(test_root)
      end
    end

    test "appends default Claude project guide imports to the prompt" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-project-guides-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-GUIDES")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(Path.join(workspace, "CLAUDE.md"), "Claude rule\n@AGENTS.md\n")
        File.write!(Path.join(workspace, "AGENTS.md"), "Agent rule\n")
        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-guides"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)

        assert {:ok, _result} = AppServer.run_turn(session, "Workflow prompt", %{}, [])

        stdin = File.read!(Path.join(workspace, "stdin.trace"))
        assert stdin =~ "Workflow prompt\n\n## Project conventions"
        assert stdin =~ "### CLAUDE.md"
        assert stdin =~ "Claude rule"
        assert stdin =~ "### @AGENTS.md"
        assert stdin =~ "Agent rule"
      after
        File.rm_rf(test_root)
      end
    end

    test "omits Claude project guide section when default guide is missing or disabled" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-project-guides-missing-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-GUIDES-MISSING")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-guides-missing"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)
        assert {:ok, _result} = AppServer.run_turn(session, "No guide prompt", %{}, [])
        assert File.read!(Path.join(workspace, "stdin.trace")) == "No guide prompt"

        File.write!(Path.join(workspace, "CLAUDE.md"), "Should not appear\n")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_include_project_guides: false
        )

        session = local_session(workspace, test_root)
        assert {:ok, _result} = AppServer.run_turn(session, "Disabled guide prompt", %{}, [])
        assert File.read!(Path.join(workspace, "stdin.trace")) == "Disabled guide prompt"
      after
        File.rm_rf(test_root)
      end
    end

    test "Claude project guide files can be overridden explicitly" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-project-guides-explicit-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-GUIDES-EXPLICIT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(Path.join(workspace, "AGENTS.md"), "Explicit agents rule\n")
        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-guides-explicit"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_project_guide_files: ["AGENTS.md"]
        )

        session = local_session(workspace, test_root)
        assert {:ok, _result} = AppServer.run_turn(session, "Explicit prompt", %{}, [])

        stdin = File.read!(Path.join(workspace, "stdin.trace"))
        assert stdin =~ "## Project conventions"
        assert stdin =~ "### AGENTS.md"
        assert stdin =~ "Explicit agents rule"
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn when workspace and command paths contain spaces" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony elixir claude code spaced #{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "work spaces")
        workspace = Path.join(workspace_root, "ACME 1")
        bin_dir = Path.join(test_root, "bin dir")
        fake_claude = Path.join(bin_dir, "fake claude")
        File.mkdir_p!(workspace)
        File.mkdir_p!(bin_dir)

        File.write!(fake_claude, """
        #!/bin/sh
        cat > "$PWD/stdin.trace"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-spaced","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-spaced","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "'#{fake_claude}'"
        )

        {:ok, session} = AppServer.start_session(workspace)
        prompt = "do the thing from a path with spaces and \"quotes\""

        assert {:ok, result} = AppServer.run_turn(session, prompt, %{}, [])
        assert result.input_tokens == 10
        assert File.read!(Path.join(workspace, "stdin.trace")) == prompt
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command is empty" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-empty-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-EMPTY")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "   "
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :empty_agent_command} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command cannot be parsed" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-invalid-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-INVALID")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "'unterminated"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:invalid_agent_command, _message}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command cannot be found" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-missing-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-MISSING")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "missing-claude-command"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:agent_command_not_found, "missing-claude-command"}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when turn exits with non-zero status" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-exit-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-2")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' 'some error output'
        exit 1
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:exit_status, 1, %{stderr: stderr}}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])

        assert stderr == "some error output"
      after
        File.rm_rf(test_root)
      end
    end

    test "removes settings and MCP socket after a killed agent port stops" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-killed-port-cleanup-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-KILLED")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        kill -9 $$
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        assert File.exists?(session.settings_path)

        if session.mcp_session.transport == :unix do
          assert File.exists?(session.mcp_session.socket_path)
        else
          assert session.mcp_session.transport == :tcp
          assert unix_socket_bind_probe() == {:error, :eperm}
        end

        assert {:error, {:exit_status, status}} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert status > 0

        assert :ok = AppServer.stop_session(session)
        refute File.exists?(session.settings_path)

        if session.mcp_session.transport == :unix do
          refute File.exists?(session.mcp_session.socket_path)
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error and forwards turn_failed event on result/error stream line" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-failed-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-3")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"error","error":"claude api error","session_id":"sess-run-3"}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:error, {:turn_failed, "claude api error"}} =
                 AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)

        assert_received {:turn_msg, {:turn_failed, "claude api error"}}
      after
        File.rm_rf(test_root)
      end
    end

    test "forwards rate_limited event and turn_failed when result/error is a rate limit" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-rate-limited-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-RL")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"error","error":"rate_limit_error: retry after 12 seconds","session_id":"sess-rl"}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:error, {:turn_failed, reason}} =
                 AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)

        assert reason =~ "rate_limit_error"

        assert_received {:turn_msg, {:rate_limited, %{retry_after_seconds: 12, message: ^reason}}}
        assert_received {:turn_msg, {:turn_failed, ^reason}}
      after
        File.rm_rf(test_root)
      end
    end

    test "returns turn timeout when the cli process stops producing events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-timeout-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-TIMEOUT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        sleep 1
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 20
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :turn_timeout} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "closing the port after a timeout tolerates a cli that already exited" do
      # Regression: the turn timeout fired, the cli exited, and the port closed
      # before cleanup called Port.close/1, which raised ArgumentError.
      port = Port.open({:spawn_executable, System.find_executable("sh")}, [:exit_status, args: ["-c", "exit 0"]])
      monitor_ref = :erlang.monitor(:port, port)
      assert_receive {^port, {:exit_status, 0}}, 5_000
      assert_receive {:DOWN, ^monitor_ref, :port, ^port, _reason}, 5_000

      assert AppServer.safe_close_port(port) == :ok
    end

    test "closing the port stops a cli that is still running" do
      port = Port.open({:spawn_executable, System.find_executable("sh")}, [:exit_status, args: ["-c", "exec cat"]])

      assert AppServer.safe_close_port(port) == :ok
      assert Port.info(port) == nil
    end

    test "passes the run profile's model and effort to Claude over ssh" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-run-profile-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-REMOTE-PROFILE")
        trace_file = Path.join(test_root, "ssh-command.trace")
        fake_ssh = Path.join(test_root, "ssh")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        for arg in "$@"; do
          last_arg="$arg"
        done
        printf '%s' "$last_arg" > "#{trace_file}"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-remote-profile","cwd":"/remote","tools":[],"mcp_servers":[],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":200,"duration_api_ms":150,"is_error":false,"num_turns":1,"result":"remote done","session_id":"sess-remote-profile","total_cost_usd":0.0,"usage":{"input_tokens":5,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-remote"
        )

        {:ok, session} =
          AppServer.start_session(workspace,
            worker_host: "worker-01",
            run_profile: %{kind: :breakdown, model: "claude-opus-5-5", effort: "high"}
          )

        assert {:ok, _result} = AppServer.run_turn(session, "remote breakdown", %{}, [])

        assert File.read!(trace_file) =~
                 ~s(--print'"'"' '"'"'--model'"'"' '"'"'claude-opus-5-5'"'"' '"'"'--effort'"'"' '"'"'high'"'"' < "$prompt_file")
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a turn over ssh for remote workers" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-run-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-REMOTE")
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "ssh-command.trace")
        stdin_trace_file = Path.join(test_root, "ssh-stdin.trace")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        printf '%s' "$*" > "#{Path.join(test_root, "ssh-argv.trace")}"
        last_arg=""
        for arg in "$@"; do
          last_arg="$arg"
        done
        printf '%s' "$last_arg" > "#{trace_file}"
        case "$last_arg" in
          *fake-claude-remote*)
            cat > "#{stdin_trace_file}"
            ;;
        esac
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-remote","cwd":"/remote","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":200,"duration_api_ms":150,"is_error":false,"num_turns":1,"result":"remote done","session_id":"sess-remote","total_cost_usd":0.0,"usage":{"input_tokens":5,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-remote"
        )

        {:ok, session} = AppServer.start_session(workspace, worker_host: "worker-01")
        refute File.exists?(Path.join(workspace, ".claude/settings.json"))

        assert {:ok, result} = AppServer.run_turn(session, "remote task", %{}, [])
        assert result.input_tokens == 5
        assert result.output_tokens == 3
        traced_command = File.read!(trace_file)
        traced_argv = File.read!(Path.join(test_root, "ssh-argv.trace"))
        assert traced_command =~ "cd"
        assert traced_command =~ workspace
        assert traced_command =~ "fake-claude-remote"
        assert traced_command =~ "--setting-sources"
        assert traced_command =~ "'\"'\"'--setting-sources'\"'\"' '\"'\"''\"'\"'"
        refute traced_command =~ "--setting-sources 'user'"
        assert traced_command =~ "--settings"
        assert traced_command =~ session.settings_path
        assert traced_command =~ "--mcp-config"
        assert traced_command =~ session.mcp_config_path
        assert traced_command =~ "--strict-mcp-config"
        assert traced_command =~ "--plugin-dir"
        assert traced_command =~ session.plugin_dir
        assert traced_command =~ "--verbose"
        assert traced_command =~ "--output-format"
        assert traced_command =~ "stream-json"
        assert traced_command =~ "--print"
        assert traced_command =~ "umask 077"
        assert traced_command =~ "mktemp -d"
        assert traced_command =~ "cat >"
        assert traced_command =~ "chmod 0600"
        assert traced_command =~ "cleanup_prompt"
        refute traced_command =~ "remote task"
        refute traced_argv =~ "remote task"
        assert File.read!(stdin_trace_file) == "remote task"
        refute traced_command =~ "--remote-control"

        if session.mcp_session.transport == :unix do
          assert traced_argv =~ "-R #{session.mcp_remote_socket_path}:#{session.mcp_session.socket_path}"
        else
          assert session.mcp_session.transport == :tcp
          assert unix_socket_bind_probe() == {:error, :eperm}
          refute traced_argv =~ "-R "
        end
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when process exits 0 without emitting a result event" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-no-result-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-NORESULT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' 'some unexpected non-json output'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :no_result_event} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns command_timeout when a tool call runs too long" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-command-timeout-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-CMDTIMEOUT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"tool_use","name":"bash","id":"t-1","input":{"command":"sleep 10"}}'
        sleep 1
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 5_000,
          agent_command_timeout_ms: 30
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :command_timeout} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "clears command timeout after a tool result arrives" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-command-timeout-cleared-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-CMDDONE")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"tool_use","name":"bash","id":"t-1","input":{"command":"make all"}}'
        printf '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-1","content":"make all passed"}]},"session_id":"sess-cmd-done"}'
        sleep 0.08
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":100,"duration_api_ms":80,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-cmd-done","total_cost_usd":0.0,"usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 5_000,
          agent_command_timeout_ms: 30
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert result.input_tokens == 7
        assert result.output_tokens == 3
      after
        File.rm_rf(test_root)
      end
    end

    test "keeps command timeout active until all tool results arrive" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-command-timeout-pending-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-CMDPENDING")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t-1","name":"bash","input":{"command":"make all"}},{"type":"tool_use","id":"t-2","name":"read","input":{"file_path":"README.md"}}]}}'
        printf '%s\\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-1","content":"make all passed"}]},"session_id":"sess-cmd-pending"}'
        sleep 1
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 5_000,
          agent_command_timeout_ms: 30
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :command_timeout} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "correctly reassembles lines split by port line limit into parseable events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-noeol-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-4")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        # Build a tool_use event whose JSON is padded to exceed @port_line_bytes (1 MB)
        # by stuffing extra whitespace into an otherwise valid JSON field.
        padding = String.duplicate("a", 1_100_000)

        oversized_tool_use =
          Jason.encode!(%{
            "type" => "tool_use",
            "name" => "bash",
            "id" => "t-large",
            "input" => %{"padding" => padding}
          })

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '#{oversized_tool_use}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":100,"duration_api_ms":80,"is_error":false,"num_turns":1,"result":"ok","session_id":"sess-run-4","total_cost_usd":0.0,"usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)
        assert result.input_tokens == 7
        assert result.output_tokens == 3

        # The oversized tool_use line must have been reassembled and parsed correctly
        assert_received {:turn_msg, {:tool_use, "bash"}}
      after
        File.rm_rf(test_root)
      end
    end

    test "returns success when terminal result is emitted while a tool subprocess keeps the cli alive" do
      Application.put_env(:symphony_elixir, :claude_post_completion_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_post_completion_grace_ms) end)

      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-lingering-#{System.unique_integer([:positive])}"
        )

      sleep_pid_file = Path.join(test_root, "sleep.pid")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-LINGER")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-linger","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-linger","total_cost_usd":0.001,"usage":{"input_tokens":11,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        sleep 30 &
        sleep_pid=$!
        printf '%s' "$sleep_pid" > "#{sleep_pid_file}"
        wait "$sleep_pid"
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 10_000
        )

        session = local_session(workspace, test_root)

        start = System.monotonic_time(:millisecond)

        log =
          capture_log(fn ->
            assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
            assert result.input_tokens == 11
            assert result.output_tokens == 4
          end)

        elapsed = System.monotonic_time(:millisecond) - start
        # Without the fix we would block on the lingering `sleep` until the
        # turn_timeout (10s). With the grace period (50ms) we should finalize
        # in well under that.
        assert elapsed < 5_000, "expected fast finalize after grace, elapsed=#{elapsed}ms"
        assert log =~ "turn_completed_without_process_exit"
      after
        # Best-effort cleanup of the descendant in case the runtime sandbox
        # blocks the OS process enumeration used by our cleanup path.
        if File.exists?(sleep_pid_file) do
          sleep_pid = sleep_pid_file |> File.read!() |> String.trim()
          _ = System.cmd("kill", ["-KILL", sleep_pid], stderr_to_stdout: true)
        end

        File.rm_rf(test_root)
      end
    end

    test "returns success when claude exits with a non-zero status after emitting a terminal result" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-success-then-nonzero-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-LATEEXIT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-late-exit","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-late-exit","total_cost_usd":0.001,"usage":{"input_tokens":3,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 7
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)

        log =
          capture_log(fn ->
            assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
            assert result.input_tokens == 3
            assert result.output_tokens == 2
          end)

        assert log =~ "terminal result before non-zero exit"
      after
        File.rm_rf(test_root)
      end
    end

    test "returns exit_status when claude exits non-zero before emitting a terminal result" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-nonzero-before-result-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-EARLYEXIT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' 'some error output'
        exit 7
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)

        assert {:error, {:exit_status, 7, %{stderr: stderr}}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])

        assert stderr == "some error output"
      after
        File.rm_rf(test_root)
      end
    end

    test "bounds multi-byte diagnostic output by bytes when claude exits non-zero" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-multibyte-diagnostic-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-MULTIBYTE-DIAGNOSTIC")
        fake_claude = Path.join(test_root, "fake-claude")
        diagnostic_line = String.duplicate(<<0xE7, 0x95, 0x8C>>, 2_000)
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '#{diagnostic_line}'
        exit 7
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        session = local_session(workspace, test_root)

        assert {:error, {:exit_status, 7, %{stderr: stderr}}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])

        assert String.valid?(stderr)
        assert byte_size(stderr) <= 4_096
        assert byte_size(stderr) > 0
      after
        File.rm_rf(test_root)
      end
    end

    test "returns turn_failed when terminal error result is emitted while a tool subprocess keeps the cli alive" do
      Application.put_env(:symphony_elixir, :claude_post_completion_grace_ms, 50)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_post_completion_grace_ms) end)

      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-failed-lingering-#{System.unique_integer([:positive])}"
        )

      sleep_pid_file = Path.join(test_root, "sleep.pid")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "ACME-FAILED-LINGER")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-failed-linger","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"error","error":"claude api error","session_id":"sess-failed-linger"}'
        sleep 30 &
        sleep_pid=$!
        printf '%s' "$sleep_pid" > "#{sleep_pid_file}"
        wait "$sleep_pid"
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 10_000
        )

        session = local_session(workspace, test_root)

        start = System.monotonic_time(:millisecond)

        log =
          capture_log(fn ->
            assert {:error, {:turn_failed, "claude api error"}} =
                     AppServer.run_turn(session, "do the thing", %{}, [])
          end)

        elapsed = System.monotonic_time(:millisecond) - start
        assert elapsed < 5_000, "expected fast finalize after grace, elapsed=#{elapsed}ms"
        assert log =~ "turn_completed_without_process_exit"
      after
        if File.exists?(sleep_pid_file) do
          sleep_pid = sleep_pid_file |> File.read!() |> String.trim()
          _ = System.cmd("kill", ["-KILL", sleep_pid], stderr_to_stdout: true)
        end

        File.rm_rf(test_root)
      end
    end
  end

  defp successful_fake_claude_script(session_id, input_tokens, output_tokens) do
    """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"#{session_id}","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"#{session_id}","total_cost_usd":0.001,"usage":{"input_tokens":#{input_tokens},"output_tokens":#{output_tokens},"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
    exit 0
    """
  end

  defp with_claude_cache_root(cache_root, fun) do
    Application.put_env(:symphony_elixir, :claude_cache_root, cache_root)

    try do
      fun.()
    after
      Application.delete_env(:symphony_elixir, :claude_cache_root)
      File.rm_rf(Path.dirname(cache_root))
    end
  end

  defp run_fake_init_turn(test_root, workspace, init_json) do
    fake_claude = Path.join(test_root, "fake-claude")
    File.mkdir_p!(workspace)

    File.write!(fake_claude, """
    #!/bin/sh
    printf '%s\\n' '#{init_json}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Done.","session_id":"sess","usage":{"input_tokens":1,"output_tokens":1}}'
    exit 0
    """)

    File.chmod!(fake_claude, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(workspace),
      agent_kind: "claude",
      agent_command: fake_claude
    )

    issue = %{id: "issue-#{Path.basename(workspace)}", identifier: Path.basename(workspace)}
    AppServer.run_turn(local_session(workspace, test_root), "do the thing", issue, [])
  end

  defp local_session(workspace, test_root) do
    %{
      workspace: workspace,
      metadata: %{},
      worker_host: nil,
      settings_path: Path.join(test_root, "settings.json"),
      mcp_config_path: Path.join(test_root, "mcp.json"),
      mcp_session: nil,
      mcp_remote_socket_path: nil,
      mcp_remote_shim_path: nil
    }
  end

  defp with_openrouter_key(value, fun) do
    previous = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", value)

    try do
      fun.()
    after
      restore_env("OPENROUTER_API_KEY", previous)
    end
  end

  @openrouter_models [
    %{"id" => "anthropic/claude-haiku-4.5", "supported_parameters" => ["tools", "reasoning"], "context_length" => 200_000},
    %{"id" => "acme/chat-only", "supported_parameters" => ["max_tokens"], "context_length" => 8_192}
  ]

  defp with_models_api(models \\ @openrouter_models, fun) do
    previous = Application.get_env(:symphony_elixir, :openrouter_models_request)
    request_fun = fn _url, _opts -> {:ok, %{status: 200, body: %{"data" => models}}} end
    Application.put_env(:symphony_elixir, :openrouter_models_request, request_fun)
    Models.clear_cache()

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, :openrouter_models_request, previous)
      Models.clear_cache()
    end
  end

  defp with_provider_env_fake_claude(identifier, fun) do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-claude-code-provider-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, identifier)
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      {
        printf 'BASE_URL=%s\\n' "${ANTHROPIC_BASE_URL-<unset>}"
        printf 'AUTH_TOKEN=%s\\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
        printf 'API_KEY=%s\\n' "${ANTHROPIC_API_KEY-<unset>}"
        printf 'SUBAGENT_MODEL=%s\\n' "${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}"
        printf 'OPENROUTER_API_KEY=%s\\n' "${OPENROUTER_API_KEY-<unset>}"
      } > "$PWD/provider-env.trace"
      #{argv_tracing_fake_claude_script("sess-provider") |> String.replace("#!/bin/sh\n", "")}
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        agent_command: fake_claude
      )

      fun.(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  defp provider_env_trace(workspace) do
    workspace |> Path.join("provider-env.trace") |> File.read!() |> String.split("\n", trim: true)
  end

  defp argv_tracing_fake_claude_script(session_id) do
    """
    #!/bin/sh
    : > "$PWD/argv.trace"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$PWD/argv.trace"
    done
    cat > "$PWD/stdin.trace"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"#{session_id}","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"#{session_id}","total_cost_usd":0.001,"usage":{"input_tokens":6,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
    exit 0
    """
  end

  defp trace_only_ssh_script(trace_file) do
    """
    #!/bin/sh
    last_arg=""
    for arg in "$@"; do
      last_arg="$arg"
    done
    printf '%s' "$last_arg" > "#{trace_file}"
    exit 0
    """
  end

  defp failing_ssh_script(status) do
    """
    #!/bin/sh
    printf '%s\\n' 'ssh failed'
    exit #{status}
    """
  end

  defp assert_claude_mcp_config_matches_transport(mcp_config, %{transport: :unix} = mcp_session) do
    assert Enum.take(get_in(mcp_config, ["mcpServers", "symphony", "args"]), -2) == [
             "--socket",
             mcp_session.socket_path
           ]
  end

  defp assert_claude_mcp_config_matches_transport(mcp_config, %{transport: :tcp} = mcp_session) do
    assert unix_socket_bind_probe() == {:error, :eperm}

    assert Enum.take(get_in(mcp_config, ["mcpServers", "symphony", "args"]), -4) == [
             "--tcp-host",
             "127.0.0.1",
             "--tcp-port",
             Integer.to_string(mcp_session.tcp_port)
           ]
  end
end
