defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias SymphonyElixirWeb.Plugs.{BearerToken, SameOriginOrAllowlisted}

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api_state_changing do
    plug(SameOriginOrAllowlisted)
  end

  pipeline :control_api do
    plug(BearerToken)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/audit", AuditLive, :index)
    live("/quality", QualityLive, :index)
    live("/learnings", LearningsLive, :index)
    live("/repos/:repo_key/issues/:identifier/transcript", TranscriptLive, :show)
    live("/issues/:identifier/transcript", TranscriptLive, :show)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:api_state_changing)

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
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
    post("/approve_pr", ControlApiController, :approve_pr)
    post("/rework", ControlApiController, :rework)
    post("/decisions", ControlApiController, :decisions)
    post("/sign_off", ControlApiController, :sign_off)
    post("/backlog", ControlApiController, :backlog)
    post("/undo", ControlApiController, :undo)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/runs", ObservabilityApiController, :runs)
    get("/api/v1/repos", ObservabilityApiController, :repos)
    get("/api/v1/inbox", ObservabilityApiController, :inbox)
    get("/api/v1/runs/:session_id/report", ObservabilityApiController, :quality_report)
    get("/api/v1/audit", AuditController, :index)
    get("/api/v1/repos/:repo_key/issues/:identifier/transcript", ObservabilityApiController, :transcript)
    get("/api/v1/issues/:identifier/transcript", ObservabilityApiController, :transcript)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/repos", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/inbox", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/runs/:session_id/report", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/audit", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/repos/:repo_key/issues/:identifier/transcript", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues/:identifier/transcript", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/webhook", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
