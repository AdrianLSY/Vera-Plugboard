defmodule VeraWeb.Router do
  use VeraWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VeraWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VeraWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/services", ServiceLive.Index, :index
    live "/services/new", ServiceLive.Index, :new
    live "/services/:id/edit", ServiceLive.Index, :edit
    live "/services/:id", ServiceLive.Show, :show
    live "/services/:id/new", ServiceLive.Show, :new
    live "/services/:id/edit/:child_id", ServiceLive.Show, :edit
    live "/services/:id/delete", ServiceLive.Show, :delete
  end

  # Other scopes may use custom stacks.
  # scope "/api", VeraWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:vera, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VeraWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
