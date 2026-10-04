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
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: {SymphonyElixir.HttpServer, :allowed_origin?, []},
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
    repo_fetch_retry_delay_ms: 0
end
