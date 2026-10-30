defmodule SymphonyElixir.SelfHealTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import SymphonyElixir.TestSupport, only: [ticket_events: 2]

  alias SymphonyElixir.{BlockedHold, NeedsDecisionHold, Pauses, Questions, SelfHeal, TicketState}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HumanActions.Collector
  alias SymphonyElixir.Linear.Issue

  @repo_key "repo-self-heal"
  @issue_id "issue-self-heal"
  @symphony_repo_key "repo-symphony"
  @fix_ticket "TP-900"

  # The run store, standing in for the real one so a test can script every read and write.
  defmodule Store do
    def get_ticket_state(_repo_key, _issue_id), do: Process.get(:ticket_state)
    def list_all_ticket_states, do: Process.get(:ticket_states, [])

    def record_ticket_self_heal(_repo_key, _issue_id, attrs) do
      Process.put(:recorded_self_heal, attrs)
      Process.get(:record_result, :ok)
    end

    def set_ticket_hold(_repo_key, _issue_id, kind, attrs) do
      Process.put(:hold_attrs, {kind, attrs})
      Process.get(:hold_result, :ok)
    end

    def clear_ticket_hold(_repo_key, _issue_id, kind) do
      Process.put(:hold_cleared, kind)
      :ok
    end
  end

  # The fix-ticket filer: every effect is recorded, and each one can be made to fail.
  defmodule Fixer do
    def create(attrs, _opts) do
      Process.put(:fixer_create, attrs)
      Process.get(:create_result, {:ok, %{identifier: "TP-900", url: "https://linear.app/acme/issue/TP-900"}})
    end

    def attach(identifier, body, _opts) do
      Process.put(:fixer_attach, {identifier, body})
      Process.get(:attach_result, :ok)
    end

    def block(issue, ticket, _opts) do
      Process.put(:fixer_block, {issue.id, ticket.identifier})
      Process.get(:block_result, :ok)
    end
  end

  # The tracker: the machine-label projection the holds go through, and the fix ticket's state.
  defmodule Tracker do
    def set_machine_label(issue_id, label) do
      Process.put(:machine_label, {issue_id, label})
      Process.get(:label_result, :ok)
    end

    def clear_machine_label(_issue_id, _label), do: :ok
    def fetch_issue_by_identifier(identifier), do: Process.get({:fix_ticket_state, identifier}, {:error, :not_found})

    def create_comment(issue_id, body) do
      Process.put(:comment, {issue_id, body})
      Process.get(:comment_result, :ok)
    end
  end

  # The Linear client the fixer's adapter calls, dispatched on the operation name in the query.
  defmodule LinearClient do
    def graphql(query, variables) do
      Process.put(:graphql_calls, [{query, variables} | Process.get(:graphql_calls, [])])

      cond do
        query =~ "SymphonyTeams" -> Process.get(:teams_result, {:ok, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "t1", "key" => "TP"}]}}}})
        query =~ "SymphonyCreateIssueScope" -> Process.get(:scope_result, {:ok, scope_response()})
        query =~ "SymphonyCreateIssueRelation" -> Process.get(:relation_result, {:ok, %{"data" => %{"issueRelationCreate" => %{"success" => true}}}})
        query =~ "SymphonyCreateIssue" -> Process.get(:create_result, {:ok, create_response()})
        query =~ "SymphonyIssueId" -> Process.get(:issue_id_result, {:ok, %{"data" => %{"issue" => %{"id" => "blocker-id"}}}})
        true -> flunk("unexpected query: #{query}")
      end
    end

    defp scope_response do
      %{
        "data" => %{
          "team" => %{
            "id" => "t1",
            "states" => %{"nodes" => [%{"id" => "s-todo", "name" => "Todo"}]},
            "projects" => %{"nodes" => [%{"id" => "p1", "name" => "Fix Project"}]}
          }
        }
      }
    end

    defp create_response do
      %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "i1", "identifier" => "TP-900", "url" => "https://linear.app/acme/issue/TP-900"}
          }
        }
      }
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, LinearClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :linear_client_module)
      end
    end)

    :ok
  end

  defp issue(attrs \\ %{}) do
    struct!(%Issue{id: @issue_id, identifier: "TP-816", repo_key: @repo_key}, attrs)
  end

  defp heal_opts(outcome, extra \\ []) do
    extra ++
      [
        outcome: outcome,
        repo_key: @repo_key,
        symphony_repo_key: @symphony_repo_key,
        store: Store,
        tracker: Tracker,
        fixer: Fixer
      ]
  end

  defp outcome(cause, extra \\ %{}) do
    Map.merge(%{verdict: :blocked, cause: cause, reason: inspect(cause), findings: [], needs_person: false}, extra)
  end

  # A ticket-state record carrying self-heal bookkeeping, as a previous run would have left it.
  defp recorded(repo_key, issue_id, attrs) do
    repo_key
    |> TicketState.new(issue_id)
    |> TicketState.put_self_heal(attrs)
  end

  describe "component/1" do
    test "maps each known cause to its component" do
      cases = [
        {{:qa_dev_server_failed, {:verification_failed, {:dev_server_build_failed, 3}}}, "dev_server"},
        {{:qa_dev_server_failed, :health_timeout, "listening soon"}, "dev_server"},
        {{:qa_dev_server_failed, {:dev_server_port_busy, 8090, 6557, "TP-1124"}, ""}, "dev_server"},
        {{:qa_dev_server_failed, {:dev_server_unreachable, "ssh: refused"}, ""}, "qa_environment"},
        {{:verification_failed, {:dev_server_exit, 1}}, "dev_server"},
        {{:dev_server_not_on_socket, "s"}, "dev_server"},
        {{:dev_server_not_configured}, "dev_server"},
        {:health_timeout, "dev_server"},
        {{:remote_worker_unsupported, "worker-1"}, "worker_host"},
        {{:qa_host_missing_tool, ["go"]}, "worker_host"},
        {{:qa_worker, "qa_worker_unsafe"}, "worker_host"},
        {{:qa_host_tool_check_failed, "exit status 255"}, "worker_host"},
        {"no QA playbook applies to this change", "qa_playbook"},
        {"QA cannot run on the remote worker \"worker-1\"", "worker_host"},
        {"something else entirely", "qa_environment"},
        {:unknown_atom, "qa_environment"}
      ]

      for {cause, component} <- cases do
        assert SelfHeal.component(%{cause: cause}) == component
      end

      assert SelfHeal.component(%{reason: "no QA playbook applies"}) == "qa_playbook"

      # A QA run that says the project's own server was not running names its dev server, whatever its wording.
      assert SelfHeal.component(%{reason: "Without a running hub, the app can't show the board", needs_dev_server: true}) == "dev_server"
      assert SelfHeal.component(%{reason: "Without a running hub, the app can't show the board", needs_dev_server: false}) == "qa_environment"

      # The PR and CI watcher's red backstop names the failing check, with or without its error.
      assert SelfHeal.component(%{cause: {:ci_check_failed, "make all"}}) == "ci:make all"
      assert SelfHeal.component(%{cause: {:ci_check_failed, "make all", "ERROR: boom"}}) == "ci:make all"
    end

    test "falls back to the flow's own environment for anything unrecognized" do
      assert SelfHeal.component(:not_a_map) == "qa_environment"
      assert SelfHeal.component(nil) == "qa_environment"
    end
  end

  describe "scope/3" do
    test "the affected repo owns its own build/test/run setup, Symphony the rest" do
      assert SelfHeal.scope("dev_server", @repo_key, symphony_repo_key: @symphony_repo_key) == @repo_key
      assert SelfHeal.scope("qa_environment", @repo_key, symphony_repo_key: @symphony_repo_key) == @symphony_repo_key
      assert SelfHeal.scope("worker_host", @repo_key, symphony_repo_key: @symphony_repo_key) == @symphony_repo_key
      assert SelfHeal.scope("qa_playbook", @repo_key, symphony_repo_key: @symphony_repo_key) == @symphony_repo_key
      # A CI check belongs to the repo whose CI fails.
      assert SelfHeal.scope("ci:make all", @repo_key, symphony_repo_key: @symphony_repo_key) == @repo_key
    end

    test "falls back to the configured primary repo when none is given" do
      assert SelfHeal.scope("qa_environment", @repo_key) == SymphonyElixir.Config.repo_key_or_nil()
    end
  end

  describe "dev_server_ruled_out/2" do
    @dev_server %{"start_cmd" => "bin/hub", "health_check_url" => "http://localhost:4000/healthz"}
    @own_server_macos %{"macos_app" => %{"build" => "make app", "app" => "build/Hub.app", "dev_server" => true}}
    @cli [%{kind: "cli", paths: [], prompt: "Follow the CLI playbook."}]

    defp repo_settings(verification, playbooks \\ %{}) do
      assert {:ok, settings} =
               Schema.parse(%{"tracker" => %{"kind" => "memory"}, "verification" => verification, "auto_review" => %{"playbooks" => playbooks}})

      settings
    end

    test "a repo that sets up a dev server but keeps it switched off has ruled it out, with the Mac app's pass named when it runs the server" do
      assert SelfHeal.dev_server_ruled_out(repo_settings(%{"enabled" => false, "dev_server" => @dev_server}, @own_server_macos), @cli) =~
               "runs its own server only beside the app on the QA host"

      assert SelfHeal.dev_server_ruled_out(repo_settings(%{"enabled" => false, "dev_server" => @dev_server}), @cli) ==
               "this repo sets up a dev server but keeps it switched off on the Symphony host, so no QA pass here has the server"
    end

    test "a pass whose own playbook runs the server has not ruled it out" do
      settings = repo_settings(%{"enabled" => false, "dev_server" => @dev_server}, @own_server_macos)

      own_server = %{kind: "macos_app", dev_server: true, paths: [], prompt: ""}

      assert SelfHeal.dev_server_ruled_out(settings, [own_server | @cli]) == nil
      assert SelfHeal.dev_server_ruled_out(settings, [%{kind: "web", paths: [], prompt: ""}]) == nil
    end

    test "a repo with no dev server, or with verification on, has ruled nothing out: the repair stays open to it" do
      assert SelfHeal.dev_server_ruled_out(repo_settings(%{"enabled" => false}), @cli) == nil
      verification_on = repo_settings(%{"enabled" => true, "dev_server" => @dev_server}, @own_server_macos)
      assert SelfHeal.dev_server_ruled_out(verification_on, @cli) == nil
    end
  end

  describe "signature/1" do
    test "normalizes the outcome's cause" do
      assert SelfHeal.signature(%{cause: {:dev_server_exit, 3}}) == "{:dev_server_exit, 3}"
      # A QA-host dev server's log is not part of the failure.
      assert SelfHeal.signature(%{cause: {:qa_dev_server_failed, :health_timeout, "one log"}}) == "{:qa_dev_server_failed, :health_timeout}"
      # Nor is the pid that holds a busy port, which changes from run to run.
      assert SelfHeal.signature(%{cause: {:qa_dev_server_failed, {:dev_server_port_busy, 8090, 6557, "TP-1124"}, ""}}) ==
               "{:qa_dev_server_failed, {:dev_server_port_busy, 8090}}"

      assert SelfHeal.signature(%{cause: "  a   spaced\n reason "}) == "a spaced reason"
      assert SelfHeal.signature(%{cause: nil, reason: nil}) == ""
      assert SelfHeal.signature(:not_a_map) == ""
    end

    test "a QA agent's own block is named by its blocked steps and covering ticket, not its wording" do
      steps = [
        %{name: " Watch the  update banner", status: "blocked"},
        %{name: "Open the window", status: "blocked"},
        %{name: "Open the window", status: "blocked"},
        %{name: " ", status: "blocked"},
        %{name: "Read the notes", status: "pass"}
      ]

      first = %{reason: "qa_launch_app cannot set the update feed", steps: steps, covered_by: "TP-1000"}
      reworded = %{first | reason: "The app cannot be pointed at a fake update feed", steps: Enum.reverse(steps)}

      assert SelfHeal.signature(first) == "blocked steps: Open the window, Watch the update banner; covered by: TP-1000"
      assert SelfHeal.signature(reworded) == SelfHeal.signature(first)
      assert SelfHeal.signature(%{reason: "anything", steps: steps}) == "blocked steps: Open the window, Watch the update banner"
      assert SelfHeal.signature(%{reason: "anything", steps: [], covered_by: "TP-1000"}) == "covered by: TP-1000"

      # The machine's own cause still wins, and a run with neither falls back to its reason.
      assert SelfHeal.signature(%{cause: :environment_unreachable, steps: steps}) == ":environment_unreachable"
      assert SelfHeal.signature(%{reason: " no  steps ", steps: [%{name: "x", status: "pass"}]}) == "no steps"
      assert SelfHeal.signature(%{reason: "no steps key"}) == "no steps key"
    end
  end

  describe "compare/2" do
    test "tells progress from no new information" do
      assert SelfHeal.compare(nil, "anything") == :first
      assert SelfHeal.compare("same", "same") == :same
      assert SelfHeal.compare("anything", "") == :same
      assert SelfHeal.compare("{:dev_server_exit, 3} at line 1", "{:dev_server_exit, 3}") == :narrowed
      assert SelfHeal.compare("old failure", "a different one") == :changed
    end
  end

  # Another affected ticket's record of the fix ticket it filed for `signature`.
  defp fix_record(signature, fix_ticket \\ @fix_ticket) do
    recorded(@symphony_repo_key, "other-issue", %{
      component: "qa_environment",
      scope: @symphony_repo_key,
      signature: signature,
      fix_ticket: fix_ticket
    })
  end

  describe "heal/2" do
    test "files one fix ticket, records the bookkeeping, links and holds the ticket on it" do
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      assert %{component: "qa_environment", scope: @symphony_repo_key, fix_ticket: @fix_ticket, signature: ":environment_unreachable"} =
               Process.get(:recorded_self_heal)

      assert %{scope: @symphony_repo_key, component: "qa_environment", title: "Self-heal: repair the qa_environment block"} = Process.get(:fixer_create)
      assert Process.get(:fixer_block) == {@issue_id, @fix_ticket}

      assert {:blocked, %{waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}}} = Process.get(:hold_attrs)
      assert {@issue_id, "Blocked"} = Process.get(:machine_label)
    end

    test "pauses the ticket on the fix ticket beside its hold, once however often it heals" do
      :ok = SymphonyElixir.RunStore.clear()
      on_exit(fn -> SymphonyElixir.RunStore.clear() end)
      ticket = {:ticket, @repo_key, @issue_id}

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      assert {:ok, %{reasons: [reason]}} = Pauses.get(ticket)
      assert %{kind: :ticket, waits_on: %{identifier: @fix_ticket}, text: "Waiting for TP-900 to finish: it fixes what stopped this ticket"} = reason
      assert reason.set_by == BlockedHold.reason_setter(:fix_ticket)
      assert [{"pause.set", %{waits_on: %{identifier: @fix_ticket}}}] = ticket_events(@repo_key, @issue_id) |> Enum.filter(&match?({"pause." <> _, _}, &1))
    end

    test "a setup block's dev server build files in the project's repo, and the hold gives the cause in words" do
      outcome = SymphonyElixir.SetupBlock.outcome({:verification_failed, {:dev_server_build_failed, 127}})
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome))

      assert %{scope: @repo_key, component: "dev_server", description: description} = Process.get(:fixer_create)
      assert description =~ "before the agent's first turn"

      assert {:blocked, %{reason: reason}} = Process.get(:hold_attrs)

      assert reason ==
               "waiting on fix ticket TP-900 for the dev_server block: " <>
                 "verification.dev_server build failed with exit 127: a command it runs is not on the sandbox PATH"
    end

    test "a setup block's port collision is Symphony's, a structural cause" do
      outcome = SymphonyElixir.SetupBlock.outcome({:verification_failed, {:loopback_bridge_unavailable, :eaddrinuse}})
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome))

      assert %{scope: @symphony_repo_key, component: "qa_environment"} = Process.get(:fixer_create)
      assert {:blocked, %{reason: reason}} = Process.get(:hold_attrs)
      assert reason =~ "the port is already in use (eaddrinuse)"
    end

    test "files a QA host's missing tool in Symphony's repo, where its provisioning script lives" do
      cause = {:qa_host_missing_tool, ["go"]}
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(cause, %{reason: SymphonyElixir.QaAgent.blocked_reason(cause)})))

      assert %{scope: @symphony_repo_key, component: "worker_host", title: "Self-heal: repair the worker_host block", description: description} =
               Process.get(:fixer_create)

      assert description =~ "qa_host_missing_tool: go"
      assert description =~ "scripts/qa-vm/provision.sh"
    end

    test "a CI check that keeps failing files a fix ticket in the repo whose CI fails, naming the pull request" do
      ci = outcome({:ci_check_failed, "specs"}, %{reason: "CI keeps failing", pr_url: "https://github.com/acme/app/pull/7", head_sha: "abcdef123456"})

      assert :filed = SelfHeal.heal(issue(), heal_opts(ci))

      assert %{scope: @repo_key, component: "ci:specs", title: "Self-heal: CI keeps failing the specs check", description: description} = Process.get(:fixer_create)
      assert description =~ "- Pull request: https://github.com/acme/app/pull/7 at `abcdef1`"
      assert description =~ "CI Fix runs could not make the `specs` check pass on PR #7."
      assert description =~ "The failure may be that pull request's own rather than this repo's CI"
      assert %{component: "ci:specs", scope: @repo_key, signature: ~s({:ci_check_failed, "specs"})} = Process.get(:recorded_self_heal)

      # A pull request read without its head is named without one.
      assert :filed = SelfHeal.heal(issue(), heal_opts(Map.delete(ci, :head_sha)))
      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "- Pull request: https://github.com/acme/app/pull/7\n"
    end

    test "a CI check failing after another component's block, or another check's, files its own fix ticket" do
      ci = outcome({:ci_check_failed, "specs"})

      for previous <- [
            %{component: "ci:lint", scope: @repo_key, signature: ~s({:ci_check_failed, "lint"})},
            %{component: "qa_environment", scope: @symphony_repo_key, signature: "an old failure"},
            %{component: "dev_server", scope: @repo_key, signature: ~s({:ci_check_failed, "specs"})}
          ] do
        Process.delete(:fixer_create)
        Process.put(:ticket_state, recorded(@repo_key, @issue_id, previous))
        assert :filed = SelfHeal.heal(issue(), heal_opts(ci))
        assert %{component: "ci:specs"} = Process.get(:fixer_create)
      end

      # A QA block after a CI backstop is a new break too.
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "ci:specs", scope: @repo_key, signature: "x"}))
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      # The same check failing the same way after its fix landed escalates, as any block does.
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "ci:specs", scope: @repo_key, signature: ~s({:ci_check_failed, "specs"})}))
      assert :escalated = SelfHeal.heal(issue(), heal_opts(ci))
    end

    test "a failed check's signature is its name and first error line, the same failure the PR watcher's streak counts" do
      assert SelfHeal.signature(%{cause: {:ci_check_failed, "specs", "  ERROR:\tboom  "}}) == "specs: ERROR: boom"

      # After its fix landed, the same error escalates; another error of the same check is progress.
      ci = outcome({:ci_check_failed, "specs", "ERROR: boom"})
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "ci:specs", scope: @repo_key, signature: "specs: ERROR: boom"}))
      assert :escalated = SelfHeal.heal(issue(), heal_opts(ci))
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "ci:specs", scope: @repo_key, signature: "specs: ERROR: other"}))
      assert :retry = SelfHeal.heal(issue(), heal_opts(ci, attempts: 1))
    end

    test "a failing check gets one open fix ticket per repo, whatever error each ticket hit" do
      other = recorded(@repo_key, "other-issue", %{component: "ci:specs", scope: @repo_key, signature: "specs: ERROR: other", fix_ticket: @fix_ticket})
      Process.put(:ticket_states, [other])
      Process.put({:fix_ticket_state, @fix_ticket}, {:ok, %Issue{id: "fix-id", identifier: @fix_ticket, state: "Todo"}})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome({:ci_check_failed, "specs", "ERROR: boom"}), terminal_states: ["Done"]))
      assert Process.get(:fixer_create) == nil
      assert {@fix_ticket, evidence} = Process.get(:fixer_attach)
      assert evidence =~ "specs: ERROR: boom"
    end

    test "a block a person must clear keeps the access hold and files nothing" do
      assert :held = SelfHeal.heal(issue(), heal_opts(outcome(:secret_missing, %{needs_person: true})))

      assert Process.get(:fixer_create) == nil

      assert {:blocked, %{waits_on: %{type: "access", keys: []}, reason: reason}} = Process.get(:hold_attrs)
      assert reason == "QA blocked after 0 attempt(s): :secret_missing"
    end

    test "a block a person must clear pauses the ticket on the broken component beside its access hold, once" do
      :ok = SymphonyElixir.RunStore.clear()
      on_exit(fn -> SymphonyElixir.RunStore.clear() end)
      ticket = {:ticket, @repo_key, @issue_id}
      outcome = outcome({:qa_worker, "qa_worker_unreachable"}, %{needs_person: true})

      assert :held = SelfHeal.heal(issue(), heal_opts(outcome))
      assert :held = SelfHeal.heal(issue(), heal_opts(outcome))

      assert {:blocked, %{waits_on: %{type: "access", keys: []}}} = Process.get(:hold_attrs)
      assert {:ok, %{reasons: [reason]}} = Pauses.get(ticket)
      assert %{kind: :environment, waits_on: %{condition: "self_heal:worker_host"}, text: "The QA machine is not reachable", releasable: true} = reason
      assert reason.set_by == BlockedHold.reason_setter(:fix_ticket)
      assert SelfHeal.environment_reason?(reason)
    end

    test "reuses the open fix ticket another ticket already filed for the same failure, attaching the evidence" do
      Process.put(:ticket_states, [fix_record(":environment_unreachable")])
      Process.put({:fix_ticket_state, @fix_ticket}, {:ok, %Issue{id: "fix-id", identifier: @fix_ticket, state: "In Progress"}})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable), terminal_states: ["Done", "Canceled"]))

      assert Process.get(:fixer_create) == nil
      assert {@fix_ticket, evidence} = Process.get(:fixer_attach)
      assert evidence =~ ":environment_unreachable"
      assert Process.get(:fixer_block) == {@issue_id, @fix_ticket}
      assert {:blocked, %{waits_on: %{type: "fix_ticket", keys: [@fix_ticket]}}} = Process.get(:hold_attrs)
    end

    test "a fix ticket of the same component that is terminal or unreadable is not reused; a new one is filed" do
      # TP-971 on 2026-10-13: the record pointed at TP-919, Done an hour earlier.
      Process.put(:ticket_states, [fix_record(":environment_unreachable", "TP-919")])
      Process.put(:create_result, {:ok, %{identifier: "TP-1001", url: "https://linear.app/acme/issue/TP-1001"}})

      for fix_state <- [{:ok, %Issue{id: "fix-id", identifier: "TP-919", state: "Done"}}, {:error, :not_found}] do
        Process.delete(:fixer_create)
        Process.delete(:fixer_attach)
        Process.put({:fix_ticket_state, "TP-919"}, fix_state)

        log =
          capture_log(fn ->
            assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable), terminal_states: ["Done", "Canceled"]))
          end)

        assert %{component: "qa_environment", scope: @symphony_repo_key} = Process.get(:fixer_create)
        assert Process.get(:fixer_attach) == nil
        assert Process.get(:fixer_block) == {@issue_id, "TP-1001"}
        assert {:blocked, %{waits_on: %{type: "fix_ticket", keys: ["TP-1001"]}}} = Process.get(:hold_attrs)
        assert %{fix_ticket: "TP-1001"} = Process.get(:recorded_self_heal)
        if fix_state == {:error, :not_found}, do: assert(log =~ "cannot reuse fix ticket TP-919")
      end
    end

    test "an open fix ticket of the same component but for a different failure is not reused" do
      # TP-919 tracked selecting a row in the Tickets table; this block is a missing signing key.
      Process.put(:ticket_states, [fix_record("the Tickets table row cannot be selected", "TP-919")])
      Process.put({:fix_ticket_state, "TP-919"}, {:ok, %Issue{id: "fix-id", identifier: "TP-919", state: "In Progress"}})

      assert :filed =
               SelfHeal.heal(issue(), heal_opts(outcome("the QA build has no update signing key"), terminal_states: ["Done", "Canceled"]))

      assert %{component: "qa_environment", description: description} = Process.get(:fixer_create)
      assert description =~ "the QA build has no update signing key"
      assert Process.get(:fixer_attach) == nil
      assert {:blocked, %{waits_on: %{keys: [@fix_ticket]}}} = Process.get(:hold_attrs)
    end

    test "a blocked QA outcome naming an open covering ticket holds the ticket on it and files nothing" do
      # TP-716 already tracks the QA tools the run lacks: the acceptance gate filed it, so no
      # self-heal record names it.
      Process.put({:fix_ticket_state, "TP-716"}, {:ok, %Issue{id: "covering-id", identifier: "TP-716", state: "Merging"}})
      outcome = outcome("a fake gh and a git checkout are missing on the QA host", %{covered_by: "TP-716"})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome, terminal_states: ["Done", "Canceled"]))

      assert Process.get(:fixer_create) == nil
      assert Process.get(:fixer_block) == {@issue_id, "TP-716"}
      assert {"TP-716", evidence} = Process.get(:fixer_attach)
      assert evidence =~ "a fake gh and a git checkout are missing"

      assert {:blocked, %{waits_on: %{type: "fix_ticket", keys: ["TP-716"]}, reason: reason}} = Process.get(:hold_attrs)
      assert reason =~ "waiting on fix ticket TP-716 for the qa_environment block"
      assert %{fix_ticket: "TP-716", component: "qa_environment"} = Process.get(:recorded_self_heal)

      # A covering ticket without a known state counts as open, as a blocker does.
      Process.put({:fix_ticket_state, "TP-716"}, {:ok, %Issue{id: "covering-id", identifier: "TP-716", state: nil}})
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome, terminal_states: ["Done", "Canceled"]))
      assert Process.get(:fixer_create) == nil
    end

    test "a covering ticket that is terminal, unreadable or the ticket itself covers nothing" do
      Process.put({:fix_ticket_state, "TP-716"}, {:ok, %Issue{id: "covering-id", identifier: "TP-716", state: "Done"}})
      Process.put({:fix_ticket_state, "TP-816"}, {:ok, issue(%{state: "QA"})})

      for covered_by <- ["TP-716", "TP-404", "TP-816"] do
        Process.delete(:fixer_create)
        outcome = outcome(:environment_unreachable, %{covered_by: covered_by})

        log =
          capture_log(fn ->
            assert :filed = SelfHeal.heal(issue(), heal_opts(outcome, terminal_states: ["Done", "Canceled"]))
          end)

        assert %{component: "qa_environment"} = Process.get(:fixer_create)
        assert {:blocked, %{waits_on: %{keys: [@fix_ticket]}}} = Process.get(:hold_attrs)
        if covered_by != "TP-716", do: assert(log =~ "cannot wait on #{covered_by}")
      end
    end

    test "reports a fix ticket that could not be filed, or a hold that could not be set" do
      Process.put(:create_result, {:error, :linear_down})
      assert {:error, {:self_heal_fix_ticket_failed, :linear_down}} = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      Process.delete(:create_result)
      Process.put(:hold_result, {:error, :disk_full})
      assert {:error, {:self_heal_hold_failed, :disk_full}} = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
    end

    test "an unknown scope is reported instead of filing somewhere arbitrary" do
      assert {:error, {:self_heal_scope_unknown, "worker_host"}} =
               SelfHeal.heal(issue(), heal_opts(outcome({:remote_worker_unsupported, "worker-1"}), symphony_repo_key: nil))
    end

    test "a failure with no new information escalates to a Needs Decision hold" do
      :ok = SymphonyElixir.RunStore.clear()

      previous =
        recorded(@repo_key, @issue_id, %{
          component: "qa_environment",
          scope: @symphony_repo_key,
          signature: ":environment_unreachable",
          fix_ticket: @fix_ticket
        })

      Process.put(:ticket_state, previous)

      assert :escalated = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      assert {:needs_decision, %{decision: decision, reason: reason}} = Process.get(:hold_attrs)
      assert reason =~ "The qa environment block on TP-816 came back unchanged"
      assert decision.title == "Self-heal is stuck on the qa environment block"
      assert Enum.map(decision.options, &Map.get(&1, :recommended)) == [true, nil]
      # The question is asked through the Question service, and the hold carries it.
      assert [%{id: id, title: "Self-heal is stuck on the qa environment block", options: [_investigate, _drop]}] = Questions.open({:ticket, @repo_key, @issue_id})
      assert decision.question_id == id
      assert [{"question.asked", %{title: "Self-heal is stuck on the qa environment block"}}, {"pause.set", _pause}] = ticket_events(@repo_key, @issue_id)

      # TP-1019: the decision is posted as a request, so the Inbox's read of the ticket finds it open
      # and keeps the hold. With no request it cleared the hold, and the ticket dispatched again.
      assert {@issue_id, "## Decision needed: Self-heal is stuck on the qa environment block" <> _rest = body} = Process.get(:comment)
      node = %{"id" => @issue_id, "comments" => %{"nodes" => [%{"id" => "c1", "body" => body, "createdAt" => "2026-10-14T22:35:27.000Z"}]}}
      assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})

      request = Collector.newest_request(node, settings)
      assert NeedsDecisionHold.desired(request, %{kind: :needs_decision, decision: decision}) == :none
    end

    test "an escalation whose request can't be posted keeps the question asked and its hold" do
      :ok = SymphonyElixir.RunStore.clear()
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: ":environment_unreachable"}))
      Process.put(:comment_result, {:error, :linear_down})

      capture_log(fn ->
        assert {:error, {:self_heal_escalation_request_failed, :linear_down}} = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
      end)

      assert Process.get(:hold_cleared) == nil
      assert {:needs_decision, %{decision: %{question_id: id}}} = Process.get(:hold_attrs)
      assert [%{id: ^id}] = Questions.open({:ticket, @repo_key, @issue_id})
    end

    test "a block that recurs after the fix landed, unchanged, escalates instead of filing again" do
      # The shape a lifted fix-ticket hold leaves: the record keeps the signature but no fix ticket.
      previous =
        recorded(@repo_key, @issue_id, %{
          component: "qa_environment",
          scope: @symphony_repo_key,
          signature: ":environment_unreachable",
          fix_ticket: nil,
          attempts: 2
        })

      Process.put(:ticket_state, previous)

      assert :escalated = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      assert {:needs_decision, _attrs} = Process.get(:hold_attrs)
      assert Process.get(:fixer_create) == nil
    end

    test "a narrowed failure retries with the new information, attached to the fix ticket" do
      previous =
        recorded(@repo_key, @issue_id, %{
          component: "dev_server",
          scope: @repo_key,
          signature: "{:dev_server_exit, 3} after build",
          fix_ticket: @fix_ticket
        })

      Process.put(:ticket_state, previous)

      assert :retry = SelfHeal.heal(issue(), heal_opts(outcome({:dev_server_exit, 3})))

      assert %{fix_ticket: @fix_ticket, signature: "{:dev_server_exit, 3}"} = Process.get(:recorded_self_heal)
      assert {@fix_ticket, evidence} = Process.get(:fixer_attach)
      assert evidence =~ "{:dev_server_exit, 3}"
      assert Process.get(:hold_attrs) == nil
    end

    test "the same blocked steps found to need the project's own server after a Symphony repair file in the project's repo" do
      steps = [%{name: "Open the Pipeline board", status: "blocked"}, %{name: "Wide pass", status: "blocked"}]
      first = %{verdict: :blocked, reason: "Without a running hub, the app can't show the board", steps: steps, findings: []}
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: SelfHeal.signature(first)}))

      # Narrowed to one of the steps, or unchanged: either way the project's repo has never been asked.
      for again <- [first, %{first | steps: Enum.take(steps, 1)}] do
        Process.delete(:fixer_create)
        assert :filed = SelfHeal.heal(issue(), heal_opts(Map.put(again, :needs_dev_server, true), attempts: 3))

        assert %{scope: @repo_key, component: "dev_server", title: "Self-heal: repair the dev_server block", description: description} =
                 Process.get(:fixer_create)

        assert description =~ "QA had no running copy of this project's own server"
        assert description =~ "set `verification.enabled: true` and `verification.dev_server`"
        assert %{component: "dev_server", scope: @repo_key, fix_ticket: @fix_ticket} = Process.get(:recorded_self_heal)
      end

      # Once the project's repo has its fix ticket, the same block again is unchanged and escalates.
      again = Map.put(first, :needs_dev_server, true)
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "dev_server", scope: @repo_key, signature: SelfHeal.signature(again)}))
      assert :escalated = SelfHeal.heal(issue(), heal_opts(again, attempts: 4))
    end

    test "another component's failure with the same owner is compared, not filed again" do
      previous = %{component: "worker_host", scope: @symphony_repo_key, signature: ":environment_unreachable on worker-1", fix_ticket: @fix_ticket}
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, previous))

      assert :retry = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
      assert Process.get(:fixer_create) == nil
      assert %{component: "qa_environment", fix_ticket: @fix_ticket} = Process.get(:recorded_self_heal)
    end

    test "a dev server that fails to start keeps the generic fix description" do
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome({:dev_server_exit, 3})))
      assert %{component: "dev_server", description: description} = Process.get(:fixer_create)
      assert description =~ "This is the dev_server component"
      refute description =~ "QA had no running copy"
    end

    test "a reworded QA block with the same blocked steps escalates instead of retrying" do
      steps = [%{name: "Watch the update banner", status: "blocked"}]
      first = %{verdict: :blocked, reason: "qa_launch_app cannot set the update feed", steps: steps, findings: []}

      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: SelfHeal.signature(first)}))

      reworded = %{first | reason: "The app cannot be pointed at a fake update feed"}
      assert :escalated = SelfHeal.heal(issue(), heal_opts(reworded, attempts: 3))
      assert {:needs_decision, %{decision: decision}} = Process.get(:hold_attrs)
      assert decision.question =~ "came back unchanged after 3 attempt(s)"
    end

    test "a changed failure retries only while the head has attempts left" do
      previous = recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: "blocked steps: Open the window"})
      outcome = %{verdict: :blocked, reason: "blocked", steps: [%{name: "Watch the update banner", status: "blocked"}], findings: []}

      Process.put(:ticket_state, previous)
      assert :retry = SelfHeal.heal(issue(), heal_opts(outcome, attempts: 4))
      assert Process.get(:hold_attrs) == nil

      Process.put(:ticket_state, previous)

      log =
        capture_log(fn ->
          assert :escalated = SelfHeal.heal(issue(), heal_opts(outcome, attempts: 5))
        end)

      assert log =~ "stuck on the qa_environment block"
      assert {:needs_decision, %{decision: decision, reason: reason}} = Process.get(:hold_attrs)
      assert reason =~ "blocked steps: Watch the update banner"
      assert decision.question =~ "kept coming back over 5 blocked runs of the same change"
      assert decision.why =~ "only 5 times for one change"
    end

    test "an open covering ticket holds the ticket on it even after an earlier failure was recorded" do
      Process.put({:fix_ticket_state, "TP-1000"}, {:ok, %Issue{id: "covering-id", identifier: "TP-1000", state: "CI Fix"}})
      outcome = %{verdict: :blocked, reason: "needs TP-1000", steps: [%{name: "Watch the update banner", status: "blocked"}], findings: [], covered_by: "TP-1000"}

      for signature <- [SelfHeal.signature(outcome), "an older failure"] do
        Process.delete(:hold_attrs)
        Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: signature}))

        assert :filed = SelfHeal.heal(issue(), heal_opts(outcome, attempts: 9, terminal_states: ["Done", "Canceled"]))

        assert Process.get(:fixer_create) == nil
        assert Process.get(:fixer_block) == {@issue_id, "TP-1000"}
        assert {:blocked, %{waits_on: %{type: "fix_ticket", keys: ["TP-1000"]}}} = Process.get(:hold_attrs)
        assert %{fix_ticket: "TP-1000"} = Process.get(:recorded_self_heal)
      end

      # Once the covering ticket is done, the recorded failure decides again.
      Process.put({:fix_ticket_state, "TP-1000"}, {:ok, %Issue{id: "covering-id", identifier: "TP-1000", state: "Done"}})
      Process.put(:ticket_state, recorded(@repo_key, @issue_id, %{component: "qa_environment", scope: @symphony_repo_key, signature: SelfHeal.signature(outcome)}))

      assert :escalated = SelfHeal.heal(issue(), heal_opts(outcome, attempts: 3, terminal_states: ["Done", "Canceled"]))
    end

    test "a changed failure also retries, with no fix ticket to attach to" do
      previous =
        TicketState.new(@repo_key, @issue_id)
        |> TicketState.put_self_heal(%{component: "qa_environment", scope: @symphony_repo_key, signature: "an old failure"})

      Process.put(:ticket_state, previous)

      assert :retry = SelfHeal.heal(issue(), heal_opts(outcome(:a_new_failure)))
      assert Process.get(:fixer_attach) == nil
    end

    test "reports an escalation that could not be recorded" do
      previous =
        recorded(@repo_key, @issue_id, %{
          component: "qa_environment",
          scope: @symphony_repo_key,
          signature: ":environment_unreachable"
        })

      Process.put(:ticket_state, previous)
      Process.put(:hold_result, {:error, :disk_full})

      assert {:error, {:self_heal_escalation_failed, :disk_full}} = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
    end

    test "reports an access hold that could not be set" do
      Process.put(:hold_result, {:error, :disk_full})

      assert {:error, {:self_heal_hold_failed, :disk_full}} =
               SelfHeal.heal(issue(), heal_opts(outcome(:secret_missing, %{needs_person: true})))
    end

    test "a non-issue is refused" do
      assert {:error, :invalid_issue} = SelfHeal.heal(%{}, heal_opts(outcome(:environment_unreachable)))
    end
  end

  describe "environment_reason/1 and healthy/3" do
    setup do
      :ok = SymphonyElixir.RunStore.clear()
      on_exit(fn -> SymphonyElixir.RunStore.clear() end)
      %{ticket: {:ticket, @repo_key, @issue_id}}
    end

    test "names each component in plain words" do
      texts =
        for component <- ["worker_host", "dev_server", "qa_playbook", "ci:specs", "qa_environment"],
            do: SelfHeal.environment_reason(component).text

      assert texts == [
               "The QA machine is not reachable",
               "The QA machine cannot start the project's dev server",
               "The QA environment has no playbook for this change",
               "The QA environment cannot run the specs check",
               "The QA environment is not ready"
             ]

      refute SelfHeal.environment_reason?(%{kind: :environment, waits_on: %{condition: "ci_wait:abc"}})
      refute SelfHeal.environment_reason?(Pauses.ticket_reason(:fix_ticket, @fix_ticket))
    end

    test "the environment seen healthy clears its reasons, the backfill's too, by who says so, and leaves every other reason", %{ticket: ticket} do
      director = %{kind: :person, name: "Director"}
      backfilled = "QA blocked after 2 attempt(s): the QA host refused the connection"
      {:ok, _pause} = Pauses.set(ticket, Pauses.ticket_reason(:fix_ticket, @fix_ticket))
      {:ok, _pause} = Pauses.set(ticket, SelfHeal.environment_reason("worker_host"))
      {:ok, _pause} = Pauses.set(ticket, %{kind: :environment, waits_on: %{condition: backfilled}, text: backfilled}, backfilled: true)
      {:ok, _pause} = Pauses.set(ticket, %{kind: :environment, waits_on: %{condition: "ci_wait:abc"}})

      assert :ok = SelfHeal.healthy(@repo_key, @issue_id, director)

      assert {:ok, %{reasons: [%{kind: :ticket}, %{waits_on: %{condition: "ci_wait:abc"}}]}} = Pauses.get(ticket)
      assert [{"pause.reason_cleared", %{by: ^director}}, {"pause.reason_cleared", %{by: ^director}}] = ticket_events(@repo_key, @issue_id) |> Enum.filter(&match?({"pause.reason_cleared", _}, &1))
    end

    test "clears the pause with its last reason, and changes nothing on a ticket not paused or with no repo", %{ticket: ticket} do
      {:ok, _pause} = Pauses.set(ticket, SelfHeal.environment_reason("worker_host"))

      assert :ok = SelfHeal.healthy(@repo_key, @issue_id)
      assert {:ok, nil} = Pauses.get(ticket)
      assert :ok = SelfHeal.healthy(@repo_key, @issue_id)
      assert :ok = SelfHeal.healthy(nil, @issue_id)
    end
  end

  describe "heal/2 when the store or the tracker misbehaves" do
    test "an unreadable ticket-state list deduplicates nothing and an unreadable record is a first failure" do
      Process.put(:ticket_states, {:error, :mnesia_down})
      Process.put(:ticket_state, {:error, :mnesia_down})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
      assert Process.get(:fixer_create) != nil
    end

    test "a bookkeeping write that fails is reported and the hold still lands" do
      Process.put(:record_result, {:error, :disk_full})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
      assert Process.get(:hold_attrs) != nil
    end

    test "a link or an evidence comment that fails does not stop the hold" do
      Process.put(:block_result, {:error, :linear_down})
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))

      Process.put(:block_result, :ok)
      Process.put(:attach_result, {:error, :linear_down})

      Process.put(:ticket_states, [fix_record(":environment_unreachable")])
      Process.put({:fix_ticket_state, @fix_ticket}, {:ok, %Issue{id: "fix-id", identifier: @fix_ticket, state: "Todo"}})

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable), terminal_states: ["Done", "Canceled"]))
      assert {@fix_ticket, _evidence} = Process.get(:fixer_attach)
    end

    test "a ticket with no previous bookkeeping record is judged as a first failure" do
      Process.put(:ticket_state, nil)

      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable)))
    end
  end

  describe "the failure evidence" do
    test "carries the run's findings when it has any" do
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable, %{findings: ["`symphony check` exits 1"]})))

      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "- Findings:\n  - `symphony check` exits 1"
    end

    test "gives the run's own reason, not its first finding, with the findings listed apart" do
      outcome = outcome(:environment_unreachable, %{reason: "the QA build has no hub command", findings: ["the count truncates"]})
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome))

      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "- Reason: the QA build has no hub command\n"
      assert description =~ "- Findings:\n  - the count truncates"

      assert :filed = SelfHeal.heal(issue(), heal_opts(%{outcome | reason: nil}))
      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "- Reason: the count truncates\n"
    end

    test "falls back to the outcome's reason, and to a default when it has none" do
      assert :filed = SelfHeal.heal(issue(), heal_opts(outcome(:environment_unreachable, %{reason: "the sandbox could not start"})))
      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "the sandbox could not start"

      assert :filed = SelfHeal.heal(issue(), heal_opts(%{verdict: :blocked, cause: :x, reason: nil, findings: [], needs_person: false}))
      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ "the run could not verify the change"
    end

    test "an outcome with no findings key carries none" do
      assert :filed = SelfHeal.heal(issue(), heal_opts(%{verdict: :blocked, cause: :environment_unreachable, reason: "a reason", needs_person: false}))

      assert %{description: description} = Process.get(:fixer_create)
      refute description =~ "Findings"
    end

    test "an issue with no identifier is labelled by its id" do
      assert :filed = SelfHeal.heal(issue(%{identifier: nil}), heal_opts(outcome(:environment_unreachable)))
      assert %{description: description} = Process.get(:fixer_create)
      assert description =~ @issue_id
    end

    test "takes the repo key from the issue when none is given" do
      opts = heal_opts(outcome(:environment_unreachable)) |> Keyword.delete(:repo_key)

      assert :filed = SelfHeal.heal(issue(), opts)
      assert Process.get(:hold_attrs) != nil
    end
  end
end
