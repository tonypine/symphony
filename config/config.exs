import Config

config :logger, :default_formatter,
  metadata: [
    :issue_id,
    :issue_identifier,
    :session_id,
    :age_ms,
    :orchestrator_mailbox_len,
    :orchestrator_alive?,
    :existing_owner,
    :self
  ]

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  secret_key_base: String.duplicate("s", 64),
  server: false

if config_env() == :test do
  config :symphony_elixir,
    symphony_file_path: Path.expand("../test/fixtures/runtime/symphony.yml", __DIR__),
    # Include the OS pid: System.unique_integer/1 is only unique within one VM,
    # so concurrent `mix test` runs sharing TMPDIR would otherwise collide on
    # the same Mnesia run store directory (RunStore startup timeouts and
    # :no_such_log aborts when one run's after_suite removes the shared dir).
    state_root: Path.join(System.tmp_dir!(), "symphony-elixir-test-state-#{System.pid()}-#{System.unique_integer([:positive])}"),
    logs_root: Path.join(System.tmp_dir!(), "symphony-elixir-test-logs-#{System.pid()}-#{System.unique_integer([:positive])}"),
    run_store_dir: Path.join(System.tmp_dir!(), "symphony-elixir-test-run-store-#{System.pid()}-#{System.unique_integer([:positive])}"),
    # A git fetch that fails on `cannot lock ref` is retried at once in tests.
    repo_fetch_retry_delay_ms: 0,
    # The orchestrator's boot starts the ticket events backfill, and the pause backfill after it, in
    # a task; in tests it would race the events and the state payload a test asserts, so it runs only
    # where a test starts it (`TicketEvents.Backfill.start/1`). Set here, not in `test_helper.exs`:
    # `mix test` boots the app before the helper runs.
    ticket_events_backfill: false,
    # The pause projector (`SymphonyElixir.Pauses.Projector`) writes the labels and the Decisions
    # section in place of the holds and the decision store. Its tests and the ones that prove its
    # gates turn it on; off here, the suites of the holds and the decisions keep their own writes.
    pause_projector: false

  # No test reaches the network: every Req request goes through the guard, which lets 127.0.0.1 and
  # localhost through and raises `SymphonyElixir.OutboundConnectionInTest` for any other host. A test
  # that stubs its requests (`plug:`, its own `adapter:`) replaces it.
  config :req, default_options: [adapter: SymphonyElixir.OutboundGuard]

  # The secrets the config resolves (`issues.linear.api_key` and the `$NAME` references, with
  # `LINEAR_API_KEY` and `LINEAR_ASSIGNEE` as fallbacks) come from the test, never from the shell
  # that runs `mix test`: they are cleared before the app boots, so a key the developer exported is
  # invisible to the suite and to every process it starts. A test that wants one sets it itself.
  for name <- ~w(LINEAR_API_KEY LINEAR_ASSIGNEE OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY
                 GH_TOKEN GITHUB_TOKEN SLACK_WEBHOOK_URL SLACK_BOT_TOKEN WEBHOOK_URL),
      do: System.delete_env(name)
end
