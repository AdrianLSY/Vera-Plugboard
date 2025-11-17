defmodule PlugboardWeb.Router do
  use PlugboardWeb, :router

  import PlugboardWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PlugboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_scope_for_user
  end

  scope "/", PlugboardWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Proxy pipeline with validation
  pipeline :proxy do
    plug :accepts, ["json"]
    plug PlugboardWeb.Plugs.ValidatePath
  end

  # Proxy routes - must come after other routes to avoid conflicts
  scope "/call", PlugboardWeb do
    pipe_through :proxy

    # Catch-all route for proxy requests
    # The *path captures all remaining path segments as a list
    get "/*path", ProxyController, :proxy
    post "/*path", ProxyController, :proxy
    put "/*path", ProxyController, :proxy
    patch "/*path", ProxyController, :proxy
    delete "/*path", ProxyController, :proxy
    options "/*path", ProxyController, :proxy
    head "/*path", ProxyController, :proxy
  end

  # API routes for telephone token management
  scope "/api", PlugboardWeb.Api do
    pipe_through [:api, :require_authenticated_user]

    # Telephone token endpoints
    post "/paths/:path_id/tokens", TelephoneTokenController, :create
    get "/paths/:path_id/tokens", TelephoneTokenController, :index
    delete "/tokens/:id", TelephoneTokenController, :delete

    # Service account endpoints
    post "/paths/:path_id/service-accounts", ServiceAccountController, :create
    get "/paths/:path_id/service-accounts", ServiceAccountController, :index
    get "/service-accounts", ServiceAccountController, :index_for_user
    delete "/service-accounts/:id", ServiceAccountController, :delete

    # Domain affinity endpoints
    post "/paths/:path_id/domain-affinities", DomainAffinityController, :create
    get "/paths/:path_id/domain-affinities", DomainAffinityController, :index
    delete "/domain-affinities/:id", DomainAffinityController, :delete
  end

  # Token Vending Machine API (no user authentication required, uses service account API key)
  scope "/api/token-vending", PlugboardWeb.Api do
    pipe_through :api

    post "/generate", TokenVendingController, :generate
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:plugboard, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PlugboardWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PlugboardWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{PlugboardWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/paths", PathsLive.Index, :index
      live "/paths/:path_id/tokens", PathTokensLive.Index, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PlugboardWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Domain affinity proxy pipeline
  pipeline :domain_proxy do
    plug :accepts, ["json", "html"]
    plug PlugboardWeb.Plugs.DomainAffinityRouter
  end

  # Domain affinity routes - MUST come last as fallback
  # These routes handle domain-based routing (e.g., users.example.com → /call/users)
  # Only matches if no other route matched and domain has affinity
  scope "/", PlugboardWeb do
    pipe_through :domain_proxy

    # Catch-all for domain affinity routing
    get "/*path", ProxyController, :proxy_domain
    post "/*path", ProxyController, :proxy_domain
    put "/*path", ProxyController, :proxy_domain
    patch "/*path", ProxyController, :proxy_domain
    delete "/*path", ProxyController, :proxy_domain
    options "/*path", ProxyController, :proxy_domain
    head "/*path", ProxyController, :proxy_domain
  end
end
