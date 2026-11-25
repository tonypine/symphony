defmodule SymphonyElixir.Harnesses.EventStreamUsageLimitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.Harnesses.EventStream

  @fallback_refusal ~s|{"type":"result","subtype":"success","is_error":true,"result":"API Error: Request rejected (429) · OpenCode Go usage limit reached (weekly, resets in 15h 11m).","session_id":"sess-1"}|
  @claude_rejection ~s({"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1759528800,"rateLimitType":"five_hour","utilization":1.0},"session_id":"sess-1"})

  defp read(lines, provider) do
    script = Enum.map_join(lines, "; ", &"printf '%s\\n' '#{&1}'") <> "; exit 1"
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, {:line, 4096}, args: ["-c", script]])
    EventStream.read(port, fn _event -> :ok end, 10_000, 0, parse: &AppServer.parse_event/1, provider: provider, label: "Claude")
  end

  test "a usage limit in the result text of a run on a fallback provider is that provider's, with its own reset" do
    before = DateTime.utc_now()

    assert {:error, {:usage_limited, %{provider: "opencode-go", window: "seven_day", source: :result_text, resets_at: %DateTime{} = resets_at}}} =
             read([@fallback_refusal], "opencode-go")

    assert DateTime.diff(resets_at, before) in (15 * 3600 + 11 * 60)..(15 * 3600 + 11 * 60 + 10)
  end

  test "the Claude subscription's own rejection stays Anthropic's whatever provider the run is on" do
    assert {:error, {:usage_limited, %{provider: "anthropic", window: "five_hour", source: :rate_limit_event}}} =
             read([@claude_rejection, @fallback_refusal], "openrouter")
  end
end
