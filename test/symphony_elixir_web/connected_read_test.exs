defmodule SymphonyElixirWeb.ConnectedReadTest do
  # The ticket read's `connected`, through the control API: a ticket in a chain, with one resolved
  # and one open blocker, and a ticket it holds up.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Initiatives
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.PrDecision.Facts

  @endpoint SymphonyElixirWeb.Endpoint
  @repo "default"
  @landed ~U[2026-11-05 15:22:00Z]

  # Idle until a test gives it what it tracks.
  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, %{running: [], retrying: [], rate_limits: nil}}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
    def handle_call({:track, tracked}, _from, snapshot), do: {:reply, :ok, Map.merge(snapshot, tracked)}
  end

  setup do
    :ok = RunStore.clear()

    on_exit(fn ->
      RunStore.clear()
      :persistent_term.erase({Initiatives, :initiatives, Initiatives})
      :persistent_term.erase({Initiatives, :read, Initiatives})
    end)

    write_workflow_file!(Workflow.workflow_file_path())
    orchestrator = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    start_supervised!(%{id: SnapshotOrchestrator, start: {SnapshotOrchestrator, :start_link, [orchestrator]}})

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), orchestrator: orchestrator, snapshot_timeout_ms: 1_000)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    %{orchestrator: orchestrator}
  end

  # Eight sub-tickets in a chain, the first four done and the fifth, MT-6, this ticket.
  defp read_the_plan do
    children =
      for number <- 2..9 do
        {name, type} = if number <= 5, do: {"Done", "completed"}, else: {"Todo", "unstarted"}

        %{
          "id" => "id-MT-#{number}",
          "identifier" => "MT-#{number}",
          "title" => "Part #{number}",
          "createdAt" => "2026-11-01T10:00:0#{number}Z",
          "state" => %{"name" => name, "type" => type},
          "inverseRelations" => %{"nodes" => []}
        }
      end

    plan = %{
      "id" => "id-MT-1",
      "identifier" => "MT-1",
      "title" => "The plan",
      "state" => %{"name" => "Waiting on sub-tickets", "type" => "started"},
      "children" => %{"nodes" => children}
    }

    issues = %{"nodes" => [plan], "pageInfo" => %{"hasNextPage" => false}}

    Initiatives.run_once(%{
      opts: [
        name: Initiatives,
        repos: fn -> {:ok, [%{name: @repo}]} end,
        settings_fun: fn _repo -> %Schema{} end,
        scope_filter: fn _repo -> {:ok, %{}} end,
        linear_client: fn _query, _variables, _opts -> {:ok, %{"data" => %{"issues" => issues}}} end,
        now: fn -> ~U[2026-11-06 12:00:00Z] end
      ]
    })
  end

  defp ticket(id, identifier, phase, fields \\ %{}) do
    :ok = RunStore.put_ticket_state(Map.merge(%{repo_key: @repo, issue_id: id, issue_identifier: identifier, phase: phase}, fields))
  end

  defp wait_on(id, blocker, at), do: {:ok, _pause} = Pauses.set({:ticket, @repo, id}, Pauses.ticket_reason(:dependency, blocker), at: at)

  defp ticket_in_a_chain do
    ticket("id-MT-5", "MT-5", "Done", %{title: "Part 5"})
    ticket("id-MT-20", "MT-20", "In Progress", %{title: "Elsewhere"})
    ticket("id-MT-6", "MT-6", "Todo", %{title: "Part 6", blockers: [%{id: "id-MT-20", identifier: "MT-20", state: "In Progress"}]})
    ticket("id-MT-7", "MT-7", "Todo", %{title: "Part 7", blockers: [%{id: "id-MT-6", identifier: "MT-6", state: "Todo"}]})

    wait_on("id-MT-6", "MT-5", ~U[2026-11-01 11:00:00Z])
    wait_on("id-MT-6", "MT-20", ~U[2026-11-02 09:00:00Z])
    landed = %{kind: :ticket, waits_on: %{identifier: "MT-5"}}
    {:ok, _pause} = Pauses.clear_reason({:ticket, @repo, "id-MT-6"}, landed, at: @landed)
    wait_on("id-MT-7", "MT-6", ~U[2026-11-01 11:00:00Z])
  end

  defp read(identifier), do: build_conn() |> get("/api/v1/#{identifier}") |> json_response(200)

  defp watched(id, identifier) do
    ticket(id, identifier, "Code Review")
    facts = %Facts{phase: :code_review, ci: :pending, pr: :open, pr_number: 741}
    :ok = RunStore.put_ticket_pr_watch(@repo, id, identifier, %{facts: facts, head_sha: "abc1234"})
  end

  defp tracked_links(held_up, related) do
    %{
      parent: nil,
      sub_tickets: [],
      blocked_by: [],
      blocks: [%{identifier: held_up, title: "Held up", state: "Todo"}],
      related: [%{identifier: related, title: "Related", state: "Todo"}]
    }
  end

  defp running_entry(id, identifier, connected) do
    %{
      issue_id: id,
      repo_key: @repo,
      identifier: identifier,
      state: "Code Review",
      session_id: "thread-#{identifier}",
      last_codex_message: nil,
      last_codex_event: :notification,
      last_codex_timestamp: nil,
      started_at: DateTime.utc_now(),
      connected: connected
    }
  end

  defp watching_entry(id, identifier, connected) do
    %{
      issue_id: id,
      repo_key: @repo,
      identifier: identifier,
      state: "Code Review",
      url: "https://linear.app/example/issue/#{identifier}",
      pull_request_url: "https://github.com/example/repo/pull/741",
      last_ran_at: DateTime.utc_now(),
      seconds_since_last_run: 0,
      connected: connected
    }
  end

  defp identifiers(tickets), do: Enum.map(tickets, & &1["identifier"])

  test "a ticket in a chain reads 4 of 8 done with itself current, and the blocker that landed with when" do
    read_the_plan()
    ticket_in_a_chain()

    assert %{"connected" => connected} = read("MT-6")

    assert %{"identifier" => "MT-1", "title" => "The plan", "done" => 4, "total" => 8, "incomplete" => false, "tickets" => tickets} = connected["epic"]
    assert Enum.map(tickets, & &1["identifier"]) == Enum.map(2..9, &"MT-#{&1}")
    assert [%{"identifier" => "MT-6", "title" => "Part 6"}] = Enum.filter(tickets, & &1["current"])
    assert %{"situation" => "done"} = Enum.find(tickets, &(&1["identifier"] == "MT-5"))
    assert %{"situation" => "blocked_by_ticket"} = Enum.find(tickets, &(&1["identifier"] == "MT-6"))
    assert %{"situation" => nil} = Enum.find(tickets, &(&1["identifier"] == "MT-9"))

    assert connected["blocked_by"] == [
             %{"identifier" => "MT-5", "title" => "Part 5", "state" => "Done", "status" => "resolved", "resolved_at" => "2026-11-05T15:22:00Z"},
             %{"identifier" => "MT-20", "title" => "Elsewhere", "state" => "In Progress", "status" => "open", "resolved_at" => nil}
           ]

    assert connected["blocks"] == [%{"identifier" => "MT-7", "title" => "Part 7", "state" => "Todo", "situation" => "blocked_by_ticket"}]
  end

  test "the epic's progress equals the Initiatives page's count for the same epic" do
    read_the_plan()
    ticket_in_a_chain()

    assert %{"initiatives" => [%{"identifier" => "MT-1", "counts" => counts}]} = build_conn() |> get("/api/v1/initiatives") |> json_response(200)
    assert %{"connected" => %{"epic" => epic}} = read("MT-6")

    assert {epic["done"], epic["total"]} == {counts["done"], counts["total"]}
  end

  test "each of the state's issues carries the same connected" do
    read_the_plan()
    ticket_in_a_chain()

    facts = %Facts{phase: :rework, ci: :pending, pr: :open, pr_number: 741}
    :ok = RunStore.put_ticket_pr_watch(@repo, "id-MT-6", "MT-6", %{facts: facts, head_sha: "abc1234"})

    assert %{"issues" => [issue]} = build_conn() |> get("/api/v1/state") |> json_response(200)

    assert issue["connected"] == read("MT-6")["connected"]
  end

  test "the state's issues carry what the orchestrator holds, as the ticket read does", %{orchestrator: orchestrator} do
    watched("id-MT-30", "MT-30")
    watched("id-MT-31", "MT-31")
    watched("id-MT-32", "MT-32")

    :ok =
      GenServer.call(
        orchestrator,
        {:track,
         %{
           running: [
             running_entry("id-MT-30", "MT-30", tracked_links("MT-40", "MT-41")),
             running_entry("id-MT-31", "MT-31", nil)
           ],
           watching: [
             watching_entry("id-MT-30", "MT-30", tracked_links("MT-50", "MT-51")),
             watching_entry("id-MT-31", "MT-31", tracked_links("MT-60", "MT-61"))
           ]
         }}
      )

    assert %{"issues" => issues} = build_conn() |> get("/api/v1/state") |> json_response(200)
    assert ["MT-30", "MT-31", "MT-32"] = Enum.map(issues, & &1["identifier"])
    [running_wins, nil_ignored, nothing_held] = Enum.map(issues, & &1["connected"])

    assert identifiers(running_wins["blocks"]) == ["MT-40"]
    assert identifiers(running_wins["related"]) == ["MT-41"]
    assert identifiers(nil_ignored["blocks"]) == ["MT-60"]
    assert identifiers(nil_ignored["related"]) == ["MT-61"]
    assert %{"blocks" => [], "related" => []} = nothing_held

    assert running_wins == read("MT-30")["connected"]
    assert nil_ignored == read("MT-31")["connected"]
    assert nothing_held == read("MT-32")["connected"]
  end
end
