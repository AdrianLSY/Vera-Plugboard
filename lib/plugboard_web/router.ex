defmodule PlugboardWeb.Router do
  use PlugboardWeb, :router

  import PlugboardWeb.Accounts.AccountAuth

  pipeline :admin_or_own_account do
    plug :require_admin_or_own_account
  end

  @doc """
  Pipelines:
  - :browser - basic browser functionality
  - :api - API functionality
  - :redirect_if_account_is_authenticated - redirects if user is already logged in
  - :require_authenticated_account - ensures user is logged in
  - :require_admin_account - ensures user is logged in AND has admin role
  """

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PlugboardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PlugboardWeb do
    pipe_through :browser
    get "/", PageController, :home
  end

  scope "/", PlugboardWeb do
    pipe_through :api
    post "/", PageController, :request
    post "/account_token/new", PageController, :account_token
    post "/service_token/new", PageController, :service_token
  end

  if Application.compile_env(:plugboard, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: PlugboardWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser, :redirect_if_account_is_authenticated]

    live_session :redirect_if_account_is_authenticated,
      on_mount: [{PlugboardWeb.Accounts.AccountAuth, :redirect_if_account_is_authenticated}] do
      live "/register", AccountLive.Registration, :new
      live "/login", AccountLive.Login, :new
      live "/reset_password", AccountLive.ForgotPassword, :new
      live "/reset_password/:token", AccountLive.ResetPassword, :edit
    end

    post "/login", AccountSessionController, :create
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser, :require_authenticated_account]

    live_session :require_authenticated_account,
      on_mount: [{PlugboardWeb.Accounts.AccountAuth, :ensure_authenticated}] do
      live "/settings", AccountLive.Settings, :edit
      live "/settings/confirm_email/:token", AccountLive.Settings, :confirm_email
    end
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser]

    delete "/log_out", AccountSessionController, :delete

    live_session :current_account,
      on_mount: [{PlugboardWeb.Accounts.AccountAuth, :mount_current_account}] do
      live "/confirm/:token", AccountLive.Confirmation, :edit
      live "/confirm", AccountLive.ConfirmationInstructions, :new
    end
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser, :require_admin_account]

    live_session :require_admin_account,
      on_mount: [{PlugboardWeb.Accounts.AccountAuth, :ensure_admin}] do
      live "/services", ServiceLive.Index, :index
      live "/services/new", ServiceLive.Index, :new
      live "/services/:id/edit", ServiceLive.Index, :edit
      live "/services/:id", ServiceLive.Show, :show
      live "/services/:id/new", ServiceLive.Show, :new
      live "/services/:id/edit/:child_id", ServiceLive.Show, :edit
      live "/services/:id/delete", ServiceLive.Show, :delete
      live "/services/:id/tokens/new", ServiceLive.Show, :new_token

      live "/accounts", AccountLive.Index, :index
      live "/accounts/new", AccountLive.Index, :new
      live "/accounts/:id/edit", AccountLive.Index, :edit
    end
  end

  scope "/", PlugboardWeb do
    pipe_through [:browser, :admin_or_own_account]

    live_session :require_admin_or_own_account,
      on_mount: [{PlugboardWeb.Accounts.AccountAuth, :ensure_admin_or_own_account}] do
      live "/accounts/:id", AccountLive.Show, :show
    end
  end
end
