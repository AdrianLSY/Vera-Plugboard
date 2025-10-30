defmodule PlugboardWeb.UserLive.Confirmation do
  use PlugboardWeb, :live_view

  alias Plugboard.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p class="ui-text-primary">Welcome {@user.email}</p>
          </.header>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            type="submit"
            phx-disable-with="Confirming..."
          >
            Confirm and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button type="submit" phx-disable-with="Confirming..." class="mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button type="submit" phx-disable-with="Logging in...">
              Log in <span aria-hidden="true">→</span>
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              type="submit"
              phx-disable-with="Logging in..."
            >
              Keep me logged in on this device <span aria-hidden="true">→</span>
            </.button>
            <.button type="submit" phx-disable-with="Logging in..." class="mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <div :if={!@user.confirmed_at} class="ui-inverted-background rounded-lg p-3 flex gap-3 mt-8">
          <.icon name="hero-information-circle" class="size-6 shrink-0 ui-inverted-text-primary" />
          <p class="ui-inverted-text-primary">
            Tip: If you prefer passwords, you can enable them in the user settings.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
