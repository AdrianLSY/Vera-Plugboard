defmodule PlugboardWeb.PathsLive.Index do
  use PlugboardWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto">
        <.header>
          <p class="ui-text-primary">Paths</p>
          <:subtitle>
            <span class="ui-text-secondary">
              Manage your path hierarchy and mount points
            </span>
          </:subtitle>
        </.header>

        <div class="mt-8">
          <p class="ui-text-secondary text-center">
            Path management interface coming soon...
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
