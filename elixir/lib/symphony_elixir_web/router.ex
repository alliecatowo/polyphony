defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
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
  end

  scope "/", SymphonyElixirWeb do
    get("/auth/github/start", GitHubAuthController, :start)
    get("/auth/github/callback", GitHubAuthController, :callback)
    get("/auth/github/status", GitHubAuthController, :status)
    post("/github/webhook", GitHubWebhookController, :receive)

    get("/api/v1/state", ObservabilityApiController, :state)
    post("/api/v1/control/pause", ControlApiController, :pause)
    post("/api/v1/control/drain", ControlApiController, :drain)
    post("/api/v1/control/resume", ControlApiController, :resume)
    post("/api/v1/control/stop", ControlApiController, :stop)
    post("/api/v1/control/hard-stop", ControlApiController, :hard_stop)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/control/pause", ControlApiController, :method_not_allowed)
    match(:*, "/api/v1/control/drain", ControlApiController, :method_not_allowed)
    match(:*, "/api/v1/control/resume", ControlApiController, :method_not_allowed)
    match(:*, "/api/v1/control/stop", ControlApiController, :method_not_allowed)
    match(:*, "/api/v1/control/hard-stop", ControlApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
