defmodule SymphonyElixir.HumanActionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions
  alias SymphonyElixir.HumanActions.{Action, CiSecrets, Update}
  alias SymphonyElixir.Linear.Usage

  @project %{id: "project-1", name: "Cycle"}
  @minute 60_000

  # GitHub as the test process's dictionary says it is.
  defmodule FakeGitHub do
    def list_branch_runs("acme/cycle", "main", _opts), do: {:ok, Process.get(:runs)}
    def fetch_failed_log(run_id, repo: "acme/cycle"), do: {:ok, Process.get({:log, run_id})}
  end

  defp action(key, attrs \\ %{}) do
    struct!(
      Action,
      Map.merge(
        %{
          key: key,
          kind: :request,
          title: "Do #{key}",
          steps: ["Step for #{key}"],
          issue: %{id: "id-MOT-24", identifier: "MOT-24", title: "Release", url: "https://linear.app/acme/issue/MOT-24", state: "Backlog"},
          project: @project
        },
        attrs
      )
    )
  end

  # A Linear stand-in: answers the last-update query with `previous` (a list of update nodes) and
  # records every post. `post` decides the post's answer.
  defp linear(test_pid, previous, post \\ {:ok, %{"data" => %{"projectUpdateCreate" => %{"success" => true}}}}) do
    fn query, variables, _opts ->
      send(test_pid, {:caller, Usage.current_caller()})

      cond do
        query =~ "SymphonyHumanActionsLastUpdate" ->
          send(test_pid, {:recovered, variables.id})
          previous

        query =~ "SymphonyHumanActionsPostUpdate" ->
          send(test_pid, {:posted, variables.input})
          post

        query =~ "SymphonyHumanActionsRepoProjects" ->
          {:ok, %{"data" => %{"projects" => %{"nodes" => [@project |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)]}}}}
      end
    end
  end

  defp no_updates, do: {:ok, %{"data" => %{"project" => %{"projectUpdates" => %{"nodes" => []}}}}}

  defp state(opts) do
    test_pid = self()
    clock = Keyword.get(opts, :clock) || start_clock(0)

    defaults = [
      settings_fun: fn -> %Schema{} end,
      repos: fn -> {:ok, [:repo]} end,
      collect: fn _repos, _opts -> {:ok, collected(Agent.get(Keyword.fetch!(opts, :actions), & &1))} end,
      linear_client: linear(test_pid, Keyword.get(opts, :previous, no_updates())),
      now_ms: fn -> Agent.get(clock, & &1) end,
      notify: fn event, attrs -> send(test_pid, {:notified, event, attrs}) end
    ]

    %{opts: Keyword.merge(defaults, Keyword.drop(opts, [:actions, :clock, :previous])), projects: %{}, ci: %{}, timer: make_ref()}
  end

  defp start_clock(now_ms) do
    {:ok, clock} = Agent.start_link(fn -> now_ms end)
    clock
  end

  defp start_actions(actions) do
    {:ok, agent} = Agent.start_link(fn -> actions end)
    agent
  end

  defp collected([]), do: %{}
  defp collected(actions), do: %{@project.id => %{project: @project, actions: actions}}

  test "posts one update listing a new action, and nothing more while the list stays the same" do
    actions = start_actions([action("request:comment-1", %{why: "Release fails.", est_minutes: 10})])
    state = state(actions: actions) |> HumanActions.run_once()

    assert_received {:recovered, "project-1"}
    assert_received {:posted, %{"projectId" => "project-1", "health" => "atRisk", "body" => body}}
    assert body =~ "### 1. Do request:comment-1"
    assert body =~ "1. Step for request:comment-1"
    assert body =~ "Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24)"
    assert_received {:notified, :human_action_needed, %{issue_identifier: "MOT-24", reason: "Do request:comment-1", metadata: %{"kind" => "request"}}}

    state = HumanActions.run_once(state)
    refute_received {:posted, _input}
    refute_received {:recovered, _project_id}
    assert state.projects["project-1"].list_id == Update.list_id(Agent.get(actions, & &1))
  end

  test "posts a changed list once the per-project interval has passed, notifying only the new action" do
    clock = start_clock(0)
    actions = start_actions([action("a")])
    state = state(actions: actions, clock: clock) |> HumanActions.run_once()
    assert_received {:posted, _input}
    assert_received {:notified, :human_action_needed, %{reason: "Do a"}}

    Agent.update(actions, &[action("b") | &1])
    Agent.update(clock, fn _now -> 14 * @minute end)
    state = HumanActions.run_once(state)
    refute_received {:posted, _input}

    Agent.update(clock, fn _now -> 15 * @minute end)
    _state = HumanActions.run_once(state)
    assert_received {:posted, %{"body" => body}}
    assert body =~ "**2 actions need you.**"
    assert_received {:notified, :human_action_needed, %{reason: "Do b"}}
    refute_received {:notified, :human_action_needed, %{reason: "Do a"}}
  end

  test "says once that nothing needs the human when the last action closes" do
    clock = start_clock(0)
    actions = start_actions([action("a")])
    state = state(actions: actions, clock: clock) |> HumanActions.run_once()
    assert_received {:posted, _input}

    Agent.update(actions, fn _actions -> [] end)
    Agent.update(clock, fn _now -> 20 * @minute end)
    state = HumanActions.run_once(state)
    assert_received {:posted, %{"projectId" => "project-1", "health" => "onTrack", "body" => "**Nothing needs you.**" <> _rest}}

    Agent.update(clock, fn _now -> 60 * @minute end)
    HumanActions.run_once(state)
    refute_received {:posted, _input}
  end

  test "lists a workflow on the default branch that keeps failing on a missing secret, until it is green again" do
    clock = start_clock(0)
    fake_value = "ghp_" <> String.duplicate("A1b2", 9)
    red = fn id -> %{id: id, workflow_name: "Release", status: "COMPLETED", conclusion: "FAILURE", url: nil, created_at: nil} end

    github_opts = [github: FakeGitHub, github_repo: fn %{name: "cycle"} -> "acme/cycle" end, base_branch: fn "cycle" -> "main" end]
    ci_collect = fn repos, cache, opts -> CiSecrets.collect(repos, cache, opts ++ github_opts) end
    settings = %Schema{ci: %{%Schema{}.ci | enabled: true}, tracker: %{%Schema{}.tracker | project_slug: "cycle"}}

    state =
      state(
        actions: start_actions([]),
        clock: clock,
        repos: fn -> {:ok, [%{name: "cycle"}]} end,
        ci_collect: ci_collect,
        settings_fun: fn -> settings end
      )

    Process.put({:log, "1"}, "SIGNING_KEY=#{fake_value}\nError: secret SIGNING_KEY is not set\n")
    Process.put({:log, "2"}, "SIGNING_KEY=#{fake_value}\nError: secret SIGNING_KEY is not set\n")

    # One red run is not enough.
    Process.put(:runs, [red.("1")])
    state = HumanActions.run_once(state)
    refute_received {:posted, _input}

    Process.put(:runs, [red.("2"), red.("1")])
    state = HumanActions.run_once(state)
    assert_received {:posted, %{"projectId" => "project-1", "health" => "atRisk", "body" => body}}
    assert body =~ "**1 action needs you.**"
    assert body =~ "### 1. Add the `SIGNING_KEY` secret"
    assert body =~ "Unblocks the `Release` workflow on `main` in acme/cycle"
    assert body =~ "1. Open https://github.com/acme/cycle/settings/secrets/actions (the repository's Settings → Secrets and variables → Actions)."
    assert body =~ "**Done when:** the next run of `Release` on `main` is green."
    refute body =~ fake_value
    assert_received {:notified, :human_action_needed, %{issue_identifier: nil, reason: "Add the `SIGNING_KEY` secret", metadata: %{"kind" => "ci_secret"}}}

    Process.put(:runs, [%{red.("3") | conclusion: "SUCCESS"}, red.("2"), red.("1")])
    Agent.update(clock, fn _now -> 15 * @minute end)
    HumanActions.run_once(state)
    assert_received {:posted, %{"projectId" => "project-1", "health" => "onTrack", "body" => "**Nothing needs you.**" <> _rest}}
  end

  test "posts nothing for a project that never had an action" do
    state(actions: start_actions([]), repos: fn -> {:ok, []} end) |> HumanActions.run_once()
    refute_received {:recovered, _project_id}
    refute_received {:posted, _input}

    # A project read with no actions and no earlier update from Symphony stays quiet too.
    collect = fn _repos, _opts -> {:ok, %{"project-1" => %{project: @project, actions: []}}} end
    state(actions: start_actions([]), collect: collect) |> HumanActions.run_once()
    assert_received {:recovered, "project-1"}
    refute_received {:posted, _input}
  end

  test "reads the last list back after a restart instead of posting it again" do
    listed = [action("a")]
    {body, []} = Update.render(listed, "human-action")

    previous =
      {:ok,
       %{
         "data" => %{
           "project" => %{
             "projectUpdates" => %{
               "nodes" => [
                 %{"body" => "Shipped the wrapper.", "createdAt" => "2026-10-04T09:00:00.000Z"},
                 %{"body" => body, "createdAt" => "2026-10-04T10:00:00.000Z"},
                 %{"body" => "list `0000000a` with a bad time", "createdAt" => "yesterday"},
                 %{"id" => "update-without-body"}
               ]
             }
           }
         }
       }}

    posted_at = DateTime.to_unix(~U[2026-10-04 10:00:00.000Z], :millisecond)
    clock = start_clock(posted_at + 5 * @minute)
    actions = start_actions(listed)
    state = state(actions: actions, clock: clock, previous: previous) |> HumanActions.run_once()
    assert_received {:recovered, "project-1"}
    refute_received {:posted, _input}
    assert %{list_id: _list_id, posted_at_ms: ^posted_at, keys: nil} = state.projects["project-1"]

    # A change right after the recovered update waits for the interval, then notifies every action.
    Agent.update(actions, &[action("b") | &1])
    state = HumanActions.run_once(state)
    refute_received {:posted, _input}

    Agent.update(clock, fn _now -> posted_at + 15 * @minute end)
    HumanActions.run_once(state)
    assert_received {:posted, _input}
    assert_received {:notified, :human_action_needed, %{reason: "Do a"}}
    assert_received {:notified, :human_action_needed, %{reason: "Do b"}}
  end

  test "keeps going when Linear fails, and retries the post on the next poll" do
    actions = start_actions([action("a")])

    log =
      capture_log(fn ->
        state(actions: actions, collect: fn _repos, _opts -> {:error, :linear_down} end) |> HumanActions.run_once()
        state(actions: actions, repos: fn -> {:error, :invalid_config} end) |> HumanActions.run_once()
        state(actions: actions, previous: {:ok, %{"errors" => [%{"message" => "no project"}]}}) |> HumanActions.run_once()
      end)

    assert log =~ "could not read the open actions: :linear_down"
    assert log =~ "could not read the open actions: :invalid_config"
    assert log =~ "could not read the last update of project project-1"
    refute_received {:posted, _input}

    failing = state(actions: actions, linear_client: linear(self(), no_updates(), {:error, :linear_down}))
    log = capture_log(fn -> assert HumanActions.run_once(failing).projects["project-1"].list_id == nil end)
    assert log =~ "could not post the update to project Cycle"
    assert_received {:posted, _input}
    refute_received {:notified, _event, _attrs}
  end

  test "never posts a secret value, and audits the redaction" do
    audit_dir = Path.join(System.tmp_dir!(), "human-actions-audit-#{System.unique_integer([:positive])}")
    secret = "sk-ant-" <> String.duplicate("a", 24)
    actions = start_actions([action("a", %{title: "Rotate #{secret}", steps: ["Paste #{secret}"]})])

    try do
      state(actions: actions, audit_opts: [dir: audit_dir]) |> HumanActions.run_once()

      assert_received {:posted, %{"body" => body}}
      refute body =~ secret
      assert_received {:notified, :human_action_needed, %{reason: reason}}
      refute reason =~ secret

      assert [%{"event_type" => "agent_tool_secret_redaction", "tool" => "human_actions"}] =
               audit_dir |> Path.join("*.ndjson") |> Path.wildcard() |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true))) |> Enum.map(&Jason.decode!/1)
    after
      File.rm_rf(audit_dir)
    end
  end

  test "polls on its own, counts its Linear requests as `human_actions`, and refreshes on request" do
    actions = start_actions([action("a")])
    %{opts: opts} = state(actions: actions)
    settings = %Schema{human_actions: %{%Schema{}.human_actions | interval_ms: 3_600_000, min_update_interval_ms: 0}}
    name = :"human_actions_#{System.unique_integer([:positive])}"

    pid = start_supervised!({HumanActions, Keyword.merge(opts, name: name, initial_delay_ms: 0, refresh_delay_ms: 0, settings_fun: fn -> settings end)})

    assert_receive {:recovered, "project-1"}
    assert_receive {:posted, %{"body" => "**1 action needs you.**" <> _rest}}
    assert_receive {:caller, :human_actions}

    # The next poll is an hour away, so only the refresh can post the changed list now.
    Agent.update(actions, &[action("b") | &1])
    assert :ok = HumanActions.refresh(name)
    assert_receive {:posted, %{"body" => "**2 actions need you.**" <> _rest}}, 1_000
    assert Process.alive?(pid)

    assert :ok = HumanActions.refresh(:"not_running_#{System.unique_integer([:positive])}")
  end

  test "is on for a Linear tracker with human_actions.enabled" do
    linear = %Schema{tracker: %{%Schema{}.tracker | kind: "linear"}}

    assert HumanActions.enabled?(linear)
    refute HumanActions.enabled?(%{linear | human_actions: %{linear.human_actions | enabled: false}})
    refute HumanActions.enabled?(%Schema{tracker: %{%Schema{}.tracker | kind: "memory"}})
  end
end
