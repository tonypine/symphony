defmodule SymphonyElixir.QaVerificationSupport do
  @moduledoc """
  What the QA verification tests share: the stand-ins a pass is given (QA agents, policies, a
  fixer, trackers), the ticket `issue-qa-verification` and its settings, and `run/3`, which runs
  that ticket through `SymphonyElixir.QaVerification.run/3` with them.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Handoff
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Pauses
  alias SymphonyElixir.QaVerification

  @repo_key "repo-qa-verification"
  @issue_id "issue-qa-verification"
  @symphony_repo_key "repo-symphony"
  @base_head "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

  @execution %{"harnesses" => %{"claude" => %{"command" => "claude", "small_model" => %{"anthropic" => "small-test"}}}}
  @runs %{"default" => %{"harness" => "claude", "provider" => "anthropic", "model" => "claude-test"}}

  defmodule FakeQaAgent do
    def run(job, settings, _opts) do
      send(self(), {:qa_agent_run, job, settings})
      Process.get(:qa_agent_result, pass_result())
    end

    defp pass_result do
      {:ok, %{result: %{verdict: :pass, summary: "Every journey worked.", steps: [], findings: []}, tokens: %{input: 10, output: 5}}}
    end
  end

  # A QA agent session that does what `:walkthrough_session` says, as an agent would: writes its
  # evidence under the worktree, uploads files with `linear_attach_file`, starts a Claude session
  # whose transcript Claude keeps, and records its verdict with `qa_verdict`.
  defmodule WalkthroughSession do
    alias SymphonyElixir.Codex.DynamicTool

    def start_session(worktree, _opts), do: {:ok, %{worktree: worktree}}
    def stop_session(_session), do: :ok

    def run_turn(%{worktree: worktree}, _prompt, issue, opts) do
      %{files: files, uploads: uploads, verdict: verdict} = Process.get(:walkthrough_session)
      tool_opts = Keyword.take(opts, [:tool_scope, :qa_verdict_sink])

      for {name, bytes} <- files do
        File.mkdir_p!(Path.dirname(Path.join(worktree, name)))
        File.write!(Path.join(worktree, name), bytes)
      end

      for name <- uploads do
        upload_client = fn _url, _opts -> {:ok, %{status: 200}} end
        attach_opts = [issue: issue, workspace: worktree, linear_client: &linear/3, upload_client: upload_client]
        %{"success" => true} = DynamicTool.execute("linear_attach_file", %{"local_path" => name}, tool_opts ++ attach_opts)
      end

      Keyword.fetch!(opts, :on_message).({:session_started, "walkthrough-session"})
      %{"success" => true} = DynamicTool.execute("qa_verdict", verdict, tool_opts)
      {:ok, %{result: ""}}
    end

    defp linear(query, variables, _opts) do
      if query =~ "SymphonyAgentFileUpload" do
        send(self(), {:walkthrough_upload, variables.filename})
        upload = %{"uploadUrl" => "https://upload.test", "assetUrl" => "https://assets.linear.test/#{variables.filename}", "headers" => []}
        {:ok, %{"data" => %{"fileUpload" => %{"success" => true, "uploadFile" => upload}}}}
      else
        attachment = %{"id" => "attachment-1", "url" => "https://uploads.linear.app/qa/" <> Path.basename(variables.url)}
        {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true, "attachment" => attachment}}}}
      end
    end
  end

  # Drives the real dev server, so a failing command injected through the settings is what blocks
  # the run — the QA environment block the self-heal lane exists for, not a hand-made verdict.
  defmodule DevServerQaAgent do
    def run(job, settings, _opts) do
      send(self(), {:qa_agent_run, job, settings})

      start_opts = [settings: settings, repo_key: job.repo_key]

      case SymphonyElixir.Verification.start_qa_dev_server(job.issue, job.run_id, job.workspace_path, start_opts) do
        {:ok, dev_server} ->
          SymphonyElixir.Verification.stop_qa_dev_server(dev_server)

          {:ok, %{result: %{verdict: :pass, summary: "The dev server started.", steps: [], findings: []}, tokens: %{}}}

        {:error, reason} ->
          {:error, {:qa_dev_server_failed, reason}, %{}}
      end
    end
  end

  # The fix-ticket filer, standing in for the Linear-backed one so no test reaches the network.
  defmodule FakeFixer do
    def create(attrs, _opts) do
      send(self(), {:fixer_create, attrs})
      Process.get(:fix_ticket_create, {:ok, %{identifier: Process.get(:fix_ticket, "TP-900"), url: "https://linear.app/acme/issue/TP-900"}})
    end

    def attach(identifier, body, _opts) do
      send(self(), {:fixer_attach, identifier, body})
      :ok
    end

    def block(_issue, ticket, _opts) do
      send(self(), {:fixer_block, ticket.identifier})
      :ok
    end
  end

  # The skip rule, driven from the test rather than from git: what the verdict says is the
  # behaviour under test here (`QaPolicy` itself is tested directly).
  defmodule RunPolicy do
    def decide(_issue, _settings, _opts) do
      {:run, [%{kind: "cli", paths: ["lib/symphony_elixir/cli.ex"], prompt: "Follow the CLI playbook."}], "the change delivers or updates a user journey"}
    end
  end

  # A UI change on the hub: the diff selects the enabled `macos_app` playbook, whose pass runs the
  # project's own server beside the app on the QA host.
  defmodule AppPolicy do
    def decide(_issue, settings, _opts) do
      {:run, Enum.filter(SymphonyElixir.QaPolicy.enabled_playbooks(settings), &(&1.kind == "macos_app")), "the change delivers or updates a user journey"}
    end
  end

  # A `macos_app` pass whose live-server choice `QaPolicy` already made: the playbook the test puts.
  defmodule LivePolicy do
    def decide(_issue, _settings, _opts), do: {:run, [Process.get(:qa_live_playbook)], "the change delivers or updates a user journey"}
  end

  defmodule FailingTracker do
    def update_issue_state(_issue_id, _state), do: {:error, :rate_limited}
  end

  defmodule SkipPolicy do
    def decide(_issue, _settings, _opts), do: {:skip, "the PR only changes docs, tests or `auto_review.skip_globs` paths"}
  end

  defmodule NothingToVerifyPolicy do
    def decide(_issue, _settings, _opts), do: {:nothing_to_verify, "the head changes no files against its base branch"}
  end

  # A workspace out of sync with its PR finds nothing to verify once; after the re-sync it runs.
  defmodule OnceEmptyPolicy do
    alias SymphonyElixir.QaVerificationSupport.RunPolicy

    def decide(issue, settings, opts) do
      if Process.put(:once_empty_decided, true),
        do: RunPolicy.decide(issue, settings, opts),
        else: {:nothing_to_verify, "the head changes no files against its base branch"}
    end
  end

  defmodule NoPlaybookPolicy do
    def decide(_issue, _settings, _opts), do: {:run, [], "the change delivers or updates a user journey"}
  end

  # The tracker the dependency sweep reads the fix ticket's state from.
  defmodule FixTicketTracker do
    def fetch_issue_by_identifier(_identifier), do: Process.get(:fix_ticket_issue, {:error, :not_found})
    def set_machine_label(_issue_id, _label), do: :ok
    def clear_machine_label(_issue_id, _label), do: :ok
  end

  def settings!(extra \\ %{}) do
    assert {:ok, settings} =
             Schema.parse(Map.merge(%{"tracker" => %{"kind" => "memory"}, "execution" => @execution, "runs" => @runs}, extra))

    settings
  end

  def issue(state \\ "QA", attrs \\ %{}) do
    struct!(
      %Issue{
        id: @issue_id,
        identifier: "TP-816",
        title: "Land the QA state",
        description: "## User walkthrough\n\n1. Run `symphony check`.\n",
        state: state,
        repo_key: @repo_key
      },
      attrs
    )
  end

  def run(workspace, opts, state \\ "QA") do
    QaVerification.run(
      issue(state),
      workspace,
      opts ++
        [
          settings: settings!(),
          repo_key: @repo_key,
          qa_policy: RunPolicy,
          qa_agent: FakeQaAgent,
          fixer: FakeFixer,
          symphony_repo_key: @symphony_repo_key
        ]
    )
  end

  # The hub's setup (TP-1279): its server is configured for the Mac app's pass on the QA host and
  # switched off on the Symphony host, so a server-only diff, which selects only `cli`, has neither
  # the app nor the server.
  def hub_settings do
    settings!(%{
      "verification" => %{
        "enabled" => false,
        "dev_server" => %{"start_cmd" => "bin/hub", "health_check_url" => "http://localhost:4000/healthz", "runs" => "every_qa_pass"}
      },
      "auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/Hub.app"}}}
    })
  end

  def needs_dev_server(steps) do
    %{verdict: :blocked, summary: "The server steps passed.", steps: steps, findings: [], reason: "no Postgres or hub dev server was running", needs_dev_server: true}
  end

  # A repo that also has the Mac app's playbook, which a server-only diff does not select, and no
  # server it rules out: a pass on such a diff offers `unprovable` for the app's steps only.
  def app_repo_settings(extra \\ %{}) do
    settings!(Map.merge(%{"auto_review" => %{"playbooks" => %{"macos_app" => %{"build" => "make app", "app" => "build/Hub.app"}}}}, extra))
  end

  def blocked_result(blocked_steps, reason) do
    steps = for name <- blocked_steps, do: %{name: name, status: "blocked", details: reason, evidence: []}
    {:ok, %{result: %{verdict: :blocked, summary: "Blocked.", steps: steps, findings: [], reason: reason}, tokens: %{}}}
  end

  # Paused on anything but a question: a fix ticket, the environment.
  def blocked?(issue_id) do
    case Pauses.get({:ticket, @repo_key, issue_id}) do
      {:ok, %{reasons: reasons}} -> Enum.any?(reasons, &(&1.kind != :question))
      _none -> false
    end
  end

  # The ticket's open decision request, as the Director's Decide answers it.
  def deciding(issue_id \\ @issue_id), do: SymphonyElixir.Questions.deciding({:ticket, @repo_key, issue_id})

  # The fix tickets the ticket's pause waits on.
  def fix_waits(issue_id) do
    case Pauses.get({:ticket, @repo_key, issue_id}) do
      {:ok, %{reasons: reasons}} ->
        for %{waits_on: %{identifier: identifier}} = reason <- reasons,
            Pauses.ticket_source(reason) == :fix_ticket,
            do: identifier

      _none ->
        []
    end
  end

  # A real checkout, so the verdict really binds to the head the run judged.
  def git_workspace! do
    dir = Path.join(System.tmp_dir!(), "qa-verification-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_out, 0} = System.cmd("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "first"], cd: dir)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {dir, String.trim(head)}
  end

  # Answers GitHub's diff of the PR (`SymphonyElixir.GitHub.PullRequest.fetch_diff/2`): its head
  # `pr_head`, compared with main at `@base_head`, changes `changed_files` files.
  def github_diff(pr_head, changed_files) do
    fn
      ["api", "repos/acme/repo/pulls/816", "--jq", _jq], _opts -> {Jason.encode!(%{head: pr_head, base_ref: "main"}), 0}
      ["api", "repos/acme/repo/compare/main..." <> _head, "--jq", _jq], _opts -> {Jason.encode!(%{base: @base_head, changed_files: changed_files}), 0}
    end
  end

  def nothing_opts(gh_runner), do: [qa_policy: NothingToVerifyPolicy, gh_runner: gh_runner]

  # The implementer's proof of walkthrough step `step`, as `linear_record_walkthrough_proofs` records it.
  def record_proof!(step, test) do
    payload = %{caption: "step #{step}", proof: %{step: step, test: test}}
    {:ok, _event} = SymphonyElixir.TicketEvents.record(@repo_key, @issue_id, "evidence", payload, actor: {:agent, "run-1", "implementation"})
  end

  def verdicts, do: Handoff.verdicts(@repo_key, @issue_id, "qa")
end
