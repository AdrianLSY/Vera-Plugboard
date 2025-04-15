defmodule VeraWeb.Router do
  use VeraWeb, :router

  import VeraWeb.AccountAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VeraWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VeraWeb do
    pipe_through :browser
    get "/", PageController, :home
  end

  scope "/", VeraWeb do
    pipe_through :api
    post "/", PageController, :request
  end

  if Application.compile_env(:vera, :dev_routes) do
    import Phoenix.LiveDashboard.Router
    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: VeraWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", VeraWeb do
    pipe_through [:browser, :redirect_if_account_is_authenticated]
    live_session :redirect_if_account_is_authenticated,
      on_mount: [{VeraWeb.AccountAuth, :redirect_if_account_is_authenticated}] do
      live "/accounts/register", AccountRegistrationLive, :new
      live "/accounts/log_in", AccountLoginLive, :new
      live "/accounts/reset_password", AccountForgotPasswordLive, :new
      live "/accounts/reset_password/:token", AccountResetPasswordLive, :edit
    end
    post "/accounts/log_in", AccountSessionController, :create
  end

  scope "/", VeraWeb do
    pipe_through [:browser, :require_authenticated_account]
    live_session :require_authenticated_account,
      on_mount: [{VeraWeb.AccountAuth, :ensure_authenticated}] do
      live "/accounts/settings", AccountSettingsLive, :edit
      live "/accounts/settings/confirm_email/:token", AccountSettingsLive, :confirm_email
      live "/services", ServiceLive.Index, :index
      live "/services/new", ServiceLive.Index, :new
      live "/services/:id/edit", ServiceLive.Index, :edit
      live "/services/:id", ServiceLive.Show, :show
      live "/services/:id/new", ServiceLive.Show, :new
      live "/services/:id/edit/:child_id", ServiceLive.Show, :edit
      live "/services/:id/delete", ServiceLive.Show, :delete
    end
  end

  scope "/", VeraWeb do
    pipe_through [:browser]

    delete "/accounts/log_out", AccountSessionController, :delete

    live_session :current_account,
      on_mount: [{VeraWeb.AccountAuth, :mount_current_account}] do
      live "/accounts/confirm/:token", AccountConfirmationLive, :edit
      live "/accounts/confirm", AccountConfirmationInstructionsLive, :new
    end
  end
end
