defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability and control API.
  """

  use Phoenix.Router

  alias SymphonyElixirWeb.Plugs.{BearerToken, SameOriginOrAllowlisted}

  pipeline :api_state_changing do
    plug(SameOriginOrAllowlisted)
  end

  # Check Now forces one more watcher tick; a client that sends no Origin (curl, the app) may ask.
  pipeline :api_watch_check do
    plug(SameOriginOrAllowlisted, allow_missing: true)
  end

  pipeline :control_api do
    plug(BearerToken)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api_state_changing)

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api_watch_check)

    post("/api/v1/issues/:issue_identifier/watch/check", ObservabilityApiController, :watch_check)

    # The app's Setup turns instant GitHub updates on and off, and curl may too.
    post("/api/v1/setup/github_updates/:action", SetupController, :github_updates)
    post("/api/v1/setup/refresh", SetupController, :refresh)
  end

  # GitHub webhook deliveries authenticate with their HMAC signature, not a browser origin.
  # `log: false` keeps Phoenix from logging the payload as request parameters.
  scope "/", SymphonyElixirWeb do
    post("/api/v1/github/webhook", GitHubWebhookController, :create, log: false)
  end

  scope "/api/v1/control", SymphonyElixirWeb do
    pipe_through(:control_api)

    post("/pause", ControlApiController, :pause)
    post("/resume", ControlApiController, :resume)
    post("/stop", ControlApiController, :stop)
    post("/dispatch_pr", ControlApiController, :dispatch_pr)
    post("/force", ControlApiController, :force)
    post("/approve_plan", ControlApiController, :approve_plan)
    post("/rework", ControlApiController, :rework)
    post("/restart", ControlApiController, :restart)
    post("/decisions", ControlApiController, :decisions)
    post("/backlog", ControlApiController, :backlog)
    post("/unblock", ControlApiController, :unblock)
    post("/decide", ControlApiController, :decide)
    post("/undo", ControlApiController, :undo)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/setup", SetupController, :show)
    get("/api/v1/runs", ObservabilityApiController, :runs)
    get("/api/v1/history", ObservabilityApiController, :history)
    get("/api/v1/shipped", ObservabilityApiController, :shipped)
    get("/api/v1/learnings", ObservabilityApiController, :learnings)
    get("/api/v1/repos", ObservabilityApiController, :repos)
    get("/api/v1/inbox", ObservabilityApiController, :inbox)
    get("/api/v1/initiatives", ObservabilityApiController, :initiatives)
    get("/api/v1/runs/:session_id/report", ObservabilityApiController, :quality_report)
    get("/api/v1/pull_requests/:repo_key/:number", ObservabilityApiController, :pull_request)
    get("/api/v1/audit", AuditController, :index)
    get("/api/v1/audit/verify", AuditController, :verify)
    get("/api/v1/repos/:repo_key/issues/:identifier/transcript", ObservabilityApiController, :transcript)
    get("/api/v1/issues/:identifier/transcript", ObservabilityApiController, :transcript)

    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/setup", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/setup/github_updates/:action", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/setup/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/history", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/shipped", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/learnings", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/repos", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/inbox", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/initiatives", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:session_id/report", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/pull_requests/:repo_key/:number", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/audit", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/audit/verify", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/repos/:repo_key/issues/:identifier/transcript", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues/:identifier/transcript", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues/:issue_identifier/watch/check", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/webhook", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
