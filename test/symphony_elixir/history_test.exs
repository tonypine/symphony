defmodule SymphonyElixir.HistoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.History

  @today ~D[2026-10-13]
  @agent %{max_tokens_per_day: 1_000_000, max_tokens_per_issue: 300_000}

  defp run(issue_id, identifier, started_at, attrs) do
    Map.merge(
      %{issue_id: issue_id, issue_identifier: identifier, title: "#{identifier} title", repo_key: "app", started_at: started_at},
      attrs
    )
  end

  defp payload(params, runs) do
    runs_started_on = fn date -> Enum.filter(runs, &(DateTime.to_date(&1.started_at) == date)) end
    History.payload(params, today: @today, agent: @agent, runs_started_on: runs_started_on, ticket_states: [])
  end

  test "totals tokens per day per provider, per ticket with attempts and cap, and merges per day" do
    runs = [
      run("i1", "TP-1", ~U[2026-10-13 09:00:00Z], %{
        model: "claude-opus-5-5",
        tokens: %{total_tokens: 100},
        reviewer_tokens: %{total_tokens: 20},
        issue_completed_notified_at: ~U[2026-10-13 10:00:00Z]
      }),
      run("i1", "TP-1", ~U[2026-10-12 09:00:00Z], %{provider: "anthropic", tokens: %{total_tokens: 50}}),
      run("i2", "TP-2", ~U[2026-10-13 08:00:00Z], %{model: "gpt-5", tokens: %{total_tokens: 400}}),
      run("i3", "TP-3", ~U[2026-10-12 08:00:00Z], %{model: "moonshot/kimi", tokens: nil}),
      run(nil, nil, ~U[2026-10-12 07:00:00Z], %{tokens: %{total_tokens: 5}}),
      run("old", "TP-0", ~U[2026-10-01 08:00:00Z], %{model: "claude", tokens: %{total_tokens: 9}})
    ]

    assert {:ok, payload} = payload(%{"days" => "2"}, runs)

    assert %{days: 2, from: "2026-10-12", to: "2026-10-13", daily_budget: 1_000_000, per_ticket_cap: 300_000} = payload

    assert payload.tokens_per_day == [
             %{date: "2026-10-12", total_tokens: 55, providers: %{"anthropic" => 50, "openrouter" => 0, "unknown" => 5}},
             %{date: "2026-10-13", total_tokens: 520, providers: %{"anthropic" => 120, "openai" => 400}}
           ]

    assert [
             %{identifier: "TP-2", total_tokens: 400, attempts: 1, cap: 300_000},
             %{identifier: "TP-1", issue_id: "i1", title: "TP-1 title", repo_key: "app", total_tokens: 170, attempts: 2},
             %{identifier: "TP-3", total_tokens: 0, attempts: 1}
           ] = payload.tickets

    assert payload.merged_per_day == [%{date: "2026-10-12", merged: 0}, %{date: "2026-10-13", merged: 1}]
    assert %{agreement: %{agreed: 0, rate: nil}, disagreements: []} = payload.review
  end

  test "defaults to 14 days and rejects a days value outside 1..90" do
    assert {:ok, %{days: 14, from: "2026-09-30"}} = payload(%{}, [])
    assert {:ok, %{days: 90}} = payload(%{"days" => 90}, [])

    for days <- ["0", "91", "abc", "7d", 3.5] do
      assert payload(%{"days" => days}, []) == {:error, :invalid_days}
    end
  end

  test "skips a day whose runs fail to load" do
    failing = fn _date -> {:error, :down} end

    assert {:ok, %{tokens_per_day: [%{total_tokens: 0}]}} =
             History.payload(%{"days" => "1"}, today: @today, agent: @agent, runs_started_on: failing, ticket_states: [])
  end

  test "provider comes from the recorded provider, else the model" do
    assert History.provider(%{provider: "openrouter", model: "claude-opus"}) == "openrouter"
    assert History.provider(%{provider: "", model: "Claude-Sonnet"}) == "anthropic"
    assert History.provider(%{model: "o3-mini"}) == "openai"
    assert History.provider(%{model: "llama"}) == "unknown"
    assert History.provider(%{}) == "unknown"
  end
end
